import XCTest
@testable import SkyDeskCore

final class ArrivalPacerTests: XCTestCase {
    private let frame = 1.0 / 120

    func testAFrameArrivingEarlyInTheIntervalIsDrawnAtOnce() {
        var pacer = ArrivalPacer()
        pacer.tick(target: 10 + frame, interval: frame)          // tick at t = 10, next refresh 8.3 ms later
        XCTAssertTrue(pacer.mayDrawOnArrival(now: 10.001))        // 7.3 ms left
        pacer.drew()
        // Only one frame per refresh: a second arrival waits for the tick.
        XCTAssertFalse(pacer.mayDrawOnArrival(now: 10.002))
        pacer.tick(target: 10 + 2 * frame, interval: frame)
        XCTAssertTrue(pacer.mayDrawOnArrival(now: 10 + frame + 0.001))
    }

    func testTooCloseToTheRefreshWaitsForTheTick() {
        var pacer = ArrivalPacer()
        pacer.tick(target: 10 + frame, interval: frame)
        XCTAssertFalse(pacer.mayDrawOnArrival(now: 10 + frame - 0.003))   // 3 ms left, margin is 4
        // A frame drawn at the tick itself also closes the interval.
        pacer.tick(target: 10 + 2 * frame, interval: frame)
        pacer.drew()
        XCTAssertFalse(pacer.mayDrawOnArrival(now: 10 + frame + 0.0005))
    }

    func testNoTickYetOrAStaleOneMeansNoEarlyDraw() {
        var pacer = ArrivalPacer()
        XCTAssertFalse(pacer.mayDrawOnArrival(now: 5))
        pacer.tick(target: 10 + frame, interval: frame)
        XCTAssertFalse(pacer.mayDrawOnArrival(now: 11))           // the tick is long past
        XCTAssertFalse(pacer.mayDrawOnArrival(now: 9.9))          // the clock is nowhere near this refresh
    }

    func testMissesWidenTheMarginAndLongRunsOfHitsNarrowIt() {
        var pacer = ArrivalPacer()
        XCTAssertEqual(pacer.margin, 0.004, accuracy: 1e-9)
        pacer.tick(target: 10 + frame, interval: frame)
        // Shown one refresh late: a miss.
        pacer.arrivalResult(expected: 10 + frame, presented: 10 + 2 * frame)
        XCTAssertEqual(pacer.margin, 0.0045, accuracy: 1e-9)
        for _ in 0..<20 { pacer.arrivalResult(expected: 10, presented: 10 + frame) }
        XCTAssertEqual(pacer.margin, ArrivalPacer.largestMargin, accuracy: 1e-9)
        // On time (a millisecond of slack is normal).
        for _ in 0..<200 { pacer.arrivalResult(expected: 10, presented: 10.001) }
        XCTAssertEqual(pacer.margin, ArrivalPacer.largestMargin - 0.00025, accuracy: 1e-9)
        for _ in 0..<10_000 { pacer.arrivalResult(expected: 10, presented: 10) }
        XCTAssertEqual(pacer.margin, ArrivalPacer.smallestMargin, accuracy: 1e-9)
        XCTAssertEqual(pacer.misses, 21)
    }
}
