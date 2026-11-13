import Foundation

/// Diagnostic only: records what the main thread last started and reports when it stops responding.
enum Breadcrumb {
    private static let lock = NSLock()
    private static var stage = "launch"
    private static var beat = monotonicNanos()
    static func mark(_ value: String) { lock.lock(); stage = value; lock.unlock() }
    static func heartbeat() { lock.lock(); beat = monotonicNanos(); lock.unlock() }
    static func stalled() -> (seconds: Double, stage: String)? {
        lock.lock(); defer { lock.unlock() }
        let now = monotonicNanos()
        guard now > beat, now - beat > 1_000_000_000 else { return nil }
        return (Double(now - beat) / 1_000_000_000, stage)
    }
}
