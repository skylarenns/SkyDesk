import Foundation

/// Lowers the video bitrate when the network cannot keep up and raises it again when it can (build 33).
///
/// Two signs of trouble, both measured on the Mac: video waiting to be sent (`backlogBytes`), and frames taking
/// longer than usual from "handed to the network" to "acknowledged by the iPad" (`transitMS`). Encoder time is
/// not part of either, so a busy Mac never looks like a slow network.
///
/// A slow network path is not that kind of trouble. On 2026-11-13 the iPad's Wi-Fi answered everything (plain
/// pings included) about 80 ms late for two minutes; build 33 read that as congestion and held the bitrate at
/// its floor, which blurred the picture and could not shorten the delay. So the iPad's own round-trip time is
/// taken off first: only time beyond it, video waiting behind a link that cannot carry it, counts as late.
public struct BitrateController: Equatable {
    public struct Sample {
        /// Length of the interval the sample covers.
        public var seconds: Double
        /// Mean network-and-decode time of the frames acknowledged in the interval, and how many there were.
        public var transitMS: Double
        public var acknowledged: Int
        /// Video bytes handed to the connection that it has not yet taken.
        public var backlogBytes: Int
        /// Video bytes the iPad acknowledged in the interval: what the network actually carried.
        public var deliveredBytes: Int
        /// The network round trip the iPad last measured with its own small pings, if known.
        public var roundTripMS: Double?
        /// Video over UDP only: the share of datagrams that had to be sent again in the interval.
        public var resentShare: Double?
        public init(seconds: Double, transitMS: Double, acknowledged: Int, backlogBytes: Int, deliveredBytes: Int, roundTripMS: Double? = nil,
                    resentShare: Double? = nil) {
            self.seconds = seconds; self.transitMS = transitMS; self.acknowledged = acknowledged
            self.backlogBytes = backlogBytes; self.deliveredBytes = deliveredBytes; self.roundTripMS = roundTripMS
            self.resentShare = resentShare
        }
    }
    public static let floor = 1_500_000
    /// The user's setting: never exceeded.
    public let maximum: Int
    public let minimum: Int
    public private(set) var target: Int
    /// Why the target last went down, for the log.
    public private(set) var reason = ""
    /// Lowest usual transit time seen; drifts up slowly so a slower route is learned.
    private var baseline: Double?
    /// The lowest rate at which the network recently fell behind. Climbing is fast below it and careful near it.
    private var ceiling: Int?
    /// How many times in a row trouble came back before the ceiling expired: twice or more means a real limit
    /// (a slow uplink away from home), not a passing hiccup.
    private var hits = 0
    private var sinceTrouble = 0.0
    private var sinceCut = 10.0
    private var backedUpBefore = false
    /// How long frames have been late without a break. The iPad's round-trip figure is a two-second average, so a
    /// path that has just become slow looks like queueing for a moment; real queueing lasts.
    private var lateFor = 0.0
    public static let lateBeforeCutting = 1.5
    public static let heavyLoss = 0.12
    private var grace = 0.0

    public init(maximum: Int) {
        self.maximum = max(maximum, 250_000)
        minimum = min(Self.floor, self.maximum)
        target = self.maximum
    }
    /// Ignore the next `seconds`: a keyframe (session start, return from the background) is a burst, not congestion.
    public mutating func startGrace(_ seconds: Double) { grace = max(grace, seconds); backedUpBefore = false; lateFor = 0 }

    /// Returns the new target when it changed.
    public mutating func update(_ sample: Sample) -> Int? {
        let seconds = max(0.01, min(5, sample.seconds))
        sinceCut += seconds; sinceTrouble += seconds
        if grace > 0 { grace -= seconds; return nil }
        var late = false
        var queued = 0.0
        if sample.acknowledged >= 5, sample.transitMS.isFinite, sample.transitMS > 0 {
            // Time beyond the path's own round trip (a floor of 3 ms keeps the arithmetic sane).
            let path = sample.roundTripMS.map { max(0, $0) } ?? 0
            queued = max(3, sample.transitMS - path)
            if let usual = baseline {
                late = queued > usual + max(30, usual)
                baseline = min(queued, usual * (1 + 0.01 * seconds))
            } else { baseline = queued }
        }
        // Over UDP nothing holds the sender back, so a link that drops a large share of what is sent is itself the
        // sign that too much is being sent. (A few percent is ordinary Wi-Fi and is simply repaired.)
        let lossy = (sample.resentShare ?? 0) >= Self.heavyLoss
        lateFor = late || lossy ? lateFor + seconds : 0
        let delayed = lateFor >= Self.lateBeforeCutting
        let backlogSeconds = Double(max(0, sample.backlogBytes)) * 8 / Double(target)
        // One reading above a quarter second can be a single large frame caught mid-send; two in a row cannot.
        let backedUp = backlogSeconds > 1 || (backlogSeconds > 0.25 && backedUpBefore)
        backedUpBefore = backlogSeconds > 0.25
        if backedUp || delayed {
            // Give the previous cut a second to show before cutting again.
            guard sinceCut >= 1 else { return nil }
            // Aim a little under what the network actually carried, but never cut by less than a quarter or by more
            // than half in one step: a stalled half second says nothing about the link's real speed.
            let before = target
            let delivered = Int(Double(max(0, sample.deliveredBytes)) * 8 / seconds)
            let guided = Int(Double(min(before, max(delivered, minimum))) * 0.85)
            let next = max(minimum, min(Int(Double(before) * 0.75), max(Int(Double(before) * 0.5), guided)))
            if let known = ceiling { ceiling = min(known, before); hits += 1 } else { ceiling = before; hits = 1 }
            sinceTrouble = 0
            guard next < target else { return nil }
            reason = backedUp ? String(format: "%.1f s of video waiting to be sent", backlogSeconds)
                : lossy && !late ? String(format: "%.0f%% of the video had to be sent twice", (sample.resentShare ?? 0) * 100)
                : String(format: "frames queueing %.0f ms instead of the usual %.0f ms", queued, baseline ?? 0)
            target = next; sinceCut = 0
            return target
        }
        guard target < maximum, sinceCut >= 2 else { return nil }
        if sinceTrouble > 20 { ceiling = nil; hits = 0 }
        // 15 % a second back towards the rate that last failed; beyond 90 % of it, 3 % a second (1 % once the
        // limit has shown itself twice).
        let careful = ceiling.map { Double(target) >= Double($0) * 0.9 } ?? false
        let next = min(maximum, Int(Double(target) * pow(careful ? (hits >= 2 ? 1.01 : 1.03) : 1.15, seconds)) + 1)
        guard next > target else { return nil }
        target = next
        return target
    }
}
