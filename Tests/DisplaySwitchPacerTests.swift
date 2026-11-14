import XCTest
@testable import SkyDeskCore

final class DisplaySwitchPacerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testPanelStaysOffAndOnForMinimumTimes() {
        var pacer = DisplaySwitchPacer()
        XCTAssertEqual(pacer.waitBeforeOn(now: t0), 0); XCTAssertEqual(pacer.waitBeforeOff(now: t0), 0)
        // The incident: powered on 2.4 s after being powered off.
        pacer.lastOff = t0
        XCTAssertEqual(pacer.waitBeforeOn(now: t0.addingTimeInterval(2.4)), 2.6, accuracy: 0.001)
        XCTAssertEqual(pacer.waitBeforeOn(now: t0.addingTimeInterval(5)), 0)
        XCTAssertEqual(pacer.waitBeforeOn(now: t0.addingTimeInterval(600)), 0)
        // And switched off again 3 s after being switched on.
        pacer.lastOn = t0.addingTimeInterval(5)
        XCTAssertEqual(pacer.waitBeforeOff(now: t0.addingTimeInterval(8)), 17, accuracy: 0.001)
        XCTAssertEqual(pacer.waitBeforeOff(now: t0.addingTimeInterval(25)), 0)
    }
    func testWaitsAreBoundedAndIgnoreClockChanges() {
        let pacer = DisplaySwitchPacer(lastOff: t0.addingTimeInterval(3600), lastOn: t0.addingTimeInterval(3600))
        XCTAssertEqual(pacer.waitBeforeOn(now: t0), 0, "A timestamp from the future must not block restoring the Mac display")
        XCTAssertEqual(pacer.waitBeforeOff(now: t0), 0)
        // The restore path blocks a thread for this long; the recovery helper acts on a 6 s heartbeat stall.
        XCTAssertLessThan(DisplaySwitchPacer.minimumOffSeconds, 6)
        XCTAssertLessThanOrEqual(DisplaySwitchPacer(lastOff: t0).waitBeforeOn(now: t0), DisplaySwitchPacer.minimumOffSeconds)
    }
    #if os(macOS)
    func testClockSurvivesAcrossProcesses() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("skydesk-pacer-\(UUID().uuidString)/switch.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(DisplaySwitchClock.load(from: url), DisplaySwitchPacer())
        DisplaySwitchClock.noteOff(at: t0, url: url)
        DisplaySwitchClock.noteOn(at: t0.addingTimeInterval(7), url: url)
        let loaded = DisplaySwitchClock.load(from: url)
        XCTAssertEqual(loaded.lastOff, t0); XCTAssertEqual(loaded.lastOn, t0.addingTimeInterval(7))
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(DisplaySwitchClock.load(from: url), DisplaySwitchPacer(), "A damaged file must never block the display")
    }
    #endif
    func testAutomaticPadOnlyFollowsTheSettingOnEveryConnection() {
        XCTAssertTrue(AutoPadOnly.shouldStart(setting: true, supported: true))
        XCTAssertFalse(AutoPadOnly.shouldStart(setting: false, supported: true))
        XCTAssertFalse(AutoPadOnly.shouldStart(setting: true, supported: false))
    }
}
