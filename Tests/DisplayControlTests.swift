import XCTest
@testable import SkyDeskCore

final class DisplayControlTests: XCTestCase {
    func testBlankingNegotiatesWithoutBreakingOlderStreamInfo() throws {
        let old = StreamInfo(width: 2752, height: 2064, fps: 120, bitrate: 25_000_000,
                             displayName: "iPad", inputEnabled: true)
        let decoded = try JSONDecoder().decode(StreamInfo.self, from: JSONEncoder().encode(old))
        XCTAssertNil(decoded.displayBlankingSupported)
        for value in [true, false] {
            guard case .setMacDisplayBlanked(let command) = try WirePacket.control(.setMacDisplayBlanked(value)).controlMessage(),
                  case .macDisplayBlanked(let state) = try WirePacket.control(.macDisplayBlanked(value)).controlMessage() else {
                return XCTFail("Lost display control")
            }
            XCTAssertEqual(command, value); XCTAssertEqual(state, value)
        }
    }
    #if os(macOS)
    func testRemoteInputTagSurvivesCopyForKeysPointerAndScroll() throws {
        // Do not post input. Exercise the exact event metadata used by the global monitor.
        let events = [CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                      CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                              mouseCursorPosition: .zero, mouseButton: .left),
                      CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 10, wheel2: 0, wheel3: 0)]
        for candidate in events {
            let event = try XCTUnwrap(candidate)
            XCTAssertTrue(RemoteInputOrigin.isLocalActivity(event))
            RemoteInputOrigin.mark(event)
            XCTAssertFalse(RemoteInputOrigin.isLocalActivity(try XCTUnwrap(event.copy())))
            // A new physical-source event must not inherit the remote marker.
            let local = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
            XCTAssertTrue(RemoteInputOrigin.isLocalActivity(local))
        }
    }
    #endif

    func testMakingTheIPadMainKeepsTheArrangementAroundIt() {
        // As in the log of 2026-11-14: the Mac's display at 0, 0 (main), the iPad's desktop to its left.
        let before = DisplayLayoutSnapshot(main: 1, sessionDisplay: 40, screens: [.init(id: 1, x: 0, y: 0), .init(id: 40, x: -1376, y: 0)])
        let moved = DisplayLayout.origins(withMain: 40, in: before)
        XCTAssertEqual(moved?.map(\.id), [1, 40])
        XCTAssertEqual(moved?.map(\.x), [1376, 0]); XCTAssertEqual(moved?.map(\.y), [0, 0])
        // A third display keeps its place relative to the others.
        let three = DisplayLayoutSnapshot(main: 1, sessionDisplay: 40, screens: [.init(id: 1, x: 0, y: 0), .init(id: 2, x: 2056, y: -200), .init(id: 40, x: -1376, y: 100)])
        let shifted = DisplayLayout.origins(withMain: 40, in: three)
        XCTAssertEqual(shifted?.map(\.x), [1376, 3432, 0]); XCTAssertEqual(shifted?.map(\.y), [-100, -300, 0])
        XCTAssertNil(DisplayLayout.origins(withMain: 99, in: before))
    }
}
