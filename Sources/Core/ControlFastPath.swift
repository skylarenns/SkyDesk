import Foundation

/// Answers latency-critical control messages on the transport queue, so main-thread work on the host
/// (UI, accessibility, input injection) cannot delay frame acknowledgements or distort measured RTT.
public final class ControlFastPath {
    public enum Outcome: Equatable { case handled, pongSent, pass }
    private let lock = NSLock()
    private var controlID: UUID?
    private weak var window: FrameWindow?
    public init() {}
    public func bind(control id: UUID?) { lock.lock(); controlID = id; lock.unlock() }
    public func bind(window: FrameWindow?) { lock.lock(); self.window = window; lock.unlock() }
    /// Only the established control channel is served here; everything else takes the validated main path.
    public func handle(_ message: ControlMessage, channel id: UUID, reply: (ControlMessage) -> Void) -> Outcome {
        lock.lock(); let isControl = controlID == id; let window = self.window; lock.unlock()
        guard isControl else { return .pass }
        switch message {
        case .frameAck(let sequence): window?.acknowledge(sequence); return .handled
        case .ping(let value): reply(.pong(value)); return .pongSent
        case .clientStats(let text):
            if text.utf8.count <= 512 { MetricsLog.shared.append("ipad  " + text) }
            return .handled
        default: return .pass
        }
    }
}
