import Foundation
import GRDB

/// Everything in the library matching a search, by category.
public struct LibrarySearchResults: Sendable {
    public var artists: [ArtistSummary] = []
    public var albums: [AlbumSummary] = []
    public var songs: [Track] = []
    /// People from the album credits (musicians, producers, engineers, studios) who are not library artists.
    public var people: [CreditedPerson] = []

    public init() {}

    public var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty && people.isEmpty }
}

/// A person from the credits matching a search, with what they did.
public struct CreditedPerson: Hashable, Sendable, Identifiable {
    public var person: CreditPerson
    /// Their roles, most frequent first.
    public var roles: [String]
    public var albumCount: Int

    public var id: String { person.artistId ?? "name:" + person.name.lowercased() }
}

/// Word prefix matching that ignores case, accents and punctuation: every word of the query must start a word of the
/// text ("beat yel" matches "Yellow Submarine" by "The Beatles", "acdc" does not match "AC/DC" but "ac dc" does).
public struct SearchMatcher: Sendable {
    public let words: [String]
    private let phrase: String

    public init(_ query: String) {
        words = Self.words(query)
        phrase = words.joined(separator: " ")
    }

    public var isEmpty: Bool { words.isEmpty }

    /// Lower is better: 0 exact, 1 the text starts with the query, 2 every query word starts a word of the text. Nil when
    /// some query word matches nothing.
    public func score(_ text: String) -> Int? {
        let textWords = Self.words(text)
        guard !words.isEmpty, words.allSatisfy({ word in textWords.contains { $0.hasPrefix(word) } }) else { return nil }
        let joined = textWords.joined(separator: " ")
        if joined == phrase { return 0 }
        if joined.hasPrefix(phrase) { return 1 }
        return 2
    }

    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}

extension LibraryDatabase {
    /// Artists, albums, songs and credited people matching `query`, best matches first in each category.
    public static func search(_ db: Database, query: String, limit: Int = 300) throws -> LibrarySearchResults {
        let matcher = SearchMatcher(query)
        guard !matcher.isEmpty else { return LibrarySearchResults() }
        var results = LibrarySearchResults()

        results.artists = ranked(try artists(db), limit: limit) { matcher.score($0.name) }

        // Albums by title first, then albums of a matching artist.
        results.albums = ranked(try albums(db, sort: .artist), limit: limit) { album in
            matcher.score(album.title) ?? matcher.score(album.title + " " + album.artist).map { $0 + 3 }
        }

        results.songs = try searchSongs(db, matcher: matcher, limit: limit)

        let artistNames = Set(results.artists.map { $0.name.lowercased() })
        results.people = ranked(try creditedPeople(db), limit: limit) { person in
            artistNames.contains(person.person.name.lowercased()) ? nil : matcher.score(person.person.name)
        }
        return results
    }

    /// Songs by full-text search, a title match weighing most.
    private static func searchSongs(_ db: Database, matcher: SearchMatcher, limit: Int) throws -> [Track] {
        let pattern = matcher.words.map { "\"\($0)\"*" }.joined(separator: " ")
        // Columns: title, artist, album, albumArtist, composer, genre.
        return try Track.fetchAll(db, sql: """
            SELECT track.* FROM track
            JOIN track_ft ON track_ft.rowid = track.id AND track_ft MATCH ?
            ORDER BY bm25(track_ft, 10.0, 4.0, 3.0, 3.0, 2.0, 1.0)
            LIMIT ?
            """, arguments: [pattern, limit])
    }

    /// Everyone in the credits, one entry per person (by MusicBrainz id, or by name without one).
    private static func creditedPeople(_ db: Database) throws -> [CreditedPerson] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT MIN(name) AS name, artistId, COUNT(DISTINCT albumKey) AS albumCount, GROUP_CONCAT(roles, char(10)) AS roles
            FROM creditIndex
            GROUP BY COALESCE(artistId, 'name:' || nameKey)
            """)
        return rows.map { row in
            var counts: [String: Int] = [:]
            for role in ((row["roles"] as String?) ?? "").split(separator: "\n") { counts[String(role), default: 0] += 1 }
            let roles = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
            return CreditedPerson(person: CreditPerson(name: row["name"], artistId: row["artistId"]), roles: roles,
                                  albumCount: row["albumCount"])
        }
    }

    /// The items that match, best score first (ties keep their order), at most `limit`.
    private static func ranked<T>(_ items: [T], limit: Int, score: (T) -> Int?) -> [T] {
        var matches: [(item: T, score: Int, index: Int)] = []
        for (index, item) in items.enumerated() {
            if let value = score(item) { matches.append((item, value, index)) }
        }
        matches.sort { $0.score != $1.score ? $0.score < $1.score : $0.index < $1.index }
        return matches.prefix(limit).map(\.item)
    }
}
