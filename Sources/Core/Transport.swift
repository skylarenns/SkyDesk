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
    public init(data: Data) { precondition(data.count == 32, "Pairing keys are 32 bytes."); self.data = data }
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
        guard let text = try loadText(account: account, allowInteraction: allowInteraction) else { return nil }
        return try PairingKey(text: text)
    }
    public static func save(_ key: PairingKey, account: String, allowInteraction: Bool = false) throws {
        try saveText(key.text, account: account, allowInteraction: allowInteraction)
    }
    /// The same Keychain service as the keys; used for the Mac's pairing password.
    public static func loadText(account: String, allowInteraction: Bool = false) throws -> String? {
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
            throw DeskError.system("Read pairing secret", status)
        }
        return text
        }
    }
    public static func saveText(_ text: String, account: String, allowInteraction: Bool = false) throws {
        try withKeychainAccess(allowInteraction: allowInteraction) {
        var query = base(account)
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        query[kSecUseAuthenticationContext as String] = context
        let attributes: [String: Any] = [kSecValueData as String: Data(text.utf8),
                                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DeskError.system("Save pairing secret", status) }
        }
    }
    /// Removes one item. Missing items are not an error.
    public static func delete(account: String) {
        withKeychainAccess(allowInteraction: false) { _ = SecItemDelete(base(account) as CFDictionary) }
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
    /// TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256: the same pre-shared key proves who is connecting, and a fresh
    /// Diffie-Hellman exchange per connection supplies the session keys, so a key that leaks later cannot decrypt
    /// sessions recorded earlier (forward secrecy; build 37). Not in the SDK's named list; Apple's TLS accepts it
    /// (Tests/PairedDeviceTests.swift connects with it).
    public static let forwardSecretSuite: UInt16 = 0xCCAC
    /// The suite of builds before 37, kept so either side can still talk to an older build.
    public static let legacySuite = UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256)
    public static func parameters(key: PairingKey) -> NWParameters { parameters(credentials: [.password(key)]) }
    /// A listener passes every credential it accepts; a connection passes the one it wants to use.
    public static func parameters(credentials: [PairingCredential]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        // Preference order: both sides on build 37+ agree on the forward-secret suite.
        for suite in [forwardSecretSuite, legacySuite] {
            if let value = tls_ciphersuite_t(rawValue: suite) { sec_protocol_options_append_tls_ciphersuite(options, value) }
        }
        for credential in credentials {
            let secret = credential.key.data.withUnsafeBytes { DispatchData(bytes: $0) }
            let identity = Data(credential.identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(options, secret as __DispatchData, identity as __DispatchData)
        }
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
    public static func wiredParameters(credential: PairingCredential) -> NWParameters {
        let parameters = parameters(credentials: [credential])
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
    /// The TLS cipher suite in use once the channel is ready (for the log and tests).
    public var negotiatedSuite: UInt16? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
        return sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata).rawValue
    }
    private var parser = WireParser()
    private var closed = false
    private var ready = false
    private var pendingBytes = 0 { didSet { backlogLock.lock(); backlog = pendingBytes; backlogLock.unlock() } }
    private var pendingMessages = 0
    private let backlogLock = NSLock()
    private var backlog = 0
    /// Bytes handed to the connection that it has not taken yet; readable from any thread.
    public var backlogBytes: Int { backlogLock.lock(); defer { backlogLock.unlock() }; return backlog }
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
            case .failed(let error):
                if case .tls = error { self.finish(PairingPassword.mismatchMessage) } else { self.finish(error.localizedDescription) }
            case .waiting(let error):
                // A TLS failure never recovers by waiting: the password (pre-shared key) did not match.
                if case .tls = error { self.finish(PairingPassword.mismatchMessage) }
                else if self.failWhenWaiting { self.finish(error.localizedDescription) }
            case .cancelled: self.finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.ready else { return }
            self.finish("Connection timed out. Check that the Mac is awake and on the same network.")
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
