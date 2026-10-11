import Foundation
import GRDB
import Testing
@testable import LibraryKit

struct FileNamingTests {
    let options = OrganizeOptions()

    @Test func rendersTheDefaultTemplate() {
        let fields = NamingFields(title: "Karma Police", artist: "Radiohead", album: "OK Computer", albumArtist: "Radiohead",
                                  year: 1997, trackNumber: 6, discNumber: 1, discTotal: 1)
        #expect(FileNaming.relativePath(for: fields, fileExtension: "FLAC", options: options) == "Radiohead/OK Computer (1997)/06 Karma Police.flac")
    }

    @Test func optionalPartsDisappearWithoutValues() {
        var fields = NamingFields(title: "Song", artist: "Artist", album: "Album", trackNumber: 3)
        #expect(FileNaming.relativePath(for: fields, fileExtension: "mp3", options: options) == "Artist/Album/03 Song.mp3")
        // Multi-disc albums get the disc number; compilations go under Various Artists.
        fields.discNumber = 2
        fields.discTotal = 2
        fields.isCompilation = true
        #expect(FileNaming.relativePath(for: fields, fileExtension: "mp3", options: options) == "Various Artists/Album/2-03 Song.mp3")
        // No track number: the file name is just the title.
        let bare = NamingFields(title: "Loose Song")
        #expect(FileNaming.relativePath(for: bare, fileExtension: "m4a", options: options) == "Unknown Artist/Unknown Album/Loose Song.m4a")
    }

    @Test func sanitizesNames() {
        let fields = NamingFields(title: "Song: Part 1/2 ft. Someone?", artist: "AC/DC", album: "...Hidden.", albumArtist: "AC/DC",
                                  trackNumber: 1)
        #expect(FileNaming.relativePath(for: fields, fileExtension: "flac", options: options)
                == "AC-DC/Hidden/01 Song - Part 1-2 feat. Someone_.flac")
        var loose = options
        loose.portableNames = false
        #expect(FileNaming.relativePath(for: fields, fileExtension: "flac", options: loose).hasSuffix("Someone?.flac"))
        // Decomposed accents become composed.
        let decomposed = NamingFields(title: "Cafe\u{301}", trackNumber: 1)
        #expect(FileNaming.relativePath(for: decomposed, fileExtension: "mp3", options: options).hasSuffix("01 Caf\u{E9}.mp3"))
    }

    @Test func titleCasesWithExceptions() {
        #expect(FileNaming.titleCased("the end of the world as we know it") == "The End of the World as We Know It")
        #expect(FileNaming.titleCased("live in the USA") == "Live in the USA")
    }

    @Test func limitsLongNames() {
        let long = NamingFields(title: String(repeating: "é", count: 300), trackNumber: 1)
        let name = FileNaming.relativePath(for: long, fileExtension: "flac", options: options).split(separator: "/").last!
        #expect(name.utf8.count <= 255 && name.hasSuffix(".flac"))
    }

    @Test func keepsFilesInPlaceWithoutFolderOrganizing() {
        var flat = options
        flat.organizeFolders = false
        let fields = NamingFields(title: "Song", artist: "Artist", album: "Album", trackNumber: 1)
        #expect(FileNaming.relativePath(for: fields, fileExtension: "mp3", options: flat) == "01 Song.mp3")
    }
}

struct OrganizerTests {
    /// A library with real files in messy places.
    static func library() async throws -> (LibraryDatabase, URL, [URL]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-\(UUID().uuidString)")
        let files = try ScannerIntegrationTests.makeFixtures(in: directory.appendingPathComponent("Music/Messy Downloads"))
        // A cover next to the songs.
        try ScannerIntegrationTests.pngData().write(to: files[0].deletingLastPathComponent().appendingPathComponent("cover.jpg"))
        let database = try LibraryDatabase.inMemory()
        let root = try database.addRoot(path: directory.appendingPathComponent("Music").path, bookmark: Data())
        _ = try await LibraryScanner(database: database, artwork: try ArtworkCache(directory: directory.appendingPathComponent("Artwork"))).scan(root: root)
        // Tag them in the library (as a fix would).
        let tracks = try await database.writer.read { try LibraryDatabase.allTracks($0) }
        var changes: [Int64: TrackMetadata] = [:]
        for (index, track) in tracks.enumerated() {
            changes[track.id!] = TrackMetadata(title: "Song \(index + 1)", artist: "Test Artist", album: "Fixture Album", albumArtist: "Test Artist",
                                               year: 2001, trackNumber: index + 1)
        }
        try database.applyMetadata(changes, asOverrides: true)
        return (database, directory, files)
    }

    @Test func renamesThenUndoRestoresExactPaths() async throws {
        let (database, directory, files) = try await Self.library()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Music")
        let before = try await database.writer.read { try LibraryDatabase.allTracks($0) }
        let originalPaths = Dictionary(uniqueKeysWithValues: before.map { ($0.id!, $0.path) })

        let plan = RenamePlanner.plan(tracks: before, root: root, options: OrganizeOptions())
        #expect(plan.allSatisfy { $0.status == .move })
        #expect(plan.contains { $0.destination.path.hasSuffix("Test Artist/Fixture Album (2001)/01 Song 1.wav") })

        let journal = try FileOrganizer.apply(plan, database: database)
        let after = try await database.writer.read { try LibraryDatabase.allTracks($0) }
        for track in after {
            #expect(FileManager.default.fileExists(atPath: track.path), "\(track.path)")
            #expect(track.path.contains("/Test Artist/Fixture Album (2001)/"))
        }
        // The cover moved with the album and the old folder is gone.
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Test Artist/Fixture Album (2001)/cover.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: files[0].deletingLastPathComponent().path))

        // A rescan sees nothing new.
        let summary = try await LibraryScanner(database: database, artwork: try ArtworkCache(directory: directory.appendingPathComponent("Artwork")))
            .scan(root: try database.writer.read { try LibraryDatabase.roots($0).first! })
        #expect(summary.added == 0 && summary.removed == 0)

        try FileOrganizer.undo(journal, database: database)
        let undone = try await database.writer.read { try LibraryDatabase.allTracks($0) }
        for track in undone {
            #expect(track.path == originalPaths[track.id!])
            #expect(FileManager.default.fileExists(atPath: track.path))
        }
        #expect(FileManager.default.fileExists(atPath: files[0].deletingLastPathComponent().appendingPathComponent("cover.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Test Artist").path))
    }

    @Test func resolvesConflictsAndSwaps() async throws {
        let (database, directory, _) = try await Self.library()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Music")
        // The two .m4a songs (ALAC and AAC) get the same title and number: the second becomes " (2)".
        let m4a = try await database.writer.read { try LibraryDatabase.allTracks($0) }.filter { $0.path.hasSuffix(".m4a") }
        #expect(m4a.count == 2)
        try database.applyMetadata([m4a[0].id!: TrackMetadata(title: "Same", trackNumber: 1), m4a[1].id!: TrackMetadata(title: "Same", trackNumber: 1)],
                                   asOverrides: true)
        var all = try await database.writer.read { try LibraryDatabase.allTracks($0) }
        let plan = RenamePlanner.plan(tracks: all, root: root, options: OrganizeOptions())
        let names = plan.map(\.destination.lastPathComponent)
        #expect(names.contains("01 Same.m4a") && names.contains("01 Same (2).m4a"), "\(names)")
        #expect(plan.contains { $0.status == .renamedForConflict })
        _ = try FileOrganizer.apply(plan, database: database)

        // Swap them: "A" takes "B"'s name and the reverse, without clobbering either file.
        try database.applyMetadata([m4a[0].id!: TrackMetadata(title: "B", trackNumber: 2), m4a[1].id!: TrackMetadata(title: "A", trackNumber: 1)],
                                   asOverrides: true)
        all = try await database.writer.read { try LibraryDatabase.allTracks($0) }
        _ = try FileOrganizer.apply(RenamePlanner.plan(tracks: all, root: root, options: OrganizeOptions()), database: database)
        try database.applyMetadata([m4a[0].id!: TrackMetadata(title: "A", trackNumber: 1), m4a[1].id!: TrackMetadata(title: "B", trackNumber: 2)],
                                   asOverrides: true)
        all = try await database.writer.read { try LibraryDatabase.allTracks($0) }
        let swap = RenamePlanner.plan(tracks: all, root: root, options: OrganizeOptions())
        #expect(swap.filter { $0.status != .unchanged }.count == 2)
        _ = try FileOrganizer.apply(swap, database: database)
        let final = try await database.writer.read { try LibraryDatabase.allTracks($0) }
        #expect(Set(final.map(\.path)).count == final.count)
        for track in final { #expect(FileManager.default.fileExists(atPath: track.path), "\(track.path)") }
        let a = try #require(final.first { $0.id == m4a[0].id })
        #expect(a.path.hasSuffix("/01 A.m4a"))
    }

    @Test func undoingAnImportTakesSongsOut() async throws {
        let (database, directory, _) = try await Self.library()
        defer { try? FileManager.default.removeItem(at: directory) }
        // An "import": one file copied in, one moved in, then the library is scanned.
        let outside = directory.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let tracks = try await database.writer.read { try LibraryDatabase.allTracks($0) }
        let copySource = outside.appendingPathComponent("copied.flac")
        let moveSource = outside.appendingPathComponent("moved.wav")
        try FileManager.default.copyItem(atPath: tracks.first { $0.path.hasSuffix(".flac") }!.path, toPath: copySource.path)
        try FileManager.default.copyItem(atPath: tracks.first { $0.path.hasSuffix(".wav") }!.path, toPath: moveSource.path)
        let root = directory.appendingPathComponent("Music")
        let copied = root.appendingPathComponent("Imported/copied.flac")
        let moved = root.appendingPathComponent("Imported/moved.wav")
        try FileManager.default.createDirectory(at: copied.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: copySource, to: copied)
        try FileManager.default.moveItem(at: moveSource, to: moved)
        _ = try await LibraryScanner(database: database, artwork: try ArtworkCache(directory: directory.appendingPathComponent("Artwork")))
            .scan(root: try database.writer.read { try LibraryDatabase.roots($0).first! })
        let ids = try await database.writer.read { db in
            try [copied, moved].map { url in try Track.filter(Column("path") == url.standardizedFileURL.path).fetchOne(db)!.id! }
        }
        let journal = FileOperationJournal(id: UUID(), kind: .import, date: .now, entries: [
            .init(trackId: ids[0], from: copySource.path, to: copied.standardizedFileURL.path, copied: true),
            .init(trackId: ids[1], from: moveSource.path, to: moved.standardizedFileURL.path, copied: false),
        ], createdFolders: [copied.deletingLastPathComponent().path])

        try FileOrganizer.undo(journal, database: database)
        #expect(FileManager.default.fileExists(atPath: copySource.path) && FileManager.default.fileExists(atPath: moveSource.path))
        #expect(!FileManager.default.fileExists(atPath: copied.deletingLastPathComponent().path))
        #expect(try await database.writer.read { try Track.fetchAll($0, keys: ids) }.isEmpty)
    }

    @Test func journalsRoundTripOnDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("journals-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = FileOperationJournal(id: UUID(), kind: .import, date: .now,
                                           entries: [.init(trackId: 1, from: "/a", to: "/b", copied: true)], createdFolders: ["/x"])
        try FileOrganizer.save(journal, in: folder)
        #expect(FileOrganizer.latestJournal(in: folder)?.0.entries == journal.entries)
    }
}
