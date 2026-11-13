import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

private func checkVT(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw DeskError.system(operation, status) }
}

#if os(macOS)
/// Called on the capture queue; output callbacks may arrive on a VideoToolbox queue.
public final class HEVCEncoder {
    private var session: VTCompressionSession?
    public private(set) var hardwareAccelerated = false
    public let fps: Int
    public init(width: Int, height: Int, fps: Int, bitrate: Int, lowLatencyRateControl: Bool = false) throws {
        self.fps = fps
        var specification: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        if lowLatencyRateControl { specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        try checkVT(VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_HEVC, encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil,
            refcon: nil, compressionSessionOut: &session), "Create hardware HEVC encoder")
        guard let session else { throw DeskError.invalid("No HEVC encoder.") }
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_HEVC_Main_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            // The transport is lossless and a session starts with a forced keyframe, so periodic keyframes
            // would only add megabyte bursts (measured ~1.4–1.9 MB at 2752 × 2064) that stall the stream.
            kVTCompressionPropertyKey_MaxKeyFrameInterval: fps * 3_600,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 3_600,
            kVTCompressionPropertyKey_MaxFrameDelayCount: 1,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        ]
        try checkVT(VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary), "Configure HEVC encoder")
        try checkVT(VTCompressionSessionPrepareToEncodeFrames(session), "Prepare HEVC encoder")
        var hardware: Unmanaged<CFTypeRef>?
        try checkVT(VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                          allocator: nil, valueOut: &hardware), "Verify hardware encoder")
        hardwareAccelerated = (hardware?.takeRetainedValue() as? Bool) == true
        guard hardwareAccelerated else { throw DeskError.invalid("Hardware HEVC encoding is unavailable.") }
    }
    public func encode(_ image: CVPixelBuffer, sequence: UInt64, captureTime: UInt64,
                       timestamp: CMTime, afterIdle: Bool = false, completion: @escaping (Result<VideoFrame, Error>) -> Void) {
        guard let session else { completion(.failure(DeskError.invalid("Encoder stopped."))); return }
        let properties = sequence == 1 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: image, presentationTimeStamp: timestamp,
            duration: CMTime(value: 1, timescale: CMTimeScale(fps)), frameProperties: properties, infoFlagsOut: nil) { status, flags, sample in
                do {
                    try checkVT(status, "Encode frame")
                    guard !flags.contains(.frameDropped), let sample else { throw DeskError.invalid("Encoder dropped a frame.") }
                    completion(.success(try Self.packet(sample, sequence: sequence, captureTime: captureTime, afterIdle: afterIdle)))
                } catch { completion(.failure(error)) }
            }
        if status != noErr { completion(.failure(DeskError.system("Submit frame for encoding", status))) }
    }
    public func flush() { if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) } }
    private static func packet(_ sample: CMSampleBuffer, sequence: UInt64, captureTime: UInt64, afterIdle: Bool) throws -> VideoFrame {
        guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else {
            throw DeskError.invalid("Encoder returned an empty frame.")
        }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        var parameters: [Data] = []
        if keyframe {
            for index in 0..<3 {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                try checkVT(CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil), "Read HEVC parameters")
                guard let pointer else { throw DeskError.invalid("Missing HEVC parameter set.") }
                parameters.append(Data(bytes: pointer, count: size))
            }
        }
        var bytes = Data(count: CMBlockBufferGetDataLength(block))
        try bytes.withUnsafeMutableBytes { storage in
            try checkVT(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: storage.count, destination: storage.baseAddress!), "Copy encoded frame")
        }
        return VideoFrame(sequence: sequence, captureTime: captureTime, encodeTime: monotonicNanos(),
                          keyframe: keyframe, afterIdle: afterIdle, parameterSets: parameters, bytes: bytes)
    }
    deinit { if let session { VTCompressionSessionInvalidate(session) } }
}
#endif

/// Serial caller. HEVC dependencies are decoded in order; only the renderer may replace decoded images.
public final class HEVCDecoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var parameters: [Data] = []
    private let requireHardware: Bool
    public private(set) var hardwareAccelerated = false
    public init(requireHardware: Bool = true) { self.requireHardware = requireHardware }
    public func decode(_ frame: VideoFrame, completion: @escaping (Result<CVPixelBuffer, Error>) -> Void) throws {
        if frame.keyframe, frame.parameterSets != parameters {
            try configure(frame.parameterSets)
        }
        guard let session, let format else { throw DeskError.invalid("Video arrived before its HEVC keyframe.") }
        var block: CMBlockBuffer?
        try checkVT(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: frame.bytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: frame.bytes.count, flags: 0, blockBufferOut: &block), "Allocate decode buffer")
        guard let block else { throw DeskError.invalid("No decode buffer.") }
        try frame.bytes.withUnsafeBytes { bytes in
            try checkVT(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: bytes.count), "Copy decode buffer")
        }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(clamping: frame.captureTime), timescale: 1_000_000_000), decodeTimeStamp: .invalid)
        var size = frame.bytes.count
        var sample: CMSampleBuffer?
        try checkVT(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), "Create compressed sample")
        guard let sample else { throw DeskError.invalid("No compressed sample.") }
        try checkVT(VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr, let image { completion(.success(image)) }
            else { completion(.failure(DeskError.system("Decode HEVC frame", status))) }
        }, "Submit frame for decoding")
    }
    private func configure(_ sets: [Data]) throws {
        guard sets.count == 3 else { throw DeskError.invalid("HEVC requires VPS, SPS, and PPS.") }
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) }
        session = nil
        var newFormat: CMVideoFormatDescription?
        let sizes = sets.map(\.count)
        let status = sets[0].withUnsafeBytes { a in
            sets[1].withUnsafeBytes { b in
                sets[2].withUnsafeBytes { c in
                    let pointers = [a.bindMemory(to: UInt8.self).baseAddress!, b.bindMemory(to: UInt8.self).baseAddress!, c.bindMemory(to: UInt8.self).baseAddress!]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault,
                        parameterSetCount: 3, parameterSetPointers: pointers, parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &newFormat)
                }
            }
        }
        try checkVT(status, "Create HEVC format")
        guard let newFormat else { throw DeskError.invalid("No HEVC format.") }
        let dimensions = CMVideoFormatDescriptionGetDimensions(newFormat)
        guard dimensions.width > 0, dimensions.height > 0, dimensions.width <= 4096, dimensions.height <= 4096 else {
            throw DeskError.invalid("HEVC dimensions exceed the supported limit.")
        }
        let specification: [CFString: Any] = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: requireHardware]
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                          kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
        try checkVT(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: newFormat,
            decoderSpecification: specification as CFDictionary, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &session), "Create HEVC decoder")
        guard let session else { throw DeskError.invalid("No HEVC decoder.") }
        try checkVT(VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue), "Configure realtime decoder")
        var hardware: Unmanaged<CFTypeRef>?
        VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: &hardware)
        hardwareAccelerated = (hardware?.takeRetainedValue() as? Bool) == true
        format = newFormat; parameters = sets
    }
    public func flush() { if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) } }
    deinit { if let session { VTDecompressionSessionInvalidate(session) } }
}
