#if os(macOS)
import CoreGraphics

/// Marks every injected event so local-activity recovery can ignore remote input.
public enum RemoteInputOrigin {
    public static let marker: Int64 = 0x534B594445534B
    public static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
    }
    public static func isLocalActivity(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) != marker
    }
    /// When the host last replayed an iPad gesture (main thread only). A gesture event seen right after that is the
    /// iPad's, even if the marker did not survive the trip through the system.
    public static var lastGesture: UInt64 = 0
    public static func gestureJustInjected(now: UInt64 = monotonicNanos()) -> Bool {
        lastGesture != 0 && now >= lastGesture && now - lastGesture < 500_000_000
    }
}
#endif
