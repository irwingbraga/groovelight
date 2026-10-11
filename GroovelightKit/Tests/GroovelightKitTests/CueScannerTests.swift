import Foundation
import GRDB
import SFBAudioEngine
import Testing
@testable import LibraryKit

/// Albums stored as one audio file plus a cue sheet: the scanner turns them into one song per cue track.
struct CueScannerTests {
    static let sheet = """
        REM GENRE "Alternative Rock"
        REM DATE 1997
        PERFORMER "Cue Band"
        TITLE "Single File Album"
        FILE "Single File Album.wav" WAVE
          TRACK 01 AUDIO
            TITLE "First"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Second"
            PERFORMER "Guest Singer"
            INDEX 00 00:00:20
            INDEX 01 00:00:30
          TRACK 03 AUDIO
            TITLE "Third"
            INDEX 01 00:00:60
        """

    /// A 1 s FLAC in its own album folder (the fixture set's FLAC, renamed).
    private func makeImage(in directory: URL) throws -> URL {
        let files = try ScannerIntegrationTests.makeFixtures(in: directory.appendingPathComponent("work"))
        let flac = try #require(files.first { $0.pathExtension == "flac" })
        let album = directory.appendingPathComponent("Library/Cue Band", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let image = album.appendingPathComponent("Single File Album.flac")
        try FileManager.default.moveItem(at: flac, to: image)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("work"))
        return image
    }

    private func scan(_ directory: URL) async throws -> (LibraryDatabase, LibraryScanner, LibraryRoot) {
        let database = try LibraryDatabase.inMemory()
        let artwork = try ArtworkCache(directory: directory.appendingPathComponent("Artwork"))
        let root = try database.addRoot(path: directory.appendingPathComponent("Library").path, bookmark: Data())
        return (database, LibraryScanner(database: database, artwork: artwork), root)
    }

    private func checkTracks(_ tracks: [Track], image: URL, base: String) {
        #expect(tracks.count == 3)
        #expect(tracks.map(\.title) == ["First", "Second", "Third"])
        #expect(tracks.map(\.path) == ["01", "02", "03"].map { base + "#" + $0 })
        #expect(tracks.allSatisfy { $0.audioPath == image.path && $0.url.path == image.path && $0.isCueTrack })
        #expect(tracks.map(\.startTime) == [0, 0.4, 0.8])
        #expect(tracks[0].endTime == 0.4 && tracks[1].endTime == 0.8 && tracks[2].endTime == nil)
        #expect(abs(tracks[1].duration - 0.4) < 0.01 && abs(tracks[2].duration - 0.2) < 0.05)
        #expect(tracks.allSatisfy { $0.album == "Single File Album" && $0.albumArtist == "Cue Band" && $0.year == 1997 })
        #expect(tracks[0].artist == "Cue Band" && tracks[1].artist == "Guest Singer")
        #expect(Set(tracks.map(\.albumKey)).count == 1)
    }

    @Test func externalSheetSplitsTheImage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try makeImage(in: directory)
        // The sheet names the ".wav" the rip started as: resolved to the FLAC beside it.
        let cue = image.deletingLastPathComponent().appendingPathComponent("Single File Album.cue")
        try Self.sheet.write(to: cue, atomically: true, encoding: .utf8)

        let (database, scanner, root) = try await scan(directory)
        let first = try await scanner.scan(root: root)
        #expect(first.added == 3 && first.failed.isEmpty)
        var tracks = try await database.writer.read { try Track.order(Column("path")).fetchAll($0) }
        checkTracks(tracks, image: image, base: cue.path)

        // History survives a rescan after the sheet changes.
        try await database.writer.write { db in try db.execute(sql: "UPDATE track SET playCount = 5 WHERE path LIKE '%#02'") }
        let second = try await scanner.scan(root: root)
        #expect(second.unchanged == 3 && second.added == 0)
        try Self.sheet.replacingOccurrences(of: "\"Second\"", with: "\"Second (Edit)\"").write(to: cue, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(10)], ofItemAtPath: cue.path)
        let third = try await scanner.scan(root: root)
        #expect(third.updated == 3 && third.added == 0 && third.removed == 0)
        tracks = try await database.writer.read { try Track.order(Column("path")).fetchAll($0) }
        #expect(tracks[1].title == "Second (Edit)" && tracks[1].playCount == 5)

        // Without the sheet the file is one song again.
        try FileManager.default.removeItem(at: cue)
        let fourth = try await scanner.scan(root: root)
        #expect(fourth.added == 1 && fourth.removed == 3)
        tracks = try await database.writer.read { try Track.fetchAll($0) }
        #expect(tracks.count == 1 && tracks[0].path == image.path && !tracks[0].isCueTrack)
    }

    @Test func embeddedSheetSplitsTheFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try makeImage(in: directory)
        let file = try AudioFile(readingPropertiesAndMetadataFrom: image)
        file.metadata.additionalMetadata = ["CUESHEET": Self.sheet]
        try file.writeMetadata()

        let (database, scanner, root) = try await scan(directory)
        let first = try await scanner.scan(root: root)
        #expect(first.added == 3 && first.failed.isEmpty)
        let tracks = try await database.writer.read { try Track.order(Column("path")).fetchAll($0) }
        checkTracks(tracks, image: image, base: image.path)

        let second = try await scanner.scan(root: root)
        #expect(second.unchanged == 3 && second.added == 0 && second.removed == 0)
    }

    @Test func organizeMovesTheAlbumAsAUnit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try makeImage(in: directory)
        let cue = image.deletingLastPathComponent().appendingPathComponent("Single File Album.cue")
        try Self.sheet.write(to: cue, atomically: true, encoding: .utf8)
        let (database, scanner, root) = try await scan(directory)
        _ = try await scanner.scan(root: root)
        try await database.writer.write { db in try db.execute(sql: "UPDATE track SET playCount = 2") }
        let before = try await database.writer.read { try Track.order(Column("path")).fetchAll($0) }

        let rootURL = URL(fileURLWithPath: root.path)
        let plan = RenamePlanner.plan(tracks: before, root: rootURL, options: OrganizeOptions())
        let folder = rootURL.appendingPathComponent("Cue Band/Single File Album (1997)")
        #expect(plan.count == 2 && plan.allSatisfy { $0.status == .move && $0.trackId == nil })
        #expect(Set(plan.map(\.destination.path)) == [folder.appendingPathComponent("Single File Album.flac").path,
                                                     folder.appendingPathComponent("Single File Album.cue").path])

        let journal = try FileOrganizer.apply(plan, database: database)
        let movedImage = folder.appendingPathComponent("Single File Album.flac")
        let movedCue = folder.appendingPathComponent("Single File Album.cue")
        #expect(FileManager.default.fileExists(atPath: movedImage.path) && FileManager.default.fileExists(atPath: movedCue.path))
        var tracks = try await database.writer.read { try Track.order(Column("path")).fetchAll($0) }
        checkTracks(tracks, image: movedImage.standardizedFileURL, base: movedCue.standardizedFileURL.path)
        #expect(tracks.map(\.id) == before.map(\.id))

        // The library already matches the disk: a rescan changes nothing, and history is kept.
        let rescan = try await scanner.scan(root: root)
        #expect(rescan.unchanged == 3 && rescan.added == 0 && rescan.removed == 0)

        try FileOrganizer.undo(journal, database: database)
        #expect(FileManager.default.fileExists(atPath: image.path) && FileManager.default.fileExists(atPath: cue.path))
        tracks = try await database.writer.read { try Track.order(Column("path")).fetchAll($0) }
        checkTracks(tracks, image: image, base: cue.path)
        #expect(tracks.allSatisfy { $0.playCount == 2 })
    }
}
