import AVFoundation

/// One audio session for the whole app: playing the Mac's sound, recording the microphone, or both.
/// Whoever starts or stops says so here, and the session is set up for what is in use at that moment.
enum PadAudioSession {
    private static let lock = NSLock()
    /// For the volume log (build 62): how often the session was switched on or off, and its state now.
    private(set) static var activations = 0, deactivations = 0
    static var state: String {
        let session = AVAudioSession.sharedInstance()
        lock.lock(); defer { lock.unlock() }
        return "category=\(session.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "")) "
            + "playing=\(playing) recording=\(recording) on=\(activations)/off=\(deactivations) "
            + "others=\(session.isOtherAudioPlaying) route=\(session.currentRoute.outputs.first?.portType.rawValue ?? "-")"
    }
    private static var playing = false, recording = false
    static func set(playing: Bool? = nil, recording: Bool? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        if let playing { self.playing = playing }
        if let recording { self.recording = recording }
        let session = AVAudioSession.sharedInstance()
        guard self.playing || self.recording else {
            deactivations += 1
            try? session.setActive(false, options: [.notifyOthersOnDeactivation]); return
        }
        // Mixes with whatever the iPad itself is playing instead of stopping it. With the microphone on, sound
        // still goes to the speaker or to Bluetooth headphones in full quality; the headphones' own microphone is
        // deliberately not used, because switching them to their headset mode makes everything sound like a phone call.
        let category: AVAudioSession.Category = self.recording ? .playAndRecord : .playback
        let options: AVAudioSession.CategoryOptions = self.recording ? [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP] : [.mixWithOthers]
        if session.category != category || session.categoryOptions != options {
            try session.setCategory(category, mode: .default, options: options)
        }
        try? session.setPreferredIOBufferDuration(0.005)
        activations += 1
        try session.setActive(true)
    }
}

/// Sends the iPad's microphone to the Mac (StreamFeature.microphone, build 50): one channel of Opus, a packet
/// every 10 ms, on its own connection. The format goes first, and again whenever the microphone changes.
final class MicCapture {
    private let queue = DispatchQueue(label: "skydesk.mic.capture", qos: .userInteractive)
    private let channel: SecureChannel
    private var engine: AVAudioEngine?
    private var encoder: OpusEncoder?
    private var sequence: UInt64 = 0
    private var wanted = false
    private var suspended = false
    private var observer: NSObjectProtocol?
    /// Called on the capture queue when the microphone cannot be used.
    var onFailure: ((String) -> Void)?
    init(channel: SecureChannel) { self.channel = channel }

    func start() {
        AVAudioApplication.requestRecordPermission { [weak self] granted in
            self?.queue.async { [weak self] in
                guard let self else { return }
                guard granted else {
                    self.onFailure?("SkyDesk isn't allowed to use the microphone. Allow it in Settings › Privacy & Security › Microphone.")
                    return
                }
                self.wanted = true
                self.observe()
                self.begin()
            }
        }
    }
    func stop() {
        queue.async { [self] in
            wanted = false
            if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
            end()
            try? PadAudioSession.set(recording: false)
        }
    }
    /// The app left the screen: iPadOS stops the microphone anyway; say so by stopping cleanly.
    func setSuspended(_ value: Bool) {
        queue.async { [self] in
            guard suspended != value else { return }
            suspended = value
            if value { end() } else if wanted { begin() }
        }
    }
    private func observe() {
        guard observer == nil else { return }
        // A headset plugged in, a call ending…: the microphone's format may have changed, so start again.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] note in
            self?.queue.async { [weak self] in
                guard let self, self.wanted, !self.suspended, let engine = self.engine, (note.object as? AVAudioEngine) === engine else { return }
                self.end(); self.begin()
            }
        }
    }
    private func begin() {
        guard wanted, !suspended, engine == nil else { return }
        do {
            try PadAudioSession.set(recording: true)
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw DeskError.invalid("This iPad has no microphone available right now.") }
            let encoder = try OpusEncoder(input: format, bitrate: 48_000, channels: 1)
            // The sink is handed sound on the audio thread, a few milliseconds at a time: copy it and get off that thread.
            let sink = AVAudioSinkNode { [weak self] _, frames, list -> OSStatus in
                guard let self, let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return noErr }
                copy.frameLength = frames
                let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
                let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                for index in 0..<min(source.count, target.count) {
                    guard let from = source[index].mData, let to = target[index].mData else { continue }
                    memcpy(to, from, Int(min(source[index].mDataByteSize, target[index].mDataByteSize)))
                }
                self.queue.async { [weak self] in self?.send(copy, with: encoder) }
                return noErr
            }
            engine.attach(sink)
            engine.connect(input, to: sink, format: format)
            try engine.start()
            self.engine = engine; self.encoder = encoder
            channel.send(.audioFormat(encoder.info))
        } catch {
            end(); wanted = false
            try? PadAudioSession.set(recording: false)
            onFailure?("The microphone couldn't be started: \(error.localizedDescription)")
        }
    }
    private func end() {
        engine?.stop(); engine = nil; encoder = nil
    }
    private func send(_ buffer: AVAudioPCMBuffer, with encoder: OpusEncoder) {
        // Sound captured for an encoder that has since been replaced is dropped.
        guard self.encoder === encoder, channel.backlogBytes < 12_000, let packets = try? encoder.encode(buffer) else { return }
        for bytes in packets {
            sequence &+= 1
            channel.send(AudioPacket(sequence: sequence, bytes: bytes).packet())
        }
    }
}
