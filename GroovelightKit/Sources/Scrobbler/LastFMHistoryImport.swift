import Foundation
import GRDB
import LibraryKit

/// Song names as Last.fm and the library may spell them differently: case, accents, "feat." parts, bracketed notes
/// ("Remastered 2011", "Live") and punctuation are left out. Groovelight for Windows has the same rules (`SongKey`).
public enum SongKey {
    public static func key(artist: String, title: String) -> String {
        artistName(artist) + "\u{1}" + normalize(title)
    }

    public static func artistName(_ artist: String) -> String {
        var name = normalize(artist)
        if name.hasPrefix("the ") { name.removeFirst(4) }
        return name
    }

    public static func normalize(_ text: String) -> String {
        var value = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        value = value.replacing(#/\s*[(\[][^)\]]*[)\]]/#, with: "")
        value = value.replacing(#/\s+-\s+.*\b(remaster\w*|live|version|edit|mono|stereo|demo|mix)\b.*$/#, with: "")
        value = value.replacing(#/\s+(feat\.?|ft\.?|featuring)\s+.*$/#, with: "")
        value = value.replacing("&", with: " and ")
        value = value.replacing(#/[^\p{L}\p{N}]+/#, with: " ")
        return value.trimmingCharacters(in: .whitespaces)
    }
}

/// Brings the user's Last.fm history into the listening log (rows with source `lastfm`), oldest page first, so a stopped
/// import picks up where it left off. Plays Groovelight itself sent (a play here within 2 minutes of the scrobble) are not
/// counted twice. Songs not in the library keep their names (artist level stats still use them).
public struct LastFMHistoryImport: Sendable {
    public struct Progress: Sendable, Equatable {
        public var imported = 0
        public var matched = 0
        public var page = 0
        public var totalPages = 0
        public var total = 0
    }

    public let database: LibraryDatabase
    public let client: LastFMClient
    public let user: String
    /// Between pages (Last.fm asks for no more than about 5 calls a second; 1 a second stays well away from it).
    public var pause: Duration = .seconds(1)
    public var now: @Sendable () -> Date = { .now }

    public init(database: LibraryDatabase, client: LastFMClient, user: String) {
        self.database = database
        self.client = client
        self.user = user
    }

    public func run(progress: @Sendable (Progress) -> Void = { _ in }) async throws -> Progress {
        let newest = try await database.writer.read { db in
            try Date.fetchOne(db, sql: "SELECT MAX(startedAt) FROM listen WHERE source = ?", arguments: [Listen.Source.lastfm])
        }
        let from = newest.map { $0.addingTimeInterval(1) }
        let to = now()
        let first = try await page(1, from: from, to: to)
        var state = Progress(totalPages: first.totalPages, total: first.total)
        guard first.totalPages > 0, !first.plays.isEmpty else { return state }
        progress(state)

        let (library, local) = try await indexes(since: from)
        for number in stride(from: first.totalPages, through: 1, by: -1) {
            try Task.checkCancellation()
            let result = number == 1 ? first : try await page(number, from: from, to: to)
            let (imported, matched) = try await save(result.plays.reversed(), library: library, local: local)
            state.imported += imported
            state.matched += matched
            state.page = first.totalPages - number + 1
            progress(state)
            if number > 1 { try await Task.sleep(for: pause) }
        }
        return state
    }

    /// A page, tried again a few times when Last.fm is busy or the connection drops.
    private func page(_ number: Int, from: Date?, to: Date) async throws -> LastFMHistoryPage {
        var attempt = 0
        while true {
            do {
                return try await client.recentTracks(user: user, from: from, to: to, page: number)
            } catch let error as LastFMError where error.isTemporary && attempt < 3 {
                attempt += 1
                try await Task.sleep(for: pause * (5 * attempt))
            }
        }
    }

    struct Song: Sendable {
        var id: Int64
        var album: String
        var duration: Double
    }

    /// The library's songs by name, and the times of plays already in the log by name.
    private func indexes(since from: Date?) async throws -> (library: [String: [Song]], local: [String: [Date]]) {
        try await database.writer.read { db in
            var library: [String: [Song]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, artist, albumArtist, title, album, duration FROM track") {
                let title: String = row["title"]
                let song = Song(id: row["id"], album: SongKey.normalize(row["album"] ?? ""), duration: row["duration"])
                let artists = Set([row["artist"] as String?, row["albumArtist"] as String?].compactMap { $0 })
                for artist in artists {
                    library[SongKey.key(artist: artist, title: title), default: []].append(song)
                }
            }
            var local: [String: [Date]] = [:]
            let start = from.map { $0.addingTimeInterval(-600) } ?? .distantPast
            for row in try Row.fetchAll(db, sql: """
                SELECT artist, title, startedAt FROM listen WHERE source NOT IN (?, ?) AND startedAt >= ?
                """, arguments: [Listen.Source.lastfm, Listen.Source.summary, start]) {
                local[SongKey.key(artist: row["artist"], title: row["title"]), default: []].append(row["startedAt"])
            }
            return (library, local)
        }
    }

    private func save(_ plays: [LastFMPlay], library: [String: [Song]], local: [String: [Date]]) async throws -> (Int, Int) {
        try await database.writer.write { db in
            var imported = 0
            var matched = 0
            for play in plays {
                let key = SongKey.key(artist: play.artist, title: play.title)
                if local[key]?.contains(where: { abs($0.timeIntervalSince(play.date)) <= 120 }) == true { continue }
                let candidates = library[key] ?? []
                let album = SongKey.normalize(play.album)
                let song = candidates.first { $0.album == album } ?? candidates.first
                var listen = Listen(trackId: song?.id, startedAt: play.date, listened: song?.duration ?? 0, duration: song?.duration ?? 0,
                                    counted: true, skipped: false, source: Listen.Source.lastfm,
                                    artist: play.artist, title: play.title, album: play.album)
                try listen.insert(db)
                imported += 1
                if song != nil { matched += 1 }
            }
            return (imported, matched)
        }
    }
}
