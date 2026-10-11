import Foundation
import GRDB
@_exported import class GRDB.Database

/// SQLite library store (GRDB). Safe to share across threads.
public final class LibraryDatabase: Sendable {
    public let writer: any DatabaseWriter

    /// Opens (or creates) the database at `url`.
    public convenience init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try self.init(writer: DatabasePool(path: url.path, configuration: Self.configuration))
    }

    /// In-memory database, for tests and previews.
    public static func inMemory() throws -> LibraryDatabase {
        try LibraryDatabase(writer: DatabaseQueue(configuration: configuration))
    }

    static var configuration: Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            // Used by smart playlist "Quality" rules.
            db.add(function: SmartPlaylistSQL.qualityTierFunction)
        }
        return config
    }

    init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: LibraryRoot.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique()
                t.column("bookmark", .blob).notNull()
                t.column("addedAt", .datetime).notNull()
                t.column("lastScanAt", .datetime)
            }

            try db.create(table: Track.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("rootId", .integer).notNull().indexed().references(LibraryRoot.databaseTableName, onDelete: .cascade)
                t.column("path", .text).notNull().unique()
                t.column("fileSize", .integer).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("title", .text).notNull()
                t.column("artist", .text)
                t.column("album", .text)
                t.column("albumArtist", .text)
                t.column("composer", .text)
                t.column("genre", .text)
                t.column("year", .integer)
                t.column("trackNumber", .integer)
                t.column("trackTotal", .integer)
                t.column("discNumber", .integer)
                t.column("discTotal", .integer)
                t.column("isCompilation", .boolean).notNull().defaults(to: false)
                t.column("bpm", .integer)
                t.column("comment", .text)
                t.column("lyrics", .text)
                t.column("musicBrainzRecordingId", .text)
                t.column("musicBrainzReleaseId", .text)
                t.column("replayGainTrackGain", .double)
                t.column("replayGainAlbumGain", .double)
                t.column("duration", .double).notNull()
                t.column("format", .text)
                t.column("sampleRate", .double)
                t.column("bitDepth", .integer)
                t.column("bitrate", .double)
                t.column("channels", .integer)
                t.column("artworkHash", .text)
                t.column("albumKey", .text).notNull().indexed()
                t.column("rating", .integer).notNull().defaults(to: 0)
                t.column("isLoved", .boolean).notNull().defaults(to: false)
                t.column("playCount", .integer).notNull().defaults(to: 0)
                t.column("skipCount", .integer).notNull().defaults(to: 0)
                t.column("lastPlayedAt", .datetime)
                t.column("dateAdded", .datetime).notNull().indexed()
            }
            try db.create(index: "track_on_artist", on: Track.databaseTableName, columns: ["artist"])
            try db.create(index: "track_on_albumArtist", on: Track.databaseTableName, columns: ["albumArtist"])

            try db.create(virtualTable: "track_ft", using: FTS5()) { t in
                t.synchronize(withTable: Track.databaseTableName)
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("title")
                t.column("artist")
                t.column("album")
                t.column("albumArtist")
                t.column("composer")
                t.column("genre")
            }

            try db.create(table: Playlist.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("smartRules", .blob)
            }

            try db.create(table: PlaylistItem.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo(Playlist.databaseTableName, onDelete: .cascade).notNull()
                t.belongsTo(Track.databaseTableName, onDelete: .cascade).notNull()
                t.column("position", .integer).notNull()
            }
        }
        migrator.registerMigration("v2-metadata") { db in
            try db.alter(table: Track.databaseTableName) { t in
                t.add(column: "metadataOverrides", .blob)
                t.add(column: "fetchedLyrics", .text)
                t.add(column: "lyricsCheckedAt", .datetime)
                t.add(column: "fetchedArtworkHash", .text)
            }
        }
        migrator.registerMigration("v3-lovedAt") { db in
            try db.alter(table: Track.databaseTableName) { t in
                t.add(column: "lovedAt", .datetime)
            }
        }
        migrator.registerMigration("v4-playlistCover") { db in
            try db.alter(table: Playlist.databaseTableName) { t in
                t.add(column: "cover", .blob)
            }
        }
        migrator.registerMigration("v5-albumInfo") { db in
            // Credits and background fetched online per album (JSON decoded by MetadataKit).
            try db.create(table: "albumInfo") { t in
                t.primaryKey("albumKey", .text)
                t.column("data", .blob).notNull()
                t.column("fetchedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v6-artistInfo") { db in
            // Background fetched online per artist (keyed by the lowercased name, JSON decoded by MetadataKit).
            try db.create(table: "artistInfo") { t in
                t.primaryKey("artistKey", .text)
                t.column("data", .blob).notNull()
                t.column("fetchedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v7-creditIndex") { db in
            // Who is credited on which album and song, from the fetched album credits (for person pages).
            try db.create(table: "creditIndex") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("nameKey", .text).notNull().indexed()
                t.column("artistId", .text).indexed()
                t.column("albumKey", .text).notNull().indexed()
                t.column("trackId", .integer)
                t.column("roles", .text).notNull()
                t.column("wholeRelease", .boolean).notNull().defaults(to: false)
            }
        }
        migrator.registerMigration("v8-cueTracks") { db in
            try db.alter(table: Track.databaseTableName) { t in
                t.add(column: "audioPath", .text)
                t.add(column: "startTime", .double)
                t.add(column: "endTime", .double)
            }
        }
        return migrator
    }

    /// Async sequence of values that re-emits whenever the tables read by `fetch` change.
    public func observe<T: Sendable>(_ fetch: @escaping @Sendable (Database) throws -> T) -> AsyncValueObservation<T> {
        ValueObservation.tracking(fetch).values(in: writer, scheduling: .async(onQueue: .main))
    }
}

// MARK: - Queries

public enum AlbumSort: String, CaseIterable, Sendable {
    case artist, title, year, recentlyAdded
}

extension LibraryDatabase {
    static let albumArtistSQL = """
        CASE WHEN MAX(isCompilation) THEN 'Various Artists'
             ELSE COALESCE(NULLIF(MAX(albumArtist), ''), NULLIF(MAX(artist), ''), 'Unknown Artist') END
        """
    static let artistNameSQL = "COALESCE(NULLIF(TRIM(albumArtist), ''), NULLIF(TRIM(artist), ''), 'Unknown Artist')"

    public static func albums(_ db: Database, sort: AlbumSort = .artist, artist: String? = nil) throws -> [AlbumSummary] {
        let order = switch sort {
        case .artist: "artist COLLATE NOCASE, year, title COLLATE NOCASE"
        case .title: "title COLLATE NOCASE"
        case .year: "year DESC, artist COLLATE NOCASE"
        case .recentlyAdded: "dateAdded DESC"
        }
        var arguments: StatementArguments = []
        var filter = ""
        if let artist {
            filter = "WHERE isCompilation = 0 AND \(artistNameSQL) = ? COLLATE NOCASE"
            arguments = [artist]
        }
        return try AlbumSummary.fetchAll(db, sql: """
            SELECT albumKey,
                   COALESCE(NULLIF(MAX(album), ''), 'Unknown Album') AS title,
                   \(albumArtistSQL) AS artist,
                   MAX(year) AS year,
                   MAX(genre) AS genre,
                   COUNT(*) AS trackCount,
                   SUM(duration) AS duration,
                   MAX(artworkHash) AS artworkHash,
                   MIN(dateAdded) AS dateAdded
            FROM track \(filter)
            GROUP BY albumKey
            ORDER BY \(order)
            """, arguments: arguments)
    }

    public static func recentlyAddedAlbums(_ db: Database, limit: Int = 60) throws -> [AlbumSummary] {
        Array(try albums(db, sort: .recentlyAdded).prefix(limit))
    }

    public static func artists(_ db: Database) throws -> [ArtistSummary] {
        try ArtistSummary.fetchAll(db, sql: """
            SELECT \(artistNameSQL) AS name,
                   COUNT(DISTINCT albumKey) AS albumCount,
                   COUNT(*) AS trackCount,
                   MAX(artworkHash) AS artworkHash
            FROM track
            WHERE isCompilation = 0
            GROUP BY \(artistNameSQL) COLLATE NOCASE
            ORDER BY name COLLATE NOCASE
            """)
    }

    public static func genres(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT DISTINCT TRIM(genre) AS g FROM track WHERE genre IS NOT NULL AND TRIM(genre) != ''
            ORDER BY g COLLATE NOCASE
            """)
    }

    public static func tracks(_ db: Database, albumKey: String) throws -> [Track] {
        try Track.filter(Column("albumKey") == albumKey)
            .order(Column("discNumber"), Column("trackNumber"), Column("title").collating(.nocase))
            .fetchAll(db)
    }

    public static func tracks(_ db: Database, artist: String) throws -> [Track] {
        try Track.fetchAll(db, sql: """
            SELECT * FROM track WHERE \(artistNameSQL) = ? COLLATE NOCASE OR artist = ? COLLATE NOCASE
            ORDER BY year, album COLLATE NOCASE, discNumber, trackNumber
            """, arguments: [artist, artist])
    }

    public static func tracks(_ db: Database, genre: String) throws -> [Track] {
        try Track.filter(sql: "TRIM(genre) = ? COLLATE NOCASE", arguments: [genre])
            .order(Column("artist").collating(.nocase), Column("album").collating(.nocase), Column("discNumber"), Column("trackNumber"))
            .fetchAll(db)
    }

    public static func allTracks(_ db: Database) throws -> [Track] {
        try Track.order(Column("title").collating(.nocase)).fetchAll(db)
    }

    /// Full-text search with prefix matching on every word ("beat yel" finds "Yellow Submarine" by The Beatles).
    public static func search(_ db: Database, query: String, limit: Int = 300) throws -> [Track] {
        let words = query.split(whereSeparator: \.isWhitespace)
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        let pattern = words.map { "\"\($0)\"*" }.joined(separator: " ")
        return try Track.fetchAll(db, sql: """
            SELECT track.* FROM track
            JOIN track_ft ON track_ft.rowid = track.id AND track_ft MATCH ?
            ORDER BY rank
            LIMIT ?
            """, arguments: [pattern, limit])
    }

    public static func playlists(_ db: Database) throws -> [Playlist] {
        try Playlist.order(Column("name").collating(.nocase)).fetchAll(db)
    }

    /// Songs of a playlist: its items in order, or for a smart playlist the songs matching its rules.
    public static func tracks(_ db: Database, playlistId: Int64) throws -> [Track] {
        if let playlist = try Playlist.fetchOne(db, key: playlistId), let rules = playlist.rules {
            return try tracks(db, rules: rules)
        }
        return try Track.fetchAll(db, sql: """
            SELECT track.* FROM playlistItem JOIN track ON track.id = playlistItem.trackId
            WHERE playlistItem.playlistId = ? ORDER BY playlistItem.position
            """, arguments: [playlistId])
    }

    /// Loved Songs: most recently loved first (songs loved before dates were kept come last, by artist and album).
    public static func lovedTracks(_ db: Database) throws -> [Track] {
        try Track.fetchAll(db, sql: """
            SELECT * FROM track WHERE isLoved = 1
            ORDER BY lovedAt IS NULL, lovedAt DESC, \(artistNameSQL) COLLATE NOCASE, album COLLATE NOCASE, discNumber, trackNumber
            """)
    }

    /// Loved Songs and every playlist with its count, length and covers (for the All Playlists grid).
    public static func playlistOverview(_ db: Database) throws -> PlaylistOverview {
        func covers(_ tracks: [Track]) -> [String] {
            var seen = Set<String>()
            return tracks.compactMap(\.artworkHash).filter { seen.insert($0).inserted }.prefix(4).map { $0 }
        }
        let loved = try lovedTracks(db)
        let summaries = try playlists(db).map { playlist in
            let tracks = try playlist.id.map { try Self.tracks(db, playlistId: $0) } ?? []
            return PlaylistSummary(playlist: playlist, trackCount: tracks.count, duration: tracks.reduce(0) { $0 + $1.duration },
                                   artworkHashes: covers(tracks))
        }
        return PlaylistOverview(lovedCount: loved.count, lovedDuration: loved.reduce(0) { $0 + $1.duration },
                                lovedArtworkHashes: covers(loved), playlists: summaries)
    }

    public static func roots(_ db: Database) throws -> [LibraryRoot] {
        try LibraryRoot.order(Column("path")).fetchAll(db)
    }
}

// MARK: - Mutations

extension LibraryDatabase {
    public func createPlaylist(named name: String, trackIds: [Int64] = [], cover: PlaylistCover? = nil) throws -> Playlist {
        try writer.write { db in
            var playlist = Playlist(name: name, cover: cover)
            try playlist.insert(db)
            try Self.append(db, trackIds: trackIds, to: playlist.id!)
            return playlist
        }
    }

    public func addTracks(_ trackIds: [Int64], toPlaylist playlistId: Int64) throws {
        try writer.write { db in try Self.append(db, trackIds: trackIds, to: playlistId) }
    }

    public func renamePlaylist(_ playlistId: Int64, to name: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE playlist SET name = ? WHERE id = ?", arguments: [name, playlistId])
        }
    }

    /// Renames a playlist and sets its cover (nil shows the songs' covers).
    public func updatePlaylist(_ playlistId: Int64, name: String, cover: PlaylistCover?) throws {
        let data = try cover.map { try JSONEncoder().encode($0) }
        try writer.write { db in
            try db.execute(sql: "UPDATE playlist SET name = ?, cover = ? WHERE id = ?", arguments: [name, data, playlistId])
        }
    }

    public func deletePlaylist(_ playlistId: Int64) throws {
        _ = try writer.write { db in try Playlist.deleteOne(db, key: playlistId) }
    }

    /// Rewrites the playlist order to exactly `trackIds`.
    public func setPlaylistTracks(_ playlistId: Int64, trackIds: [Int64]) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM playlistItem WHERE playlistId = ?", arguments: [playlistId])
            try Self.append(db, trackIds: trackIds, to: playlistId)
        }
    }

    private static func append(_ db: Database, trackIds: [Int64], to playlistId: Int64) throws {
        let start = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position) + 1, 0) FROM playlistItem WHERE playlistId = ?",
                                     arguments: [playlistId]) ?? 0
        for (offset, trackId) in trackIds.enumerated() {
            var item = PlaylistItem(playlistId: playlistId, trackId: trackId, position: start + offset)
            try item.insert(db)
        }
    }

    public func recordPlay(trackId: Int64, at date: Date = .now) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE track SET playCount = playCount + 1, lastPlayedAt = ? WHERE id = ?", arguments: [date, trackId])
        }
    }

    public func recordSkip(trackId: Int64) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE track SET skipCount = skipCount + 1 WHERE id = ?", arguments: [trackId])
        }
    }

    public func setLoved(_ loved: Bool, trackId: Int64, at date: Date = .now) throws {
        try setLoved(loved, trackIds: [trackId], at: date)
    }

    public func setLoved(_ loved: Bool, trackIds: [Int64], at date: Date = .now) throws {
        try writer.write { db in
            for id in trackIds {
                // Loving an already loved song keeps its original date.
                try db.execute(sql: """
                    UPDATE track SET lovedAt = CASE WHEN ? THEN COALESCE(CASE WHEN isLoved THEN lovedAt END, ?) END, isLoved = ?
                    WHERE id = ?
                    """, arguments: [loved, date, loved, id])
            }
        }
    }

    public func setRating(_ rating: Int, trackId: Int64) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE track SET rating = ? WHERE id = ?", arguments: [min(max(rating, 0), 5), trackId])
        }
    }

    public func addRoot(path: String, bookmark: Data) throws -> LibraryRoot {
        try writer.write { db in
            if var existing = try LibraryRoot.filter(Column("path") == path).fetchOne(db) {
                existing.bookmark = bookmark
                try existing.update(db)
                return existing
            }
            var root = LibraryRoot(path: path, bookmark: bookmark)
            try root.insert(db)
            return root
        }
    }

    /// Applies metadata fixes. With `asOverrides`, they are also kept as overrides so a rescan does not revert them
    /// (used when the fix is not written to the file); otherwise existing overrides of those fields are cleared.
    public func applyMetadata(_ changes: [Int64: TrackMetadata], asOverrides: Bool) throws {
        try writer.write { db in
            for (id, metadata) in changes {
                guard var track = try Track.fetchOne(db, key: id) else { continue }
                track.apply(metadata)
                track.overrides = asOverrides ? (track.overrides ?? TrackMetadata()).merging(metadata) : nil
                try track.update(db)
            }
        }
    }

    /// Records the file's new size and date after Groovelight rewrote its tags, so the scanner does not reread it.
    public func updateFileInfo(trackId: Int64, fileSize: Int64, modifiedAt: Date) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE track SET fileSize = ?, modifiedAt = ? WHERE id = ?", arguments: [fileSize, modifiedAt, trackId])
        }
    }

    /// Stores lyrics fetched online (nil records a miss) and the lookup time.
    public func setFetchedLyrics(_ lyrics: String?, trackId: Int64, at date: Date = .now) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE track SET fetchedLyrics = COALESCE(?, fetchedLyrics), lyricsCheckedAt = ? WHERE id = ?",
                           arguments: [lyrics, date, trackId])
        }
    }

    /// Sets an online cover on tracks, replacing the shown artwork.
    public func setFetchedArtwork(_ hash: String, trackIds: [Int64]) throws {
        try writer.write { db in
            for id in trackIds {
                try db.execute(sql: "UPDATE track SET fetchedArtworkHash = ?, artworkHash = ? WHERE id = ?", arguments: [hash, hash, id])
            }
        }
    }

    public static func track(_ db: Database, id: Int64) throws -> Track? {
        try Track.fetchOne(db, key: id)
    }

    /// Online album info (credits, background) cached for an album, with when it was fetched.
    public static func albumInfo(_ db: Database, albumKey: String) throws -> (data: Data, fetchedAt: Date)? {
        guard let row = try Row.fetchOne(db, sql: "SELECT data, fetchedAt FROM albumInfo WHERE albumKey = ?", arguments: [albumKey]) else {
            return nil
        }
        return (row["data"], row["fetchedAt"])
    }

    public static func artistInfo(_ db: Database, name: String) throws -> (data: Data, fetchedAt: Date)? {
        guard let row = try Row.fetchOne(db, sql: "SELECT data, fetchedAt FROM artistInfo WHERE artistKey = ?",
                                         arguments: [name.lowercased()]) else { return nil }
        return (row["data"], row["fetchedAt"])
    }

    public func setArtistInfo(_ data: Data, name: String, at date: Date = .now) throws {
        try writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO artistInfo (artistKey, data, fetchedAt) VALUES (?, ?, ?)",
                           arguments: [name.lowercased(), data, date])
        }
    }

    public func setAlbumInfo(_ data: Data, albumKey: String, at date: Date = .now) throws {
        try writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO albumInfo (albumKey, data, fetchedAt) VALUES (?, ?, ?)",
                           arguments: [albumKey, data, date])
        }
    }

    public func removeRoot(_ rootId: Int64) throws {
        _ = try writer.write { db in try LibraryRoot.deleteOne(db, key: rootId) }
    }
}
