import XCTest
import Network
@testable import SkyDeskCore

final class PairedDeviceTests: XCTestCase {
    private let queue = DispatchQueue(label: "skydesk.test.devices")

    /// Connects once to a listener that accepts `accepted`; returns the cipher suite, or nil if the handshake failed.
    private func connect(accepted: [PairingCredential], using client: NWParameters, timeout: TimeInterval = 4) throws -> UInt16? {
        let parameters = DeskNetwork.parameters(credentials: accepted)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = expectation(description: "listener")
        var held: [SecureChannel] = []
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { [queue] connection in
            let peer = SecureChannel(connection: connection, queue: queue)
            held.append(peer)
            peer.onPacket = { [weak peer] packet in peer?.send(packet) }
            peer.start()
        }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        let channel = SecureChannel(connection: NWConnection(host: "127.0.0.1", port: port, using: client), queue: queue)
        let finished = expectation(description: "handshake result")
        var suite: UInt16?
        var settled = false
        channel.onReady = { [weak channel] in channel?.send(.ping(7)) }
        // Proof of a working session, not just a handshake: the echo comes back through the encrypted channel.
        channel.onPacket = { [weak channel] packet in
            guard !settled, case .ping(7)? = try? packet.controlMessage() else { return }
            settled = true; suite = channel?.negotiatedSuite; finished.fulfill()
        }
        channel.onClose = { _ in if !settled { settled = true; finished.fulfill() } }
        channel.start()
        wait(for: [finished], timeout: timeout + 8)
        channel.close(); queue.sync { held.forEach { $0.close() } }; listener.cancel()
        return suite
    }

    func testNewBuildsAgreeOnTheForwardSecretSuite() throws {
        let password = PairingCredential.password(try PairingKey())
        let suite = try connect(accepted: [password], using: DeskNetwork.parameters(credentials: [password]))
        XCTAssertEqual(suite, DeskNetwork.forwardSecretSuite)
    }

    func testAnOlderBuildStillConnectsWithItsOwnSuite() throws {
        let key = try PairingKey()
        // What builds before 37 send: the password identity and only the old suite.
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: DeskNetwork.legacySuite)!)
        let secret = key.data.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data(PairingPassword.pskIdentity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, secret as __DispatchData, identity as __DispatchData)
        let old = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        XCTAssertEqual(try connect(accepted: [.password(key)], using: old), DeskNetwork.legacySuite)
    }

    func testEachPairedIPadConnectsWithItsOwnKeyBesideThePassword() throws {
        let password = PairingCredential.password(try PairingKey())
        let first = PairingCredential.device(UUID(), key: try PairingKey())
        let second = PairingCredential.device(UUID(), key: try PairingKey())
        let accepted = [password, first, second]
        for credential in accepted {
            XCTAssertEqual(try connect(accepted: accepted, using: DeskNetwork.parameters(credentials: [credential])), DeskNetwork.forwardSecretSuite)
        }
    }

    func testARemovedIPadAndAPasswordThatIsSwitchedOffAreRefused() throws {
        let password = PairingCredential.password(try PairingKey())
        let kept = PairingCredential.device(UUID(), key: try PairingKey())
        let removed = PairingCredential.device(UUID(), key: try PairingKey())
        // The listener no longer lists the removed iPad's key, and password pairing is off.
        XCTAssertNil(try connect(accepted: [kept], using: DeskNetwork.parameters(credentials: [removed])))
        XCTAssertNil(try connect(accepted: [kept], using: DeskNetwork.parameters(credentials: [password])))
        XCTAssertNotNil(try connect(accepted: [kept], using: DeskNetwork.parameters(credentials: [kept])))
        // The right identity with the wrong key is refused too.
        let forged = PairingCredential(key: try PairingKey(), identity: kept.identity)
        XCTAssertNil(try connect(accepted: [kept], using: DeskNetwork.parameters(credentials: [forged])))
    }

    func testListKeepsNewestFirstAndDropsTheOldestBeyondItsLimit() {
        var list = PairedDeviceList()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let ids = (0..<PairedDeviceList.limit + 1).map { _ in UUID() }
        var dropped: [PairedDevice] = []
        for (index, id) in ids.enumerated() { dropped += list.record(id, name: "iPad \(index)", at: start.addingTimeInterval(Double(index))) }
        XCTAssertEqual(list.devices.count, PairedDeviceList.limit)
        XCTAssertEqual(dropped.map(\.id), [ids[0]])
        XCTAssertEqual(list.devices.first?.id, ids.last)
        // Seen again: moves to the front, keeps its added date, takes a new name only if one is given.
        XCTAssertTrue(list.record(ids[3], name: nil, at: start.addingTimeInterval(100)).isEmpty)
        XCTAssertEqual(list.devices.first?.id, ids[3]); XCTAssertEqual(list.devices.first?.name, "iPad 3")
        XCTAssertEqual(list.devices.first?.added, start.addingTimeInterval(3))
        XCTAssertEqual(list.remove(ids[3])?.name, "iPad 3")
        XCTAssertFalse(list.contains(ids[3])); XCTAssertNil(list.remove(ids[3]))
        XCTAssertEqual(PairedDeviceList.cleanName("  \u{7}Sky's iPad\n"), "Sky's iPad")
        XCTAssertEqual(PairedDeviceList.cleanName(""), "iPad")
        // Survives storage.
        let defaults = UserDefaults(suiteName: "skydesk.test.\(UUID().uuidString)")!
        list.save(to: defaults)
        XCTAssertEqual(PairedDeviceList.load(from: defaults), list)
    }

    func testKeyMessagesCrossTheWireAndOlderHellosStillDecode() throws {
        let grant = DeviceKeyGrant(device: UUID(), host: UUID(), key: try PairingKey().data)
        XCTAssertTrue(grant.isValid)
        XCTAssertFalse(DeviceKeyGrant(device: UUID(), host: UUID(), key: Data(count: 16)).isValid)
        guard case .deviceKey(let received) = try WirePacket.control(.deviceKey(grant)).controlMessage() else { return XCTFail("wrong message") }
        XCTAssertEqual(received, grant)
        let request = DeviceKeyRequest(device: UUID(), name: String(repeating: "x", count: 200))
        XCTAssertEqual(request.name?.count, 64)
        // A hello from a build before 37 has no device fields.
        let old = #"{"hello":{"_0":{"session":"7C0B3E5E-3D56-4A54-8A52-0C3B6B3B2C11","role":"control","features":127,"appBuild":30}}}"#
        guard case .hello(let hello) = try JSONDecoder().decode(ControlMessage.self, from: Data(old.utf8)) else { return XCTFail("wrong message") }
        XCTAssertNil(hello.device); XCTAssertEqual(hello.appBuild, 30)
    }
}
