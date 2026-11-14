import XCTest
@testable import SkyDeskCore

/// A deterministic random source, so a failing run can be repeated exactly.
private struct Lottery: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state >> 11 | state << 53 }
    mutating func chance(_ probability: Double) -> Bool { Double(next() % 1_000_000) / 1_000_000 < probability }
}

final class DatagramVideoTests: XCTestCase {
    func testPacketsSurviveTheWireAndRubbishIsRejected() {
        let session = UUID()
        let packets: [DatagramPacket] = [
            .data(frame: 77, index: 3, count: 9, payload: Data([1, 2, 3])),
            .nack([.init(frame: 5, range: 2...4), .init(frame: 6, range: nil)]),
            .hello(session), .ready(session)
        ]
        for packet in packets { XCTAssertEqual(DatagramPacket(packet.encoded()), packet) }
        XCTAssertNil(DatagramPacket(Data()))
        XCTAssertNil(DatagramPacket(Data([9, 1, 2])))
        XCTAssertNil(DatagramPacket(Data([3, 1, 2])))                                         // hello without a full session
        XCTAssertNil(DatagramPacket(DatagramPacket.data(frame: 1, index: 0, count: 1, payload: Data()).encoded()))
        var bad = DatagramPacket.data(frame: 1, index: 0, count: 1, payload: Data([1])).encoded()
        bad[9] = 0; bad[10] = 5                                                              // index 5 of 1
        XCTAssertNil(DatagramPacket(bad))
        XCTAssertLessThanOrEqual(DatagramPacket.data(frame: 1, index: 0, count: 1, payload: Data(count: DatagramPacket.payloadSize)).encoded().count, 1_200)
    }

    func testAFrameArrivingInAnyOrderIsReleasedWholeAndInSequence() {
        var send = DatagramSendBuffer()
        let first = Data((0..<3_000).map { UInt8(truncatingIfNeeded: $0) }), second = Data(repeating: 7, count: 500)
        XCTAssertTrue(send.add(frame: 1, bytes: first, now: 0)); XCTAssertTrue(send.add(frame: 2, bytes: second, now: 0))
        var packets: [DatagramPacket] = []
        while let packet = send.next(budget: 10_000, now: 0) { packets.append(packet) }
        XCTAssertEqual(packets.count, 4)                                                      // 3 pieces + 1
        var receive = DatagramReceiveBuffer(first: 1)
        var released: [(frame: UInt64, bytes: Data)] = []
        for packet in packets.reversed() {
            guard case .data(let frame, let index, let count, let payload) = packet else { return XCTFail() }
            released += receive.insert(frame: frame, index: index, count: count, payload: payload, now: 0.001)
        }
        XCTAssertEqual(released.map(\.frame), [1, 2]); XCTAssertEqual(released[0].bytes, first); XCTAssertEqual(released[1].bytes, second)
        // Late copies change nothing.
        guard case .data(let frame, let index, let count, let payload) = packets[0] else { return XCTFail() }
        XCTAssertTrue(receive.insert(frame: frame, index: index, count: count, payload: payload, now: 0.002).isEmpty)
        XCTAssertEqual(receive.duplicates, 1)
    }

    func testLaterFramesOnUDPWaitForTheKeyframeStillArrivingOverTCP() {
        var receive = DatagramReceiveBuffer()
        XCTAssertTrue(receive.insert(frame: 2, index: 0, count: 1, payload: Data([2]), now: 0).isEmpty)
        XCTAssertTrue(receive.insert(frame: 3, index: 0, count: 1, payload: Data([3]), now: 0).isEmpty)
        // Until TCP has brought the stream's first frame nothing is released and nothing is asked for.
        XCTAssertTrue(receive.missing(now: 1).isEmpty)
        XCTAssertEqual(receive.insert(frame: 1, bytes: Data([1])).map(\.frame), [1, 2, 3])
        XCTAssertEqual(receive.next, 4)
        // After UDP gives up, the Mac resends over TCP what the iPad already has: ignored.
        XCTAssertTrue(receive.insert(frame: 3, bytes: Data([3])).isEmpty)
        XCTAssertEqual(receive.insert(frame: 4, bytes: Data([4])).map(\.frame), [4])
    }

    func testOnlyTheMissingPiecesAreAskedForAndOnlyAfterAMoment() {
        var receive = DatagramReceiveBuffer(first: 10)
        for index in [0, 1, 4, 5, 7] { _ = receive.insert(frame: 10, index: index, count: 8, payload: Data([UInt8(index)]), now: 0) }
        // Only just arrived: the holes may be plain reordering.
        XCTAssertTrue(receive.missing(now: 0.001).isEmpty)
        // Pieces 2, 3 and 6 lie below a piece that did arrive: asked for after the reordering allowance.
        XCTAssertEqual(receive.missing(now: 0.0025), [.init(frame: 10, range: 2...3), .init(frame: 10, range: 6...6)])
        // Not asked again before an answer could have come back.
        XCTAssertTrue(receive.missing(now: 0.010).isEmpty)
        XCTAssertEqual(receive.missing(now: 0.022).count, 2)
        // A frame whose last pieces never came: asked for once it has stood still.
        for index in 0..<3 { _ = receive.insert(frame: 11, index: index, count: 5, payload: Data([1]), now: 0.030) }
        XCTAssertTrue(receive.missing(now: 0.032).filter { $0.frame == 11 }.isEmpty)
        XCTAssertEqual(receive.missing(now: 0.0345).filter { $0.frame == 11 }, [.init(frame: 11, range: 3...4)])
        // A newer frame arrives: frame 12 was lost whole and is asked for after the reordering allowance.
        _ = receive.insert(frame: 13, index: 0, count: 1, payload: Data([1]), now: 0.040)
        XCTAssertTrue(receive.missing(now: 0.041).filter { $0.frame == 12 }.isEmpty)
        XCTAssertEqual(receive.missing(now: 0.0425).filter { $0.frame == 12 }, [.init(frame: 12, range: nil)])
        // The time an answer takes is learned, so a far-away Mac is not asked twice for the same piece.
        var far = DatagramReceiveBuffer(first: 1)
        _ = far.insert(frame: 1, index: 0, count: 3, payload: Data([1]), now: 0)
        _ = far.insert(frame: 1, index: 2, count: 3, payload: Data([1]), now: 0)
        XCTAssertEqual(far.missing(now: 0.003).count, 1)
        _ = far.insert(frame: 1, index: 1, count: 3, payload: Data([1]), now: 0.083)       // 80 ms later
        XCTAssertGreaterThan(far.nackSpacing, 0.03)
    }

    func testTheSenderResendsOnRequestProbesASilentFrameAndForgetsAcknowledgedOnes() {
        var send = DatagramSendBuffer()
        XCTAssertTrue(send.add(frame: 1, bytes: Data(count: 3_000), now: 0))
        while send.next(budget: 10_000, now: 0) != nil {}
        // Asked at once: the first copy is probably still in flight, so nothing is resent yet.
        send.request([.init(frame: 1, range: 1...1)], now: 0.002)
        XCTAssertNil(send.next(budget: 10_000, now: 0.002))
        send.request([.init(frame: 1, range: 1...1), .init(frame: 99, range: nil)], now: 0.012)
        guard case .data(1, 1, 3, _)? = send.next(budget: 10_000, now: 0.012) else { return XCTFail("piece 1 not resent") }
        XCTAssertNil(send.next(budget: 10_000, now: 0.012))
        XCTAssertEqual(send.piecesResent, 1)
        // Nothing heard about the frame: its last piece goes again, so the iPad learns the frame exists.
        send.probe(now: 0.03); XCTAssertNil(send.next(budget: 10_000, now: 0.03))
        send.probe(now: 0.05)
        guard case .data(1, 2, 3, _)? = send.next(budget: 10_000, now: 0.05) else { return XCTFail("no probe") }
        // The pacing budget is respected.
        XCTAssertTrue(send.add(frame: 2, bytes: Data(count: 2_000), now: 0.05))
        XCTAssertNil(send.next(budget: 500, now: 0.05))
        XCTAssertNotNil(send.next(budget: 1_180, now: 0.05))
        XCTAssertEqual(send.unacknowledged().map(\.frame), [1, 2]); XCTAssertEqual(send.unacknowledged()[1].bytes.count, 2_000)
        send.acknowledge(1); send.acknowledge(2)
        XCTAssertTrue(send.isEmpty); XCTAssertEqual(send.bytesHeld, 0)
        XCTAssertNil(send.next(budget: 10_000, now: 0.06))
    }

    func testTheFirstFrameOfASessionGoesOverTCPHoweverSmallItIs() {
        // The failure of build 38 on the real devices: UDP was up 36 ms after connecting, the opening keyframe of a
        // quiet desktop was about 200 kB, and it went over UDP although the iPad starts the stream on TCP.
        var policy = VideoPathPolicy()
        XCTAssertFalse(policy.useDatagrams(available: true, bytes: 200_000))
        XCTAssertTrue(policy.useDatagrams(available: true, bytes: 26_000))
        // Large frames (a keyframe after returning from the background) stay on TCP; so does everything while UDP is down.
        XCTAssertFalse(policy.useDatagrams(available: true, bytes: 1_500_000))
        XCTAssertFalse(policy.useDatagrams(available: false, bytes: 26_000))
        XCTAssertTrue(policy.useDatagrams(available: true, bytes: VideoPathPolicy.largestDatagramFrame))
        // UDP not up yet when the session starts: the first frames go over TCP anyway, then UDP takes over.
        var later = VideoPathPolicy()
        XCTAssertFalse(later.useDatagrams(available: false, bytes: 1_500_000))
        XCTAssertTrue(later.useDatagrams(available: true, bytes: 26_000))
    }

    func testTheIPadKnowsWhenVideoArrivesBeforeTheStreamHasStarted() {
        var receive = DatagramReceiveBuffer()
        XCTAssertFalse(receive.waitingForStart)
        _ = receive.insert(frame: 1, index: 0, count: 2, payload: Data([1]), now: 0)
        XCTAssertTrue(receive.waitingForStart)
        _ = receive.insert(frame: 1, index: 1, count: 2, payload: Data([2]), now: 0)
        XCTAssertTrue(receive.waitingForStart, "complete, but nothing says the stream starts here")
        // TCP brings the frame (the Mac resends it after being told): the stream starts.
        XCTAssertEqual(receive.insert(frame: 1, bytes: Data([1, 2])).map(\.frame), [1])
        XCTAssertFalse(receive.waitingForStart)
    }

    func testPacingSpreadsAKeyframeButNotAnOrdinaryFrame() {
        var pacer = DatagramPacer()
        XCTAssertEqual(DatagramPacer.rate(forBitrate: 25_000_000), 150_000_000)
        XCTAssertEqual(DatagramPacer.rate(forBitrate: 1_500_000), 30_000_000)
        // A 26 kB frame fits the allowance and leaves in one go.
        XCTAssertGreaterThanOrEqual(pacer.refill(rate: 150_000_000, now: 0), 26_000)
        pacer.spend(96_000)
        XCTAssertEqual(pacer.refill(rate: 150_000_000, now: 0), 0)
        // 1 ms at 150 Mbps is 18,750 bytes.
        XCTAssertEqual(pacer.refill(rate: 150_000_000, now: 0.001), 18_750)
        XCTAssertEqual(pacer.wait(for: 20_000, rate: 150_000_000), 1_250.0 * 8 / 150_000_000, accuracy: 1e-9)
        XCTAssertEqual(pacer.refill(rate: 150_000_000, now: 10), 96_000)
    }

    /// One simulated stream: 120 frames a second for `seconds`, over a link that delays each datagram by `oneWay`
    /// (plus jitter) and loses it with `loss` probability (and everything during `outage`). Returns how long each
    /// frame took from "encoded" to "ready for the decoder", in milliseconds.
    private func simulate(loss: Double, oneWay: Double = 0.0025, outage: ClosedRange<Double>? = nil, seconds: Double = 8, seed: UInt64 = 42,
                          keyframeAt: UInt64? = nil, nackEvery: Double = 0.002) -> [Double] {
        var lottery = Lottery(state: seed)
        var send = DatagramSendBuffer(), receive = DatagramReceiveBuffer(first: 1), pacer = DatagramPacer()
        var toReceiver: [(at: Double, packet: DatagramPacket)] = [], toSender: [(at: Double, packet: DatagramPacket)] = []
        var acks: [(at: Double, frame: UInt64)] = []
        var encodedAt: [UInt64: Double] = [:], latency: [Double] = []
        var delivered: [UInt64] = []
        let step = 0.0005, rate = DatagramPacer.rate(forBitrate: 25_000_000)
        var now = 0.0, nextFrame: UInt64 = 1, nextFrameAt = 0.0, nextNackCheck = 0.0
        func lost(_ time: Double, _ lottery: inout Lottery) -> Bool { (outage?.contains(time) ?? false) || lottery.chance(loss) }
        while now < seconds + 2 {
            if now >= nextFrameAt, now < seconds {
                // Ordinary frames average about 26 kB at 25 Mbps. (The megabyte keyframe that opens a session goes
                // over TCP before UDP takes over; `testAKeyframeIsSpreadOutAndStillArrives` covers one on UDP.)
                let size = keyframeAt == nextFrame ? 1_500_000 : 8_000 + Int(lottery.next() % 36_000)
                XCTAssertTrue(send.add(frame: nextFrame, bytes: Data(repeating: UInt8(truncatingIfNeeded: nextFrame), count: size), now: now))
                encodedAt[nextFrame] = now; nextFrame += 1; nextFrameAt += 1.0 / 120
            }
            for ack in acks where ack.at <= now { send.acknowledge(ack.frame) }
            acks.removeAll { $0.at <= now }
            for item in toSender where item.at <= now { if case .nack(let missing) = item.packet { send.request(missing, now: now) } }
            toSender.removeAll { $0.at <= now }
            send.probe(now: now)
            var budget = pacer.refill(rate: rate, now: now)
            while let packet = send.next(budget: budget, now: now) {
                let bytes = packet.encoded().count
                pacer.spend(bytes); budget -= bytes
                if !lost(now, &lottery) { toReceiver.append((now + oneWay + Double(lottery.next() % 1_000) / 1_000_000, packet)) }
            }
            for item in toReceiver where item.at <= now {
                guard case .data(let frame, let index, let count, let payload) = item.packet else { continue }
                for ready in receive.insert(frame: frame, index: index, count: count, payload: payload, now: now) {
                    delivered.append(ready.frame)
                    XCTAssertEqual(ready.bytes.first, UInt8(truncatingIfNeeded: ready.frame))
                    latency.append((now - encodedAt[ready.frame]!) * 1_000)
                    acks.append((now + oneWay, ready.frame))              // acknowledgements travel on the TCP control channel
                }
            }
            toReceiver.removeAll { $0.at <= now }
            if now >= nextNackCheck {
                nextNackCheck = now + nackEvery
                let missing = receive.missing(now: now)
                if !missing.isEmpty, !lost(now, &lottery) { toSender.append((now + oneWay, .nack(missing))) }
            }
            now += step
        }
        XCTAssertEqual(delivered, Array(1..<nextFrame), "every frame must arrive, once, in order")
        XCTAssertTrue(send.isEmpty)
        return latency
    }
    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted(); return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }

    func testACleanLinkAddsOnlyTheTripItself() {
        let latency = simulate(loss: 0)
        XCTAssertLessThan(percentile(latency, 0.5), 5); XCTAssertLessThan(latency.max()!, 12)
    }

    func testAKeyframeIsSpreadOutAndStillArrives() {
        // A megabyte keyframe mid-stream (return from the background): paced over tens of milliseconds, the frames
        // behind it wait their turn, and the stream is back to normal straight after.
        let latency = simulate(loss: 0.01, seconds: 4, keyframeAt: 240)
        XCTAssertLessThan(latency.max()!, 220)
        XCTAssertLessThan(percentile(Array(latency.suffix(200)), 0.5), 8)
    }

    func testLostPacketsCostAboutOneRoundTripNotAStall() {
        for (loss, limit99) in [(0.001, 20.0), (0.01, 30.0), (0.05, 45.0)] {
            let latency = simulate(loss: loss)
            let median = percentile(latency, 0.5), high = percentile(latency, 0.99), worst = latency.max()!
            print(String(format: "UDP simulation, %.1f%% loss, 5 ms round trip: median %.1f ms, 99th %.1f ms, worst %.1f ms over %d frames",
                         loss * 100, median, high, worst, latency.count))
            XCTAssertLessThan(median, loss > 0.02 ? 16 : 8); XCTAssertLessThan(high, limit99); XCTAssertLessThan(worst, 150)
        }
    }

    func testAWideAreaLinkAndAShortOutageRecoverWithoutLosingAFrame() {
        // 40 ms round trip, 2 % loss (a VPN away from home).
        let far = simulate(loss: 0.02, oneWay: 0.020)
        print(String(format: "UDP simulation, 2%% loss, 40 ms round trip: median %.1f ms, 99th %.1f ms, worst %.1f ms",
                     percentile(far, 0.5), percentile(far, 0.99), far.max()!))
        XCTAssertLessThan(percentile(far, 0.99), 220)
        // The link is dead for 60 ms (a Wi-Fi channel hop): everything sent then is lost, and all of it comes back.
        let hop = simulate(loss: 0, outage: 3.0...3.06)
        print(String(format: "UDP simulation, 60 ms outage: worst frame %.1f ms late, 99th %.1f ms", hop.max()!, percentile(hop, 0.99)))
        XCTAssertLessThan(hop.max()!, 160)
    }
}
