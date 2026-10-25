import CryptoKit
import Foundation
import LibraryKit
import WirelessSync

/// Something the Mac answered with an error, or an answer that could not be trusted.
public struct MacError: LocalizedError, Sendable {
    public var message: String
    /// The HTTP status, 0 when the Mac did not answer.
    public var status: Int

    public init(_ message: String, status: Int = 0) {
        self.message = message
        self.status = status
    }

    public var errorDescription: String? { message }
}

/// Requests to Groovelight on the Mac, the device's side of `WirelessProtocol` (as Groovelight for Android makes them).
/// After pairing every request is signed with the shared key. With `tls` (protocol v2) it talks HTTPS to the Mac's
/// HTTPS port and accepts only the certificate whose fingerprint was pinned (`pinnedCertificate()`).
public final class MacClient: Sendable {
    /// The HTTPS port and the pinned certificate's SHA-256 (lowercase hex): only that certificate is accepted.
    public struct TLS: Sendable, Hashable {
        public var port: Int
        public var fingerprint: String

        public init(port: Int, fingerprint: String) {
            self.port = port
            self.fingerprint = fingerprint
        }
    }

    public let host: String
    public let port: Int
    public let deviceId: String
    private let key: SymmetricKey?
    public let tls: TLS?
    private let session: URLSession

    public init(host: String, port: Int, deviceId: String, key: SymmetricKey?, tls: TLS? = nil) {
        self.host = host
        self.port = port
        self.deviceId = deviceId
        self.key = key
        self.tls = tls
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 6 * 3600
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration, delegate: PinningDelegate(fingerprint: tls?.fingerprint), delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// Whether requests go over HTTPS (protocol v2).
    public var isSecure: Bool { tls != nil }

    // MARK: - Pairing

    public func info() async throws -> WirelessProtocol.Info {
        try await json("GET", "/info", signed: false, timeout: 8)
    }

    public func pair(name: String, model: String, publicKey: Data) async throws -> WirelessProtocol.PairResponse {
        let request = WirelessProtocol.PairRequest(deviceId: deviceId, name: name, model: model, publicKey: publicKey.base64EncodedString())
        return try await json("POST", "/pair", body: try WirelessProtocol.encoder.encode(request), signed: false)
    }

    public func pairStatus() async throws -> String {
        let status: WirelessProtocol.PairStatus = try await json("GET", "/pair/\(deviceId)", signed: false)
        return status.status
    }

    /// The fingerprint of the certificate the Mac's HTTPS port serves, to pin before connecting to it. Asked over HTTP:
    /// the answer carries the Mac's proof, made with the pairing key, so no one else on the network can name another
    /// certificate.
    public func pinnedCertificate() async throws -> String {
        guard let key else { throw MacError("Not paired") }
        let nonce = UUID().uuidString
        let answer: WirelessProtocol.Certificate = try await json("GET", "/certificate?nonce=\(nonce)", signedPath: "/certificate")
        let proof = WirelessProtocol.certificateProof(fingerprint: answer.fingerprint, nonce: nonce, key: key)
        guard answer.fingerprint.count == 64, Self.equal(proof, answer.proof) else {
            throw MacError("Could not verify the Mac's secure connection")
        }
        return answer.fingerprint
    }

    // MARK: - Syncing

    public func status() async throws -> WirelessProtocol.Status {
        try await json("GET", "/status")
    }

    public func sync(_ request: WirelessProtocol.SyncRequest) async throws -> WirelessProtocol.SyncPlan {
        try await json("POST", "/sync", body: try WirelessProtocol.encoder.encode(request), timeout: 300)
    }

    public func done(session: String, result: WirelessProtocol.SyncResult) async throws {
        let _: WirelessProtocol.PairStatus = try await json("POST", "/sync/\(session)/done", body: try WirelessProtocol.encoder.encode(result))
    }

    /// The request for a file of a plan (`FileDownloads` makes it): with the plan's `token` over HTTPS, else signed.
    public func downloadRequest(session: String, index: Int, token: String?) throws -> URLRequest {
        var request = try makeRequest("GET", "/sync/\(session)/file/\(index)", signed: token == nil, timeout: 120)
        if let token { request.setValue(token, forHTTPHeaderField: WirelessProtocol.Header.token) }
        return request
    }

    /// The library snapshot of a player sync (v2), checked against its SHA-256.
    public func snapshot(session: String, token: String) async throws -> Data {
        try await retrying { try await self.checkedData("/sync/\(session)/snapshot", token: token) }
    }

    /// A cover (600 pixels, JPEG) the snapshot refers to (v2), or nil when the Mac has none.
    public func artwork(session: String, token: String, hash: String) async throws -> Data? {
        do {
            return try await retrying { try await self.checkedData("/sync/\(session)/artwork/\(hash)", token: token) }
        } catch let error as MacError where error.status == 404 {
            return nil
        }
    }

    /// Sends loves, ratings, plays, skips and playlist edits made on the device (over HTTPS).
    public func history(_ events: [DeviceHistoryEvent]) async throws {
        let _: [String: Int] = try await json("POST", "/history", body: try WirelessProtocol.encoder.encode(WirelessProtocol.History(events: events)))
    }

    // MARK: - The Mac's whole library

    /// The Mac's whole library and what this device's selection holds (`DeviceCatalog`), or nil when the version this
    /// device has (`tag`) is still current. Comes deflated, checked against its SHA-256.
    public func catalog(tag: String?) async throws -> (catalog: DeviceCatalog, tag: String)? {
        var request = try makeRequest("GET", "/catalog", signed: true, timeout: 60)
        if let tag { request.setValue(tag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        if http?.statusCode == 304 { return nil }
        guard http?.statusCode == 200 else { throw MacError("The Mac's library could not be read (\(http?.statusCode ?? 0))", status: http?.statusCode ?? 0) }
        if let expected = http?.value(forHTTPHeaderField: WirelessProtocol.Header.sha256), Self.sha256(data) != expected {
            throw MacError("Arrived damaged")
        }
        let json = http?.value(forHTTPHeaderField: WirelessProtocol.Header.encoding) == "deflate"
            ? try (data as NSData).decompressed(using: .zlib) as Data : data
        let catalog = try WirelessProtocol.decoder.decode(DeviceCatalog.self, from: json)
        return (catalog, http?.value(forHTTPHeaderField: "ETag") ?? "")
    }

    /// A cover of the Mac's library (300 pixels), for albums this device does not have.
    public func catalogArtwork(_ hash: String) async throws -> Data? {
        let request = try makeRequest("GET", "/catalog/artwork/\(hash)", signed: true, timeout: 30)
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200, !data.isEmpty else { return nil }
        if let expected = http?.value(forHTTPHeaderField: WirelessProtocol.Header.sha256), Self.sha256(data) != expected { return nil }
        return data
    }

    /// Asks the Mac to add albums, artists or songs to this device (or take them off); answers with what its selection
    /// holds then. The Mac then asks this device to sync.
    public func requests(_ requests: [TransferRequest]) async throws -> DeviceCatalog.Chosen {
        try await json("POST", "/requests", body: try WirelessProtocol.encoder.encode(WirelessProtocol.Requests(requests: requests)))
    }

    // MARK: - Playing on the Mac

    /// The Mac's player now (or, with `device`, another device's through the Mac); with `after` (the version last
    /// seen), the next change, or the same state after about 25 seconds. A `MacError` with status 403 when the Mac does
    /// not let this device control it, 404 when that device is no longer there.
    public func remoteState(after version: String? = nil, device: String? = nil) async throws -> WirelessProtocol.RemoteState {
        let query = Self.query(["after": version, "device": device])
        return try await json("GET", "/remote" + query, timeout: version == nil ? 15 : 40, signedPath: "/remote")
    }

    /// Asks the Mac's player (or, with `device`, another device's) to do something; returns its state after.
    @discardableResult
    public func remote(_ command: WirelessProtocol.RemoteCommand, device: String? = nil) async throws -> WirelessProtocol.RemoteState {
        try await json("POST", "/remote" + Self.query(["device": device]), body: try WirelessProtocol.encoder.encode(command),
                       signedPath: "/remote")
    }

    /// The other devices music can play on now (phones with Groovelight open), through the Mac.
    public func remoteDevices() async throws -> [WirelessProtocol.RemoteDevice] {
        let answer: WirelessProtocol.RemoteDevices = try await json("GET", "/remote/devices")
        return answer.devices
    }

    // MARK: - Being played on (through the Mac)

    /// Commands for this device after `after` (the last one applied), waiting up to about 25 seconds for some. Without
    /// `after`, at once: none, and the sequence number to start from. Waiting also tells the Mac this device is there.
    public func relayCommands(after seq: Int?) async throws -> WirelessProtocol.RelayCommands {
        try await json("GET", "/relay" + Self.query(["after": seq.map(String.init)]), timeout: seq == nil ? 15 : 40, signedPath: "/relay")
    }

    /// This device's player, for the devices controlling it, with the last command applied.
    public func relayState(_ state: WirelessProtocol.RemoteState?, applied: Int) async throws {
        let _: [String: Bool] = try await json("POST", "/relay/state",
                                               body: try WirelessProtocol.encoder.encode(WirelessProtocol.RelayState(state: state, applied: applied)))
    }

    private static func query(_ items: [String: String?]) -> String {
        let pairs = items.compactMap { key, value in
            value.map { "\(key)=\($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
        }.sorted()
        return pairs.isEmpty ? "" : "?" + pairs.joined(separator: "&")
    }

    // MARK: - Requests

    private func checkedData(_ path: String, token: String) async throws -> Data {
        var request = try makeRequest("GET", path, signed: false, timeout: 120)
        request.setValue(token, forHTTPHeaderField: WirelessProtocol.Header.token)
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200 else { throw MacError("Download failed (\(http?.statusCode ?? 0))", status: http?.statusCode ?? 0) }
        if let expected = http?.value(forHTTPHeaderField: WirelessProtocol.Header.sha256), Self.sha256(data) != expected {
            throw MacError("Arrived damaged")
        }
        return data
    }

    /// A one-off download tried again twice when the connection drops, rather than failing the whole sync. The Mac's own
    /// answers (errors it sent) are final.
    private func retrying<T>(_ body: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await body()
            } catch let error as MacError where error.status != 0 {
                throw error
            } catch {
                attempt += 1
                if attempt >= 3 { throw error }
                try await Task.sleep(for: .seconds(attempt))
            }
        }
    }

    private func json<T: Decodable>(_ method: String, _ path: String, body: Data = Data(), signed: Bool = true, timeout: TimeInterval = 15,
                                    signedPath: String? = nil) async throws -> T {
        var request = try makeRequest(method, path, body: body, signed: signed, timeout: timeout, signedPath: signedPath)
        if !body.isEmpty {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled || error.code == .serverCertificateUntrusted
                    || error.code == .secureConnectionFailed {
            throw MacError("Could not verify the Mac's secure connection")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status < 400 else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "Error \(status)"
            throw MacError(message, status: status)
        }
        return try WirelessProtocol.decoder.decode(T.self, from: data)
    }

    /// `signedPath`: the path without its query, which is what the Mac checks the signature against.
    private func makeRequest(_ method: String, _ path: String, body: Data = Data(), signed: Bool, timeout: TimeInterval,
                             signedPath: String? = nil) throws -> URLRequest {
        let name = host.contains(":") ? "[\(host.replacingOccurrences(of: "%", with: "%25"))]" : host
        let base = tls.map { "https://\(name):\($0.port)" } ?? "http://\(name):\(port)"
        guard let url = URL(string: base + path) else { throw MacError("Bad address \(host)") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        if signed {
            guard let key else { throw MacError("Not paired") }
            let time = Int(Date.now.timeIntervalSince1970)
            let nonce = UUID().uuidString
            request.setValue(deviceId, forHTTPHeaderField: WirelessProtocol.Header.device)
            request.setValue("\(time)", forHTTPHeaderField: WirelessProtocol.Header.time)
            request.setValue(nonce, forHTTPHeaderField: WirelessProtocol.Header.nonce)
            request.setValue(WirelessProtocol.signature(method: method, path: signedPath ?? path, time: time, nonce: nonce, body: body, key: key),
                             forHTTPHeaderField: WirelessProtocol.Header.signature)
        }
        return request
    }

    // MARK: - Hashing

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(file url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time comparison.
    static func equal(_ a: String, _ b: String) -> Bool {
        let a = Data(a.utf8), b = Data(b.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Accepts the Mac's HTTPS certificate only when it is the pinned one. The Mac is reached by its address, which its
/// certificate does not name: what identifies it is the pinned certificate, not the system's trust or the host name.
final class PinningDelegate: NSObject, URLSessionDelegate, Sendable {
    let fingerprint: String?

    init(fingerprint: String?) {
        self.fingerprint = fingerprint
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        Self.evaluate(challenge, fingerprint: fingerprint)
    }

    static func evaluate(_ challenge: URLAuthenticationChallenge, fingerprint: String?) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        guard let fingerprint, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return (.cancelAuthenticationChallenge, nil)
        }
        let actual = MacClient.sha256(SecCertificateCopyData(leaf) as Data)
        guard MacClient.equal(actual, fingerprint) else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}
