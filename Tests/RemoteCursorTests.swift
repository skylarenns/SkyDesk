import XCTest
@testable import SkyDeskCore

final class RemoteCursorTests: XCTestCase {
    func testCursorMessageRoundTrips() throws {
        let cursor = RemoteCursor(png: Data([1, 2, 3]), width: 28.0 / 1376, height: 40.0 / 1032, hotX: 5.0 / 28, hotY: 0.125)
        XCTAssertTrue(cursor.isValid)
        let packet = try WirePacket.control(.cursor(cursor))
        guard case .cursor(let decoded) = try packet.controlMessage() else { return XCTFail("wrong message") }
        XCTAssertEqual(decoded, cursor)
    }
    func testRejectsOversizedOrMalformedCursors() {
        XCTAssertFalse(RemoteCursor(png: Data(), width: 0.02, height: 0.02, hotX: 0, hotY: 0).isValid)
        XCTAssertFalse(RemoteCursor(png: Data(count: 50_000), width: 0.02, height: 0.02, hotX: 0, hotY: 0).isValid)
        XCTAssertFalse(RemoteCursor(png: Data([1]), width: 0.5, height: 0.02, hotX: 0, hotY: 0).isValid)
        XCTAssertFalse(RemoteCursor(png: Data([1]), width: 0.02, height: 0.02, hotX: 1.5, hotY: 0).isValid)
        XCTAssertFalse(RemoteCursor(png: Data([1]), width: .nan, height: 0.02, hotX: 0, hotY: 0).isValid)
    }
}
