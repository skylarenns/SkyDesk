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
}
#endif
