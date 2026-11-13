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
}
