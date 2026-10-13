import Foundation
import Testing
@testable import LibraryKit
@testable import MetadataKit
@testable import Scrobbler

/// Last.fm: request signing, scrobble rules, the offline queue and sending it.
struct ScrobblerTests {
    @Test func signsRequestsLikeLastFM() {
        // Expected values computed independently (md5 of the sorted name+value pairs and the secret).
        let auth = LastFMClient.signature(["method": "auth.getSession", "api_key": "KEY", "token": "TOK", "format": "json"],
                                          secret: "SECRET")
        #expect(auth == "0bf279e021f3a81b4553dd7e76cf72ad")
        let scrobble = LastFMClient.signature(["method": "track.scrobble", "api_key": "KEY", "sk": "SK", "artist[0]": "Björk",
                                               "track[0]": "Jóga", "timestamp[0]": "1700000000"], secret: "SECRET")
        #expect(scrobble == "5db62934573e3bf31004fd1dcef6cd8d")
    }

    @Test func scrobbleRules() {
        #expect(!ScrobbleRules.isEligible(duration: 30, listened: 30))
        #expect(ScrobbleRules.isEligible(duration: 200, listened: 100))
        #expect(!ScrobbleRules.isEligible(duration: 200, listened: 99))
        // Long songs: 4 minutes are enough.
        #expect(ScrobbleRules.isEligible(duration: 1200, listened: 240))
        #expect(!ScrobbleRules.isEligible(duration: 1200, listened: 239))
    }

    @Test func encodesBatchesAndForms() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let params = LastFMClient.scrobbleParameters([
            (LastFMTrack(artist: "A", track: "One", album: "X", duration: 199.6, trackNumber: 1), date),
            (LastFMTrack(artist: "B", track: "Two"), date.addingTimeInterval(200)),
        ])
        #expect(params["artist[0]"] == "A" && params["duration[0]"] == "200" && params["trackNumber[0]"] == "1")
        #expect(params["timestamp[1]"] == "1700000200" && params["album[1]"] == nil)
        #expect(LastFMClient.formEncoded(["track": "Jóga & Co+", "artist": "Björk"]) == "artist=Bj%C3%B6rk&track=J%C3%B3ga%20%26%20Co%2B")
    }

    @Test func queueKeepsOnlyTheLastLoveOfASong() throws {
        let database = try LibraryDatabase.inMemory()
        try database.enqueueLastFM(LastFMQueueItem(kind: .love, artist: "A", track: "One", timestamp: .now))
        try database.enqueueLastFM(LastFMQueueItem(kind: .unlove, artist: "a", track: "one", timestamp: .now))
        try database.enqueueLastFM(LastFMQueueItem(kind: .scrobble, artist: "A", track: "One", timestamp: .now))
        let loves = try database.pendingLastFM(kinds: [.love, .unlove], limit: 10)
        #expect(loves.map(\.kind) == [.unlove])
        #expect(try database.writer.read { try LibraryDatabase.lastFMQueueCount($0) } == 2)
    }

    @Test func sendsTheQueueAndHandlesFailures() async throws {
        let database = try LibraryDatabase.inMemory()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<55 {
            try database.enqueueLastFM(LastFMQueueItem(kind: .scrobble, artist: "A", track: "Song \(index)", duration: 200,
                                                       timestamp: start.addingTimeInterval(Double(index) * 200)))
        }
        try database.enqueueLastFM(LastFMQueueItem(kind: .love, artist: "A", track: "Song 1", timestamp: .now))
        let sender = LastFMSender(database: database)
        let credentials = LastFMCredentials(apiKey: "KEY", secret: "SECRET")

        // Last.fm down: everything waits.
        let down = FakeLastFM { _ in (503, #"{"error": 11, "message": "Service Offline"}"#) }
        #expect(await sender.send(with: LastFMClient(credentials: credentials, sessionKey: "SK", fetcher: down)) == .postponed("Service Offline"))
        #expect(try database.pendingLastFM(kinds: [.scrobble, .love], limit: 100).count == 56)

        // Up: two batches (50 + 5) and the love, all signed with the session key.
        let up = FakeLastFM { params in
            switch params["method"] {
            case "track.scrobble":
                let count = params.keys.filter { $0.hasPrefix("artist[") }.count
                return (200, #"{"scrobbles": {"@attr": {"accepted": \#(count), "ignored": 0}}}"#)
            default: return (200, "{}")
            }
        }
        let outcome = await sender.send(with: LastFMClient(credentials: credentials, sessionKey: "SK", fetcher: up))
        #expect(outcome == .sent(scrobbles: 55, loves: 1, ignored: 0))
        #expect(try database.pendingLastFM(kinds: [.scrobble, .love], limit: 100).isEmpty)
        let calls = up.calls
        #expect(calls.map { $0["method"] } == ["track.scrobble", "track.scrobble", "track.love"])
        #expect(calls.allSatisfy { $0["sk"] == "SK" && $0["api_sig"]?.count == 32 })
        #expect(calls.first?.keys.filter { $0.hasPrefix("artist[") }.count == 50)

        // Session revoked: stop and ask to connect again; the scrobble waits.
        try database.enqueueLastFM(LastFMQueueItem(kind: .scrobble, artist: "A", track: "Later", timestamp: .now))
        let revoked = FakeLastFM { _ in (403, #"{"error": 9, "message": "Invalid session key"}"#) }
        #expect(await sender.send(with: LastFMClient(credentials: credentials, sessionKey: "SK", fetcher: revoked))
                == .needsReconnect("Invalid session key"))
        #expect(try database.pendingLastFM(kinds: [.scrobble], limit: 10).count == 1)

        // A song Last.fm keeps refusing (bad data) is dropped after a few tries; the others still go.
        try database.enqueueLastFM(LastFMQueueItem(kind: .scrobble, artist: "A", track: "Bad", timestamp: .now.addingTimeInterval(1)))
        let picky = FakeLastFM { params in
            if params.values.contains("Bad") { return (400, #"{"error": 6, "message": "Invalid parameters"}"#) }
            return (200, #"{"scrobbles": {"@attr": {"accepted": 1, "ignored": 0}}}"#)
        }
        let picked = await sender.send(with: LastFMClient(credentials: credentials, sessionKey: "SK", fetcher: picky))
        #expect(picked == .sent(scrobbles: 1, loves: 0, ignored: 0))
        #expect(try database.pendingLastFM(kinds: [.scrobble], limit: 10).isEmpty)
    }

    @Test func authenticationSteps() async throws {
        let fake = FakeLastFM { params in
            switch params["method"] {
            case "auth.getToken": (200, #"{"token": "TOK"}"#)
            case "auth.getSession" where params["token"] == "TOK": (200, #"{"session": {"name": "irwing", "key": "SESSION"}}"#)
            default: (400, #"{"error": 14, "message": "Unauthorized Token"}"#)
            }
        }
        let client = LastFMClient(credentials: LastFMCredentials(apiKey: "KEY", secret: "SECRET"), fetcher: fake)
        let token = try await client.getToken()
        #expect(client.authorizationURL(token: token).absoluteString == "https://www.last.fm/api/auth/?api_key=KEY&token=TOK")
        let session = try await client.getSession(token: token)
        #expect(session.name == "irwing" && session.key == "SESSION")
        await #expect(throws: LastFMError.api(code: 14, message: "Unauthorized Token")) { try await client.getSession(token: "OTHER") }
        #expect(LastFMError.api(code: 14, message: "").isUnauthorizedToken)
    }
}

/// Answers Last.fm requests from a closure and records each request's parameters.
private final class FakeLastFM: HTTPFetching, @unchecked Sendable {
    private let answer: @Sendable ([String: String]) -> (Int, String)
    private let lock = NSLock()
    private var recorded: [[String: String]] = []

    init(_ answer: @escaping @Sendable ([String: String]) -> (Int, String)) {
        self.answer = answer
    }

    var calls: [[String: String]] { lock.withLock { recorded } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let query = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? request.url?.query ?? ""
        var params: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if parts.count == 2 { params[parts[0]] = parts[1] }
        }
        lock.withLock { recorded.append(params) }
        let (status, body) = answer(params)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
