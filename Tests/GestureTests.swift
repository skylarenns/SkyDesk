import XCTest
@testable import SkyDeskCore
#if os(macOS)
import AppKit
#endif

final class GestureTests: XCTestCase {
    func testPinchTotalsBecomeZoomSteps() {
        var steps = GestureSteps()
        XCTAssertEqual(steps.magnification(scale: 1.1)!, 0.1, accuracy: 1e-9)
        XCTAssertEqual(steps.magnification(scale: 1.21)!, 0.1, accuracy: 1e-9)
        XCTAssertEqual(steps.magnification(scale: 0.605)!, -0.5, accuracy: 1e-9)
        XCTAssertNil(steps.magnification(scale: 0))
        XCTAssertNil(steps.magnification(scale: .nan))
        // An unusable total leaves the running scale alone.
        XCTAssertEqual(steps.magnification(scale: 0.605)!, 0, accuracy: 1e-9)
        steps.reset()
        XCTAssertEqual(steps.magnification(scale: 100)!, 4, accuracy: 1e-9)
    }

    func testRotationTotalsBecomeCounterClockwiseDegrees() {
        var steps = GestureSteps()
        // UIKit: clockwise positive radians. macOS: counter-clockwise positive degrees.
        XCTAssertEqual(steps.degrees(radians: .pi / 2)!, -90, accuracy: 1e-9)
        XCTAssertEqual(steps.degrees(radians: .pi / 4)!, 45, accuracy: 1e-9)
        XCTAssertNil(steps.degrees(radians: .infinity))
    }

    func testValidityAndWireRoundTrip() throws {
        XCTAssertTrue(GestureEvent(kind: .magnify, value: 0.2, phase: ScrollPhase.changed).isValid)
        XCTAssertFalse(GestureEvent(kind: .magnify, value: 5, phase: ScrollPhase.changed).isValid)
        XCTAssertFalse(GestureEvent(kind: .rotate, value: .nan, phase: ScrollPhase.changed).isValid)
        XCTAssertFalse(GestureEvent(kind: .rotate, value: 1, phase: 0).isValid)
        let sent = GestureEvent(kind: .rotate, value: -12.5, phase: ScrollPhase.began)
        let packet = try WirePacket.control(.gesture(sent))
        guard case .gesture(let received) = try packet.controlMessage() else { return XCTFail("wrong message") }
        XCTAssertEqual(received, sent)
    }

    #if os(macOS)
    /// AppKit must read the injected event back as the gesture it stands for. Nothing is posted to the system.
    func testInjectedEventsAreRealMacGestures() throws {
        let place = CGPoint(x: 300, y: 200)
        let phases: [(Int, NSEvent.Phase)] = [(ScrollPhase.began, .began), (ScrollPhase.changed, .changed), (ScrollPhase.ended, .ended)]
        for (phase, expected) in phases {
            let zoom = try XCTUnwrap(GestureInjection.event(GestureEvent(kind: .magnify, value: 0.25, phase: phase), at: place))
            let event = try XCTUnwrap(NSEvent(cgEvent: zoom))
            XCTAssertEqual(event.type, .magnify)
            XCTAssertEqual(event.magnification, 0.25, accuracy: 1e-6)
            XCTAssertEqual(event.phase, expected)
            XCTAssertFalse(RemoteInputOrigin.isLocalActivity(try XCTUnwrap(event.cgEvent)), "remote marker lost")
            XCTAssertEqual(zoom.location, place)
        }
        let turn = try XCTUnwrap(GestureInjection.event(GestureEvent(kind: .rotate, value: -12.5, phase: ScrollPhase.changed), at: place))
        let event = try XCTUnwrap(NSEvent(cgEvent: turn))
        XCTAssertEqual(event.type, .rotate)
        XCTAssertEqual(Double(event.rotation), -12.5, accuracy: 1e-4)
        XCTAssertNil(GestureInjection.event(GestureEvent(kind: .magnify, value: 9, phase: ScrollPhase.changed), at: place))
    }

    func testGestureSeenRightAfterAnInjectionIsNotLocalActivity() {
        RemoteInputOrigin.lastGesture = 0
        XCTAssertFalse(RemoteInputOrigin.gestureJustInjected(now: 1_000_000_000))
        RemoteInputOrigin.lastGesture = 1_000_000_000
        XCTAssertTrue(RemoteInputOrigin.gestureJustInjected(now: 1_300_000_000))
        XCTAssertFalse(RemoteInputOrigin.gestureJustInjected(now: 1_600_000_000))
        RemoteInputOrigin.lastGesture = 0
    }
    #endif
}
