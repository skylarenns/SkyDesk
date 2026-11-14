import Foundation

/// Control messages of a file transfer. They travel on the session's file channel only, never on the control channel.
public struct FileEvent: Codable, Equatable {
    public enum Kind: String, Codable {
        /// Sender → receiver: a file is coming (`name`, `size`).
        case offer
        /// Receiver → sender: `bytes` received and written so far (flow control).
        case ack
        /// Sender → receiver: every byte has been sent.
        case complete
        /// Receiver → sender: saved as `name`.
        case saved
        /// Either side: the transfer stopped (`reason`).
        case failed
    }
    public let kind: Kind
    public let id: UUID
    public var name: String?
    public var size: UInt64?
    public var bytes: UInt64?
    public var reason: String?
    public init(kind: Kind, id: UUID, name: String? = nil, size: UInt64? = nil, bytes: UInt64? = nil, reason: String? = nil) {
        self.kind = kind; self.id = id; self.name = name; self.size = size; self.bytes = bytes; self.reason = reason
    }
}

/// One piece of a file: 16-byte transfer id, 8-byte offset, then the bytes. Sent as a `.file` wire packet.
public struct FileChunk: Equatable {
    public let id: UUID
    public let offset: UInt64
    public let data: Data
    public init(id: UUID, offset: UInt64, data: Data) { self.id = id; self.offset = offset; self.data = data }
    public func packet() -> WirePacket {
        var payload = Data()
        withUnsafeBytes(of: id.uuid) { payload.append(contentsOf: $0) }
        payload.appendInteger(offset)
        payload.append(data)
        return WirePacket(kind: .file, payload: payload)
    }
    public init(packet: WirePacket) throws {
        guard packet.kind == .file, packet.payload.count > 24 else { throw DeskError.invalid("Invalid file chunk.") }
        let bytes = [UInt8](packet.payload.prefix(16))
        id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                         bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        offset = packet.payload.integer(at: 16, as: UInt64.self)
        data = packet.payload.subdata(in: packet.payload.startIndex + 24..<packet.payload.endIndex)
    }
}

public enum FileNames {
    /// A received name reduced to one safe path component: no folders, no "..", no hidden files, no control
    /// characters, at most 180 UTF-8 bytes. A transfer can therefore only ever create a file directly in its folder.
    public static func sanitized(_ name: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var clean = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != ":" }.map(Character.init))
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.hasPrefix(".") { clean.removeFirst() }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { clean = "File" }
        if clean.utf8.count > 180 {
            let ext = (clean as NSString).pathExtension
            var stem = (clean as NSString).deletingPathExtension
            let room = 180 - (ext.isEmpty ? 0 : ext.utf8.count + 1)
            while stem.utf8.count > max(1, room) { stem.removeLast() }
            clean = ext.isEmpty || ext.utf8.count > 20 ? String(clean.prefix(120)) : stem + "." + ext
        }
        return clean
    }
    /// `folder/name`, or `folder/name 2.ext`, `name 3.ext`… when taken. Always directly inside `folder`.
    public static func uniqueURL(for name: String, in folder: URL, fileManager: FileManager = .default) throws -> URL {
        let safe = sanitized(name)
        let ext = (safe as NSString).pathExtension
        let stem = (safe as NSString).deletingPathExtension
        for index in 1...10_000 {
            let candidate = index == 1 ? safe : (ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)")
            let url = folder.appendingPathComponent(candidate, isDirectory: false)
            guard url.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path else {
                throw DeskError.invalid("Unsafe file name.")
            }
            if !fileManager.fileExists(atPath: url.path) { return url }
        }
        throw DeskError.invalid("Too many files with this name.")
    }
}

/// Writes incoming files into one folder. Not thread-safe: use from one serial queue.
public final class FileReceiver {
    public static let maxFileSize: UInt64 = 4 * 1_024 * 1_024 * 1_024
    public static let maxConcurrent = 8
    public let directory: URL
    private struct Incoming { let name: String; let size: UInt64; var received: UInt64; let handle: FileHandle; let part: URL }
    private var incoming: [UUID: Incoming] = [:]
    public init(directory: URL) { self.directory = directory }

    public func offer(id: UUID, name: String, size: UInt64) throws {
        guard incoming[id] == nil else { throw DeskError.invalid("Duplicate file transfer.") }
        guard incoming.count < Self.maxConcurrent else { throw DeskError.invalid("Too many files at once.") }
        guard size <= Self.maxFileSize else { throw DeskError.invalid("Files larger than 4 GB can't be sent.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let part = directory.appendingPathComponent(".\(id.uuidString).skydesk-part")
        guard FileManager.default.createFile(atPath: part.path, contents: nil) else { throw DeskError.invalid("Can't create the file.") }
        incoming[id] = Incoming(name: FileNames.sanitized(name), size: size, received: 0,
                                handle: try FileHandle(forWritingTo: part), part: part)
    }
    /// Chunks must arrive in order (the channel is TCP). Returns the bytes received so far.
    @discardableResult
    public func write(_ chunk: FileChunk) throws -> UInt64 {
        guard var file = incoming[chunk.id] else { throw DeskError.invalid("Unknown file transfer.") }
        guard chunk.offset == file.received, file.received + UInt64(chunk.data.count) <= file.size else {
            cancel(id: chunk.id); throw DeskError.invalid("File data arrived out of order.")
        }
        do { try file.handle.write(contentsOf: chunk.data) } catch { cancel(id: chunk.id); throw error }
        file.received += UInt64(chunk.data.count)
        incoming[chunk.id] = file
        return file.received
    }
    /// Checks the size and moves the finished file into place. Returns where it was saved.
    public func complete(id: UUID) throws -> URL {
        guard let file = incoming.removeValue(forKey: id) else { throw DeskError.invalid("Unknown file transfer.") }
        try? file.handle.close()
        guard file.received == file.size else {
            try? FileManager.default.removeItem(at: file.part)
            throw DeskError.invalid("The file arrived incomplete.")
        }
        let target = try FileNames.uniqueURL(for: file.name, in: directory)
        try FileManager.default.moveItem(at: file.part, to: target)
        return target
    }
    public func cancel(id: UUID) {
        guard let file = incoming.removeValue(forKey: id) else { return }
        try? file.handle.close(); try? FileManager.default.removeItem(at: file.part)
    }
    public func cancelAll() { for id in Array(incoming.keys) { cancel(id: id) } }
    public var activeCount: Int { incoming.count }
}

/// Reads one outgoing file in chunks, never more than `window` bytes ahead of the receiver's acknowledgements.
public final class FileSender {
    public static let chunkSize = 256 * 1_024
    public static let window: UInt64 = 2 * 1_024 * 1_024
    public let id: UUID
    public let name: String
    public let size: UInt64
    private let handle: FileHandle
    public private(set) var sent: UInt64 = 0
    public private(set) var acked: UInt64 = 0
    public init(url: URL, name: String? = nil, id: UUID = UUID()) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw DeskError.invalid("Only files can be sent, not folders.") }
        let size = UInt64(values.fileSize ?? 0)
        guard size <= FileReceiver.maxFileSize else { throw DeskError.invalid("Files larger than 4 GB can't be sent.") }
        self.id = id; self.name = FileNames.sanitized(name ?? url.lastPathComponent); self.size = size
        handle = try FileHandle(forReadingFrom: url)
    }
    public var canSend: Bool { sent < size && sent - acked < Self.window }
    public var allSent: Bool { sent == size }
    public func nextChunk() throws -> FileChunk? {
        guard canSend else { return nil }
        let length = Int(min(UInt64(Self.chunkSize), size - sent))
        guard let data = try handle.read(upToCount: length), data.count == length else {
            throw DeskError.invalid("The file changed while it was being sent.")
        }
        let chunk = FileChunk(id: id, offset: sent, data: data)
        sent += UInt64(length)
        return chunk
    }
    public func acknowledge(_ bytes: UInt64) { if bytes > acked && bytes <= sent { acked = bytes } }
    deinit { try? handle.close() }
}

/// Both directions of file transfer for one session, on one serial queue. Transport and UI are plugged in as closures.
public final class FileTransferEngine {
    public struct Progress: Identifiable, Equatable {
        public enum State: Equatable { case active, saved(String), failed(String) }
        public let id: UUID
        public let name: String
        public let size: UInt64
        public var done: UInt64
        public let outgoing: Bool
        public var state: State
        public var fraction: Double { size == 0 ? 1 : Double(done) / Double(size) }
    }
    /// Called on the engine queue whenever a transfer advances (throttled) or finishes.
    public var onProgress: ((Progress) -> Void)?
    public var sendMessage: ((ControlMessage) -> Void)?
    /// The completion reports whether the transport accepted the packet.
    public var sendPacket: ((WirePacket, @escaping (Bool) -> Void) -> Void)?
    public let queue: DispatchQueue
    private let receiver: FileReceiver
    private let bytesPerSecond: Double
    private var pending: [(url: URL, name: String?)] = []
    private var current: FileSender?
    private var currentProgress: Progress?
    private var pumping = false
    private var incoming: [UUID: Progress] = [:]
    private var lastReport: [UUID: UInt64] = [:]
    private var closed = false

    /// `bytesPerSecond` paces sending so a big file can't fill the Wi-Fi queue in front of the video stream.
    public init(directory: URL, queue: DispatchQueue, bytesPerSecond: Double = 12_500_000) {
        receiver = FileReceiver(directory: directory); self.queue = queue; self.bytesPerSecond = bytesPerSecond
    }
    public func send(fileAt url: URL, name: String? = nil) {
        queue.async { [self] in
            guard !closed else { return }
            pending.append((url, name)); startNext()
        }
    }
    public func handle(_ packet: WirePacket) {
        queue.async { [self] in
            guard !closed else { return }
            if packet.kind == .file {
                do {
                    let chunk = try FileChunk(packet: packet)
                    let received = try receiver.write(chunk)
                    sendMessage?(.file(FileEvent(kind: .ack, id: chunk.id, bytes: received)))
                    updateIncoming(chunk.id, done: received)
                } catch let error {
                    if let chunk = try? FileChunk(packet: packet) { failIncoming(chunk.id, error.localizedDescription) }
                }
                return
            }
            guard case .file(let event)? = try? packet.controlMessage() else { return }
            handle(event)
        }
    }
    /// Ends every transfer (link closed or session over); partial files are deleted.
    public func close(reason: String) {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            receiver.cancelAll()
            for (_, var progress) in incoming { progress.state = .failed(reason); onProgress?(progress) }
            incoming.removeAll()
            if var progress = currentProgress { progress.state = .failed(reason); onProgress?(progress) }
            for item in pending {
                onProgress?(Progress(id: UUID(), name: FileNames.sanitized(item.name ?? item.url.lastPathComponent), size: 0, done: 0,
                                     outgoing: true, state: .failed(reason)))
            }
            pending.removeAll(); current = nil; currentProgress = nil
        }
    }

    private func handle(_ event: FileEvent) {
        switch event.kind {
        case .offer:
            let name = FileNames.sanitized(event.name ?? "File")
            do {
                try receiver.offer(id: event.id, name: name, size: event.size ?? 0)
                let progress = Progress(id: event.id, name: name, size: event.size ?? 0, done: 0, outgoing: false, state: .active)
                incoming[event.id] = progress; onProgress?(progress)
            } catch {
                sendMessage?(.file(FileEvent(kind: .failed, id: event.id, reason: error.localizedDescription)))
            }
        case .complete:
            guard var progress = incoming.removeValue(forKey: event.id) else { return }
            do {
                let url = try receiver.complete(id: event.id)
                progress.done = progress.size; progress.state = .saved(url.lastPathComponent)
                sendMessage?(.file(FileEvent(kind: .saved, id: event.id, name: url.lastPathComponent)))
            } catch {
                progress.state = .failed(error.localizedDescription)
                sendMessage?(.file(FileEvent(kind: .failed, id: event.id, reason: error.localizedDescription)))
            }
            onProgress?(progress)
        case .ack:
            guard let sender = current, sender.id == event.id, let bytes = event.bytes else { return }
            sender.acknowledge(bytes)
            report(outgoingDone: bytes)
            pump()
        case .saved:
            guard current?.id == event.id, var progress = currentProgress else { return }
            progress.done = progress.size; progress.state = .saved(event.name ?? progress.name)
            onProgress?(progress)
            current = nil; currentProgress = nil; startNext()
        case .failed:
            if current?.id == event.id, var progress = currentProgress {
                progress.state = .failed(event.reason ?? "The other side stopped the transfer.")
                onProgress?(progress); current = nil; currentProgress = nil; startNext()
            } else {
                receiver.cancel(id: event.id)
                if var progress = incoming.removeValue(forKey: event.id) {
                    progress.state = .failed(event.reason ?? "Stopped."); onProgress?(progress)
                }
            }
        }
    }
    private func startNext() {
        guard current == nil, !pending.isEmpty else { return }
        let item = pending.removeFirst()
        do {
            let sender = try FileSender(url: item.url, name: item.name)
            current = sender
            let progress = Progress(id: sender.id, name: sender.name, size: sender.size, done: 0, outgoing: true, state: .active)
            currentProgress = progress; onProgress?(progress)
            sendMessage?(.file(FileEvent(kind: .offer, id: sender.id, name: sender.name, size: sender.size)))
            pump()
        } catch {
            onProgress?(Progress(id: UUID(), name: FileNames.sanitized(item.name ?? item.url.lastPathComponent), size: 0, done: 0,
                                 outgoing: true, state: .failed(error.localizedDescription)))
            startNext()
        }
    }
    /// Sends one chunk, then waits long enough to hold the paced rate before the next one.
    private func pump() {
        guard !pumping, !closed, let sender = current else { return }
        if sender.allSent {
            if sender.sent == sender.acked, currentProgress?.state == .active, !completeSent.contains(sender.id) {
                completeSent.insert(sender.id)
                sendMessage?(.file(FileEvent(kind: .complete, id: sender.id)))
            }
            return
        }
        do {
            guard let chunk = try sender.nextChunk() else { return }
            pumping = true
            let delay = Double(chunk.data.count) / bytesPerSecond
            let started = DispatchTime.now()
            sendPacket?(chunk.packet()) { [weak self] ok in
                guard let self else { return }
                self.queue.asyncAfter(deadline: started + delay) {
                    self.pumping = false
                    guard !self.closed, self.current?.id == chunk.id else { return }
                    if ok { self.pump() } else { self.failCurrent("The connection dropped while sending.") }
                }
            }
        } catch { failCurrent(error.localizedDescription) }
    }
    private var completeSent: Set<UUID> = []
    private func failCurrent(_ reason: String) {
        guard let sender = current, var progress = currentProgress else { return }
        sendMessage?(.file(FileEvent(kind: .failed, id: sender.id, reason: reason)))
        progress.state = .failed(reason); onProgress?(progress)
        current = nil; currentProgress = nil; startNext()
    }
    private func failIncoming(_ id: UUID, _ reason: String) {
        receiver.cancel(id: id)
        sendMessage?(.file(FileEvent(kind: .failed, id: id, reason: reason)))
        if var progress = incoming.removeValue(forKey: id) { progress.state = .failed(reason); onProgress?(progress) }
    }
    private func updateIncoming(_ id: UUID, done: UInt64) {
        guard var progress = incoming[id] else { return }
        progress.done = done; incoming[id] = progress
        // About every 1 MiB, so the UI isn't flooded.
        if done - (lastReport[id] ?? 0) >= 1_048_576 || done == progress.size { lastReport[id] = done; onProgress?(progress) }
    }
    private func report(outgoingDone bytes: UInt64) {
        guard var progress = currentProgress else { return }
        progress.done = bytes; currentProgress = progress
        if bytes - (lastReport[progress.id] ?? 0) >= 1_048_576 || bytes == progress.size { lastReport[progress.id] = bytes; onProgress?(progress) }
    }
}
