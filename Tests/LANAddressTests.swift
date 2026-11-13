#if os(macOS)
import Darwin
import XCTest
@testable import SkyDeskCore

final class LANAddressTests: XCTestCase {
    private let active = UInt32(IFF_UP | IFF_RUNNING)
    private let labels = ["en0": "Wi-Fi", "en7": "USB Ethernet"]

    func testDefaultLANInterfaceFirstWithOtherActiveAddressStillAvailable() {
        let entries = [entry("en0", "10.240.173.132"), entry("en7", "10.62.101.30"),
                       entry("en0", "10.240.173.132")]
        let addresses = LANAddressDiscovery.select(entries, labels: labels, primaryInterface: "en7")
        XCTAssertEqual(addresses.map(\.address), ["10.62.101.30", "10.240.173.132"])
        XCTAssertEqual(addresses.map(\.connectionName), ["USB Ethernet", "Wi-Fi"])
    }

    func testDisconnectAndDHCPChangesRemoveOldAddresses() {
        let wired = LANAddressDiscovery.select([entry("en7", "10.62.101.30")], labels: labels, primaryInterface: "en7")
        XCTAssertEqual(wired.first?.address, "10.62.101.30")
        let wifi = LANAddressDiscovery.select([entry("en7", "10.62.101.30", flags: UInt32(IFF_UP)),
                                               entry("en0", "10.240.173.132")], labels: labels, primaryInterface: "en0")
        XCTAssertEqual(wifi.map(\.address), ["10.240.173.132"])
        let renewed = LANAddressDiscovery.select([entry("en0", "10.240.173.133")], labels: labels, primaryInterface: "en0")
        XCTAssertEqual(renewed.map(\.address), ["10.240.173.133"])
        XCTAssertTrue(LANAddressDiscovery.select([], labels: labels, primaryInterface: nil).isEmpty)
    }

    func testRejectsTunnelsLoopbackInactiveAndUnusableAddresses() {
        let entries = [entry("utun4", "100.64.1.1"), entry("awdl0", "10.1.1.1"),
                       entry("lo0", "127.0.0.1"), entry("en0", "10.1.1.1", flags: 0),
                       entry("en0", "10.1.1.1", flags: active | UInt32(IFF_POINTOPOINT)),
                       entry("en0", "10.1.1.1", flags: active | UInt32(IFF_LOOPBACK))]
            + ["127.0.0.1", "0.0.0.0", "169.254.1.2", "224.1.1.1", "255.255.255.255", "bad", "::1"]
                .map { entry("en0", $0) }
        XCTAssertTrue(LANAddressDiscovery.select(entries, labels: labels, primaryInterface: "utun4").isEmpty)
    }

    func testVPNDefaultDoesNotHidePhysicalLANAddressOrRequireInternet() {
        let entries = [entry("utun4", "100.64.1.1"), entry("en0", "10.240.173.132")]
        XCTAssertEqual(LANAddressDiscovery.select(entries, labels: labels, primaryInterface: "utun4").map(\.address),
                       ["10.240.173.132"])
        XCTAssertEqual(LANAddressDiscovery.select(entries, labels: labels, primaryInterface: nil).map(\.address),
                       ["10.240.173.132"])
    }

    private func entry(_ name: String, _ address: String, flags: UInt32? = nil) -> LANAddressDiscovery.InterfaceAddress {
        .init(name: name, address: address, flags: flags ?? active)
    }
}
#endif
