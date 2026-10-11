import Foundation

// MARK: - Models (the subset of the MusicBrainz JSON web service that Groovelight uses)

public struct MBArtistCredit: Codable, Hashable, Sendable {
    public struct Artist: Codable, Hashable, Sendable {
        public var id: String
        public var name: String
    }

    public var name: String
    public var joinphrase: String?
    public var artist: Artist
}

extension [MBArtistCredit] {
    /// "Artist A feat. Artist B", as credited.
    public var displayName: String {
        map { $0.name + ($0.joinphrase ?? "") }.joined()
    }

    public var isVariousArtists: Bool {
        // The special "Various Artists" artist.
        contains { $0.artist.id == "89ad4ac3-39f7-470e-963a-56509c546377" }
    }
}

public struct MBGenre: Codable, Hashable, Sendable {
    public var name: String
    public var count: Int?
}

public struct MBReleaseGroup: Codable, Hashable, Sendable {
    public var id: String
    public var title: String?
    public var primaryType: String?
    public var secondaryTypes: [String]?
    public var firstReleaseDate: String?
    public var genres: [MBGenre]?
    public var relations: [MBRelation]?

    public init(id: String, title: String? = nil, primaryType: String? = nil, secondaryTypes: [String]? = nil,
                firstReleaseDate: String? = nil, genres: [MBGenre]? = nil) {
        self.id = id
        self.title = title
        self.primaryType = primaryType
        self.secondaryTypes = secondaryTypes
        self.firstReleaseDate = firstReleaseDate
        self.genres = genres
    }

    enum CodingKeys: String, CodingKey {
        case id, title, genres, relations
        case primaryType = "primary-type"
        case secondaryTypes = "secondary-types"
        case firstReleaseDate = "first-release-date"
    }
}

public struct MBRecordingRef: Codable, Hashable, Sendable {
    public var id: String
    public var title: String?
    public var genres: [MBGenre]?
    /// Credits of the recording (performers, production) and its works (songwriting), when requested.
    public var relations: [MBRelation]?
}

public struct MBTrack: Codable, Hashable, Sendable {
    public var id: String
    public var number: String?
    public var position: Int?
    public var title: String
    /// Milliseconds.
    public var length: Int?
    public var artistCredit: [MBArtistCredit]?
    public var recording: MBRecordingRef?

    enum CodingKeys: String, CodingKey {
        case id, number, position, title, length, recording
        case artistCredit = "artist-credit"
    }
}

public struct MBMedium: Codable, Hashable, Sendable {
    public var position: Int?
    public var format: String?
    public var trackCount: Int?
    /// Present on release lookups (`tracks`) and on recording search results (`track`).
    public var tracks: [MBTrack]?
    public var track: [MBTrack]?

    enum CodingKeys: String, CodingKey {
        case position, format, tracks, track
        case trackCount = "track-count"
    }

    public var allTracks: [MBTrack] { tracks ?? track ?? [] }
}

public struct MBRelease: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// Search relevance (0 to 100), only on search results.
    public var score: Int?
    public var status: String?
    public var date: String?
    public var country: String?
    public var trackCount: Int?
    public var artistCredit: [MBArtistCredit]?
    public var releaseGroup: MBReleaseGroup?
    public var media: [MBMedium]?
    public var genres: [MBGenre]?
    /// Release-level credits (producer, mastering, design...), when requested.
    public var relations: [MBRelation]?

    public init(id: String, title: String, score: Int? = nil, status: String? = nil, date: String? = nil, country: String? = nil,
                trackCount: Int? = nil, artistCredit: [MBArtistCredit]? = nil, releaseGroup: MBReleaseGroup? = nil,
                media: [MBMedium]? = nil, genres: [MBGenre]? = nil) {
        self.id = id
        self.title = title
        self.score = score
        self.status = status
        self.date = date
        self.country = country
        self.trackCount = trackCount
        self.artistCredit = artistCredit
        self.releaseGroup = releaseGroup
        self.media = media
        self.genres = genres
    }

    enum CodingKeys: String, CodingKey {
        case id, title, score, status, date, country, media, genres, relations
        case trackCount = "track-count"
        case artistCredit = "artist-credit"
        case releaseGroup = "release-group"
    }

    /// Original year of the album (its release group's first release), then this edition's date: a 2009 reissue of
    /// a 1997 album is filed under 1997.
    public var year: Int? { Self.year(from: releaseGroup?.firstReleaseDate) ?? Self.year(from: date) }
    public var artistName: String { artistCredit?.displayName ?? "" }
    public var totalTracks: Int { trackCount ?? media?.reduce(0) { $0 + ($1.trackCount ?? $1.allTracks.count) } ?? 0 }

    /// Most voted genre of the release, then of its release group, title cased ("alternative rock" to "Alternative Rock").
    public var primaryGenre: String? {
        let genres = (genres?.isEmpty == false ? genres : releaseGroup?.genres) ?? []
        return genres.max { ($0.count ?? 0) < ($1.count ?? 0) }?.name.capitalized
    }

    static func year(from date: String?) -> Int? {
        guard let date, date.count >= 4, let year = Int(date.prefix(4)) else { return nil }
        return year
    }
}

public struct MBRecording: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var score: Int?
    public var length: Int?
    public var artistCredit: [MBArtistCredit]?
    public var releases: [MBRelease]?

    enum CodingKeys: String, CodingKey {
        case id, title, score, length, releases
        case artistCredit = "artist-credit"
    }
}

struct MBReleaseSearch: Codable { var releases: [MBRelease] }
struct MBRecordingSearch: Codable { var recordings: [MBRecording] }

// MARK: - Client

/// MusicBrainz web service client, rate limited to one request per second as the service requires.
public final class MusicBrainzClient: Sendable {
    private let fetcher: any HTTPFetching
    private let identity: ClientIdentity
    private let limiter: RateLimiter
    private let baseURL = "https://musicbrainz.org/ws/2"

    public init(fetcher: any HTTPFetching = URLSessionFetcher(), identity: ClientIdentity,
                limiter: RateLimiter = RateLimiter(interval: .milliseconds(1100))) {
        self.fetcher = fetcher
        self.identity = identity
        self.limiter = limiter
    }

    /// Releases matching an album title and artist, best first.
    public func searchReleases(album: String, artist: String?, limit: Int = 10) async throws -> [MBRelease] {
        var query = "release:(\(Self.escape(album)))"
        if let artist, !artist.isEmpty { query += " AND artist:(\(Self.escape(artist)))" }
        let data = try await get("release", ["query": query, "limit": String(limit)])
        return try JSONDecoder().decode(MBReleaseSearch.self, from: data).releases
    }

    /// Recordings matching a title and (optional) artist, each listing the releases it appears on. With
    /// `officialAlbumsOnly`, only official album releases are searched (skipping the many live bootlegs of a song).
    public func searchRecordings(title: String, artist: String?, officialAlbumsOnly: Bool = false,
                                 limit: Int = 25) async throws -> [MBRecording] {
        var query = "recording:(\(Self.escape(title)))"
        if let artist, !artist.isEmpty { query += " AND artist:(\(Self.escape(artist)))" }
        if officialAlbumsOnly { query += " AND status:official AND primarytype:album" }
        let data = try await get("recording", ["query": query, "limit": String(limit)])
        return try JSONDecoder().decode(MBRecordingSearch.self, from: data).recordings
    }

    /// Full release with its tracklist, artist credits, release group and genres.
    public func release(id: String) async throws -> MBRelease {
        let data = try await get("release/\(id)", ["inc": "recordings artist-credits release-groups genres"])
        return try JSONDecoder().decode(MBRelease.self, from: data)
    }

    /// Release with its tracklist and every credit: release, recording and work relationships (performers with their
    /// instruments, production, songwriting, studios).
    public func releaseWithCredits(id: String) async throws -> MBRelease {
        let data = try await get("release/\(id)", [
            "inc": "recordings artist-credits artist-rels recording-level-rels work-rels work-level-rels place-rels release-groups",
        ])
        return try JSONDecoder().decode(MBRelease.self, from: data)
    }

    /// Artists matching a name, best first.
    public func searchArtists(name: String, limit: Int = 5) async throws -> [MBArtist] {
        let data = try await get("artist", ["query": "artist:(\(Self.escape(name)))", "limit": String(limit)])
        return try JSONDecoder().decode(MBArtistSearch.self, from: data).artists
    }

    /// Wikidata item id of an artist, from its URL relationships.
    public func wikidataId(artistId: String) async throws -> String? {
        let data = try await get("artist/\(artistId)", ["inc": "url-rels"])
        let artist = try JSONDecoder().decode(MBArtist.self, from: data)
        return Self.wikidataId(in: artist.relations)
    }

    static func wikidataId(in relations: [MBRelation]?) -> String? {
        let link = relations?.first { $0.type == "wikidata" }?.url?.resource
        return link.flatMap { URL(string: $0)?.lastPathComponent }.flatMap { $0.hasPrefix("Q") ? $0 : nil }
    }

    /// Wikidata item id ("Q202996") of a release group, from its URL relationships.
    public func wikidataId(releaseGroupId: String) async throws -> String? {
        let data = try await get("release-group/\(releaseGroupId)", ["inc": "url-rels"])
        let group = try JSONDecoder().decode(MBReleaseGroup.self, from: data)
        return Self.wikidataId(in: group.relations)
    }

    private func get(_ path: String, _ items: [String: String?]) async throws -> Data {
        var items = items
        items["fmt"] = "json"
        return try await fetcher.get(.build("\(baseURL)/\(path)", items), identity: identity, limiter: limiter)
    }

    /// Escapes Lucene special characters in a search term.
    static func escape(_ term: String) -> String {
        let special = Set(#"+-&|!(){}[]^"~*?:\/"#)
        var result = ""
        for character in term {
            if special.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
