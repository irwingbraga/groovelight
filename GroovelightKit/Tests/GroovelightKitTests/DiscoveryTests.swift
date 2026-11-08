import Foundation
import GRDB
import Testing
@testable import LibraryKit
import WirelessSync

struct DiscoveryTests {
    struct Fixture: Codable {
        var today: Int
        var songs: [Discovery.Song]
        var plays: [Discovery.Play]
        var past: [Discovery.PastPick]
    }

    /// What both platforms must pick from `picks.json` (Windows' DiscoveryTests reads the same files).
    struct Expected: Codable, Equatable {
        struct Draw: Codable, Equatable {
            var key: String
            var reason: String
            var trackIds: [Int64]
        }

        var song: [Draw]
        var album: [Draw]
        var artist: [Draw]
        var affinity: [String: Int]
    }

    static func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/Discovery"))
    }

    @Test func picksTheSameAsWindows() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixture("picks")))
        let picker = Discovery.DailyPicks(songs: fixture.songs, plays: fixture.plays, past: fixture.past, today: fixture.today)
        func draws(_ kind: Discovery.Kind) -> [Expected.Draw] {
            picker.draw(kind, count: 3).map { Expected.Draw(key: $0.key, reason: $0.reason.code, trackIds: $0.trackIds) }
        }
        let affinity = Dictionary(uniqueKeysWithValues: fixture.songs.map { (String($0.id), picker.taste[$0.id].affinity) })
        let result = Expected(song: draws(.song), album: draws(.album), artist: draws(.artist), affinity: affinity)
        if let path = ProcessInfo.processInfo.environment["GL_WRITE_PICKS"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(result).write(to: URL(fileURLWithPath: path))
        }
        let expected = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: Self.fixture("picks-expected")))
        #expect(result == expected)
        // Resting picks stay out: song 12 three days ago, Radiohead ten days ago.
        #expect(!result.song.contains { $0.key == "12" })
        #expect(!result.artist.contains { $0.key == "Radiohead" })
        #expect(Set(result.song.map(\.key)).count == 3)
    }

    @Test func keepsTheDaysPickAllDay() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixture("picks")))
        let kept = Discovery.PastPick(day: fixture.today, kind: .album, key: "björk|homogenic", reason: "anniversary,25")
        let picker = Discovery.DailyPicks(songs: fixture.songs, plays: fixture.plays, past: fixture.past + [kept], today: fixture.today)
        let pick = try #require(picker.pick(.album))
        #expect(pick.key == "björk|homogenic" && pick.reason == .anniversary(years: 25))
        #expect(pick.trackIds == [11, 12, 13, 14, 15])
    }

    @Test func countsRecentPlaysMore() {
        #expect(Discovery.decayed(1000, age: 0) == 1000)
        #expect(Discovery.decayed(1000, age: 45) == 750)
        #expect(Discovery.decayed(1000, age: 90) == 500)
        #expect(Discovery.decayed(1000, age: 180) == 250)
        #expect(Discovery.decayed(1000, age: 5000) == 0)
        let song = Discovery.Song(id: 1, title: "A", artist: "X", albumArtist: "X", album: "Y", albumKey: "y", genre: nil, year: nil,
                                  loved: true, rating: 4, addedDay: 0, duration: 100, order: 1)
        let taste = Discovery.Taste(songs: [song], plays: [
            .init(trackId: 1, day: 100, counted: true, skipped: false, source: "mac"),
            .init(trackId: 1, day: 100, counted: false, skipped: true, source: "mac"),
            .init(trackId: 1, day: 10, counted: true, skipped: false, count: 9, source: "summary"),
        ], today: 100)
        #expect(taste[1].plays == 10 && taste[1].skips == 1 && taste[1].lastDay == 100)
        #expect(taste[1].affinity == 1000 - 400 + 9 * Discovery.decayed(1000, age: 90) + 3000 + 2000)
        // Last.fm history has the summary's plays already.
        let withLastFM = Discovery.Taste(songs: [song], plays: [
            .init(trackId: 1, day: 10, counted: true, skipped: false, count: 9, source: "summary"),
            .init(trackId: 1, day: 50, counted: true, skipped: false, source: "lastfm"),
        ], today: 100)
        #expect(withLastFM[1].plays == 1)
    }

    @Test func drawsTheSameNumbersEverywhere() {
        var random = Discovery.Random(seed: "groovelight")
        #expect([random.next(), random.next(), random.below(100)] == [2_317_881_071_274_320_010, 15_988_805_049_024_803_882, 36])
        var weighted = Discovery.Random(seed: "w")
        #expect(weighted.weighted([0, 0]) == nil)
        #expect(weighted.weighted([0, 5, 0]) == 1)
    }

    @Test func countsDaysInTheLocalCalendar() throws {
        #expect(Discovery.daysFromCivil(year: 1970, month: 1, day: 1) == 0)
        #expect(Discovery.daysFromCivil(year: 2025, month: 11, day: 8) == 20400)
        #expect(Discovery.year(ofDay: 20400) == 2025)
        #expect(Discovery.year(ofDay: -1) == 1969)
        let saoPaulo = try #require(TimeZone(identifier: "America/Sao_Paulo"))
        // 01:30 UTC on 8 November is still the 7th in São Paulo.
        #expect(Discovery.day(of: Date(timeIntervalSince1970: 20400 * 86_400 + 5400), in: saoPaulo) == 20399)
        #expect(Discovery.day(of: Date(timeIntervalSince1970: 20400 * 86_400 + 5400), in: .gmt) == 20400)
    }

    @Test func keepsTheDaysPicksInTheLibrary() throws {
        let database = try LibraryDatabaseTests.seeded()
        try database.recordListen(trackId: 1, startedAt: Date(timeIntervalSince1970: 1_700_000_000), listened: 180)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try database.dailyPicks(on: date, zone: .gmt).picks
        #expect(first.map(\.kind) == [.song, .album, .artist])
        // Played since: the day's picks stay.
        try database.recordListen(trackId: 2, startedAt: date, listened: 180)
        let later = try database.dailyPicks(on: date.addingTimeInterval(3600), zone: .gmt).picks
        #expect(later.map(\.key) == first.map(\.key) && later.map(\.reason) == first.map(\.reason))
        let stored = try database.writer.read { try LibraryDatabase.pastPicks($0, since: 0) }
        #expect(stored.count == 3 && stored.allSatisfy { $0.day == Discovery.day(of: date, in: .gmt) })
    }
}

struct ListeningStatsTests {
    @Test func summarizesListening() throws {
        let database = try LibraryDatabaseTests.seeded()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let now = Date(timeIntervalSince1970: 1_800_000_000) // Fri 15 Jan 2027, 08:00 UTC
        let day: TimeInterval = 86_400
        try database.recordListen(trackId: 1, startedAt: now.addingTimeInterval(-3600), listened: 180)
        try database.recordListen(trackId: 1, startedAt: now.addingTimeInterval(-day), listened: 180)
        try database.recordListen(trackId: 4, startedAt: now.addingTimeInterval(-2 * day), listened: 120)
        try database.recordListen(trackId: 2, startedAt: now.addingTimeInterval(-2 * day), listened: 3)
        try database.recordListen(trackId: 3, startedAt: now.addingTimeInterval(-40 * day), listened: 180)
        try database.applyDeviceHistory([DeviceHistoryEvent(id: "x", trackId: 4, kind: .play, value: 150,
                                                            atMs: Int64(now.addingTimeInterval(-5 * day).timeIntervalSince1970 * 1000))],
                                        deviceId: "phone")
        try database.writer.write { db in
            var old = Listen(trackId: 5, startedAt: now.addingTimeInterval(-900 * day), listened: 0, duration: 180, counted: true, skipped: false,
                             source: Listen.Source.summary, count: 7, artist: "Someone", title: "Song A", album: "Hits 1999")
            try old.insert(db)
        }

        let week = try database.writer.read { try LibraryDatabase.listeningStats($0, range: .week, now: now, calendar: calendar) }
        #expect(week.plays == 4 && week.songs == 2)
        #expect(abs(week.minutes - (180 + 180 + 120 + 3 + 150) / 60.0) < 0.001)
        #expect(week.streak == 3)
        #expect(week.buckets.count == 7 && week.buckets.last?.label == "2027-01-15")
        #expect(abs((week.buckets.last?.minutes[.here] ?? 0) - 3) < 0.001)
        #expect(week.places == [.here: 3, .devices: 1])
        #expect(week.topSongs.map(\.name) == ["Come Together", "Paranoid Android"] && week.topSongs.map(\.plays) == [2, 2]
                || week.topSongs.map(\.name) == ["Paranoid Android", "Come Together"])
        #expect(week.topArtists.map(\.name) == ["The Beatles", "Radiohead"] || week.topArtists.map(\.name) == ["Radiohead", "The Beatles"])
        #expect(week.hours[5][7] == 1) // Friday 07:00.
        // Come Together and Paranoid Android were first heard this week (Yellow Submarine 40 days ago).
        #expect(week.newSongs == 2)

        let all = try database.writer.read { try LibraryDatabase.listeningStats($0, range: .all, now: now, calendar: calendar) }
        #expect(all.plays == 5 + 7)
        #expect(all.buckets.map(\.label) == ["2026", "2027"])
        #expect(all.decades.map(\.name) == ["1960s"])
        #expect(all.librarySongs == 6 && all.loved == 0)
    }
}

struct HomeSnapshotTests {
    /// Home as the phones get it: three picks with more of each kind, the dashboard for every range, places as JSON maps.
    /// Its JSON is kept in `Fixtures/Discovery/home.json` (`GL_WRITE_HOME`), which Android and Windows read back.
    @Test func makesHomeForThePhones() throws {
        let database = try LibraryDatabaseTests.seeded()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Added long ago, so the picks do not depend on the day the test runs (Windows' HomeSnapshotTests does the same).
        try database.writer.write { try $0.execute(sql: "UPDATE track SET dateAdded = ?", arguments: [Date(timeIntervalSince1970: 1_600_000_000)]) }
        try database.recordListen(trackId: 1, startedAt: now.addingTimeInterval(-3600), listened: 180)
        try database.recordListen(trackId: 4, startedAt: now.addingTimeInterval(-86_400), listened: 120)
        let home = try database.homeSnapshot(now: now, zone: .gmt)
        #expect(home.day == Discovery.day(of: now, in: .gmt))
        #expect(!home.song.isEmpty && !home.album.isEmpty && !home.artist.isEmpty)
        #expect(home.stats.map(\.range) == [.week, .month, .year, .all])
        let pick = try #require(home.song.first)
        #expect(pick.reasonText == Discovery.Reason(code: pick.reason)?.text(for: .song))
        #expect(!pick.trackIds.isEmpty && pick.key == String(pick.trackIds[0]))
        // The day's picks are the ones kept in the library.
        let kept = try database.writer.read { try LibraryDatabase.pastPicks($0, since: home.day) }
        #expect(Set(kept.map(\.key)) == Set([home.song[0].key, home.album[0].key, home.artist[0].key]))

        let json = try WirelessProtocol.encoder.encode(home)
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let week = try #require((object["stats"] as? [[String: Any]])?.first)
        #expect((week["places"] as? [String: Int]) == ["here": 2])
        #expect(((week["buckets"] as? [[String: Any]])?.last?["minutes"] as? [String: Double]) == ["here": 3])
        #expect(try WirelessProtocol.decoder.decode(HomeSnapshot.self, from: json) == home)
        if let path = ProcessInfo.processInfo.environment["GL_WRITE_HOME"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(home).write(to: URL(fileURLWithPath: path))
        }
    }
}
