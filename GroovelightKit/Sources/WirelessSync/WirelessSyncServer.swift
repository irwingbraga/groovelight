import CryptoKit
import Foundation
import LibraryKit

/// Groovelight's side of wireless sync: routes requests from the Android app, checks their signatures, and serves the
/// files of a plan. What it knows about the library comes from `Backend`, provided by the app.
public final class WirelessSyncServer: @unchecked Sendable {
    public struct Backend: Sendable {
        /// This Mac's id and name.
        public var info: @Sendable () -> WirelessProtocol.Info
        /// A device asks to pair: the app shows the code and asks the user.
        public var pairRequested: @Sendable (WirelessProtocol.PairRequest, WirelessProtocol.Pairing) async -> Void
        /// "pending", "accepted" or "rejected".
        public var pairStatus: @Sendable (String) async -> String
        /// The signing key of a paired device.
        public var key: @Sendable (String) async -> SymmetricKey?
        /// The plan for a device, from what it holds.
        public var plan: @Sendable (String, WirelessProtocol.SyncRequest) async throws -> (DeviceSyncPlan, DeviceProfile)
        /// cover.jpg data for an artwork hash at a size.
        public var cover: @Sendable (String, Int) -> Data?
        public var finished: @Sendable (String, WirelessProtocol.SyncResult) async -> Void
        public var status: @Sendable (String) async -> WirelessProtocol.Status
        /// A file of a plan was asked for (index, count), for progress on the Mac.
        public var fileServed: @Sendable (String, Int, Int) -> Void
        /// The FLAC conversion of a song (its source and the plan's fingerprint), for player devices (v2).
        public var flac: @Sendable (FormatConverter.Source, String) throws -> URL
        /// The library snapshot (JSON) for a device: song ids to their paths on it, and to the codec of converted ones.
        public var snapshot: @Sendable (String, [Int64: String], [Int64: String]) async throws -> Data
        /// The whole library for a device to browse (`DeviceCatalog` JSON).
        public var catalog: @Sendable (String) async throws -> Data
        /// Applies a device's requests to its selection and asks it to sync; returns what the selection holds then.
        public var requests: @Sendable (String, [TransferRequest]) async -> DeviceCatalog.Chosen

        public init(info: @escaping @Sendable () -> WirelessProtocol.Info,
                    pairRequested: @escaping @Sendable (WirelessProtocol.PairRequest, WirelessProtocol.Pairing) async -> Void,
                    pairStatus: @escaping @Sendable (String) async -> String,
                    key: @escaping @Sendable (String) async -> SymmetricKey?,
                    plan: @escaping @Sendable (String, WirelessProtocol.SyncRequest) async throws -> (DeviceSyncPlan, DeviceProfile),
                    cover: @escaping @Sendable (String, Int) -> Data?,
                    finished: @escaping @Sendable (String, WirelessProtocol.SyncResult) async -> Void,
                    status: @escaping @Sendable (String) async -> WirelessProtocol.Status,
                    fileServed: @escaping @Sendable (String, Int, Int) -> Void = { _, _, _ in },
                    flac: @escaping @Sendable (FormatConverter.Source, String) throws -> URL = { source, _ in source.url },
                    snapshot: @escaping @Sendable (String, [Int64: String], [Int64: String]) async throws -> Data = { _, _, _ in Data("{}".utf8) },
                    catalog: @escaping @Sendable (String) async throws -> Data = { _ in Data("{}".utf8) },
                    requests: @escaping @Sendable (String, [TransferRequest]) async -> DeviceCatalog.Chosen = { _, _ in
                        DeviceCatalog.Chosen(DeviceSelection())
                    }) {
            self.info = info
            self.pairRequested = pairRequested
            self.pairStatus = pairStatus
            self.key = key
            self.plan = plan
            self.cover = cover
            self.finished = finished
            self.status = status
            self.fileServed = fileServed
            self.flac = flac
            self.snapshot = snapshot
            self.catalog = catalog
            self.requests = requests
        }
    }

    private struct Session {
        var deviceId: String
        var plan: DeviceSyncPlan
        var profile: DeviceProfile
        var expires: Date
        /// Authorizes this session's downloads over TLS (v2).
        var token: String?
        var isPlayer = false
        /// SHA-256 of files already served (a resumed download asks again).
        var hashes: [Int: String] = [:]
    }

    private let backend: Backend
    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    /// Nonces seen lately (requests are valid for five minutes either way): a captured request cannot be sent again.
    private var recentNonces: [String: Date] = [:]
    private var server: LocalHTTPServer?
    private var secureServer: LocalHTTPServer?
    private var tlsPort: UInt16?
    /// The certificate the HTTPS port serves.
    private var fingerprint: String?

    public init(backend: Backend) {
        self.backend = backend
    }

    /// Serves HTTP on `port` (v1 and pairing) and, with a TLS identity, HTTPS on another port (v2), which `/info`
    /// reports. `ready` gets the HTTP port.
    public func start(name: String, port: UInt16 = 0, tls: (identity: SecIdentity, fingerprint: String)? = nil,
                      ready: @escaping @Sendable (UInt16?) -> Void) {
        let handler: LocalHTTPServer.Handler = { [weak self] request in await self?.handle(request) ?? .error(503, "stopped") }
        let server = LocalHTTPServer(handler: handler)
        lock.withLock { self.server = server }
        guard let tls else {
            start(server, name: name, port: port, ready: ready)
            return
        }
        // HTTPS first (the next port when free), so /info reports it as soon as HTTP answers.
        let secure = LocalHTTPServer(identity: tls.identity, handler: handler)
        lock.withLock {
            secureServer = secure
            fingerprint = tls.fingerprint
        }
        secure.start(name: nil, port: port == 0 ? 0 : port + 1) { [weak self] securePort in
            guard let self else { return }
            if let securePort {
                self.lock.withLock { self.tlsPort = securePort }
                self.start(server, name: name, port: port, ready: ready)
            } else if port != 0 {
                // Taken: any free port.
                secure.start(name: nil, port: 0) { securePort in
                    self.lock.withLock { self.tlsPort = securePort }
                    self.start(server, name: name, port: port, ready: ready)
                }
            } else {
                self.start(server, name: name, port: port, ready: ready)
            }
        }
    }

    private func start(_ server: LocalHTTPServer, name: String, port: UInt16, ready: @escaping @Sendable (UInt16?) -> Void) {
        let info = info()
        var txt = ["id": info.id, "v": "\(WirelessProtocol.version)"]
        if let tlsPort = info.tlsPort { txt["tls"] = "\(tlsPort)" }
        server.start(name: name, txt: txt, port: port, ready: ready)
    }

    public func stop() {
        lock.withLock {
            server?.stop()
            server = nil
            secureServer?.stop()
            secureServer = nil
            tlsPort = nil
        }
    }

    private func info() -> WirelessProtocol.Info {
        var info = backend.info()
        info.tlsPort = lock.withLock { tlsPort.map(Int.init) }
        return info
    }

    // MARK: - Routing

    func handle(_ request: LocalHTTPServer.Request) async -> LocalHTTPServer.Response {
        let parts = request.path.split(separator: "/").map(String.init)
        switch (request.method, parts.count, parts.first) {
        case ("GET", 1, "info"):
            return .json(info())
        case ("POST", 1, "pair"):
            return await pair(request)
        case ("GET", 2, "pair"):
            return .json(WirelessProtocol.PairStatus(status: await backend.pairStatus(parts[1])))
        default:
            break
        }
        // A session's downloads over TLS, with its token instead of a signature (v2).
        if request.method == "GET", parts.count >= 3, parts[0] == "sync", let token = request.headers[WirelessProtocol.Header.token] {
            guard request.secure, let session = lock.withLock({ sessions[parts[1]] }), session.expires > .now,
                  let expected = session.token, Self.equal(token, expected) else { return .error(401, "bad token") }
            return await download(session: parts[1], parts: parts, deviceId: session.deviceId)
        }
        guard let deviceId = await verify(request) else { return .error(401, "not paired or bad signature") }
        switch (request.method, parts.count, parts.first) {
        case ("GET", 1, "status"):
            return .json(await backend.status(deviceId))
        case ("GET", 1, "certificate"):
            return await certificate(deviceId: deviceId, request: request)
        case ("POST", 1, "sync"):
            return await startSync(deviceId: deviceId, request: request)
        case ("GET", 4, "sync") where parts[2] == "file":
            return await download(session: parts[1], parts: parts, deviceId: deviceId)
        case ("POST", 3, "sync") where parts[2] == "done":
            return await finish(session: parts[1], deviceId: deviceId, request: request)
        // The whole library and the device's requests (v2, over TLS only: they describe the library).
        case ("GET", 1, "catalog"):
            guard request.secure else { return .error(403, "HTTPS only") }
            return await catalog(deviceId: deviceId, request: request)
        case ("GET", 3, "catalog") where parts[1] == "artwork":
            guard request.secure else { return .error(403, "HTTPS only") }
            guard let data = backend.cover(parts[2], 300) else { return .error(404, "no cover") }
            return LocalHTTPServer.Response(headers: ["Content-Type": "image/jpeg", WirelessProtocol.Header.sha256: Self.sha256(data)],
                                            body: .data(data))
        case ("POST", 1, "requests"):
            guard request.secure else { return .error(403, "HTTPS only") }
            guard let body = try? WirelessProtocol.decoder.decode(WirelessProtocol.Requests.self, from: request.body) else {
                return .error(400, "bad requests")
            }
            return .json(await backend.requests(deviceId, body.requests))
        default:
            return .error(404, "unknown request")
        }
    }

    /// The catalog, deflated (raw DEFLATE, `X-GL-Encoding: deflate`), with its SHA-256 as the ETag: a device that has
    /// this version gets 304 and nothing else.
    private func catalog(deviceId: String, request: LocalHTTPServer.Request) async -> LocalHTTPServer.Response {
        do {
            let json = try await backend.catalog(deviceId)
            let tag = Self.sha256(json)
            if request.headers["if-none-match"] == tag { return LocalHTTPServer.Response(status: 304, headers: ["ETag": tag]) }
            let deflated = try (json as NSData).compressed(using: .zlib) as Data
            return LocalHTTPServer.Response(headers: ["Content-Type": "application/json", "ETag": tag, WirelessProtocol.Header.encoding: "deflate",
                                                      WirelessProtocol.Header.sha256: Self.sha256(deflated)], body: .data(deflated))
        } catch {
            return .error(500, error.localizedDescription)
        }
    }

    /// The certificate the HTTPS port serves, with proof that this Mac (paired with the device) is the one serving it.
    /// Asked over plain HTTP before the first HTTPS connection: the proof, made with the pairing key, is what the device
    /// trusts, so it pins the certificate before any handshake and never accepts an unknown one.
    private func certificate(deviceId: String, request: LocalHTTPServer.Request) async -> LocalHTTPServer.Response {
        guard let fingerprint = lock.withLock({ fingerprint }), let nonce = request.query["nonce"], nonce.count >= 16,
              let key = await backend.key(deviceId) else { return .error(400, "no certificate, or no nonce") }
        return .json(WirelessProtocol.Certificate(fingerprint: fingerprint,
                                                  proof: WirelessProtocol.certificateProof(fingerprint: fingerprint, nonce: nonce, key: key)))
    }

    /// Constant-time comparison of tokens.
    private static func equal(_ a: String, _ b: String) -> Bool {
        let a = Data(a.utf8), b = Data(b.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func pair(_ request: LocalHTTPServer.Request) async -> LocalHTTPServer.Response {
        guard let pairRequest = try? WirelessProtocol.decoder.decode(WirelessProtocol.PairRequest.self, from: request.body),
              let publicKey = Data(base64Encoded: pairRequest.publicKey),
              let pairing = try? WirelessProtocol.Pairing(devicePublicKey: publicKey) else {
            return .error(400, "bad pairing request")
        }
        await backend.pairRequested(pairRequest, pairing)
        let info = backend.info()
        return .json(WirelessProtocol.PairResponse(macId: info.id, macName: info.name,
                                                   publicKey: pairing.macPublicKey.base64EncodedString()))
    }

    /// The device of a correctly signed request from a paired device.
    func verify(_ request: LocalHTTPServer.Request, now: Date = .now) async -> String? {
        guard let deviceId = request.headers[WirelessProtocol.Header.device],
              let time = request.headers[WirelessProtocol.Header.time].flatMap({ Int($0) }),
              let signature = request.headers[WirelessProtocol.Header.signature],
              let nonce = request.headers[WirelessProtocol.Header.nonce],
              let key = await backend.key(deviceId),
              WirelessProtocol.isValid(signature: signature, method: request.method, path: request.path, time: time, nonce: nonce,
                                       body: request.body, key: key, now: now) else { return nil }
        return lock.withLock { () -> String? in
            recentNonces = recentNonces.filter { now.timeIntervalSince($0.value) < 600 }
            guard recentNonces[nonce] == nil else { return nil }
            recentNonces[nonce] = now
            return deviceId
        }
    }

    private func startSync(deviceId: String, request: LocalHTTPServer.Request) async -> LocalHTTPServer.Response {
        guard let syncRequest = try? WirelessProtocol.decoder.decode(WirelessProtocol.SyncRequest.self, from: request.body) else {
            return .error(400, "bad sync request")
        }
        do {
            let (plan, profile) = try await backend.plan(deviceId, syncRequest)
            let id = UUID().uuidString
            // A token only over TLS: in plain HTTP it could be read by others on the network.
            let token = request.secure ? Self.randomToken() : nil
            lock.withLock {
                sessions = sessions.filter { $0.value.expires > .now }
                sessions[id] = Session(deviceId: deviceId, plan: plan, profile: profile, expires: .now.addingTimeInterval(6 * 3600),
                                       token: token, isPlayer: syncRequest.isPlayer)
            }
            let writes = plan.writes.enumerated().map { index, write in
                WirelessProtocol.SyncPlan.Write(index: index, path: write.path, size: write.entry.size, entry: write.entry)
            }
            return .json(WirelessProtocol.SyncPlan(session: id, writes: writes, deletions: plan.deletions, unchanged: plan.unchanged,
                                                   profile: profile, songs: plan.songCount,
                                                   skipped: plan.skipped.map { "\($0.title): \($0.reason)" }, token: token))
        } catch {
            return .error(409, error.localizedDescription)
        }
    }

    private static func randomToken() -> String {
        var bytes = Data(count: 32)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        return bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    /// GET /sync/<session>/file/<index>, and over TLS /sync/<session>/snapshot and /sync/<session>/artwork/<hash>.
    private func download(session id: String, parts: [String], deviceId: String) async -> LocalHTTPServer.Response {
        guard let session = lock.withLock({ sessions[id] }), session.deviceId == deviceId else { return .error(404, "no such session") }
        switch (parts.count, parts[2]) {
        case (4, "file"):
            return await file(session: id, session, index: Int(parts[3]) ?? -1)
        case (3, "snapshot") where session.isPlayer:
            return await snapshot(session)
        case (4, "artwork"):
            guard let data = backend.cover(parts[3], 600) else { return .error(404, "no cover") }
            return LocalHTTPServer.Response(headers: ["Content-Type": "image/jpeg", WirelessProtocol.Header.sha256: Self.sha256(data)],
                                            body: .data(data))
        default:
            return .error(404, "unknown request")
        }
    }

    private func file(session id: String, _ session: Session, index: Int) async -> LocalHTTPServer.Response {
        guard session.plan.writes.indices.contains(index) else { return .error(404, "no such file") }
        backend.fileServed(session.deviceId, index, session.plan.writes.count)
        let write = session.plan.writes[index]
        switch write.content {
        case .file(let url):
            return fileResponse(url, session: id, index: index, cached: session.hashes[index])
        case .converted(let source):
            // Converted on first request (cached by the Mac), off the server's queue.
            let converted = await Task.detached(priority: .userInitiated) { [backend] in
                Result { try backend.flac(source, write.entry.fingerprint) }
            }.value
            switch converted {
            case .success(let url): return fileResponse(url, session: id, index: index, cached: session.hashes[index])
            case .failure(let error): return .error(500, error.localizedDescription)
            }
        case .data(let data):
            return LocalHTTPServer.Response(headers: [WirelessProtocol.Header.sha256: Self.sha256(data)], body: .data(data))
        case .cover(let hash):
            guard let data = backend.cover(hash, session.profile.coverSize) else { return .error(404, "no cover") }
            return LocalHTTPServer.Response(headers: ["Content-Type": "image/jpeg", WirelessProtocol.Header.sha256: Self.sha256(data)],
                                            body: .data(data))
        }
    }

    /// A file with its SHA-256 (worked out once per session and file).
    private func fileResponse(_ url: URL, session id: String, index: Int, cached: String?) -> LocalHTTPServer.Response {
        guard let hash = cached ?? Self.sha256(file: url) else { return .error(404, "missing file") }
        if cached == nil { lock.withLock { sessions[id]?.hashes[index] = hash } }
        return LocalHTTPServer.Response(headers: [WirelessProtocol.Header.sha256: hash], body: .file(url))
    }

    /// The library snapshot for the songs the device will hold after this sync.
    private func snapshot(_ session: Session) async -> LocalHTTPServer.Response {
        var paths: [Int64: String] = [:]
        var codecs: [Int64: String] = [:]
        for (path, entry) in session.plan.unchanged where entry.kind == .song {
            if let id = entry.trackId { paths[id] = path }
        }
        for write in session.plan.writes where write.entry.kind == .song {
            guard let id = write.entry.trackId else { continue }
            paths[id] = write.path
            if case .converted = write.content, let codec = DeviceSync.convertedCodec(fingerprint: write.entry.fingerprint) { codecs[id] = codec }
        }
        // Converted earlier and unchanged since: still in that format on the device.
        for (path, entry) in session.plan.unchanged where entry.kind == .song {
            if let id = entry.trackId, paths[id] == path, let codec = DeviceSync.convertedCodec(fingerprint: entry.fingerprint) { codecs[id] = codec }
        }
        do {
            let data = try await backend.snapshot(session.deviceId, paths, codecs)
            return LocalHTTPServer.Response(headers: ["Content-Type": "application/json", WirelessProtocol.Header.sha256: Self.sha256(data)],
                                            body: .data(data))
        } catch {
            return .error(500, error.localizedDescription)
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(file url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func finish(session id: String, deviceId: String, request: LocalHTTPServer.Request) async -> LocalHTTPServer.Response {
        guard lock.withLock({ sessions[id]?.deviceId == deviceId }),
              let result = try? WirelessProtocol.decoder.decode(WirelessProtocol.SyncResult.self, from: request.body) else {
            return .error(404, "no such session")
        }
        _ = lock.withLock { sessions.removeValue(forKey: id) }
        await backend.finished(deviceId, result)
        return .json(WirelessProtocol.PairStatus(status: "ok"))
    }
}
