import Foundation
import GRDB
import Testing
@testable import LibraryKit

struct ClassicalGroupingTests {
    typealias Song = ClassicalGrouping.Song

    @Test func classicalGenresAreWholeWords() {
        for genre in ["Classical", "Clássica", "Baroque", "Música de concerto", "Opera", "Western Classical", "Rock; Classical", "Kammermusik"] {
            #expect(ClassicalGrouping.isClassicalGenre(genre), "\(genre)")
        }
        for genre in ["Classic Rock", "Neoclassical Metal", "Classical Crossover", "Symphonic Metal", "Progressive Rock;Classic Rock", nil] {
            #expect(!ClassicalGrouping.isClassicalGenre(genre), "\(genre ?? "nil")")
        }
    }

    @Test func composerTagsAreReadAsNames() {
        #expect(ClassicalGrouping.composers(in: "Bach, Johann Sebastian") == ["Johann Sebastian Bach"])
        #expect(ClassicalGrouping.composers(in: "Antonio Vivaldi; Georg Friedrich Händel") == ["Antonio Vivaldi", "Georg Friedrich Händel"])
        #expect(ClassicalGrouping.composers(in: "Anonyme").isEmpty)
        #expect(ClassicalGrouping.composers(in: "Traditional").isEmpty)
        #expect(ClassicalGrouping.composers(in: nil).isEmpty)
    }

    @Test func shortNamesJoinTheFullName() {
        let names = ClassicalGrouping.canonicalNames(["Antonio Vivaldi", "Vivaldi", "Palestrina", "Giovanni Pierluigi da Palestrina",
                                                      "J.S. Bach", "Johann Sebastian Bach", "C.P.E. Bach", "Carl Philipp Emanuel Bach",
                                                      "Bach", "ANTONIO VIVALDI"])
        #expect(names["Vivaldi"] == "Antonio Vivaldi")
        #expect(names["ANTONIO VIVALDI"] == "Antonio Vivaldi")
        #expect(names["Palestrina"] == "Giovanni Pierluigi da Palestrina")
        #expect(names["J.S. Bach"] == "Johann Sebastian Bach")
        #expect(names["C.P.E. Bach"] == "Carl Philipp Emanuel Bach")
        // Two Bachs: a bare "Bach" could be either, so it stays as it is.
        #expect(names["Bach"] == "Bach")
    }

    /// Patterns from a real library: one composer's albums under a different performer each time.
    @Test func classicalAlbumsAreListedByComposer() {
        var id: Int64 = 0
        func album(_ key: String, genre: String, composer: String?, artist: String, songs: Int = 2) -> [Song] {
            (0..<songs).map { _ in
                id += 1
                return Song(id: id, albumKey: key, genre: genre, composer: composer, artistName: artist)
            }
        }
        let podger = album("podger", genre: "Clássica", composer: "Antonio Vivaldi", artist: "Rachel Podger")
        let savall = album("savall", genre: "Baroque", composer: "Antonio Vivaldi", artist: "Jordi Savall")
        let niquet = album("niquet", genre: "Classical", composer: "Vivaldi", artist: "Vivaldi; Le Concert Spirituel, Hervé Niquet")
        let sixteen = album("sixteen", genre: "Clássica", composer: "Traditional", artist: "The Sixteen and Harry Christophers")
        let evanescenceClassical = album("ev1", genre: "Classical", composer: "Amy Lee", artist: "Evanescence")
        let evanescenceRock = album("ev2", genre: "Rock", composer: "Amy Lee", artist: "Evanescence")
        let rush = album("rush", genre: "Progressive Rock;Classic Rock", composer: "Geddy Lee;Alex Lifeson", artist: "Rush")
        let all = podger + savall + niquet + sixteen + evanescenceClassical + evanescenceRock + rush
        let groups = ClassicalGrouping.groups(for: all)

        for song in podger + savall + niquet { #expect(groups[song.id] == "Antonio Vivaldi") }
        // No composer to list it under, an artist with other music, and a rock genre: left under their artists.
        for song in sixteen + evanescenceClassical + evanescenceRock + rush { #expect(groups[song.id] == nil) }

        // Overrides, either way.
        let moved = ClassicalGrouping.groups(for: all, overrides: ["ev1": .composer, "podger": .artist])
        for song in evanescenceClassical { #expect(moved[song.id] == "Amy Lee") }
        for song in podger { #expect(moved[song.id] == nil) }
    }

    @Test func recitalsAreUnderEachComposer() {
        let songs = [
            Song(id: 1, albumKey: "arias", genre: "Opera", composer: "Georg Friedrich Händel", artistName: "Cecilia Bartoli"),
            Song(id: 2, albumKey: "arias", genre: "Opera", composer: "Antonio Vivaldi", artistName: "Cecilia Bartoli"),
            Song(id: 3, albumKey: "arias", genre: "Opera", composer: "Anonymous", artistName: "Cecilia Bartoli"),
        ]
        let groups = ClassicalGrouping.groups(for: songs)
        #expect(groups[1] == "Georg Friedrich Händel")
        #expect(groups[2] == "Antonio Vivaldi")
        #expect(groups[3] == nil)
    }

    @Test func libraryListsComposersApartFromArtists() throws {
        let database = try LibraryDatabase.inMemory()
        let root = try database.addRoot(path: "/music", bookmark: Data())
        func song(_ title: String, artist: String, album: String, number: Int, genre: String, composer: String?) -> Track {
            var track = LibraryDatabaseTests.makeTrack(rootId: root.id!, title, artist: artist, album: album, number: number)
            track.genre = genre
            track.composer = composer
            return track
        }
        let songs = [
            song("Spring", artist: "Rachel Podger", album: "The Four Seasons", number: 1, genre: "Classical", composer: "Antonio Vivaldi"),
            song("Summer", artist: "Rachel Podger", album: "The Four Seasons", number: 2, genre: "Classical", composer: "Antonio Vivaldi"),
            song("Gloria", artist: "Le Concert Spirituel", album: "Gloria", number: 1, genre: "Baroque", composer: "Vivaldi"),
            song("Come Together", artist: "The Beatles", album: "Abbey Road", number: 1, genre: "Rock", composer: "Lennon-McCartney"),
        ]
        try database.writer.write { db in
            for var track in songs { try track.insert(db) }
        }
        // As after a scan.
        try database.writer.write { db in try LibraryDatabase.refreshComposerGroups(db) }

        let (artists, composers, vivaldi) = try database.writer.read { db in
            (try LibraryDatabase.artists(db, includingComposerAlbums: false).map(\.name), try LibraryDatabase.composers(db),
             try LibraryDatabase.albums(db, composer: "Antonio Vivaldi").map(\.title))
        }
        #expect(artists == ["The Beatles"])
        #expect(composers.map(\.name) == ["Antonio Vivaldi"])
        #expect(composers.first?.albumCount == 2)
        #expect(vivaldi == ["Gloria", "The Four Seasons"] || Set(vivaldi) == ["Gloria", "The Four Seasons"])
        // Performers still have their page.
        #expect(try database.writer.read { try LibraryDatabase.hasArtist($0, named: "rachel podger") })

        // Listed under its artist instead, from its page.
        let key = Track.makeAlbumKey(album: "The Four Seasons", albumArtist: nil, artist: "Rachel Podger", isCompilation: false)
        try database.setAlbumGrouping(.artist, albumKey: key)
        let after = try database.writer.read { db in
            (try LibraryDatabase.artists(db, includingComposerAlbums: false).map(\.name), try LibraryDatabase.albumGrouping(db, albumKey: key))
        }
        #expect(after.0 == ["Rachel Podger", "The Beatles"])
        #expect(after.1 == .artist)
        try database.setAlbumGrouping(nil, albumKey: key)
        #expect(try database.writer.read { try LibraryDatabase.artists($0, includingComposerAlbums: false).map(\.name) } == ["The Beatles"])
        // Everyone else (links, pickers, the phone apps without Composers) still sees the performers.
        #expect(try database.writer.read { try LibraryDatabase.artists($0).count } == 3)

        // A fix that changes the genre moves the album back to Artists.
        let gloria = try database.writer.read { db in try Track.filter(Column("album") == "Gloria").fetchAll(db) }
        try database.applyMetadata(Dictionary(uniqueKeysWithValues: gloria.map { ($0.id!, TrackMetadata(genre: "Pop")) }), asOverrides: true)
        #expect(try database.writer.read { try LibraryDatabase.composers($0).first?.albumCount } == 1)
    }

    /// The phone apps list by composer as the Mac decided: the snapshot and the catalog carry each song's composer.
    @Test func phonesGetTheMacsComposers() throws {
        let mac = try LibraryDatabase.inMemory()
        let root = try mac.addRoot(path: "/music", bookmark: Data())
        var vivaldi = LibraryDatabaseTests.makeTrack(rootId: root.id!, "Spring", artist: "Rachel Podger", album: "The Four Seasons", number: 1)
        vivaldi.genre = "Classical"
        vivaldi.composer = "Vivaldi, Antonio"
        var beatles = LibraryDatabaseTests.makeTrack(rootId: root.id!, "Something", artist: "The Beatles", album: "Abbey Road", number: 2)
        try mac.writer.write { db in
            try vivaldi.insert(db)
            try beatles.insert(db)
            try LibraryDatabase.refreshComposerGroups(db)
        }
        let paths = [vivaldi.id!: "a.flac", beatles.id!: "b.flac"]
        let (snapshot, catalog) = try mac.writer.read { db in
            (try DeviceSnapshot.build(db, paths: paths), try DeviceCatalog.build(db, selection: DeviceSelection()))
        }
        #expect(snapshot.songs.first { $0.id == vivaldi.id }?.composer == "Antonio Vivaldi")
        #expect(snapshot.songs.first { $0.id == beatles.id }?.composer == nil)
        #expect(catalog.songs.first { $0.id == vivaldi.id }?.composer == "Antonio Vivaldi")

        // Through JSON, as sent, into a phone's database.
        let decoded = try JSONDecoder().decode(DeviceSnapshot.self, from: try JSONEncoder().encode(snapshot))
        let phone = try LibraryDatabase.inMemory()
        try phone.importSnapshot(decoded, musicFolder: URL(fileURLWithPath: "/device/Music"))
        let (artists, composers) = try phone.writer.read { db in
            (try LibraryDatabase.artists(db, includingComposerAlbums: false).map(\.name), try LibraryDatabase.composers(db).map(\.name))
        }
        #expect(artists == ["The Beatles"])
        #expect(composers == ["Antonio Vivaldi"])
    }
}
