import Foundation

/// One secret a connection may authenticate with, and the name it is offered under in the handshake.
public struct PairingCredential: Equatable, Sendable {
    public let key: PairingKey
    public let identity: String
    public init(key: PairingKey, identity: String) { self.key = key; self.identity = identity }
    /// The shared pairing password (every build since 12).
    public static func password(_ key: PairingKey) -> PairingCredential { .init(key: key, identity: PairingPassword.pskIdentity) }
    /// A key the Mac issued to one iPad (build 37).
    public static func device(_ id: UUID, key: PairingKey) -> PairingCredential { .init(key: key, identity: "SkyDesk-device-" + id.uuidString) }
}

/// An iPad the Mac has issued its own key to. The key itself lives in the Keychain under `keychainAccount`.
public struct PairedDevice: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let added: Date
    public var lastSeen: Date
    public init(id: UUID, name: String, added: Date, lastSeen: Date) { self.id = id; self.name = name; self.added = added; self.lastSeen = lastSeen }
    public var keychainAccount: String { "host-device:" + id.uuidString }
}

/// The Mac's list of paired iPads, most recently seen first. Each has its own key, so one can be removed without
/// the others having to pair again, and changing the password only affects iPads that have not paired yet.
public struct PairedDeviceList: Codable, Equatable, Sendable {
    public static let limit = 12
    public private(set) var devices: [PairedDevice]
    public init(devices: [PairedDevice] = []) { self.devices = Array(devices.sorted { $0.lastSeen > $1.lastSeen }.prefix(Self.limit)) }
    public func contains(_ id: UUID) -> Bool { devices.contains { $0.id == id } }
    public static func cleanName(_ name: String?) -> String {
        let trimmed = (name ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "iPad" : String(trimmed.prefix(48))
    }
    /// Adds a device or refreshes one already listed. Returns devices pushed off the end (their keys are deleted).
    @discardableResult
    public mutating func record(_ id: UUID, name: String?, at date: Date) -> [PairedDevice] {
        if let index = devices.firstIndex(where: { $0.id == id }) {
            var device = devices.remove(at: index)
            if let name, !name.isEmpty { device.name = Self.cleanName(name) }
            device.lastSeen = date
            devices.insert(device, at: 0)
            return []
        }
        devices.insert(PairedDevice(id: id, name: Self.cleanName(name), added: date, lastSeen: date), at: 0)
        let removed = Array(devices.dropFirst(Self.limit))
        devices = Array(devices.prefix(Self.limit))
        return removed
    }
    @discardableResult
    public mutating func remove(_ id: UUID) -> PairedDevice? {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return nil }
        return devices.remove(at: index)
    }
    public static func load(from defaults: UserDefaults, key: String = "pairedDevices") -> PairedDeviceList {
        guard let data = defaults.data(forKey: key), let list = try? JSONDecoder().decode(PairedDeviceList.self, from: data) else { return PairedDeviceList() }
        return PairedDeviceList(devices: list.devices)
    }
    public func save(to defaults: UserDefaults, key: String = "pairedDevices") {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: key) }
    }
}

/// Mac → iPad: the iPad's own key for this Mac. Sent once, over the already encrypted control connection.
public struct DeviceKeyGrant: Codable, Equatable {
    public let device: UUID
    /// Identifies the Mac, so the iPad uses this key for every address the same Mac is reached at.
    public let host: UUID
    public let key: Data
    public init(device: UUID, host: UUID, key: Data) { self.device = device; self.host = host; self.key = key }
    public var isValid: Bool { key.count == 32 }
}

/// iPad → Mac: "I have no key of my own for you yet."
public struct DeviceKeyRequest: Codable, Equatable {
    public let device: UUID
    public let name: String?
    public init(device: UUID, name: String?) { self.device = device; self.name = name.map { String($0.prefix(64)) } }
}
