import XCTest
import Network
@testable import SkyDeskCore

final class TransportTests: XCTestCase {
    func testEncryptedLoopbackAndLargeFrame() throws {
        let key = try PairingKey()
        let queue = DispatchQueue(label: "skydesk.test.positive")
        let parameters = DeskNetwork.parameters(key: key)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = expectation(description: "Listener ready")
        let received = expectation(description: "Large encrypted payload round trip")
        let payload = Data(repeating: 0x5a, count: 300_000)
        var server: SecureChannel?
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            let peer = SecureChannel(connection: connection, queue: queue)
            server = peer
            peer.onPacket = { [weak peer] packet in peer?.send(packet) }
            peer.start()
        }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 5)
        guard let port = listener.port else { listener.cancel(); return XCTFail("Listener did not bind") }
        let client = SecureChannel(connection: NWConnection(host: "127.0.0.1", port: port, using: DeskNetwork.parameters(key: key)), queue: queue)
        client.onReady = { [weak client] in client?.send(WirePacket(kind: .video, payload: payload)) }
        client.onPacket = { packet in
            XCTAssertEqual(packet.kind, .video); XCTAssertEqual(packet.payload, payload); received.fulfill()
        }
        client.start()
        wait(for: [received], timeout: 8)
        client.close(); queue.sync { server?.close() }; listener.cancel()
    }
    func testWrongPairingKeyCannotReachReady() throws {
        let serverKey = try PairingKey(), clientKey = try PairingKey()
        let queue = DispatchQueue(label: "skydesk.test.rejection")
        let parameters = DeskNetwork.parameters(key: serverKey)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = expectation(description: "Listener ready")
        let rejected = expectation(description: "Wrong key rejected")
        var server: SecureChannel?
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            let peer = SecureChannel(connection: connection, queue: queue)
            server = peer
            peer.onReady = { XCTFail("Server accepted a wrong key") }
            peer.start()
        }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 5)
        guard let port = listener.port else { listener.cancel(); return XCTFail("Listener did not bind") }
        let client = SecureChannel(connection: NWConnection(host: "127.0.0.1", port: port, using: DeskNetwork.parameters(key: clientKey)), queue: queue)
        client.onReady = { XCTFail("Client authenticated with a wrong key") }
        client.onClose = { _ in rejected.fulfill() }
        client.start()
        // Network.framework may leave a rejected PSK handshake waiting; the channel's
        // explicit ten-second deadline must close it without ever becoming ready.
        wait(for: [rejected], timeout: 12)
        client.close(); queue.sync { server?.close() }; listener.cancel()
    }
}
