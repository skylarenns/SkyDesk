import XCTest
@testable import SkyDeskCore

final class NativeDesktopTests: XCTestCase {
    func testIPadRetinaResolutionSurvivesHandshakeAndPixelSizing() throws {
        let display = ClientDisplay(width: 2752, height: 2064, maximumFPS: 120)
        try display.validate()
        let hello = Hello(session: UUID(), role: .control, display: display)
        let packet = try WirePacket.control(.hello(hello))
        guard case .hello(let decoded) = try packet.controlMessage() else { return XCTFail("Lost handshake") }
        XCTAssertEqual(decoded.display, display)
        XCTAssertEqual(DesktopGeometry.pixelSize(native: CGSize(width: 2752, height: 2064), longestEdge: 4096),
                       CGSize(width: 2752, height: 2064))
        let frame = DesktopGeometry.fit(content: CGSize(width: 2752, height: 2064),
                                        in: CGRect(x: 0, y: 0, width: 2752, height: 2064))
        XCTAssertEqual(frame, CGRect(x: 0, y: 0, width: 2752, height: 2064))
    }
    func testRejectsUnboundedOrOddNativeDisplayRequests() {
        for display in [ClientDisplay(width: 50000, height: 2064, maximumFPS: 120),
                        ClientDisplay(width: 2753, height: 2064, maximumFPS: 120),
                        ClientDisplay(width: 2752, height: 2064, maximumFPS: 500)] {
            XCTAssertThrowsError(try display.validate())
        }
    }
    func testKeyboardMovesCaretIntoViewWithoutShrinkingDesktop() {
        let content = CGSize(width: 2752, height: 2064)
        let bounds = CGRect(x: 0, y: 0, width: 1376, height: 1032)
        let caret = CGRect(x: 0.5, y: 0.88, width: 0.001, height: 0.025)
        let frame = DesktopGeometry.keyboardAdjustedFit(content: content, in: bounds, keyboardHeight: 360, focus: caret)
        XCTAssertEqual(frame.size, bounds.size)
        XCTAssertLessThan(frame.minY, 0)
        XCTAssertLessThanOrEqual(frame.minY + caret.maxY * frame.height, bounds.height - 360)
        let touch = CGPoint(x: frame.minX + caret.midX * frame.width, y: frame.minY + caret.midY * frame.height)
        let normalized = DesktopGeometry.normalized(touch, in: frame)!
        XCTAssertEqual(normalized.x, caret.midX, accuracy: 0.000001)
        XCTAssertEqual(normalized.y, caret.midY, accuracy: 0.000001)
        let pixels = DesktopGeometry.keyboardAdjustedFit(content: content,
            in: CGRect(origin: .zero, size: content), keyboardHeight: 720, focus: caret)
        XCTAssertEqual(pixels.minY, frame.minY * 2, accuracy: 0.000001)
    }
    func testKeyboardDoesNotMoveAlreadyVisibleFieldAndRestoresWhenHidden() {
        let bounds = CGRect(x: 0, y: 0, width: 1376, height: 1032)
        let content = CGSize(width: 2752, height: 2064)
        let high = CGRect(x: 0.2, y: 0.1, width: 0.2, height: 0.02)
        XCTAssertEqual(DesktopGeometry.keyboardAdjustedFit(content: content, in: bounds, keyboardHeight: 360, focus: high), bounds)
        XCTAssertEqual(DesktopGeometry.keyboardAdjustedFit(content: content, in: bounds, keyboardHeight: 0,
            focus: CGRect(x: 0.2, y: 0.9, width: 0.2, height: 0.02)), bounds)
    }
    func testTextFocusAndUnicodeRoundTripWithoutFieldContents() throws {
        let focus = RemoteTextFocus(id: 42, rect: CGRect(x: 0.2, y: 0.8, width: 0.001, height: 0.025), secure: true)
        XCTAssertTrue(focus.isValid)
        XCTAssertFalse(RemoteTextFocus(id: 1, rect: CGRect(x: CGFloat.nan, y: 0, width: 0, height: 0), secure: false).isValid)
        let packet = try WirePacket.control(.textFocus(focus))
        guard case .textFocus(let decoded) = try packet.controlMessage() else { return XCTFail("Missing focus") }
        XCTAssertEqual(decoded, focus)
        let text = "Hello 👋🏽 café 日本語"
        guard case .text(let result) = try WirePacket.control(.text(text)).controlMessage() else { return XCTFail("Missing text") }
        XCTAssertEqual(result, text)
    }
}
