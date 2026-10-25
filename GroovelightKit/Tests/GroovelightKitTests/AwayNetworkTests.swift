import CryptoKit
import Foundation
import Testing
@testable import WirelessSync

struct AwayNetworkTests {
    /// A Mac on 192.168.1.0/24 and on an IPv6 network, as its Wi-Fi gives them.
    static let local = [
        AwayNetwork.Network(address: [192, 168, 1, 20], mask: [255, 255, 255, 0]),
        AwayNetwork.Network(address: [0x2A, 0x02, 0, 1, 0, 2, 0, 3] + [UInt8](repeating: 7, count: 8), mask: [UInt8](repeating: 0xFF, count: 8) + [UInt8](repeating: 0, count: 8)),
    ]

    @Test func homeAndAwayAddresses() {
        // Home: the Mac's networks, loopback, link-local, an IPv4 address seen through IPv6.
        #expect(!AwayNetwork.isAway([192, 168, 1, 77], local: Self.local))
        #expect(!AwayNetwork.isAway([127, 0, 0, 1], local: Self.local))
        #expect(!AwayNetwork.isAway([169, 254, 3, 4], local: Self.local))
        #expect(!AwayNetwork.isAway([0xFE, 0x80] + [UInt8](repeating: 1, count: 14), local: Self.local))
        #expect(!AwayNetwork.isAway([UInt8](repeating: 0, count: 10) + [0xFF, 0xFF, 192, 168, 1, 9], local: Self.local))
        #expect(!AwayNetwork.isAway([0x2A, 0x02, 0, 1, 0, 2, 0, 3] + [UInt8](repeating: 9, count: 8), local: Self.local))
        // Away: Tailscale, another private network, the internet, another IPv6 network.
        #expect(AwayNetwork.isAway([100, 68, 94, 116], local: Self.local))
        #expect(AwayNetwork.isAway([192, 168, 2, 5], local: Self.local))
        #expect(AwayNetwork.isAway([8, 8, 8, 8], local: Self.local))
        #expect(AwayNetwork.isAway([0x2A, 0x02, 0, 1, 0, 2, 0, 4] + [UInt8](repeating: 9, count: 8), local: Self.local))
        #expect(AwayNetwork.isAway([0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0] + [UInt8](repeating: 1, count: 10), local: Self.local))
    }

    @Test func tailscaleHosts() {
        #expect(AwayNetwork.isTailscale(host: "100.109.215.46"))
        #expect(AwayNetwork.isTailscale(host: "100.127.255.1"))
        #expect(!AwayNetwork.isTailscale(host: "100.128.0.1"))
        #expect(!AwayNetwork.isTailscale(host: "192.168.1.20"))
        #expect(AwayNetwork.isTailscale(host: "fd7a:115c:a1e0::1"))
        #expect(!AwayNetwork.isTailscale(host: "fe80::1%en0"))
    }

    /// Away from home: no pairing, and only the devices the Mac allows.
    @Test func awayRequests() async throws {
        let key = SymmetricKey(size: .bits256)
        final class Allowed: @unchecked Sendable { var ids: Set<String> = [] }
        let allowed = Allowed()
        let server = WirelessSyncServer(backend: WirelessSyncServer.Backend(
            info: { WirelessProtocol.Info(id: "mac-1", name: "Test Mac") },
            pairRequested: { _, _ in },
            pairStatus: { _ in "pending" },
            key: { $0 == "phone-1" ? key : nil },
            plan: { _, _ in throw CocoaError(.featureUnsupported) },
            cover: { _, _ in nil },
            finished: { _, _ in },
            status: { _ in WirelessProtocol.Status(syncRequested: false, pendingSends: 0) },
            mayConnectAway: { allowed.ids.contains($0) }))

        func request(_ method: String, _ path: String, away: Bool, signed: Bool = false) -> LocalHTTPServer.Request {
            var headers: [String: String] = [:]
            if signed {
                let time = Int(Date.now.timeIntervalSince1970), nonce = UUID().uuidString
                headers = [WirelessProtocol.Header.device: "phone-1", WirelessProtocol.Header.time: "\(time)", WirelessProtocol.Header.nonce: nonce,
                           WirelessProtocol.Header.signature: WirelessProtocol.signature(method: method, path: path, time: time, nonce: nonce,
                                                                                          body: Data(), key: key)]
            }
            var request = LocalHTTPServer.Request(method: method, path: path, query: [:], headers: headers, body: Data(), remote: "test")
            request.isAway = away
            return request
        }

        #expect(await server.handle(request("GET", "/info", away: true)).status == 200)
        #expect(await server.handle(request("POST", "/pair", away: true)).status == 403)
        #expect(await server.handle(request("GET", "/pair/phone-1", away: true)).status == 403)
        #expect(await server.handle(request("GET", "/pair/phone-1", away: false)).status == 200)
        #expect(await server.handle(request("GET", "/status", away: false, signed: true)).status == 200)
        #expect(await server.handle(request("GET", "/status", away: true, signed: true)).status == 403)
        allowed.ids = ["phone-1"]
        #expect(await server.handle(request("GET", "/status", away: true, signed: true)).status == 200)
    }
}
