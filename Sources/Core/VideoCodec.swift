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
    /// With `chroma444` the session expects BGRA frames and keeps every pixel's colour (Main 4:4:4). The profile
    /// has no named constant in the SDK; it is one of the values the hardware encoder lists as supported, and
    /// creating the session fails cleanly on a Mac whose encoder does not have it.
    public static let main444Profile = "HEVC_Main444_AutoLevel"
    public let chroma444: Bool
    /// `preferSpeed` (build 39) asks the encoder for its fastest mode. Measured on an M4 Max at 2752 × 2064 with
    /// frames 62 ms apart, which is ordinary desktop use: 11.5 ms per frame instead of 16.8, with frames about
    /// twice the size (the stream is far below its bitrate limit then). With frames 17 ms apart it made no
    /// difference to either. The encoder otherwise spends the spare time between sparse frames on compression.
    public init(width: Int, height: Int, fps: Int, bitrate: Int, lowLatencyRateControl: Bool = false, chroma444: Bool = false,
                preferSpeed: Bool = false) throws {
        self.fps = fps; self.chroma444 = chroma444
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
            kVTCompressionPropertyKey_ProfileLevel: chroma444 ? Self.main444Profile as CFString : kVTProfileLevel_HEVC_Main_AutoLevel,
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
        // Set on its own: an encoder that does not know the option must not fail the whole configuration.
        if preferSpeed { VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue) }
        try checkVT(VTCompressionSessionPrepareToEncodeFrames(session), "Prepare HEVC encoder")
        var hardware: Unmanaged<CFTypeRef>?
        try checkVT(VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                          allocator: nil, valueOut: &hardware), "Verify hardware encoder")
        hardwareAccelerated = (hardware?.takeRetainedValue() as? Bool) == true
        guard hardwareAccelerated else { throw DeskError.invalid("Hardware HEVC encoding is unavailable.") }
    }
    public func encode(_ image: CVPixelBuffer, sequence: UInt64, captureTime: UInt64,
                       timestamp: CMTime, afterIdle: Bool = false, forceKeyframe: Bool = false, completion: @escaping (Result<VideoFrame, Error>) -> Void) {
        guard let session else { completion(.failure(DeskError.invalid("Encoder stopped."))); return }
        let properties = sequence == 1 || forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
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
    /// Changes the target bitrate of the running session; takes effect within a few frames, with no keyframe.
    @discardableResult
    public func setBitrate(_ bitrate: Int) -> Bool {
        guard let session else { return false }
        return VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate)) == noErr
    }
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
    /// True while the stream being decoded is 4:4:4.
    public private(set) var chroma444 = false
    public init(requireHardware: Bool = true) { self.requireHardware = requireHardware }
    /// Chroma layout of a stream, read from its own description: 1 = 4:2:0, 3 = 4:4:4 (nil when it cannot be read).
    public static func chromaFormat(of format: CMVideoFormatDescription) -> Int? {
        guard let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
              let record = atoms["hvcC"] as? Data, record.count > 16 else { return nil }
        return Int(record[record.startIndex + 16] & 3)
    }
    /// Builds the description of an HEVC stream from its VPS, SPS and PPS.
    public static func description(parameterSets sets: [Data]) throws -> CMVideoFormatDescription {
        guard sets.count == 3, sets.allSatisfy({ !$0.isEmpty }) else { throw DeskError.invalid("HEVC requires VPS, SPS, and PPS.") }
        var format: CMVideoFormatDescription?
        let sizes = sets.map(\.count)
        let status = sets[0].withUnsafeBytes { a in
            sets[1].withUnsafeBytes { b in
                sets[2].withUnsafeBytes { c in
                    let pointers = [a.bindMemory(to: UInt8.self).baseAddress!, b.bindMemory(to: UInt8.self).baseAddress!, c.bindMemory(to: UInt8.self).baseAddress!]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault,
                        parameterSetCount: 3, parameterSetPointers: pointers, parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
                }
            }
        }
        try checkVT(status, "Create HEVC format")
        guard let format else { throw DeskError.invalid("No HEVC format.") }
        return format
    }
    /// Parameter sets of a real 4:4:4 stream from an Apple hardware encoder, used only to ask this device whether
    /// its hardware decoder accepts 4:4:4 before offering it to the Mac.
    public static let sample444ParameterSets: [Data] = [
        "40010c01ffff240800000300be0800000300009c170240",
        "420101240800000300be0800000300009c90002b0400408b102f722c8a5ff973f89fd1",
        "4401c072f45364"
    ].map { text in
        var data = Data(); var index = text.startIndex
        while index < text.endIndex { let next = text.index(index, offsetBy: 2); data.append(UInt8(text[index..<next], radix: 16) ?? 0); index = next }
        return data
    }
    /// Whether a hardware decoder for 4:4:4 can be created here. Cheap; no frame is decoded.
    public static func canDecode444(requireHardware: Bool = true) -> Bool {
        guard let format = try? description(parameterSets: sample444ParameterSets), chromaFormat(of: format) == 3 else { return false }
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: requireHardware] as CFDictionary,
            imageBufferAttributes: outputAttributes(chroma444: true) as CFDictionary, outputCallback: nil, decompressionSessionOut: &session)
        guard status == noErr, let session else { return false }
        VTDecompressionSessionInvalidate(session)
        return true
    }
    /// The renderer draws two-plane video-range frames; for 4:4:4 the colour plane is simply full size.
    private static func outputAttributes(chroma444: Bool) -> [CFString: Any] {
        [kCVPixelBufferPixelFormatTypeKey: chroma444 ? kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
         kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    }
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
        let newFormat = try Self.description(parameterSets: sets)
        let dimensions = CMVideoFormatDescriptionGetDimensions(newFormat)
        guard dimensions.width > 0, dimensions.height > 0, dimensions.width <= 4096, dimensions.height <= 4096 else {
            throw DeskError.invalid("HEVC dimensions exceed the supported limit.")
        }
        let specification: [CFString: Any] = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: requireHardware]
        // The stream says what it is; a 4:4:4 stream decoded to 4:2:0 output would throw its extra detail away.
        let full = Self.chromaFormat(of: newFormat) == 3
        let attributes = Self.outputAttributes(chroma444: full)
        try checkVT(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: newFormat,
            decoderSpecification: specification as CFDictionary, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &session), "Create HEVC decoder")
        guard let session else { throw DeskError.invalid("No HEVC decoder.") }
        try checkVT(VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue), "Configure realtime decoder")
        var hardware: Unmanaged<CFTypeRef>?
        VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: &hardware)
        hardwareAccelerated = (hardware?.takeRetainedValue() as? Bool) == true
        format = newFormat; parameters = sets; chroma444 = full
    }
    public func flush() { if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) } }
    /// Drops the session so the next keyframe builds a new one. iPadOS may invalidate decoder sessions while the
    /// app is in the background, so this runs before video resumes.
    public func reset() {
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil; parameters = []
    }
    deinit { if let session { VTDecompressionSessionInvalidate(session) } }
}
