import Foundation

/// Time-stamped samples kept for a fixed trailing span. Not thread-safe; callers serialize access.
public struct RollingSamples {
    public let span: UInt64
    private var times: [UInt64] = []
    private var values: [Double] = []
    private var head = 0
    public init(span: UInt64) { self.span = span }
    public mutating func add(_ value: Double, at time: UInt64) {
        guard value.isFinite else { return }
        times.append(time); values.append(value)
        trim(now: time)
    }
    public mutating func trim(now: UInt64) {
        while head < times.count, now > times[head], now - times[head] >= span { head += 1 }
        if head > 1_024 { times.removeFirst(head); values.removeFirst(head); head = 0 }
    }
    /// Values younger than `last` nanoseconds at `now` (the whole span when nil); the window is half-open.
    public func recent(_ last: UInt64? = nil, now: UInt64) -> ArraySlice<Double> {
        let limit = min(last ?? span, span)
        var start = head
        while start < times.count, now > times[start], now - times[start] >= limit { start += 1 }
        return values[start...]
    }
    public func mean(last: UInt64? = nil, now: UInt64) -> Double? {
        let slice = recent(last, now: now)
        return slice.isEmpty ? nil : slice.reduce(0, +) / Double(slice.count)
    }
    /// Nearest-rank percentile over the span; nil below `minimumSamples` so a thin tail is never presented as a tail.
    public func percentile(_ fraction: Double, now: UInt64, minimumSamples: Int) -> Double? {
        let slice = recent(now: now)
        guard slice.count >= max(1, minimumSamples) else { return nil }
        let sorted = slice.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }
}

/// Client-side stream statistics. Thread-safe; fed from the network, decode, and presentation callbacks.
///
/// Definitions (all on the iPad's monotonic clock; no cross-device clock is compared):
/// - FPS: new frames that reached the screen in the last second.
/// - FPS 1% low: 1000 / (99th-percentile gap in ms between consecutive on-screen frames) over the last 10 s.
///   A gap is left out only when the Mac reported that its screen had stopped changing for at least
///   `idleGapNanos` before the later frame, so pauses are not stutter but every delivery hitch is.
/// - Latency average: mean of the samples from the last 2 s. Latency 1% high: 99th percentile of the last 10 s.
/// - Network RTT: ping/pong round trip on the control connection, sampled `pingsPerSecond` times a second.
/// - Local display: frame fully received → on screen. Excludes Mac capture, encode, and network transit.
/// - Total (estimate): per on-screen frame, the Mac's capture→encoded time (both timestamps on the Mac's clock)
///   + the current RTT average + that frame's local display time. Excludes the Mac app's own reaction time.
/// - A percentile needs `minimumTailSamples` samples in its window; otherwise it is nil ("—").
public final class StreamStatistics {
    public static let rateSpan: UInt64 = 1_000_000_000
    public static let averageSpan: UInt64 = 2_000_000_000
    public static let tailSpan: UInt64 = 10_000_000_000
    public static let idleGapNanos: UInt64 = 100_000_000
    public static let minimumTailSamples = 100
    public static let pingsPerSecond = 20

    public struct Snapshot: Equatable {
        public var fps = 0.0
        public var fpsLow1: Double?
        public var megabitsPerSecond = 0.0
        public var rttAverageMS: Double?
        public var rttHigh1MS: Double?
        public var displayAverageMS: Double?
        public var displayHigh1MS: Double?
        public var totalAverageMS: Double?
        public var totalHigh1MS: Double?
        public var decodeAverageMS: Double?
        /// Frames that finished arriving in the last second, whether or not they reached the screen.
        public var arrivedFPS = 0.0
    }

    private let lock = NSLock()
    private var presented = RollingSamples(span: StreamStatistics.rateSpan)
    private var received = RollingSamples(span: StreamStatistics.rateSpan)
    private var decode = RollingSamples(span: StreamStatistics.averageSpan)
    private var intervals = RollingSamples(span: StreamStatistics.tailSpan)
    private var display = RollingSamples(span: StreamStatistics.tailSpan)
    private var total = RollingSamples(span: StreamStatistics.tailSpan)
    private var rtt = RollingSamples(span: StreamStatistics.tailSpan)
    private var lastPresented: UInt64?
    private var lastPong: UInt64?
    public init() {}

    public func recordReceived(bytes: Int, decodeMS: Double, now: UInt64 = monotonicNanos()) {
        lock.lock(); defer { lock.unlock() }
        received.add(Double(bytes), at: now); decode.add(decodeMS, at: now)
    }
    /// `time` is when the frame reached the screen; `afterIdle` marks a frame that followed a pause in Mac screen updates.
    /// `macMS`: the frame's capture→encoded time on the Mac, when known; it feeds the total estimate.
    public func recordPresented(at time: UInt64, receivedAt: UInt64, afterIdle: Bool, macMS: Double? = nil) {
        lock.lock(); defer { lock.unlock() }
        presented.add(1, at: time)
        if time >= receivedAt {
            let local = Double(time - receivedAt) / 1_000_000
            display.add(local, at: time)
            if let macMS, macMS >= 0, let round = rtt.mean(last: Self.averageSpan, now: time) { total.add(macMS + round + local, at: time) }
        }
        if let last = lastPresented {
            guard time > last else { return }
            if !afterIdle { intervals.add(Double(time - last) / 1_000_000, at: time) }
        }
        lastPresented = time
    }
    public func recordPong(sentAt: UInt64, now: UInt64 = monotonicNanos()) -> Bool {
        guard sentAt <= now else { return false }
        lock.lock(); defer { lock.unlock() }
        rtt.add(Double(now - sentAt) / 1_000_000, at: now); lastPong = now
        return true
    }
    public func lastPongAge(now: UInt64 = monotonicNanos()) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard let lastPong else { return nil }
        return now >= lastPong ? now - lastPong : 0
    }
    public func snapshot(now: UInt64 = monotonicNanos()) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let minimum = Self.minimumTailSamples
        var value = Snapshot()
        value.fps = Double(presented.recent(now: now).count) / (Double(Self.rateSpan) / 1_000_000_000)
        value.megabitsPerSecond = received.recent(now: now).reduce(0, +) * 8 / 1_000_000 / (Double(Self.rateSpan) / 1_000_000_000)
        if let slowest = intervals.percentile(0.99, now: now, minimumSamples: minimum), slowest > 0 { value.fpsLow1 = 1_000 / slowest }
        value.rttAverageMS = rtt.mean(last: Self.averageSpan, now: now)
        value.rttHigh1MS = rtt.percentile(0.99, now: now, minimumSamples: minimum)
        value.displayAverageMS = display.mean(last: Self.averageSpan, now: now)
        value.displayHigh1MS = display.percentile(0.99, now: now, minimumSamples: minimum)
        value.totalAverageMS = total.mean(last: Self.averageSpan, now: now)
        value.totalHigh1MS = total.percentile(0.99, now: now, minimumSamples: minimum)
        value.decodeAverageMS = decode.mean(now: now)
        value.arrivedFPS = Double(received.recent(now: now).count) / (Double(Self.rateSpan) / 1_000_000_000)
        return value
    }
}

public enum StatisticsText {
    public static func milliseconds(_ value: Double?) -> String { value.map { String(format: "%.1f ms", $0) } ?? "—" }
    public static func headline(_ s: StreamStatistics.Snapshot) -> String {
        String(format: "%.0f FPS · 1%% low %@ · %.1f Mbps", s.fps, s.fpsLow1.map { String(format: "%.0f", $0) } ?? "—", s.megabitsPerSecond)
    }
    public static func network(_ s: StreamStatistics.Snapshot) -> String {
        "Network RTT  avg \(milliseconds(s.rttAverageMS)) · 1% high \(milliseconds(s.rttHigh1MS))"
    }
    public static func display(_ s: StreamStatistics.Snapshot) -> String {
        "Local display  avg \(milliseconds(s.displayAverageMS)) · 1% high \(milliseconds(s.displayHigh1MS))"
    }
    public static func total(_ s: StreamStatistics.Snapshot) -> String {
        "Total  avg \(milliseconds(s.totalAverageMS)) · 1% high \(milliseconds(s.totalHigh1MS))"
    }
    public static func pipeline(_ s: StreamStatistics.Snapshot) -> String {
        String(format: "Arrived %.0f FPS · Decode avg %@ · Local display avg %@", s.arrivedFPS, milliseconds(s.decodeAverageMS),
               milliseconds(s.displayAverageMS))
    }
    /// One compact line for the host's diagnostic log.
    public static func logLine(_ s: StreamStatistics.Snapshot, link: String) -> String {
        func n(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "-" }
        return String(format: "shown=%.0f low1=%@ arrived=%.0f mbps=%.1f rtt=%@/%@ display=%@/%@ total=%@/%@ decode=%@ link=%@",
                      s.fps, n(s.fpsLow1), s.arrivedFPS, s.megabitsPerSecond, n(s.rttAverageMS), n(s.rttHigh1MS),
                      n(s.displayAverageMS), n(s.displayHigh1MS), n(s.totalAverageMS), n(s.totalHigh1MS), n(s.decodeAverageMS), link)
    }
    /// The average round trip (ms) from a `logLine`; nil when the line has none yet. The Mac's bitrate control
    /// reads it to tell a slow network path from video queueing up behind a slow link.
    public static func roundTrip(fromLogLine line: String) -> Double? {
        guard let start = line.range(of: " rtt=")?.upperBound, let end = line[start...].firstIndex(of: "/"),
              let value = Double(line[start..<end]), value.isFinite, value >= 0, value < 60_000 else { return nil }
        return value
    }
    public static let explanation = "Avg: last 2 s. 1% high/low: 99th percentile of the last 10 s, shown once 100 samples exist. "
        + "1% low skips pauses where the Mac screen was not changing. RTT: network round trip, 20 samples/s. "
        + "Total: Mac capture and encoding + network round trip + iPad display."
}

/// Append-only diagnostic log (~/Library/Logs/SkyDesk/stream-metrics.log on the Mac). Numbers only, no screen content.
public final class MetricsLog {
    public static let shared = MetricsLog()
    private let queue = DispatchQueue(label: "skydesk.metrics-log", qos: .utility)
    private var handle: FileHandle?
    private let formatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()
    public let url: URL
    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.homeDirectoryForCurrentUserOrTemporary
            .appendingPathComponent("Library/Logs/SkyDesk/stream-metrics.log")
    }
    public func append(_ line: String) {
        let stamp = Date()
        queue.async { [self] in
            if handle == nil {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Start over above 4 MB so the log cannot grow without bound.
                if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 4_000_000 {
                    try? FileManager.default.removeItem(at: url)
                }
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                handle = try? FileHandle(forWritingTo: url); _ = try? handle?.seekToEnd()
            }
            try? handle?.write(contentsOf: Data("\(formatter.string(from: stamp)) \(line)\n".utf8))
        }
    }
    public func flush() { queue.sync { try? handle?.synchronize() } }
}

private extension FileManager {
    var homeDirectoryForCurrentUserOrTemporary: URL {
        #if os(macOS)
        return homeDirectoryForCurrentUser
        #else
        return temporaryDirectory
        #endif
    }
}
