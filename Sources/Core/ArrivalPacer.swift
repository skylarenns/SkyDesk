import Foundation

/// Decides whether a frame that has just arrived may be drawn at once instead of at the next display tick (build 35).
///
/// The screen changes only at each refresh. A frame drawn at a tick appears at the following refresh; a frame that
/// arrives shortly after a tick used to wait for the next tick and so appeared two refreshes later. Drawn on
/// arrival it makes the very next refresh, provided nothing else was already drawn for that refresh (two frames
/// for one refresh queue up and add delay) and enough time is left for the system to pick it up. How much time
/// is enough is learned: every miss widens the margin a little, a long run of hits narrows it again.
public struct ArrivalPacer: Equatable {
    public static let smallestMargin = 0.0025
    public static let largestMargin = 0.0075
    /// Seconds that must remain before the next refresh.
    public private(set) var margin = 0.004
    public private(set) var nextRefresh = 0.0
    private var interval = 1.0 / 120
    private var drawnForNextRefresh = false
    private var hitsInARow = 0
    public private(set) var hits = 0
    public private(set) var misses = 0
    public init() {}

    /// A display tick: `target` is when the display next refreshes, `interval` the time between refreshes.
    public mutating func tick(target: Double, interval: Double) {
        nextRefresh = target
        if interval.isFinite, interval > 0.001, interval < 0.1 { self.interval = interval }
        drawnForNextRefresh = false
    }
    /// A frame was drawn (at the tick or on arrival): nothing more may be drawn for the coming refresh.
    public mutating func drew() { drawnForNextRefresh = true }
    public func mayDrawOnArrival(now: Double) -> Bool {
        let left = nextRefresh - now
        return !drawnForNextRefresh && left >= margin && left <= interval * 1.5
    }
    /// Reports when a frame drawn on arrival really reached the screen.
    public mutating func arrivalResult(expected: Double, presented: Double) {
        if presented > expected + interval * 0.25 {
            misses += 1; hitsInARow = 0
            margin = min(Self.largestMargin, margin + 0.0005)
        } else {
            hits += 1; hitsInARow += 1
            if hitsInARow >= 200 { hitsInARow = 0; margin = max(Self.smallestMargin, margin - 0.00025) }
        }
    }
}
