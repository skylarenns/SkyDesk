import XCTest
@testable import SkyDeskCore

final class StreamMetricsTests: XCTestCase {
    private let ms: UInt64 = 1_000_000
    private let second: UInt64 = 1_000_000_000

    func testAverageUsesOnlyTheLastTwoSecondsAndTailTheLastTen() {
        let stats = StreamStatistics()
        // 20 Hz pings for 10 s: 80 ms for the first 8 s, 10 ms for the final 2 s.
        for index in 1...200 {
            let now = second + UInt64(index) * 50 * ms
            XCTAssertTrue(stats.recordPong(sentAt: now - (index <= 160 ? 80 : 10) * ms, now: now))
        }
        let value = stats.snapshot(now: 11 * second)
        XCTAssertEqual(value.rttAverageMS!, 10, accuracy: 0.001, "Samples older than 2 s must not move the average.")
        XCTAssertEqual(value.rttHigh1MS!, 80, accuracy: 0.001, "The tail still covers the last 10 s.")
        // 13 s later every sample has aged out: no stale numbers.
        let later = stats.snapshot(now: 23 * second)
        XCTAssertNil(later.rttAverageMS); XCTAssertNil(later.rttHigh1MS)
    }

    func testOnePercentHighIsTheNearestRank99thPercentileNotTheMaximum() {
        let stats = StreamStatistics()
        // 200 samples: 197 at 10 ms, then 30, 40 and one 500 ms outlier.
        let values: [UInt64] = Array(repeating: 10, count: 197) + [30, 40, 500]
        for (index, value) in values.shuffledDeterministically().enumerated() {
            let now = second + UInt64(index + 1) * 50 * ms
            _ = stats.recordPong(sentAt: now - value * ms, now: now)
        }
        // Nearest rank: ceil(0.99 × 200) = 198th smallest = 30 ms.
        XCTAssertEqual(stats.snapshot(now: 11 * second).rttHigh1MS!, 30, accuracy: 0.001)
    }

    func testTailStatisticsStayBlankUntilOneHundredSamples() {
        let stats = StreamStatistics()
        // The former 1 Hz ping yields 10 samples per window: an average exists, a 1% tail does not.
        for index in 1...10 { _ = stats.recordPong(sentAt: UInt64(index) * second - 15 * ms, now: UInt64(index) * second) }
        var value = stats.snapshot(now: 10 * second)
        XCTAssertEqual(value.rttAverageMS!, 15, accuracy: 0.001)
        XCTAssertNil(value.rttHigh1MS)
        for index in 0..<99 { stats.recordPresented(at: UInt64(index) * 10 * ms + 5 * ms, receivedAt: UInt64(index) * 10 * ms, afterIdle: false) }
        value = stats.snapshot(now: second)
        XCTAssertNil(value.displayHigh1MS, "99 samples are not enough.")
        XCTAssertNil(value.fpsLow1, "98 intervals are not enough.")
        XCTAssertEqual(value.displayAverageMS!, 5, accuracy: 0.001)
        XCTAssertFalse(stats.recordPong(sentAt: 2, now: 1), "A pong from the future is rejected.")
    }

    func testFPSLowReportsStutterButIgnoresDeclaredIdlePauses() {
        let frame: UInt64 = 8_333_333
        func run(hitchMS: UInt64) -> StreamStatistics.Snapshot {
            let stats = StreamStatistics()
            var time: UInt64 = second
            for index in 0..<600 {
                // Ten hitches (more than 1% of the gaps) plus one 3 s pause declared idle by the Mac.
                let pause = index == 350
                let hitch = index > 0 && index % 50 == 0
                time += pause ? 3 * second : hitch ? hitchMS * ms : frame
                stats.recordPresented(at: time, receivedAt: time - 4 * ms, afterIdle: pause)
            }
            return stats.snapshot(now: time)
        }
        // The 3 s idle pause is excluded; the 50 ms hitches set the 1% low (20 FPS), not 0.33 FPS.
        XCTAssertEqual(run(hitchMS: 50).fpsLow1!, 20, accuracy: 0.01)
        // Without hitches the pause leaves the 1% low at the full rate.
        XCTAssertEqual(run(hitchMS: 8).fpsLow1!, 120, accuracy: 5)
        XCTAssertEqual(run(hitchMS: 8).fps, 120, accuracy: 2)
    }

    func testUnmarkedStallsCountAgainstTheOnePercentLow() {
        let stats = StreamStatistics()
        var time: UInt64 = second
        // 200 smooth 120 Hz frames with three 250 ms delivery stalls: three slow gaps exceed 1% of 199.
        for index in 0..<200 {
            time += [50, 100, 150].contains(index) ? 250 * ms : 8_333_333
            stats.recordPresented(at: time, receivedAt: time - 4 * ms, afterIdle: false)
        }
        XCTAssertEqual(stats.snapshot(now: time).fpsLow1!, 4, accuracy: 0.01)
    }

    func testSteadyStreamReportsItsRateBitrateAndDisplayDelay() {
        let stats = StreamStatistics()
        for index in 1...240 {
            let now = second + UInt64(index) * 8_333_333
            stats.recordReceived(bytes: 26_042, decodeMS: 3, now: now)
            stats.recordPresented(at: now + 9 * ms, receivedAt: now, afterIdle: false)
        }
        let value = stats.snapshot(now: second + 240 * 8_333_333 + 9 * ms)
        XCTAssertEqual(value.fps, 120, accuracy: 1)
        XCTAssertEqual(value.fpsLow1!, 120, accuracy: 0.5)
        XCTAssertEqual(value.megabitsPerSecond, 25, accuracy: 0.5)
        XCTAssertEqual(value.displayAverageMS!, 9, accuracy: 0.001)
        XCTAssertEqual(value.displayHigh1MS!, 9, accuracy: 0.001)
        XCTAssertEqual(value.decodeAverageMS!, 3, accuracy: 0.001)
        var shown = StreamStatistics.Snapshot(); shown.fps = 118.6; shown.fpsLow1 = 96.4; shown.megabitsPerSecond = 24.96
        XCTAssertEqual(StatisticsText.headline(shown), "119 FPS · 1% low 96 · 25.0 Mbps")
        XCTAssertEqual(StatisticsText.headline(StreamStatistics.Snapshot()), "0 FPS · 1% low — · 0.0 Mbps")
        XCTAssertEqual(StatisticsText.network(StreamStatistics.Snapshot()), "Network RTT  avg — · 1% high —")
        XCTAssertEqual(StatisticsText.display(value), "Local display  avg 9.0 ms · 1% high 9.0 ms")
    }

    func testOutOfOrderPresentationCannotCreateNegativeIntervals() {
        let stats = StreamStatistics()
        for index in 1...150 { stats.recordPresented(at: UInt64(index) * 10 * ms, receivedAt: 0, afterIdle: false) }
        stats.recordPresented(at: 5 * ms, receivedAt: 0, afterIdle: false)
        XCTAssertEqual(stats.snapshot(now: 1_500 * ms).fpsLow1!, 100, accuracy: 0.01)
    }

    func testIdleFlagAndFeaturesSurviveTheWireAndOlderPeersStillDecode() throws {
        let frame = VideoFrame(sequence: 9, captureTime: 1, encodeTime: 2, keyframe: false, afterIdle: true,
                               parameterSets: [], bytes: Data([1, 2, 3]))
        let decoded = try VideoFrame(data: try frame.encoded())
        XCTAssertTrue(decoded.afterIdle); XCTAssertFalse(decoded.keyframe)
        let plain = try VideoFrame(data: try VideoFrame(sequence: 9, captureTime: 1, encodeTime: 2, keyframe: false,
                                                        parameterSets: [], bytes: Data([1])).encoded())
        XCTAssertFalse(plain.afterIdle)
        var bad = try frame.encoded(); bad[24] = 4
        XCTAssertThrowsError(try VideoFrame(data: bad))

        let hello = Hello(session: UUID(), role: .control, features: StreamFeature.idleGapFlags)
        guard case .hello(let back) = try WirePacket.control(.hello(hello)).controlMessage() else { return XCTFail("Lost hello") }
        XCTAssertEqual(back.features, StreamFeature.idleGapFlags)
        // A build-4 client sends no "features" key; a build-4 host sends none in its welcome.
        let oldHello = try JSONDecoder().decode(Hello.self, from: Data(#"{"session":"\#(UUID().uuidString)","role":"control"}"#.utf8))
        XCTAssertNil(oldHello.features)
        let oldInfo = try JSONDecoder().decode(StreamInfo.self, from: Data(
            #"{"width":2752,"height":2064,"fps":120,"bitrate":25000000,"displayName":"d","inputEnabled":true}"#.utf8))
        XCTAssertNil(oldInfo.features)
    }

    func testFastPathServesOnlyTheBoundControlChannel() {
        let fast = ControlFastPath(), window = FrameWindow.streaming(fps: 120)
        let control = UUID(), other = UUID()
        var replies: [ControlMessage] = []
        let sequence = window.reserve(now: 0)!
        // Before the handshake binds a control channel nothing is short-circuited.
        XCTAssertEqual(fast.handle(.frameAck(sequence), channel: control) { replies.append($0) }, .pass)
        fast.bind(control: control); fast.bind(window: window)
        XCTAssertEqual(fast.handle(.frameAck(sequence), channel: other) { replies.append($0) }, .pass)
        XCTAssertEqual(fast.handle(.ping(7), channel: other) { replies.append($0) }, .pass)
        XCTAssertNotNil(window.oldestAge(now: 1))
        XCTAssertEqual(fast.handle(.frameAck(sequence), channel: control) { replies.append($0) }, .handled)
        XCTAssertNil(window.oldestAge(now: 1), "The acknowledgement must free the in-flight slot.")
        XCTAssertEqual(fast.handle(.ping(7), channel: control) { replies.append($0) }, .pongSent)
        guard replies.count == 1, case .pong(7) = replies[0] else { return XCTFail("Expected exactly one pong") }
        XCTAssertEqual(fast.handle(.releaseInput, channel: control) { replies.append($0) }, .pass)
        fast.bind(control: nil)
        XCTAssertEqual(fast.handle(.ping(8), channel: control) { replies.append($0) }, .pass)
    }
}

private extension Array {
    /// Fixed permutation so the percentile test does not depend on insertion order or on randomness.
    func shuffledDeterministically() -> [Element] {
        var result = self, state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in stride(from: result.count - 1, to: 0, by: -1) {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            result.swapAt(index, Int((state >> 33) % UInt64(index + 1)))
        }
        return result
    }
}

final class TotalLatencyTests: XCTestCase {
    func testTotalAddsMacTimeRoundTripAndLocalDisplay() {
        let ms: UInt64 = 1_000_000
        let stats = StreamStatistics()
        let start: UInt64 = 1_000 * ms
        // RTT 8 ms, Mac capture→encode 12 ms, local display 16 ms → total 36 ms.
        for index in 0..<120 {
            let t = start + UInt64(index) * 10 * ms
            _ = stats.recordPong(sentAt: t - 8 * ms, now: t)
            stats.recordPresented(at: t + 16 * ms, receivedAt: t, afterIdle: false, macMS: 12)
        }
        let value = stats.snapshot(now: start + 1_200 * ms)
        XCTAssertEqual(value.totalAverageMS ?? 0, 36, accuracy: 0.01)
        XCTAssertEqual(value.totalHigh1MS ?? 0, 36, accuracy: 0.01)
        XCTAssertEqual(StatisticsText.total(value), "Total  avg 36.0 ms · 1% high 36.0 ms")
        XCTAssertTrue(StatisticsText.pipeline(value).hasSuffix("Local display avg 16.0 ms"))
        // No RTT yet or no Mac timing: no total sample rather than a misleading one.
        let fresh = StreamStatistics()
        fresh.recordPresented(at: 20 * ms, receivedAt: 4 * ms, afterIdle: false, macMS: 12)
        XCTAssertNil(fresh.snapshot(now: 21 * ms).totalAverageMS)
    }
}
