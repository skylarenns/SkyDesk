import XCTest
import Network
@testable import SkyDeskCore

/// Forwards UDP between the iPad side and the Mac side of a test, losing a share of the datagrams on the way.
/// It never sees inside them: they are DTLS records.
private final class LossyRelay {
    private let queue = DispatchQueue(label: "skydesk.test.relay")
    private var listener: NWListener?
    private var flows: [NWConnection] = []
    private var forwarded = 0
    private var state: UInt64 = 7
    /// Share of datagrams dropped once `clearFirst` have passed (the handshake is left alone).
    var loss = 0.0
    var clearFirst = 14
    /// From this moment on nothing gets through (a network that blocks UDP after the fact).
    var blackout = false
    private(set) var dropped = 0

    func start(towards port: NWEndpoint.Port) throws -> NWEndpoint.Port {
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [weak self] inbound in
            guard let self else { return }
            let outbound = NWConnection(host: "127.0.0.1", port: port, using: .udp)
            self.flows += [inbound, outbound]
            inbound.start(queue: self.queue); outbound.start(queue: self.queue)
            self.pipe(from: inbound, to: outbound); self.pipe(from: outbound, to: inbound)
        }
        listener.start(queue: queue)
        self.listener = listener
        _ = ready.wait(timeout: .now() + 3)
        return try XCTUnwrap(listener.port)
    }
    private func pipe(from: NWConnection, to: NWConnection) {
        from.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data {
                self.forwarded += 1
                self.state = self.state &* 6364136223846793005 &+ 1442695040888963407
                let unlucky = Double((self.state >> 33) % 1_000_000) / 1_000_000 < self.loss
                if self.blackout || (self.forwarded > self.clearFirst && unlucky) { self.dropped += 1 }
                else { to.send(content: data, completion: .contentProcessed { _ in }) }
            }
            if error == nil { self.pipe(from: from, to: to) }
        }
    }
    func stop() { queue.sync { flows.forEach { $0.cancel() }; listener?.cancel() } }
}

final class DatagramTransportTests: XCTestCase {
    private func frameBytes(_ frame: UInt64) -> Data {
        // 3 to 43 kB, recognisable content.
        Data((0..<(3_000 + Int(frame % 41) * 1_000)).map { UInt8(truncatingIfNeeded: Int(frame) &+ $0) })
    }

    /// Streams `count` frames from a sender to a receiver through the relay and returns what the receiver released.
    private func stream(count: UInt64, loss: Double, blackoutAfter: UInt64? = nil) throws -> (frames: [UInt64], resent: Int, dropped: Int, viaFallback: Int) {
        let credential = PairingCredential.device(UUID(), key: try PairingKey())
        let session = UUID()
        let macQueue = DispatchQueue(label: "skydesk.test.mac"), padQueue = DispatchQueue(label: "skydesk.test.pad")
        let parameters = DeskNetwork.datagramParameters(credentials: [.password(try PairingKey()), credential])
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let listening = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        let active = expectation(description: "UDP accepted")
        let finished = expectation(description: "all frames released")
        var sender: VideoDatagramSender?
        var released: [UInt64] = []
        var intact = true
        var fallback = 0
        let receiver = VideoDatagramReceiver(queue: padQueue)
        let relay = LossyRelay(); relay.loss = loss
        listener.newConnectionHandler = { connection in
            let made = VideoDatagramSender(connection: connection, queue: macQueue)
            made.stallLimit = 0.5
            made.onHello = { $0 == session }
            made.onActive = { active.fulfill() }
            // UDP gave up: what was not acknowledged goes over "TCP" (straight into the receiver here).
            made.onStopped = { _, unsent in
                padQueue.async { for item in unsent { fallback += 1; receiver.insertReliable(frame: item.frame, bytes: item.bytes) } }
            }
            sender = made
            made.start()
        }
        listener.start(queue: macQueue)
        wait(for: [listening], timeout: 5)
        let relayPort = try relay.start(towards: try XCTUnwrap(listener.port))
        receiver.onFrame = { [weak self] frame, bytes in
            guard let self else { return }
            released.append(frame)
            if bytes != self.frameBytes(frame) { intact = false }
            macQueue.async { sender?.acknowledge(frame) }          // the acknowledgement travels on the TCP control channel
            if frame == count { finished.fulfill() }
        }
        padQueue.async {
            // The stream opens on TCP, as in a real session.
            receiver.insertReliable(frame: 1, bytes: self.frameBytes(1))
            receiver.attach(NWConnection(host: "127.0.0.1", port: relayPort, using: DeskNetwork.datagramParameters(credentials: [credential])), session: session)
        }
        wait(for: [active], timeout: 8)
        // 120 frames a second, like the real stream.
        let feeder = DispatchSource.makeTimerSource(queue: macQueue)
        var next: UInt64 = 2
        feeder.schedule(deadline: .now(), repeating: .microseconds(8_333))
        feeder.setEventHandler { [weak self] in
            guard let self, next <= count else { feeder.cancel(); return }
            if let limit = blackoutAfter, next == limit { relay.blackout = true }
            sender?.send(frame: next, bytes: self.frameBytes(next)); next += 1
        }
        feeder.resume()
        wait(for: [finished], timeout: 30)
        var resent = 0
        let counted = expectation(description: "counters")
        if let sender { sender.drainCounters { resent = $0.resent; counted.fulfill() } } else { counted.fulfill() }
        wait(for: [counted], timeout: 3)
        padQueue.sync { receiver.detach() }
        sender?.close(); listener.cancel(); relay.stop()
        XCTAssertTrue(intact, "a frame arrived with the wrong bytes")
        return (padQueue.sync { released }, resent, relay.dropped, padQueue.sync { fallback })
    }

    func testEncryptedUDPCarriesTheStreamInOrder() throws {
        let result = try stream(count: 240, loss: 0)
        XCTAssertEqual(result.frames, Array(1...240))
        XCTAssertEqual(result.viaFallback, 0)
    }

    func testLostDatagramsAreAskedForAgainUntilEveryFrameIsWhole() throws {
        let result = try stream(count: 360, loss: 0.05)
        XCTAssertEqual(result.frames, Array(1...360))
        XCTAssertGreaterThan(result.dropped, 100, "the relay should really have dropped datagrams")
        XCTAssertGreaterThan(result.resent, 50)
        XCTAssertEqual(result.viaFallback, 0, "5 % loss must be repaired on UDP itself")
    }

    func testWhenUDPStopsGettingThroughTheStreamContinuesOverTCPWithoutAGap() throws {
        let result = try stream(count: 200, loss: 0, blackoutAfter: 80)
        XCTAssertEqual(result.frames, Array(1...200))
        XCTAssertGreaterThan(result.viaFallback, 100)
    }

    func testTheWrongKeyNeverGetsAUDPFlow() throws {
        let parameters = DeskNetwork.datagramParameters(credentials: [.password(try PairingKey())])
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "skydesk.test.wrong")
        let listening = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        var held: [VideoDatagramSender] = []
        listener.newConnectionHandler = { connection in
            let sender = VideoDatagramSender(connection: connection, queue: queue)
            sender.onHello = { _ in XCTFail("a flow with the wrong key reached the session check"); return true }
            held.append(sender); sender.start()
        }
        listener.start(queue: queue)
        wait(for: [listening], timeout: 5)
        let receiver = VideoDatagramReceiver(queue: queue)
        let refused = expectation(description: "refused")
        receiver.onReady = { XCTFail("accepted with the wrong key") }
        receiver.onStopped = { _ in refused.fulfill() }
        let port = try XCTUnwrap(listener.port)
        queue.async {
            receiver.attach(NWConnection(host: "127.0.0.1", port: port, using: DeskNetwork.datagramParameters(credentials: [.password(try! PairingKey())])), session: UUID())
        }
        wait(for: [refused], timeout: 9)
        queue.sync { held.forEach { $0.close() } }; listener.cancel()
    }
}
