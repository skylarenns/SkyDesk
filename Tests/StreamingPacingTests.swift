import XCTest
import CoreMedia
import CoreVideo
@testable import SkyDeskCore

final class StreamingPacingTests: XCTestCase {
    func testCongestionCannotGrowQueueAndUnknownAcksDoNotTrainIt() {
        let window = FrameWindow.streaming(fps: 120)
        window.acknowledge(999, now: 80_000_000)
        XCTAssertEqual(window.currentLimit, 2)
        let first = window.reserve(now: 0)!
        window.acknowledge(first, now: 80_000_000)
        XCTAssertEqual(window.currentLimit, 8)
        for tick in 0..<100 {
            _ = window.reserve(now: 100_000_000 + UInt64(tick) * 8_333_334)
        }
        XCTAssertNil(window.reserve(now: 1_000_000_000))
        XCTAssertLessThanOrEqual(window.currentLimit, 8)
        window.reset()
        XCTAssertEqual(window.currentLimit, 2)
        XCTAssertEqual(window.feedbackMilliseconds, 0)
        XCTAssertNotNil(window.reserve(now: 2_000_000_000))
    }

    func testFeedbackSpikeDoesNotInflateAnEstablishedWindow() {
        let window = FrameWindow.streaming(fps: 120)
        let first = window.reserve(now: 0)!
        window.acknowledge(first, now: 20_000_000)
        let baseline = window.currentLimit
        let next = window.reserve(now: 30_000_000)!
        window.acknowledge(next, now: 130_000_000)
        XCTAssertEqual(window.currentLimit, baseline)
    }

    func testNormalLANFeedbackDoesNotThrottle120HzCaptureTo60FPS() {
        let window = FrameWindow.streaming(fps: 120)
        let interval: UInt64 = 8_333_334
        let feedbackDelay: UInt64 = 32_000_000
        var pending: [(sequence: UInt64, due: UInt64)] = []
        var accepted = 0
        for tick in 0..<240 {
            let now = UInt64(tick) * interval
            for ack in pending where ack.due <= now { window.acknowledge(ack.sequence, now: ack.due) }
            pending.removeAll { $0.due <= now }
            if let sequence = window.reserve(now: now) {
                accepted += 1
                pending.append((sequence, now + feedbackDelay))
            }
        }
        print("120 Hz capture, 32 ms capture-to-decode feedback: \(Double(accepted) / 2) accepted FPS")
        XCTAssertGreaterThanOrEqual(accepted, 220, "Healthy LAN feedback should not halve capture throughput.")
        XCTAssertLessThanOrEqual(pending.count, 6, "Throughput must remain bounded under congestion.")
    }

    /// Model of the one measured live interval: 33 ms best-case feedback, 62 ms mean (Wi-Fi jitter).
    func testJitteredFeedbackKeepsMostOfA120HzSource() {
        let window = FrameWindow.streaming(fps: 120)
        let interval: UInt64 = 8_333_334
        let jitterMS: [UInt64] = [0, 8, 17, 25, 33, 42, 50, 58]
        var pending: [(sequence: UInt64, due: UInt64)] = []
        var accepted = 0, worstInFlight = 0
        for tick in 0..<480 {
            let now = UInt64(tick) * interval
            for ack in pending.filter({ $0.due <= now }).sorted(by: { $0.due < $1.due }) {
                window.acknowledge(ack.sequence, now: ack.due)
            }
            pending.removeAll { $0.due <= now }
            if let sequence = window.reserve(now: now) {
                pending.append((sequence, now + 33_000_000 + jitterMS[accepted % jitterMS.count] * 1_000_000))
                accepted += 1
            }
            worstInFlight = max(worstInFlight, pending.count)
        }
        print("120 Hz capture, 33–91 ms jittered feedback (mean 62 ms): \(Double(accepted) / 4) accepted FPS, \(worstInFlight) max in flight")
        XCTAssertGreaterThanOrEqual(accepted, 360, "Ordinary Wi-Fi jitter should not discard a third of captured frames.")
        XCTAssertLessThanOrEqual(worstInFlight, 8, "The in-flight bound must stay small.")
    }

    #if os(macOS)
    /// TCP delivery is lossless, so periodic keyframes only add megabyte bursts that stall the stream.
    func testEncoderSendsOneKeyframeThenOnlyDependentFrames() throws {
        let width = 1280, height = 720, fps = 60, count = 150
        let encoder: HEVCEncoder
        do { encoder = try HEVCEncoder(width: width, height: height, fps: fps, bitrate: 8_000_000) }
        catch { throw XCTSkip("Hardware HEVC encoder unavailable: \(error.localizedDescription)") }
        let lock = NSLock(); var keyframes = 0, total = 0, largest = 0
        for index in 1...count {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
            let image = buffer!
            CVPixelBufferLockBaseAddress(image, [])
            let luma = CVPixelBufferGetBaseAddressOfPlane(image, 0)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
            for row in 0..<height { memset(luma + row * stride, Int32((row + index * 8) / 16 % 2 == 0 ? 40 : 220), width) }
            memset(CVPixelBufferGetBaseAddressOfPlane(image, 1)!, 128, CVPixelBufferGetBytesPerRowOfPlane(image, 1) * height / 2)
            CVPixelBufferUnlockBaseAddress(image, [])
            encoder.encode(image, sequence: UInt64(index), captureTime: 0,
                           timestamp: CMTime(value: Int64(index), timescale: CMTimeScale(fps))) { result in
                guard case .success(let frame) = result else { return }
                lock.lock(); total += 1; if frame.keyframe { keyframes += 1 }; largest = max(largest, frame.bytes.count); lock.unlock()
            }
        }
        encoder.flush()
        print("Encoded \(total) frames spanning \(count / fps) s: \(keyframes) keyframe(s), largest \(largest) bytes")
        XCTAssertEqual(total, count)
        XCTAssertEqual(keyframes, 1, "Only the first frame of a session may be a keyframe.")
    }
    #endif
}
