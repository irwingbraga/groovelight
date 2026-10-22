import Foundation
import GRDB

/// A person (or group, or studio) credited in the library. Identified by their MusicBrainz artist id when known,
/// otherwise by name (studios, or credits without an id).
public struct CreditPerson: Hashable, Sendable, Codable {
    public var name: String
    public var artistId: String?

    public init(name: String, artistId: String?) {
        self.name = name
        self.artistId = artistId
    }
}

/// One credit of a person on an album (`trackId` nil: anywhere on the album) or on one song.
public struct CreditIndexEntry: Hashable, Sendable {
    public var person: CreditPerson
    public var albumKey: String
    public var trackId: Int64?
    public var roles: [String]
    /// Credited on the release itself (mastering, design...): applies to every song of the album.
    public var wholeRelease: Bool

    public init(person: CreditPerson, albumKey: String, trackId: Int64?, roles: [String], wholeRelease: Bool = false) {
        self.person = person
        self.albumKey = albumKey
        self.trackId = trackId
        self.roles = roles
        self.wholeRelease = wholeRelease
    }
}

/// What a person did in the library: albums and songs with their roles there.
public struct PersonCredits: Sendable {
    public var person: CreditPerson
    public var albums: [(album: AlbumSummary, roles: [String])]
    public var tracks: [(track: Track, roles: [String])]
    /// Every role, most frequent first.
    public var roles: [String]
}

extension LibraryDatabase {
    /// Replaces the credits indexed for an album.
    public func setCredits(_ entries: [CreditIndexEntry], albumKey: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM creditIndex WHERE albumKey = ?", arguments: [albumKey])
            for entry in entries {
                try db.execute(sql: """
                    INSERT INTO creditIndex (name, nameKey, artistId, albumKey, trackId, roles, wholeRelease) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [entry.person.name, entry.person.name.lowercased(), entry.person.artistId, entry.albumKey,
                                     entry.trackId, entry.roles.joined(separator: "\n"), entry.wholeRelease])
            }
        }
    }

    /// Every cached album info (album key and JSON), to rebuild the index.
    public static func allAlbumInfo(_ db: Database) throws -> [(albumKey: String, data: Data)] {
        try Row.fetchAll(db, sql: "SELECT albumKey, data FROM albumInfo").map { ($0["albumKey"], $0["data"]) }
    }

    /// Every cached artist info (lowercased name and JSON).
    public static func allArtistInfo(_ db: Database) throws -> [(artistKey: String, data: Data)] {
        try Row.fetchAll(db, sql: "SELECT artistKey, data FROM artistInfo").map { ($0["artistKey"], $0["data"]) }
    }

    /// The photos known for these artists (in the artwork cache), by name as given: matched without case, as the
    /// artist info is kept.
    public static func artistPhotos(_ db: Database, names: some Sequence<String>) throws -> [String: String] {
        let wanted = Dictionary(names.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        guard !wanted.isEmpty else { return [:] }
        var photos: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT artistKey, data FROM artistInfo") {
            guard let name = wanted[row["artistKey"] as String],
                  let hash = try? JSONDecoder().decode(ArtistPhoto.self, from: row["data"] as Data).imageHash else { continue }
            photos[name] = hash
        }
        return photos
    }

    /// Albums (with a title) whose credits were never looked up.
    public static func albumKeysWithoutInfo(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT DISTINCT albumKey FROM track WHERE albumKey NOT IN (SELECT albumKey FROM albumInfo) AND COALESCE(album, '') != ''
            """)
    }

    /// Library artists (album artists of non-compilations) whose background was never looked up.
    public static func artistNamesWithoutInfo(_ db: Database) throws -> [String] {
        let known = Set(try String.fetchAll(db, sql: "SELECT artistKey FROM artistInfo"))
        return try artists(db).map(\.name).filter { name in
            !["unknown artist", "various artists"].contains(name.lowercased()) && !known.contains(name.lowercased())
        }
    }

    /// Songs without lyrics (from the file or online) whose online lookup never ran.
    public static func trackIdsNeedingLyrics(_ db: Database) throws -> [Int64] {
        try Int64.fetchAll(db, sql: """
            SELECT id FROM track WHERE COALESCE(lyrics, '') = '' AND COALESCE(fetchedLyrics, '') = '' AND lyricsCheckedAt IS NULL
            ORDER BY dateAdded DESC
            """)
    }

    public static func creditIndexCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM creditIndex") ?? 0
    }

    /// Albums whose credits are known (fetched), and all albums, for "credits known for N of M albums".
    public static func creditCoverage(_ db: Database) throws -> (known: Int, total: Int) {
        let known = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM albumInfo WHERE albumKey IN (SELECT DISTINCT albumKey FROM track)") ?? 0
        let total = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT albumKey) FROM track") ?? 0
        return (known, total)
    }

    /// Everything a person is credited on. Songs: the ones credited to them, plus every song of albums where they are
    /// credited on the release itself (mastering, design...). Someone credited only on songs that are not in the library
    /// shows the album without songs.
    public static func credits(_ db: Database, person: CreditPerson) throws -> PersonCredits {
        let rows: [Row]
        if let artistId = person.artistId {
            rows = try Row.fetchAll(db, sql: "SELECT * FROM creditIndex WHERE artistId = ?", arguments: [artistId])
        } else {
            rows = try Row.fetchAll(db, sql: "SELECT * FROM creditIndex WHERE artistId IS NULL AND nameKey = ?",
                                    arguments: [person.name.lowercased()])
        }
        func roles(_ row: Row) -> [String] { (row["roles"] as String).split(separator: "\n").map(String.init) }

        var albumRoles: [String: [String]] = [:]
        var trackRoles: [Int64: [String]] = [:]
        var albumsWithTrackCredits = Set<String>()
        var wholeReleaseAlbums = Set<String>()
        var roleCounts: [String: Int] = [:]
        for row in rows {
            let key: String = row["albumKey"]
            let list = roles(row)
            if let trackId: Int64 = row["trackId"] {
                trackRoles[trackId, default: []].append(contentsOf: list.filter { !(trackRoles[trackId] ?? []).contains($0) })
                albumsWithTrackCredits.insert(key)
            } else {
                if row["wholeRelease"] as Bool { wholeReleaseAlbums.insert(key) }
                albumRoles[key, default: []].append(contentsOf: list.filter { !(albumRoles[key] ?? []).contains($0) })
                for role in list { roleCounts[role, default: 0] += 1 }
            }
        }

        let albums = try Self.albums(db, sort: .year).filter { albumRoles[$0.albumKey] != nil || albumsWithTrackCredits.contains($0.albumKey) }
        var tracks: [(track: Track, roles: [String])] = []
        for album in albums {
            let albumTracks = try Self.tracks(db, albumKey: album.albumKey)
            if wholeReleaseAlbums.contains(album.albumKey) {
                // Release credits apply to every song, alongside any song-specific roles.
                tracks += albumTracks.map { track in
                    let own = track.id.flatMap { trackRoles[$0] } ?? []
                    return (track, own.isEmpty ? (albumRoles[album.albumKey] ?? []) : own)
                }
            } else {
                tracks += albumTracks.compactMap { track in track.id.flatMap { trackRoles[$0] }.map { (track, $0) } }
            }
        }
        let sortedRoles = roleCounts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
        return PersonCredits(person: person, albums: albums.map { ($0, albumRoles[$0.albumKey] ?? []) }, tracks: tracks, roles: sortedRoles)
    }
}

/// The photo in a cached artist info (MetadataKit's `ArtistInfo`, which this package does not see).
private struct ArtistPhoto: Decodable { var imageHash: String? }
