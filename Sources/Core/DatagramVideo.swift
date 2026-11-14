import Foundation

/// Video over UDP (StreamFeature.datagramVideo, build 38): the pure logic, with no sockets, so it can be tested
/// against a simulated lossy link. `DatagramTransport.swift` puts it on encrypted UDP.
///
/// Why: on TCP one lost packet holds back everything sent after it until the retransmission arrives, and the
/// sender then slows down. Here each frame is cut into datagrams; the receiver asks again only for the pieces
/// that are missing (a NACK) while later frames keep arriving, and the sender's pace is set by SkyDesk's own
/// bitrate control instead of by TCP. Frames are still handed to the decoder complete and in order, because each
/// one builds on the one before.
public enum DatagramPacket: Equatable {
    /// Mac → iPad: one piece of an encoded frame.
    case data(frame: UInt64, index: Int, count: Int, payload: Data)
    /// iPad → Mac: pieces still missing. `whole` asks for a frame of which nothing has arrived.
    case nack([Missing])
    /// iPad → Mac, repeated until answered: "this is session …".
    case hello(UUID)
    /// Mac → iPad: the session is accepted; video may arrive here from now on.
    case ready(UUID)

    public struct Missing: Equatable {
        public let frame: UInt64
        /// Inclusive piece indices; nil = the whole frame.
        public let range: ClosedRange<Int>?
        public init(frame: UInt64, range: ClosedRange<Int>?) { self.frame = frame; self.range = range }
    }
    /// Bytes of frame data per datagram: with this header, DTLS and UDP/IP it stays under 1,280 bytes, the
    /// smallest size every IPv6 path and VPN tunnel must carry unfragmented.
    public static let payloadSize = 1_180
    public static let maximumPieces = 16_384
    public static let maximumNacks = 120

    public func encoded() -> Data {
        var data = Data()
        switch self {
        case .data(let frame, let index, let count, let payload):
            data.append(1); data.appendInteger(frame); data.appendInteger(UInt16(index)); data.appendInteger(UInt16(count)); data.append(payload)
        case .nack(let missing):
            data.append(2); data.append(UInt8(min(missing.count, Self.maximumNacks)))
            for item in missing.prefix(Self.maximumNacks) {
                data.appendInteger(item.frame)
                data.appendInteger(UInt16(item.range?.lowerBound ?? 0xFFFF)); data.appendInteger(UInt16(item.range?.upperBound ?? 0xFFFF))
            }
        case .hello(let session): data.append(3); withUnsafeBytes(of: session.uuid) { data.append(contentsOf: $0) }
        case .ready(let session): data.append(4); withUnsafeBytes(of: session.uuid) { data.append(contentsOf: $0) }
        }
        return data
    }
    public init?(_ data: Data) {
        guard let type = data.first else { return nil }
        let body = data.dropFirst()
        func session() -> UUID? {
            guard body.count == 16 else { return nil }
            let b = [UInt8](body)
            return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
        }
        switch type {
        case 1:
            guard body.count > 12 else { return nil }
            let bytes = Data(body)
            let index = Int(bytes.integer(at: 8, as: UInt16.self)), count = Int(bytes.integer(at: 10, as: UInt16.self))
            guard count >= 1, count <= Self.maximumPieces, index < count, bytes.count - 12 <= Self.payloadSize else { return nil }
            self = .data(frame: bytes.integer(at: 0, as: UInt64.self), index: index, count: count, payload: bytes.subdata(in: 12..<bytes.count))
        case 2:
            let bytes = Data(body)
            guard let listed = bytes.first, Int(listed) <= Self.maximumNacks, bytes.count == 1 + Int(listed) * 12 else { return nil }
            var missing: [Missing] = []
            for item in 0..<Int(listed) {
                let offset = 1 + item * 12
                let first = Int(bytes.integer(at: offset + 8, as: UInt16.self)), last = Int(bytes.integer(at: offset + 10, as: UInt16.self))
                let frame = bytes.integer(at: offset, as: UInt64.self)
                if first == 0xFFFF, last == 0xFFFF { missing.append(Missing(frame: frame, range: nil)) }
                else if first <= last, last < Self.maximumPieces { missing.append(Missing(frame: frame, range: first...last)) }
                else { return nil }
            }
            self = .nack(missing)
        case 3: guard let id = session() else { return nil }; self = .hello(id)
        case 4: guard let id = session() else { return nil }; self = .ready(id)
        default: return nil
        }
    }
}

/// Mac side: the frames sent but not yet acknowledged, cut into pieces, with what to send next.
/// Not thread-safe; times are seconds on any monotonic clock.
public struct DatagramSendBuffer {
    public struct Piece: Equatable { public let frame: UInt64; public let index: Int }
    private struct Entry {
        let pieces: [Data]
        let sentAt: Double
        var lastSent: [Double]
        var lastProbe: Double
        var probes = 0
        /// The iPad asked for a piece of it again.
        var repaired = false
    }
    private var frames: [UInt64: Entry] = [:]
    /// Pieces waiting for their turn: retransmissions first, then new frames in order.
    private var urgent: [Piece] = []
    /// Which of the urgent pieces are probes (sent on the Mac's own initiative) rather than answers to the iPad.
    private var probing: [Piece] = []
    private var queued: [Piece] = []
    private var queuedHead = 0
    public private(set) var bytesHeld = 0
    public private(set) var piecesSent = 0
    /// Pieces sent again because the iPad asked: the measure of loss.
    public private(set) var piecesResent = 0
    /// Pieces sent again because nothing had been heard about their frame. Not a sign of loss on its own.
    public private(set) var piecesProbed = 0
    /// How long the iPad usually takes to acknowledge a frame (network both ways plus decoding), learned from the
    /// acknowledgements themselves. Build 39 used fixed times tuned on a 5 ms home network; through a VPN, where
    /// an acknowledgement takes about 55 ms, every frame was probed after 35 ms, the probes were counted as loss,
    /// and the bitrate was cut to its floor for nothing (2026-11-14).
    ///
    /// It is the quickest of the last 32, not their average: a frame that waited for a lost piece, or behind one,
    /// says nothing about how fast the link is, and an average would stretch every timer just when pieces are
    /// being lost.
    public private(set) var acknowledgeTime: Double?
    private var acknowledgeSamples: [Double] = []
    /// A piece is not sent again within this time of its last sending: the first copy may still be on its way.
    public var resendSpacing = 0.008
    /// An unacknowledged frame gets its last piece sent again after this long (and never before an acknowledgement
    /// could reasonably have arrived), in case all of it or its tail was lost and nothing came after it for the
    /// iPad to notice by.
    public var probeAfter = 0.035
    private var probeWait: Double { max(probeAfter, (acknowledgeTime ?? 0) * 1.5 + 0.02) }
    private var resendWait: Double { max(resendSpacing, (acknowledgeTime ?? 0) * 0.4) }
    public static let maximumFrames = 96
    public static let maximumBytes = 48 * 1_024 * 1_024
    public init() {}

    public var isEmpty: Bool { frames.isEmpty }
    public var pending: Bool { !urgent.isEmpty || queuedHead < queued.count }
    public var heldFrames: [UInt64] { frames.keys.sorted() }
    public func oldestAge(now: Double) -> Double? { frames.values.map(\.sentAt).min().map { now - $0 } }

    /// Adds a new frame. Returns false when too much is unacknowledged (the caller falls back to TCP).
    public mutating func add(frame: UInt64, bytes: Data, now: Double) -> Bool {
        guard frames[frame] == nil, !bytes.isEmpty, frames.count < Self.maximumFrames, bytesHeld + bytes.count <= Self.maximumBytes else { return false }
        var pieces: [Data] = []
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            let end = min(bytes.endIndex, offset + DatagramPacket.payloadSize)
            pieces.append(bytes.subdata(in: offset..<end)); offset = end
        }
        guard pieces.count <= DatagramPacket.maximumPieces else { return false }
        frames[frame] = Entry(pieces: pieces, sentAt: now, lastSent: Array(repeating: -1, count: pieces.count), lastProbe: now)
        bytesHeld += bytes.count
        queued.append(contentsOf: pieces.indices.map { Piece(frame: frame, index: $0) })
        return true
    }
    /// The iPad decoded the frame: nothing of it is needed any more.
    public mutating func acknowledge(_ frame: UInt64, now: Double? = nil) {
        guard let entry = frames.removeValue(forKey: frame) else { return }
        bytesHeld -= entry.pieces.reduce(0) { $0 + $1.count }
        // Frames that needed no repair say how long an acknowledgement normally takes. (A probe does not delay a
        // frame, so probed frames count: otherwise a slow link, where every early frame is probed, would never be learned.)
        if let now, !entry.repaired, now >= entry.sentAt, now - entry.sentAt < 2 {
            acknowledgeSamples.append(now - entry.sentAt)
            if acknowledgeSamples.count > 32 { acknowledgeSamples.removeFirst() }
            acknowledgeTime = acknowledgeSamples.min()
        }
    }
    /// The iPad says these pieces are missing: they jump the queue, unless a copy was sent a moment ago.
    public mutating func request(_ missing: [DatagramPacket.Missing], now: Double) {
        for item in missing {
            guard let entry = frames[item.frame] else { continue }      // already acknowledged, or it went over TCP
            let range = item.range ?? 0...(entry.pieces.count - 1)
            for index in range where index < entry.pieces.count {
                // Never sent yet: it is still in the queue and will go out in its turn.
                guard entry.lastSent[index] >= 0, now - entry.lastSent[index] >= resendWait else { continue }
                let piece = Piece(frame: item.frame, index: index)
                if let asked = probing.firstIndex(of: piece) { probing.remove(at: asked) }      // the iPad wants it: count it as loss
                frames[item.frame]?.repaired = true
                if !urgent.contains(piece) { urgent.append(piece) }
            }
        }
    }
    /// Frames unacknowledged for a while with nothing asked about them: queue their last piece again.
    public mutating func probe(now: Double) {
        for (frame, entry) in frames {
            guard let last = entry.lastSent.last, last >= 0 else { continue }       // not fully sent yet
            // Each further probe waits twice as long, up to a quarter second.
            let wait = min(0.5, probeWait * Double(1 << min(entry.probes, 3)))
            guard now - max(entry.lastProbe, last) >= wait else { continue }
            frames[frame]?.lastProbe = now; frames[frame]?.probes += 1
            let piece = Piece(frame: frame, index: entry.pieces.count - 1)
            if !urgent.contains(piece) { urgent.append(piece); probing.append(piece) }
        }
    }
    /// The next datagram to send, if any. `budget` is the number of bytes the pacing allows right now.
    public mutating func next(budget: Int, now: Double) -> DatagramPacket? {
        while true {
            let piece: Piece
            let resend: Bool
            if let first = urgent.first { piece = first; resend = true }
            else if queuedHead < queued.count { piece = queued[queuedHead]; resend = false }
            else { compact(); return nil }
            guard let entry = frames[piece.frame] else {                           // acknowledged meanwhile
                if resend, let probe = probing.firstIndex(of: piece) { probing.remove(at: probe) }
                drop(resend); continue
            }
            let payload = entry.pieces[piece.index]
            guard payload.count <= budget else { return nil }
            drop(resend)
            frames[piece.frame]?.lastSent[piece.index] = now
            if !resend { piecesSent += 1 }
            else if let probe = probing.firstIndex(of: piece) { probing.remove(at: probe); piecesProbed += 1 }
            else { piecesResent += 1 }
            return .data(frame: piece.frame, index: piece.index, count: entry.pieces.count, payload: payload)
        }
    }
    private mutating func drop(_ resend: Bool) { if resend { urgent.removeFirst() } else { queuedHead += 1 } }
    private mutating func compact() { if queuedHead > 0 { queued.removeAll(keepingCapacity: true); queuedHead = 0 } }
    /// Everything not yet acknowledged, whole and in order (to resend over TCP when UDP stops working).
    public func unacknowledged() -> [(frame: UInt64, bytes: Data)] {
        frames.keys.sorted().map { key in (key, frames[key]!.pieces.reduce(into: Data()) { $0.append($1) }) }
    }
    public mutating func removeAll() { frames.removeAll(); urgent.removeAll(); probing.removeAll(); queued.removeAll(); queuedHead = 0; bytesHeld = 0 }
}

/// iPad side: puts frames back together and releases them complete and in order, whichever way they arrived
/// (pieces over UDP, or whole over TCP before UDP took over or after it gave up).
/// Not thread-safe; times are seconds on any monotonic clock.
public struct DatagramReceiveBuffer {
    private struct Partial {
        var pieces: [Data?]
        var have = 0
        var lastProgress: Double
        var lastNack = -1.0
        /// Highest piece index received, and since when a piece below it has been missing.
        var top = -1
        var gapSince: Double?
    }
    private var partial: [UInt64: Partial] = [:]
    private var complete: [UInt64: Data] = [:]
    /// The frame the decoder needs next. It is set by the first frame that arrives over TCP: a session's opening
    /// keyframe always travels that way, and pieces of later frames that overtake it on UDP wait for it.
    public private(set) var next: UInt64?
    /// Highest frame of which a piece arrived over UDP, and when it first did.
    private var highest: UInt64?
    private var highestSeenAt = 0.0
    /// When a frame that nothing has arrived of was first asked for.
    private var unknownNack: [UInt64: Double] = [:]
    /// How long a gap may be plain reordering before it is asked about.
    public var reorderDelay = 0.002
    /// How long a frame may stand with its last pieces outstanding and nothing arriving before they are asked for.
    /// A frame's pieces leave the Mac back to back, so a pause this long means the rest is not coming.
    public var tailDelay = 0.004
    /// Measured time from asking for a piece to getting one for that frame; sets how soon to ask again.
    public private(set) var recovery = 0.010
    /// Not before the answer to the last request could have arrived, or every request would be sent twice.
    public var nackSpacing: Double { min(0.25, max(0.006, recovery * 1.5 + 0.002)) }
    public private(set) var piecesReceived = 0
    public private(set) var duplicates = 0
    public private(set) var nacksSent = 0
    public static let maximumWaiting = 256
    public init(first: UInt64? = nil) { next = first }

    public var waiting: Int { partial.count + complete.count }
    /// Pieces are arriving but the stream has no starting point yet (no frame has come over TCP).
    public var waitingForStart: Bool { next == nil && waiting > 0 }

    /// One piece from UDP. Returns the frames that are now ready for the decoder, in order.
    public mutating func insert(frame: UInt64, index: Int, count: Int, payload: Data, now: Double) -> [(frame: UInt64, bytes: Data)] {
        if let next, frame < next { duplicates += 1; return [] }
        if highest == nil || frame > highest! { highest = frame; highestSeenAt = now }
        guard complete[frame] == nil else { duplicates += 1; return [] }
        var entry = partial[frame] ?? Partial(pieces: Array(repeating: nil, count: count), lastProgress: now)
        guard entry.pieces.count == count, index < count else { return [] }       // inconsistent: ignore
        guard entry.pieces[index] == nil else { duplicates += 1; return [] }
        guard partial[frame] != nil || waiting < Self.maximumWaiting else { return [] }
        entry.pieces[index] = payload; entry.have += 1; entry.lastProgress = now
        if entry.lastNack >= 0, now - entry.lastNack < 1 { recovery = recovery * 0.8 + (now - entry.lastNack) * 0.2 }
        if index > entry.top + 1, entry.gapSince == nil { entry.gapSince = now }
        entry.top = max(entry.top, index)
        if entry.have == entry.top + 1 { entry.gapSince = nil }
        piecesReceived += 1
        unknownNack[frame] = nil
        if entry.have == count {
            partial[frame] = nil
            complete[frame] = entry.pieces.reduce(into: Data()) { $0.append($1!) }
        } else { partial[frame] = entry }
        return release()
    }
    /// A whole frame from TCP.
    public mutating func insert(frame: UInt64, bytes: Data) -> [(frame: UInt64, bytes: Data)] {
        if let next, frame < next { return [] }
        if next == nil { next = frame }
        partial[frame] = nil; unknownNack[frame] = nil
        if complete[frame] == nil, waiting < Self.maximumWaiting { complete[frame] = bytes }
        return release()
    }
    private mutating func release() -> [(frame: UInt64, bytes: Data)] {
        var ready: [(UInt64, Data)] = []
        while let wanted = next, let bytes = complete.removeValue(forKey: wanted) {
            ready.append((wanted, bytes)); next = wanted + 1
        }
        return ready
    }
    /// What to ask the Mac for again, right now.
    public mutating func missing(now: Double) -> [DatagramPacket.Missing] {
        guard let next, let highest, highest >= next else { return [] }
        var list: [DatagramPacket.Missing] = []
        var frame = next
        while frame <= highest, list.count < DatagramPacket.maximumNacks {
            defer { frame += 1 }
            if complete[frame] != nil { continue }
            if var entry = partial[frame] {
                // A hole below a piece that did arrive can only be reordering, and not for long. The pieces after
                // the last one received are either still arriving or lost: lost if the frame has stood still, or
                // if a newer frame has already started.
                let holes = entry.gapSince.map { now - $0 >= reorderDelay } ?? false
                let tail = entry.top + 1 < entry.pieces.count
                    && now - entry.lastProgress >= (frame < highest ? min(reorderDelay, tailDelay) : tailDelay)
                guard holes || tail, now - entry.lastNack >= nackSpacing else { continue }
                entry.lastNack = now; partial[frame] = entry
                var start: Int?
                for index in 0...entry.pieces.count {
                    let absent = index < entry.pieces.count && entry.pieces[index] == nil && (index < entry.top ? holes : tail)
                    if absent, start == nil { start = index }
                    if !absent, let from = start {
                        list.append(.init(frame: frame, range: from...(index - 1))); start = nil
                        if list.count >= DatagramPacket.maximumNacks { break }
                    }
                }
            } else if frame < highest {
                // Nothing of it has arrived although a later frame has: all of it was lost, or it is on its way over
                // TCP (the Mac ignores the question then).
                let asked = unknownNack[frame]
                guard now - highestSeenAt >= reorderDelay, asked == nil || now - asked! >= nackSpacing else { continue }
                unknownNack[frame] = now
                list.append(.init(frame: frame, range: nil))
            }
        }
        nacksSent += list.count
        return list
    }
}

/// How many bytes may leave per second, with a small allowance so ordinary frames go out at once and only large
/// ones (a keyframe is over a megabyte) are spread out instead of overflowing the Wi-Fi queue.
public struct DatagramPacer {
    public private(set) var allowance: Double
    public let burst: Double
    private var last: Double?
    public init(burst: Int = 96_000) { self.burst = Double(burst); allowance = Double(burst) }
    /// `rate` in bits per second. Returns the bytes that may be sent now.
    public mutating func refill(rate: Int, now: Double) -> Int {
        if let last, now > last { allowance = min(burst, allowance + (now - last) * Double(rate) / 8) }
        last = now
        return Int(allowance)
    }
    public mutating func spend(_ bytes: Int) { allowance -= Double(bytes) }
    /// Seconds until `bytes` may be sent at `rate`.
    public func wait(for bytes: Int, rate: Int) -> Double { max(0, (Double(bytes) - allowance) * 8 / Double(max(rate, 1))) }
    /// The pace for a given video bitrate: six times it, and never under 30 Mbps, so sending is never the limit
    /// on a healthy link while a megabyte keyframe still takes tens of milliseconds, not one burst.
    public static func rate(forBitrate bitrate: Int) -> Int { max(30_000_000, bitrate * 6) }
}

/// Which path a frame takes, decided on the Mac for every frame.
///
/// The iPad starts the stream at the first frame TCP brings it, so the first frame of a session must go over TCP
/// whatever its size. Build 38 chose by size alone: a quiet desktop's opening keyframe was about 200 kB, went over
/// UDP, and the iPad waited 1.5 s for a TCP frame that never came before the fallback rescued it (2026-11-13).
/// Large frames always go over TCP: a keyframe is a megabyte or two, and as datagrams it would have to be spread
/// over a tenth of a second (measured: 2 MB took 110 ms and held up the frames behind it).
public struct VideoPathPolicy: Equatable {
    public static let largestDatagramFrame = 256_000
    public private(set) var startedOnTCP = false
    public init() {}
    /// True = send this frame as datagrams. `available`: the iPad's UDP flow is up.
    public mutating func useDatagrams(available: Bool, bytes: Int) -> Bool {
        if available, startedOnTCP, bytes <= Self.largestDatagramFrame { return true }
        startedOnTCP = true
        return false
    }
}
