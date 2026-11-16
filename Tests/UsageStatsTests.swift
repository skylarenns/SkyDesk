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
}
