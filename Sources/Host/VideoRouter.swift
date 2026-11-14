import Foundation
import Network

/// Chooses the path for each encoded frame: UDP once the iPad's UDP flow has been accepted for this session, TCP
/// before that and again if UDP stops getting through. Frames carry their sequence number on both paths and the
/// iPad puts them in order, so a switch never needs a keyframe. Safe from any thread.
final class VideoRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var tcp: SecureChannel?
    private var udp: VideoDatagramSender?
    private var session: UUID?
    private var bitrateTarget = 25_000_000
    private var resent: Double?
    private var gaveUp = false
    static let largestDatagramFrame = 256_000
    /// Called (on any thread) when the path changes: true = UDP, with the reason when it went back to TCP.
    var onPathChange: ((Bool, String?) -> Void)?

    /// A session starts. `session` nil means UDP was not agreed and every frame goes over TCP.
    func begin(session: UUID?, tcp: SecureChannel, bitrate: Int) {
        lock.withLock { self.session = session; self.tcp = tcp; bitrateTarget = bitrate; resent = nil; gaveUp = false }
    }
    func end() {
        let old: VideoDatagramSender? = lock.withLock { let value = udp; udp = nil; tcp = nil; session = nil; resent = nil; return value }
        old?.close()
    }
    var bitrate: Int {
        get { lock.withLock { bitrateTarget } }
        set { lock.withLock { bitrateTarget = newValue } }
    }
    var usingUDP: Bool { lock.withLock { udp != nil } }
    /// Share of datagrams sent twice in the last measured interval; nil on TCP.
    var resentShare: Double? { lock.withLock { udp == nil ? nil : resent } }

    /// A UDP flow said hello with this session: is it ours, and is UDP still wanted?
    func accepts(_ candidate: UUID) -> Bool { lock.withLock { session == candidate && udp == nil && !gaveUp } }
    func activate(_ sender: VideoDatagramSender) {
        let taken: Bool = lock.withLock {
            guard udp == nil, session != nil, !gaveUp else { return false }
            udp = sender; return true
        }
        if taken { onPathChange?(true, nil) } else { sender.close() }
    }
    /// A sender stopped. If it was the one in use, everything it had not got acknowledged goes over TCP.
    func stopped(_ sender: VideoDatagramSender, reason: String?, unsent: [(frame: UInt64, bytes: Data)]) {
        let (channel, wasActive): (SecureChannel?, Bool) = lock.withLock {
            let active = udp === sender
            if active { udp = nil; resent = nil; gaveUp = true }
            return (tcp, active)
        }
        for item in unsent { channel?.send(WirePacket(kind: .video, payload: item.bytes)) }
        if wasActive { onPathChange?(false, reason) }
    }
    /// The iPad reports that its end of the UDP flow is gone.
    func giveUp() {
        let old: VideoDatagramSender? = lock.withLock { gaveUp = true; return udp }
        old?.close()          // its `onStopped` hands the unacknowledged frames to TCP
    }
    func send(_ frame: VideoFrame) {
        let (channel, sender): (SecureChannel?, VideoDatagramSender?) = lock.withLock { (tcp, udp) }
        do {
            let payload = try frame.encoded()
            // A keyframe is a megabyte or two (a session's first frame, or the first after the iPad returns from the
            // background). As datagrams it would have to be spread over a tenth of a second or risk overflowing
            // buffers (measured: 2 MB took 110 ms and held up the frames behind it); TCP is built for exactly that
            // kind of burst, and the iPad orders frames by number whichever way they come.
            if let sender, payload.count <= Self.largestDatagramFrame { sender.send(frame: frame.sequence, bytes: payload) }
            else { channel?.send(WirePacket(kind: .video, payload: payload)) }
        } catch { channel?.close(reason: error.localizedDescription) }
    }
    func acknowledge(_ sequence: UInt64) { lock.withLock { udp }?.acknowledge(sequence) }
    /// Measures the share of resent datagrams since the last call; the result is read through `resentShare`.
    func measure() {
        guard let sender = lock.withLock({ udp }) else { return }
        sender.drainCounters { [weak self, weak sender] counters in
            guard let self, let sender else { return }
            self.lock.withLock {
                guard self.udp === sender else { return }
                self.resent = counters.sent + counters.resent >= 20 ? Double(counters.resent) / Double(counters.sent + counters.resent) : 0
            }
        }
    }
}
