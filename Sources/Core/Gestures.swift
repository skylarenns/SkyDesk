import Foundation
import CoreGraphics

/// A trackpad or touch gesture that is not a pointer, scroll or key event (StreamFeature.gestures, build 32).
public struct GestureEvent: Codable, Equatable {
    public enum Kind: String, Codable { case magnify, rotate }
    public var kind: Kind
    /// Magnify: the fraction to add to the current zoom (0.1 = 10 % larger), as macOS reports a pinch.
    /// Rotate: degrees, counter-clockwise positive, as macOS reports a rotation.
    public var value: Double
    /// ScrollPhase: began, changed or ended.
    public var phase: Int
    public init(kind: Kind, value: Double, phase: Int) { self.kind = kind; self.value = value; self.phase = phase }
    public var isValid: Bool {
        value.isFinite && abs(value) <= (kind == .magnify ? 4 : 360) && (ScrollPhase.began...ScrollPhase.ended).contains(phase)
    }
}

/// Turns UIKit's running totals (pinch scale since the gesture began, rotation in radians, clockwise positive)
/// into the per-event steps macOS expects.
public struct GestureSteps {
    private var scale = 1.0
    private var radians = 0.0
    public init() {}
    public mutating func reset() { scale = 1; radians = 0 }
    /// The zoom step for a new total scale; nil when the total is unusable.
    public mutating func magnification(scale total: Double) -> Double? {
        guard total.isFinite, total > 0.01, scale > 0.01 else { return nil }
        let step = total / scale - 1
        scale = total
        return max(-0.9, min(4, step))
    }
    /// The rotation step in degrees (counter-clockwise positive) for a new total in radians (clockwise positive).
    public mutating func degrees(radians total: Double) -> Double? {
        guard total.isFinite else { return nil }
        let step = -(total - radians) * 180 / .pi
        radians = total
        return max(-360, min(360, step))
    }
}

#if os(macOS)
/// The macOS event for a gesture. These are the gesture events a Mac trackpad produces: event type 29 with the
/// gesture kind in field 110, its value in field 113 and its phase in field 132. The fields are not named in the
/// public headers; Tests/GestureTests.swift checks that AppKit reads them back as magnify and rotate events.
public enum GestureInjection {
    public static func event(_ gesture: GestureEvent, at location: CGPoint) -> CGEvent? {
        guard gesture.isValid, let type = CGEventType(rawValue: 29), let kind = CGEventField(rawValue: 110),
              let value = CGEventField(rawValue: 113), let phase = CGEventField(rawValue: 132),
              let event = CGEvent(source: nil) else { return nil }
        event.type = type
        event.setIntegerValueField(kind, value: gesture.kind == .magnify ? 8 : 5)
        event.setDoubleValueField(value, value: gesture.value)
        // began 1, changed 2, ended 4.
        event.setIntegerValueField(phase, value: gesture.phase == ScrollPhase.began ? 1 : gesture.phase == ScrollPhase.changed ? 2 : 4)
        event.location = location
        RemoteInputOrigin.mark(event)
        return event
    }
}
#endif

/// Screen edges matter on a Mac: an auto-hidden Dock, the menu bar in full screen, hot corners and apps that
/// reveal a sidebar when the pointer rests on the edge (a browser's hidden tab bar) all wait for the pointer to
/// arrive exactly there and, some of them, to keep pushing. Two things got in the way from an iPad (user report
/// 2026-11-15: a hidden sidebar would not open): the iPad's pointer has to be brought to the last point of the
/// screen, and once it rests there no more events are sent, where a real mouse held against an edge keeps
/// reporting movement. So a pointer within `zone` points of an edge counts as on it (build 43), and while it rests
/// there the move is repeated a few times, which the Mac replays as a push against that edge.
public enum PointerEdges {
    public static let zone = 5.0
    /// How many times, and how often, a move on an edge is repeated while the pointer stays there.
    public static let pushes = 10
    public static let pushInterval = 0.03
    /// `point` and `size` in the stream view's points. Returns the point to use and whether it lies on an edge.
    public static func snapped(_ point: CGPoint, in frame: CGRect) -> (point: CGPoint, onEdge: Bool) {
        guard frame.width > zone * 4, frame.height > zone * 4 else { return (point, false) }
        var result = point
        if point.x - frame.minX <= zone { result.x = frame.minX } else if frame.maxX - point.x <= zone { result.x = frame.maxX - 0.01 }
        if point.y - frame.minY <= zone { result.y = frame.minY } else if frame.maxY - point.y <= zone { result.y = frame.maxY - 0.01 }
        return (result, result != point || point.x == frame.minX || point.y == frame.minY)
    }
}
