import Foundation
import GRDB
import Testing
@testable import LibraryKit

struct DeviceSnapshotTests {
    @Test func describesTheSongsOnTheDevice() throws {
        let database = try LibraryDatabaseTests.seeded()
        let tracks = try database.writer.read { try LibraryDatabase.allTracks($0) }
        let id = { (title: String) in tracks.first { $0.title == title }!.id! }
        try database.setLoved(true, trackId: id("Something"), at: Date(timeIntervalSince1970: 1_700_000_000))
        // A playlist with a song on the device and one that is not, and one with none of them.
        var mix = try database.createPlaylist(named: "Mix", trackIds: [id("Paranoid Android"), id("Something"), id("Come Together")])
        mix.cover = try JSONEncoder().encode(PlaylistCover(kind: .image(hash: "cafe"), showsTitle: false))
        try database.writer.write { [mix] db in try mix.update(db) }
        _ = try database.createPlaylist(named: "Elsewhere", trackIds: [id("Yellow Submarine")])

        let paths = [id("Something"): "Music/The Beatles/Abbey Road/02 Something.flac",
                     id("Come Together"): "Music/The Beatles/Abbey Road/01 Come Together.flac",
                     id("Song A"): "Music/Compilations/Hits 1999/01 Song A.flac"]
        let snapshot = try database.writer.read {
            try DeviceSnapshot.build($0, paths: paths, codecs: [id("Come Together"): "flac"], now: Date(timeIntervalSince1970: 1_800_000_000))
        }
        #expect(snapshot.songs.map(\.title).sorted() == ["Come Together", "Something", "Song A"])
        let something = try #require(snapshot.songs.first { $0.title == "Something" })
        #expect(something.path == "Music/The Beatles/Abbey Road/02 Something.flac")
        #expect(something.loved && something.lovedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(snapshot.songs.first { $0.title == "Come Together" }?.codec == "flac")
        // Albums of those songs only; compilations under Various Artists.
        #expect(snapshot.albums.map(\.title).sorted() == ["Abbey Road", "Hits 1999"])
        #expect(snapshot.albums.first { $0.title == "Hits 1999" }?.artist == "Various Artists")
        // Playlists keep their order, with the songs that are on the device.
        #expect(snapshot.playlists.map(\.name) == ["Mix"])
        #expect(snapshot.playlists.first?.id == mix.id)
        #expect(snapshot.playlists.first?.songIds == [id("Something"), id("Come Together")])
        #expect(snapshot.playlists.first?.cover == DeviceSnapshot.Cover(style: "image", imageHash: "cafe", showsTitle: false))
        // Credits of those albums only, and of songs on the device.
        try database.setCredits([
            CreditIndexEntry(person: CreditPerson(name: "George Martin", artistId: nil), albumKey: tracks.first { $0.title == "Something" }!.albumKey,
                             trackId: nil, roles: ["producer"]),
            CreditIndexEntry(person: CreditPerson(name: "Ringo Starr", artistId: nil), albumKey: tracks.first { $0.title == "Something" }!.albumKey,
                             trackId: id("Paranoid Android"), roles: ["drums"]),
        ], albumKey: tracks.first { $0.title == "Something" }!.albumKey)
        let credited = try database.writer.read { try DeviceSnapshot.build($0, paths: paths) }
        #expect(credited.credits?.map(\.name) == ["George Martin"])
        #expect(credited.credits?.first?.roles == ["producer"] && credited.credits?.first?.trackId == nil)
        // It travels as JSON (dates to the second).
        let json = try JSONEncoder.withISODates.encode(snapshot)
        let decoded = try JSONDecoder.withISODates.decode(DeviceSnapshot.self, from: json)
        #expect(try JSONEncoder.withISODates.encode(decoded) == json)
        #expect(decoded.songs.count == 3 && decoded.playlists == snapshot.playlists)
    }
}

extension DeviceSnapshotTests {
    @Test func catalogsTheWholeLibraryWithTheDevicesChoice() throws {
        let database = try LibraryDatabaseTests.seeded()
        let tracks = try database.writer.read { try LibraryDatabase.allTracks($0) }
        var selection = DeviceSelection()
        selection.albumKeys = [tracks[0].albumKey]
        selection.trackIds = [tracks[1].id!]
        selection.lovedSongs = true
        let catalog = try database.writer.read { try DeviceCatalog.build($0, selection: selection) }
        #expect(catalog.songs.count == tracks.count)
        #expect(Set(catalog.albums.map(\.key)) == Set(tracks.map(\.albumKey)))
        #expect(catalog.albums.first { $0.title == "Hits 1999" }?.artist == "Various Artists")
        #expect(catalog.chosen.albumKeys == [tracks[0].albumKey] && catalog.chosen.trackIds == [tracks[1].id!] && catalog.chosen.hasOthers)
        // Songs chosen one by one go to the device with the rest.
        var songs = DeviceSelection()
        songs.trackIds = [tracks[1].id!]
        #expect(try database.writer.read { try LibraryDatabase.deviceContents($0, songs) }.tracks.map(\.id) == [tracks[1].id])
    }
}

extension DeviceSnapshotTests {
    @Test func lovesAndRatingsFromADeviceReachTheLibrary() throws {
        let database = try LibraryDatabaseTests.seeded()
        let tracks = try database.writer.read { try LibraryDatabase.allTracks($0) }
        let id = { (title: String) in tracks.first { $0.title == title }!.id! }
        let early = Int64(1_700_000_000_000), late = Int64(1_800_000_000_000)
        // Loved here later than the device's unlove: stays loved. Not loved here: the device's love and rating apply.
        try database.setLoved(true, trackId: id("Something"), at: Date(timeIntervalSince1970: Double(late) / 1000))
        let changed = try database.applyDeviceHistory([
            DeviceHistoryEvent(id: "1", trackId: id("Something"), kind: .love, value: 0, atMs: early),
            DeviceHistoryEvent(id: "2", trackId: id("Come Together"), kind: .love, value: 1, atMs: early),
            DeviceHistoryEvent(id: "3", trackId: id("Come Together"), kind: .rating, value: 4, atMs: early),
        ]).loves
        #expect(changed.map(\.trackId) == [id("Come Together")] && changed.first?.loved == true)
        let after = try database.writer.read { try LibraryDatabase.allTracks($0) }
        let something = try #require(after.first { $0.title == "Something" }), together = try #require(after.first { $0.title == "Come Together" })
        #expect(something.isLoved && together.isLoved && together.rating == 4)
        #expect(together.lovedAt == Date(timeIntervalSince1970: Double(early) / 1000))
        // Sent again (a retry): nothing changes.
        #expect(try database.applyDeviceHistory([DeviceHistoryEvent(id: "2", trackId: id("Come Together"), kind: .love, value: 1, atMs: early)]).isEmpty)
        // An unlove made on the device after the Mac's love wins.
        let unloved = try database.applyDeviceHistory([DeviceHistoryEvent(id: "4", trackId: id("Something"), kind: .love, value: 0, atMs: late + 1)]).loves
        #expect(unloved.first?.loved == false)
    }

    @Test func playsFromADeviceCountOnceAndKeepTheirTimes() throws {
        let database = try LibraryDatabaseTests.seeded()
        let tracks = try database.writer.read { try LibraryDatabase.allTracks($0) }
        let song = try #require(tracks.first { $0.title == "Something" }).id!
        let early = Int64(1_700_000_000_000), late = Int64(1_800_000_000_000)
        let events = [
            DeviceHistoryEvent(id: "a", trackId: song, kind: .play, value: 180, atMs: late),
            DeviceHistoryEvent(id: "b", trackId: song, kind: .play, value: 200, atMs: early),
            DeviceHistoryEvent(id: "c", trackId: song, kind: .skip, value: 5, atMs: late + 1),
            DeviceHistoryEvent(id: "d", trackId: song, kind: .unknown, value: 1, atMs: late),
        ]
        let changes = try database.applyDeviceHistory(events, deviceId: "phone")
        #expect(changes.plays.map(\.startedAt) == [early, late].map { Date(timeIntervalSince1970: Double($0) / 1000) })
        #expect(changes.plays.map(\.listened) == [200, 180])
        var track = try #require(try database.writer.read { try Track.fetchOne($0, key: song) })
        // Last Played is the newest play, whatever order they came in.
        #expect(track.playCount == 2 && track.skipCount == 1 && track.lastPlayedAt == Date(timeIntervalSince1970: Double(late) / 1000))
        // Sent again (the answer was lost): counted once. The same ids from another device count.
        #expect(try database.applyDeviceHistory(events, deviceId: "phone").isEmpty)
        try database.applyDeviceHistory(Array(events.prefix(1)), deviceId: "player")
        track = try #require(try database.writer.read { try Track.fetchOne($0, key: song) })
        #expect(track.playCount == 3 && track.skipCount == 1)
    }

    @Test func playlistsEditedOnADeviceChangeTheLibrary() throws {
        let database = try LibraryDatabaseTests.seeded()
        let ids = try database.writer.read { try LibraryDatabase.allTracks($0) }.compactMap(\.id)
        let at = Int64(1_800_000_000_000)
        func playlist(_ name: String) throws -> Playlist? {
            try database.writer.read { try Playlist.filter(Column("name") == name).fetchOne($0) }
        }
        func songs(_ name: String) throws -> [Int64] {
            let id = try #require(try playlist(name)?.id)
            return try database.writer.read { try LibraryDatabase.tracks($0, playlistId: id).compactMap(\.id) }
        }
        // Made on the device (id -5), songs added and removed there, then renamed: one batch.
        let first = [
            DeviceHistoryEvent(id: "1", kind: .playlistCreate, atMs: at, playlistId: -5, name: "Car", trackIds: [ids[0], 99_999]),
            DeviceHistoryEvent(id: "2", kind: .playlistAdd, atMs: at, playlistId: -5, trackIds: [ids[1], ids[2]]),
            DeviceHistoryEvent(id: "3", kind: .playlistRemove, atMs: at, playlistId: -5, trackIds: [ids[1]]),
        ]
        try database.applyDeviceHistory(first, deviceId: "phone")
        // Sent again (the answer was lost): nothing twice.
        try database.applyDeviceHistory(first, deviceId: "phone")
        #expect(try songs("Car") == [ids[0], ids[2]])
        // Later, still with the device's id (before its next sync), and then with the Mac's.
        try database.applyDeviceHistory([DeviceHistoryEvent(id: "4", kind: .playlistRename, atMs: at, playlistId: -5, name: "Road")],
                                        deviceId: "phone")
        let made = try #require(try playlist("Road")).id!
        try database.applyDeviceHistory([DeviceHistoryEvent(id: "5", kind: .playlistAdd, atMs: at, playlistId: made, trackIds: [ids[1]])],
                                        deviceId: "phone")
        #expect(try songs("Road") == [ids[0], ids[2], ids[1]])
        // Another device's -5 is its own.
        try database.applyDeviceHistory([DeviceHistoryEvent(id: "1", kind: .playlistDelete, atMs: at, playlistId: -5)], deviceId: "player")
        #expect(try playlist("Road") != nil)
        try database.applyDeviceHistory([DeviceHistoryEvent(id: "6", kind: .playlistDelete, atMs: at, playlistId: -5)], deviceId: "phone")
        #expect(try playlist("Road") == nil)
    }

    @Test func artistPhotosGoWithTheirArtists() throws {
        let database = try LibraryDatabaseTests.seeded()
        let tracks = try database.writer.read { try LibraryDatabase.allTracks($0) }
        let id = { (title: String) in tracks.first { $0.title == title }!.id! }
        // Kept by lowercased name; one artist without a photo, one not on the device.
        try database.setArtistInfo(Data(#"{"fetchedAt":0,"imageHash":"beatles"}"#.utf8), name: "The Beatles")
        try database.setArtistInfo(Data(#"{"fetchedAt":0,"imageChecked":true}"#.utf8), name: "Radiohead")
        try database.setArtistInfo(Data(#"{"fetchedAt":0,"imageHash":"elsewhere"}"#.utf8), name: "Somebody Else")
        let snapshot = try database.writer.read {
            try DeviceSnapshot.build($0, paths: [id("Something"): "a.flac", id("Paranoid Android"): "b.flac"])
        }
        #expect(snapshot.artists == [DeviceSnapshot.Artist(name: "The Beatles", artworkHash: "beatles")])
        let catalog = try database.writer.read { try DeviceCatalog.build($0, selection: DeviceSelection()) }
        #expect(catalog.artists?.map(\.artworkHash) == ["beatles"])
    }

    @Test func historyFromANewerAppSkipsWhatItDoesNotKnow() throws {
        let json = #"[{"id":"1","trackId":3,"kind":"somethingNew","value":1,"atMs":1}]"#
        let events = try JSONDecoder().decode([DeviceHistoryEvent].self, from: Data(json.utf8))
        #expect(events.first?.kind == .unknown)
    }
}

private extension JSONEncoder {
    static var withISODates: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}

private extension JSONDecoder {
    static var withISODates: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
