import Foundation
import Network
import Security
import LocalAuthentication

public struct PairingKey: Equatable, Sendable {
    public let data: Data
    public var text: String { data.map { String(format: "%02x", $0) }.joined() }
    public init() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw DeskError.system("Generate pairing key", status) }
        data = Data(bytes)
    }
    public init(text: String) throws {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.utf8.count == 64 else { throw DeskError.invalid("Pairing key must contain 64 hexadecimal characters.") }
        let chars = Array(clean.utf8)
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(bytes: chars[index...index + 1], encoding: .utf8) ?? "", radix: 16) else {
                throw DeskError.invalid("Pairing key contains invalid characters.")
            }
            bytes.append(byte)
        }
        data = Data(bytes)
    }
}

public enum PairingStore {
    private static let service = "com.skylar.skydesk.pairing"
    private static let accessLock = NSLock()
    public static func load(account: String, allowInteraction: Bool = false) throws -> PairingKey? {
        try withKeychainAccess(allowInteraction: allowInteraction) {
        var query = base(account)
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        query[kSecUseAuthenticationContext as String] = context
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
            throw DeskError.system("Read pairing key", status)
        }
        return try PairingKey(text: text)
        }
    }
    public static func save(_ key: PairingKey, account: String, allowInteraction: Bool = false) throws {
        try withKeychainAccess(allowInteraction: allowInteraction) {
        var query = base(account)
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        query[kSecUseAuthenticationContext as String] = context
        let attributes: [String: Any] = [kSecValueData as String: Data(key.text.utf8),
                                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DeskError.system("Save pairing key", status) }
        }
    }
    private static func withKeychainAccess<T>(allowInteraction: Bool, _ operation: () throws -> T) rethrows -> T {
        accessLock.lock()
        defer { accessLock.unlock() }
        #if os(macOS)
        // File-based macOS Keychain ACLs can ignore LAContext.interactionNotAllowed.
        // These legacy APIs are intentional until the host migrates to a signed,
        // entitlement-backed data-protection Keychain. This setting is process-local.
        var previous: DarwinBoolean = true
        let status = SecKeychainGetUserInteractionAllowed(&previous)
        if status == errSecSuccess { SecKeychainSetUserInteractionAllowed(allowInteraction) }
        defer { if status == errSecSuccess { SecKeychainSetUserInteractionAllowed(previous.boolValue) } }
        #endif
        return try operation()
    }
    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

public enum DeskNetwork {
    public static let serviceType = "_skydesk._tcp"
    public static let port: UInt16 = 48772
    public static func parameters(key: PairingKey) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let secret = key.data.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("SkyDesk-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, secret as __DispatchData, identity as __DispatchData)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.connectionTimeout = 10
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        return parameters
    }
    /// Same security, restricted to a cable link (USB or Ethernet): never Wi-Fi or cellular.
    public static func wiredParameters(key: PairingKey) -> NWParameters {
        let parameters = parameters(key: key)
        parameters.prohibitedInterfaceTypes = [.wifi, .cellular, .loopback]
        return parameters
    }
}

/// All callbacks execute on `queue`. The send budget also bounds control input during congestion.
public final class SecureChannel {
    public let id = UUID()
    public let connection: NWConnection
    public let queue: DispatchQueue
    public var onReady: (() -> Void)?
    public var onPacket: ((WirePacket) -> Void)?
    public var onClose: ((String?) -> Void)?
    private var parser = WireParser()
    private var closed = false
    private var ready = false
    private var pendingBytes = 0
    private var pendingMessages = 0
    private let maxPendingBytes: Int
    private let failWhenWaiting: Bool
    /// `failWhenWaiting` ends an attempt as soon as no usable route exists, so a caller can fall back to another link.
    public init(connection: NWConnection, queue: DispatchQueue = DispatchQueue(label: "skydesk.transport", qos: .userInteractive),
                maxPendingBytes: Int = 18 * 1_024 * 1_024, failWhenWaiting: Bool = false) {
        self.connection = connection; self.queue = queue; self.maxPendingBytes = maxPendingBytes
        self.failWhenWaiting = failWhenWaiting
    }
    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready: self.ready = true; self.receive(); self.onReady?()
            case .failed(let error): self.finish(error.localizedDescription)
            case .waiting(let error): if self.failWhenWaiting { self.finish(error.localizedDescription) }
            case .cancelled: self.finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.ready else { return }
            self.finish("Connection timed out. Check the pairing key and local network access.")
        }
    }
    public func send(_ message: ControlMessage) {
        do { send(try WirePacket.control(message)) } catch { close(reason: error.localizedDescription) }
    }
    public func send(_ packet: WirePacket, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self, !self.closed, self.ready else { completion?(false); return }
            do {
                let bytes = try packet.encoded()
                guard self.pendingBytes + bytes.count <= self.maxPendingBytes, self.pendingMessages < 256 else {
                    self.finish("Connection stalled; reconnect to resume."); completion?(false); return
                }
                self.pendingBytes += bytes.count; self.pendingMessages += 1
                self.connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    self.pendingBytes -= bytes.count; self.pendingMessages -= 1
                    if let error { self.finish(error.localizedDescription) }
                    completion?(error == nil)
                })
            } catch { self.finish(error.localizedDescription); completion?(false) }
        }
    }
    public func close(reason: String? = nil) { queue.async { [weak self] in self?.finish(reason) } }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            do {
                if let data { for packet in try self.parser.append(data) { self.onPacket?(packet) } }
            } catch { self.finish(error.localizedDescription); return }
            if let error { self.finish(error.localizedDescription) }
            else if complete { self.finish(nil) }
            else { self.receive() }
        }
    }
    private func finish(_ reason: String?) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?(reason)
        onReady = nil; onPacket = nil; onClose = nil
    }
    deinit { connection.cancel() }
}
