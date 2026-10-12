import Foundation
import GRDB
import Testing
@testable import LibraryKit

struct LibraryDatabaseTests {
    static func makeTrack(rootId: Int64, _ title: String, artist: String, album: String, number: Int, compilation: Bool = false) -> Track {
        Track(id: nil, rootId: rootId, path: "/music/\(artist)/\(album)/\(number) \(title).flac", fileSize: 1, modifiedAt: .now,
              title: title, artist: artist, album: album, albumArtist: nil, composer: nil, genre: "Rock", year: 1969,
              trackNumber: number, trackTotal: nil, discNumber: 1, discTotal: nil, isCompilation: compilation, bpm: nil,
              comment: nil, lyrics: nil, musicBrainzRecordingId: nil, musicBrainzReleaseId: nil, replayGainTrackGain: nil,
              replayGainAlbumGain: nil, duration: 180, format: "FLAC", sampleRate: 44_100, bitDepth: 16, bitrate: nil,
              channels: 2, artworkHash: nil,
              albumKey: Track.makeAlbumKey(album: album, albumArtist: nil, artist: artist, isCompilation: compilation),
              rating: 0, isLoved: false, playCount: 0, skipCount: 0, lastPlayedAt: nil, dateAdded: .now)
    }

    static func seeded() throws -> LibraryDatabase {
        let database = try LibraryDatabase.inMemory()
        let root = try database.addRoot(path: "/music", bookmark: Data())
        try database.writer.write { db in
            for var track in [
                makeTrack(rootId: root.id!, "Come Together", artist: "The Beatles", album: "Abbey Road", number: 1),
                makeTrack(rootId: root.id!, "Something", artist: "The Beatles", album: "Abbey Road", number: 2),
                makeTrack(rootId: root.id!, "Yellow Submarine", artist: "The Beatles", album: "Revolver", number: 6),
                makeTrack(rootId: root.id!, "Paranoid Android", artist: "Radiohead", album: "OK Computer", number: 2),
                makeTrack(rootId: root.id!, "Song A", artist: "Someone", album: "Hits 1999", number: 1, compilation: true),
                makeTrack(rootId: root.id!, "Song B", artist: "Other", album: "Hits 1999", number: 2, compilation: true),
            ] {
                try track.insert(db)
            }
        }
        return database
    }

    @Test func groupsAlbumsAndArtists() throws {
        let database = try Self.seeded()
        let albums = try database.writer.read { try LibraryDatabase.albums($0, sort: .title) }
        #expect(albums.map(\.title) == ["Abbey Road", "Hits 1999", "OK Computer", "Revolver"])
        #expect(albums.first { $0.title == "Hits 1999" }?.artist == "Various Artists")
        #expect(albums.first { $0.title == "Abbey Road" }?.trackCount == 2)

        let artists = try database.writer.read { try LibraryDatabase.artists($0) }
        #expect(artists.map(\.name) == ["Radiohead", "The Beatles"])
        #expect(artists.last?.albumCount == 2)

        let beatlesAlbums = try database.writer.read { try LibraryDatabase.albums($0, artist: "the beatles") }
        #expect(beatlesAlbums.count == 2)
    }

    @Test func albumTracksAreOrdered() throws {
        let database = try Self.seeded()
        let key = Track.makeAlbumKey(album: "Abbey Road", albumArtist: nil, artist: "The Beatles", isCompilation: false)
        let tracks = try database.writer.read { try LibraryDatabase.tracks($0, albumKey: key) }
        #expect(tracks.map(\.title) == ["Come Together", "Something"])
    }

    @Test func fullTextSearchWithPrefixes() throws {
        let database = try Self.seeded()
        let results = try database.writer.read { try LibraryDatabase.search($0, query: "beat yell") }
        #expect(results.songs.map(\.title) == ["Yellow Submarine"])
        let none = try database.writer.read { try LibraryDatabase.search($0, query: "  ") }
        #expect(none.isEmpty)
    }

    @Test func searchFindsEveryCategory() throws {
        let database = try Self.seeded()
        let abbey = Track.makeAlbumKey(album: "Abbey Road", albumArtist: nil, artist: "The Beatles", isCompilation: false)
        let ok = Track.makeAlbumKey(album: "OK Computer", albumArtist: nil, artist: "Radiohead", isCompilation: false)
        try database.setCredits([
            CreditIndexEntry(person: CreditPerson(name: "George Martin", artistId: "gm"), albumKey: abbey, trackId: nil,
                             roles: ["producer"], wholeRelease: true),
            CreditIndexEntry(person: CreditPerson(name: "The Beatles", artistId: "tb"), albumKey: abbey, trackId: nil, roles: ["performer"]),
        ], albumKey: abbey)
        try database.setCredits([
            CreditIndexEntry(person: CreditPerson(name: "Nigel Godrich", artistId: "ng"), albumKey: ok, trackId: nil, roles: ["producer"]),
            CreditIndexEntry(person: CreditPerson(name: "Nigel Godrich", artistId: "ng"), albumKey: ok, trackId: 4, roles: ["engineer"]),
        ], albumKey: ok)

        let beatles = try database.writer.read { try LibraryDatabase.search($0, query: "beatles") }
        #expect(beatles.artists.map(\.name) == ["The Beatles"])
        #expect(Set(beatles.albums.map(\.title)) == ["Abbey Road", "Revolver"])
        #expect(beatles.songs.count == 3)
        // A credited name that is also a library artist shows only as the artist.
        #expect(beatles.people.isEmpty)

        let abbeyRoad = try database.writer.read { try LibraryDatabase.search($0, query: "abbey") }
        #expect(abbeyRoad.albums.map(\.title) == ["Abbey Road"])
        #expect(abbeyRoad.artists.isEmpty)

        let nigel = try database.writer.read { try LibraryDatabase.search($0, query: "godr") }
        #expect(nigel.people.map(\.person.name) == ["Nigel Godrich"])
        #expect(nigel.people.first?.albumCount == 1)
        #expect(nigel.people.first?.roles == ["engineer", "producer"])

        // Accents and case are ignored, and an exact title ranks first.
        let radiohead = try database.writer.read { try LibraryDatabase.search($0, query: "RÁDIOHEAD") }
        #expect(radiohead.artists.map(\.name) == ["Radiohead"])
        #expect(radiohead.albums.map(\.title) == ["OK Computer"])
    }

    @Test func searchMatcherScores() {
        let matcher = SearchMatcher("ok comp")
        #expect(matcher.score("OK Computer") == 1)
        #expect(matcher.score("Computer, OK?") == 2)
        #expect(matcher.score("Okay") == nil)
        #expect(SearchMatcher("ac dc").score("AC/DC") == 0)
        #expect(SearchMatcher("bjork").score("Björk") == 0)
    }

    @Test func playlistCoversPersist() throws {
        let database = try Self.seeded()
        let cover = PlaylistCover(kind: .generated(palette: "sunset", pattern: "vinyl"), showsTitle: true)
        let playlist = try database.createPlaylist(named: "Mix", cover: cover)
        let id = try #require(playlist.id)
        #expect(try database.writer.read { try Playlist.fetchOne($0, key: id) }?.coverStyle == cover)

        let image = PlaylistCover(kind: .image(hash: "abc"))
        try database.updatePlaylist(id, name: "Renamed", cover: image)
        let updated = try database.writer.read { try Playlist.fetchOne($0, key: id) }
        #expect(updated?.name == "Renamed" && updated?.coverStyle == image)

        try database.updatePlaylist(id, name: "Renamed", cover: nil)
        #expect(try database.writer.read { try Playlist.fetchOne($0, key: id) }?.coverStyle == nil)
    }

    @Test func playlistsKeepOrder() throws {
        let database = try Self.seeded()
        let ids = try database.writer.read { try Int64.fetchAll($0, sql: "SELECT id FROM track ORDER BY id DESC LIMIT 3") }
        let playlist = try database.createPlaylist(named: "Mix", trackIds: ids)
        try database.addTracks([ids[0]], toPlaylist: playlist.id!)
        let tracks = try database.writer.read { try LibraryDatabase.tracks($0, playlistId: playlist.id!) }
        #expect(tracks.compactMap(\.id) == ids + [ids[0]])
    }

    @Test func albumKeyIgnoresCaseAndLeadingThe() {
        #expect(Track.makeAlbumKey(album: "Abbey Road", albumArtist: nil, artist: "The Beatles", isCompilation: false)
            == Track.makeAlbumKey(album: "abbey road ", albumArtist: "Beatles", artist: nil, isCompilation: false))
    }

    @Test func parsesYears() {
        #expect(TagReader.parseYear("1999-03-02") == 1999)
        #expect(TagReader.parseYear("03/02/2004") == 2004)
        #expect(TagReader.parseYear("unknown") == nil)
    }
}
