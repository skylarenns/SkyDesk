#if os(macOS)
import Darwin
import Foundation
import SystemConfiguration

struct LANAddress: Equatable, Hashable, Identifiable {
    let interfaceName: String
    let connectionName: String
    let address: String
    var id: String { "\(interfaceName)/\(address)" }
}

enum LANAddressDiscovery {
    struct InterfaceAddress {
        let name: String
        let address: String
        let flags: UInt32
    }

    static func current() -> [LANAddress] {
        var labels: [String: String] = [:]
        for interface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            let type = SCNetworkInterfaceGetInterfaceType(interface)
            if type == kSCNetworkInterfaceTypeIEEE80211 {
                labels[name] = "Wi-Fi"
            } else if type == kSCNetworkInterfaceTypeEthernet {
                labels[name] = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? "Ethernet"
            }
        }
        let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        let primary = global?[kSCDynamicStorePropNetPrimaryInterface as String] as? String
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var interfaces: [InterfaceAddress] = []
        var cursor = list
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let item = current.pointee
            guard let address = item.ifa_addr, Int32(address.pointee.sa_family) == AF_INET else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            interfaces.append(InterfaceAddress(name: String(cString: item.ifa_name),
                                               address: String(cString: host), flags: item.ifa_flags))
        }
        return select(interfaces, labels: labels, primaryInterface: primary)
    }

    // Build a fresh snapshot so a disconnected adapter or DHCP change never leaves a cached IP behind.
    static func select(_ interfaces: [InterfaceAddress], labels: [String: String],
                       primaryInterface: String?) -> [LANAddress] {
        let required = UInt32(IFF_UP | IFF_RUNNING)
        let excluded = UInt32(IFF_LOOPBACK | IFF_POINTOPOINT)
        let candidates = interfaces.compactMap { item -> LANAddress? in
            guard item.flags & required == required, item.flags & excluded == 0,
                  let label = labels[item.name], isUsableIPv4(item.address) else { return nil }
            return LANAddress(interfaceName: item.name, connectionName: label, address: item.address)
        }
        return Set(candidates).sorted { lhs, rhs in
            let leftPrimary = lhs.interfaceName == primaryInterface
            let rightPrimary = rhs.interfaceName == primaryInterface
            if leftPrimary != rightPrimary { return leftPrimary }
            if lhs.interfaceName != rhs.interfaceName { return lhs.interfaceName < rhs.interfaceName }
            return lhs.address < rhs.address
        }
    }

    private static func isUsableIPv4(_ address: String) -> Bool {
        var parsed = in_addr()
        guard inet_pton(AF_INET, address, &parsed) == 1 else { return false }
        let number = UInt32(bigEndian: parsed.s_addr)
        let first = number >> 24
        return first > 0 && first != 127 && first < 224 && number >> 16 != 0xa9fe
    }
}
#endif
