import XCTest
@testable import SkyDeskCore

final class FileTransferTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("skydesk-ft-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testSanitisedNamesNeverLeaveTheFolder() throws {
        XCTAssertEqual(FileNames.sanitized("../../etc/passwd"), "passwd")
        XCTAssertEqual(FileNames.sanitized("a/b\\c.txt"), "c.txt")
        XCTAssertEqual(FileNames.sanitized(".hidden"), "hidden")
        XCTAssertEqual(FileNames.sanitized(".."), "File")
        XCTAssertEqual(FileNames.sanitized("   "), "File")
        XCTAssertEqual(FileNames.sanitized("x\u{0}y\u{7}z:w.pdf"), "xyzw.pdf")
        XCTAssertEqual(FileNames.sanitized("Report final.pdf"), "Report final.pdf")
        let long = FileNames.sanitized(String(repeating: "é", count: 300) + ".jpeg")
        XCTAssertLessThanOrEqual(long.utf8.count, 180); XCTAssertTrue(long.hasSuffix(".jpeg"))
        for hostile in ["../x", "/etc/hosts", "..\\..\\x", "a/../../b", "~/x", "%2e%2e/x"] {
            let url = try FileNames.uniqueURL(for: hostile, in: root)
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, root.standardizedFileURL.path, hostile)
        }
    }
    func testUniqueNamesDoNotOverwrite() throws {
        FileManager.default.createFile(atPath: root.appendingPathComponent("photo.jpg").path, contents: Data([1]))
        FileManager.default.createFile(atPath: root.appendingPathComponent("photo 2.jpg").path, contents: Data([2]))
        XCTAssertEqual(try FileNames.uniqueURL(for: "photo.jpg", in: root).lastPathComponent, "photo 3.jpg")
        XCTAssertEqual(try FileNames.uniqueURL(for: "notes", in: root).lastPathComponent, "notes")
    }
    func testChunkRoundTripAndPacketLimit() throws {
        let chunk = FileChunk(id: UUID(), offset: 123_456_789, data: Data((0..<FileSender.chunkSize).map { UInt8($0 & 255) }))
        let packet = chunk.packet()
        XCTAssertNoThrow(try packet.encoded())
        XCTAssertEqual(try FileChunk(packet: packet), chunk)
        var parser = WireParser()
        let wire = try packet.encoded()
        var parsed: [WirePacket] = []
        for start in stride(from: 0, to: wire.count, by: 64 * 1_024) { parsed += try parser.append(wire.subdata(in: start..<min(wire.count, start + 64 * 1_024))) }
        XCTAssertEqual(parsed.count, 1); XCTAssertEqual(try FileChunk(packet: parsed[0]), chunk)
        XCTAssertThrowsError(try WirePacket(kind: .file, payload: Data(count: FileSender.chunkSize + 65)).encoded())
    }
    func testReceiverRejectsGapsOversizeAndShortFiles() throws {
        let receiver = FileReceiver(directory: root)
        let id = UUID()
        try receiver.offer(id: id, name: "a.bin", size: 10)
        XCTAssertThrowsError(try receiver.write(FileChunk(id: id, offset: 5, data: Data(count: 5))), "gap")
        XCTAssertEqual(receiver.activeCount, 0, "a bad chunk cancels and deletes the partial file")
        let short = UUID()
        try receiver.offer(id: short, name: "b.bin", size: 10)
        try receiver.write(FileChunk(id: short, offset: 0, data: Data(count: 4)))
        XCTAssertThrowsError(try receiver.complete(id: short))
        let over = UUID()
        try receiver.offer(id: over, name: "c.bin", size: 3)
        XCTAssertThrowsError(try receiver.write(FileChunk(id: over, offset: 0, data: Data(count: 4))))
        XCTAssertThrowsError(try receiver.offer(id: UUID(), name: "huge", size: FileReceiver.maxFileSize + 1))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(leftovers, [], "no partial files left behind")
    }
    func testSenderNeverRunsMoreThanAWindowAhead() throws {
        let source = root.appendingPathComponent("big.bin")
        try Data(count: Int(FileSender.window) * 3 + 17).write(to: source)
        let sender = try FileSender(url: source)
        var chunks = 0
        while try sender.nextChunk() != nil { chunks += 1 }
        XCTAssertEqual(sender.sent, FileSender.window)
        XCTAssertEqual(chunks, Int(FileSender.window) / FileSender.chunkSize)
        sender.acknowledge(FileSender.window)
        XCTAssertNotNil(try sender.nextChunk())
        XCTAssertThrowsError(try FileSender(url: root), "folders are refused")
    }
    /// Two engines wired back to back, as on a real file channel: files in both directions, a zero-byte file,
    /// a hostile name, and a byte-for-byte comparison of what arrives.
    func testEnginesTransferFilesBothWays() throws {
        let macDir = root.appendingPathComponent("mac"), padDir = root.appendingPathComponent("pad"), src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let mac = FileTransferEngine(directory: macDir, queue: DispatchQueue(label: "mac"), bytesPerSecond: 1e10)
        let pad = FileTransferEngine(directory: padDir, queue: DispatchQueue(label: "pad"), bytesPerSecond: 1e10)
        func wire(_ from: FileTransferEngine, _ to: FileTransferEngine) {
            from.sendMessage = { message in to.handle(try! WirePacket.control(message)) }
            from.sendPacket = { packet, done in to.handle(packet); done(true) }
        }
        wire(mac, pad); wire(pad, mac)
        let big = Data((0..<(5 * 1_024 * 1_024 + 333)).map { _ in UInt8.random(in: 0...255) })
        try big.write(to: src.appendingPathComponent("movie.mov"))
        try Data().write(to: src.appendingPathComponent("empty.txt"))
        try Data("hi".utf8).write(to: src.appendingPathComponent("plain.txt"))
        let saved = expectation(description: "three files saved"); saved.expectedFulfillmentCount = 3
        let lock = NSLock(); var outcomes: [String: FileTransferEngine.Progress.State] = [:]
        for engine in [mac, pad] {
            engine.onProgress = { progress in
                guard progress.outgoing, progress.state != .active else { return }
                lock.lock(); outcomes[progress.name] = progress.state; lock.unlock(); saved.fulfill()
            }
        }
        pad.send(fileAt: src.appendingPathComponent("movie.mov"))
        pad.send(fileAt: src.appendingPathComponent("empty.txt"))
        mac.send(fileAt: src.appendingPathComponent("plain.txt"), name: "../../Library/evil.txt")
        wait(for: [saved], timeout: 20)
        XCTAssertEqual(outcomes["movie.mov"], .saved("movie.mov"))
        XCTAssertEqual(outcomes["empty.txt"], .saved("empty.txt"))
        XCTAssertEqual(outcomes["evil.txt"], .saved("evil.txt"))
        XCTAssertEqual(try Data(contentsOf: macDir.appendingPathComponent("movie.mov")), big)
        XCTAssertEqual(try Data(contentsOf: macDir.appendingPathComponent("empty.txt")), Data())
        XCTAssertEqual(try Data(contentsOf: padDir.appendingPathComponent("evil.txt")), Data("hi".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: padDir.path).sorted(), ["evil.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Library").path))
    }
    func testClosingFailsActiveTransfersAndRemovesPartials() throws {
        let dir = root.appendingPathComponent("in")
        let engine = FileTransferEngine(directory: dir, queue: DispatchQueue(label: "x"))
        let id = UUID()
        engine.sendMessage = { _ in }
        let failed = expectation(description: "failed")
        engine.onProgress = { if case .failed = $0.state { failed.fulfill() } }
        engine.handle(try WirePacket.control(.file(FileEvent(kind: .offer, id: id, name: "a", size: 100))))
        engine.handle(FileChunk(id: id, offset: 0, data: Data(count: 10)).packet())
        engine.close(reason: "Disconnected")
        wait(for: [failed], timeout: 5)
        engine.queue.sync {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }
}

final class ClipboardSyncTests: XCTestCase {
    func testLocalChangeIsSentOnceAndRemoteWriteIsNotEchoed() {
        var mac = ClipboardSync(changeCount: 10)
        var pad = ClipboardSync(changeCount: 500)
        XCTAssertFalse(mac.localChanged(changeCount: 10), "nothing copied since connect")
        // User copies on the Mac.
        XCTAssertTrue(mac.localChanged(changeCount: 11))
        let sent = mac.outgoing("hello")
        XCTAssertEqual(sent, "hello")
        // iPad receives and writes it; the write bumps the iPad counter but must not bounce back.
        XCTAssertTrue(pad.incoming("hello"))
        pad.wroteRemote(changeCount: 501)
        XCTAssertFalse(pad.localChanged(changeCount: 501))
        // Even if the counter moves for the same text (an app rewriting it), it is not sent back.
        XCTAssertTrue(pad.localChanged(changeCount: 502))
        XCTAssertNil(pad.outgoing("hello"))
        // A real new copy on the iPad goes to the Mac, and the Mac does not echo it.
        XCTAssertTrue(pad.localChanged(changeCount: 503))
        XCTAssertEqual(pad.outgoing("from iPad"), "from iPad")
        XCTAssertTrue(mac.incoming("from iPad")); mac.wroteRemote(changeCount: 12)
        XCTAssertFalse(mac.localChanged(changeCount: 12))
        XCTAssertFalse(mac.incoming("from iPad"), "duplicate delivery is ignored")
    }
    func testLimitsAndEmptyText() {
        var sync = ClipboardSync(changeCount: 0)
        XCTAssertNil(sync.outgoing(nil)); XCTAssertNil(sync.outgoing(""))
        XCTAssertNotNil(sync.outgoing(String(repeating: "a", count: ClipboardSync.maxBytes)))
        XCTAssertNil(sync.outgoing(String(repeating: "b", count: ClipboardSync.maxBytes + 1)))
        // Heavily escaped text that would overflow a 64 KiB control packet is refused, not truncated.
        XCTAssertFalse(ClipboardSync.fits(String(repeating: "\u{1}", count: 12_000)))
        XCTAssertFalse(sync.incoming(String(repeating: "c", count: ClipboardSync.maxBytes + 1)))
    }
}

import Network
final class FileTransferTLSTests: XCTestCase {
    func testFileCrossesARealEncryptedChannelWithPacing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skydesk-tls-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let key = try PairingPassword.deriveKey("file-test-1", iterations: 1_000)
        let queue = DispatchQueue(label: "skydesk.test.files")
        let parameters = DeskNetwork.parameters(key: key)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let receiver = FileTransferEngine(directory: root.appendingPathComponent("in"), queue: DispatchQueue(label: "rx"))
        var server: SecureChannel?
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            let peer = SecureChannel(connection: connection, queue: queue)
            server = peer
            receiver.sendMessage = { [weak peer] in peer?.send($0) }
            receiver.sendPacket = { [weak peer] packet, done in peer?.send(packet, completion: done) }
            peer.onPacket = { receiver.handle($0) }
            peer.start()
        }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 5)
        let client = SecureChannel(connection: NWConnection(host: "127.0.0.1", port: listener.port!, using: DeskNetwork.parameters(key: key)), queue: queue)
        // 40 MB/s pacing: a 3 MiB file must take at least ~70 ms, proving the pacing path runs.
        let sender = FileTransferEngine(directory: root.appendingPathComponent("unused"), queue: DispatchQueue(label: "tx"), bytesPerSecond: 40_000_000)
        sender.sendMessage = { [weak client] in client?.send($0) }
        sender.sendPacket = { [weak client] packet, done in client?.send(packet, completion: done) }
        client.onPacket = { sender.handle($0) }
        let saved = expectation(description: "saved")
        sender.onProgress = { if case .saved = $0.state { saved.fulfill() } }
        let data = Data((0..<(3 * 1_024 * 1_024 + 5)).map { _ in UInt8.random(in: 0...255) })
        let source = root.appendingPathComponent("photo.heic"); try data.write(to: source)
        let opened = expectation(description: "open"); client.onReady = { opened.fulfill() }
        client.start(); wait(for: [opened], timeout: 5)
        let started = Date()
        sender.send(fileAt: source)
        wait(for: [saved], timeout: 20)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.07)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("in/photo.heic")), data)
        client.close(); queue.sync { server?.close() }; listener.cancel()
    }
}
