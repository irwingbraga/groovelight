import Foundation
import GRDB

/// Something waiting to be sent to Last.fm: a scrobble, or a love or unlove. Kept in the database so nothing is lost
/// while offline or when the app quits before sending.
public struct LastFMQueueItem: Codable, Hashable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "lastfmQueue"

    public enum Kind: String, Codable, Sendable {
        case scrobble, love, unlove
    }

    public var id: Int64?
    public var kind: Kind
    public var artist: String
    public var track: String
    public var album: String?
    public var albumArtist: String?
    public var duration: Double?
    public var trackNumber: Int?
    /// When the song started playing (scrobbles), or when the love changed.
    public var timestamp: Date
    /// Failed attempts so far (items failing again and again are dropped).
    public var attempts: Int

    public init(id: Int64? = nil, kind: Kind, artist: String, track: String, album: String? = nil, albumArtist: String? = nil,
                duration: Double? = nil, trackNumber: Int? = nil, timestamp: Date, attempts: Int = 0) {
        self.id = id
        self.kind = kind
        self.artist = artist
        self.track = track
        self.album = album
        self.albumArtist = albumArtist
        self.duration = duration
        self.trackNumber = trackNumber
        self.timestamp = timestamp
        self.attempts = attempts
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension LibraryDatabase {
    public func enqueueLastFM(_ item: LastFMQueueItem) throws {
        try writer.write { db in
            var item = item
            // A love followed by an unlove (or the reverse) of the same song: only the last one matters.
            if item.kind != .scrobble {
                try db.execute(sql: """
                    DELETE FROM lastfmQueue WHERE kind IN ('love', 'unlove') AND artist = ? COLLATE NOCASE AND track = ? COLLATE NOCASE
                    """, arguments: [item.artist, item.track])
            }
            try item.insert(db)
        }
    }

    /// Waiting items of a kind, oldest first.
    public func pendingLastFM(kinds: [LastFMQueueItem.Kind], limit: Int) throws -> [LastFMQueueItem] {
        try writer.read { db in
            try LastFMQueueItem.filter(kinds.map(\.rawValue).contains(Column("kind")))
                .order(Column("timestamp"), Column("id"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    public func removeLastFM(_ ids: [Int64]) throws {
        _ = try writer.write { db in try LastFMQueueItem.deleteAll(db, keys: ids) }
    }

    /// Counts a failed attempt for these items, dropping the ones that failed `maxAttempts` times.
    public func failedLastFM(_ ids: [Int64], maxAttempts: Int) throws {
        try writer.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE lastfmQueue SET attempts = attempts + 1 WHERE id = ?", arguments: [id])
            }
            try db.execute(sql: "DELETE FROM lastfmQueue WHERE attempts >= ?", arguments: [maxAttempts])
        }
    }

    public static func lastFMQueueCount(_ db: Database) throws -> Int {
        try LastFMQueueItem.fetchCount(db)
    }
}
