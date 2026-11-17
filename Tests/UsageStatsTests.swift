import XCTest
@testable import SkyDeskCore

final class UsageStatsTests: XCTestCase {
    func testCPUShareOfOneCore() {
        var meter = CPUMeter()
        meter.sample(wall: 0, cpu: 10)
        XCTAssertNil(meter.recent)
        meter.sample(wall: 1, cpu: 10.25)
        XCTAssertEqual(meter.recent ?? 0, 25, accuracy: 0.001)
        meter.sample(wall: 2, cpu: 11.75)                      // one and a half cores busy
        XCTAssertEqual(meter.recent ?? 0, 150, accuracy: 0.001)
        XCTAssertEqual(meter.average ?? 0, 87.5, accuracy: 0.001)
        XCTAssertGreaterThan(ProcessCPU.seconds(), 0)
    }
    func testDrainNeedsTimeAndMoreThanOnePointAndRestartsAfterCharging() {
        var drain = BatteryDrain()
        drain.sample(percent: 80, charging: false, now: 0)
        drain.sample(percent: 79, charging: false, now: 300)
        XCTAssertEqual(drain.used, 1); XCTAssertNil(drain.perHour)  // 1 point in 5 minutes means little
        drain.sample(percent: 75, charging: false, now: 1_800)
        XCTAssertEqual(drain.used, 5); XCTAssertEqual(drain.perHour ?? 0, 10, accuracy: 0.001)
        drain.sample(percent: 76, charging: true, now: 1_900)
        XCTAssertNil(drain.used)
        drain.sample(percent: 90, charging: false, now: 5_000)
        XCTAssertEqual(drain.used, 0); XCTAssertEqual(drain.startPercent, 90)
    }
    func testLogFields() {
        var drain = BatteryDrain(); var cpu = CPUMeter()
        drain.sample(percent: 80, charging: false, now: 0); drain.sample(percent: 77, charging: false, now: 1_200)
        cpu.sample(wall: 0, cpu: 0); cpu.sample(wall: 1, cpu: 0.2)
        XCTAssertEqual(UsageText.logFields(open: 1_500, session: 1_200, drain: drain, cpu: cpu, thermal: 1, lowPower: false),
                       "open=25.0m sess=20.0m drain=3%/20m rate=9.0%/h cpu=20/20 therm=1")
    }
    func testGPUShareInTheLogLine() {
        var drain = BatteryDrain(); var cpu = CPUMeter(); var gpu = CPUMeter()
        drain.sample(percent: 90, charging: false, now: 0)
        cpu.sample(wall: 0, cpu: 0); cpu.sample(wall: 1, cpu: 0.2)
        gpu.sample(wall: 0, cpu: 0); gpu.sample(wall: 1, cpu: 0.012)   // 12 ms of GPU work in a second
        XCTAssertEqual(UsageText.logFields(open: 60, session: 60, drain: drain, cpu: cpu, gpu: gpu, thermal: 0, lowPower: false),
                       "open=1.0m sess=1.0m drain=0%/0m cpu=20/20 gpu=1.2/1.2 therm=0")
    }
}

final class ScrollPacerTests: XCTestCase {
    func testMovementsArrivingTogetherAreSpreadOverRefreshes() {
        // Steady input, 10 points a refresh: after the first refresh, steps settle at about 10 a refresh.
        var pacer = ScrollPacer()
        var steps: [Double] = []
        for _ in 0..<20 { pacer.add(CGPoint(x: 0, y: 10)); steps.append(pacer.next().y) }
        XCTAssertEqual(steps.last ?? 0, 10, accuracy: 0.01)
        // Wi-Fi delivers two at once, then none: on arrival that was 20, 0, 20, 0. Paced, the steps stay close.
        pacer = ScrollPacer(); steps = []
        for refresh in 0..<40 {
            if refresh % 2 == 0 { pacer.add(CGPoint(x: 0, y: 10)); pacer.add(CGPoint(x: 0, y: 10)) }
            steps.append(pacer.next().y)
        }
        let late = steps.suffix(20)
        XCTAssertLessThan((late.max() ?? 0) - (late.min() ?? 0), 10.1)   // against 20 unpaced
        XCTAssertEqual(late.reduce(0, +) / Double(late.count), 10, accuracy: 0.5)
        // Nothing is lost, and the end lets everything out.
        pacer = ScrollPacer(); pacer.add(CGPoint(x: 3, y: 47))
        _ = pacer.next()
        let last = pacer.next(ending: true)
        XCTAssertTrue(pacer.isEmpty); XCTAssertEqual(last.y, 23.5, accuracy: 0.001)
    }
}
