import XCTest
import Network
@testable import SkyDeskCore

final class PairingPasswordTests: XCTestCase {
    /// Pinned against Python's hashlib.pbkdf2_hmac, so a change to salt, iterations or normalisation is caught.
    func testDerivationMatchesIndependentPBKDF2() throws {
        XCTAssertEqual(try PairingPassword.deriveKey("k7mq-3xvp").text,
                       "02bccac6d367fd5e2ca4719f1049cc24b155dda2b6473a5c2fac045e382a885a")
        XCTAssertEqual(try PairingPassword.deriveKey("k7mq3xvp", iterations: 1_000).text,
                       "7b3381652222bbcb24f3f6241a0101845e90143dfd0327fc2f945925c7b1f781")
    }
    func testDerivationIsDeliberatelySlow() throws {
        let start = Date()
        _ = try PairingPassword.deriveKey("k7mq3xvp")
        // ~0.14 s on an M4 Max; far slower than a raw hash, far faster than a connect timeout.
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.03)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
    func testNormalisationIgnoresDashesAndSpacesButNotCase() throws {
        XCTAssertEqual(try PairingPassword.deriveKey(" k7mq 3xvp\n", iterations: 1_000),
                       try PairingPassword.deriveKey("k7mq-3xvp", iterations: 1_000))
        XCTAssertNotEqual(try PairingPassword.deriveKey("K7MQ3XVP", iterations: 1_000),
                          try PairingPassword.deriveKey("k7mq3xvp", iterations: 1_000))
    }
    func testShortPasswordsAreRejected() {
        XCTAssertThrowsError(try PairingPassword.validate("12-34"))
        XCTAssertThrowsError(try PairingPassword.deriveKey("     "))
        XCTAssertNoThrow(try PairingPassword.validate("123456"))
    }
    func testGeneratedPasswordsAreReadableAndVaried() throws {
        var seen = Set<String>()
        for _ in 0..<200 {
            let password = try PairingPassword.generate()
            XCTAssertEqual(password.count, 9)
            XCTAssertEqual(Array(password)[4], "-")
            XCTAssertTrue(password.replacingOccurrences(of: "-", with: "").allSatisfy { PairingPassword.alphabet.contains($0) })
            seen.insert(password)
        }
        XCTAssertEqual(seen.count, 200)
    }
    func testRightPasswordConnectsAndWrongPasswordFailsFastWithClearMessage() throws {
        let serverKey = try PairingPassword.deriveKey("sky-desk-42", iterations: 1_000)
        let wrongKey = try PairingPassword.deriveKey("sky-desk-43", iterations: 1_000)
        let queue = DispatchQueue(label: "skydesk.test.password")
        let parameters = DeskNetwork.parameters(key: serverKey)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = expectation(description: "Listener ready")
        var servers: [SecureChannel] = []
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            let peer = SecureChannel(connection: connection, queue: queue)
            servers.append(peer); peer.start()
        }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 5)
        guard let port = listener.port else { listener.cancel(); return XCTFail("Listener did not bind") }

        let good = expectation(description: "Right password reaches ready")
        let right = SecureChannel(connection: NWConnection(host: "127.0.0.1", port: port, using: DeskNetwork.parameters(key: serverKey)), queue: queue)
        right.onReady = { good.fulfill() }
        right.start()
        wait(for: [good], timeout: 5)

        let rejected = expectation(description: "Wrong password rejected")
        let started = Date()
        var reason: String?
        let wrong = SecureChannel(connection: NWConnection(host: "127.0.0.1", port: port, using: DeskNetwork.parameters(key: wrongKey)), queue: queue)
        wrong.onReady = { XCTFail("Wrong password authenticated") }
        wrong.onClose = { reason = $0; rejected.fulfill() }
        wrong.start()
        wait(for: [rejected], timeout: 12)
        XCTAssertEqual(reason, PairingPassword.mismatchMessage)
        // Not the ten-second timeout: the TLS failure ends the attempt at once.
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        right.close(); wrong.close(); queue.sync { servers.forEach { $0.close() } }; listener.cancel()
    }
}
