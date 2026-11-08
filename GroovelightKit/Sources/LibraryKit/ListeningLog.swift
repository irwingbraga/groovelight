import Foundation
import GRDB

/// One listen: a song played (all the way, partly, or skipped) on this computer, a device, or Last.fm. Home's picks,
/// playlists and charts are worked out from these.
public struct Listen: Codable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "listen"

    public enum Source {
        public static let mac = "mac"
        public static let windows = "windows"
        public static let lastfm = "lastfm"
        /// The song's play count from before the log (`count` plays, at the last one).
        public static let summary = "summary"
        public static func device(_ id: String) -> String { "device:\(id)" }
    }

    public var id: Int64?
    /// Nil for a Last.fm play of a song not in the library, or a song since removed.
    public var trackId: Int64?
    public var startedAt: Date
    /// Seconds heard.
    public var listened: Double
    public var duration: Double
    /// Heard long enough to count as a play (what Play Count counts).
    public var counted: Bool
    /// Stopped early (what Skips counts).
    public var skipped: Bool
    public var source: String
    /// Plays this row stands for: 1, or a song's total for a `summary` row.
    public var count: Int
    public var artist: String
    public var title: String
    public var album: String

    public init(id: Int64? = nil, trackId: Int64?, startedAt: Date, listened: Double, duration: Double, counted: Bool, skipped: Bool,
                source: String, count: Int = 1, artist: String, title: String, album: String) {
        self.id = id
        self.trackId = trackId
        self.startedAt = startedAt
        self.listened = listened
        self.duration = duration
        self.counted = counted
        self.skipped = skipped
        self.source = source
        self.count = count
        self.artist = artist
        self.title = title
        self.album = album
    }

    /// A listen of `seconds` of a song: a play when at least half (or 4 minutes) was heard, a skip when it stopped in the
    /// first 20 seconds (or the first half of a shorter song).
    public init(track: Track, startedAt: Date, listened seconds: Double, source: String) {
        let duration = track.duration
        let counted = duration > 0 && seconds >= min(duration * 0.5, 240)
        self.init(trackId: track.id, startedAt: startedAt, listened: seconds, duration: duration, counted: counted,
                  skipped: !counted && seconds < min(20, duration * 0.5), source: source,
                  artist: track.artist ?? "", title: track.title, album: track.album ?? "")
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension LibraryDatabase {
    /// Records a listen made here: the log row, and Play Count, Last Played and Skips as before.
    /// Returns the listen (nil when the song is gone).
    @discardableResult
    public func recordListen(trackId: Int64, startedAt: Date, listened: Double, source: String = Listen.Source.mac) throws -> Listen? {
        try writer.write { db in
            guard let track = try Track.fetchOne(db, key: trackId) else { return nil }
            var listen = Listen(track: track, startedAt: startedAt, listened: listened, source: source)
            try Self.count(db, listen)
            try listen.insert(db)
            return listen
        }
    }

    /// Play Count, Last Played and Skips for a listen.
    static func count(_ db: Database, _ listen: Listen) throws {
        guard let trackId = listen.trackId else { return }
        if listen.counted {
            let end = listen.startedAt.addingTimeInterval(listen.listened)
            try db.execute(sql: """
                UPDATE track SET playCount = playCount + 1,
                    lastPlayedAt = CASE WHEN lastPlayedAt IS NULL OR lastPlayedAt < ? THEN ? ELSE lastPlayedAt END
                WHERE id = ?
                """, arguments: [end, end, trackId])
        } else if listen.skipped {
            try db.execute(sql: "UPDATE track SET skipCount = skipCount + 1 WHERE id = ?", arguments: [trackId])
        }
    }

    /// Listens from a source, and how many of them are songs in the library.
    public static func listenCounts(_ db: Database, source: String) throws -> (plays: Int, matched: Int) {
        let row = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS plays, COUNT(trackId) AS matched FROM listen WHERE source = ?",
                                   arguments: [source])
        return (row?["plays"] ?? 0, row?["matched"] ?? 0)
    }

    /// Listens from `start` on (all when nil), oldest first.
    public func listens(since start: Date? = nil) throws -> [Listen] {
        try writer.read { db in
            if let start {
                return try Listen.filter(Column("startedAt") >= start).order(Column("startedAt")).fetchAll(db)
            }
            return try Listen.order(Column("startedAt")).fetchAll(db)
        }
    }
}
