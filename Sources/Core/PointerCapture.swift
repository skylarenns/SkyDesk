import Foundation
import CoreGraphics

/// Captured pointer (build 47, user request 2026-11-15: "support for stuff that captures the mouse, like games").
///
/// Normally the iPad sends where the pointer is. A game that takes the mouse hides the pointer, holds it in one
/// place and reads how far the mouse moved, so positions are useless to it: the view would stop turning as soon
/// as the iPad's pointer reached the edge of the screen. While the pointer is captured the iPad sends distances
/// instead (`InputEvent.relative`), taken from the mouse or trackpad itself, and the Mac replays them as movement.
/// Only the arithmetic lives here, so it can be tested; the event handling is in the two apps.

/// Mac side: turns distances from the iPad into whole-point pointer movement.
public struct RelativePointer: Equatable {
    private var restX = 0.0, restY = 0.0
    public init() {}
    public mutating func reset() { restX = 0; restY = 0 }
    public struct Step: Equatable {
        /// Where the Mac's pointer belongs after this movement.
        public let target: CGPoint
        /// The movement to report, in whole points.
        public let dx: Int, dy: Int
    }
    /// `current` is where the Mac's pointer really is now, read fresh each time because a game may hold it in
    /// place or put it back in the middle of its window; `bounds` is the desktop the iPad shows. Returns nil
    /// until the fractions carried over add up to a whole point.
    ///
    /// The pointer is always asked to move by the distance, and the distance is reported with the event. A game
    /// that has taken the mouse reads the distance and keeps the pointer where it wants it. (Telling whether an
    /// app has hidden the pointer would allow holding it still here too, but the one call for that,
    /// CGCursorIsVisible, answered "hidden" 250 times out of 250 on macOS 27 while the pointer was in use.)
    public mutating func step(dx: Double, dy: Double, from current: CGPoint, in bounds: CGRect) -> Step? {
        guard dx.isFinite, dy.isFinite else { return nil }
        restX += dx; restY += dy
        let wholeX = restX.rounded(.towardZero), wholeY = restY.rounded(.towardZero)
        guard wholeX != 0 || wholeY != 0 else { return nil }
        restX -= wholeX; restY -= wholeY
        // A push against an edge still reports the movement (the Dock and edge sidebars wait for exactly that).
        let target = CGPoint(x: min(max(current.x + wholeX, bounds.minX), max(bounds.minX, bounds.maxX - 1)),
                             y: min(max(current.y + wholeY, bounds.minY), max(bounds.minY, bounds.maxY - 1)))
        return Step(target: target, dx: Int(wholeX), dy: Int(wholeY))
    }
}

/// iPad side: a mouse can report a thousand movements a second; the Mac is sent at most one every `interval`,
/// carrying their sum, so nothing is lost and the control connection is not flooded.
public struct DeltaCoalescer: Equatable {
    public let interval: UInt64
    public private(set) var x = 0.0, y = 0.0
    private var lastSent: UInt64?
    public init(interval: UInt64 = 4_000_000) { self.interval = interval }
    public enum Outcome: Equatable {
        /// Send this now.
        case send(dx: Double, dy: Double)
        /// Held back; call `flush` after this many nanoseconds unless more movement arrives first.
        case wait(UInt64)
    }
    public mutating func add(dx: Double, dy: Double, now: UInt64) -> Outcome {
        x += dx; y += dy
        if let last = lastSent, now >= last, now - last < interval { return .wait(interval - (now - last)) }
        return flush(now: now).map { .send(dx: $0.dx, dy: $0.dy) } ?? .wait(interval)
    }
    /// What is being held back, if anything. Also called before a click, so it lands after the movement.
    public mutating func flush(now: UInt64) -> (dx: Double, dy: Double)? {
        guard x != 0 || y != 0 else { return nil }
        // One message carries at most what InputEvent allows; a larger sum (never seen in 4 ms) is sent in parts.
        let part = (dx: min(max(x, -InputEvent.largestRelativeMove), InputEvent.largestRelativeMove),
                    dy: min(max(y, -InputEvent.largestRelativeMove), InputEvent.largestRelativeMove))
        x -= part.dx; y -= part.dy; lastSent = now
        return part
    }
    public mutating func reset() { x = 0; y = 0; lastSent = nil }
}
