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
    /// Where the scheduled sound ends, in frames on the player's own clock. Only touched on `queue`.
    private var scheduledEnd: Int64 = 0
    private let counters = NSLock()
    private var suspended = false
    private var reportedPlaying = false
    private var sampleRate = 48_000
    private let healthLock = NSLock()
    private var health = AudioHealth()
    private var sinceDeviceCheck = 0
    private var observers: [NSObjectProtocol] = []
    /// Called on the player's queue: true once sound is really being played, false when it stops.
    var onPlaying: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?

    func configure(_ info: AudioStreamInfo) {
        queue.async { [self] in
            do {
                decoder = try OpusDecoder(info: info)
                sampleRate = info.sampleRate
                try startEngine()
                observe()
            } catch { teardown(); onFailure?("The Mac's sound can't be played: \(error.localizedDescription)") }
        }
    }
    func receive(_ packet: AudioPacket) {
        // Timed here, on the network's queue, so a busy player cannot hide a late packet.
        let arrival = monotonicNanos()
        note { $0.arrived(now: arrival) }
        queue.async { [self] in
            guard !suspended, let decoder, let node, let engine else { return }
            do {
                guard let sound = try decoder.decode(packet.bytes) else { return }
                if !engine.isRunning { try engine.start(); node.play(); jitter.restart() }
                sinceDeviceCheck += 1
                if sinceDeviceCheck >= 100 { sinceDeviceCheck = 0; readDevice() }
                let waiting = waiting(), before = (jitter.underruns, jitter.flushes)
                switch jitter.next(waiting: waiting) {
                case .play: break
                case .playAfterSilence(let frames): schedule(silence(frames, format: sound.format))
                case .flushThenPlayAfterSilence(let frames):
                    flush()
                    schedule(silence(frames, format: sound.format))
                }
                schedule(sound)
                let underran = jitter.underruns > before.0, flushed = jitter.flushes > before.1
                let rate = max(1, sampleRate), cushion = jitter.cushion
                note {
                    if underran { $0.underrun() }
                    if flushed { $0.flushed() }
                    $0.waitingMS = waiting * 1_000 / rate; $0.cushionMS = cushion * 1_000 / rate
                }
                report(true)
            } catch { teardown(); onFailure?("The Mac's sound stopped: \(error.localizedDescription)") }
        }
    }
    /// One piece of the once-a-second log line, from any thread.
    func statisticsText() -> String { healthLock.lock(); defer { healthLock.unlock() }; return health.drain() }
    private func note(_ change: (inout AudioHealth) -> Void) { healthLock.lock(); change(&health); healthLock.unlock() }
    /// How much the output takes at once is iPadOS's decision and can change with the output in use; the
    /// cushion follows it. Read at the start and about once a second.
    private func readDevice() {
        let session = AVAudioSession.sharedInstance()
        let buffer = session.ioBufferDuration * 1_000, latency = session.outputLatency * 1_000
        let output = session.currentRoute.outputs.first?.portType.rawValue ?? "-"
        if jitter.setDeviceBuffer(ms: buffer) { jitter.restart() }
        note { $0.deviceBufferMS = buffer; $0.outputLatencyMS = latency; $0.output = output }
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
        jitter = AudioJitter(sampleRate: sampleRate, deviceBufferMS: session.ioBufferDuration * 1_000)
        resetCounters(); sinceDeviceCheck = 0; readDevice()
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
                self.note { $0.interrupted() }
                if ended { self.rebuild() } else { self.report(false) }
            }
        })
    }
    private func rebuild() {
        note { $0.rebuilt() }
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
    /// Frames the player has put out since it last started, whether or not it had sound to play.
    private func playerNow() -> Int64? {
        guard let node, let time = node.lastRenderTime, time.isSampleTimeValid, let own = node.playerTime(forNodeTime: time) else { return nil }
        return own.sampleTime
    }
    /// Sound in hand: scheduled and not yet taken by the output. Read from the player's own clock, which runs on
    /// when the player has nothing to play, so running dry shows as zero at once (checked on a Mac: a stall of
    /// 80 ms was seen on the first packet after it). Until build 46 this counted sound as in hand until it had
    /// been heard, which adds the whole way to the speaker (a fifth of a second over Bluetooth): running dry
    /// went unnoticed, so the cushion was never rebuilt, and sound that was only on its way looked like a backlog.
    private func waiting() -> Int {
        if let now = playerNow() { return Int(max(0, scheduledEnd - now)) }
        counters.lock(); defer { counters.unlock() }; return max(0, scheduled - played)
    }
    private func resetCounters() { counters.lock(); generation += 1; scheduled = 0; played = 0; counters.unlock(); scheduledEnd = 0 }
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
        scheduledEnd = max(scheduledEnd, playerNow() ?? scheduledEnd) + Int64(frames)
        // The callback count is only the fallback for the moments the player's clock cannot be read.
        node.scheduleBuffer(buffer, completionCallbackType: .dataRendered) { [weak self] _ in
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
