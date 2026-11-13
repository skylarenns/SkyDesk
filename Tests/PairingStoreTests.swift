import XCTest
import Security
@testable import SkyDeskCore

final class PairingStoreTests: XCTestCase {
    func testNoninteractiveKeychainRoundTripAndReplacement() throws {
        var previous: DarwinBoolean = true
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&previous), errSecSuccess)
        let account = "test-" + UUID().uuidString
        defer {
            // Only the temporary item created by this test is removed.
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.skylar.skydesk.pairing", kSecAttrAccount as String: account]
            SecItemDelete(query as CFDictionary)
        }
        XCTAssertNil(try PairingStore.load(account: account))
        let first = try PairingKey()
        try PairingStore.save(first, account: account)
        XCTAssertEqual(try PairingStore.load(account: account), first)
        let replacement = try PairingKey()
        try PairingStore.save(replacement, account: account)
        XCTAssertEqual(try PairingStore.load(account: account), replacement)
        var restored: DarwinBoolean = false
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&restored), errSecSuccess)
        XCTAssertEqual(previous.boolValue, restored.boolValue)
    }
}
