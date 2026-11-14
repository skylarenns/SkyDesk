import XCTest
import Network
import CoreVideo
import CoreMedia
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

    #if os(macOS)
    /// The real thing on one Mac: hardware-encoded video at the iPad's resolution, 120 frames a second, through
    /// encrypted UDP that loses 2 % of its datagrams, reassembled and hardware-decoded. Includes a megabyte
    /// keyframe sent over UDP mid-stream (what happens when the iPad returns from the background).
    func testRealEncodedVideoSurvivesLossyUDPAndDecodes() throws {
        let width = 2_752, height = 2_064, total: UInt64 = 300
        let encoder: HEVCEncoder
        do { encoder = try HEVCEncoder(width: width, height: height, fps: 120, bitrate: 25_000_000) }
        catch { throw XCTSkip("Hardware HEVC encoding is unavailable here: \(error.localizedDescription)") }
        // Scrolling text-like stripes: every frame differs from the last.
        let images: [CVPixelBuffer] = (0..<8).map { step in
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            let pixels = buffer!
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(pixels)
            for row in 0..<height {
                let dark = ((row + step * 6) / 12) % 2 == 0
                memset(base + row * stride, dark ? 40 : 235, stride)
                if dark { var x = (row * 7) % 40; while x < width - 12 { memset(base + row * stride + x * 4, 235, 24); x += 40 } }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            return pixels
        }
        let credential = PairingCredential.password(try PairingKey())
        let session = UUID()
        let macQueue = DispatchQueue(label: "skydesk.test.mac.video"), padQueue = DispatchQueue(label: "skydesk.test.pad.video")
        let parameters = DeskNetwork.datagramParameters(credentials: [credential])
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let listening = expectation(description: "listening"), active = expectation(description: "UDP accepted")
        let finished = expectation(description: "all frames decoded")
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        var sender: VideoDatagramSender?
        let receiver = VideoDatagramReceiver(queue: padQueue)
        let decoder = HEVCDecoder()
        let relay = LossyRelay(); relay.loss = 0.02
        let lock = NSLock()
        var decoded: [UInt64] = [], problems: [String] = [], sentAt: [UInt64: UInt64] = [:], transit: [Double] = [], largest = 0
        listener.newConnectionHandler = { connection in
            let made = VideoDatagramSender(connection: connection, queue: macQueue)
            made.onHello = { $0 == session }
            made.onActive = { active.fulfill() }
            made.onStopped = { reason, unsent in if reason != nil || !unsent.isEmpty { lock.withLock { problems.append("UDP stopped: \(reason ?? "?")") } } }
            sender = made; made.start()
        }
        listener.start(queue: macQueue)
        wait(for: [listening], timeout: 5)
        let relayPort = try relay.start(towards: try XCTUnwrap(listener.port))
        receiver.onFrame = { sequence, payload in
            let arrived = monotonicNanos()
            do {
                let frame = try VideoFrame(data: payload)
                try decoder.decode(frame) { result in
                    lock.lock()
                    if case .failure(let error) = result { problems.append("frame \(sequence): \(error.localizedDescription)") }
                    decoded.append(sequence)
                    if let sent = sentAt[sequence], sequence > 1 { transit.append(Double(arrived - sent) / 1_000_000) }
                    let done = sequence == total
                    lock.unlock()
                    macQueue.async { sender?.acknowledge(sequence) }
                    if done { finished.fulfill() }
                }
            } catch { lock.withLock { problems.append("frame \(sequence): \(error.localizedDescription)") }; if sequence == total { finished.fulfill() } }
        }
        padQueue.async {
            receiver.attach(NWConnection(host: "127.0.0.1", port: relayPort, using: DeskNetwork.datagramParameters(credentials: [credential])), session: session)
        }
        wait(for: [active], timeout: 8)
        for index in 1...total {
            let moment = monotonicNanos()
            encoder.encode(images[Int(index) % images.count], sequence: index, captureTime: moment, timestamp: CMTime(value: Int64(index), timescale: 120),
                           forceKeyframe: index == 150) { result in
                guard case .success(let frame) = result, let payload = try? frame.encoded() else { lock.withLock { problems.append("encode \(index)") }; return }
                lock.withLock { sentAt[index] = monotonicNanos(); largest = max(largest, payload.count) }
                // The opening keyframe travels over TCP in a real session; everything after it over UDP.
                if index == 1 { padQueue.async { receiver.insertReliable(frame: 1, bytes: payload) } }
                else { sender?.send(frame: index, bytes: payload) }
            }
            Thread.sleep(forTimeInterval: 1.0 / 120)
        }
        encoder.flush()
        wait(for: [finished], timeout: 30)
        decoder.flush()
        padQueue.sync { receiver.detach() }
        sender?.close(); listener.cancel(); relay.stop()
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(problems, [])
        XCTAssertEqual(decoded, Array(1...total), "every frame decoded, in order")
        XCTAssertGreaterThan(relay.dropped, 20)
        XCTAssertGreaterThan(largest, 200_000, "the forced keyframe should be large")
        let sorted = transit.sorted()
        print(String(format: "Real HEVC over lossy encrypted UDP (2%% loss, loopback): %d frames, %d datagrams dropped, largest frame %d kB, encoded→reassembled median %.1f ms, 99th %.1f ms, worst %.1f ms",
                     decoded.count, relay.dropped, largest / 1_000, sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.99)], sorted.last ?? 0))
    }
    #endif

    /// Build 38's failure, end to end: the Mac sends the opening frame over UDP. The iPad must say so within half a
    /// second, and the stream must then start from what the Mac resends over TCP.
    func testAStreamWronglyStartedOnUDPIsRescuedQuickly() throws {
        let credential = PairingCredential.password(try PairingKey())
        let session = UUID()
        let macQueue = DispatchQueue(label: "skydesk.test.mac.orphan"), padQueue = DispatchQueue(label: "skydesk.test.pad.orphan")
        let parameters = DeskNetwork.datagramParameters(credentials: [credential])
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let listening = expectation(description: "listening"), active = expectation(description: "UDP accepted")
        let told = expectation(description: "iPad reports the orphaned stream"), shown = expectation(description: "frames released after the resend")
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        var sender: VideoDatagramSender?
        let receiver = VideoDatagramReceiver(queue: padQueue)
        var released: [UInt64] = []
        var began = Date()
        var noticedAfter = 0.0
        listener.newConnectionHandler = { connection in
            let made = VideoDatagramSender(connection: connection, queue: macQueue)
            made.onHello = { $0 == session }
            made.onActive = { active.fulfill() }
            // What the real host does when UDP stops: everything unacknowledged goes over TCP.
            made.onStopped = { _, unsent in padQueue.async { for item in unsent { receiver.insertReliable(frame: item.frame, bytes: item.bytes) } } }
            sender = made; made.start()
        }
        listener.start(queue: macQueue)
        wait(for: [listening], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        receiver.onFrame = { frame, _ in released.append(frame); if frame == 3 { shown.fulfill() } }
        receiver.onStopped = { _ in
            noticedAfter = Date().timeIntervalSince(began)
            told.fulfill()
            macQueue.async { sender?.close() }          // the iPad's "UDP stopped" message reaches the Mac
        }
        padQueue.async { receiver.attach(NWConnection(host: "127.0.0.1", port: port, using: DeskNetwork.datagramParameters(credentials: [credential])), session: session) }
        wait(for: [active], timeout: 8)
        began = Date()
        for frame in UInt64(1)...3 { sender?.send(frame: frame, bytes: frameBytes(frame)) }
        wait(for: [told, shown], timeout: 5)
        XCTAssertLessThan(noticedAfter, 0.9)
        XCTAssertEqual(padQueue.sync { released }, [1, 2, 3])
        listener.cancel()
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
