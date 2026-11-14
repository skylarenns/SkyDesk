import XCTest
@testable import SkyDeskCore

final class ProtocolTests: XCTestCase {
    func testEverySplitAndCoalescedPackets() throws {
        let packet = try WirePacket.control(.ping(42)).encoded()
        for split in 0...packet.count {
            var parser = WireParser()
            let messages = try parser.append(Data(packet.prefix(split))) + parser.append(Data(packet.dropFirst(split)))
            XCTAssertEqual(messages.count, 1)
            guard case .ping(42) = try messages[0].controlMessage() else { return XCTFail("Lost framing") }
        }
        var parser = WireParser()
        XCTAssertEqual(try parser.append(packet + packet).count, 2)
    }
    func testRejectsVersionAndLengthBeforeBody() throws {
        var header = Data([0x53, 0x4b, 0x59, 0x44, 1, 1, 0, 0])
        header.appendInteger(UInt32(65537))
        var parser = WireParser()
        XCTAssertThrowsError(try parser.append(header))
        header[4] = 2
        parser = WireParser()
        XCTAssertThrowsError(try parser.append(header))
    }
    func testVideoRoundTripAndTruncatedParameters() throws {
        let frame = VideoFrame(sequence: 7, captureTime: 100, encodeTime: 200, keyframe: true,
            parameterSets: [Data([1]), Data([2, 3]), Data([4])], bytes: Data([0, 0, 0, 1, 5]))
        let bytes = try frame.encoded()
        let decoded = try VideoFrame(data: bytes)
        XCTAssertEqual(decoded.sequence, 7)
        XCTAssertEqual(decoded.parameterSets, frame.parameterSets)
        XCTAssertEqual(decoded.bytes, frame.bytes)
        for length in 0..<bytes.count - frame.bytes.count + 1 {
            XCTAssertThrowsError(try VideoFrame(data: Data(bytes.prefix(length))))
        }
    }
    func testFrameWindowDoesNotAcceptUnrelatedAcknowledgement() {
        let window = FrameWindow(capacity: 2)
        XCTAssertEqual(window.reserve(), 1); XCTAssertEqual(window.reserve(), 2)
        XCTAssertNil(window.reserve())
        window.acknowledge(999); XCTAssertNil(window.reserve())
        window.acknowledge(1); XCTAssertEqual(window.reserve(), 3)
        window.acknowledge(1); XCTAssertNil(window.reserve())
    }
    func testStallDeadlineTracksOutstandingFrameNotIdleDesktop() {
        let window = FrameWindow(capacity: 2)
        let sequence = window.reserve(now: 10)!
        XCTAssertEqual(window.oldestAge(now: 20), 10)
        window.acknowledge(sequence)
        XCTAssertNil(window.oldestAge(now: 100_000))
        _ = window.reserve(now: 100_000)
        XCTAssertEqual(window.oldestAge(now: 100_001), 1)
        XCTAssertEqual(window.oldestAge(now: 6_000_100_000), 6_000_000_000)
    }
    func testLetterboxMappingAndRetinaAspectRatio() {
        let content = CGSize(width: 2560, height: 1600)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        XCTAssertNil(DesktopGeometry.normalized(CGPoint(x: 500, y: 20), content: content, in: bounds))
        XCTAssertEqual(DesktopGeometry.normalized(CGPoint(x: 500, y: 500), content: content, in: bounds), CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(DesktopGeometry.pixelSize(native: CGSize(width: 3456, height: 2234), longestEdge: 2560), CGSize(width: 2560, height: 1654))
    }
    func testHostileInputAndPairingValidation() throws {
        XCTAssertFalse(InputEvent(kind: .move, x: .nan).isValid)
        XCTAssertFalse(InputEvent(kind: .down, x: 1.1).isValid)
        XCTAssertFalse(InputEvent(kind: .scroll, y: 2001).isValid)
        XCTAssertFalse(InputEvent(kind: .key, keyCode: 65535).isValid)
        XCTAssertFalse(InputEvent(kind: .key, modifiers: 32).isValid)
        let key = try PairingKey()
        XCTAssertEqual(try PairingKey(text: key.text), key)
        XCTAssertThrowsError(try PairingKey(text: String(repeating: "z", count: 64)))
        XCTAssertThrowsError(try PairingKey(text: "1234"))
    }
}

final class PauseVideoProtocolTests: XCTestCase {
    func testPauseMessageAndHostNameRoundTrip() throws {
        let packet = try WirePacket.control(.pauseVideo(true))
        guard case .pauseVideo(true) = try packet.controlMessage() else { return XCTFail("pauseVideo did not round-trip") }
        let info = StreamInfo(width: 2752, height: 2064, fps: 120, bitrate: 25_000_000, displayName: "iPad",
                              inputEnabled: true, features: StreamFeature.pauseVideo, hostName: "Studio")
        let decoded = try JSONDecoder().decode(StreamInfo.self, from: JSONEncoder().encode(info))
        XCTAssertEqual(decoded.hostName, "Studio")
        XCTAssertEqual((decoded.features ?? 0) & StreamFeature.pauseVideo, StreamFeature.pauseVideo)
        // An older host's welcome has no name and no pause bit: the iPad falls back to disconnect-and-resume.
        let old = try JSONDecoder().decode(StreamInfo.self, from: Data(#"{"width":2,"height":2,"fps":60,"bitrate":1000000,"displayName":"x","inputEnabled":true}"#.utf8))
        XCTAssertNil(old.hostName); XCTAssertNil(old.features)
        XCTAssertEqual(Set([StreamFeature.idleGapFlags, StreamFeature.clientStatsLog, StreamFeature.localCursor, StreamFeature.pauseVideo]).count, 4)
    }
}
