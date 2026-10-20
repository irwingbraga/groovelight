import Foundation
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
