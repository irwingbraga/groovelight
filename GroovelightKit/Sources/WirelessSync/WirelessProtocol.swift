import CryptoKit
import Foundation
import LibraryKit

/// The protocol between Groovelight on the Mac and Groovelight for Android and iOS, over the local network.
///
/// The Mac serves (Bonjour `_groovelight._tcp`); the Android app finds it, pairs once, and then pulls: it sends what
/// it holds, gets a plan, downloads the files and reports back. Every request after pairing is signed with a key both
/// sides derived from an X25519 exchange (it never travels), and pairing is confirmed by a 6-digit code shown on both
/// screens, so another device on the network can neither pose as the Mac nor as the player.
///
/// Version 2 adds HTTPS on a second port (`Info.tlsPort`): the device pins the Mac's certificate from a signed
/// `GET /certificate`, whose answer only the paired Mac can make (`certificateProof`), before connecting to it. Over it, a player device reports
/// what it decodes, downloads with the plan's token, checks each file's SHA-256, and gets the library snapshot.
/// Version 1 (plain HTTP) stays for Groovelight Sync 0.4 and earlier.
public enum WirelessProtocol {
    public static let serviceType = "_groovelight._tcp"
    public static let version = 2

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
        /// The plan's download token (v2, over TLS): files, the snapshot and covers of that sync, without signing each.
        public static let token = "x-gl-token"
        /// SHA-256 of a whole downloaded file (lowercase hex), checked by the device before keeping it.
        public static let sha256 = "x-gl-sha256"
        /// "deflate": the body is raw DEFLATE (the catalog).
        public static let encoding = "x-gl-encoding"
    }

    // MARK: - Certificate (v2)

    /// GET /certificate?nonce=<random> (signed): the certificate the HTTPS port serves, and proof that the paired Mac is
    /// the one serving it. The device pins the fingerprint when the proof checks, then accepts only that certificate.
    public struct Certificate: Codable, Sendable {
        /// SHA-256 of the certificate's DER bytes, lowercase hex.
        public var fingerprint: String
        /// `certificateProof`, base64.
        public var proof: String

        public init(fingerprint: String, proof: String) {
            self.fingerprint = fingerprint
            self.proof = proof
        }
    }

    /// HMAC-SHA256 of "groovelight-certificate\n<fingerprint>\n<nonce>" with the pairing key: only the paired Mac can
    /// make it, and the device's nonce makes an old answer useless.
    public static func certificateProof(fingerprint: String, nonce: String, key: SymmetricKey) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data("groovelight-certificate\n\(fingerprint)\n\(nonce)".utf8), using: key))
            .base64EncodedString()
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
        /// The HTTPS port (v2), when it is serving.
        public var tlsPort: Int?
        /// The Mac's Tailscale addresses, where paired devices reach it away from home (when it allows them).
        public var awayAddresses: [String]?

        public init(id: String, name: String, version: Int = WirelessProtocol.version, tlsPort: Int? = nil, awayAddresses: [String]? = nil) {
            self.id = id
            self.name = name
            self.version = version
            self.tlsPort = tlsPort
            self.awayAddresses = awayAddresses
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
        /// "player" (Groovelight plays the music) or "sync" (another app does); v1 devices send nothing (sync).
        public var mode: String?
        /// `AudioSpec.Codec` raw values the device decodes (player mode): the Mac converts the rest to FLAC.
        public var decodes: [String]?
        /// The format the device wants lossless songs in, chosen on it: "original" or a `LossyEncoding` raw value. Nil:
        /// as set on the Mac's device page.
        public var encoding: String?

        public init(manifest: DeviceManifest?, files: [String], capacity: Int64, available: Int64, model: String? = nil,
                    name: String? = nil, volumes: [Volume]? = nil, mode: String? = nil, decodes: [String]? = nil, encoding: String? = nil) {
            self.manifest = manifest
            self.files = files
            self.capacity = capacity
            self.available = available
            self.model = model
            self.name = name
            self.volumes = volumes
            self.mode = mode
            self.decodes = decodes
            self.encoding = encoding
        }

        public var isPlayer: Bool { mode == "player" }
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
        /// The download token (v2, over TLS): sent as `Header.token` for this session's files, snapshot and covers.
        public var token: String?

        public init(session: String, writes: [Write], deletions: [String], unchanged: [String: DeviceManifest.Entry],
                    profile: DeviceProfile, songs: Int, skipped: [String], token: String? = nil) {
            self.session = session
            self.writes = writes
            self.deletions = deletions
            self.unchanged = unchanged
            self.profile = profile
            self.songs = songs
            self.skipped = skipped
            self.token = token
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
    /// Loves, ratings, plays and skips made on the device (`POST /history`), answered with how many there were.
    public struct History: Codable, Sendable {
        public var events: [DeviceHistoryEvent]

        public init(events: [DeviceHistoryEvent]) {
            self.events = events
        }
    }

    /// Changes the app asks of its selection (`POST /requests`), answered with what the selection holds then.
    public struct Requests: Codable, Sendable {
        public var requests: [TransferRequest]

        public init(requests: [TransferRequest]) {
            self.requests = requests
        }
    }

    public struct Status: Codable, Sendable {
        public var syncRequested: Bool
        public var pendingSends: Int

        public init(syncRequested: Bool, pendingSends: Int) {
            self.syncRequested = syncRequested
            self.pendingSends = pendingSends
        }
    }

    // MARK: - Playing on the Mac (remote control)

    /// The Mac's player as a paired device sees it (`GET /remote`, HTTPS): what plays, where, and the queue, for a phone
    /// that plays music on the Mac rather than on itself. Positions are as of the answer: the device moves them on with
    /// its own clock, so the two clocks need not agree.
    public struct RemoteState: Codable, Hashable, Sendable {
        public struct Item: Codable, Hashable, Sendable {
            public var id: Int64
            public var title: String
            public var artist: String
            public var album: String
            public var albumKey: String?
            public var artworkHash: String?
            public var duration: Double
            /// Loved where it plays (nil from an older app).
            public var loved: Bool?

            public init(id: Int64, title: String, artist: String, album: String, albumKey: String?, artworkHash: String?, duration: Double,
                        loved: Bool? = nil) {
                self.id = id
                self.title = title
                self.artist = artist
                self.album = album
                self.albumKey = albumKey
                self.artworkHash = artworkHash
                self.duration = duration
                self.loved = loved
            }
        }

        public var item: Item?
        public var playing: Bool
        /// Seconds into `item`.
        public var position: Double
        /// The playing speed (1 is normal), to move `position` on.
        public var rate: Double
        /// 0 to 1.
        public var volume: Double
        public var shuffle: Bool
        /// "off", "all" or "one".
        public var repeatMode: String
        /// Song ids in play order, and where the current one is: to take the queue over to the device.
        public var queue: [Int64]
        public var queueIndex: Int?
        /// Changes when anything but the steady progress of the song changes (a seek does): the device waits with it.
        public var version: String = ""

        public init(item: Item?, playing: Bool, position: Double, rate: Double = 1, volume: Double, shuffle: Bool, repeatMode: String,
                    queue: [Int64], queueIndex: Int?) {
            self.item = item
            self.playing = playing
            self.position = position
            self.rate = rate
            self.volume = volume
            self.shuffle = shuffle
            self.repeatMode = repeatMode
            self.queue = queue
            self.queueIndex = queueIndex
        }

        /// What `version` is made from, as of `now`: while playing, the moment the song started (rounded), which a
        /// seek moves and steady playing does not.
        public func signature(now: Date) -> String {
            let anchor = playing ? (now.timeIntervalSince1970 - position / max(rate, 0.01)).rounded() : position.rounded()
            let queueHash = queue.reduce(into: Hasher()) { $0.combine($1) }.finalize()
            return [item.map { "\($0.id)" } ?? "-", playing ? "p" : "s", "\(Int64(anchor))", String(format: "%.2f", volume),
                    shuffle ? "1" : "0", repeatMode, "\(queueHash)", queueIndex.map { "\($0)" } ?? "-"].joined(separator: "|")
        }
    }

    /// Another device that music can play on (`GET /remote/devices`): a phone with Groovelight open, reached through the
    /// Mac. Commands and state for it go through the same `/remote` routes with `?device=<id>`.
    public struct RemoteDevice: Codable, Hashable, Sendable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public struct RemoteDevices: Codable, Sendable {
        public var devices: [RemoteDevice]

        public init(devices: [RemoteDevice]) {
            self.devices = devices
        }
    }

    /// A command for a device that music plays on, passed on by the Mac from the device that sent it.
    public struct RelayedCommand: Codable, Hashable, Sendable {
        /// Counts up for each device: it answers with the last one it applied.
        public var seq: Int
        /// The device that sent it, and its name.
        public var from: String
        public var fromName: String
        public var command: RemoteCommand

        public init(seq: Int, from: String, fromName: String, command: RemoteCommand) {
            self.seq = seq
            self.from = from
            self.fromName = fromName
            self.command = command
        }
    }

    /// The commands for a device after the last one it has (`GET /relay?after=<seq>`, held until there are some).
    /// `last` is the newest sequence number: a device that just started takes it as where to begin, so it never
    /// applies commands sent before it was there.
    public struct RelayCommands: Codable, Sendable {
        public var commands: [RelayedCommand]
        public var last: Int

        public init(commands: [RelayedCommand], last: Int) {
            self.commands = commands
            self.last = last
        }
    }

    /// A device's own player, for the devices controlling it (`POST /relay/state`), with the last command it applied.
    public struct RelayState: Codable, Sendable {
        public var state: RemoteState?
        public var applied: Int

        public init(state: RemoteState?, applied: Int) {
            self.state = state
            self.applied = applied
        }
    }

    /// What a device asks the Mac's player to do (`POST /remote`, HTTPS), answered with the state after it. In JSON a
    /// flat object, easy to make on Android: `{"command": "seek", "position": 42}`, `{"command": "play", "songIds": [...],
    /// "startAt": 0, "position": 0, "shuffle": false}`, `{"command": "volume", "volume": 0.5}`, `{"command": "shuffle",
    /// "on": true}`, `{"command": "repeatMode", "mode": "all"}`, or only the command for the others.
    public enum RemoteCommand: Codable, Hashable, Sendable {
        /// Plays these songs (by id) from `startAt`, at `position` seconds into it: a queue handed over from the device.
        case play(songIds: [Int64], startAt: Int, position: Double, shuffle: Bool)
        case pause
        case resume
        case next
        case previous
        case seek(Double)
        case volume(Double)
        case shuffle(Bool)
        case repeatMode(String)
        case stop

        private enum Keys: String, CodingKey {
            case command, songIds, startAt, position, shuffle, volume, on, mode
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            let command = try container.decode(String.self, forKey: .command)
            switch command {
            case "play":
                self = .play(songIds: try container.decode([Int64].self, forKey: .songIds),
                             startAt: try container.decodeIfPresent(Int.self, forKey: .startAt) ?? 0,
                             position: try container.decodeIfPresent(Double.self, forKey: .position) ?? 0,
                             shuffle: try container.decodeIfPresent(Bool.self, forKey: .shuffle) ?? false)
            case "pause": self = .pause
            case "resume": self = .resume
            case "next": self = .next
            case "previous": self = .previous
            case "seek": self = .seek(try container.decode(Double.self, forKey: .position))
            case "volume": self = .volume(try container.decode(Double.self, forKey: .volume))
            case "shuffle": self = .shuffle(try container.decode(Bool.self, forKey: .on))
            case "repeatMode": self = .repeatMode(try container.decode(String.self, forKey: .mode))
            case "stop": self = .stop
            default: throw DecodingError.dataCorruptedError(forKey: .command, in: container, debugDescription: "Unknown command \(command)")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            switch self {
            case let .play(songIds, startAt, position, shuffle):
                try container.encode("play", forKey: .command)
                try container.encode(songIds, forKey: .songIds)
                try container.encode(startAt, forKey: .startAt)
                try container.encode(position, forKey: .position)
                try container.encode(shuffle, forKey: .shuffle)
            case .pause: try container.encode("pause", forKey: .command)
            case .resume: try container.encode("resume", forKey: .command)
            case .next: try container.encode("next", forKey: .command)
            case .previous: try container.encode("previous", forKey: .command)
            case .seek(let position):
                try container.encode("seek", forKey: .command)
                try container.encode(position, forKey: .position)
            case .volume(let volume):
                try container.encode("volume", forKey: .command)
                try container.encode(volume, forKey: .volume)
            case .shuffle(let on):
                try container.encode("shuffle", forKey: .command)
                try container.encode(on, forKey: .on)
            case .repeatMode(let mode):
                try container.encode("repeatMode", forKey: .command)
                try container.encode(mode, forKey: .mode)
            case .stop: try container.encode("stop", forKey: .command)
            }
        }
    }
}
