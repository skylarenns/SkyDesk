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

/// Mac side: notices that an app has taken the mouse, so the iPad can capture its pointer by itself (build 48,
/// user request 2026-11-15: "can u make game mouse be automatic?").
///
/// Build 48 took "the pointer stays hidden while the iPad moves it" as the sign. That is wrong on a Mac driven
/// from an iPad: after typing, macOS hides the pointer until the *real* mouse moves, and movement injected by
/// SkyDesk does not count, so the pointer read as hidden through ordinary use in a browser, the iPad captured
/// its pointer for nothing and never gave it back (2026-11-15 23:01, "this thing genuinely broke my mouse").
///
/// Since build 49 two things must both be true: the pointer is hidden, and it does not go where it is put. An
/// app that has taken the mouse holds the pointer in place or puts it back after every movement; in ordinary
/// use the pointer lands exactly where the last movement sent it. The pointer is given back as soon as it
/// shows again, or once it has gone where it was put for a while. When in doubt, it is not held.
///
/// Since build 55 the pointer must also be found *in one place* while it fails to follow. Build 54 captured for
/// nothing during ordinary use (2026-11-16 14:18:11, released by itself 3.5 s later): "hidden" says little on
/// macOS 27 (CGCursorIsVisible reads hidden nearly all the time), and a reading of the pointer's position that
/// trails the movements by more than a few events also counts as "not where it was put". A trailing reading
/// moves along with the pointer; a game that holds the mouse keeps putting it back in the same spot.
public struct PointerHoldDetector: Equatable {
    public private(set) var held = false
    /// Hidden and not following through this many seconds and movements before it counts as held.
    /// One second since build 63: 0.3 s was met three times on 2026-11-17 in ordinary use, the readings frozen
    /// in place for a moment (a busy Mac) and moving again 0.1 to 2 s later. A game holds the mouse for minutes.
    public static let holdAfter = 1.0, movesNeeded = 30
    /// While suspected, every reading of the pointer must stay this close (points) to the first one.
    public static let stillRadius = 16.0
    /// How far the pointer's readings strayed from the first one during the hold just found (for the log).
    public private(set) var lastWander = 0.0
    private var anchor: CGPoint?
    private var wander = 0.0
    /// Showing for this long before it counts as given back (a game may flash it for a frame).
    public static let releaseAfter = 0.2
    /// Or following again through this many movements over this long.
    public static let followsNeeded = 12, followAfter = 0.3
    /// "The pointer did not go where it was put" only means something on a Mac where it has been seen to go
    /// where it was put: this many such movements must have been seen first, in this session. If the reading
    /// never matches for some other reason, nothing is ever captured by itself.
    public static let provenAfter = 20
    public private(set) var proven = 0
    private var since: Double?
    private var count = 0
    private var shownSince: Double?
    public init() {}
    /// Call for every pointer movement from the iPad (`moved`), and on a timer while held (`moved` false).
    /// `followed`: whether the pointer was found where a recent movement had put it; nil when that says nothing
    /// (no movement was asked for, or this is the first). Returns the new state when it changes, otherwise nil.
    /// `actual`: where the pointer was read before this movement; without it, nothing new counts toward a hold.
    public mutating func note(hidden: Bool, moved: Bool, followed: Bool?, actual: CGPoint? = nil, now: Double) -> Bool? {
        if held {
            if !hidden {
                let start = shownSince ?? now; shownSince = start
                if now - start >= Self.releaseAfter { reset(); return false }
            } else { shownSince = nil }
            guard moved, let followed else { return nil }
            guard followed else { since = nil; count = 0; return nil }
            let start = since ?? now; since = start; count += 1
            guard count >= Self.followsNeeded, now - start >= Self.followAfter else { return nil }
            reset(); return false
        }
        if moved, followed == true, proven < Self.provenAfter { proven += 1 }
        // One movement that landed where it was sent, or a pointer that shows, ends any suspicion.
        guard hidden, followed != true else { clearSuspicion(); return nil }
        guard moved, followed == false, proven >= Self.provenAfter, let actual else { return nil }
        // Held in place: the readings stay together. One that has moved away starts the count again from there.
        if let anchor {
            let distance = hypot(actual.x - anchor.x, actual.y - anchor.y)
            if distance > Self.stillRadius { clearSuspicion() } else { wander = max(wander, distance) }
        }
        if anchor == nil { anchor = actual; wander = 0 }
        let start = since ?? now; since = start; count += 1
        guard count >= Self.movesNeeded, now - start >= Self.holdAfter else { return nil }
        lastWander = wander
        held = true; clearSuspicion(); shownSince = nil
        return true
    }
    private mutating func clearSuspicion() { since = nil; count = 0; anchor = nil; wander = 0 }
    /// Ends a hold; what the session has proven so far is kept.
    public mutating func reset() { held = false; clearSuspicion(); shownSince = nil }
}

/// Mac side: whether the pointer went where it was put. The pointer's position is read just before each new
/// movement and compared with where the last few movements sent it (the last few, because the position read
/// may trail the newest one by a moment).
public struct PointerFollowing: Equatable {
    private var targets: [CGPoint] = []
    private var asked = false
    public static let tolerance = 3.0
    public init() {}
    /// `actual`: where the pointer is now, before the next movement is posted.
    public func followed(actual: CGPoint) -> Bool? {
        guard asked, !targets.isEmpty else { return nil }
        return targets.contains { hypot($0.x - actual.x, $0.y - actual.y) <= Self.tolerance }
    }
    /// `target`: where the movement about to be posted sends the pointer.
    public mutating func sent(target: CGPoint, from actual: CGPoint) {
        // A movement that sends the pointer (nearly) where it already is proves nothing about the next reading,
        // and must not be remembered either: a game holding the pointer in the middle of its window would
        // otherwise seem to follow, because the middle is where every small movement started.
        asked = hypot(target.x - actual.x, target.y - actual.y) > Self.tolerance
        guard asked else { return }
        targets.append(target)
        if targets.count > 3 { targets.removeFirst() }
    }
    public mutating func reset() { targets = []; asked = false }
}
