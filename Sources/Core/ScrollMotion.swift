import Foundation

/// Scroll phases carried in InputEvent.phase (absent from older iPads: plain wheel scrolling).
public enum ScrollPhase {
    public static let began = 1
    public static let changed = 2
    public static let ended = 3
}

/// Whole-point scroll steps with the fractions carried over, so slow scrolling is not rounded away.
public struct ScrollAccumulator {
    private var remainder = CGPoint.zero
    public init() {}
    public mutating func step(_ delta: CGPoint) -> (x: Int32, y: Int32) {
        let x = remainder.x + delta.x, y = remainder.y + delta.y
        let wholeX = x.rounded(.towardZero), wholeY = y.rounded(.towardZero)
        remainder = CGPoint(x: x - wholeX, y: y - wholeY)
        return (Int32(clamping: Int(wholeX)), Int32(clamping: Int(wholeY)))
    }
    public mutating func reset() { remainder = .zero }
}

/// The glide after the fingers lift, generated on the Mac so Wi-Fi jitter can't make it uneven.
/// Same feel as UIScrollView's normal deceleration: velocity × 0.998 per millisecond.
public struct ScrollMomentum {
    public static let decayPerMillisecond = 0.998
    public static let stopBelow = 12.0          // points per second
    public static let maximumDuration = 4.0     // seconds
    public static let maximumSpeed = 12_000.0   // points per second
    private var velocity: CGPoint
    private var elapsed = 0.0
    public init?(velocity: CGPoint) {
        guard velocity.x.isFinite, velocity.y.isFinite else { return nil }
        let speed = hypot(velocity.x, velocity.y)
        guard speed >= 60 else { return nil }
        let scale = min(1, Self.maximumSpeed / speed)
        self.velocity = CGPoint(x: velocity.x * scale, y: velocity.y * scale)
    }
    /// Advances by `dt` seconds. Returns the distance to scroll, or nil when the glide is over.
    public mutating func step(_ dt: Double) -> CGPoint? {
        guard dt > 0, elapsed < Self.maximumDuration, hypot(velocity.x, velocity.y) >= Self.stopBelow else { return nil }
        elapsed += dt
        // Exact integral of v·k^t over the step, so the total distance does not depend on the tick rate.
        let k = log(Self.decayPerMillisecond) * 1_000
        let factor = exp(k * dt)
        let distance = (factor - 1) / k
        let delta = CGPoint(x: velocity.x * distance, y: velocity.y * distance)
        velocity = CGPoint(x: velocity.x * factor, y: velocity.y * factor)
        return delta
    }
}

/// Keeps the remembered modifier keys honest. iPadOS sometimes keeps a modifier's key-up for itself (holding ⌘ for
/// the shortcut list, ⌘-Tab), so a remembered ⌘ stayed "down" and every later click reached the Mac as ⌘-click:
/// links opened in new tabs, Dock clicks revealed apps in Finder (user report 2026-11-13). Pointer events carry the
/// real modifier state; this works out which held modifier keys must be released.
public enum ModifierSync {
    /// SkyDesk modifier bit → the HID usages of its left and right keys. Caps Lock (16) is a toggle and never released.
    public static let keys: [(bit: UInt, usages: [Int])] = [(1, [225, 229]), (2, [224, 228]), (4, [226, 230]), (8, [227, 231])]
    /// Held modifier keys whose modifier is no longer actually down.
    public static func stale(held: Set<Int>, actual: UInt) -> [Int] {
        keys.filter { actual & $0.bit == 0 }.flatMap(\.usages).filter(held.contains).sorted()
    }
}

/// Scroll movement handed to the Mac app in even portions, one per display refresh (build 63, user report
/// 2026-11-17: "the scrolling is just like stuttery and not the 120fps smooth that i expect").
///
/// The iPad sends scroll movement as iPadOS reports it, at an even rate; Wi-Fi delivers it unevenly, two
/// together and then none. Applied on arrival, the app moved in lurches: the Mac drew 60 to 100 distinct frames a
/// second while scrolling, though every frame drawn was captured, encoded and shown. Here what has arrived waits
/// in `pending` and each refresh takes a share of it, so two movements arriving together are spread over two
/// refreshes. The cost is about one refresh of delay. A small remainder, or anything left at the gesture's end,
/// goes out whole.
public struct ScrollPacer: Equatable {
    public static let share = 0.5
    /// Below this (points) the remainder goes out in one step.
    public static let whole = 1.5
    public private(set) var pending = CGPoint.zero
    public init() {}
    public mutating func add(_ delta: CGPoint) {
        guard delta.x.isFinite, delta.y.isFinite else { return }
        pending.x += delta.x; pending.y += delta.y
    }
    public var isEmpty: Bool { pending == .zero }
    /// The movement for this refresh. `ending`: the fingers have lifted, so let everything out now.
    public mutating func next(ending: Bool = false) -> CGPoint {
        let out = ending || hypot(pending.x, pending.y) <= Self.whole ? pending
            : CGPoint(x: pending.x * Self.share, y: pending.y * Self.share)
        pending.x -= out.x; pending.y -= out.y
        return out
    }
    public mutating func reset() { pending = .zero }
}
