import AVFoundation
import Accelerate
import CoreAudio

/// Reads everything the Mac is playing through a Core Audio process tap (macOS 14.2+).
///
/// With `muted`, macOS stops sending that sound to the Mac's own speakers for as long as this tap is being read,
/// and starts again by itself the moment it is not (stop, quit or crash). No volume or mute setting is changed.
@available(macOS 14.2, *)
final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "skydesk.audio.tap", qos: .userInteractive)
    private(set) var format: AVAudioFormat?
    private(set) var muted = false
    /// Called on the tap's queue. The buffer's memory is only valid during the call.
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Set on the tap's own queue, so it never changes under a buffer being delivered.
    func setHandler(_ handler: @escaping (AVAudioPCMBuffer) -> Void) { queue.async { [weak self] in self?.onBuffer = handler } }

    var running: Bool { deviceID != kAudioObjectUnknown }

    func start(muted: Bool) throws {
        stop()
        do {
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcess().map { [$0] } ?? [])
            description.uuid = UUID()
            description.name = "SkyDesk"
            description.isPrivate = true
            description.muteBehavior = muted ? .mutedWhenTapped : .unmuted
            var tap = AudioObjectID(kAudioObjectUnknown)
            try Self.check(AudioHardwareCreateProcessTap(description, &tap), "Create the system sound tap")
            tapID = tap
            var stream = AudioStreamBasicDescription()
            try Self.read(tap, kAudioTapPropertyFormat, into: &stream, "Read the sound format")
            guard let format = AVAudioFormat(streamDescription: &stream) else { throw DeskError.invalid("Unsupported Mac sound format.") }
            self.format = format
            // The tap is read through a private device that takes its clock from the Mac's current output.
            let output = try Self.defaultOutputUID()
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "SkyDesk Sound",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: output,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]]
            ]
            var device = AudioObjectID(kAudioObjectUnknown)
            try Self.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &device), "Create the sound capture device")
            deviceID = device
            var proc: AudioDeviceIOProcID?
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { [weak self] _, input, _, _, _ in
                guard let self, let format = self.format,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
                self.onBuffer?(buffer)
            }, "Read the Mac's sound")
            procID = proc
            try Self.check(AudioDeviceStart(device, proc), "Start reading the Mac's sound")
            self.muted = muted
        } catch { stop(); throw error }
    }
    func stop() {
        if deviceID != kAudioObjectUnknown {
            if let procID { AudioDeviceStop(deviceID, procID); AudioDeviceDestroyIOProcID(deviceID, procID) }
            AudioHardwareDestroyAggregateDevice(deviceID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        deviceID = AudioObjectID(kAudioObjectUnknown); tapID = AudioObjectID(kAudioObjectUnknown); procID = nil
        muted = false
    }
    deinit { stop() }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw DeskError.system(operation, status) }
    }
    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout T, _ operation: String) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), operation)
    }
    /// SkyDesk makes no sound itself; excluding it keeps the tap from ever feeding back.
    private static func ownProcess() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
    static func defaultOutput() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        try? read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, into: &device, "Find the Mac's sound output")
        return device == kAudioObjectUnknown ? nil : device
    }
    private static func defaultOutputUID() throws -> String {
        guard let device = defaultOutput() else { throw DeskError.invalid("This Mac has no sound output.") }
        var uid: Unmanaged<CFString>?
        try read(device, kAudioDevicePropertyDeviceUID, into: &uid, "Identify the Mac's sound output")
        guard let uid else { throw DeskError.invalid("This Mac's sound output has no identifier.") }
        return uid.takeRetainedValue() as String
    }
}

/// One session's sound: captures the Mac's audio, compresses it and sends it on the audio channel.
///
/// The Mac's own speakers are silenced only once two things are known: real sound has been captured (so the
/// permission is in place and capture works) and the iPad says it is playing. Until then, and whenever the iPad
/// stops playing, the Mac plays its sound itself as usual.
@MainActor
final class HostAudio {
    private var worker: AnyObject?
    private var padPlaying = false
    private var heardSound = false
    private var paused = false
    private var stopped = false
    private var outputWatch: AudioObjectPropertyListenerBlock?
    private var lastOutput: AudioObjectID?
    private var restartWork: DispatchWorkItem?
    var onStatus: ((String) -> Void)?

    static var supported: Bool { if #available(macOS 14.2, *) { return true } else { return false } }

    init(channel: SecureChannel) {
        guard #available(macOS 14.2, *) else { return }
        let worker = AudioCaptureWorker(channel: channel)
        worker.onHeard = { [weak self] in
            guard let self, !self.heardSound else { return }
            self.heardSound = true; self.sync()
        }
        worker.onFailure = { [weak self] in self?.onStatus?($0) }
        self.worker = worker
    }
    func start() {
        guard #available(macOS 14.2, *) else { return }
        lastOutput = SystemAudioTap.defaultOutput()
        watchOutputDevice()
        sync()
    }

    // MARK: SkyDesk Speakers (build 65)

    /// The output this object itself last chose, so the change notice it causes is not taken for the user's choice.
    private var expectedOutput: AudioObjectID?
    /// With SkyDesk Speakers installed, the Mac's Sound output menu is the switch: sound goes to the iPad only
    /// while SkyDesk Speakers is chosen, and nothing on the Mac needs silencing (that output makes no sound).
    private var speakers: AudioObjectID? { SpeakersDriver.device() }
    /// Chooses SkyDesk Speakers or the Mac's own output to match the session and the user's last choice.
    private func route() {
        guard speakers != nil else { return }
        let toPad = !stopped && !paused && padPlaying && SpeakersDriver.wanted
        let switched = toPad ? SpeakersDriver.routeToPad() : SpeakersDriver.routeToMac()
        if switched { expectedOutput = SpeakersDriver.defaultOutput() }
    }
    /// A change of output made in the Sound menu during a session becomes the choice for later sessions.
    private func noteOutputChange(_ output: AudioObjectID?) {
        defer { expectedOutput = nil }
        guard let speakers, output != expectedOutput, !stopped, !paused else { return }
        let chose = output == speakers
        if SpeakersDriver.wanted != chose {
            SpeakersDriver.wanted = chose
            MetricsLog.shared.append("host  sound output chosen in the Sound menu: " + (chose ? "SkyDesk Speakers (iPad plays)" : "a Mac output (Mac plays)"))
        }
        if !chose, let output { SpeakersDriver.previousUID = SpeakersDriver.uid(of: output) }
    }
    func setPadPlaying(_ playing: Bool) {
        guard padPlaying != playing else { return }
        padPlaying = playing
        MetricsLog.shared.append("host  iPad " + (playing ? "is playing the Mac's sound" : "stopped playing the Mac's sound"))
        sync()
    }
    /// iPad in the background: nothing is captured, so the Mac plays its sound itself.
    func setPaused(_ value: Bool) {
        guard paused != value else { return }
        paused = value
        if value { padPlaying = false }
        sync()
    }
    func stop() {
        stopped = true
        restartWork?.cancel(); restartWork = nil
        sync()
        if let outputWatch {
            var address = Self.outputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, outputWatch)
            self.outputWatch = nil
        }
    }
    private func sync(force: Bool = false) {
        guard #available(macOS 14.2, *), let worker = worker as? AudioCaptureWorker else { return }
        if let speakers {
            route()
            // Captured while the sound goes into SkyDesk Speakers, and at the start of a session that will use it:
            // the iPad only says it is playing once sound has reached it, and the switch waits for that.
            let onSpeakers = SystemAudioTap.defaultOutput() == speakers
            let starting = !padPlaying && SpeakersDriver.wanted
            worker.set(running: !stopped && !paused && (onSpeakers || starting), muted: false, force: force)
            return
        }
        worker.set(running: !stopped && !paused, muted: heardSound && padPlaying && !paused, force: force)
    }
    func statisticsText() -> String? {
        guard #available(macOS 14.2, *), let worker = worker as? AudioCaptureWorker else { return nil }
        return worker.statisticsText()
    }
    private static var outputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
    /// Headphones plugged in, a display with speakers switched off…: the capture device follows the new output.
    private func watchOutputDevice() {
        guard #available(macOS 14.2, *), outputWatch == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                let output = SystemAudioTap.defaultOutput()
                guard output != self.lastOutput else { return }
                self.lastOutput = output
                self.noteOutputChange(output)
                self.restartWork?.cancel()
                let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.sync(force: true) } }
                self.restartWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
        }
        var address = Self.outputAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr { outputWatch = block }
    }
}

/// Starts and stops the tap on its own queue: Core Audio calls can take a moment (or wait on a permission
/// prompt), and none of that may hold up the app's main thread. Callbacks arrive on the main thread.
@available(macOS 14.2, *)
final class AudioCaptureWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "skydesk.audio.control", qos: .userInitiated)
    private let channel: SecureChannel
    private var tap: SystemAudioTap?
    private var announced = false
    private let state = AudioSendState()
    var onHeard: (@MainActor () -> Void)?
    var onFailure: (@MainActor (String) -> Void)?

    init(channel: SecureChannel) { self.channel = channel }

    func set(running: Bool, muted: Bool, force: Bool = false) {
        queue.async { [self] in
            guard running else {
                if tap != nil { tap?.stop(); tap = nil; MetricsLog.shared.append("host  sound capture off") }
                return
            }
            if let tap, tap.running, tap.muted == muted, !force { return }
            restart(muted: muted)
        }
    }
    private func restart(muted: Bool) {
        tap?.stop(); tap = nil
        let tap = SystemAudioTap()
        do {
            try tap.start(muted: muted)
            guard let format = tap.format else { throw DeskError.invalid("No Mac sound format.") }
            let encoder = try OpusEncoder(input: format)
            if !announced { announced = true; channel.send(.audioFormat(encoder.info)) }
            let channel = channel, state = state
            tap.setHandler { [weak self] buffer in
                // The tap's queue. Level check first: proof that capture really works.
                if !state.heard, Self.peak(buffer) > 0.001 {
                    state.heard = true
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.onHeard?() } }
                }
                state.captured(now: monotonicNanos())
                // A stalled link drops sound instead of queueing it: late sound is worse than a gap.
                guard channel.backlogBytes < 24_000, let packets = try? encoder.encode(buffer) else { state.dropped(); return }
                for bytes in packets {
                    state.sequence &+= 1
                    channel.send(AudioPacket(sequence: state.sequence, bytes: bytes).packet())
                }
                state.sent(packets.count)
            }
            self.tap = tap
            MetricsLog.shared.append("host  sound capture on (\(Int(format.sampleRate)) Hz, " + (muted ? "Mac speakers silenced" : "Mac speakers still playing") + ")")
        } catch {
            tap.stop()
            let reason = error.localizedDescription
            MetricsLog.shared.append("host  sound capture failed: \(reason)")
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onFailure?("The Mac's sound couldn't be captured: \(reason)") } }
        }
    }
    /// For the once-a-second log line: nil while nothing is being captured.
    func statisticsText() -> String? { state.drain() }
    static func peak(_ buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.format.commonFormat == .pcmFormatFloat32, let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var value: Float = 0
        let samples = Int(buffer.frameLength) * (buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1)
        vDSP_maxmgv(data[0], 1, &value, vDSP_Length(samples))
        return value
    }
}

/// `sequence` and `heard` are touched only on the tap's queue; the counts are read from the main thread too.
private final class AudioSendState: @unchecked Sendable {
    var sequence: UInt64 = 0
    var heard = false
    private let lock = NSLock()
    private var buffers = 0, packets = 0, drops = 0
    private var longestGap = 0.0
    private var last: UInt64?
    func captured(now: UInt64) {
        lock.lock(); buffers += 1
        if let last, now > last { longestGap = max(longestGap, Double(now - last) / 1_000_000) }
        last = now; lock.unlock()
    }
    func sent(_ count: Int) { lock.lock(); packets += count; lock.unlock() }
    func dropped() { lock.lock(); drops += 1; lock.unlock() }
    /// Sound packets sent, capture buffers not sent (stalled link or a failed encode), and the longest wait
    /// between two capture buffers, since the last call.
    func drain() -> String? {
        lock.lock(); defer { buffers = 0; packets = 0; drops = 0; longestGap = 0; lock.unlock() }
        guard buffers > 0 else { return nil }
        return String(format: "sound %d sent, %d dropped, longest capture gap %.0f ms", packets, drops, longestGap)
    }
}
