import AppKit
import Darwin

// Independent recovery process. Parent writes a heartbeat every second and closes
// the pipe on restoration. EOF or a six-second stall restores the saved layout.
guard CommandLine.arguments.count == 2,
      let data = Data(base64Encoded: CommandLine.arguments[1]),
      let snapshot = try? JSONDecoder().decode(DisplayLayoutSnapshot.self, from: data),
      DisplayLayout.isSupported else { exit(2) }
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
enum Recovery {
@MainActor static func run(_ snapshot: DisplayLayoutSnapshot, remaining: Int) {
    do { try DisplayLayout.restore(snapshot) } catch { fputs("SkyDesk recovery: \(error.localizedDescription)\n", stderr) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        if DisplayLayout.isRestored(snapshot) { exit(0) }
        if remaining > 0 { run(snapshot, remaining: remaining - 1) }
        else { fputs("SkyDesk display recovery could not verify the original main display.\n", stderr); exit(1) }
    }
}
}
DispatchQueue.global(qos: .userInitiated).async {
    var lastBeat = ProcessInfo.processInfo.systemUptime
    var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
    while ProcessInfo.processInfo.systemUptime - lastBeat < 6 {
        let ready = poll(&descriptor, 1, 250)
        if ready > 0 {
            var bytes = [UInt8](repeating: 0, count: 64)
            if read(STDIN_FILENO, &bytes, bytes.count) <= 0 { break }
            lastBeat = ProcessInfo.processInfo.systemUptime
        } else if ready < 0 && errno != EINTR { break }
    }
    DispatchQueue.main.async { Recovery.run(snapshot, remaining: 8) }
}
FileHandle.standardOutput.write(Data("ready\n".utf8))
app.run()
