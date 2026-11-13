import XCTest
import CoreVideo
import Metal
@testable import SkyDeskCore

final class YUVMetalRendererTests: XCTestCase {
    /// 64 × 32 video-range BT.709 frame: left half white, right half pure red, top-left 8 × 8 block black.
    private func frame() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           attributes as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let luma = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        for y in 0..<32 { for x in 0..<64 { luma[y * lumaStride + x] = x < 8 && y < 8 ? 16 : x < 32 ? 235 : 63 } }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(pixels, 1)!.assumingMemoryBound(to: UInt8.self)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1)
        for y in 0..<16 { for x in 0..<32 {
            chroma[y * chromaStride + x * 2] = x < 16 ? 128 : 102
            chroma[y * chromaStride + x * 2 + 1] = x < 16 ? 128 : 240
        } }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    private func render(destination: CGRect, size: (Int, Int), sharpen: Float) throws -> (Int, Int) -> [UInt8] {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device.") }
        let renderer = try YUVMetalRenderer(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size.0, height: size.1, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = target
        let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        XCTAssertTrue(renderer.encode(try frame(), pass: pass, commandBuffer: command, destination: destination, sharpen: sharpen))
        command.commit(); command.waitUntilCompleted()
        XCTAssertNil(command.error)
        var bytes = [UInt8](repeating: 0, count: size.0 * size.1 * 4)
        target.getBytes(&bytes, bytesPerRow: size.0 * 4, from: MTLRegionMake2D(0, 0, size.0, size.1), mipmapLevel: 0)
        return { x, y in let o = (y * size.0 + x) * 4; return [bytes[o + 2], bytes[o + 1], bytes[o]] }  // RGB
    }
    private func assertColor(_ value: [UInt8], _ expected: [Int], _ message: String, line: UInt = #line) {
        for (a, b) in zip(value, expected) { XCTAssertLessThanOrEqual(abs(Int(a) - b), 4, "\(message): \(value)", line: line) }
    }

    func testOneToOneFrameKeepsColoursAndOrientation() throws {
        let pixel = try render(destination: CGRect(x: 0, y: 0, width: 64, height: 32), size: (64, 32), sharpen: 0)
        assertColor(pixel(3, 3), [0, 0, 0], "top-left block is black (image is not flipped)")
        assertColor(pixel(3, 28), [255, 255, 255], "bottom-left is white")
        assertColor(pixel(20, 16), [255, 255, 255], "left half is white")
        assertColor(pixel(50, 16), [255, 0, 0], "right half is BT.709 red")
    }

    func testDestinationRectPlacesTheFrameAndLeavesBlackBars() throws {
        // Target twice as tall; frame shifted up by 8 px as the keyboard viewport does, partly off-target.
        let pixel = try render(destination: CGRect(x: 0, y: -8, width: 64, height: 32), size: (64, 64), sharpen: 0)
        assertColor(pixel(20, 4), [255, 255, 255], "frame row 12 shows at target row 4")
        assertColor(pixel(50, 20), [255, 0, 0], "red half inside the frame")
        assertColor(pixel(20, 40), [0, 0, 0], "below the frame is black")
        assertColor(pixel(50, 60), [0, 0, 0], "below the frame is black")
    }

    func testSharpeningLeavesFlatAreasUntouched() throws {
        let pixel = try render(destination: CGRect(x: 0, y: 0, width: 64, height: 32), size: (64, 32), sharpen: 0.12)
        assertColor(pixel(20, 20), [255, 255, 255], "flat white stays white")
        assertColor(pixel(50, 20), [255, 0, 0], "flat red stays red")
    }
}
