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
}
