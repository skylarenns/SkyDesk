import Foundation
import Network
import CoreMedia
import CoreVideo
import SkyDeskCore

/// Synthetic pixels only: no screen permission, clipboard access, or input injection.
final class SmokeCheck {
    let queue = DispatchQueue(label: "skydesk.smoke.network", qos: .userInteractive)
    let ready = DispatchSemaphore(value: 0)
    let slots = DispatchSemaphore(value: 2)
    let done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    let decoder = HEVCDecoder()
    var listener: NWListener?
    var server: SecureChannel?
    var client: SecureChannel?
    var failure: String?
    var count = 0
    var expected = 0
    var encodeTimes: [Double] = []
    var decodeTimes: [Double] = []
    var roundTripTimes: [Double] = []
    var dimensions = CGSize.zero

    func fail(_ error: String) {
        lock.lock(); if failure == nil { failure = error }; lock.unlock()
        done.signal(); slots.signal(); ready.signal()
    }
    func run(width: Int, height: Int, frames: Int, lowLatency: Bool) throws {
        dimensions = CGSize(width: width, height: height); expected = frames
        let key = try PairingKey()
        let parameters = DeskNetwork.parameters(key: key)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let server = SecureChannel(connection: connection, queue: self.queue)
            self.server = server
            server.onReady = { [weak self] in self?.ready.signal() }
            server.onPacket = { [weak self] packet in
                guard let self else { return }
                do {
                    guard case .frameAck = try packet.controlMessage() else { throw DeskError.invalid("Missing frame acknowledgement.") }
                    self.slots.signal()
                } catch { self.fail(error.localizedDescription) }
            }
            server.onClose = { [weak self] error in if let error { self?.fail(error) } }
            server.start()
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state, let port = self.listener?.port {
                let client = SecureChannel(connection: NWConnection(host: "127.0.0.1", port: port,
                    using: DeskNetwork.parameters(key: key)), queue: self.queue)
                self.client = client
                client.onPacket = { [weak self] packet in self?.decode(packet) }
                client.onClose = { [weak self] error in if let error { self?.fail(error) } }
                client.start()
            } else if case .failed(let error) = state { self.fail(error.localizedDescription) }
        }
        listener.start(queue: queue)
        defer { queue.sync { client?.close(); server?.close(); listener.cancel() } }
        guard ready.wait(timeout: .now() + 10) == .success else { throw DeskError.invalid("TLS smoke connection timed out.") }
        try checkFailure()
        let encoder = try HEVCEncoder(width: width, height: height, fps: 120, bitrate: 40_000_000, lowLatencyRateControl: lowLatency)
        var image: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &image)
        guard status == kCVReturnSuccess, let image else { throw DeskError.system("Create synthetic image", status) }
        CVPixelBufferLockBaseAddress(image, [])
        let base = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(image)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * stride + x * 4
                base[offset] = UInt8(x % 256); base[offset + 1] = UInt8(y % 256)
                base[offset + 2] = UInt8((x / 32 + y / 32) % 2 == 0 ? 220 : 30); base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        for index in 1...frames {
            guard slots.wait(timeout: .now() + 10) == .success else { throw DeskError.invalid("Video pipeline stalled.") }
            try checkFailure()
            let now = monotonicNanos()
            encoder.encode(image, sequence: UInt64(index), captureTime: now,
                           timestamp: CMTime(value: Int64(index), timescale: 120)) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let frame):
                    self.lock.lock(); self.encodeTimes.append(Double(frame.encodeTime - now) / 1_000_000); self.lock.unlock()
                    self.queue.async { [weak self] in
                        do { self?.server?.send(WirePacket(kind: .video, payload: try frame.encoded())) }
                        catch { self?.fail(error.localizedDescription) }
                    }
                case .failure(let error): self.fail(error.localizedDescription)
                }
            }
        }
        encoder.flush()
        guard done.wait(timeout: .now() + 15) == .success else { throw DeskError.invalid("Hardware decode timed out.") }
        decoder.flush(); try checkFailure()
        guard count == frames else { throw DeskError.invalid("Decoded \(count) of \(frames) frames.") }
        let result: [String: Any] = [
            "result": "passed", "frames": count, "width": width, "height": height,
            "hardwareEncode": encoder.hardwareAccelerated, "hardwareDecode": decoder.hardwareAccelerated,
            "tls": "TLS 1.2 PSK AES-128-GCM loopback", "lowLatencyRateControl": lowLatency,
            "encodeP50MS": percentile(encodeTimes, 0.5), "encodeP95MS": percentile(encodeTimes, 0.95),
            "decodeP50MS": percentile(decodeTimes, 0.5), "decodeP95MS": percentile(decodeTimes, 0.95),
            "encodeTransportDecodeP95MS": percentile(roundTripTimes, 0.95),
            "scope": "Synthetic static pixels on one Mac. Excludes capture, LAN, iPad presentation, and input-to-photon latency. Not a sustained 120 FPS benchmark."
        ]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
    private func decode(_ packet: WirePacket) {
        do {
            guard packet.kind == .video else { throw DeskError.invalid("Non-video packet in smoke check.") }
            let frame = try VideoFrame(data: packet.payload)
            let start = monotonicNanos()
            try decoder.decode(frame) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let image):
                    guard CVPixelBufferGetWidth(image) == Int(self.dimensions.width), CVPixelBufferGetHeight(image) == Int(self.dimensions.height) else {
                        self.fail("Decoded dimensions differ from the source."); return
                    }
                    let now = monotonicNanos()
                    self.lock.lock()
                    self.decodeTimes.append(Double(now - start) / 1_000_000)
                    self.roundTripTimes.append(Double(now - frame.captureTime) / 1_000_000)
                    self.count += 1; let finished = self.count == self.expected
                    self.lock.unlock()
                    self.client?.send(.frameAck(frame.sequence))
                    if finished { self.done.signal() }
                case .failure(let error): self.fail(error.localizedDescription)
                }
            }
        } catch { fail(error.localizedDescription) }
    }
    private func checkFailure() throws {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw DeskError.invalid(failure) }
    }
    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
func number(_ name: String, fallback: Int) -> Int {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return fallback }
    return Int(arguments[index + 1]) ?? fallback
}
do {
    let width = number("--width", fallback: 2560), height = number("--height", fallback: 1600)
    let frames = number("--frames", fallback: 120)
    guard (64...4096).contains(width), (64...4096).contains(height), width % 2 == 0, height % 2 == 0,
          (1...10_000).contains(frames) else { throw DeskError.invalid("Use even dimensions 64–4096 and 1–10000 frames.") }
    try SmokeCheck().run(width: width, height: height, frames: frames, lowLatency: arguments.contains("--low-latency"))
} catch {
    fputs("SkyDesk check failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
