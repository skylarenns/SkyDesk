import XCTest
@testable import SkyDeskCore

final class ScrollMotionTests: XCTestCase {
    func testSlowScrollingIsNotRoundedAway() {
        var steps = ScrollAccumulator()
        var total: Int32 = 0
        // 120 small steps of 0.4 pt used to round to zero each time: 0 pt of scrolling instead of 48.
        for _ in 0..<120 { total += steps.step(CGPoint(x: 0, y: 0.4)).y }
        XCTAssertEqual(total, 48)
        var down = ScrollAccumulator(); var sum: Int32 = 0
        for _ in 0..<10 { sum += down.step(CGPoint(x: -0.75, y: 0)).x }
        XCTAssertEqual(sum, -7)
    }
    func testGlideDistanceMatchesUIKitAndDoesNotDependOnTickRate() {
        func distance(_ dt: Double) -> CGPoint {
            var glide = ScrollMomentum(velocity: CGPoint(x: 0, y: 2_000))!
            var total = CGPoint.zero
            while let delta = glide.step(dt) { total.x += delta.x; total.y += delta.y }
            return total
        }
        let at120 = distance(1.0 / 120), at60 = distance(1.0 / 60)
        // UIScrollView normal deceleration: total ≈ v / -ln(0.998)/1000 ≈ 2000 × 0.4995 ≈ 999 pt (minus the cut-off tail).
        XCTAssertEqual(at120.y, 999, accuracy: 15)
        XCTAssertEqual(at120.y, at60.y, accuracy: 3)
        XCTAssertEqual(at120.x, 0)
    }
    func testGlideIgnoresTinyOrInvalidVelocityAndCapsSpeedAndDuration() {
        XCTAssertNil(ScrollMomentum(velocity: CGPoint(x: 10, y: 20)))
        XCTAssertNil(ScrollMomentum(velocity: CGPoint(x: CGFloat.nan, y: 500)))
        var fast = ScrollMomentum(velocity: CGPoint(x: 0, y: 1_000_000))!
        let first = fast.step(0.01)!
        XCTAssertLessThan(first.y, ScrollMomentum.maximumSpeed * 0.01 + 1)
        var seconds = 0.0
        while fast.step(0.01) != nil { seconds += 0.01 }
        XCTAssertLessThanOrEqual(seconds, ScrollMomentum.maximumDuration)
    }
    func testAZeroStepDoesNotEndTheGlide() {
        // Build 64: a glide whose first refresh shared the fingers' last timestamp ended at once.
        var glide = ScrollMomentum(velocity: CGPoint(x: 0, y: 300))!
        XCTAssertEqual(glide.step(0), .zero)
        XCTAssertGreaterThan(glide.step(1.0 / 120)?.y ?? 0, 0)
    }
    func testPhaseIsOptionalOnTheWireAndValidated() throws {
        let old = try JSONDecoder().decode(InputEvent.self, from: Data(#"{"kind":"scroll","x":0,"y":3,"button":0,"keyCode":0,"isDown":false,"modifiers":0}"#.utf8))
        XCTAssertNil(old.phase); XCTAssertTrue(old.isValid)
        XCTAssertTrue(InputEvent(kind: .scroll, y: 2, phase: ScrollPhase.ended).isValid)
        XCTAssertFalse(InputEvent(kind: .scroll, y: 2, phase: 9).isValid)
        guard case .scrollMomentum(let x, let y) = try WirePacket.control(.scrollMomentum(1.5, -800)).controlMessage() else { return XCTFail() }
        XCTAssertEqual(x, 1.5); XCTAssertEqual(y, -800)
    }
}

final class ModifierSyncTests: XCTestCase {
    func testStuckCommandIsReleasedWhenThePointerSaysItIsUp() {
        // ⌘ (227) still remembered as held, but the click's real modifiers are none.
        XCTAssertEqual(ModifierSync.stale(held: [227], actual: 0), [227])
        XCTAssertEqual(ModifierSync.stale(held: [227, 4], actual: 0), [227], "letters are not modifiers")
        XCTAssertEqual(ModifierSync.stale(held: [227, 225], actual: 8), [225], "⌘ really down: only ⇧ is stale")
        XCTAssertEqual(ModifierSync.stale(held: [231, 230], actual: 0), [230, 231], "right-hand keys too")
        XCTAssertEqual(ModifierSync.stale(held: [57], actual: 0), [], "Caps Lock is a toggle")
        XCTAssertEqual(ModifierSync.stale(held: [], actual: 15), [])
    }
}
