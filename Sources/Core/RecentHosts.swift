import Foundation

/// A Mac the iPad connected to successfully. The pairing credential lives in the Keychain under `keychainAccount`.
public struct RecentHost: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var address: String
    public var name: String
    /// Bonjour service name, when the Mac was found nearby; survives DHCP address changes.
    public var serviceName: String?
    public var lastConnected: Date
    /// Which Mac this address belongs to (build 37): the iPad's own key for that Mac is stored under it, so
    /// every address of the same Mac uses the same key.
    public var hostID: UUID?
    public init(id: UUID = UUID(), address: String, name: String, serviceName: String? = nil, lastConnected: Date, hostID: UUID? = nil) {
        self.id = id; self.address = address; self.name = name; self.serviceName = serviceName; self.lastConnected = lastConnected
        self.hostID = hostID
    }
    public static func deviceKeyAccount(host: UUID) -> String { "pad-device:" + host.uuidString }
    /// Stores the derived 256-bit key, never the typed password.
    public var keychainAccount: String { "pad-v2:" + id.uuidString }
}

/// The five most recent Mac addresses, newest first, one entry per address.
public struct RecentHostList: Codable, Equatable, Sendable {
    public static let limit = 5
    /// Keychain account holding the most recently used credential, offered for a new address of the same Mac.
    public static let lastCredentialAccount = "pad-v2:last"
    public private(set) var entries: [RecentHost]
    public init(entries: [RecentHost] = []) {
        self.entries = Array(entries.sorted { $0.lastConnected > $1.lastConnected }.prefix(Self.limit))
    }
    public static func key(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    /// Records a successful connection. Returns the stored entry and any entries pushed off the end
    /// (whose Keychain items the caller deletes).
    @discardableResult
    public mutating func record(address: String, name: String, serviceName: String?, at date: Date, hostID: UUID? = nil) -> (entry: RecentHost, removed: [RecentHost]) {
        let clean = address.trimmingCharacters(in: .whitespacesAndNewlines)
        var entry: RecentHost
        if let index = entries.firstIndex(where: { Self.key($0.address) == Self.key(clean) }) {
            entry = entries.remove(at: index)
            entry.address = clean
            entry.name = name.isEmpty ? entry.name : name
            entry.serviceName = serviceName ?? entry.serviceName
            entry.lastConnected = date
            entry.hostID = hostID ?? entry.hostID
        } else {
            entry = RecentHost(address: clean, name: name.isEmpty ? clean : name, serviceName: serviceName, lastConnected: date, hostID: hostID)
        }
        entries.insert(entry, at: 0)
        let removed = Array(entries.dropFirst(Self.limit))
        entries = Array(entries.prefix(Self.limit))
        return (entry, removed)
    }
    @discardableResult
    public mutating func remove(id: UUID) -> RecentHost? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return entries.remove(at: index)
    }
    public var mostRecent: RecentHost? { entries.first }
    public func entry(serviceName: String) -> RecentHost? { entries.first { $0.serviceName == serviceName } }

    public static func load(from defaults: UserDefaults, key: String = "recentHosts") -> RecentHostList {
        guard let data = defaults.data(forKey: key), let list = try? JSONDecoder().decode(RecentHostList.self, from: data) else {
            return RecentHostList()
        }
        return RecentHostList(entries: list.entries)
    }
    public func save(to defaults: UserDefaults, key: String = "recentHosts") {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: key) }
    }
}

/// What the iPad does with a session when it leaves or returns to the foreground.
public enum SessionLifecycle {
    /// iPadOS gives a backgrounded app roughly 30 s of runtime with a background task; after that it is suspended.
    public enum BackgroundAction: Equatable {
        /// Release held input, pause video, keep the link alive until the grace period ends.
        case pauseAndHold
        /// The Mac cannot pause video (older host) or nothing is connected yet: end now, reconnect on return.
        case disconnectAndResumeLater
        case nothing
    }
    public enum ForegroundAction: Equatable {
        /// The held session is still alive: resume video.
        case resumeVideo
        /// The session ended while away: reconnect straight away with the saved credential.
        case reconnect
        /// Nothing was connected (or the user had disconnected): opening the app means "connect", so try the
        /// most recent Mac, exactly as on a fresh launch (5 s, then the connection screen).
        case connectToMostRecent
        case nothing
    }
    /// A link whose last heartbeat reply is older than this is treated as dead rather than waited on.
    public static let staleAfterSeconds: Double = 2.5

    public static func onBackground(connected: Bool, connecting: Bool, hostCanPause: Bool) -> BackgroundAction {
        if connected { return hostCanPause ? .pauseAndHold : .disconnectAndResumeLater }
        return connecting ? .disconnectAndResumeLater : .nothing
    }
    public static func onForeground(connected: Bool, lastReplyAge: Double?, resumeWanted: Bool,
                                    connecting: Bool = false) -> ForegroundAction {
        if connected, let age = lastReplyAge, age < staleAfterSeconds { return .resumeVideo }
        if connected || resumeWanted { return .reconnect }
        return connecting ? .nothing : .connectToMostRecent
    }
}

/// How long an automatic connection may take before the iPad shows the connection screen instead.
public enum AutoConnect {
    public static let deadlineSeconds: Double = 5
    /// First launch of a new build: the Mac is usually restarting into its own update at the same moment,
    /// so keep retrying longer before showing the connection screen.
    public static let afterUpdateSeconds: Double = 25
    public static func deadline(justUpdated: Bool) -> Double { justUpdated ? afterUpdateSeconds : deadlineSeconds }
    /// The Mac to try on launch, if any. Only entries with a saved credential qualify.
    public static func launchTarget(_ list: RecentHostList, hasCredential: (RecentHost) -> Bool) -> RecentHost? {
        list.entries.first(where: hasCredential)
    }
}

/// What kind of link a session runs over, for the iPad's toolbar and the statistics log.
public enum LinkKind: Equatable {
    case wireless, cable, vpn
    /// `interfaces` are the connection path's interface names, most preferred first. A tunnel (utun, ipsec, ppp)
    /// is neither Wi-Fi nor cellular to the system, and before build 31 it was shown as a USB cable.
    public static func of(interfaces: [String], wifi: Bool, cellular: Bool) -> LinkKind {
        if let first = interfaces.first, ["utun", "ipsec", "ppp", "wg"].contains(where: first.hasPrefix) { return .vpn }
        return wifi || cellular ? .wireless : .cable
    }
}

/// Several remembered addresses can belong to the same Mac (home Wi-Fi, a VPN address for use away from home).
/// The iPad asks all of them at once and uses the newest one that answers (build 33). Index 0 is the newest.
public struct AddressRace {
    public enum Step: Equatable {
        case wait
        /// A newer address may still answer: give it a moment, then use the best one so far.
        case waitBriefly
        case choose(Int?)
    }
    private let count: Int
    private var answered: Set<Int> = []
    private var failed: Set<Int> = []
    public init(count: Int) { self.count = count }
    public var best: Int? { answered.min() }
    public mutating func answered(_ index: Int) -> Step {
        answered.insert(index)
        return settled ?? .waitBriefly
    }
    public mutating func failed(_ index: Int) -> Step {
        failed.insert(index)
        return settled ?? .wait
    }
    /// Decided once nothing newer than the best answer is still pending, or once everything failed.
    private var settled: Step? {
        if let best, (0..<best).allSatisfy(failed.contains) { return .choose(best) }
        return failed.count >= count ? .choose(nil) : nil
    }
}
