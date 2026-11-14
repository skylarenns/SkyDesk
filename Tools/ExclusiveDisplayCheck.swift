import AppKit

@main struct ExclusiveDisplayCheck {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        DispatchQueue.main.async {
            Task { @MainActor in
                var virtual: SkyDeskVirtualDisplay?
                var snapshot: DisplayLayoutSnapshot?
                var recovery: DisplayRecoveryGuard?
                var passed = false
                do {
                    guard try DisplayLayout.online().count == 1 else { throw DisplayLayoutFailure.unsafeLayout }
                    let display = try SkyDeskVirtualDisplay(pixelWidth: 2752, height: 2064, refreshRate: 120)
                    virtual = display
                    try await Task.sleep(nanoseconds: 100_000_000); try display.activate()
                    for _ in 0..<30 {
                        if CGDisplayCopyDisplayMode(display.displayID) != nil { break }
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    let saved = try DisplayLayout.snapshot(sessionDisplay: display.displayID); snapshot = saved
                    guard saved.screens.count == 2 else { throw DisplayLayoutFailure.unsafeLayout }
                    recovery = try DisplayRecoveryGuard(snapshot: saved, executable: URL(fileURLWithPath: "/tmp/skydesk-restore"))
                    print("Recovery helper ready; original main \(saved.main), iPad display \(display.displayID)"); fflush(stdout)
                    try DisplayLayout.makeExclusive(display.displayID, snapshot: saved)
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    let online = try DisplayLayout.online()
                    passed = online == [display.displayID] && CGMainDisplayID() == display.displayID
                    print("Exclusive online displays: \(online); main: \(CGMainDisplayID()); passed: \(passed)"); fflush(stdout)
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    if CommandLine.arguments.contains("--helper-recovery") {
                        print("Closing heartbeat pipe; recovery helper must restore the layout"); fflush(stdout)
                        recovery?.finish()
                    } else { try DisplayLayout.restore(saved) }
                } catch { fputs("Exclusive check: \(error.localizedDescription)\n", stderr) }
                recovery?.finish()
                if let snapshot {
                    for _ in 0..<50 {
                        if DisplayLayout.isRestored(snapshot) { break }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    let restored = DisplayLayout.isRestored(snapshot)
                    print("Original layout restored: \(restored)"); passed = passed && restored
                }
                virtual?.invalidate()
                try? await Task.sleep(nanoseconds: 500_000_000)
                exit(passed ? 0 : 1)
            }
        }
        app.run()
    }
}
