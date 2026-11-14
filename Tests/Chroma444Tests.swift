#if os(macOS)
import XCTest
import CoreVideo
import CoreMedia
@testable import SkyDeskCore

/// Real hardware encode and decode on this Mac; skipped where the encoder has no 4:4:4.
final class Chroma444Tests: XCTestCase {
    private let width = 1280, height = 720

    /// Vertical stripes one pixel wide: red-orange on white. 4:2:0 cannot keep the colour of single-pixel columns.
    private func stripes() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let pixels = buffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(pixels)
        for row in 0..<height {
            for x in 0..<width {
                let coloured = x % 2 == 0
                let pixel = base + row * stride + x * 4
                pixel[0] = coloured ? 40 : 255; pixel[1] = coloured ? 60 : 255; pixel[2] = coloured ? 230 : 255; pixel[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    private func roundTrip(chroma444: Bool) throws -> (decoder: HEVCDecoder, image: CVPixelBuffer) {
        let encoder: HEVCEncoder
        do { encoder = try HEVCEncoder(width: width, height: height, fps: 60, bitrate: 40_000_000, chroma444: chroma444) }
        catch { throw XCTSkip("Hardware HEVC \(chroma444 ? "4:4:4 " : "")encoding is unavailable here: \(error.localizedDescription)") }
        let decoder = HEVCDecoder()
        let source = stripes()
        let done = expectation(description: "decoded")
        var result: CVPixelBuffer?
        var failure: Error?
        // A few frames so rate control settles on the still picture; the last one is inspected.
        for index in 1...6 {
            encoder.encode(source, sequence: UInt64(index), captureTime: monotonicNanos(), timestamp: CMTime(value: Int64(index), timescale: 60)) { encoded in
                do {
                    try decoder.decode(try encoded.get()) { decoded in
                        if index == 6 {
                            switch decoded { case .success(let image): result = image; case .failure(let error): failure = error }
                            done.fulfill()
                        }
                    }
                } catch { if index == 6 { failure = error; done.fulfill() } }
            }
        }
        encoder.flush()
        wait(for: [done], timeout: 10)
        if let failure { throw failure }
        return (decoder, try XCTUnwrap(result))
    }

    /// Mean absolute difference in Cb and Cr between neighbouring columns on one row of the colour plane.
    private func colourContrast(_ image: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(image, .readOnly); defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let plane = CVPixelBufferGetBaseAddressOfPlane(image, 1)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 1), columns = CVPixelBufferGetWidthOfPlane(image, 1)
        let row = plane + (CVPixelBufferGetHeightOfPlane(image, 1) / 2) * rowBytes
        var total = 0.0
        for x in 100..<300 where x + 1 < columns {
            total += abs(Double(row[x * 2]) - Double(row[(x + 1) * 2])) + abs(Double(row[x * 2 + 1]) - Double(row[(x + 1) * 2 + 1]))
        }
        return total / 400
    }

    func testFullColourKeepsSinglePixelColourThatTheUsualFormatLoses() throws {
        let usual = try roundTrip(chroma444: false)
        XCTAssertFalse(usual.decoder.chroma444)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(usual.image), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(CVPixelBufferGetWidthOfPlane(usual.image, 1), width / 2)

        let full = try roundTrip(chroma444: true)
        XCTAssertTrue(full.decoder.chroma444)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(full.image), kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(CVPixelBufferGetWidthOfPlane(full.image, 1), width)
        XCTAssertEqual(CVPixelBufferGetPlaneCount(full.image), 2)
        // Neighbouring columns keep different colours in 4:4:4; in 4:2:0 the colour plane cannot tell them apart.
        XCTAssertGreaterThan(colourContrast(full.image), 40)
        XCTAssertLessThan(colourContrast(usual.image), 8)
    }

    func testFullColourUsesTheSameColourMathAsTheRenderer() throws {
        let full = try roundTrip(chroma444: true)
        CVPixelBufferLockBaseAddress(full.image, .readOnly); defer { CVPixelBufferUnlockBaseAddress(full.image, .readOnly) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(full.image, 0)!.assumingMemoryBound(to: UInt8.self)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(full.image, 1)!.assumingMemoryBound(to: UInt8.self)
        let row = height / 2
        let y = Double(luma[row * CVPixelBufferGetBytesPerRowOfPlane(full.image, 0) + 200])            // a coloured column
        let cb = Double(chroma[row * CVPixelBufferGetBytesPerRowOfPlane(full.image, 1) + 400])
        let cr = Double(chroma[row * CVPixelBufferGetBytesPerRowOfPlane(full.image, 1) + 401])
        // The renderer's BT.709 video-range conversion must give back the red-orange that went in (230, 60, 40).
        let l = (y - 16) * 255 / 219, b = (cb - 128) * 255 / 224, r = (cr - 128) * 255 / 224
        let red = l + 1.5748 * r, green = l - 0.1873 * b - 0.4681 * r, blue = l + 1.8556 * b
        XCTAssertEqual(red, 230, accuracy: 14); XCTAssertEqual(green, 60, accuracy: 14); XCTAssertEqual(blue, 40, accuracy: 14)
    }

    /// The fast encoder mode must still produce a stream the decoder accepts, in both colour layouts.
    func testFastEncodingStillDecodes() throws {
        for full in [false, true] {
            let encoder: HEVCEncoder
            do { encoder = try HEVCEncoder(width: width, height: height, fps: 60, bitrate: 40_000_000, chroma444: full, preferSpeed: true) }
            catch { throw XCTSkip("Hardware HEVC encoding is unavailable here: \(error.localizedDescription)") }
            let decoder = HEVCDecoder()
            let done = expectation(description: "decoded \(full)")
            var good = 0
            for index in 1...5 {
                encoder.encode(stripes(), sequence: UInt64(index), captureTime: monotonicNanos(), timestamp: CMTime(value: Int64(index), timescale: 60)) { encoded in
                    guard let frame = try? encoded.get() else { if index == 5 { done.fulfill() }; return }
                    try? decoder.decode(frame) { decoded in
                        if case .success = decoded { good += 1 }
                        if index == 5 { done.fulfill() }
                    }
                }
            }
            encoder.flush()
            wait(for: [done], timeout: 10)
            decoder.flush()
            XCTAssertEqual(good, 5)
            XCTAssertEqual(decoder.chroma444, full)
        }
    }

    func testAStreamDescribesItsOwnColourLayout() throws {
        let format = try HEVCDecoder.description(parameterSets: HEVCDecoder.sample444ParameterSets)
        XCTAssertEqual(HEVCDecoder.chromaFormat(of: format), 3)
        XCTAssertThrowsError(try HEVCDecoder.description(parameterSets: [Data([1]), Data()]))
        // This Mac's hardware decoder takes 4:4:4 (the iPad asks itself the same question before offering it).
        XCTAssertTrue(HEVCDecoder.canDecode444())
    }
}
#endif
