import CryptoKit
import Foundation
import LibraryKit

/// The protocol between Groovelight on the Mac and the Groovelight Sync app on Android, over the local network.
///
/// The Mac serves (Bonjour `_groovelight._tcp`); the Android app finds it, pairs once, and then pulls: it sends what
/// it holds, gets a plan, downloads the files and reports back. Every request after pairing is signed with a key both
/// sides derived from an X25519 exchange (it never travels), and pairing is confirmed by a 6-digit code shown on both
/// screens, so another device on the network can neither pose as the Mac nor as the player.
public enum WirelessProtocol {
    public static let serviceType = "_groovelight._tcp"
    public static let version = 1

    // MARK: - Pairing

    /// A pairing in progress: the Mac's side of the key exchange with one device.
    public struct Pairing: Sendable {
        public let macPublicKey: Data
        public let key: SymmetricKey
        /// Shown on both screens; the user checks they match before allowing the device.
        public let code: String

        /// The Mac's side: a fresh key pair against the device's public key (raw 32-byte X25519).
        public init(devicePublicKey: Data) throws {
            let mine = Curve25519.KeyAgreement.PrivateKey()
            try self.init(privateKey: mine, devicePublicKey: devicePublicKey)
        }

        init(privateKey: Curve25519.KeyAgreement.PrivateKey, devicePublicKey: Data) throws {
            let device = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: devicePublicKey)
            let secret = try privateKey.sharedSecretFromKeyAgreement(with: device)
            macPublicKey = privateKey.publicKey.rawRepresentation
            (key, code) = WirelessProtocol.derive(secret: secret.withUnsafeBytes { Data($0) },
                                                  macPublicKey: macPublicKey, devicePublicKey: devicePublicKey)
        }
    }

    /// The signing key and the confirmation code from the X25519 shared secret (HKDF-SHA256, RFC 5869), bound to both
    /// public keys. The Android app computes the same.
    public static func derive(secret: Data, macPublicKey: Data, devicePublicKey: Data) -> (SymmetricKey, String) {
        let salt = Data("groovelight-pair-v1".utf8)
        let input = SymmetricKey(data: secret)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: input, salt: salt, info: Data("key".utf8) + macPublicKey + devicePublicKey,
                                         outputByteCount: 32)
        let codeBytes = HKDF<SHA256>.deriveKey(inputKeyMaterial: input, salt: salt,
                                               info: Data("code".utf8) + macPublicKey + devicePublicKey, outputByteCount: 4)
        let number = codeBytes.withUnsafeBytes { bytes in bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } } % 1_000_000
        return (key, String(format: "%06u", number))
    }

    // MARK: - Signing

    /// Header names of a signed request.
    public enum Header {
        public static let device = "x-gl-device"
        public static let time = "x-gl-time"
        public static let signature = "x-gl-signature"
        /// Random per request, so two identical requests in the same second still differ (and a replay is caught).
        public static let nonce = "x-gl-nonce"
    }

    /// "METHOD\npath\ntime\nnonce\nsha256(body) in hex", signed with HMAC-SHA256 and sent in base64.
    public static func signature(method: String, path: String, time: Int, nonce: String, body: Data, key: SymmetricKey) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: signedMessage(method, path, time, nonce, body), using: key)).base64EncodedString()
    }

    public static func isValid(signature: String, method: String, path: String, time: Int, nonce: String, body: Data,
                               key: SymmetricKey, now: Date = .now) -> Bool {
        // Five minutes either way covers clocks a little off.
        guard abs(Int(now.timeIntervalSince1970) - time) <= 300, !nonce.isEmpty,
              let given = Data(base64Encoded: signature) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(given, authenticating: signedMessage(method, path, time, nonce, body), using: key)
    }

    private static func signedMessage(_ method: String, _ path: String, _ time: Int, _ nonce: String, _ body: Data) -> Data {
        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return Data("\(method.uppercased())\n\(path)\n\(time)\n\(nonce)\n\(bodyHash)".utf8)
    }

    // MARK: - Messages

    /// GET /info: who is serving (no signature needed).
    public struct Info: Codable, Sendable {
        public var id: String
        public var name: String
        public var version: Int

        public init(id: String, name: String, version: Int = WirelessProtocol.version) {
            self.id = id
            self.name = name
            self.version = version
        }
    }

    /// POST /pair: a device asks to pair.
    public struct PairRequest: Codable, Sendable {
        public var deviceId: String
        public var name: String
        public var model: String?
        /// Raw 32-byte X25519 public key, base64.
        public var publicKey: String

        public init(deviceId: String, name: String, model: String?, publicKey: String) {
            self.deviceId = deviceId
            self.name = name
            self.model = model
            self.publicKey = publicKey
        }
    }

    public struct PairResponse: Codable, Sendable {
        public var macId: String
        public var macName: String
        public var publicKey: String

        public init(macId: String, macName: String, publicKey: String) {
            self.macId = macId
            self.macName = macName
            self.publicKey = publicKey
        }
    }

    /// GET /pair/<deviceId>: "pending", "accepted" or "rejected".
    public struct PairStatus: Codable, Sendable {
        public var status: String

        public init(status: String) { self.status = status }
    }

    /// A storage volume of the device: internal memory, an SD card.
    public struct Volume: Codable, Hashable, Sendable {
        public var name: String
        public var removable: Bool
        public var total: Int64
        public var free: Int64
        /// Holds the music folder picked in the app.
        public var music: Bool

        public init(name: String, removable: Bool, total: Int64, free: Int64, music: Bool) {
            self.name = name
            self.removable = removable
            self.total = total
            self.free = free
            self.music = music
        }
    }

    /// POST /sync (signed): what the device holds.
    public struct SyncRequest: Codable, Sendable {
        /// The device's `.groovelight-device.json`.
        public var manifest: DeviceManifest?
        /// Every file under the music folder the user picked, relative to it.
        public var files: [String]
        public var capacity: Int64
        public var available: Int64
        public var model: String?
        public var name: String?
        /// Every storage of the device (older app versions do not send it).
        public var volumes: [Volume]?

        public init(manifest: DeviceManifest?, files: [String], capacity: Int64, available: Int64, model: String? = nil,
                    name: String? = nil, volumes: [Volume]? = nil) {
            self.manifest = manifest
            self.files = files
            self.capacity = capacity
            self.available = available
            self.model = model
            self.name = name
            self.volumes = volumes
        }
    }

    /// The plan for the device.
    public struct SyncPlan: Codable, Sendable {
        public struct Write: Codable, Sendable {
            /// Download as GET /sync/<session>/file/<index>.
            public var index: Int
            public var path: String
            public var size: Int64
            /// The manifest entry to record once the file is written.
            public var entry: DeviceManifest.Entry

            public init(index: Int, path: String, size: Int64, entry: DeviceManifest.Entry) {
                self.index = index
                self.path = path
                self.size = size
                self.entry = entry
            }
        }

        public var session: String
        public var writes: [Write]
        public var deletions: [String]
        /// Manifest entries for files that stay.
        public var unchanged: [String: DeviceManifest.Entry]
        /// The profile to store in the manifest.
        public var profile: DeviceProfile
        public var songs: Int
        public var skipped: [String]

        public init(session: String, writes: [Write], deletions: [String], unchanged: [String: DeviceManifest.Entry],
                    profile: DeviceProfile, songs: Int, skipped: [String]) {
            self.session = session
            self.writes = writes
            self.deletions = deletions
            self.unchanged = unchanged
            self.profile = profile
            self.songs = songs
            self.skipped = skipped
        }
    }

    /// Dates as ISO 8601, like the manifest file.
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// POST /sync/<session>/done (signed).
    public struct SyncResult: Codable, Sendable {
        public var written: Int
        public var deleted: Int
        public var failed: [String]
        public var available: Int64?

        public init(written: Int, deleted: Int, failed: [String], available: Int64?) {
            self.written = written
            self.deleted = deleted
            self.failed = failed
            self.available = available
        }
    }

    /// GET /status (signed): whether the Mac asked for a sync (its Sync button), so an open app starts one.
    public struct Status: Codable, Sendable {
        public var syncRequested: Bool
        public var pendingSends: Int

        public init(syncRequested: Bool, pendingSends: Int) {
            self.syncRequested = syncRequested
            self.pendingSends = pendingSends
        }
    }
}
