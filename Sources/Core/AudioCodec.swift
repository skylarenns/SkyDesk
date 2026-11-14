import Foundation
import AVFoundation

/// How the Mac's sound is sent (StreamFeature.audio, build 34): Opus, 48 kHz stereo, one packet every 10 ms.
public struct AudioStreamInfo: Codable, Equatable {
    public static let opus = "opus"
    public let codec: String
    public let sampleRate: Int
    public let channels: Int
    public let framesPerPacket: Int
    /// The encoder's set-up data, handed to the decoder unchanged.
    public let cookie: Data?
    public init(codec: String = AudioStreamInfo.opus, sampleRate: Int = 48_000, channels: Int = 2, framesPerPacket: Int = 480, cookie: Data? = nil) {
        self.codec = codec; self.sampleRate = sampleRate; self.channels = channels
        self.framesPerPacket = framesPerPacket; self.cookie = cookie
    }
    public var isValid: Bool {
        codec == Self.opus && sampleRate == 48_000 && channels == 2 && [120, 240, 480, 960].contains(framesPerPacket)
            && (cookie?.count ?? 0) <= 256
    }
    fileprivate func compressedFormat() throws -> AVAudioFormat {
        guard isValid else { throw DeskError.invalid("Unsupported sound format.") }
        var description = AudioStreamBasicDescription(mSampleRate: Double(sampleRate), mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(framesPerPacket), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        guard let format = AVAudioFormat(streamDescription: &description) else { throw DeskError.invalid("Opus sound is unavailable.") }
        return format
    }
}

/// One compressed packet on the audio channel: an 8-byte counter, then the Opus bytes.
public struct AudioPacket: Equatable {
    public static let maximumBytes = 4_000
    public let sequence: UInt64
    public let bytes: Data
    public init(sequence: UInt64, bytes: Data) { self.sequence = sequence; self.bytes = bytes }
    public func packet() -> WirePacket {
        var payload = Data(); payload.appendInteger(sequence); payload.append(bytes)
        return WirePacket(kind: .audio, payload: payload)
    }
    public init(packet: WirePacket) throws {
        guard packet.kind == .audio, packet.payload.count > 8, packet.payload.count <= Self.maximumBytes + 8 else {
            throw DeskError.invalid("Invalid sound packet.")
        }
        sequence = packet.payload.integer(at: 0, as: UInt64.self)
        bytes = packet.payload.subdata(in: packet.payload.startIndex + 8..<packet.payload.endIndex)
    }
}

/// Mac side. One caller at a time (the capture queue).
public final class OpusEncoder {
    public let info: AudioStreamInfo
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    /// `input` is whatever the Mac's audio system delivers (any sample rate, interleaved or not).
    public init(input: AVAudioFormat, bitrate: Int = 128_000, framesPerPacket: Int = 480) throws {
        let plain = AudioStreamInfo(framesPerPacket: framesPerPacket)
        output = try plain.compressedFormat()
        guard let converter = AVAudioConverter(from: input, to: output) else { throw DeskError.invalid("Can't compress this Mac's sound format.") }
        converter.bitRate = bitrate
        self.converter = converter
        info = AudioStreamInfo(framesPerPacket: framesPerPacket, cookie: converter.magicCookie)
    }
    /// Compresses `buffer` (copied, so the caller may reuse its memory) and returns the packets that are complete.
    public func encode(_ buffer: AVAudioPCMBuffer) throws -> [Data] {
        guard buffer.frameLength > 0, let copy = Self.copy(buffer) else { return [] }
        var pending: AVAudioPCMBuffer? = copy
        var packets: [Data] = []
        while true {
            let out = AVAudioCompressedBuffer(format: output, packetCapacity: 8, maximumPacketSize: max(converter.maximumOutputPacketSize, 1_500))
            var failure: NSError?
            let status = converter.convert(to: out, error: &failure) { _, state in
                if let next = pending { pending = nil; state.pointee = .haveData; return next }
                state.pointee = .noDataNow; return nil
            }
            if status == .error { throw failure ?? DeskError.invalid("Sound compression failed.") }
            if out.packetCount > 0, let descriptions = out.packetDescriptions {
                for index in 0..<Int(out.packetCount) {
                    let entry = descriptions[index]
                    guard entry.mDataByteSize > 0, Int(entry.mStartOffset) + Int(entry.mDataByteSize) <= Int(out.byteLength) else { continue }
                    packets.append(Data(bytes: out.data.advanced(by: Int(entry.mStartOffset)), count: Int(entry.mDataByteSize)))
                }
            }
            // Stop once the input is used up and the converter has nothing more ready.
            if pending == nil, out.packetCount < out.packetCapacity { break }
        }
        return packets
    }
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == target.count else { return nil }
        for index in 0..<source.count {
            guard let from = source[index].mData, let to = target[index].mData else { return nil }
            let bytes = min(source[index].mDataByteSize, target[index].mDataByteSize)
            memcpy(to, from, Int(bytes)); target[index].mDataByteSize = bytes
        }
        return copy
    }
}

/// iPad side. One caller at a time. Output: 32-bit float, 48 kHz stereo, one array per channel (what AVAudioEngine plays).
public final class OpusDecoder {
    public let format: AVAudioFormat
    private let input: AVAudioFormat
    private let converter: AVAudioConverter
    private let framesPerPacket: Int
    public init(info: AudioStreamInfo) throws {
        input = try info.compressedFormat()
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(info.sampleRate),
                                         channels: AVAudioChannelCount(info.channels), interleaved: false),
              let converter = AVAudioConverter(from: input, to: format) else { throw DeskError.invalid("This iPad can't play Opus sound.") }
        if let cookie = info.cookie, !cookie.isEmpty { converter.magicCookie = cookie }
        self.format = format; self.converter = converter; framesPerPacket = info.framesPerPacket
    }
    /// Returns nil when the packet produced no sound yet (the decoder's first packet may be shorter or empty).
    public func decode(_ packet: Data) throws -> AVAudioPCMBuffer? {
        guard !packet.isEmpty, packet.count <= AudioPacket.maximumBytes else { throw DeskError.invalid("Invalid sound packet.") }
        let compressed = AVAudioCompressedBuffer(format: input, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { compressed.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        compressed.byteLength = UInt32(packet.count); compressed.packetCount = 1
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                              mDataByteSize: UInt32(packet.count))
        guard let decoded = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(framesPerPacket * 2)) else {
            throw DeskError.invalid("No sound buffer.")
        }
        var given = false
        var failure: NSError?
        let status = converter.convert(to: decoded, error: &failure) { _, state in
            if given { state.pointee = .noDataNow; return nil }
            given = true; state.pointee = .haveData; return compressed
        }
        if status == .error { throw failure ?? DeskError.invalid("Sound decoding failed.") }
        return decoded.frameLength > 0 ? decoded : nil
    }
}

/// Decides how each arriving piece of sound is played so that it stays smooth without falling behind.
///
/// A little sound is kept waiting (the cushion) to ride out uneven arrival. If the player runs dry the cushion is
/// rebuilt, slightly larger each time up to a limit. If far too much is waiting (a burst after a network stall),
/// the backlog is thrown away rather than played late.
public struct AudioJitter: Equatable {
    public enum Action: Equatable {
        case play
        /// Start, or the player ran dry: lead with this much silence.
        case playAfterSilence(frames: Int)
        /// Too far behind: drop what is waiting, then start again.
        case flushThenPlayAfterSilence(frames: Int)
    }
    public private(set) var cushion: Int
    public let largestCushion: Int
    public let step: Int
    public let limit: Int
    public private(set) var underruns = 0
    public private(set) var flushes = 0
    private var started = false
    public init(sampleRate: Int = 48_000, cushionMS: Int = 30, largestCushionMS: Int = 100, limitMS: Int = 220) {
        cushion = sampleRate * cushionMS / 1_000; largestCushion = sampleRate * largestCushionMS / 1_000
        step = sampleRate / 100; limit = sampleRate * limitMS / 1_000
    }
    /// `waiting`: frames scheduled but not yet played when the new piece arrives.
    public mutating func next(waiting: Int) -> Action {
        if !started { started = true; return .playAfterSilence(frames: cushion) }
        if waiting <= 0 {
            underruns += 1
            cushion = min(largestCushion, cushion + step)
            return .playAfterSilence(frames: cushion)
        }
        if waiting > limit { flushes += 1; return .flushThenPlayAfterSilence(frames: cushion) }
        return .play
    }
    public mutating func restart() { started = false }
}
