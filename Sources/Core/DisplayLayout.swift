#if os(macOS)
import Foundation
import CoreGraphics
import Darwin

public struct DisplayLayoutSnapshot: Codable, Sendable {
    public struct Screen: Codable, Sendable {
        public let id: CGDirectDisplayID
        public let x: Int32
        public let y: Int32
        public init(id: CGDirectDisplayID, x: Int32, y: Int32) { self.id = id; self.x = x; self.y = y }
    }
    public let main: CGDirectDisplayID
    public let sessionDisplay: CGDirectDisplayID?
    public let screens: [Screen]
    public init(main: CGDirectDisplayID, sessionDisplay: CGDirectDisplayID?, screens: [Screen]) {
        self.main = main; self.sessionDisplay = sessionDisplay; self.screens = screens
    }
}

public enum DisplayLayoutFailure: Error, LocalizedError {
    case unavailable
    case operation(String, CGError)
    case unsafeLayout
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "This macOS version cannot disable the Mac display."
        case .operation(let name, let code): return "\(name) failed (\(code.rawValue))."
        case .unsafeLayout: return "A separate active iPad desktop is required before disabling the Mac display."
        }
    }
}

/// Only changes enabled state and origins, never resolution, brightness, or mirroring.
public enum DisplayLayout {
    private typealias SetEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError
    private static let framework = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
    private static let setEnabled: SetEnabled? = {
        guard let framework, let address = dlsym(framework, "SLSConfigureDisplayEnabled") else { return nil }
        return unsafeBitCast(address, to: SetEnabled.self)
    }()
    public static var isSupported: Bool { setEnabled != nil }
    public static func online() throws -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32); var count: UInt32 = 0
        try check(CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count), "Read displays")
        return Array(ids.prefix(Int(count)))
    }
    public static func snapshot(sessionDisplay: CGDirectDisplayID? = nil) throws -> DisplayLayoutSnapshot {
        let ids = try online()
        guard ids.allSatisfy({ CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }) else {
            throw DisplayLayoutFailure.unsafeLayout
        }
        return DisplayLayoutSnapshot(main: CGMainDisplayID(), sessionDisplay: sessionDisplay, screens: ids.map {
            let bounds = CGDisplayBounds($0)
            return DisplayLayoutSnapshot.Screen(id: $0, x: Int32(bounds.minX), y: Int32(bounds.minY))
        })
    }
    /// Where every display goes when `display` becomes the main one (the main display is the one at 0, 0) and the
    /// arrangement around it stays as it was.
    public static func origins(withMain display: CGDirectDisplayID, in snapshot: DisplayLayoutSnapshot) -> [DisplayLayoutSnapshot.Screen]? {
        guard let own = snapshot.screens.first(where: { $0.id == display }) else { return nil }
        return snapshot.screens.map { DisplayLayoutSnapshot.Screen(id: $0.id, x: $0.x - own.x, y: $0.y - own.y) }
    }
    /// Makes `display` the main display while every display stays on: only origins change. The Dock and the menu
    /// bar's home follow the main display, which is how the Dock reaches the iPad before the Mac's own display may
    /// be switched off (build 42; pushing the pointer against the bottom edge with injected events did not move it).
    public static func makeMain(_ display: CGDirectDisplayID, snapshot: DisplayLayoutSnapshot) throws {
        let ids = Set(try online())
        guard ids.contains(display), let moved = origins(withMain: display, in: snapshot) else { throw DisplayLayoutFailure.unsafeLayout }
        try configure(scope: .forAppOnly) { config in
            for screen in moved where ids.contains(screen.id) {
                try check(CGConfigureDisplayOrigin(config, screen.id, screen.x, screen.y), "Make iPad the main display")
            }
        }
    }
    public static func makeExclusive(_ display: CGDirectDisplayID, snapshot: DisplayLayoutSnapshot) throws {
        guard let setEnabled else { throw DisplayLayoutFailure.unavailable }
        let ids = Set(try online())
        guard ids.contains(display), snapshot.screens.contains(where: { $0.id == display }),
              snapshot.screens.contains(where: { $0.id != display && ids.contains($0.id) }) else {
            throw DisplayLayoutFailure.unsafeLayout
        }
        try configure(scope: .forAppOnly) { config in
            // Disabling the other displays makes this the only desktop and main display.
            try check(CGConfigureDisplayOrigin(config, display, 0, 0), "Make iPad the main display")
            for screen in snapshot.screens where screen.id != display && ids.contains(screen.id) {
                try check(setEnabled(config, screen.id, false), "Disable Mac display")
            }
        }
        DisplaySwitchClock.noteOff()
    }
    public static func restore(_ snapshot: DisplayLayoutSnapshot) throws {
        guard let setEnabled else { throw DisplayLayoutFailure.unavailable }
        // Enabling an already-online display can reject the whole private-API transaction.
        // Restore each missing display separately, then restore the original arrangement.
        for screen in snapshot.screens where screen.id != 0 {
            if !(try online()).contains(screen.id) {
                // A panel that was only just powered off may not come back if powered on at once.
                // Hold this thread for the rest of the minimum off time (at most 5 s), then turn it on.
                let wait = DisplaySwitchClock.load().waitBeforeOn()
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                guard !(try online()).contains(screen.id) else { continue }
                // A virtual display may have ended with the host. Failure to restore that
                // one must not prevent recovery of the original physical/main display.
                do {
                    try configure(scope: .forSession) { config in
                        try check(setEnabled(config, screen.id, true), "Restore display \(screen.id)")
                    }
                    if screen.id != snapshot.sessionDisplay { DisplaySwitchClock.noteOn() }
                } catch { if screen.id != snapshot.sessionDisplay { throw error } }
            }
        }
        let ids = Set(try online())
        let available = snapshot.screens.filter { ids.contains($0.id) }
        guard available.contains(where: { $0.id == snapshot.main }) else { throw DisplayLayoutFailure.unsafeLayout }
        let changed = available.contains { screen in
            let bounds = CGDisplayBounds(screen.id)
            return Int32(bounds.minX) != screen.x || Int32(bounds.minY) != screen.y
        } || CGMainDisplayID() != snapshot.main
        if changed {
            try configure(scope: .forSession) { config in
                for screen in available {
                    try check(CGConfigureDisplayOrigin(config, screen.id, screen.x, screen.y), "Restore display arrangement")
                }
            }
        }
    }
    public static func isRestored(_ snapshot: DisplayLayoutSnapshot) -> Bool {
        guard let ids = try? online(), ids.contains(snapshot.main), CGMainDisplayID() == snapshot.main else { return false }
        return snapshot.screens.filter { $0.id != snapshot.sessionDisplay || ids.contains($0.id) }.allSatisfy {
            guard ids.contains($0.id) else { return false }
            let bounds = CGDisplayBounds($0.id)
            return Int32(bounds.minX) == $0.x && Int32(bounds.minY) == $0.y
        }
    }
    private static func configure(scope: CGConfigureOption, body: (CGDisplayConfigRef) throws -> Void) throws {
        var config: CGDisplayConfigRef?
        try check(CGBeginDisplayConfiguration(&config), "Begin display change")
        guard let config else { throw DisplayLayoutFailure.unsafeLayout }
        do { try body(config) } catch { CGCancelDisplayConfiguration(config); throw error }
        try check(CGCompleteDisplayConfiguration(config, scope), "Apply display change")
    }
    private static func check(_ error: CGError, _ operation: String) throws {
        if error != .success { throw DisplayLayoutFailure.operation(operation, error) }
    }
}
#endif
