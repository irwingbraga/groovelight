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
        let mix = try database.createPlaylist(named: "Mix", trackIds: [id("Paranoid Android"), id("Something"), id("Come Together")])
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
        // It travels as JSON (dates to the second).
        let json = try JSONEncoder.withISODates.encode(snapshot)
        let decoded = try JSONDecoder.withISODates.decode(DeviceSnapshot.self, from: json)
        #expect(try JSONEncoder.withISODates.encode(decoded) == json)
        #expect(decoded.songs.count == 3 && decoded.playlists == snapshot.playlists)
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
