import Foundation
import Network
import Synchronization

/// Reaching the Mac away from home: through a private network the Mac and the devices share (Tailscale), never the open
/// internet. A request is from home when it comes from the network of one of the Mac's own connections (Wi-Fi, Ethernet);
/// anything else (Tailscale, a VPN, a public address) is away: devices pair only at home, and reach the Mac away only
/// when allowed on its device page.
public enum AwayNetwork {
    /// Whether a connection's other end is outside the Mac's local networks.
    public static func isAway(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return true }
        let bytes: [UInt8]
        switch host {
        case .ipv4(let address): bytes = Array(address.rawValue)
        case .ipv6(let address): bytes = Array(address.rawValue)
        default: return true
        }
        return isAway(bytes, local: localNetworks())
    }

    /// A network of one of the Mac's connections: its address and netmask.
    struct Network: Equatable {
        var address: [UInt8]
        var mask: [UInt8]

        func contains(_ bytes: [UInt8]) -> Bool {
            bytes.count == address.count && zip(zip(bytes, address), mask).allSatisfy { pair, mask in pair.0 & mask == pair.1 & mask }
        }
    }

    static func isAway(_ bytes: [UInt8], local: [Network]) -> Bool {
        let bytes = unmapped(bytes)
        if bytes == [127, 0, 0, 1] || bytes == [UInt8](repeating: 0, count: 15) + [1] { return false }
        // Link-local addresses never cross a router (and the Mac's own carry its interface in them).
        if bytes.count == 4 && bytes[0] == 169 && bytes[1] == 254 || bytes.count == 16 && bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return false }
        return !local.contains { $0.contains(bytes) }
    }

    /// An IPv4 address seen through IPv6 (`::ffff:a.b.c.d`) as IPv4.
    static func unmapped(_ bytes: [UInt8]) -> [UInt8] {
        bytes.count == 16 && bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF ? Array(bytes.suffix(4)) : bytes
    }

    /// Whether an address is Tailscale's (100.64.0.0/10, or fd7a:115c:a1e0::/48).
    static func isTailscale(_ bytes: [UInt8]) -> Bool {
        switch bytes.count {
        case 4: bytes[0] == 100 && bytes[1] & 0xC0 == 64
        case 16: bytes.prefix(6) == [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0]
        default: false
        }
    }

    /// Whether a host (an address as text) is a Tailscale address: the device reached the Mac away from home.
    public static func isTailscale(host: String) -> Bool {
        let host = host.split(separator: "%").first.map(String.init) ?? host
        if let address = IPv4Address(host) { return isTailscale(Array(address.rawValue)) }
        if let address = IPv6Address(host) { return isTailscale(Array(address.rawValue)) }
        return false
    }

    /// The Mac's local networks (connections that are up, other than point-to-point ones such as Tailscale and VPNs),
    /// read again every 10 seconds.
    static func localNetworks() -> [Network] {
        cache.withLock { cache in
            if let cached = cache, Date.now.timeIntervalSince(cached.at) < 10 { return cached.networks }
            let networks = interfaces().filter { !$0.pointToPoint && !isTailscale($0.address) }.map { Network(address: $0.address, mask: $0.mask) }
            cache = (networks, .now)
            return networks
        }
    }

    private static let cache = Mutex<(networks: [Network], at: Date)?>(nil)

    /// This Mac's Tailscale addresses (IPv4 first): what paired devices try when it is not on their network.
    public static func addresses() -> [String] {
        interfaces().filter { isTailscale($0.address) }
            .sorted { $0.address.count < $1.address.count }
            .compactMap { interface in
                interface.address.count == 4 ? IPv4Address(Data(interface.address)).map { "\($0)" }
                    : IPv6Address(Data(interface.address)).map { "\($0)" }
            }
    }

    private struct Interface {
        var address: [UInt8]
        var mask: [UInt8]
        var pointToPoint: Bool
    }

    private static func interfaces() -> [Interface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [Interface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, let address = entry.ifa_addr, let mask = entry.ifa_netmask else { continue }
            guard let bytes = Self.bytes(address), let maskBytes = Self.bytes(mask), bytes.count == maskBytes.count else { continue }
            result.append(Interface(address: bytes, mask: maskBytes, pointToPoint: flags & IFF_POINTOPOINT != 0))
        }
        return result
    }

    private static func bytes(_ address: UnsafeMutablePointer<sockaddr>) -> [UInt8]? {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inet in
                withUnsafeBytes(of: inet.pointee.sin_addr) { Array($0) }
            }
        case AF_INET6:
            return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { inet in
                withUnsafeBytes(of: inet.pointee.sin6_addr) { Array($0) }
            }
        default:
            return nil
        }
    }
}
