import Foundation
import Network

extension DeskNetwork {
    /// UDP port for video datagrams: the same number as the TCP port (the two never collide).
    public static let datagramPort: UInt16 = port
    /// Encrypted UDP (DTLS 1.2) with the same credentials and the same forward-secret key exchange as the TCP
    /// channels: the pairing key proves who is connecting, exactly as before.
    public static func datagramParameters(credentials: [PairingCredential]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .DTLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .DTLSv12)
        for suite in [forwardSecretSuite, legacySuite] {
            if let value = tls_ciphersuite_t(rawValue: suite) { sec_protocol_options_append_tls_ciphersuite(options, value) }
        }
        for credential in credentials {
            let secret = credential.key.data.withUnsafeBytes { DispatchData(bytes: $0) }
            let identity = Data(credential.identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(options, secret as __DispatchData, identity as __DispatchData)
        }
        let parameters = NWParameters(dtls: tls, udp: NWProtocolUDP.Options())
        parameters.includePeerToPeer = false
        return parameters
    }
}

private func seconds() -> Double { Double(monotonicNanos()) / 1_000_000_000 }

/// Mac side of video over UDP. Thread-safe: everything runs on `queue`.
public final class VideoDatagramSender {
    public struct Counters: Equatable { public var sent = 0, resent = 0 }
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = DatagramSendBuffer()
    private var pacer = DatagramPacer()
    private var timer: DispatchSourceTimer?
    private var wake: DispatchWorkItem?
    private var sending = 0
    private var accepted: UUID?
    private var finished = false
    private var reported = Counters()
    /// The video bitrate currently aimed for, in bits per second: sets the pace.
    public var bitrate: () -> Int = { 25_000_000 }
    /// Is this the session we are serving? Called on `queue` for each hello.
    public var onHello: ((UUID) -> Bool)?
    /// The iPad is reachable over UDP for this session: frames may be handed to `send` from now on.
    public var onActive: (() -> Void)?
    /// UDP stopped working (or was closed). `unsent` are the frames not yet acknowledged, in order: the caller
    /// resends them over TCP so the stream continues without a gap.
    public var onStopped: ((_ reason: String?, _ unsent: [(frame: UInt64, bytes: Data)]) -> Void)?
    /// No acknowledgement for this long while frames are outstanding means UDP is not getting through.
    public var stallLimit = 1.0

    public init(connection: NWConnection, queue: DispatchQueue) { self.connection = connection; self.queue = queue }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.finished else { return }
            switch state {
            case .ready: self.receive()
            case .failed(let error): self.stop(error.localizedDescription)
            case .cancelled: self.stop(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        // A flow that never completes its handshake or never says hello is dropped.
        queue.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.accepted == nil else { return }
            self.stop("No session on this UDP flow.")
        }
    }
    /// Hands over one encoded frame. Returns at once; false means UDP has already stopped (send it over TCP).
    public func send(frame: UInt64, bytes: Data) {
        queue.async { [self] in
            guard !finished, accepted != nil else { onStopped?(nil, [(frame, bytes)]); return }
            guard buffer.add(frame: frame, bytes: bytes, now: seconds()) else {
                stop("Too much video is waiting to be acknowledged.", extra: [(frame, bytes)]); return
            }
            pump()
        }
    }
    public func acknowledge(_ frame: UInt64) { queue.async { [self] in buffer.acknowledge(frame) } }
    /// Pieces sent and resent since the last call (for the log and the bitrate control).
    public func drainCounters(_ handler: @escaping (Counters) -> Void) {
        queue.async { [self] in
            let total = Counters(sent: buffer.piecesSent, resent: buffer.piecesResent)
            handler(Counters(sent: total.sent - reported.sent, resent: total.resent - reported.resent))
            reported = total
        }
    }
    public func close() { queue.async { [self] in stop(nil) } }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.finished else { return }
            if let data, let packet = DatagramPacket(data) {
                switch packet {
                case .hello(let session):
                    if self.accepted == nil, self.onHello?(session) == true { self.accepted = session; self.begin() }
                    if self.accepted == session { self.transmit(.ready(session)) }
                case .nack(let missing):
                    if self.accepted != nil { self.buffer.request(missing, now: seconds()); self.pump() }
                default: break
                }
            }
            if let error { self.stop(error.localizedDescription) } else { self.receive() }
        }
    }
    private func begin() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            let now = seconds()
            if let age = self.buffer.oldestAge(now: now), age > self.stallLimit { self.stop("Video over UDP stopped being acknowledged."); return }
            self.buffer.probe(now: now)
            self.pump()
        }
        self.timer = timer; timer.resume()
        onActive?()
    }
    private func pump() {
        guard !finished else { return }
        let rate = DatagramPacer.rate(forBitrate: bitrate())
        let now = seconds()
        var budget = pacer.refill(rate: rate, now: now)
        // A bounded number of datagrams handed to the system at a time, so a slow link pushes back here.
        while sending < 128, let packet = buffer.next(budget: budget, now: now) {
            let bytes = packet.encoded()
            pacer.spend(bytes.count); budget -= bytes.count
            transmit(bytes)
        }
        guard buffer.pending, wake == nil, sending < 128 else { return }
        let work = DispatchWorkItem { [weak self] in self?.wake = nil; self?.pump() }
        wake = work
        queue.asyncAfter(deadline: .now() + max(0.0005, pacer.wait(for: DatagramPacket.payloadSize + 13, rate: rate)), execute: work)
    }
    private func transmit(_ packet: DatagramPacket) { transmit(packet.encoded()) }
    private func transmit(_ bytes: Data) {
        sending += 1
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.sending -= 1
            if let error { self.stop(error.localizedDescription) } else if self.sending == 127 || self.buffer.pending { self.pump() }
        })
    }
    private func stop(_ reason: String?, extra: [(frame: UInt64, bytes: Data)] = []) {
        guard !finished else { return }
        finished = true
        timer?.cancel(); timer = nil; wake?.cancel(); wake = nil
        let unsent = buffer.unacknowledged() + extra
        buffer.removeAll()
        connection.stateUpdateHandler = nil
        connection.cancel()
        onStopped?(reason, unsent)
    }
}

/// iPad side: orders the video stream whichever way its frames arrive. Frames from TCP go through
/// `insertReliable`; once `attach` has opened the UDP flow, pieces arrive there and missing ones are asked for.
/// Everything runs on `queue` (the video queue), including the callbacks.
public final class VideoDatagramReceiver {
    private let queue: DispatchQueue
    private var buffer = DatagramReceiveBuffer()
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var session: UUID?
    private var hellos = 0
    private var ready = false
    private var orphanedSince: Double?
    /// Complete frames, in order (the bytes of an encoded VideoFrame).
    public var onFrame: ((UInt64, Data) -> Void)?
    /// The Mac accepted the UDP flow; `onStopped` if it never does or the flow fails later.
    public var onReady: (() -> Void)?
    public var onStopped: ((String?) -> Void)?

    public init(queue: DispatchQueue) { self.queue = queue }

    /// Call on `queue`.
    public func insertReliable(frame: UInt64, bytes: Data) { deliver(buffer.insert(frame: frame, bytes: bytes)) }
    public var statistics: (pieces: Int, duplicates: Int, asked: Int, waiting: Int) {
        (buffer.piecesReceived, buffer.duplicates, buffer.nacksSent, buffer.waiting)
    }
    /// Opens the UDP flow. Call on `queue`.
    public func attach(_ connection: NWConnection, session: UUID) {
        detach()
        self.connection = connection; self.session = session; hellos = 0; ready = false
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.connection === connection else { return }
            switch state {
            case .ready: self.receive(connection); self.greet(connection)
            case .failed(let error): self.stop(error.localizedDescription)
            case .waiting(let error): if case .tls = error { self.stop(error.localizedDescription) }
            default: break
            }
        }
        connection.start(queue: queue)
        // No handshake at all within a few seconds: UDP is blocked on this network.
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
            guard let self, let connection, self.connection === connection, !self.ready else { return }
            self.stop("The Mac did not answer over UDP.")
        }
    }
    /// Closes the UDP flow; frames keep being ordered for TCP. Call on `queue`.
    public func detach() {
        timer?.cancel(); timer = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        ready = false
    }
    private func stop(_ reason: String?) {
        guard connection != nil else { return }
        detach()
        onStopped?(reason)
    }
    private func greet(_ connection: NWConnection) {
        guard self.connection === connection, !ready, let session else { return }
        hellos += 1
        connection.send(content: DatagramPacket.hello(session).encoded(), completion: .contentProcessed { _ in })
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.greet(connection)
        }
    }
    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection, self.connection === connection else { return }
            if let data, let packet = DatagramPacket(data) {
                switch packet {
                case .data(let frame, let index, let count, let payload):
                    self.deliver(self.buffer.insert(frame: frame, index: index, count: count, payload: payload, now: seconds()))
                case .ready(let session) where session == self.session:
                    if !self.ready { self.ready = true; self.startAsking(connection); self.onReady?() }
                default: break
                }
            }
            if let error { self.stop(error.localizedDescription) } else { self.receive(connection) }
        }
    }
    /// Every 2 ms: is anything overdue? Costs nothing while every frame is complete.
    private func startAsking(_ connection: NWConnection) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(2), repeating: .milliseconds(2), leeway: .microseconds(500))
        timer.setEventHandler { [weak self, weak connection] in
            guard let self, let connection, self.connection === connection, self.buffer.waiting > 0 else { self?.orphanedSince = nil; return }
            // Video is arriving here but the stream never started on TCP: nothing can be shown. Say so quickly, so
            // the Mac sends everything over TCP, instead of waiting for it to notice the silence.
            if self.buffer.waitingForStart {
                let now = seconds()
                if let since = self.orphanedSince, now - since > 0.4 { self.stop("Video arrived over UDP before the stream had started."); return }
                if self.orphanedSince == nil { self.orphanedSince = now }
                return
            }
            self.orphanedSince = nil
            let missing = self.buffer.missing(now: seconds())
            if !missing.isEmpty { connection.send(content: DatagramPacket.nack(missing).encoded(), completion: .contentProcessed { _ in }) }
        }
        self.timer = timer; timer.resume()
    }
    private func deliver(_ frames: [(frame: UInt64, bytes: Data)]) { for item in frames { onFrame?(item.frame, item.bytes) } }
}
