import XCTest
@testable import SkyDeskCore

final class KeptDesktopTests: XCTestCase {
    private let pad = KeptDesktop.Shape(width: 2752, height: 2064, fps: 120)

    func testKeptOnlyWhenTheIPadLeftWhileIPadOnlyWasOn() {
        XCTAssertTrue(KeptDesktop.shouldKeep(setting: true, padOnly: true, end: .padLeft, macUpdateWaiting: false))
        // The setting is off by default: nothing changes for anyone who did not ask for this.
        XCTAssertFalse(KeptDesktop.shouldKeep(setting: false, padOnly: true, end: .padLeft, macUpdateWaiting: false))
        // The Mac's displays were on (or the switch was still under way): there is nothing to keep.
        XCTAssertFalse(KeptDesktop.shouldKeep(setting: true, padOnly: false, end: .padLeft, macUpdateWaiting: false))
    }
    func testTheMacEndingTheSessionAlwaysRestores() {
        // Stop Sharing, quit, sleep, a removed iPad and a failed capture must all give the Mac its displays back.
        XCTAssertFalse(KeptDesktop.shouldKeep(setting: true, padOnly: true, end: .hostEnded, macUpdateWaiting: false))
    }
    func testAWaitingMacUpdateRestores() {
        // The Mac cannot replace itself while iPad only is on; keeping the desktop would hold the update back.
        XCTAssertFalse(KeptDesktop.shouldKeep(setting: true, padOnly: true, end: .padLeft, macUpdateWaiting: true))
    }
    func testTheDesktopIsKeptForAWhileByDefaultNotForEver() {
        XCTAssertEqual(KeptDesktop.limit(minutes: KeptDesktop.defaultMinutes), 600)
        XCTAssertTrue(KeptDesktop.choices.contains(KeptDesktop.defaultMinutes))
        XCTAssertNil(KeptDesktop.limit(minutes: KeptDesktop.forever))
        XCTAssertNil(KeptDesktop.limit(minutes: 0))
        XCTAssertEqual(Set(KeptDesktop.choices.map(KeptDesktop.label)).count, KeptDesktop.choices.count)
    }
    func testOnlyTheSameDesktopIsReused() {
        XCTAssertTrue(KeptDesktop.canReuse(kept: pad, wanted: pad, padOnly: true))
        XCTAssertFalse(KeptDesktop.canReuse(kept: nil, wanted: pad, padOnly: true))
        // Another iPad, or the same one at another refresh rate, needs a display built for it.
        XCTAssertFalse(KeptDesktop.canReuse(kept: pad, wanted: KeptDesktop.Shape(width: 2360, height: 1640, fps: 120), padOnly: true))
        XCTAssertFalse(KeptDesktop.canReuse(kept: pad, wanted: KeptDesktop.Shape(width: 2752, height: 2064, fps: 60), padOnly: true))
        // The Mac's displays came back in the meantime: start from scratch.
        XCTAssertFalse(KeptDesktop.canReuse(kept: pad, wanted: pad, padOnly: false))
    }
}
