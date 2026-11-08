import Foundation
import GRDB
import Testing
@testable import LibraryKit

struct ListeningLogTests {
    @Test func logsPlaysSkipsAndPartialListens() throws {
        let database = try LibraryDatabaseTests.seeded()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        try database.recordListen(trackId: 1, startedAt: start, listened: 170)
        try database.recordListen(trackId: 1, startedAt: start.addingTimeInterval(200), listened: 5)
        try database.recordListen(trackId: 2, startedAt: start.addingTimeInterval(300), listened: 60)
        #expect(try database.recordListen(trackId: 999, startedAt: start, listened: 100) == nil)

        let log = try database.listens()
        #expect(log.map(\.counted) == [true, false, false])
        #expect(log.map(\.skipped) == [false, true, false])
        #expect(log.allSatisfy { $0.source == Listen.Source.mac })
        #expect(log[0].artist == "The Beatles" && log[0].title == "Come Together" && log[0].album == "Abbey Road")

        let tracks = try database.writer.read { try Track.fetchAll($0, keys: [1, 2]) }
        #expect(tracks[0].playCount == 1 && tracks[0].skipCount == 1)
        #expect(tracks[0].lastPlayedAt == start.addingTimeInterval(170))
        #expect(tracks[1].playCount == 0 && tracks[1].skipCount == 0)
        #expect(try database.listens(since: start.addingTimeInterval(100)).count == 2)
    }

    @Test func logsDevicePlaysOnce() throws {
        let database = try LibraryDatabaseTests.seeded()
        let at: Int64 = 1_800_000_000_000
        let events = [
            DeviceHistoryEvent(id: "a", trackId: 3, kind: .play, value: 150, atMs: at),
            DeviceHistoryEvent(id: "b", trackId: 3, kind: .skip, value: 4, atMs: at + 1000),
        ]
        try database.applyDeviceHistory(events, deviceId: "phone")
        try database.applyDeviceHistory(events, deviceId: "phone")
        let log = try database.listens()
        #expect(log.count == 2)
        #expect(log.allSatisfy { $0.source == "device:phone" && $0.trackId == 3 })
        #expect(log[0].counted && !log[0].skipped && log[0].listened == 150)
        #expect(log[1].skipped && !log[1].counted)
    }

    @Test func keepsListensOfRemovedSongs() throws {
        let database = try LibraryDatabaseTests.seeded()
        try database.recordListen(trackId: 4, startedAt: .now, listened: 180)
        try database.writer.write { try $0.execute(sql: "DELETE FROM track WHERE id = 4") }
        let listen = try #require(try database.listens().first)
        #expect(listen.trackId == nil && listen.title == "Paranoid Android")
    }

    @Test func summarizesEarlierPlaysWhenTheLogArrives() throws {
        let queue = try DatabaseQueue()
        var migrator = LibraryDatabase.migrator
        try migrator.migrate(queue, upTo: "v12-deviceHistory")
        let played = Date(timeIntervalSince1970: 1_700_000_000)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO libraryRoot (id, path, bookmark, addedAt) VALUES (1, '/m', x'', '2020-01-01')")
            var track = LibraryDatabaseTests.makeTrack(rootId: 1, "Airbag", artist: "Radiohead", album: "OK Computer", number: 1)
            track.playCount = 7
            track.lastPlayedAt = played
            try track.insert(db)
            var never = LibraryDatabaseTests.makeTrack(rootId: 1, "Lucky", artist: "Radiohead", album: "OK Computer", number: 11)
            try never.insert(db)
        }
        try migrator.migrate(queue)
        let rows = try queue.read { try Listen.fetchAll($0) }
        #expect(rows.count == 1)
        #expect(rows[0].source == Listen.Source.summary && rows[0].count == 7 && rows[0].startedAt == played && rows[0].counted)
    }
}
