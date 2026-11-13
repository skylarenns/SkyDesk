import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

// Encoder/decoder throughput probe: synthetic scrolling text-like content, native iPad resolution.
func nanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
let args = CommandLine.arguments
func opt(_ n: String, _ d: Int) -> Int { if let i = args.firstIndex(of: n), i + 1 < args.count { return Int(args[i+1]) ?? d }; return d }
let width = opt("--width", 2752), height = opt("--height", 2064), fps = opt("--fps", 120)
let bitrate = opt("--mbps", 25) * 1_000_000, seconds = opt("--seconds", 3), step = opt("--step", 24)
let lowLatency = args.contains("--low-latency"), speed = args.contains("--speed"), paced = !args.contains("--unpaced")
let inflight = opt("--inflight", 4)

// Text-like luma: rows of dark glyph blocks on light background, period 384 rows.
let period = 384
var rng = SystemRandomNumberGenerator()
var tile = [UInt8](repeating: 235, count: width * period)
for line in 0..<(period / 24) {
    var x = 40
    while x < width - 60 {
        let w = Int.random(in: 4...14, using: &rng)
        if Int.random(in: 0..<6, using: &rng) != 0 {
            for y in (line * 24 + 5)..<(line * 24 + 19) {
                for xx in x..<(x + w) where (xx + y) % 3 != 0 { tile[y * width + xx] = UInt8.random(in: 20...60, using: &rng) }
            }
        }
        x += w + Int.random(in: 2...6, using: &rng)
    }
}
func makeFrame(offset: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
    let b = pb!
    CVPixelBufferLockBaseAddress(b, [])
    let y = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
    let ys = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
    tile.withUnsafeBufferPointer { t in
        for row in 0..<height { memcpy(y + row * ys, t.baseAddress! + ((row + offset) % period) * width, width) }
    }
    let c = CVPixelBufferGetBaseAddressOfPlane(b, 1)!
    memset(c, 128, CVPixelBufferGetBytesPerRowOfPlane(b, 1) * (height / 2))
    CVPixelBufferUnlockBaseAddress(b, [])
    return b
}
let count = step == 0 ? 1 : period / step
let frames = (0..<count).map { makeFrame(offset: $0 * step) }

var session: VTCompressionSession?
var spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
precondition(VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_HEVC,
    encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
    outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr)
var props: [CFString: Any] = [
    kVTCompressionPropertyKey_RealTime: true, kVTCompressionPropertyKey_AllowFrameReordering: false,
    kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_HEVC_Main_AutoLevel,
    kVTCompressionPropertyKey_AverageBitRate: bitrate, kVTCompressionPropertyKey_ExpectedFrameRate: fps,
    kVTCompressionPropertyKey_MaxKeyFrameInterval: opt("--gop", fps), kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: opt("--gopsec", 1),
    kVTCompressionPropertyKey_MaxFrameDelayCount: 1]
if speed { props[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality] = true }
if args.contains("--no-delaycount") { props.removeValue(forKey: kVTCompressionPropertyKey_MaxFrameDelayCount) }
for (k, v) in props {
    let s = VTSessionSetProperty(session!, key: k, value: v as CFTypeRef)
    if s != noErr { print("property \(k) rejected: \(s)") }
}
VTCompressionSessionPrepareToEncodeFrames(session!)

let lock = NSLock()
var lat: [Double] = [], sizes: [Int] = [], keySizes: [Int] = [], doneTimes: [UInt64] = []
var samples: [CMSampleBuffer] = []
let slots = DispatchSemaphore(value: inflight)
let total = fps * seconds
var submitted = 0, skipped = 0
let start = nanos()
let interval = 1_000_000_000 / UInt64(fps)
for i in 0..<total {
    if paced {
        let due = start + UInt64(i) * interval
        let n = nanos(); if due > n { usleep(UInt32((due - n) / 1000)) }
        if slots.wait(timeout: .now()) != .success { skipped += 1; continue }
    } else { slots.wait() }
    let t0 = nanos(); submitted += 1
    VTCompressionSessionEncodeFrame(session!, imageBuffer: frames[i % count], presentationTimeStamp: CMTime(value: Int64(i), timescale: Int32(fps)),
        duration: CMTime(value: 1, timescale: Int32(fps)), frameProperties: nil, infoFlagsOut: nil) { status, flags, sample in
        let t1 = nanos()
        lock.lock()
        if status == noErr, let sample, !flags.contains(.frameDropped) {
            lat.append(Double(t1 - t0) / 1e6); doneTimes.append(t1)
            let size = CMBlockBufferGetDataLength(CMSampleBufferGetDataBuffer(sample)!)
            let att = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            if (att?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true { keySizes.append(size) } else { sizes.append(size) }
            samples.append(sample)
        } else { print("encode failure \(status) \(flags)") }
        lock.unlock(); slots.signal()
    }
}
VTCompressionSessionCompleteFrames(session!, untilPresentationTimeStamp: .invalid)
let elapsed = Double(nanos() - start) / 1e9
func pct(_ v: [Double], _ p: Double) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int((Double(s.count) * p).rounded(.up)) - 1 < 0 ? 0 : Int((Double(s.count) * p).rounded(.up)) - 1)] }
let avgP = sizes.isEmpty ? 0 : sizes.reduce(0, +) / sizes.count
let avgK = keySizes.isEmpty ? 0 : keySizes.reduce(0, +) / keySizes.count
print(String(format: "ENC %dx%d %s fps=%d mbps=%d step=%d ll=%d speed=%d inflight=%d | submitted %d skipped %d out %d in %.2fs = %.1f FPS | latency ms p50 %.2f p95 %.2f p99 %.2f max %.2f | P avg %d B, key avg %d B (%d keys), actual %.1f Mbps",
    width, height, (paced ? "paced" : "unpaced" as NSString).utf8String!, fps, bitrate / 1_000_000, step, lowLatency ? 1 : 0, speed ? 1 : 0, inflight,
    submitted, skipped, lat.count, elapsed, Double(lat.count) / elapsed, pct(lat, 0.5), pct(lat, 0.95), pct(lat, 0.99), lat.max() ?? 0,
    avgP, avgK, keySizes.count, Double(sizes.reduce(0, +) + keySizes.reduce(0, +)) * 8 / elapsed / 1e6))

// Decode throughput of the produced stream on this Mac (proxy only, not the iPad).
if args.contains("--decode"), let first = samples.first, let format = CMSampleBufferGetFormatDescription(first) {
    var dsession: VTDecompressionSession?
    let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelBufferIOSurfacePropertiesKey: [:]]
    precondition(VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
        decoderSpecification: [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary,
        imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &dsession) == noErr)
    VTSessionSetProperty(dsession!, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    var dl: [Double] = []
    let dslots = DispatchSemaphore(value: 4)
    let d0 = nanos()
    for s in samples {
        dslots.wait(); let t0 = nanos()
        VTDecompressionSessionDecodeFrame(dsession!, sampleBuffer: s, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { st, _, img, _, _ in
            lock.lock(); if st == noErr, img != nil { dl.append(Double(nanos() - t0) / 1e6) }; lock.unlock(); dslots.signal()
        }
    }
    VTDecompressionSessionWaitForAsynchronousFrames(dsession!)
    let de = Double(nanos() - d0) / 1e9
    print(String(format: "DEC unpaced %d frames in %.2fs = %.1f FPS | latency ms p50 %.2f p95 %.2f p99 %.2f", dl.count, de, Double(dl.count) / de, pct(dl, 0.5), pct(dl, 0.95), pct(dl, 0.99)))
}
