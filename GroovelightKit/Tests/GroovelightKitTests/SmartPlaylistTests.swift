import Foundation
import GRDB
import Testing
@testable import LibraryKit

struct SmartPlaylistTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let day = 86_400.0

    /// Eight songs with varied tags, play history and formats.
    static func library() throws -> LibraryDatabase {
        let database = try LibraryDatabase.inMemory()
        let root = try database.addRoot(path: "/music", bookmark: Data())
        func track(_ title: String, artist: String, album: String, year: Int, plays: Int = 0, loved: Bool = false,
                   addedDaysAgo: Double = 100, playedDaysAgo: Double? = nil, format: String = "FLAC", sampleRate: Double = 44_100,
                   bitDepth: Int? = 16, bitrate: Double? = 900, duration: Double = 240, size: Int64 = 30_000_000,
                   genre: String = "Rock", artwork: Bool = true, rating: Int = 0) -> Track {
            var track = LibraryDatabaseTests.makeTrack(rootId: root.id!, title, artist: artist, album: album, number: 1)
            track.path = "/music/\(artist)/\(album)/\(title).\(format.lowercased())"
            track.year = year
            track.playCount = plays
            track.isLoved = loved
            track.dateAdded = now.addingTimeInterval(-addedDaysAgo * day)
            track.lastPlayedAt = playedDaysAgo.map { now.addingTimeInterval(-$0 * day) }
            track.format = format
            track.sampleRate = sampleRate
            track.bitDepth = bitDepth
            track.bitrate = bitrate
            track.duration = duration
            track.fileSize = size
            track.genre = genre
            track.artworkHash = artwork ? "hash" : nil
            track.rating = rating
            return track
        }
        try database.writer.write { db in
            for var item in [
                track("Airbag", artist: "Radiohead", album: "OK Computer", year: 1997, plays: 40, playedDaysAgo: 1, rating: 5),
                track("Karma Police", artist: "Radiohead", album: "OK Computer", year: 1997, plays: 25, loved: true, playedDaysAgo: 20),
                track("Movement 1", artist: "Aurelia Quartet", album: "Hi-Res Sessions", year: 2024, addedDaysAgo: 2,
                      sampleRate: 96_000, bitDepth: 24, bitrate: 3000, genre: "Jazz"),
                track("Hit 1", artist: "Radio Days", album: "Three Twenty", year: 2003, plays: 3, addedDaysAgo: 5, playedDaysAgo: 3,
                      format: "MP3", bitDepth: nil, bitrate: 320, duration: 200, size: 8_000_000, genre: "Pop"),
                track("Side B", artist: "Mixtape Club", album: "Mixed Bag", year: 1989, format: "MP3", bitDepth: nil, bitrate: 192,
                      duration: 180, size: 4_000_000, genre: "Pop", artwork: false),
                track("100% Pure_Fun", artist: "The Wildcards", album: "Symbols", year: 1999, plays: 1, playedDaysAgo: 400,
                      duration: 600, genre: "Electronic"),
                track("Dsd Track", artist: "Aurelia Quartet", album: "DSD Test", year: 2020, format: "DSD Stream",
                      sampleRate: 2_822_400, bitDepth: 1, bitrate: nil, genre: "Jazz"),
                track("Long Song", artist: "Velvet Static", album: "Chrome Hearts", year: 2010, plays: 10, playedDaysAgo: 60,
                      duration: 1200, size: 120_000_000, genre: "Electronic"),
            ] {
                try item.insert(db)
            }
        }
        return database
    }

    func titles(_ rules: SmartPlaylistRules, in database: LibraryDatabase) throws -> [String] {
        try database.writer.read { try LibraryDatabase.tracks($0, rules: rules, now: Self.now) }.map(\.title).sorted()
    }

    @Test func textRules() throws {
        let db = try Self.library()
        #expect(try titles(.init(rules: [SmartRule(field: .artist, op: .contains, text: "radio")]), in: db)
                == ["Airbag", "Hit 1", "Karma Police"])
        #expect(try titles(.init(rules: [SmartRule(field: .artist, op: .is, text: "radiohead")]), in: db) == ["Airbag", "Karma Police"])
        #expect(try titles(.init(rules: [SmartRule(field: .title, op: .beginsWith, text: "100%")]), in: db) == ["100% Pure_Fun"])
        // "%" and "_" are literal, not wildcards.
        #expect(try titles(.init(rules: [SmartRule(field: .title, op: .contains, text: "e_F")]), in: db) == ["100% Pure_Fun"])
        #expect(try titles(.init(rules: [SmartRule(field: .title, op: .contains, text: "_")]), in: db) == ["100% Pure_Fun"])
        #expect(try titles(.init(rules: [SmartRule(field: .genre, op: .doesNotContain, text: "o")]), in: db)
                == ["Dsd Track", "Movement 1"])
    }

    @Test func numberRules() throws {
        let db = try Self.library()
        #expect(try titles(.init(rules: [SmartRule(field: .year, op: .inRange, number: 1990, number2: 1999)]), in: db)
                == ["100% Pure_Fun", "Airbag", "Karma Police"])
        #expect(try titles(.init(rules: [SmartRule(field: .plays, op: .greaterThan, number: 20)]), in: db) == ["Airbag", "Karma Police"])
        // Minutes and kHz are converted to the stored seconds and Hz.
        #expect(try titles(.init(rules: [SmartRule(field: .time, op: .greaterThan, number: 15)]), in: db) == ["Long Song"])
        #expect(try titles(.init(rules: [SmartRule(field: .sampleRate, op: .is, number: 96)]), in: db) == ["Movement 1"])
        #expect(try titles(.init(rules: [SmartRule(field: .bitrate, op: .is, number: 320)]), in: db) == ["Hit 1"])
        #expect(try titles(.init(rules: [SmartRule(field: .rating, op: .is, number: 5)]), in: db) == ["Airbag"])
    }

    @Test func dateRules() throws {
        let db = try Self.library()
        #expect(try titles(.init(rules: [SmartRule(field: .dateAdded, op: .inTheLast, period: 1, periodUnit: .weeks)]), in: db)
                == ["Hit 1", "Movement 1"])
        #expect(try titles(.init(rules: [SmartRule(field: .lastPlayed, op: .inTheLast, period: 1, periodUnit: .months)]), in: db)
                == ["Airbag", "Hit 1", "Karma Police"])
        // Never played counts as "not played in the last 2 months".
        #expect(try titles(.init(rules: [SmartRule(field: .lastPlayed, op: .notInTheLast, period: 2, periodUnit: .months)]), in: db).count == 4)
    }

    @Test func boolAndQualityRules() throws {
        let db = try Self.library()
        #expect(try titles(.init(rules: [SmartRule(field: .loved, op: .isTrue)]), in: db) == ["Karma Police"])
        #expect(try titles(.init(rules: [SmartRule(field: .hasArtwork, op: .isFalse)]), in: db) == ["Side B"])
        #expect(try titles(.init(rules: [SmartRule(field: .quality, op: .is, quality: .hiResLossless)]), in: db) == ["Movement 1"])
        #expect(try titles(.init(rules: [SmartRule(field: .quality, op: .isAtLeast, quality: .hiResLossless)]), in: db)
                == ["Dsd Track", "Movement 1"])
        #expect(try titles(.init(rules: [SmartRule(field: .quality, op: .is, quality: .highQuality)]), in: db) == ["Hit 1"])
        #expect(try titles(.init(rules: [SmartRule(field: .quality, op: .isAtLeast, quality: .lossless)]), in: db).count == 6)
    }

    @Test func matchAllOrAny() throws {
        let db = try Self.library()
        let rules = [SmartRule(field: .genre, op: .is, text: "Jazz"), SmartRule(field: .year, op: .greaterThan, number: 2022)]
        #expect(try titles(.init(match: .all, rules: rules), in: db) == ["Movement 1"])
        #expect(try titles(.init(match: .any, rules: rules), in: db) == ["Dsd Track", "Movement 1"])
        #expect(try titles(.init(rules: []), in: db).count == 8)
    }

    @Test func limits() throws {
        let db = try Self.library()
        let mostPlayed = SmartPlaylistRules(rules: [], limit: SmartLimit(count: 3, unit: .songs, selectedBy: .mostPlayed))
        let ordered = try db.writer.read { try LibraryDatabase.tracks($0, rules: mostPlayed, now: Self.now) }.map(\.title)
        #expect(ordered == ["Airbag", "Karma Police", "Long Song"])

        // 12 minutes of the most recently added: Movement 1 (4:00) and Hit 1 (3:20), then Airbag (4:00, the oldest additions
        // tie and fall back to library order) still fits; Karma Police would go over.
        let recent = SmartPlaylistRules(rules: [], limit: SmartLimit(count: 12, unit: .minutes, selectedBy: .mostRecentlyAdded))
        let minutes = try db.writer.read { try LibraryDatabase.tracks($0, rules: recent, now: Self.now) }
        #expect(minutes.map(\.title) == ["Movement 1", "Hit 1", "Airbag"])
        #expect(minutes.reduce(0) { $0 + $1.duration } <= 12 * 60)

        // Random is stable for a seed.
        let random = SmartPlaylistRules(rules: [], limit: SmartLimit(count: 4, selectedBy: .random, seed: 42))
        let first = try db.writer.read { try LibraryDatabase.tracks($0, rules: random) }.map(\.id)
        let second = try db.writer.read { try LibraryDatabase.tracks($0, rules: random) }.map(\.id)
        #expect(first == second && first.count == 4)
    }

    @Test func smartPlaylistsUpdateLive() throws {
        let db = try Self.library()
        let rules = SmartPlaylistRules(rules: [SmartRule(field: .loved, op: .isTrue)])
        let playlist = try db.createSmartPlaylist(named: "Loved", rules: rules)
        let id = try #require(playlist.id)
        #expect(try db.writer.read { try LibraryDatabase.tracks($0, playlistId: id) }.map(\.title) == ["Karma Police"])

        let airbag = try #require(try db.writer.read { try Track.filter(Column("title") == "Airbag").fetchOne($0) })
        try db.setLoved(true, trackId: airbag.id!)
        #expect(try db.writer.read { try LibraryDatabase.tracks($0, playlistId: id) }.map(\.title).sorted() == ["Airbag", "Karma Police"])

        try db.updateSmartPlaylist(id, name: "Loved Radiohead",
                                   rules: SmartPlaylistRules(rules: [SmartRule(field: .loved, op: .isTrue),
                                                                     SmartRule(field: .artist, op: .is, text: "Radiohead")]))
        let updated = try #require(try db.writer.read { try Playlist.fetchOne($0, key: id) })
        #expect(updated.name == "Loved Radiohead" && updated.rules?.rules.count == 2)
    }

    @Test func lovedSongsNewestFirst() throws {
        let db = try Self.library()
        let ids = try db.writer.read { db in
            try ["Side B", "Airbag", "Hit 1"].map { title in try Track.filter(Column("title") == title).fetchOne(db)!.id! }
        }
        try db.setLoved(true, trackId: ids[0], at: Self.now.addingTimeInterval(-3 * Self.day))
        try db.setLoved(true, trackId: ids[1], at: Self.now.addingTimeInterval(-1 * Self.day))
        try db.setLoved(true, trackId: ids[2], at: Self.now.addingTimeInterval(-2 * Self.day))
        // Loving again keeps the first date; "Karma Police" was loved before dates existed and comes last.
        try db.setLoved(true, trackId: ids[0], at: Self.now)
        #expect(try db.writer.read { try LibraryDatabase.lovedTracks($0) }.map(\.title) == ["Airbag", "Hit 1", "Side B", "Karma Police"])

        try db.setLoved(false, trackId: ids[1])
        let unloved = try db.writer.read { try Track.fetchOne($0, key: ids[1]) }
        #expect(unloved?.isLoved == false && unloved?.lovedAt == nil)

        _ = try db.createSmartPlaylist(named: "Jazz", rules: .init(rules: [SmartRule(field: .genre, op: .is, text: "Jazz")]))
        let overview = try db.writer.read { try LibraryDatabase.playlistOverview($0) }
        #expect(overview.lovedCount == 3)
        #expect(overview.playlists.map(\.playlist.name) == ["Jazz"] && overview.playlists.first?.trackCount == 2)
    }

    @Test func rulesRoundTripAsJSON() throws {
        let rules = SmartPlaylistRules(match: .any, rules: [SmartRule(field: .quality, op: .isAtLeast, quality: .hiResLossless)],
                                       limit: SmartLimit(count: 2, unit: .hours, selectedBy: .highestRated))
        let decoded = try JSONDecoder().decode(SmartPlaylistRules.self, from: JSONEncoder().encode(rules))
        #expect(decoded == rules)
    }
}
