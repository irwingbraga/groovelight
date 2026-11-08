import Foundation
import GRDB

extension Discovery {
    /// Days since 1970 of a moment in a time zone (the local calendar day it falls on).
    public static func day(of date: Date, in zone: TimeZone) -> Int {
        let seconds = Int(date.timeIntervalSince1970.rounded(.down)) + zone.secondsFromGMT(for: date)
        return seconds >= 0 ? seconds / 86_400 : (seconds - 86_399) / 86_400
    }
}

extension LibraryDatabase {
    /// The library and the log as the picks see them.
    public static func discoveryInput(_ db: Database, zone: TimeZone = .current) throws -> (songs: [Discovery.Song], plays: [Discovery.Play]) {
        let songs = try Row.fetchAll(db, sql: """
            SELECT id, title, artist, albumArtist, album, albumKey, genre, year, isLoved, rating, dateAdded, duration, discNumber,
                   trackNumber, isCompilation
            FROM track
            """).map { row -> Discovery.Song in
            let artist: String? = (row["artist"] as String?).flatMap { $0.isEmpty ? nil : $0 }
            let albumArtist: String? = (row["albumArtist"] as String?).flatMap { $0.isEmpty ? nil : $0 }
            let compilation: Bool = row["isCompilation"]
            return Discovery.Song(
                id: row["id"], title: row["title"], artist: artist ?? albumArtist ?? "",
                albumArtist: compilation ? "Various Artists" : albumArtist ?? artist ?? "",
                album: row["album"] ?? "", albumKey: row["albumKey"] ?? "", genre: row["genre"], year: row["year"],
                loved: row["isLoved"], rating: row["rating"], addedDay: Discovery.day(of: row["dateAdded"], in: zone),
                duration: row["duration"], order: (row["discNumber"] ?? 1) * 1000 + (row["trackNumber"] ?? 0))
        }
        let plays = try Row.fetchAll(db, sql: """
            SELECT trackId, startedAt, counted, skipped, count, source FROM listen WHERE trackId IS NOT NULL
            """).map { row in
            Discovery.Play(trackId: row["trackId"], day: Discovery.day(of: row["startedAt"], in: zone), counted: row["counted"],
                           skipped: row["skipped"], count: row["count"], source: row["source"])
        }
        return (songs, plays)
    }

    /// Songs by id, in the order asked (missing ones left out).
    public static func tracks(_ db: Database, ids: [Int64]) throws -> [Track] {
        let found = Dictionary(try Track.fetchAll(db, keys: ids).compactMap { track in track.id.map { ($0, track) } },
                               uniquingKeysWith: { first, _ in first })
        return ids.compactMap { found[$0] }
    }

    public static func pastPicks(_ db: Database, since day: Int) throws -> [Discovery.PastPick] {
        try Row.fetchAll(db, sql: "SELECT day, kind, key, reason FROM dailyPick WHERE day >= ? ORDER BY day", arguments: [day])
            .compactMap { row in
                guard let kind = Discovery.Kind(rawValue: row["kind"]) else { return nil }
                return Discovery.PastPick(day: row["day"], kind: kind, key: row["key"], reason: row["reason"])
            }
    }

    /// Today's picks (made and kept on the first call of the day), with the picker for "Something else".
    public func dailyPicks(on date: Date = .now, zone: TimeZone = .current) throws -> (picks: [Discovery.Pick], picker: Discovery.DailyPicks) {
        try writer.write { db in
            let today = Discovery.day(of: date, in: zone)
            let input = try Self.discoveryInput(db, zone: zone)
            let past = try Self.pastPicks(db, since: today - 120)
            let picker = Discovery.DailyPicks(songs: input.songs, plays: input.plays, past: past, today: today)
            var picks: [Discovery.Pick] = []
            for kind in Discovery.Kind.allCases {
                guard let pick = picker.pick(kind) else { continue }
                picks.append(pick)
                try db.execute(sql: "INSERT OR IGNORE INTO dailyPick (day, kind, key, reason) VALUES (?, ?, ?, ?)",
                               arguments: [today, kind.rawValue, pick.key, pick.reason.code])
            }
            return (picks, picker)
        }
    }
}
