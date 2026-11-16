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
}
