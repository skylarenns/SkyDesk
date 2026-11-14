import AVFoundation

/// Plays the Mac's sound on the iPad: decodes each packet and hands it to an audio engine, keeping a small cushion
/// (AudioJitter) so uneven Wi-Fi arrival stays smooth without the sound falling behind the picture.
/// Everything runs on its own queue.
final class AudioPlayer {
    private let queue = DispatchQueue(label: "skydesk.audio.play", qos: .userInteractive)
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var decoder: OpusDecoder?
    private var jitter = AudioJitter()
    private var generation = 0
    private var scheduled = 0
    private var played = 0
    private let counters = NSLock()
    private var suspended = false
    private var reportedPlaying = false
    private var observers: [NSObjectProtocol] = []
    /// Called on the player's queue: true once sound is really being played, false when it stops.
    var onPlaying: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?

    func configure(_ info: AudioStreamInfo) {
        queue.async { [self] in
            do {
                decoder = try OpusDecoder(info: info)
                jitter = AudioJitter(sampleRate: info.sampleRate)
                try startEngine()
                observe()
            } catch { teardown(); onFailure?("The Mac's sound can't be played: \(error.localizedDescription)") }
        }
    }
    func receive(_ packet: AudioPacket) {
        queue.async { [self] in
            guard !suspended, let decoder, let node, let engine else { return }
            do {
                guard let sound = try decoder.decode(packet.bytes) else { return }
                if !engine.isRunning { try engine.start(); node.play(); jitter.restart() }
                switch jitter.next(waiting: waiting()) {
                case .play: break
                case .playAfterSilence(let frames): schedule(silence(frames, format: sound.format))
                case .flushThenPlayAfterSilence(let frames):
                    flush()
                    schedule(silence(frames, format: sound.format))
                }
                schedule(sound)
                report(true)
            } catch { teardown(); onFailure?("The Mac's sound stopped: \(error.localizedDescription)") }
        }
    }
    /// The app left the screen: iPadOS will not let it keep playing, so say so and let the Mac take its sound back.
    func setSuspended(_ value: Bool) {
        queue.async { [self] in
            guard suspended != value else { return }
            suspended = value
            if value { node?.stop(); resetCounters(); engine?.pause(); report(false) }
            else { jitter.restart() }
        }
    }
    func stop() { queue.async { [self] in teardown() } }

    private func startEngine() throws {
        guard let decoder else { return }
        let session = AVAudioSession.sharedInstance()
        // Mixes with whatever the iPad itself is playing instead of stopping it.
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)
        let engine = AVAudioEngine(), node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: decoder.format)
        try engine.start()
        node.play()
        self.engine = engine; self.node = node
        resetCounters(); jitter.restart()
    }
    private func observe() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // Headphones plugged in or removed, or the output otherwise changed: the engine stops and must be rebuilt.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] note in
            self?.queue.async { [weak self] in
                guard let self, let engine = self.engine, (note.object as? AVAudioEngine) === engine, !self.suspended else { return }
                self.rebuild()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            let ended = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.ended.rawValue
            self?.queue.async { [weak self] in
                guard let self, self.decoder != nil, !self.suspended else { return }
                if ended { self.rebuild() } else { self.report(false) }
            }
        })
    }
    private func rebuild() {
        node?.stop(); engine?.stop(); engine = nil; node = nil
        do { try startEngine() } catch { report(false) }
    }
    private func teardown() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        node?.stop(); engine?.stop()
        engine = nil; node = nil; decoder = nil
        report(false)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
    private func report(_ playing: Bool) {
        guard reportedPlaying != playing else { return }
        reportedPlaying = playing
        onPlaying?(playing)
    }
    private func waiting() -> Int { counters.lock(); defer { counters.unlock() }; return max(0, scheduled - played) }
    private func resetCounters() { counters.lock(); generation += 1; scheduled = 0; played = 0; counters.unlock() }
    private func flush() {
        guard let node else { return }
        node.stop(); resetCounters()
        // Starting a player on a stopped engine raises an exception; `receive` restarts both when sound returns.
        if engine?.isRunning == true { node.play() }
    }
    private func schedule(_ buffer: AVAudioPCMBuffer) {
        guard let node, buffer.frameLength > 0 else { return }
        let frames = Int(buffer.frameLength)
        counters.lock(); scheduled += frames; let current = generation; counters.unlock()
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.counters.lock()
            if self.generation == current { self.played += frames }
            self.counters.unlock()
        }
    }
    private func silence(_ frames: Int, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, frames)))!
        buffer.frameLength = AVAudioFrameCount(max(1, frames))
        for channel in 0..<Int(format.channelCount) { memset(buffer.floatChannelData![channel], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size) }
        return buffer
    }
}
