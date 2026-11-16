import CoreGraphics

/// Pure geometry for moving windows between desktops. Global top-left coordinates,
/// matching CoreGraphics display bounds and Accessibility window positions.
public enum WindowPlacement {
    /// Scales nothing: keeps the window's size where it fits, shrinks it to the target
    /// where it does not, and preserves its relative position on the source desktop.
    public static func fit(_ frame: CGRect, from source: CGRect, into target: CGRect) -> CGRect {
        guard target.width > 0, target.height > 0 else { return frame }
        let width = min(frame.width, target.width), height = min(frame.height, target.height)
        func place(_ origin: CGFloat, _ length: CGFloat, _ sourceMin: CGFloat, _ sourceLength: CGFloat,
                   _ targetMin: CGFloat, _ targetLength: CGFloat, _ fitted: CGFloat) -> CGFloat {
            let slack = sourceLength - length
            let relative = slack > 1 ? min(1, max(0, (origin - sourceMin) / slack)) : 0
            return (targetMin + relative * (targetLength - fitted)).rounded()
        }
        return CGRect(x: place(frame.minX, frame.width, source.minX, source.width, target.minX, target.width, width),
                      y: place(frame.minY, frame.height, source.minY, source.height, target.minY, target.height, height),
                      width: width.rounded(.down), height: height.rounded(.down))
    }
    /// The desktop holding the window's centre, else the one sharing the most area.
    public static func desktop(for frame: CGRect, among desktops: [CGRect]) -> CGRect? {
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        if let hit = desktops.first(where: { $0.contains(centre) }) { return hit }
        func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
        let best = desktops.max { area($0.intersection(frame)) < area($1.intersection(frame)) }
        return best.flatMap { area($0.intersection(frame)) > 0 ? $0 : nil }
    }
    /// Whole window inside the desktop, within a small tolerance.
    public static func isContained(_ frame: CGRect, in desktop: CGRect, tolerance: CGFloat = 2) -> Bool {
        desktop.insetBy(dx: -tolerance, dy: -tolerance).contains(frame)
    }
    /// A user can still grab the window: its top edge is on the desktop and a useful part shows.
    public static func isReachable(_ frame: CGRect, in desktop: CGRect) -> Bool {
        let visible = desktop.intersection(frame)
        guard !visible.isNull, frame.width > 0, frame.height > 0 else { return false }
        return frame.minY >= desktop.minY - 2 && frame.minY < desktop.maxY - 24
            && visible.width >= min(frame.width, 120) && visible.height >= min(frame.height, 40)
    }
    public static func matches(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 3) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
    /// Where a window goes when the Mac desktop returns. `lastSeen` is its frame on the
    /// iPad desktop just before the switch back; `current` is its frame afterwards.
    /// A window the user left alone returns to its original frame; one they moved or
    /// resized on the iPad keeps that and is only pulled back if it would be stranded.
    /// A frame recorded while the Mac's display sat at `recordedMac`, in the coordinates of the arrangement where it
    /// sits at `mac`. Build 42 makes the iPad's desktop main while waiting to connect, which moves the Mac's display
    /// to the right of it (x = 1376), and windows were recorded there; put back at the same numbers once the Mac's
    /// display was at x = 0 again, they landed past its right side and macOS pushed them in against the edge
    /// (user report 2026-11-16: "the windows are all on the very edge of the screen").
    public static func translated(_ frame: CGRect, recordedMac: CGRect, mac: CGRect) -> CGRect {
        frame.offsetBy(dx: mac.minX - recordedMac.minX, dy: mac.minY - recordedMac.minY)
    }
    public static func restored(original: CGRect, placed: CGRect, lastSeen: CGRect, current: CGRect, mac: CGRect) -> CGRect {
        if matches(lastSeen, placed) { return original }
        return isReachable(current, in: mac) ? current : fit(current, from: mac, into: mac)
    }
}
