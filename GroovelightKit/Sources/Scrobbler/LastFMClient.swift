import CryptoKit
import Foundation
import MetadataKit

/// The API account of the app on Last.fm (created at https://www.last.fm/api/account/create).
public struct LastFMCredentials: Sendable, Equatable {
    public var apiKey: String
    public var secret: String

    public init(apiKey: String, secret: String) {
        self.apiKey = apiKey
        self.secret = secret
    }
}

public enum LastFMError: Error, Equatable, Sendable {
    /// An error answered by the API (https://www.last.fm/api/errorcodes).
    case api(code: Int, message: String)
    case http(Int)
    case invalidResponse
    /// No connection, timeout: try again later.
    case offline

    /// Worth retrying later: the service is down or busy, or the Mac is offline.
    public var isTemporary: Bool {
        switch self {
        case .api(let code, _): [8, 11, 16, 29].contains(code)
        case .http(let status): status >= 500 || status == 429
        case .offline: true
        case .invalidResponse: false
        }
    }

    /// The session or the API account is not valid any more: the user has to connect again.
    public var needsReconnect: Bool {
        if case .api(let code, _) = self { return [4, 9, 10, 13, 26].contains(code) }
        return false
    }

    /// The token was not authorized yet in the browser (keep waiting during the connection).
    public var isUnauthorizedToken: Bool {
        if case .api(14, _) = self { return true }
        return false
    }
}

/// A song as Last.fm wants it for now playing and scrobbles.
public struct LastFMTrack: Sendable, Equatable {
    public var artist: String
    public var track: String
    public var album: String?
    public var albumArtist: String?
    public var duration: Double?
    public var trackNumber: Int?

    public init(artist: String, track: String, album: String? = nil, albumArtist: String? = nil, duration: Double? = nil,
                trackNumber: Int? = nil) {
        self.artist = artist
        self.track = track
        self.album = album
        self.albumArtist = albumArtist
        self.duration = duration
        self.trackNumber = trackNumber
    }
}

/// What Last.fm made of a batch of scrobbles.
public struct ScrobbleResponse: Sendable, Equatable {
    public var accepted: Int
    public var ignored: Int
}

/// Last.fm web service client: desktop authentication, now playing, scrobbles and loves. Write calls are signed with the
/// API secret and the user's session key.
public struct LastFMClient: Sendable {
    public static let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    public var credentials: LastFMCredentials
    public var sessionKey: String?
    private let fetcher: HTTPFetching
    private let identity: ClientIdentity

    public init(credentials: LastFMCredentials, sessionKey: String? = nil, fetcher: HTTPFetching = URLSessionFetcher(),
                identity: ClientIdentity = ClientIdentity(version: "1.0")) {
        self.credentials = credentials
        self.sessionKey = sessionKey
        self.fetcher = fetcher
        self.identity = identity
    }

    // MARK: - Authentication

    /// Step 1: a token to authorize in the browser.
    public func getToken() async throws -> String {
        let json = try await call("auth.getToken", [:], post: false, needsSession: false)
        guard let token = json["token"] as? String else { throw LastFMError.invalidResponse }
        return token
    }

    /// Step 2: the page where the user allows the app to use their account.
    public func authorizationURL(token: String) -> URL {
        var components = URLComponents(string: "https://www.last.fm/api/auth/")!
        components.queryItems = [URLQueryItem(name: "api_key", value: credentials.apiKey), URLQueryItem(name: "token", value: token)]
        return components.url!
    }

    /// Step 3, once authorized: the user name and a session key that does not expire.
    public func getSession(token: String) async throws -> (name: String, key: String) {
        let json = try await call("auth.getSession", ["token": token], post: false, needsSession: false)
        guard let session = json["session"] as? [String: Any], let name = session["name"] as? String,
              let key = session["key"] as? String else { throw LastFMError.invalidResponse }
        return (name, key)
    }

    // MARK: - Listening

    public func updateNowPlaying(_ track: LastFMTrack) async throws {
        var params = ["artist": track.artist, "track": track.track]
        params["album"] = track.album
        params["albumArtist"] = track.albumArtist
        params["duration"] = track.duration.map { String(Int($0.rounded())) }
        params["trackNumber"] = track.trackNumber.map(String.init)
        _ = try await call("track.updateNowPlaying", params, post: true, needsSession: true)
    }

    /// Sends up to 50 scrobbles in one request.
    public func scrobble(_ scrobbles: [(track: LastFMTrack, startedAt: Date)]) async throws -> ScrobbleResponse {
        precondition(scrobbles.count <= 50, "Last.fm takes at most 50 scrobbles per request")
        let json = try await call("track.scrobble", Self.scrobbleParameters(scrobbles), post: true, needsSession: true)
        guard let body = json["scrobbles"] as? [String: Any], let attributes = body["@attr"] as? [String: Any] else {
            throw LastFMError.invalidResponse
        }
        return ScrobbleResponse(accepted: Self.int(attributes["accepted"]), ignored: Self.int(attributes["ignored"]))
    }

    public func setLoved(_ loved: Bool, artist: String, track: String) async throws {
        _ = try await call(loved ? "track.love" : "track.unlove", ["artist": artist, "track": track], post: true, needsSession: true)
    }

    // MARK: - Requests

    /// Indexed parameters of a scrobble batch ("artist[0]", "timestamp[0]"...).
    static func scrobbleParameters(_ scrobbles: [(track: LastFMTrack, startedAt: Date)]) -> [String: String] {
        var params: [String: String] = [:]
        for (index, scrobble) in scrobbles.enumerated() {
            let track = scrobble.track
            params["artist[\(index)]"] = track.artist
            params["track[\(index)]"] = track.track
            params["timestamp[\(index)]"] = String(Int(scrobble.startedAt.timeIntervalSince1970))
            params["album[\(index)]"] = track.album
            params["albumArtist[\(index)]"] = track.albumArtist
            params["duration[\(index)]"] = track.duration.map { String(Int($0.rounded())) }
            params["trackNumber[\(index)]"] = track.trackNumber.map(String.init)
        }
        return params
    }

    /// The request signature: every parameter except `format` and `callback`, sorted by name, as name and value
    /// concatenated, then the secret, hashed with MD5.
    static func signature(_ params: [String: String], secret: String) -> String {
        let text = params.filter { $0.key != "format" && $0.key != "callback" }
            .sorted { $0.key < $1.key }
            .map { $0.key + $0.value }
            .joined() + secret
        return Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func call(_ method: String, _ extra: [String: String], post: Bool, needsSession: Bool) async throws -> [String: Any] {
        var params = extra
        params["method"] = method
        params["api_key"] = credentials.apiKey
        if needsSession {
            guard let sessionKey else { throw LastFMError.api(code: 9, message: "Not connected to Last.fm") }
            params["sk"] = sessionKey
        }
        params["api_sig"] = Self.signature(params, secret: credentials.secret)
        params["format"] = "json"

        let body = Self.formEncoded(params)
        var request: URLRequest
        if post {
            request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.httpBody = Data(body.utf8)
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        } else {
            request = URLRequest(url: URL(string: Self.endpoint.absoluteString + "?" + body)!, timeoutInterval: 20)
        }
        request.setValue(identity.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await fetcher.data(for: request)
        } catch is URLError {
            throw LastFMError.offline
        }
        // Errors come as JSON (often with a 4xx status): read the body first.
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let code = json?["error"] as? Int {
            throw LastFMError.api(code: code, message: json?["message"] as? String ?? "")
        }
        guard (200..<300).contains(response.statusCode) else { throw LastFMError.http(response.statusCode) }
        guard let json else { throw LastFMError.invalidResponse }
        return json
    }

    static func formEncoded(_ params: [String: String]) -> String {
        // Unreserved ASCII only (CharacterSet.alphanumerics would let accented letters through unencoded).
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text }
        return params.sorted { $0.key < $1.key }.map { encode($0.key) + "=" + encode($0.value) }.joined(separator: "&")
    }

    private static func int(_ value: Any?) -> Int {
        if let number = value as? Int { return number }
        if let text = value as? String { return Int(text) ?? 0 }
        return 0
    }
}

/// When a play counts as a scrobble, by Last.fm's rules: the song is longer than 30 seconds and was played for at least
/// half its length or 4 minutes, whichever comes first.
public enum ScrobbleRules {
    public static func isEligible(duration: Double, listened: Double) -> Bool {
        duration > 30 && listened >= min(duration / 2, 240)
    }
}
