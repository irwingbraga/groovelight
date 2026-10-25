import CryptoKit
import Foundation
import WirelessSync

/// The device's side of pairing: a fresh X25519 key pair, the request to the Mac, and the signing key and code derived
/// once the Mac answers with its public key (the same derivation as the Mac's `WirelessProtocol.Pairing`).
public struct DevicePairing: Sendable {
    public struct Result: Sendable {
        public var macId: String
        public var macName: String
        public var key: SymmetricKey
        /// Shown on both screens: the user checks they match before allowing the device on the Mac.
        public var code: String
    }

    private let privateKey = Curve25519.KeyAgreement.PrivateKey()

    public init() {}

    public var publicKey: Data { privateKey.publicKey.rawRepresentation }

    /// Asks the Mac to pair; the answer gives the key and the code. Then `waitForApproval` until the user allows it there.
    public func start(with client: MacClient, name: String, model: String) async throws -> Result {
        let answer = try await client.pair(name: name, model: model, publicKey: publicKey)
        guard let macPublic = Data(base64Encoded: answer.publicKey) else { throw MacError("The Mac's answer could not be read") }
        let mac = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: macPublic)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: mac)
        let (key, code) = WirelessProtocol.derive(secret: secret.withUnsafeBytes { Data($0) }, macPublicKey: macPublic,
                                                  devicePublicKey: publicKey)
        return Result(macId: answer.macId, macName: answer.macName, key: key, code: code)
    }

    /// Polls the Mac until the pairing is accepted (true) or rejected (false).
    public static func waitForApproval(_ client: MacClient, every interval: Duration = .seconds(1)) async throws -> Bool {
        while true {
            try Task.checkCancellation()
            switch try await client.pairStatus() {
            case "accepted": return true
            case "rejected": return false
            default: try await Task.sleep(for: interval)
            }
        }
    }
}
