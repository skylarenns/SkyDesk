import Foundation
import CoreGraphics
import CoreVideo
import Metal

/// Draws a decoded 4:2:0 video-range BT.709 frame straight to a Metal target: one textured quad, no intermediate images.
/// The previous Core Image path cost roughly 20 ms per frame on the iPad's main thread, which capped the stream near 50 FPS.
public final class YUVMetalRenderer {
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var cache: CVMetalTextureCache?

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position [[position]]; float2 uv; };
    vertex Vertex skydesk_vertex(uint id [[vertex_id]]) {
        float2 corner = float2(float(id & 1), float(id >> 1));
        Vertex out;
        out.position = float4(corner.x * 2.0 - 1.0, 1.0 - corner.y * 2.0, 0.0, 1.0);
        out.uv = corner;
        return out;
    }
    fragment float4 skydesk_fragment(Vertex in [[stage_in]], texture2d<float> luma [[texture(0)]],
                                     texture2d<float> chroma [[texture(1)]], sampler s [[sampler(0)]],
                                     constant float &sharpen [[buffer(0)]]) {
        float y = luma.sample(s, in.uv).r;
        if (sharpen > 0.0) {
            float2 texel = float2(1.0 / float(luma.get_width()), 1.0 / float(luma.get_height()));
            float around = luma.sample(s, in.uv + float2(texel.x, 0.0)).r + luma.sample(s, in.uv - float2(texel.x, 0.0)).r
                         + luma.sample(s, in.uv + float2(0.0, texel.y)).r + luma.sample(s, in.uv - float2(0.0, texel.y)).r;
            y += sharpen * (y - around * 0.25);
        }
        float2 c = chroma.sample(s, in.uv).rg;
        float l = (y - 16.0 / 255.0) * (255.0 / 219.0);
        float cb = (c.r - 128.0 / 255.0) * (255.0 / 224.0);
        float cr = (c.g - 128.0 / 255.0) * (255.0 / 224.0);
        float3 rgb = float3(l + 1.5748 * cr, l - 0.1873 * cb - 0.4681 * cr, l + 1.8556 * cb);
        return float4(saturate(rgb), 1.0);
    }
    """

    public init(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        let library = try device.makeLibrary(source: Self.source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "skydesk_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "skydesk_fragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let sampling = MTLSamplerDescriptor()
        sampling.minFilter = .linear; sampling.magFilter = .linear
        sampling.sAddressMode = .clampToEdge; sampling.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sampling) else { throw DeskError.invalid("Metal sampler unavailable.") }
        self.sampler = sampler
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, cache != nil else {
            throw DeskError.invalid("Metal texture cache unavailable.")
        }
    }

    /// Clears the target to black and draws `pixels` into `destination` (target pixels, top-left origin; may extend off-target).
    /// Returns false, encoding nothing, when the frame cannot be mapped to textures.
    public func encode(_ pixels: CVPixelBuffer, pass: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer,
                       destination: CGRect, sharpen: Float) -> Bool {
        guard let cache, CVPixelBufferGetPlaneCount(pixels) == 2, destination.width >= 1, destination.height >= 1,
              let luma = texture(pixels, plane: 0, format: .r8Unorm, cache: cache),
              let chroma = texture(pixels, plane: 1, format: .rg8Unorm, cache: cache),
              let lumaTexture = CVMetalTextureGetTexture(luma), let chromaTexture = CVMetalTextureGetTexture(chroma) else { return false }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encoder.setRenderPipelineState(pipeline)
        encoder.setViewport(MTLViewport(originX: Double(destination.minX), originY: Double(destination.minY),
                                        width: Double(destination.width), height: Double(destination.height), znear: 0, zfar: 1))
        encoder.setFragmentTexture(lumaTexture, index: 0)
        encoder.setFragmentTexture(chromaTexture, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        var amount = max(0, sharpen)
        encoder.setFragmentBytes(&amount, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        // The wrappers must outlive GPU use of their textures.
        commandBuffer.addCompletedHandler { _ in _ = (luma, chroma, pixels) }
        return true
    }

    private func texture(_ pixels: CVPixelBuffer, plane: Int, format: MTLPixelFormat, cache: CVMetalTextureCache) -> CVMetalTexture? {
        var result: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixels, nil, format,
            CVPixelBufferGetWidthOfPlane(pixels, plane), CVPixelBufferGetHeightOfPlane(pixels, plane), plane, &result)
        return status == kCVReturnSuccess ? result : nil
    }
}
