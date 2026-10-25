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

    public init(id: String, name: String, host: String, port: Int, certificate: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.certificate = certificate
    }

    /// The Mac at its last address, or found again on the network, over HTTPS: its certificate is pinned the first time,
    /// with the Mac's proof that it holds the pairing key, and from then on nothing else is accepted. Returns the client
    /// and the Mac as it is now (address, pinned certificate), to remember.
    public func connect(deviceId: String, key: SymmetricKey) async throws -> (MacClient, PairedMac) {
        var mac = self
        let info = try await mac.locate(deviceId: deviceId, key: key)
        guard let tlsPort = info.tlsPort else {
            throw MacError("\(name) did not offer its secure connection. Update Groovelight on the Mac, or forget it here and pair again.")
        }
        if let pinned = certificate {
            let client = MacClient(host: mac.host, port: mac.port, deviceId: deviceId, key: key, tls: .init(port: tlsPort, fingerprint: pinned))
            do {
                _ = try await client.info()
                return (client, mac)
            } catch let error as MacError where error.status == 0 {
                // Another certificate (the Mac made a new one): pinned again below, only with the Mac's proof.
            }
        }
        let fingerprint = try await MacClient(host: mac.host, port: mac.port, deviceId: deviceId, key: key).pinnedCertificate()
        mac.certificate = fingerprint
        return (MacClient(host: mac.host, port: mac.port, deviceId: deviceId, key: key, tls: .init(port: tlsPort, fingerprint: fingerprint)), mac)
    }

    /// Where the Mac is now, and its `/info`.
    private mutating func locate(deviceId: String, key: SymmetricKey) async throws -> WirelessProtocol.Info {
        if let info = try? await MacClient(host: host, port: port, deviceId: deviceId, key: key).info(), info.id == id { return info }
        guard let found = await MacBrowser.find(id: id) else {
            throw MacError("\(name) is not reachable. Is Groovelight open, with wireless sync on, on the same Wi-Fi?")
        }
        host = found.host
        port = found.port
        return try await MacClient(host: host, port: port, deviceId: deviceId, key: key).info()
    }
}
