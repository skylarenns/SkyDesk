import XCTest
@testable import SkyDeskCore

final class BitrateControllerTests: XCTestCase {
    /// Half a second of a healthy link carrying `mbps`.
    private func clean(_ mbps: Double = 16) -> BitrateController.Sample {
        .init(seconds: 0.5, transitMS: 12, acknowledged: 50, backlogBytes: 0, deliveredBytes: Int(mbps * 1_000_000 / 16))
    }
    private func late(_ mbps: Double, ms: Double = 90) -> BitrateController.Sample {
        .init(seconds: 0.5, transitMS: ms, acknowledged: 40, backlogBytes: 0, deliveredBytes: Int(mbps * 1_000_000 / 16))
    }

    func testAHealthyLinkStaysAtTheUsersSetting() {
        var controller = BitrateController(maximum: 25_000_000)
        for _ in 0..<200 { XCTAssertNil(controller.update(clean())) }
        XCTAssertEqual(controller.target, 25_000_000)
    }

    /// Feeds `sample` until the controller acts or `limit` samples have gone by.
    private func untilChange(_ controller: inout BitrateController, _ sample: BitrateController.Sample, limit: Int = 10) -> Int? {
        for _ in 0..<limit { if let value = controller.update(sample) { return value } }
        return nil
    }

    func testLateFramesCutTowardsWhatTheNetworkCarried() {
        var controller = BitrateController(maximum: 25_000_000)
        _ = controller.update(clean())
        // Frames must stay late for a second and a half before anything is cut.
        XCTAssertNil(controller.update(late(20)))
        XCTAssertNil(controller.update(late(20)))
        // The network carried 20 Mbps while frames queued: aim 15 % under that.
        XCTAssertEqual(controller.update(late(20)), 17_000_000)
        XCTAssertTrue(controller.reason.contains("90 ms"))
        // The cut needs a second to show: no second cut straight away.
        XCTAssertNil(controller.update(late(17)))
        XCTAssertNotNil(controller.update(late(17)))
    }

    func testASlowNetworkPathIsNotCongestion() {
        // 2026-11-13, 20:17–20:19: the iPad's Wi-Fi answered everything 60–140 ms late. Frames took that long too,
        // but none of it was video queueing, so the bitrate must stay where the user set it.
        var controller = BitrateController(maximum: 25_000_000)
        _ = controller.update(clean())
        let observed: [(transit: Double, roundTrip: Double)] = [(75, 68), (64, 58), (58, 57), (80, 82), (169, 119), (114, 75), (63, 60), (117, 97), (158, 106), (104, 85)]
        for _ in 0..<12 {
            for moment in observed {
                XCTAssertNil(controller.update(.init(seconds: 0.5, transitMS: moment.transit, acknowledged: 12, backlogBytes: 0,
                                                     deliveredBytes: 20_000, roundTripMS: moment.roundTrip)))
            }
        }
        XCTAssertEqual(controller.target, 25_000_000)
        // The same frame times with a fast path underneath are queueing, and do get cut.
        let queued = BitrateController.Sample(seconds: 0.5, transitMS: 120, acknowledged: 12, backlogBytes: 0, deliveredBytes: 400_000, roundTripMS: 6)
        XCTAssertNotNil(untilChange(&controller, queued))
    }

    func testAPathThatJustBecameSlowIsGivenTimeToShowInTheRoundTrip() {
        var controller = BitrateController(maximum: 25_000_000)
        _ = controller.update(clean())
        // The round-trip figure lags by a second or so: frames are already 90 ms late while it still says 6 ms.
        let lagging = BitrateController.Sample(seconds: 0.5, transitMS: 90, acknowledged: 12, backlogBytes: 0, deliveredBytes: 20_000, roundTripMS: 6)
        XCTAssertNil(controller.update(lagging)); XCTAssertNil(controller.update(lagging))
        let caughtUp = BitrateController.Sample(seconds: 0.5, transitMS: 90, acknowledged: 12, backlogBytes: 0, deliveredBytes: 20_000, roundTripMS: 80)
        for _ in 0..<20 { XCTAssertNil(controller.update(caughtUp)) }
        XCTAssertEqual(controller.target, 25_000_000)
    }

    func testOneStepCutsBetweenAQuarterAndAHalf() {
        var controller = BitrateController(maximum: 24_000_000)
        _ = controller.update(clean())
        // The network carried nearly everything: still a quarter off.
        XCTAssertEqual(untilChange(&controller, late(24)), 18_000_000)
        var stalled = BitrateController(maximum: 24_000_000)
        _ = stalled.update(clean())
        // A stall (almost nothing delivered) halves the rate; it does not drop to the floor.
        XCTAssertEqual(untilChange(&stalled, late(0.2, ms: 400)), 12_000_000)
    }

    func testOneLargeFrameInTheSendQueueIsNotCongestion() {
        var controller = BitrateController(maximum: 25_000_000)
        _ = controller.update(clean())
        var sample = clean(); sample.backlogBytes = 1_200_000        // 0.38 s at 25 Mbps
        XCTAssertNil(controller.update(sample))
        XCTAssertNil(controller.update(clean()))
        XCTAssertEqual(controller.target, 25_000_000)
        // The same backlog twice in a row is real.
        XCTAssertNil(controller.update(sample))
        XCTAssertNotNil(controller.update(sample))
        XCTAssertTrue(controller.reason.contains("waiting to be sent"))
    }

    func testAHiccupRecoversQuicklyToTheSettingAndNeverPastIt() {
        var controller = BitrateController(maximum: 25_000_000)
        _ = controller.update(clean())
        XCTAssertEqual(untilChange(&controller, late(1, ms: 200)), 12_500_000)
        var steps = 0
        while controller.target < 25_000_000, steps < 400 { _ = controller.update(clean()); steps += 1 }
        XCTAssertEqual(controller.target, 25_000_000)
        // 2 s hold, 15 %/s to 90 % of the old rate, 3 %/s for the rest: about 10 s (20 half-second steps).
        XCTAssertGreaterThan(steps, 10); XCTAssertLessThan(steps, 40)
        for _ in 0..<20 { XCTAssertNil(controller.update(clean())) }
    }

    func testASlowUplinkSettlesJustUnderItsSpeed() {
        // A 6 Mbps link: anything sent faster arrives late, and only 6 Mbps is ever delivered.
        var controller = BitrateController(maximum: 25_000_000)
        _ = controller.update(clean(6))
        var targets: [Int] = []
        for _ in 0..<240 {
            let over = controller.target > 6_000_000
            _ = controller.update(over ? late(6) : clean(min(6, Double(controller.target) / 1e6)))
            targets.append(controller.target)
        }
        let settled = targets.suffix(120)
        XCTAssertLessThanOrEqual(settled.max()!, 6_200_000)
        XCTAssertGreaterThanOrEqual(settled.min()!, 4_000_000)
    }

    func testNeverGoesBelowTheFloorAndIgnoresTheKeyframeBurst() {
        var controller = BitrateController(maximum: 25_000_000)
        controller.startGrace(1.5)
        let burst = BitrateController.Sample(seconds: 0.5, transitMS: 300, acknowledged: 10, backlogBytes: 9_000_000, deliveredBytes: 2_000_000)
        for _ in 0..<3 { XCTAssertNil(controller.update(burst)) }
        XCTAssertEqual(controller.target, 25_000_000)
        _ = controller.update(clean())
        let stuck = BitrateController.Sample(seconds: 1.5, transitMS: 400, acknowledged: 10, backlogBytes: 50_000_000, deliveredBytes: 0)
        for _ in 0..<40 { _ = controller.update(stuck) }
        XCTAssertEqual(controller.target, BitrateController.floor)
        XCTAssertEqual(BitrateController(maximum: 1_000_000).target, 1_000_000)
        XCTAssertEqual(BitrateController(maximum: 1_000_000).minimum, 1_000_000)
    }

    func testFrameWindowReportsNetworkTimeWithoutEncoderTime() {
        let window = FrameWindow.streaming(fps: 120)
        let first = window.reserve(now: 1_000_000_000)!
        window.markSent(first, bytes: 30_000, now: 1_010_000_000)   // 10 ms encoding
        window.acknowledge(first, now: 1_030_000_000)               // 20 ms network + decode
        let second = window.reserve(now: 1_040_000_000)!
        window.markSent(second, bytes: 10_000, now: 1_044_000_000)
        window.acknowledge(second, now: 1_054_000_000)              // 10 ms
        let transit = window.drainTransit()
        XCTAssertEqual(transit.count, 2)
        XCTAssertEqual(transit.bytes, 40_000)
        XCTAssertEqual(transit.meanMS, 15, accuracy: 0.001)
        XCTAssertEqual(window.drainTransit().count, 0)
    }
}
