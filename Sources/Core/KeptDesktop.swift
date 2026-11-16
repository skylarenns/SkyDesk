import Foundation

/// Keeping the iPad-only desktop while no iPad is connected (build 45, user request 2026-11-15).
///
/// Without it every disconnect switches the Mac's displays back on and every reconnect switches them off again,
/// with the wait that protects the built-in panel in between. With it the virtual display and the iPad-only
/// arrangement stay as they are and the returning iPad gets its desktop back at once. Only the decisions live
/// here, so they can be tested; the display work is in the host.
public enum KeptDesktop {
    /// Why a session ended.
    public enum SessionEnd: Equatable {
        /// The iPad went away: it disconnected, left the screen for too long, or stopped answering.
        case padLeft
        /// The Mac ended it: sharing stopped, quit, sleep, a removed iPad, a failed capture.
        case hostEnded
    }
    /// What the virtual display was built for; a returning iPad must want exactly this.
    public struct Shape: Equatable, Sendable {
        public var width: Int, height: Int, fps: Int
        public init(width: Int, height: Int, fps: Int) { self.width = width; self.height = height; self.fps = fps }
    }
    /// The host setting: how long the desktop is kept with no iPad connected. 0 switches keeping off.
    public static let choices = [0, 1, 10, 60, forever]
    public static let forever = -1
    /// Ten minutes by default: long enough to come back after a dropped connection or a look at another app,
    /// short enough that a Mac left alone gets its display back and may sleep again (asked for twice, 2026-11-15:
    /// "doesn't immediately go back to computer mode").
    public static let defaultMinutes = 10
    /// Seconds after which a kept desktop is given up; nil = no limit.
    public static func limit(minutes: Int) -> TimeInterval? { minutes > 0 ? TimeInterval(minutes) * 60 : nil }
    public static func label(minutes: Int) -> String {
        switch minutes {
        case 0: return "Go back to the Mac's display at once"
        case forever: return "Stay in iPad only until someone uses the Mac"
        case 1: return "Stay in iPad only for 1 minute"
        case 60: return "Stay in iPad only for 1 hour"
        default: return "Stay in iPad only for \(minutes) minutes"
        }
    }
    /// `padOnly` means the iPad's desktop is the Mac's only display right now and the switch has finished.
    /// A Mac update that is waiting needs the displays back before it can install, so it wins.
    public static func shouldKeep(setting: Bool, padOnly: Bool, end: SessionEnd, macUpdateWaiting: Bool) -> Bool {
        setting && padOnly && end == .padLeft && !macUpdateWaiting
    }
    public static func canReuse(kept: Shape?, wanted: Shape, padOnly: Bool) -> Bool {
        padOnly && kept == wanted
    }
}
