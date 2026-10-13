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

        public init(info: @escaping @Sendable () -> WirelessProtocol.Info,
                    pairRequested: @escaping @Sendable (WirelessProtocol.PairRequest, WirelessProtocol.Pairing) async -> Void,
                    pairStatus: @escaping @Sendable (String) async -> String,
                    key: @escaping @Sendable (String) async -> SymmetricKey?,
                    plan: @escaping @Sendable (String, WirelessProtocol.SyncRequest) async throws -> (DeviceSyncPlan, DeviceProfile),
                    cover: @escaping @Sendable (String, Int) -> Data?,
                    finished: @escaping @Sendable (String, WirelessProtocol.SyncResult) async -> Void,
                    status: @escaping @Sendable (String) async -> WirelessProtocol.Status,
                    fileServed: @escaping @Sendable (String, Int, Int) -> Void = { _, _, _ in }) {
            self.info = info
            self.pairRequested = pairRequested
            self.pairStatus = pairStatus
            self.key = key
            self.plan = plan
            self.cover = cover
            self.finished = finished
            self.status = status
            self.fileServed = fileServed
        }
    }

    private struct Session {
        var deviceId: String
        var plan: DeviceSyncPlan
        var profile: DeviceProfile
        var expires: Date
    }

    private let backend: Backend
    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    /// Nonces seen lately (requests are valid for five minutes either way): a captured request cannot be sent again.
    private var recentNonces: [String: Date] = [:]
    private var server: LocalHTTPServer?

    public init(backend: Backend) {
        self.backend = backend
    }

    public func start(name: String, port: UInt16 = 0, ready: @escaping @Sendable (UInt16?) -> Void) {
        let server = LocalHTTPServer { [weak self] request in
            await self?.handle(request) ?? .error(503, "stopped")
        }
        lock.withLock { self.server = server }
        let info = backend.info()
        server.start(name: name, txt: ["id": info.id, "v": "\(WirelessProtocol.version)"], port: port, ready: ready)
    }

    public func stop() {
        lock.withLock {
            server?.stop()
            server = nil
        }
    }

    // MARK: - Routing

    func handle(_ request: LocalHTTPServer.Request) async -> LocalHTTPServer.Response {
        let parts = request.path.split(separator: "/").map(String.init)
        switch (request.method, parts.count, parts.first) {
        case ("GET", 1, "info"):
            return .json(backend.info())
        case ("POST", 1, "pair"):
            return await pair(request)
        case ("GET", 2, "pair"):
            return .json(WirelessProtocol.PairStatus(status: await backend.pairStatus(parts[1])))
        default:
            break
        }
        guard let deviceId = await verify(request) else { return .error(401, "not paired or bad signature") }
        switch (request.method, parts.count, parts.first) {
        case ("GET", 1, "status"):
            return .json(await backend.status(deviceId))
        case ("POST", 1, "sync"):
            return await startSync(deviceId: deviceId, request: request)
        case ("GET", 4, "sync") where parts[2] == "file":
            return file(session: parts[1], index: Int(parts[3]) ?? -1, deviceId: deviceId)
        case ("POST", 3, "sync") where parts[2] == "done":
            return await finish(session: parts[1], deviceId: deviceId, request: request)
        default:
            return .error(404, "unknown request")
        }
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
            lock.withLock {
                sessions = sessions.filter { $0.value.expires > .now }
                sessions[id] = Session(deviceId: deviceId, plan: plan, profile: profile, expires: .now.addingTimeInterval(6 * 3600))
            }
            let writes = plan.writes.enumerated().map { index, write in
                WirelessProtocol.SyncPlan.Write(index: index, path: write.path, size: write.entry.size, entry: write.entry)
            }
            return .json(WirelessProtocol.SyncPlan(session: id, writes: writes, deletions: plan.deletions, unchanged: plan.unchanged,
                                                   profile: profile, songs: plan.songCount,
                                                   skipped: plan.skipped.map { "\($0.title): \($0.reason)" }))
        } catch {
            return .error(409, error.localizedDescription)
        }
    }

    private func file(session id: String, index: Int, deviceId: String) -> LocalHTTPServer.Response {
        guard let session = lock.withLock({ sessions[id] }), session.deviceId == deviceId,
              session.plan.writes.indices.contains(index) else { return .error(404, "no such file") }
        backend.fileServed(deviceId, index, session.plan.writes.count)
        switch session.plan.writes[index].content {
        case .file(let url):
            return LocalHTTPServer.Response(body: .file(url))
        case .data(let data):
            return LocalHTTPServer.Response(body: .data(data))
        case .cover(let hash):
            guard let data = backend.cover(hash, session.profile.coverSize) else { return .error(404, "no cover") }
            return LocalHTTPServer.Response(headers: ["Content-Type": "image/jpeg"], body: .data(data))
        }
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
