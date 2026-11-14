import Foundation
import CoreGraphics

public enum DeskError: Error, LocalizedError, Equatable {
    case invalid(String)
    case system(String, Int32)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .system(let operation, let status): return "\(operation) failed (\(status))."
        }
    }
}

/// `file` (chunks of a file transfer) only ever travels on the file channel, opened when both sides list
/// StreamFeature.fileTransfer; older builds never see it.
public enum WireKind: UInt8 { case control = 1, video = 2, file = 3 }

public struct WirePacket {
    public let kind: WireKind
    public let payload: Data
    public init(kind: WireKind, payload: Data) { self.kind = kind; self.payload = payload }
    public func encoded() throws -> Data {
        guard !payload.isEmpty, payload.count <= WireParser.limit(kind) else {
            throw DeskError.invalid("Packet exceeds the protocol limit.")
        }
        var data = Data([0x53, 0x4b, 0x59, 0x44, 1, kind.rawValue, 0, 0])
        data.appendInteger(UInt32(payload.count))
        data.append(payload)
        return data
    }
    public static func control(_ message: ControlMessage) throws -> WirePacket {
        WirePacket(kind: .control, payload: try JSONEncoder().encode(message))
    }
    public func controlMessage() throws -> ControlMessage {
        guard kind == .control else { throw DeskError.invalid("Expected a control packet.") }
        return try JSONDecoder().decode(ControlMessage.self, from: payload)
    }
}

/// Incremental framing; reject the length before allocating or waiting for a body.
public struct WireParser {
    private var buffer = Data()
    public init() {}
    public static func limit(_ kind: WireKind) -> Int {
        switch kind {
        case .video: return 8 * 1_024 * 1_024
        case .file: return FileSender.chunkSize + 64
        case .control: return 64 * 1_024
        }
    }
    public mutating func append(_ data: Data) throws -> [WirePacket] {
        guard data.count <= 64 * 1_024 else { throw DeskError.invalid("Receive chunk too large.") }
        buffer.append(data)
        var packets: [WirePacket] = []
        var offset = 0
        while buffer.count - offset >= 12 {
            let h = buffer.startIndex + offset
            guard Array(buffer[h..<h + 5]) == [0x53, 0x4b, 0x59, 0x44, 1],
                  let kind = WireKind(rawValue: buffer[h + 5]),
                  buffer[h + 6] == 0, buffer[h + 7] == 0 else {
                throw DeskError.invalid("Unsupported SkyDesk protocol header.")
            }
            let length = Int(buffer.integer(at: offset + 8, as: UInt32.self))
            guard length > 0, length <= Self.limit(kind) else {
                throw DeskError.invalid("Invalid packet length.")
            }
            guard buffer.count - offset >= 12 + length else { break }
            packets.append(WirePacket(kind: kind, payload: buffer.subdata(in: h + 12..<h + 12 + length)))
            offset += 12 + length
        }
        if offset > 0 { buffer = Data(buffer.dropFirst(offset)) }
        return packets
    }
}

/// Optional capabilities; absent on older builds. A host uses a feature only when the client offered it.
public enum StreamFeature {
    /// Video frames mark the first frame after the Mac screen stopped changing, so pauses are not counted as stutter.
    public static let idleGapFlags = 1
    /// The host accepts a once-a-second `clientStats` summary and writes it beside its own figures.
    public static let clientStatsLog = 2
    /// The iPad draws the pointer itself: the host leaves it out of the video and sends `cursor` when its image changes.
    public static let localCursor = 4
    /// The iPad may send `pauseVideo` while it is in the background; on resume the host restarts with a keyframe.
    public static let pauseVideo = 8
    /// The iPad may switch the local pointer on and off during a session with `setLocalCursor`.
    public static let liveCursorToggle = 16
    /// Both sides send clipboard text on their own when it changes (`clipboard`), up to ClipboardSync.maxBytes.
    public static let clipboardSync = 32
    /// The iPad opens a third channel (Hello.Role.files) carrying `file` events and `.file` chunks.
    public static let fileTransfer = 64
    /// The iPad sends `scrollMomentum` when the fingers lift; the Mac generates the glide locally.
    public static let scrollMomentum = 128
    /// The Mac offers staged updates (`updateAvailable`) and installs them over Wi-Fi on request.
    public static let remoteUpdate = 256
    /// The iPad sends `gesture` (pinch to zoom, rotate) and the Mac replays it as a trackpad gesture.
    public static let gestures = 512
}

public struct Hello: Codable {
    public enum Role: String, Codable { case control, video, files }
    public let session: UUID
    public let role: Role
    public let display: ClientDisplay?
    public let features: Int?
    /// The iPad app's build number (CFBundleVersion), so the Mac knows whether its staged update is newer.
    public let appBuild: Int?
    public init(session: UUID, role: Role, display: ClientDisplay? = nil, features: Int? = nil, appBuild: Int? = nil) {
        self.session = session; self.role = role; self.display = display; self.features = features; self.appBuild = appBuild
    }
}

public struct ClientDisplay: Codable, Equatable {
    public let width: Int
    public let height: Int
    public let maximumFPS: Int
    public init(width: Int, height: Int, maximumFPS: Int) {
        self.width = width; self.height = height; self.maximumFPS = maximumFPS
    }
    public func validate() throws {
        guard (640...4096).contains(width), (640...4096).contains(height),
              width % 2 == 0, height % 2 == 0, (30...120).contains(maximumFPS) else {
            throw DeskError.invalid("Unsupported iPad display dimensions.")
        }
    }
}

public struct RemoteTextFocus: Codable, Equatable {
    public let id: UInt64
    public let rect: CGRect?
    public let secure: Bool
    public static let none = RemoteTextFocus(id: 0, rect: nil, secure: false)
    public init(id: UInt64, rect: CGRect?, secure: Bool) { self.id = id; self.rect = rect; self.secure = secure }
    public var isValid: Bool {
        guard let rect else { return true }
        return [rect.minX, rect.minY, rect.width, rect.height].allSatisfy { $0.isFinite && (0...1).contains($0) }
            && rect.maxX <= 1.001 && rect.maxY <= 1.001
    }
}

/// The Mac pointer's image. Sizes are fractions of the streamed desktop; the hot spot is a fraction of the image.
public struct RemoteCursor: Codable, Equatable {
    public let png: Data
    public let width: Double
    public let height: Double
    public let hotX: Double
    public let hotY: Double
    public init(png: Data, width: Double, height: Double, hotX: Double, hotY: Double) {
        self.png = png; self.width = width; self.height = height; self.hotX = hotX; self.hotY = hotY
    }
    public var isValid: Bool {
        !png.isEmpty && png.count <= 40_000 && [width, height, hotX, hotY].allSatisfy { $0.isFinite }
            && width > 0 && width <= 0.25 && height > 0 && height <= 0.25 && (0...1).contains(hotX) && (0...1).contains(hotY)
    }
}

public struct StreamInfo: Codable {
    public let width: Int
    public let height: Int
    public let fps: Int
    public let bitrate: Int
    public let displayName: String
    public let inputEnabled: Bool
    public let textInputEnabled: Bool?
    public let displayBlankingSupported: Bool?
    public let features: Int?
    /// The Mac's name, shown in the iPad's recent list. Absent from older hosts.
    public let hostName: String?
    public init(width: Int, height: Int, fps: Int, bitrate: Int, displayName: String, inputEnabled: Bool,
                textInputEnabled: Bool? = nil, displayBlankingSupported: Bool? = nil, features: Int? = nil, hostName: String? = nil) {
        self.width = width; self.height = height; self.fps = fps; self.bitrate = bitrate
        self.displayName = displayName; self.inputEnabled = inputEnabled; self.textInputEnabled = textInputEnabled
        self.displayBlankingSupported = displayBlankingSupported; self.features = features
        self.hostName = hostName.map { String($0.prefix(64)) }
    }
    public func validate() throws {
        guard (2...4096).contains(width), (2...4096).contains(height),
              width % 2 == 0, height % 2 == 0, [30, 60, 120].contains(fps),
              (1_000_000...100_000_000).contains(bitrate) else {
            throw DeskError.invalid("Unsupported stream configuration.")
        }
    }
}

public struct InputEvent: Codable, Equatable {
    public enum Kind: String, Codable { case move, down, up, scroll, key }
    public var kind: Kind
    public var x: Double = 0
    public var y: Double = 0
    public var button: Int = 0
    public var keyCode: Int = 0 // USB HID usage, translated to a macOS virtual key by the host.
    public var isDown: Bool = false
    public var modifiers: UInt = 0 // SkyDesk: shift=1, control=2, option=4, command=8, capsLock=16.
    /// Scroll only: ScrollPhase. Optional, so older hosts simply ignore it.
    public var phase: Int? = nil
    public init(kind: Kind, x: Double = 0, y: Double = 0, button: Int = 0,
                keyCode: Int = 0, isDown: Bool = false, modifiers: UInt = 0, phase: Int? = nil) {
        self.kind = kind; self.x = x; self.y = y; self.button = button
        self.keyCode = keyCode; self.isDown = isDown; self.modifiers = modifiers; self.phase = phase
    }
    public var isValid: Bool {
        guard x.isFinite, y.isFinite, (0...2).contains(button), (phase ?? 1) >= 1, (phase ?? 1) <= 3,
              (0...255).contains(keyCode), modifiers & ~31 == 0 else { return false }
        switch kind {
        case .move, .down, .up: return (0...1).contains(x) && (0...1).contains(y)
        case .scroll: return abs(x) <= 2_000 && abs(y) <= 2_000
        case .key: return true
        }
    }
}

public enum ControlMessage: Codable {
    case hello(Hello)
    case welcome(StreamInfo)
    case input(InputEvent)
    case releaseInput
    case clipboard(String)
    case clipboardRequest
    case ping(UInt64)
    case pong(UInt64)
    case frameAck(UInt64)
    case clientStats(String)
    case text(String)
    case textFocus(RemoteTextFocus)
    case setMacDisplayBlanked(Bool)
    case macDisplayBlanked(Bool)
    case cursor(RemoteCursor)
    case failure(String)
    /// iPad → Mac, only when both sides list StreamFeature.pauseVideo.
    case pauseVideo(Bool)
    /// iPad → Mac, only with StreamFeature.liveCursorToggle: true = iPad draws the pointer, Mac hides it in the video.
    case setLocalCursor(Bool)
    /// File channel only, with StreamFeature.fileTransfer.
    case file(FileEvent)
    /// iPad → Mac, only with StreamFeature.scrollMomentum: lift-off velocity in points per second (x, y).
    case scrollMomentum(Double, Double)
    /// Mac → iPad (StreamFeature.remoteUpdate): build number of a newer staged iPad app.
    case updateAvailable(Int)
    /// iPad → Mac: start serving the update. Answered by `updateReady` (HTTPS manifest URL) or `failure`.
    case updateRequest
    case updateReady(String)
    /// iPad → Mac: send the update certificate profile (arrives over the file channel).
    case updateCertificateRequest
    /// iPad → Mac, only with StreamFeature.gestures.
    case gesture(GestureEvent)
}

public struct VideoFrame {
    public let sequence: UInt64
    public let captureTime: UInt64
    public let encodeTime: UInt64
    public let keyframe: Bool
    /// The Mac screen had stopped changing before this frame (StreamFeature.idleGapFlags). Sent only when negotiated.
    public let afterIdle: Bool
    public let parameterSets: [Data]
    public let bytes: Data
    public init(sequence: UInt64, captureTime: UInt64, encodeTime: UInt64,
                keyframe: Bool, afterIdle: Bool = false, parameterSets: [Data], bytes: Data) {
        self.sequence = sequence; self.captureTime = captureTime; self.encodeTime = encodeTime
        self.keyframe = keyframe; self.afterIdle = afterIdle; self.parameterSets = parameterSets; self.bytes = bytes
    }
    public func encoded() throws -> Data {
        guard parameterSets.count <= 3, !bytes.isEmpty else { throw DeskError.invalid("Invalid video frame.") }
        var data = Data()
        data.appendInteger(sequence); data.appendInteger(captureTime); data.appendInteger(encodeTime)
        data.append((keyframe ? 1 : 0) | (afterIdle ? 2 : 0)); data.append(UInt8(parameterSets.count))
        for parameter in parameterSets {
            guard !parameter.isEmpty, parameter.count <= 65536 else { throw DeskError.invalid("Invalid HEVC parameters.") }
            data.appendInteger(UInt32(parameter.count)); data.append(parameter)
        }
        data.append(bytes)
        guard data.count <= WireParser.limit(.video) else { throw DeskError.invalid("Video frame too large.") }
        return data
    }
    public init(data: Data) throws {
        guard data.count >= 27, data.count <= WireParser.limit(.video), data[24] <= 3, data[25] <= 3 else {
            throw DeskError.invalid("Invalid video frame header.")
        }
        sequence = data.integer(at: 0, as: UInt64.self)
        captureTime = data.integer(at: 8, as: UInt64.self)
        encodeTime = data.integer(at: 16, as: UInt64.self)
        keyframe = data[24] & 1 != 0
        afterIdle = data[24] & 2 != 0
        var offset = 26
        var parameters: [Data] = []
        for _ in 0..<data[25] {
            guard data.count - offset >= 4 else { throw DeskError.invalid("Truncated HEVC parameters.") }
            let length = Int(data.integer(at: offset, as: UInt32.self)); offset += 4
            guard (1...65536).contains(length), data.count - offset >= length else {
                throw DeskError.invalid("Invalid HEVC parameter length.")
            }
            parameters.append(data.subdata(in: offset..<offset + length)); offset += length
        }
        guard offset < data.count, !keyframe || parameters.count == 3 else {
            throw DeskError.invalid("Missing HEVC frame data or keyframe parameters.")
        }
        parameterSets = parameters
        bytes = data.subdata(in: offset..<data.count)
    }
}

public enum DesktopGeometry {
    public static func fit(content: CGSize, in bounds: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / content.width, bounds.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    public static func normalized(_ point: CGPoint, content: CGSize, in bounds: CGRect) -> CGPoint? {
        let rect = fit(content: content, in: bounds)
        return normalized(point, in: rect)
    }
    public static func normalized(_ point: CGPoint, in rect: CGRect) -> CGPoint? {
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
        return CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }
    public static func keyboardAdjustedFit(content: CGSize, in bounds: CGRect, keyboardHeight: CGFloat,
                                           focus: CGRect?) -> CGRect {
        var frame = fit(content: content, in: bounds)
        guard keyboardHeight > 0, let focus, frame.height > 0 else { return frame }
        let visibleBottom = bounds.maxY - min(keyboardHeight, bounds.height) - bounds.height * 0.025
        let focusBottom = frame.minY + min(1, max(0, focus.maxY)) * frame.height
        let shift = max(0, focusBottom - visibleBottom)
        // Translate rather than shrink the desktop, preserving Retina text size while typing.
        frame.origin.y -= min(shift, max(0, frame.maxY - visibleBottom))
        return frame
    }
    public static func pixelSize(native: CGSize, longestEdge: Int) -> CGSize {
        let scale = min(1, CGFloat(longestEdge) / max(native.width, native.height))
        return CGSize(width: max(2, floor(native.width * scale / 2) * 2),
                      height: max(2, floor(native.height * scale / 2) * 2))
    }
}

/// Bounded capture-to-decode window; drop before encoding to preserve HEVC dependencies.
public final class FrameWindow {
    private let lock = NSLock()
    private var outstanding: [UInt64: UInt64] = [:]
    private var next: UInt64 = 0
    public let capacity: Int
    private let frameInterval: UInt64?
    private let maximumCapacity: Int
    private var limit: Int
    private var feedbackSamples: [UInt64] = []
    public init(capacity: Int = 2) {
        self.capacity = max(1, capacity); limit = max(1, capacity)
        maximumCapacity = max(1, capacity); frameInterval = nil
    }
    private init(fps: Int) {
        capacity = 2; limit = 2; maximumCapacity = 8
        frameInterval = 1_000_000_000 / UInt64(max(1, fps))
    }
    public static func streaming(fps: Int) -> FrameWindow { FrameWindow(fps: fps) }
    public var currentLimit: Int { lock.lock(); defer { lock.unlock() }; return limit }
    public var feedbackMilliseconds: Double {
        lock.lock(); defer { lock.unlock() }
        guard !feedbackSamples.isEmpty else { return 0 }
        return Double(feedbackSamples.reduce(0, +)) / Double(feedbackSamples.count) / 1_000_000
    }
    public func reserve(now: UInt64 = monotonicNanos()) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard outstanding.count < limit else { return nil }
        // Stop feeding a delayed pipeline instead of building an unbounded queue behind it.
        if frameInterval != nil, let oldest = outstanding.values.min(), now >= oldest,
           now - oldest > 120_000_000 { return nil }
        next &+= 1; outstanding[next] = now; return next
    }
    public func acknowledge(_ sequence: UInt64, now: UInt64 = monotonicNanos()) {
        lock.lock(); defer { lock.unlock() }
        guard let sent = outstanding.removeValue(forKey: sequence), now >= sent, let frameInterval else { return }
        feedbackSamples.append(now - sent)
        if feedbackSamples.count > 64 { feedbackSamples.removeFirst() }
        // The recent minimum estimates propagation + codec work; queueing spikes must not inflate the window.
        // Two frames of slack absorb ordinary Wi-Fi jitter; one frame discarded a third of a jittered 120 Hz source.
        let baseline = min(feedbackSamples.min() ?? 0, 120_000_000)
        limit = min(maximumCapacity, max(capacity, Int((baseline + frameInterval - 1) / frameInterval) + 2))
    }
    public func oldestAge(now: UInt64 = monotonicNanos()) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard let oldest = outstanding.values.min(), now >= oldest else { return nil }
        return now - oldest
    }
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        outstanding.removeAll(); feedbackSamples.removeAll(); limit = capacity
    }
}

public func monotonicNanos() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

extension Data {
    mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
    func integer<T: FixedWidthInteger>(at offset: Int, as type: T.Type) -> T {
        var value: T = 0
        for byte in self[startIndex + offset..<startIndex + offset + MemoryLayout<T>.size] {
            value = (value << 8) | T(byte)
        }
        return value
    }
}
