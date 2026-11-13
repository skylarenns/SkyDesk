import Foundation
import Darwin

@MainActor
final class DisplayRecoveryGuard {
    private let process = Process()
    private let pipe = Pipe()
    private let readiness = Pipe()
    private var timer: Timer?
    var onUnexpectedExit: (() -> Void)?
    private var finished = false

    init(snapshot: DisplayLayoutSnapshot, executable: URL? = nil) throws {
        process.executableURL = executable ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SkyDeskRestore")
        process.arguments = [try JSONEncoder().encode(snapshot).base64EncodedString()]
        process.standardInput = pipe
        process.standardOutput = readiness
        process.standardError = FileHandle.standardError
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        try? pipe.fileHandleForReading.close()
        try? readiness.fileHandleForWriting.close()
        var descriptor = pollfd(fd: readiness.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 2000) > 0,
              (try? readiness.fileHandleForReading.read(upToCount: 6)) == Data("ready\n".utf8) else {
            try? pipe.fileHandleForWriting.close()
            throw DisplayLayoutFailure.unavailable
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.finished else { return }
                self.finished = true; self.timer?.invalidate(); self.timer = nil
                self.onUnexpectedExit?()
            }
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return }
                try? self.pipe.fileHandleForWriting.write(contentsOf: Data([1]))
            }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func finish() {
        finished = true; timer?.invalidate(); timer = nil
        // EOF makes the helper independently verify/finish restoration; never kill it.
        try? pipe.fileHandleForWriting.close()
    }
}
