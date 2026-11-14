import Foundation

/// Answers latency-critical control messages on the transport queue, so main-thread work on the host
/// (UI, accessibility, input injection) cannot delay frame acknowledgements or distort measured RTT.
public final class ControlFastPath {
    public enum Outcome: Equatable { case handled, pongSent, pass }
    private let lock = NSLock()
    private var controlID: UUID?
    private weak var window: FrameWindow?
    private var roundTrip: (ms: Double, at: UInt64)?
    public init() {}
    public func bind(control id: UUID?) { lock.lock(); controlID = id; roundTrip = nil; lock.unlock() }
    /// The iPad's latest reported network round trip, if it is no older than `maxAge` seconds.
    public func roundTripMS(maxAge: Double = 3, now: UInt64 = monotonicNanos()) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let roundTrip, now >= roundTrip.at, Double(now - roundTrip.at) / 1_000_000_000 <= maxAge else { return nil }
        return roundTrip.ms
    }
    public func bind(window: FrameWindow?) { lock.lock(); self.window = window; lock.unlock() }
    /// Only the established control channel is served here; everything else takes the validated main path.
    public func handle(_ message: ControlMessage, channel id: UUID, reply: (ControlMessage) -> Void) -> Outcome {
        lock.lock(); let isControl = controlID == id; let window = self.window; lock.unlock()
        guard isControl else { return .pass }
        switch message {
        case .frameAck(let sequence): window?.acknowledge(sequence); return .handled
        case .ping(let value): reply(.pong(value)); return .pongSent
        case .clientStats(let text):
            if text.utf8.count <= 512 {
                MetricsLog.shared.append("ipad  " + text)
                if let ms = StatisticsText.roundTrip(fromLogLine: text) { lock.lock(); roundTrip = (ms, monotonicNanos()); lock.unlock() }
            }
            return .handled
        default: return .pass
        }
    }
}
