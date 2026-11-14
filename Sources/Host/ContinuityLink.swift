import Foundation

/// Switches the Mac's AirDrop/Continuity radio link (awdl0) off for the length of a stream.
///
/// While awdl0 is up the Wi-Fi radio leaves the network's channel about twice a second, which stalled every packet
/// for up to ~95 ms (measured 2026-11-12: worst ping 97 ms with it up, 12 ms with it down). Needs the sudo rule in
/// /etc/sudoers.d/skydesk-awdl; without it this does nothing. AirDrop, AirPlay, Sidecar and Universal Control are
/// unavailable on the Mac while a client is connected.
enum ContinuityLink {
    private static let queue = DispatchQueue(label: "skydesk.continuity-link", qos: .utility)
    private static var suspendedByUs = false
    private static var watcher: DispatchSourceTimer?
    private static var reEnabled = 0

    /// Call when a stream starts and periodically while it runs: macOS switches the link back on by itself.
    static func suspend() {
        queue.async {
            startWatching()
            guard isUp() else { return }
            if run("down") {
                if !suspendedByUs { MetricsLog.shared.append("host  AirDrop link (awdl0) off for this stream"); reEnabled = 0 }
                suspendedByUs = true
            }
        }
    }
    /// Call when the stream ends. Only switches the link back on if this app switched it off.
    static func resume() {
        queue.async {
            watcher?.cancel(); watcher = nil
            guard suspendedByUs else { return }
            suspendedByUs = false
            if run("up") { MetricsLog.shared.append("host  AirDrop link (awdl0) back on") }
        }
    }
    /// macOS re-enables the link on its own (AirDrop, Handoff, Universal Control activity). Each second it stays up
    /// costs ~2 radio stalls of up to ~95 ms, so it is checked 4 times a second while streaming; the check is a
    /// getifaddrs call, and sudo runs only when the link actually came back.
    private static func startWatching() {
        guard watcher == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(20))
        timer.setEventHandler {
            guard suspendedByUs, isUp() else { return }
            reEnabled += 1
            let switched = run("down")
            MetricsLog.shared.append("host  AirDrop link (awdl0) came back on by itself (#\(reEnabled) this stream)" + (switched ? "; off again" : "; could NOT switch it off"))
        }
        watcher = timer; timer.resume()
    }
    private static func isUp() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return false }
        defer { freeifaddrs(list) }
        var entry = list
        while let current = entry {
            if String(cString: current.pointee.ifa_name) == "awdl0" { return current.pointee.ifa_flags & UInt32(IFF_UP) != 0 }
            entry = current.pointee.ifa_next
        }
        return false
    }
    private static func run(_ state: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "/sbin/ifconfig", "awdl0", state]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
