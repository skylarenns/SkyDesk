import XCTest
@testable import SkyDeskCore

final class PointerCaptureTests: XCTestCase {
    private let desktop = CGRect(x: 0, y: 0, width: 1_376, height: 1_032)

    func testSmallMovementsAddUpInsteadOfBeingRoundedAway() {
        var pointer = RelativePointer()
        let start = CGPoint(x: 600, y: 500)
        XCTAssertNil(pointer.step(dx: 0.4, dy: -0.3, from: start, in: desktop))
        XCTAssertNil(pointer.step(dx: 0.4, dy: -0.3, from: start, in: desktop))
        let step = pointer.step(dx: 0.4, dy: -0.5, from: start, in: desktop)
        XCTAssertEqual(step, .init(target: CGPoint(x: 601, y: 499), dx: 1, dy: -1))
        // Ten thousand tiny steps travel the same distance as one large one.
        var total = 0
        for _ in 0..<10_000 { total += pointer.step(dx: 0.1, dy: 0, from: start, in: desktop)?.dx ?? 0 }
        XCTAssertEqual(Double(total), 1_000, accuracy: 1)
    }
    func testAPointerAGameHoldsInPlaceKeepsReportingTheFullMovement() {
        // The game puts the pointer back in the middle of its window after every event; each step starts from there.
        var pointer = RelativePointer()
        let held = CGPoint(x: 688, y: 516)
        for _ in 0..<500 {
            XCTAssertEqual(pointer.step(dx: 37, dy: -12, from: held, in: desktop), .init(target: CGPoint(x: 725, y: 504), dx: 37, dy: -12))
        }
    }
    func testThePointerStopsAtTheDesktopEdgeWhileStillPushing() {
        var pointer = RelativePointer()
        XCTAssertEqual(pointer.step(dx: 50, dy: 20, from: CGPoint(x: 100, y: 100), in: desktop)?.target, CGPoint(x: 150, y: 120))
        let pushed = pointer.step(dx: -40, dy: 500, from: CGPoint(x: 10, y: 1_000), in: desktop)
        XCTAssertEqual(pushed, .init(target: CGPoint(x: 0, y: 1_031), dx: -40, dy: 500))
        XCTAssertNil(pointer.step(dx: .nan, dy: 1, from: .zero, in: desktop))
    }
    func testFastMiceAreSummedIntoOneMessageEveryFewMilliseconds() {
        var mouse = DeltaCoalescer(interval: 4_000_000)
        XCTAssertEqual(mouse.add(dx: 1, dy: 0, now: 1_000_000), .send(dx: 1, dy: 0))        // the first goes at once
        XCTAssertEqual(mouse.add(dx: 2, dy: 1, now: 2_000_000), .wait(3_000_000))
        XCTAssertEqual(mouse.add(dx: 3, dy: 1, now: 3_000_000), .wait(2_000_000))
        XCTAssertEqual(mouse.add(dx: 4, dy: 1, now: 5_000_000), .send(dx: 9, dy: 3))        // nothing lost
        XCTAssertNil(mouse.flush(now: 5_500_000))
        XCTAssertEqual(mouse.add(dx: -1, dy: 0, now: 6_000_000), .wait(3_000_000))
        XCTAssertEqual(mouse.flush(now: 6_100_000)?.dx, -1)                                 // a click flushes first
        // A sum beyond what one message may carry goes out in parts.
        XCTAssertEqual(mouse.add(dx: 5_000, dy: 0, now: 100_000_000), .send(dx: 2_000, dy: 0))
        XCTAssertEqual(mouse.x, 3_000)
    }
    func testCapturedPointerEventsAreValidatedAsDistances() throws {
        XCTAssertTrue(InputEvent(kind: .move, x: -350, y: 120, relative: true).isValid)
        XCTAssertFalse(InputEvent(kind: .move, x: -350, y: 120).isValid)                    // a position must be 0...1
        XCTAssertFalse(InputEvent(kind: .move, x: 2_001, y: 0, relative: true).isValid)
        XCTAssertTrue(InputEvent(kind: .down, button: 1, relative: true).isValid)
        // An event from an iPad that knows nothing of capture decodes as an ordinary position.
        let old = try JSONDecoder().decode(InputEvent.self, from: Data(#"{"kind":"move","x":0.5,"y":0.25,"button":0,"keyCode":0,"isDown":false,"modifiers":0}"#.utf8))
        XCTAssertNil(old.relative); XCTAssertTrue(old.isValid)
        let sent = try JSONDecoder().decode(InputEvent.self, from: JSONEncoder().encode(InputEvent(kind: .move, x: 3, y: -4, relative: true)))
        XCTAssertEqual(sent.relative, true)
    }
    func testAnAppThatHidesThePointerAndHoldsItInPlaceHasTakenTheMouse() {
        var mac = PointerHoldDetector()
        // Before the pointer has been seen to go where it is put on this Mac, "it did not" proves nothing.
        for step in 0..<200 { XCTAssertNil(mac.note(hidden: true, moved: true, followed: false, now: -10 + Double(step) * 0.008)) }
        for step in 0..<PointerHoldDetector.provenAfter { XCTAssertNil(mac.note(hidden: false, moved: true, followed: true, now: -5 + Double(step) * 0.008)) }
        // Moves 8 ms apart, pointer hidden, and each time found somewhere other than where it was sent.
        var changes: [(Double, Bool)] = []
        for step in 0..<40 { let now = Double(step) * 0.008; if let held = mac.note(hidden: true, moved: true, followed: false, now: now) { changes.append((now, held)) } }
        XCTAssertEqual(changes.count, 1); XCTAssertEqual(changes.first?.1, true)
        XCTAssertEqual(changes.first?.0 ?? 0, 0.152, accuracy: 0.001)
        // Given back once the pointer has been showing for a fifth of a second, movement or not; one flash does not count.
        XCTAssertNil(mac.note(hidden: false, moved: false, followed: nil, now: 1.00))
        XCTAssertNil(mac.note(hidden: true, moved: false, followed: nil, now: 1.05))
        XCTAssertNil(mac.note(hidden: false, moved: false, followed: nil, now: 1.10))
        XCTAssertNil(mac.note(hidden: false, moved: true, followed: false, now: 1.25))
        XCTAssertEqual(mac.note(hidden: false, moved: false, followed: nil, now: 1.31), false)
        XCTAssertFalse(mac.held)
    }
    func testAHiddenPointerThatGoesWhereItIsPutIsNeverHeld() {
        // What broke build 48: after typing, the Mac's pointer stays hidden however much the iPad moves it.
        // It goes exactly where it is sent, so nobody has taken it.
        var mac = PointerHoldDetector()
        for step in 0..<5_000 { XCTAssertNil(mac.note(hidden: true, moved: true, followed: true, now: Double(step) * 0.008)) }
        // The odd movement that seems not to have landed changes nothing while others do land.
        for step in 0..<5_000 {
            XCTAssertNil(mac.note(hidden: true, moved: true, followed: step % 4 == 0 ? false : true, now: 40 + Double(step) * 0.008))
        }
        // Movements that say nothing either way (the pointer was not asked to move) do not add up to a hold.
        for step in 0..<500 { XCTAssertNil(mac.note(hidden: true, moved: true, followed: nil, now: 80 + Double(step) * 0.008)) }
        // Held in place but showing (something else is moving the pointer, such as someone at the Mac): not a capture.
        for step in 0..<500 { XCTAssertNil(mac.note(hidden: false, moved: true, followed: false, now: 90 + Double(step) * 0.008)) }
        XCTAssertFalse(mac.held)
    }
    func testAHeldPointerThatStartsGoingWhereItIsPutIsGivenBackEvenIfStillHidden() {
        // A wrong capture must undo itself: the pointer follows again, so the hold ends without waiting for it to show.
        var mac = PointerHoldDetector()
        for step in 0..<PointerHoldDetector.provenAfter { _ = mac.note(hidden: false, moved: true, followed: true, now: -1 + Double(step) * 0.008) }
        for step in 0..<30 { _ = mac.note(hidden: true, moved: true, followed: false, now: Double(step) * 0.008) }
        XCTAssertTrue(mac.held)
        var released: Double?
        for step in 0..<100 where released == nil {
            let now = 1 + Double(step) * 0.008
            if mac.note(hidden: true, moved: true, followed: true, now: now) == false { released = now }
        }
        XCTAssertEqual(released ?? 0, 1.304, accuracy: 0.001)
        // While the game keeps putting it back, it stays held.
        for step in 0..<30 { _ = mac.note(hidden: true, moved: true, followed: false, now: 3 + Double(step) * 0.008) }
        XCTAssertTrue(mac.held)
        for step in 0..<1_000 { XCTAssertNil(mac.note(hidden: true, moved: true, followed: step % 9 == 0, now: 4 + Double(step) * 0.008)) }
        XCTAssertTrue(mac.held)
    }
    func testWhetherThePointerWentWhereItWasPut() {
        var pointer = PointerFollowing()
        XCTAssertNil(pointer.followed(actual: CGPoint(x: 10, y: 10)))                       // nothing sent yet
        pointer.sent(target: CGPoint(x: 100, y: 100), from: CGPoint(x: 10, y: 10))
        XCTAssertEqual(pointer.followed(actual: CGPoint(x: 100, y: 101)), true)
        // The reading may trail the newest movement: an earlier target still counts as followed.
        pointer.sent(target: CGPoint(x: 140, y: 100), from: CGPoint(x: 100, y: 100))
        pointer.sent(target: CGPoint(x: 180, y: 100), from: CGPoint(x: 140, y: 100))
        XCTAssertEqual(pointer.followed(actual: CGPoint(x: 140, y: 100)), true)
        // A game put it back in the middle of its window.
        XCTAssertEqual(pointer.followed(actual: CGPoint(x: 688, y: 516)), false)
        // A movement that sends the pointer where it already is says nothing about the next reading.
        pointer.sent(target: CGPoint(x: 688, y: 517), from: CGPoint(x: 688, y: 516))
        XCTAssertNil(pointer.followed(actual: CGPoint(x: 688, y: 516)))
        // Slow aiming, then a quick turn, in a game that puts the pointer back in the middle every time: the small
        // movements say nothing, and the large one shows the pointer did not stay where it was sent.
        var game = PointerFollowing()
        let middle = CGPoint(x: 688, y: 516)
        for small in [1.0, 2.0, -1.0, 2.0] {
            XCTAssertNotEqual(game.followed(actual: middle), true)
            game.sent(target: CGPoint(x: middle.x + small, y: middle.y), from: middle)
        }
        game.sent(target: CGPoint(x: middle.x + 25, y: middle.y - 9), from: middle)
        XCTAssertEqual(game.followed(actual: middle), false)
    }
}
