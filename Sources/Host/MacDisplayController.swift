import AppKit
import IOKit.pwr_mgt

/// Owns a temporary iPad-only display arrangement and an independent recovery helper.
@MainActor
final class MacDisplayController {
    private(set) var isEnabled = false
    var onChange: ((Bool) -> Void)?
    var onLayoutChange: (() -> Void)?
    private var snapshot: DisplayLayoutSnapshot?
    private var recovery: DisplayRecoveryGuard?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var appObservers: [NSObjectProtocol] = []
    private let windows = WindowMigrator()
    private var ownFrames: [(window: NSWindow, original: NSRect, placed: NSRect)] = []
    private var assertion: IOPMAssertionID = 0
    private var capturedDisplay: CGDirectDisplayID = 0
    private var generation = UUID()
    private var changing = false
    /// WindowServer keeps re-homing the pointer and re-announcing screens for a moment after the switch.
    private var settledAt: CFTimeInterval = 0
    private var localMoves: [CFTimeInterval] = []
    private static let settleSeconds: CFTimeInterval = 3

    func enable(excluding displayID: CGDirectDisplayID) async throws {
        guard !isEnabled else { return }
        guard AXIsProcessTrusted() else { throw DisplayLayoutFailure.unsafeLayout }
        // The Mac display was only just turned back on: let it stay on a while before turning it off again.
        let wait = DisplaySwitchClock.load().waitBeforeOff()
        if wait > 0 {
            let before = generation
            DisplayLog.write("enable: waiting \(String(format: "%.1f", wait)) s (Mac display was just switched)")
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            // A restore, a new session or another request during the wait cancels this one.
            guard generation == before, !isEnabled else { return }
        }
        let saved = try DisplayLayout.snapshot(sessionDisplay: displayID)
        guard saved.main != displayID, saved.screens.contains(where: { $0.id == displayID }) else {
            throw DisplayLayoutFailure.unsafeLayout
        }
        let token = UUID(); generation = token
        snapshot = saved; capturedDisplay = displayID; isEnabled = true; changing = true
        do {
            recovery = try DisplayRecoveryGuard(snapshot: saved)
            recovery?.onUnexpectedExit = { [weak self] in self?.restore(reason: "recovery helper exited") }
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "SkyDesk iPad-only session" as CFString, &assertion)
            guard result == kIOReturnSuccess else { throw DeskError.system("Keep iPad desktop awake", result) }
            installActivityMonitors()
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.layoutChanged() }
                }
            // Move existing windows while both desktops are still active: this is the
            // ordinary cross-display move, so each window joins the iPad desktop's Space
            // instead of staying behind on the Space of the display being disabled.
            DisplayLog.write("enable: iPad display \(displayID); \(DisplayLog.displays())")
            let desktops = saved.screens.map { CGDisplayBounds($0.id) }
            _ = await windows.migrate(to: Self.usableBounds(of: displayID), desktops: desktops, apps: Self.windowApps())
            guard generation == token, isEnabled else { return }
            seatOwnWindows(on: displayID)
            try DisplayLayout.makeExclusive(displayID, snapshot: saved)
            var verified = false
            for _ in 0..<30 {
                try await Task.sleep(nanoseconds: 100_000_000)
                guard generation == token, isEnabled else { return }
                onLayoutChange?()
                if try DisplayLayout.online() == [displayID], CGMainDisplayID() == displayID {
                    verified = true; break
                }
            }
            guard verified else { throw DeskError.invalid("macOS did not switch to the iPad-only desktop.") }
            settledAt = CACurrentMediaTime() + Self.settleSeconds; localMoves = []
            changing = false; onChange?(true)
            DisplayLog.write("exclusive: \(DisplayLog.displays())")
            observeApps()
            // The iPad desktop's origin just changed. Re-seat anything left off it, again
            // once apps and the Dock have settled on the new arrangement.
            for delay in [0, 700_000_000, 1_800_000_000] as [UInt64] {
                if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                guard generation == token, isEnabled else { return }
                windows.sweep(target: Self.usableBounds(of: displayID), apps: Self.windowApps(), strict: true)
                seatOwnWindows(on: displayID)
            }
        } catch {
            if generation == token { restore(reason: "switch failed: \(error.localizedDescription)") }
            throw error
        }
    }
    func restore(reason: String = "requested by host or iPad") {
        if isEnabled { DisplayLog.write("restore reason: \(reason)") }
        let changed = isEnabled
        generation = UUID(); isEnabled = false; changing = false
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }; globalMonitor = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }; screenObserver = nil
        appObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; appObservers = []
        windows.freeze()
        if let snapshot {
            DisplayLog.write("restore requested: \(DisplayLog.displays())")
            try? DisplayLayout.restore(snapshot)
            // Windows return once the Mac desktop is confirmed back, off the main thread.
            let mac = snapshot.screens.first { $0.id == snapshot.main }
            windows.restore(mac: mac.map { screen in
                CGRect(origin: CGPoint(x: CGFloat(screen.x), y: CGFloat(screen.y)), size: Self.macSize(snapshot.main))
            }) { DisplayLayout.isRestored(snapshot) }
            returnOwnWindows(after: snapshot)
        }
        snapshot = nil
        // EOF asks a separate WindowServer client to verify/complete recovery, even
        // if the host's display cache is stale or the host exits during restoration.
        recovery?.finish(); recovery = nil
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        capturedDisplay = 0
        onLayoutChange?()
        if changed { onChange?(false) }
    }
    private func installActivityMonitors() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged, .mouseMoved,
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .rightMouseDragged,
            .otherMouseDragged, .scrollWheel, .magnify, .rotate, .swipe]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.restoreForLocalActivity(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.restoreForLocalActivity(event) }
            return event
        }
    }
    private func restoreForLocalActivity(_ event: NSEvent) {
        guard isEnabled, let cgEvent = event.cgEvent, RemoteInputOrigin.isLocalActivity(cgEvent) else { return }
        if [.magnify, .rotate, .swipe, .smartMagnify, .gesture].contains(event.type), RemoteInputOrigin.gestureJustInjected() { return }
        // WindowServer relocates the pointer during a topology change. Ignore that
        // transition motion, but let a deliberate key or click cancel immediately.
        if event.type == .mouseMoved {
            let now = CACurrentMediaTime()
            if changing || now < settledAt { return }
            // One stray pointer event is not a person at the Mac: require real, repeated motion.
            guard event.deltaX != 0 || event.deltaY != 0 else { return }
            localMoves = localMoves.filter { now - $0 < 1 } + [now]
            guard localMoves.count >= 3 else { return }
        }
        restore(reason: "local input type \(event.type.rawValue) "
            + "source pid \(cgEvent.getIntegerValueField(.eventSourceUnixProcessID)) state \(cgEvent.getIntegerValueField(.eventSourceStateID))")
    }
    /// New, unhidden or reactivated apps may bring windows that sit off the iPad desktop
    /// (for example one restored from the Dock). Only rescue ones the user cannot reach.
    private func observeApps() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification] {
            appObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
                MainActor.assumeIsolated {
                    guard let self, self.isEnabled, !self.changing, let pid else { return }
                    let display = self.capturedDisplay, token = self.generation
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        guard self.generation == token, self.isEnabled else { return }
                        self.windows.sweep(target: Self.usableBounds(of: display), apps: [pid], strict: false)
                    }
                }
            })
        }
    }
    /// The host's own windows, moved with AppKit on the main thread.
    private func seatOwnWindows(on display: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }) else { return }
        let area = screen.visibleFrame
        for window in NSApp.windows where window.isVisible && !window.isMiniaturized
            && window.styleMask.contains(.titled) && !window.styleMask.contains(.fullScreen) {
            guard !area.insetBy(dx: -2, dy: -2).contains(window.frame) else { continue }
            let original = window.frame
            let size = NSSize(width: min(original.width, area.width), height: min(original.height, area.height))
            let fitted = NSRect(x: area.midX - size.width / 2, y: area.maxY - size.height, width: size.width, height: size.height)
            window.setFrame(fitted, display: true)
            if let index = ownFrames.firstIndex(where: { $0.window === window }) { ownFrames[index].placed = window.frame }
            else { ownFrames.append((window, original, window.frame)) }
        }
    }
    private func returnOwnWindows(after snapshot: DisplayLayoutSnapshot) {
        let saved = ownFrames; ownFrames = []
        guard !saved.isEmpty else { return }
        Task { @MainActor in
            for _ in 0..<40 where !DisplayLayout.isRestored(snapshot) { try? await Task.sleep(nanoseconds: 100_000_000) }
            guard DisplayLayout.isRestored(snapshot), !isEnabled else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            // Same rule as other apps: only windows the user did not move themselves go back.
            for entry in saved where entry.window.isVisible && entry.window.frame.size == entry.placed.size {
                entry.window.setFrame(entry.original, display: true)
            }
        }
    }
    private static func windowApps() -> [pid_t] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited && !$0.isTerminated }
            .map(\.processIdentifier)
    }
    /// Display bounds minus menu bar and Dock, in global top-left coordinates.
    private static func usableBounds(of display: CGDirectDisplayID) -> CGRect {
        let bounds = CGDisplayBounds(display)
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }), screen.frame.size == bounds.size {
            // Insets are arrangement-independent, unlike a stale NSScreen origin mid-change.
            let frame = screen.frame, visible = screen.visibleFrame
            let usable = CGRect(x: bounds.minX + (visible.minX - frame.minX), y: bounds.minY + (frame.maxY - visible.maxY),
                                width: visible.width, height: visible.height)
            if usable.width >= 320, usable.height >= 240 { return usable }
        }
        let menuBar = min(40, max(24, NSStatusBar.system.thickness + 1))
        return CGRect(x: bounds.minX, y: bounds.minY + menuBar, width: bounds.width, height: bounds.height - menuBar)
    }
    private static func macSize(_ display: CGDirectDisplayID) -> CGSize {
        // A disabled display reports no bounds; its current mode still describes the desktop.
        let bounds = CGDisplayBounds(display)
        if bounds.width > 0, bounds.height > 0 { return bounds.size }
        if let mode = CGDisplayCopyDisplayMode(display) { return CGSize(width: mode.width, height: mode.height) }
        return CGSize(width: 1440, height: 900)
    }
    private func layoutChanged() {
        onLayoutChange?()
        guard isEnabled, !changing else { return }
        let wait = settledAt - CACurrentMediaTime()
        if wait > 0 {
            // Screen announcements right after the switch can describe a state that is already gone; look again once settled.
            let token = generation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64((wait + 0.1) * 1_000_000_000))
                if self.generation == token { self.layoutChanged() }
            }
            return
        }
        guard let online = try? DisplayLayout.online() else { return }
        if online != [capturedDisplay] || CGMainDisplayID() != capturedDisplay {
            restore(reason: "display layout changed: \(DisplayLog.displays())")
        }
    }
}
