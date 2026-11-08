import Foundation
import GRDB

/// Home's dashboard: listening time, plays, when and what, for a range of days. Windows has the same (`ListeningStats.cs`).
public struct ListeningStats: Codable, Hashable, Sendable {
    public enum Range: String, Codable, CaseIterable, Sendable {
        case week, month, year, all

        /// Days back from today (nil for all time).
        public var days: Int? {
            switch self {
            case .week: 7
            case .month: 30
            case .year: 365
            case .all: nil
            }
        }
    }

    /// Where listens came from, for the stacked bars.
    public enum Place: String, Codable, CaseIterable, Sendable {
        /// This computer (the Mac or the PC).
        case here
        case devices
        case lastfm
    }

    public struct Bucket: Codable, Hashable, Sendable {
        /// "2025-11-08", "2025-11" or "2025".
        public var label: String
        /// Minutes heard, by place.
        public var minutes: [Place: Double]
        public var total: Double { minutes.values.reduce(0, +) }
    }

    public struct Ranked: Codable, Hashable, Sendable {
        public var name: String
        /// The artist (songs and albums).
        public var detail: String
        /// The album key (albums), the song id (songs), for opening it.
        public var key: String
        public var plays: Int
        public var artworkHash: String?
    }

    public var range: Range
    public var minutes: Double = 0
    public var plays = 0
    public var songs = 0
    /// Songs heard for the first time in the range.
    public var newSongs = 0
    /// Days in a row, up to today (or yesterday), with at least one play.
    public var streak = 0
    public var buckets: [Bucket] = []
    /// Plays by weekday (0 is Sunday) and hour: 7 rows of 24.
    public var hours: [[Int]] = Array(repeating: Array(repeating: 0, count: 24), count: 7)
    public var topSongs: [Ranked] = []
    public var topAlbums: [Ranked] = []
    public var topArtists: [Ranked] = []
    public var genres: [Ranked] = []
    /// "1990s" and its plays.
    public var decades: [Ranked] = []
    public var places: [Place: Int] = [:]
    public var librarySongs = 0
    public var neverPlayed = 0
    public var loved = 0

    public init(range: Range) {
        self.range = range
    }

    static func place(_ source: String) -> Place {
        if source == Listen.Source.lastfm { return .lastfm }
        if source.hasPrefix("device:") { return .devices }
        return .here
    }
}

extension LibraryDatabase {
    /// The dashboard for a range, ending today (in the calendar's time zone). Summary rows (play counts from before the log) only count in
    /// "all time" totals and the top lists, not in time based charts.
    public static func listeningStats(_ db: Database, range: ListeningStats.Range, now: Date = .now,
                                      calendar: Calendar = .current) throws -> ListeningStats {
        var stats = ListeningStats(range: range)
        let startOfToday = calendar.startOfDay(for: now)
        let since = range.days.flatMap { calendar.date(byAdding: .day, value: 1 - $0, to: startOfToday) } ?? .distantPast
        let summary = Listen.Source.summary
        let filter = "startedAt >= ? AND (source <> ? OR ? = 1)"
        let isAll = range == .all
        // The calendar's offset now, as a SQLite modifier ("localtime" would be the process's zone, not the calendar's).
        let local = "'\(calendar.timeZone.secondsFromGMT(for: now)) seconds'"
        let arguments: StatementArguments = [since, summary, isAll]

        if let row = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(CASE WHEN source <> ? THEN listened ELSE 0 END), 0) AS seconds,
                   COALESCE(SUM(CASE WHEN counted THEN count ELSE 0 END), 0) AS plays,
                   COUNT(DISTINCT CASE WHEN counted THEN COALESCE(trackId, artist || '|' || title) END) AS songs
            FROM listen WHERE \(filter)
            """, arguments: [summary] + arguments) {
            stats.minutes = (row["seconds"] as Double) / 60
            stats.plays = row["plays"]
            stats.songs = row["songs"]
        }
        stats.newSongs = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM (SELECT trackId FROM listen WHERE counted AND trackId IS NOT NULL GROUP BY trackId HAVING MIN(startedAt) >= ?)
            """, arguments: [since]) ?? 0

        // Streak: local days with plays, newest first.
        let days = try String.fetchAll(db, sql: """
            SELECT DISTINCT date(startedAt, \(local)) AS day FROM listen WHERE counted AND source <> ? ORDER BY day DESC LIMIT 400
            """, arguments: [summary])
        stats.streak = streak(days, today: startOfToday, calendar: calendar)

        // Time based charts.
        let format = switch range {
        case .week, .month: "%Y-%m-%d"
        case .year: "%Y-%m"
        case .all: "%Y"
        }
        var buckets: [String: [ListeningStats.Place: Double]] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT strftime('\(format)', startedAt, \(local)) AS bucket, source, SUM(listened) AS seconds
            FROM listen WHERE startedAt >= ? AND source <> ? GROUP BY bucket, source
            """, arguments: [since, summary]) {
            let place = ListeningStats.place(row["source"])
            buckets[row["bucket"], default: [:]][place, default: 0] += (row["seconds"] as Double) / 60
        }
        stats.buckets = bucketLabels(range: range, since: since, today: startOfToday, calendar: calendar, existing: Array(buckets.keys))
            .map { ListeningStats.Bucket(label: $0, minutes: buckets[$0] ?? [:]) }
        for row in try Row.fetchAll(db, sql: """
            SELECT CAST(strftime('%w', startedAt, \(local)) AS INTEGER) AS weekday, CAST(strftime('%H', startedAt, \(local)) AS INTEGER) AS hour,
                   SUM(count) AS plays
            FROM listen WHERE counted AND startedAt >= ? AND source <> ? GROUP BY weekday, hour
            """, arguments: [since, summary]) {
            let weekday: Int = row["weekday"]
            let hour: Int = row["hour"]
            if (0..<7).contains(weekday), (0..<24).contains(hour) { stats.hours[weekday][hour] = row["plays"] }
        }
        for row in try Row.fetchAll(db, sql: """
            SELECT source, SUM(count) AS plays FROM listen WHERE counted AND \(filter) GROUP BY source
            """, arguments: arguments) {
            stats.places[ListeningStats.place(row["source"]), default: 0] += row["plays"]
        }

        // Top lists (songs in the library; artists also from Last.fm plays of songs not in it).
        stats.topSongs = try Row.fetchAll(db, sql: """
            SELECT t.id, t.title, COALESCE(NULLIF(t.artist, ''), t.albumArtist, '') AS artist, t.artworkHash, SUM(l.count) AS plays
            FROM listen l JOIN track t ON t.id = l.trackId WHERE l.counted AND l.\(filter.replacingOccurrences(of: "AND (source", with: "AND (l.source"))
            GROUP BY t.id ORDER BY plays DESC, t.id LIMIT 10
            """, arguments: arguments).map {
            ListeningStats.Ranked(name: $0["title"], detail: $0["artist"], key: String($0["id"] as Int64), plays: $0["plays"], artworkHash: $0["artworkHash"])
        }
        stats.topAlbums = try Row.fetchAll(db, sql: """
            SELECT t.albumKey, MAX(t.album) AS album,
                   CASE WHEN MAX(t.isCompilation) THEN 'Various Artists' ELSE COALESCE(MAX(NULLIF(t.albumArtist, '')), MAX(t.artist), '') END AS artist,
                   MAX(t.artworkHash) AS artworkHash, SUM(l.count) AS plays
            FROM listen l JOIN track t ON t.id = l.trackId WHERE l.counted AND l.\(filter.replacingOccurrences(of: "AND (source", with: "AND (l.source"))
            GROUP BY t.albumKey ORDER BY plays DESC, t.albumKey LIMIT 10
            """, arguments: arguments).map {
            ListeningStats.Ranked(name: $0["album"] ?? "", detail: $0["artist"], key: $0["albumKey"], plays: $0["plays"], artworkHash: $0["artworkHash"])
        }
        stats.topArtists = try Row.fetchAll(db, sql: """
            SELECT artist, SUM(count) AS plays FROM listen WHERE counted AND artist <> '' AND \(filter)
            GROUP BY artist COLLATE NOCASE ORDER BY plays DESC, artist LIMIT 10
            """, arguments: arguments).map {
            ListeningStats.Ranked(name: $0["artist"], detail: "", key: $0["artist"], plays: $0["plays"], artworkHash: nil)
        }
        stats.genres = try Row.fetchAll(db, sql: """
            SELECT t.genre, SUM(l.count) AS plays FROM listen l JOIN track t ON t.id = l.trackId
            WHERE l.counted AND t.genre IS NOT NULL AND t.genre <> '' AND l.\(filter.replacingOccurrences(of: "AND (source", with: "AND (l.source"))
            GROUP BY t.genre COLLATE NOCASE ORDER BY plays DESC, t.genre LIMIT 8
            """, arguments: arguments).map {
            ListeningStats.Ranked(name: $0["genre"], detail: "", key: $0["genre"], plays: $0["plays"], artworkHash: nil)
        }
        stats.decades = try Row.fetchAll(db, sql: """
            SELECT (t.year / 10) * 10 AS decade, SUM(l.count) AS plays FROM listen l JOIN track t ON t.id = l.trackId
            WHERE l.counted AND t.year > 0 AND l.\(filter.replacingOccurrences(of: "AND (source", with: "AND (l.source"))
            GROUP BY decade ORDER BY decade
            """, arguments: arguments).map {
            let decade: Int = $0["decade"]
            return ListeningStats.Ranked(name: "\(decade)s", detail: "", key: String(decade), plays: $0["plays"], artworkHash: nil)
        }

        if let row = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) AS songs, SUM(CASE WHEN playCount = 0 THEN 1 ELSE 0 END) AS never, SUM(CASE WHEN isLoved THEN 1 ELSE 0 END) AS loved
            FROM track
            """) {
            stats.librarySongs = row["songs"]
            stats.neverPlayed = row["never"] ?? 0
            stats.loved = row["loved"] ?? 0
        }
        return stats
    }

    /// Days in a row with plays, from today, or from yesterday when nothing was played yet today.
    static func streak(_ days: [String], today: Date, calendar: Calendar) -> Int {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let played = Set(days)
        var day = played.contains(formatter.string(from: today)) ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        var count = 0
        while played.contains(formatter.string(from: day)) {
            count += 1
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return count
    }

    /// Every bucket of the range, empty ones too (all time: from the first year with listens).
    static func bucketLabels(range: ListeningStats.Range, since: Date, today: Date, calendar: Calendar, existing: [String]) -> [String] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        switch range {
        case .week, .month:
            formatter.dateFormat = "yyyy-MM-dd"
            return (0..<(range.days ?? 0)).reversed().map { formatter.string(from: calendar.date(byAdding: .day, value: -$0, to: today)!) }
        case .year:
            formatter.dateFormat = "yyyy-MM"
            return (0..<12).reversed().map { formatter.string(from: calendar.date(byAdding: .month, value: -$0, to: today)!) }
        case .all:
            let thisYear = calendar.component(.year, from: today)
            let first = existing.compactMap(Int.init).min() ?? thisYear
            return (first...thisYear).map(String.init)
        }
    }
}
