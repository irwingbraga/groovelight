import CryptoKit
import Foundation
import WirelessSync

/// The Mac this device is paired with, as the app remembers it (the key is kept apart, in the keychain).
public struct PairedMac: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Its last address, tried first (it may have changed: then it is found again on the network).
    public var host: String
    public var port: Int
    /// The pinned fingerprint (SHA-256, hex) of the Mac's certificate: once set, the Mac is only reached over HTTPS.
    public var certificate: String?
    /// Its Tailscale addresses, as it last gave them: tried when it is not on this network (away from home).
    public var awayHosts: [String]?
    /// Its HTTPS port, as it last gave it: away from home only HTTPS is used (iOS allows plain HTTP on the local network only).
    public var tlsPort: Int?

    public init(id: String, name: String, host: String, port: Int, certificate: String? = nil, awayHosts: [String]? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.certificate = certificate
        self.awayHosts = awayHosts
    }

    /// The Mac at its last address, found again on the network, or away from home at its Tailscale address, over HTTPS: its certificate is pinned the first time,
    /// with the Mac's proof that it holds the pairing key, and from then on nothing else is accepted. Returns the client
    /// and the Mac as it is now (address, pinned certificate), to remember.
    public func connect(deviceId: String, key: SymmetricKey) async throws -> (MacClient, PairedMac) {
        var mac = self
        let (info, host) = try await mac.locate(deviceId: deviceId, key: key)
        guard let tlsPort = info.tlsPort else {
            throw MacError("\(name) did not offer its secure connection. Update Groovelight on the Mac, or forget it here and pair again.")
        }
        if let pinned = certificate {
            let client = MacClient(host: host, port: mac.port, deviceId: deviceId, key: key, tls: .init(port: tlsPort, fingerprint: pinned))
            do {
                _ = try await client.info()
                return (client, mac)
            } catch let error as MacError where error.status == 0 {
                // Another certificate (the Mac made a new one): pinned again below, only with the Mac's proof.
            }
        }
        let fingerprint = try await MacClient(host: host, port: mac.port, deviceId: deviceId, key: key).pinnedCertificate()
        mac.certificate = fingerprint
        return (MacClient(host: host, port: mac.port, deviceId: deviceId, key: key, tls: .init(port: tlsPort, fingerprint: fingerprint)), mac)
    }

    /// Where the Mac is now (the host answering) and its `/info`: its last address on this network, the Mac found again
    /// on it, or its Tailscale addresses. `host` stays its address at home, tried first next time.
    private mutating func locate(deviceId: String, key: SymmetricKey) async throws -> (WirelessProtocol.Info, String) {
        func probe(_ host: String, timeout: TimeInterval) async -> WirelessProtocol.Info? {
            guard let info = try? await MacClient(host: host, port: port, deviceId: deviceId, key: key).info(timeout: timeout), info.id == id else { return nil }
            return info
        }
        func found(_ info: WirelessProtocol.Info, at host: String) -> (WirelessProtocol.Info, String) {
            if let away = info.awayAddresses { awayHosts = away }
            if let port = info.tlsPort { tlsPort = port }
            return (info, host)
        }
        if let info = await probe(host, timeout: 4) { return found(info, at: host) }
        if let mac = await MacBrowser.find(id: id, timeout: .seconds(5)), let info = await probe(mac.host, timeout: 8) {
            host = mac.host
            port = mac.port
            return found(info, at: mac.host)
        }
        // Away: straight to the pinned HTTPS port.
        if let certificate, let tlsPort {
            for away in awayHosts ?? [] {
                let client = MacClient(host: away, port: port, deviceId: deviceId, key: key, tls: .init(port: tlsPort, fingerprint: certificate))
                if let info = try? await client.info(timeout: 8), info.id == id { return found(info, at: away) }
            }
        }
        throw MacError("\(name) is not reachable. Is Groovelight open on the Mac, and this device on the same Wi-Fi (or, away from home, on Tailscale with the Mac allowing it)?")
    }
}
