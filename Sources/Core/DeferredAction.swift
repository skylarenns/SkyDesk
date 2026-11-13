import Foundation

/// Runs an action on a later turn of `queue`, at most once per burst of requests.
///
/// Used for work that must not happen inside a SwiftUI view update. Changing the first responder from
/// `updateUIView` makes the hosting view read its own graph while that graph is updating; AttributeGraph then
/// loops on the cycle forever and the main thread never returns (iPad watchdog reports of 2026-11-12).
public final class DeferredAction {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending = false
    public init(queue: DispatchQueue = .main) { self.queue = queue }
    /// Never calls `action` before returning, even when called on `queue`.
    public func schedule(_ action: @escaping () -> Void) {
        lock.lock(); let alreadyPending = pending; pending = true; lock.unlock()
        guard !alreadyPending else { return }
        queue.async { [self] in
            lock.lock(); pending = false; lock.unlock()
            action()
        }
    }
}
