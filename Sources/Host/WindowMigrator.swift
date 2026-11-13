import AppKit
import ApplicationServices

/// Moves existing app windows onto the iPad desktop for an iPad-only session and
/// returns them when the Mac desktop comes back. Reads and writes only window
/// geometry through Accessibility, never titles or contents. All Accessibility
/// calls run off the main thread so a slow app cannot stall the recovery heartbeat.
final class WindowMigrator: @unchecked Sendable {
    private struct Entry {
        let element: AXUIElement
        let pid: pid_t
        let original: CGRect
        var placed: CGRect
        var lastSeen: CGRect
    }
    private let queue = DispatchQueue(label: "skydesk.window-migration", qos: .userInitiated)
    private var entries: [Entry] = []
    private var active = false
    private var timer: DispatchSourceTimer?
    private let frozen = NSLock()
    private var isFrozen = false
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Step 1, while both desktops are still active: remember every movable window
    /// and move the ones on other desktops onto the iPad desktop.
    func migrate(to target: CGRect, desktops: [CGRect], apps: [pid_t]) async -> Int {
        await withCheckedContinuation { continuation in
            queue.async {
                self.entries = []; self.active = true; self.setFrozen(false)
                var moved = 0
                for pid in apps {
                    for element in self.windows(of: pid) {
                        guard let frame = self.frame(of: element) else { continue }
                        var entry = Entry(element: element, pid: pid, original: frame, placed: frame, lastSeen: frame)
                        if !WindowPlacement.isContained(frame, in: target) {
                            let source = WindowPlacement.desktop(for: frame, among: desktops) ?? target
                            entry.placed = self.place(element, WindowPlacement.fit(frame, from: source, into: target), shrinkFirst: true)
                            entry.lastSeen = entry.placed
                            moved += 1
                        }
                        self.entries.append(entry)
                    }
                }
                self.startTracking()
                DisplayLog.write("migrate: \(self.entries.count) windows recorded, \(moved) moved to \(target)")
                continuation.resume(returning: moved)
            }
        }
    }
    /// Step 2, after the iPad became the only desktop (its origin changed): put any
    /// window that is not on it back on it. `strict` requires the whole window to fit;
    /// later sweeps only rescue windows the user could not reach.
    func sweep(target: CGRect, apps: [pid_t], strict: Bool) {
        queue.async {
            guard self.active, !self.frozenNow else { return }
            var fixed = 0
            for pid in apps {
                for element in self.windows(of: pid) {
                    guard let frame = self.frame(of: element) else { continue }
                    let fine = strict ? WindowPlacement.isContained(frame, in: target) : WindowPlacement.isReachable(frame, in: target)
                    let index = self.entries.firstIndex { CFEqual($0.element, element) }
                    if fine {
                        // First strict pass: the origin change shifts coordinates of windows
                        // that were moved in step 1. Track where they actually are now.
                        if strict, let index { self.entries[index].placed = frame; self.entries[index].lastSeen = frame }
                        continue
                    }
                    let placed = self.place(element, WindowPlacement.fit(frame, from: frame.union(target), into: target), shrinkFirst: true)
                    if let index { self.entries[index].placed = placed; self.entries[index].lastSeen = placed }
                    fixed += 1
                }
            }
            if fixed > 0 || strict { DisplayLog.write("sweep(strict \(strict)): \(fixed) windows brought onto \(target)") }
        }
    }
    /// Call synchronously before the display arrangement is changed back, so tracking
    /// never mistakes the coordinate shift of a display change for a user move.
    func freeze() { setFrozen(true) }
    /// Step 3: wait (bounded) for the Mac desktop, then return windows to it.
    func restore(mac: CGRect?, ready: @escaping @Sendable () -> Bool) {
        setFrozen(true)
        queue.async {
            guard self.active else { return }
            self.active = false; self.timer?.cancel(); self.timer = nil
            let saved = self.entries; self.entries = []
            var isReady = ready()
            for _ in 0..<40 where !isReady { usleep(100_000); isReady = ready() }
            guard isReady, let mac else {
                DisplayLog.write("restore: Mac desktop not confirmed; \(saved.count) windows left in place")
                return
            }
            usleep(250_000) // let apps observe the new screen arrangement first
            var goals: [(AXUIElement, CGRect)] = []
            var returned = 0, kept = 0
            for entry in saved {
                guard let current = self.frame(of: entry.element) else { continue }
                let goal = WindowPlacement.restored(original: entry.original, placed: entry.placed,
                                                    lastSeen: entry.lastSeen, current: current, mac: mac)
                if WindowPlacement.matches(goal, entry.original) { returned += 1 } else { kept += 1 }
                goals.append((entry.element, goal))
            }
            // Two passes: some apps re-clamp their frame once after a screen change.
            for pass in 0..<2 {
                for (element, goal) in goals {
                    guard let current = self.frame(of: element), !WindowPlacement.matches(current, goal) else { continue }
                    _ = self.place(element, goal, shrinkFirst: false)
                }
                if pass == 0 { usleep(400_000) }
            }
            DisplayLog.write("restore: \(returned) windows to original frames, \(kept) user-moved windows kept; \(DisplayLog.displays())")
        }
    }
    private var frozenNow: Bool { frozen.lock(); defer { frozen.unlock() }; return isFrozen }
    private func setFrozen(_ value: Bool) { frozen.lock(); isFrozen = value; frozen.unlock() }
    /// Remembers where each migrated window is, so a user's own move or resize on the
    /// iPad desktop is respected when the Mac desktop returns.
    private func startTracking() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // First reading comes after the display switch and its strict sweeps have settled.
        timer.schedule(deadline: .now() + 6, repeating: .seconds(2), leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in
            guard let self, self.active else { return }
            for index in self.entries.indices {
                guard !self.frozenNow else { return }
                if let frame = self.frame(of: self.entries[index].element), !self.frozenNow {
                    self.entries[index].lastSeen = frame
                }
            }
        }
        self.timer = timer; timer.resume()
    }

    // MARK: Accessibility geometry
    private func windows(of pid: pid_t) -> [AXUIElement] {
        // Accessibility calls on our own process run in-process on this background thread,
        // and AppKit traps when a window frame is set off the main thread. The host's own
        // windows are moved with AppKit by MacDisplayController instead.
        guard pid != ownPID else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let raw = attribute(app, kAXWindowsAttribute), let list = raw as? [AXUIElement] else { return [] }
        return list.filter { window in
            AXUIElementSetMessagingTimeout(window, 0.25)
            guard (attribute(window, kAXRoleAttribute) as? String) == kAXWindowRole,
                  (attribute(window, kAXMinimizedAttribute) as? Bool) != true,
                  (attribute(window, "AXFullScreen") as? Bool) != true else { return false }
            var settable: DarwinBoolean = false
            return AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable) == .success && settable.boolValue
        }
    }
    private func frame(of window: AXUIElement) -> CGRect? {
        guard let position = attribute(window, kAXPositionAttribute), let size = attribute(window, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero; var extent = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &extent),
              extent.width >= 50, extent.height >= 50 else { return nil }
        return CGRect(origin: point, size: extent)
    }
    /// Returns the frame the app actually accepted (apps may enforce minimum sizes).
    private func place(_ window: AXUIElement, _ frame: CGRect, shrinkFirst: Bool) -> CGRect {
        var point = frame.origin; var extent = frame.size
        guard let position = AXValueCreate(.cgPoint, &point), let size = AXValueCreate(.cgSize, &extent) else { return frame }
        // Size is clamped to the display the window is on, so set it on both sides of the move.
        if shrinkFirst { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, size) }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, size)
        if !shrinkFirst { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) }
        return self.frame(of: window) ?? frame
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}

/// Small local diagnostic log for display switches: display IDs, bounds and window
/// counts only. ~/Library/Logs/SkyDesk/display-session.log, truncated past 256 KiB.
enum DisplayLog {
    private static let queue = DispatchQueue(label: "skydesk.display-log", qos: .utility)
    private static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/SkyDesk/display-session.log")
    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 262_144 {
                try? manager.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8))
            } else { try? Data(line.utf8).write(to: url) }
        }
    }
    static func displays() -> String {
        let ids = (try? DisplayLayout.online()) ?? []
        return "online \(ids.map { "\($0)@\(CGDisplayBounds($0))" }) main \(CGMainDisplayID())"
    }
}
