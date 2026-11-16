#if os(macOS)
import Foundation
import AVFoundation
import CoreAudio

/// A sound output of this Mac.
public struct SoundOutput: Equatable, Identifiable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
}

/// The Mac has no way for an app to *be* a microphone; that takes a sound driver. A loopback device is such a
/// driver: whatever is played into it comes out of it as a microphone. BlackHole (free) is the usual one. SkyDesk
/// plays the iPad's microphone into the loopback device, and Mac apps choose that device as their microphone.
public enum SoundOutputs {
    /// Names that mark a loopback device.
    static let loopbackNames = ["blackhole", "loopback", "vb-cable", "soundflower"]
    public static func isLoopback(_ name: String) -> Bool { let lower = name.lowercased(); return loopbackNames.contains { lower.contains($0) } }
    /// The device the microphone goes to: the saved choice while it exists, otherwise the first loopback device.
    public static func microphoneTarget(saved uid: String?, among devices: [SoundOutput]) -> SoundOutput? {
        if let uid, !uid.isEmpty, let chosen = devices.first(where: { $0.uid == uid }) { return chosen }
        return devices.first { isLoopback($0.name) }
    }
    /// Every device with output channels, in the system's order.
    public static func all() -> [SoundOutput] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard outputChannels(id) > 0, let name = text(id, kAudioObjectPropertyName), let uid = text(id, kAudioDevicePropertyDeviceUID),
                  !name.hasPrefix("SkyDesk") else { return nil }
            return SoundOutput(id: id, uid: uid, name: name)
        }
    }
    private static func outputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    private static func text(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// Plays the iPad's microphone into one sound output. Fed straight from the network queue; everything else
/// runs on its own queue. The first message is the format, then come the packets.
public final class MicPlayback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "skydesk.mic.play", qos: .userInteractive)
    private let device: AudioDeviceID
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var decoder: OpusDecoder?
    private var jitter = AudioJitter()
    /// Where the scheduled sound ends, on the player's own clock (as in the iPad's player, build 46).
    private var scheduledEnd: Int64 = 0
    private var failed = false
    private let lock = NSLock()
    private var packets = 0, played = 0, dry = 0, dropped = 0
    /// Called once, on the playback queue, if the microphone cannot be played.
    public var onFailure: ((String) -> Void)?
    public init(device: AudioDeviceID) { self.device = device }

    public func handle(_ packet: WirePacket) {
        queue.async { [self] in
            guard !failed else { return }
            do {
                if packet.kind == .audio { try play(AudioPacket(packet: packet)); return }
                guard case .audioFormat(let info) = try packet.controlMessage(), info.isValid else { throw DeskError.invalid("Unexpected microphone message.") }
                try configure(info)
            } catch {
                failed = true; stopEngine()
                onFailure?("The iPad's microphone can't be played on the Mac: \(error.localizedDescription)")
            }
        }
    }
    public func stop() { queue.async { [self] in failed = true; stopEngine() } }
    /// Waits for everything handed over so far; for tests.
    public func drain() { queue.sync {} }
    /// Packets received, packets played, times the player ran dry and backlogs dropped, since the last call.
    public func statistics() -> (packets: Int, played: Int, ranDry: Int, dropped: Int) {
        lock.lock(); defer { packets = 0; played = 0; dry = 0; dropped = 0; lock.unlock() }
        return (packets, played, dry, dropped)
    }
    /// A new format arrives when the iPad's microphone changes (headset plugged in, a call ended).
    private func configure(_ info: AudioStreamInfo) throws {
        stopEngine()
        let decoder = try OpusDecoder(info: info)
        let engine = AVAudioEngine(), node = AVAudioPlayerNode()
        // Before anything is connected: the engine then builds itself for this device, not the Mac's speakers.
        try engine.outputNode.auAudioUnit.setDeviceID(device)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: decoder.format)
        try engine.start()
        node.play()
        self.decoder = decoder; self.engine = engine; self.node = node
        jitter = AudioJitter(sampleRate: info.sampleRate, deviceBufferMS: 11)
        scheduledEnd = 0
    }
    private func stopEngine() {
        node?.stop(); engine?.stop()
        engine = nil; node = nil; decoder = nil; scheduledEnd = 0
    }
    private func playerNow() -> Int64? {
        guard let node, let time = node.lastRenderTime, time.isSampleTimeValid, let own = node.playerTime(forNodeTime: time) else { return nil }
        return own.sampleTime
    }
    private func play(_ packet: AudioPacket) throws {
        lock.lock(); packets += 1; lock.unlock()
        // Packets before the format (or after a failure) have nothing to be played with.
        guard let decoder, let node, let engine, let sound = try decoder.decode(packet.bytes) else { return }
        if !engine.isRunning { try engine.start(); node.play(); jitter.restart(); scheduledEnd = 0 }
        let now = playerNow()
        let waiting = now.map { Int(max(0, scheduledEnd - $0)) } ?? 0
        let before = (jitter.underruns, jitter.flushes)
        switch jitter.next(waiting: waiting) {
        case .play: break
        case .playAfterSilence(let frames): schedule(silence(frames, format: sound.format))
        case .flushThenPlayAfterSilence(let frames):
            node.stop(); scheduledEnd = 0; node.play()
            schedule(silence(frames, format: sound.format))
        }
        schedule(sound)
        lock.lock(); played += 1; dry += jitter.underruns - before.0; dropped += jitter.flushes - before.1; lock.unlock()
    }
    private func schedule(_ buffer: AVAudioPCMBuffer) {
        guard let node, buffer.frameLength > 0 else { return }
        scheduledEnd = max(scheduledEnd, playerNow() ?? scheduledEnd) + Int64(buffer.frameLength)
        node.scheduleBuffer(buffer, completionHandler: nil)
    }
    private func silence(_ frames: Int, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, frames)))!
        buffer.frameLength = AVAudioFrameCount(max(1, frames))
        for channel in 0..<Int(format.channelCount) { memset(buffer.floatChannelData![channel], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size) }
        return buffer
    }
}
#endif
