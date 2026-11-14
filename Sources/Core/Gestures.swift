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
