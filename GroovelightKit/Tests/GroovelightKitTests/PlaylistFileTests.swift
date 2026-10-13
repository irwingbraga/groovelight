import Foundation
import GRDB
import Testing
@testable import LibraryKit

struct PlaylistFileTests {
    let folder = URL(fileURLWithPath: "/music/Playlists")

    @Test func readsExtendedM3U() throws {
        let text = """
            \u{FEFF}#EXTM3U
            #PLAYLIST:Road Trip
            #EXTINF:259,The Beatles - Come Together
            #EXTALB:Abbey Road
            ../The Beatles/Abbey Road/1 Come Together.flac
            #EXTINF:-1,Radio
            http://radio.example/stream
            file:///music/Radiohead/OK%20Computer/2%20Paranoid%20Android.flac
            C:\\Music\\song.mp3
            """
        let documents = try PlaylistFile.parse(Data(text.utf8), format: .m3u8, name: "file", folder: folder)
        let document = try #require(documents.first)
        #expect(document.name == "Road Trip")
        #expect(document.entries.count == 4)
        #expect(document.entries[0] == PlaylistEntry(path: "/music/The Beatles/Abbey Road/1 Come Together.flac", title: "Come Together",
                                                     artist: "The Beatles", album: "Abbey Road", duration: 259))
        #expect(document.entries[1].path == nil)
        #expect(document.entries[2].path == "/music/Radiohead/OK Computer/2 Paranoid Android.flac")
        #expect(document.entries[3].path == nil)
    }

    @Test func readsLatin1M3U() throws {
        let data = try #require("#EXTINF:100,Café Tacvba - Eres\n/music/café.mp3\n".data(using: .windowsCP1252))
        let entry = try #require(try PlaylistFile.parse(data, format: .m3u, name: "Old", folder: folder).first?.entries.first)
        #expect(entry.artist == "Café Tacvba")
        #expect(entry.path == "/music/café.mp3")
    }

    @Test func readsPLS() throws {
        let text = """
            [playlist]
            File2=/music/b.mp3
            Title2=Other - B
            File1=a.mp3
            Title1=A
            Length1=61
            NumberOfEntries=2
            Version=2
            """
        let entries = try #require(try PlaylistFile.parse(Data(text.utf8), format: .pls, name: "P", folder: folder).first).entries
        #expect(entries == [PlaylistEntry(path: "/music/Playlists/a.mp3", title: "A", duration: 61),
                            PlaylistEntry(path: "/music/b.mp3", title: "B", artist: "Other")])
    }

    @Test func readsXSPFAndWPL() throws {
        let xspf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <playlist version="1" xmlns="http://xspf.org/ns/0/">
              <title>Mix</title>
              <trackList>
                <track><location>file:///music/a%20b.flac</location><title>A B</title><creator>X</creator>
                  <album>Y</album><duration>90500</duration></track>
                <track><location>sub/c%20d.mp3</location><title>C</title></track>
              </trackList>
            </playlist>
            """
        let mix = try #require(try PlaylistFile.parse(Data(xspf.utf8), format: .xspf, name: "file", folder: folder).first)
        #expect(mix.name == "Mix")
        #expect(mix.entries == [PlaylistEntry(path: "/music/a b.flac", title: "A B", artist: "X", album: "Y", duration: 90.5),
                                PlaylistEntry(path: "/music/Playlists/sub/c d.mp3", title: "C")])

        let wpl = """
            <?wpl version="1.0"?>
            <smil><head><title>Windows List</title></head>
            <body><seq><media src="..\\Rock\\song.wma"/><media src="/music/x.mp3"/></seq></body></smil>
            """
        let list = try #require(try PlaylistFile.parse(Data(wpl.utf8), format: .wpl, name: "file", folder: folder).first)
        #expect(list.name == "Windows List")
        #expect(list.entries.map(\.path) == ["/music/Rock/song.wma", "/music/x.mp3"])
    }

    @Test func readsMusicXMLSkippingBuiltInPlaylists() throws {
        let plist: [String: Any] = [
            "Tracks": ["7": ["Name": "Song", "Artist": "Band", "Album": "LP", "Total Time": 200_000,
                             "Location": "file:///music/Band/LP/Song.m4a"]],
            "Playlists": [
                ["Name": "Library", "Master": true, "Playlist Items": [["Track ID": 7]]],
                ["Name": "Music", "Distinguished Kind": 4, "Playlist Items": [["Track ID": 7]]],
                ["Name": "Favorites", "Playlist Items": [["Track ID": 7], ["Track ID": 99]]],
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let documents = try PlaylistFile.parse(data, format: .musicXML, name: "file", folder: folder)
        #expect(documents == [PlaylistDocument(name: "Favorites", entries: [
            PlaylistEntry(path: "/music/Band/LP/Song.m4a", title: "Song", artist: "Band", album: "LP", duration: 200),
        ])])
    }

    @Test func writtenPlaylistsReadBackInEveryFormat() throws {
        let tracks = [
            LibraryDatabaseTests.makeTrack(rootId: 1, "Come Together", artist: "The Beatles", album: "Abbey Road", number: 1),
            LibraryDatabaseTests.makeTrack(rootId: 1, "Ação & Reação", artist: "Ç <Band>", album: "Álbum", number: 2),
        ]
        for format in PlaylistFormat.exportable {
            for style in [PlaylistFile.PathStyle.absolute, .relative(to: folder)] {
                let data = PlaylistFile.write(name: "Trip & Back", tracks: tracks, format: format, paths: style)
                let document = try #require(try PlaylistFile.parse(data, format: format, name: "file", folder: folder).first,
                                            "\(format)")
                #expect(document.entries.map(\.path) == tracks.map(\.path), "\(format) \(style)")
                #expect(document.entries.map(\.title) == tracks.map(\.title), "\(format)")
                if format != .pls { #expect(document.name == "Trip & Back", "\(format)") }
            }
        }
        // Plain M3U falls back to UTF-8 only when Latin-1 cannot hold the text.
        let japanese = LibraryDatabaseTests.makeTrack(rootId: 1, "夜に駆ける", artist: "YOASOBI", album: "THE BOOK", number: 1)
        let data = PlaylistFile.write(name: "J", tracks: [japanese], format: .m3u)
        #expect(String(data: data, encoding: .utf8)?.contains("夜に駆ける") == true)
    }

    @Test func relativePaths() {
        #expect(PlaylistFile.relativePath("/music/A/b.mp3", from: "/music/Playlists") == "../A/b.mp3")
        #expect(PlaylistFile.relativePath("/music/Playlists/b.mp3", from: "/music/Playlists") == "b.mp3")
        #expect(PlaylistFile.relativePath("/Volumes/X/b.mp3", from: "/music") == "/Volumes/X/b.mp3")
    }

    @Test func matchesEntriesByPathThenTags() throws {
        let database = try LibraryDatabaseTests.seeded()
        try database.writer.write { db in
            // A CUE album: two songs in one file.
            for (number, title) in [(1, "Intro"), (2, "Main Theme")] {
                var track = LibraryDatabaseTests.makeTrack(rootId: 1, title, artist: "Composer", album: "Score", number: number)
                track.path = "/music/Score/score.cue#\(number)"
                track.audioPath = "/music/Score/score.flac"
                track.startTime = Double(number - 1) * 100
                try track.insert(db)
            }
        }
        let entries = [
            PlaylistEntry(path: "/music/The Beatles/Abbey Road/2 Something.flac"),
            PlaylistEntry(path: "/elsewhere/Paranoid Android.mp3", title: "paranoid android", artist: "RADIOHEAD"),
            PlaylistEntry(path: "/music/Score/score.flac", title: "Main Theme"),
            PlaylistEntry(title: "Come Together", artist: "Someone Else"),
            PlaylistEntry(path: "C:/nope.mp3"),
        ]
        let ids = try database.writer.read { try LibraryDatabase.matchPlaylistEntries($0, entries) }
        let titles = try database.writer.read { db in
            try ids.map { id in try id.flatMap { try Track.fetchOne(db, key: $0)?.title } }
        }
        #expect(titles == ["Something", "Paranoid Android", "Main Theme", nil, nil])
    }
}
