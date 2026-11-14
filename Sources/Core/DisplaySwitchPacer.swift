import Foundation

/// Keeps the Mac's built-in panel from being powered off and on in quick succession.
///
/// Incident of 2026-11-13: iPad-only was switched on and off nine times in 84 s around an update, twice with the
/// panel off for only ~2 s. WindowServer reported the last power-on as complete, but the panel stayed dark until
/// the display was put to sleep for 12 s and woken. So a panel that was just turned off stays off for a minimum
/// time, and one that was just turned on stays on for a minimum time before it may be turned off again.
public struct DisplaySwitchPacer: Codable, Equatable, Sendable {
    /// Shortest time the built-in display stays off before it is turned back on.
    public static let minimumOffSeconds: Double = 5
    /// Shortest time the built-in display stays on before iPad-only may turn it off again.
    public static let minimumOnSeconds: Double = 20
    public var lastOff: Date?
    public var lastOn: Date?
    public init(lastOff: Date? = nil, lastOn: Date? = nil) { self.lastOff = lastOff; self.lastOn = lastOn }

    /// Seconds to wait before the display may be turned back on. Never more than `minimumOffSeconds`.
    public func waitBeforeOn(now: Date = Date()) -> Double { Self.remaining(lastOff, Self.minimumOffSeconds, now) }
    /// Seconds to wait before the display may be turned off. Never more than `minimumOnSeconds`.
    public func waitBeforeOff(now: Date = Date()) -> Double { Self.remaining(lastOn, Self.minimumOnSeconds, now) }
    private static func remaining(_ last: Date?, _ minimum: Double, _ now: Date) -> Double {
        guard let last else { return 0 }
        let elapsed = now.timeIntervalSince(last)
        // A timestamp from the future (clock change) must not hold the display hostage.
        guard elapsed >= 0 else { return 0 }
        return max(0, minimum - elapsed)
    }
}

#if os(macOS)
/// The pacer's state on disk, shared by SkyDesk Host and the SkyDeskRestore helper and kept across host restarts
/// (an update relaunches the host between a restore and the next iPad-only switch).
public enum DisplaySwitchClock {
    public static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SkyDesk/display-switch.json")
    public static func load(from url: URL = url) -> DisplaySwitchPacer {
        guard let data = try? Data(contentsOf: url),
              let pacer = try? JSONDecoder().decode(DisplaySwitchPacer.self, from: data) else { return DisplaySwitchPacer() }
        return pacer
    }
    public static func noteOff(at date: Date = Date(), url: URL = url) { var pacer = load(from: url); pacer.lastOff = date; save(pacer, url) }
    public static func noteOn(at date: Date = Date(), url: URL = url) { var pacer = load(from: url); pacer.lastOn = date; save(pacer, url) }
    private static func save(_ pacer: DisplaySwitchPacer, _ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(pacer).write(to: url, options: .atomic)
    }
}
#endif

/// Whether the iPad should switch to iPad-only by itself right after connecting.
///
/// Always when the setting is on (user, 2026-11-13: it must also happen after an update or a quick reconnection).
/// Spacing the display switches is the Mac's job (`DisplaySwitchPacer`); the iPad shows "Switching…" meanwhile.
public enum AutoPadOnly {
    public static func shouldStart(setting: Bool, supported: Bool) -> Bool { setting && supported }
}
