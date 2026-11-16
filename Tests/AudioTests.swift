import XCTest
import AVFoundation
@testable import SkyDeskCore

final class AudioTests: XCTestCase {
    /// A 440 Hz tone in whatever layout the Mac's audio system might deliver.
    private func tone(format: AVAudioFormat, frames: Int, phase: inout Double) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = Int(format.channelCount)
        for frame in 0..<frames {
            let value = Float(sin(phase) * 0.5); phase += 2 * .pi * 440 / format.sampleRate
            for channel in 0..<channels {
                if format.isInterleaved { buffer.floatChannelData![0][frame * channels + channel] = value }
                else { buffer.floatChannelData![channel][frame] = value }
            }
        }
        return buffer
    }

    private func roundTrip(sampleRate: Double, interleaved: Bool, chunk: Int) throws {
        let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: interleaved)!
        let encoder = try OpusEncoder(input: input)
        XCTAssertTrue(encoder.info.isValid)
        // The iPad only ever sees what crossed the wire.
        let wire = try JSONDecoder().decode(AudioStreamInfo.self, from: JSONEncoder().encode(encoder.info))
        let decoder = try OpusDecoder(info: wire)
        var phase = 0.0, packets = 0, frames = 0, peak: Float = 0, largest = 0
        let chunks = Int(sampleRate) / chunk       // one second of sound
        for _ in 0..<chunks {
            for packet in try encoder.encode(tone(format: input, frames: chunk, phase: &phase)) {
                packets += 1; largest = max(largest, packet.count)
                let sent = AudioPacket(sequence: UInt64(packets), bytes: packet).packet()
                var parser = WireParser()
                let received = try AudioPacket(packet: try XCTUnwrap(try parser.append(sent.encoded()).first))
                XCTAssertEqual(received.sequence, UInt64(packets))
                guard let sound = try decoder.decode(received.bytes) else { continue }
                XCTAssertEqual(sound.format.sampleRate, 48_000); XCTAssertEqual(sound.format.channelCount, 2)
                frames += Int(sound.frameLength)
                for index in 0..<Int(sound.frameLength) { peak = max(peak, abs(sound.floatChannelData![0][index])) }
            }
        }
        // About a second of 10 ms packets, small enough for one wire packet, and still a tone of the same loudness.
        XCTAssertGreaterThan(packets, 90); XCTAssertLessThanOrEqual(packets, 101)
        XCTAssertLessThan(largest, AudioPacket.maximumBytes)
        XCTAssertGreaterThan(frames, 43_000); XCTAssertLessThanOrEqual(frames, 48_480)
        XCTAssertEqual(peak, 0.5, accuracy: 0.12)
    }

    func testSoundSurvivesCompressionAtTheUsualMacFormats() throws {
        try roundTrip(sampleRate: 48_000, interleaved: true, chunk: 512)
        try roundTrip(sampleRate: 48_000, interleaved: false, chunk: 480)
        // 44.1 kHz devices and odd buffer sizes: packets must still come out whole.
        try roundTrip(sampleRate: 44_100, interleaved: true, chunk: 441)
        try roundTrip(sampleRate: 96_000, interleaved: false, chunk: 1_024)
    }

    func testBadPacketsAndFormatsAreRejected() throws {
        XCTAssertThrowsError(try AudioPacket(packet: WirePacket(kind: .audio, payload: Data(count: 8))))
        XCTAssertThrowsError(try AudioPacket(packet: WirePacket(kind: .video, payload: Data(count: 20))))
        XCTAssertThrowsError(try WirePacket(kind: .audio, payload: Data(count: AudioPacket.maximumBytes + 9)).encoded())
        XCTAssertFalse(AudioStreamInfo(codec: "mp3").isValid)
        XCTAssertFalse(AudioStreamInfo(sampleRate: 44_100).isValid)
        XCTAssertFalse(AudioStreamInfo(cookie: Data(count: 300)).isValid)
        XCTAssertThrowsError(try OpusDecoder(info: AudioStreamInfo(channels: 6)))
        let decoder = try OpusDecoder(info: AudioStreamInfo())
        XCTAssertThrowsError(try decoder.decode(Data()))
    }

    func testCushionIsBuiltOnceThenSoundPlaysStraightThrough() {
        var jitter = AudioJitter()
        XCTAssertEqual(jitter.next(waiting: 0), .playAfterSilence(frames: 1_440))      // 30 ms
        for waiting in [1_440, 1_900, 960, 480] { XCTAssertEqual(jitter.next(waiting: waiting), .play) }
        XCTAssertEqual(jitter.underruns, 0)
    }

    func testRunningDryRebuildsASlightlyLargerCushionUpToALimit() {
        var jitter = AudioJitter()
        _ = jitter.next(waiting: 0)
        XCTAssertEqual(jitter.next(waiting: 0), .playAfterSilence(frames: 1_920))      // 40 ms
        XCTAssertEqual(jitter.underruns, 1)
        for _ in 0..<20 { _ = jitter.next(waiting: 0) }
        XCTAssertEqual(jitter.cushion, 4_800)                                           // never more than 100 ms
    }

    func testABurstAfterAStallIsDroppedInsteadOfPlayedLate() {
        var jitter = AudioJitter()
        _ = jitter.next(waiting: 0)
        XCTAssertEqual(jitter.next(waiting: 10_560), .play)                             // exactly 220 ms: still fine
        XCTAssertEqual(jitter.next(waiting: 10_561), .flushThenPlayAfterSilence(frames: 1_440))
        XCTAssertEqual(jitter.flushes, 1)
        jitter.restart()
        XCTAssertEqual(jitter.next(waiting: 5_000), .playAfterSilence(frames: 1_440))
    }

    func testTheCushionCoversWhatTheOutputTakesAtOnce() {
        // 5 ms at a time (what SkyDesk asks for): the plain values.
        var small = AudioJitter(deviceBufferMS: 5)
        XCTAssertEqual(small.cushion, 1_440); XCTAssertEqual(small.largestCushion, 4_800); XCTAssertEqual(small.limit, 10_560)
        // 85 ms at a time (iPadOS has been seen to choose this): 30 ms waiting would run dry on every take.
        let large = AudioJitter(deviceBufferMS: 85)
        XCTAssertEqual(large.cushion, 6_600)                                            // 137.5 ms
        XCTAssertGreaterThan(large.largestCushion, large.cushion)
        XCTAssertGreaterThan(large.limit, large.largestCushion + 48 * 85)               // a full take above the cushion is not "too far behind"
        // The output changes mid-session: a bigger take needs the cushion rebuilt now, a smaller one does not.
        XCTAssertFalse(small.setDeviceBuffer(ms: 5.3))
        XCTAssertTrue(small.setDeviceBuffer(ms: 21.3)); XCTAssertEqual(small.cushion, 2_013)   // 41.95 ms
        XCTAssertFalse(small.setDeviceBuffer(ms: 5)); XCTAssertEqual(small.cushion, 2_013)     // never shrinks mid-session
        XCTAssertEqual(small.limit, 10_560)
    }

    func testSoundHealthLineCountsOneSecondThenStartsAgain() {
        var health = AudioHealth()
        health.output = "Bluetooth A2DP"; health.deviceBufferMS = 21.3; health.outputLatencyMS = 180.4
        for index in 0..<100 { health.arrived(now: UInt64(index) * 10_000_000 + (index == 50 ? 34_000_000 : 0)) }
        health.underrun(); health.underrun(); health.flushed(); health.rebuilt(); health.interrupted()
        health.waitingMS = 42; health.cushionMS = 50
        XCTAssertEqual(health.drain(), "snd=100 gap=44 under=2 flush=1 reb=1 int=1 wait=42 cush=50 io=21 lat=180 out=BluetoothA2DP")
        XCTAssertEqual(health.drain(), "snd=0 gap=0 under=0 flush=0 reb=0 int=0 wait=42 cush=50 io=21 lat=180 out=BluetoothA2DP")
        // The round trip is still found in a line that carries the sound figures after it.
        XCTAssertEqual(StatisticsText.roundTrip(fromLogLine: "shown=60 rtt=4.9/7.0 display=16.2 video=udp " + health.drain()), 4.9)
    }

    func testAVoiceSurvivesAsOneChannelFromTheUsualMicrophoneFormats() throws {
        // The iPad's microphone: one channel, at whatever rate the input in use runs (a headset may give 24 or 16 kHz).
        for (rate, chunk) in [(48_000.0, 240), (44_100.0, 256), (24_000.0, 120), (16_000.0, 160)] {
            let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
            let encoder = try OpusEncoder(input: input, bitrate: 48_000, channels: 1)
            XCTAssertTrue(encoder.info.isValid); XCTAssertEqual(encoder.info.channels, 1)
            let decoder = try OpusDecoder(info: try JSONDecoder().decode(AudioStreamInfo.self, from: JSONEncoder().encode(encoder.info)))
            var phase = 0.0, frames = 0, peak: Float = 0, largest = 0
            for _ in 0..<(Int(rate) / chunk) {
                for packet in try encoder.encode(tone(format: input, frames: chunk, phase: &phase)) {
                    largest = max(largest, packet.count)
                    guard let sound = try decoder.decode(packet) else { continue }
                    XCTAssertEqual(sound.format.channelCount, 1); XCTAssertEqual(sound.format.sampleRate, 48_000)
                    frames += Int(sound.frameLength)
                    for index in 0..<Int(sound.frameLength) { peak = max(peak, abs(sound.floatChannelData![0][index])) }
                }
            }
            XCTAssertGreaterThan(frames, 43_000, "\(rate)"); XCTAssertLessThanOrEqual(frames, 48_480, "\(rate)")
            XCTAssertEqual(peak, 0.5, accuracy: 0.15, "\(rate)")
            XCTAssertLessThan(largest, 400, "a voice packet stays small")
        }
    }

    func testTheMicrophoneGoesToTheChosenOutputOrTheFirstLoopbackDevice() {
        let devices = [SoundOutput(id: 1, uid: "speakers", name: "MacBook Pro Speakers"), SoundOutput(id: 2, uid: "bh2", name: "BlackHole 2ch"),
                       SoundOutput(id: 3, uid: "scarlett", name: "Scarlett 4i4 4th Gen")]
        XCTAssertEqual(SoundOutputs.microphoneTarget(saved: nil, among: devices)?.uid, "bh2")
        XCTAssertEqual(SoundOutputs.microphoneTarget(saved: "scarlett", among: devices)?.uid, "scarlett")
        // The saved device was unplugged or removed: back to a loopback device, never to the speakers.
        XCTAssertEqual(SoundOutputs.microphoneTarget(saved: "gone", among: devices)?.uid, "bh2")
        XCTAssertNil(SoundOutputs.microphoneTarget(saved: nil, among: [devices[0], devices[2]]))
    }

    func testMicrophonePacketsArePlayedIntoALoopbackDevice() throws {
        // Needs a loopback device on this Mac; what is played is silence, so nothing listening to it hears anything.
        guard let device = SoundOutputs.microphoneTarget(saved: nil, among: SoundOutputs.all()) else { throw XCTSkip("No loopback sound device here.") }
        let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let encoder = try OpusEncoder(input: input, bitrate: 48_000, channels: 1)
        let playback = MicPlayback(device: device.id)
        var failure: String?
        playback.onFailure = { failure = $0 }
        // A packet before the format is ignored, not an error.
        let quiet = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 480)!; quiet.frameLength = 480
        memset(quiet.floatChannelData![0], 0, 480 * MemoryLayout<Float>.size)
        var sequence: UInt64 = 0
        func send() throws {
            for bytes in try encoder.encode(quiet) { sequence += 1; playback.handle(AudioPacket(sequence: sequence, bytes: bytes).packet()) }
        }
        try send()
        playback.handle(try WirePacket.control(.audioFormat(encoder.info)))
        for _ in 0..<50 { try send(); usleep(10_000) }
        playback.drain()
        let counts = playback.statistics()
        XCTAssertNil(failure)
        XCTAssertGreaterThanOrEqual(counts.packets, 45); XCTAssertGreaterThanOrEqual(counts.played, 40)
        XCTAssertLessThanOrEqual(counts.dropped, 1)
        // A second format mid-stream (the iPad's microphone changed) starts again cleanly.
        playback.handle(try WirePacket.control(.audioFormat(encoder.info)))
        for _ in 0..<10 { try send(); usleep(10_000) }
        playback.drain(); XCTAssertNil(failure)
        XCTAssertGreaterThanOrEqual(playback.statistics().played, 8)
        // Anything else on this channel ends it.
        playback.handle(try WirePacket.control(.ping(1))); playback.drain()
        XCTAssertNotNil(failure)
        playback.stop(); playback.drain()
    }

    func testTheLoopbackDeviceCanBeListedUnderSkyDesksName() throws {
        guard let loopback = SoundOutputs.microphoneTarget(saved: nil, among: SoundOutputs.all()) else { throw XCTSkip("No loopback sound device here.") }
        // Its own name and identifier, so a running SkyDesk Host's device is left alone.
        let alias = MicrophoneAlias(name: "SkyDesk Microphone (test)", uid: "com.skylar.skydesk.microphone.test")
        defer { alias.remove() }
        let input = SoundOutputs.defaultDevice(input: true), output = SoundOutputs.defaultDevice(input: false)
        XCTAssertTrue(alias.update(target: loopback))
        let made = try XCTUnwrap(alias.device)
        XCTAssertEqual(SoundOutputs.name(made), "SkyDesk Microphone (test)")
        XCTAssertGreaterThan(SoundOutputs.inputChannels(made), 0, "Mac apps must be able to record from it")
        // The Mac keeps using the microphone and speakers it used before.
        XCTAssertEqual(SoundOutputs.defaultDevice(input: true), input); XCTAssertEqual(SoundOutputs.defaultDevice(input: false), output)
        // It is not offered as a place to play the microphone into, and asking again changes nothing.
        XCTAssertFalse(SoundOutputs.all().contains { $0.uid == alias.uid })
        XCTAssertTrue(alias.update(target: loopback)); XCTAssertEqual(alias.device, made)
        // One left behind by an earlier run is replaced, not doubled.
        let later = MicrophoneAlias(name: alias.name, uid: alias.uid)
        XCTAssertTrue(later.update(target: loopback))
        XCTAssertEqual(SoundOutputs.identifiers().filter { $0.uid == alias.uid }.count, 1)
        // A pair of speakers never gets a microphone's name, and the name goes when the microphone is switched off.
        XCTAssertFalse(later.update(target: SoundOutput(id: output, uid: "speakers", name: "MacBook Pro Speakers")))
        XCTAssertNil(later.device)
        XCTAssertTrue(later.update(target: loopback)); XCTAssertFalse(later.update(target: nil)); XCTAssertNil(alias.device)
    }
}
