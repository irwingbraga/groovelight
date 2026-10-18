import Foundation
import Testing
@testable import LibraryKit

struct ArchiveExtractorTests {
    /// A folder with an album (one fake song and its cover) to pack.
    private func makeAlbum() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("archives-\(UUID().uuidString)", isDirectory: true)
        let album = base.appendingPathComponent("source/Album", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4096).write(to: album.appendingPathComponent("01 Song.flac"))
        try Data(repeating: 1, count: 64).write(to: album.appendingPathComponent("cover.jpg"))
        return base
    }

    private func run(_ path: String, _ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    @Test(arguments: [("zip", ["--format", "zip"]), ("7z", ["--format", "7zip"]), ("tar.gz", ["-z"])])
    func extractsEveryFormat(_ format: (ext: String, flags: [String])) throws {
        let base = try makeAlbum()
        defer { try? FileManager.default.removeItem(at: base) }
        let archive = base.appendingPathComponent("Album.\(format.ext)")
        try run("/usr/bin/bsdtar", ["-c", "-f", archive.path] + format.flags + ["-C", "source", "Album"], in: base)
        #expect(ArchiveExtractor.isArchive(archive))

        let output = base.appendingPathComponent("out", isDirectory: true)
        try ArchiveExtractor.extract(archive, into: output)
        let song = output.appendingPathComponent("Album/01 Song.flac")
        #expect(try Data(contentsOf: song) == Data(repeating: 7, count: 4096))
        #expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("Album/cover.jpg").path))
    }

    @Test func keepsEntriesInsideTheFolder() throws {
        let base = try makeAlbum()
        defer { try? FileManager.default.removeItem(at: base) }
        // An entry named "../escaped.flac" must not land beside the output folder.
        let archive = base.appendingPathComponent("evil.zip")
        try run("/usr/bin/bsdtar", ["-c", "-f", archive.path, "--format", "zip", "-s", "|^Album/|../|", "-C", "source", "Album/01 Song.flac"], in: base)
        let output = base.appendingPathComponent("out", isDirectory: true)
        #expect(throws: ArchiveExtractor.ExtractError.self) { try ArchiveExtractor.extract(archive, into: output) }
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("01 Song.flac").path))
    }

    @Test func leavesOutLinks() throws {
        let base = try makeAlbum()
        defer { try? FileManager.default.removeItem(at: base) }
        // A "song" that points at a file elsewhere on the Mac, and a folder link.
        let secret = base.appendingPathComponent("secret.txt")
        try Data("private".utf8).write(to: secret)
        let album = base.appendingPathComponent("source/Album")
        try FileManager.default.createSymbolicLink(at: album.appendingPathComponent("02 Song.mp3"), withDestinationURL: secret)
        try FileManager.default.createSymbolicLink(at: album.appendingPathComponent("Elsewhere"), withDestinationURL: base)
        let archive = base.appendingPathComponent("Album.zip")
        try run("/usr/bin/bsdtar", ["-c", "-f", archive.path, "--format", "zip", "-C", "source", "Album"], in: base)

        let output = base.appendingPathComponent("out", isDirectory: true)
        try ArchiveExtractor.extract(archive, into: output)
        let contents = try FileManager.default.contentsOfDirectory(atPath: output.appendingPathComponent("Album").path).sorted()
        #expect(contents == ["01 Song.flac", "cover.jpg"])
    }

    @Test func reportsPasswordProtectedArchives() throws {
        let base = try makeAlbum()
        defer { try? FileManager.default.removeItem(at: base) }
        let archive = base.appendingPathComponent("locked.zip")
        try run("/usr/bin/zip", ["-q", "-r", "-P", "secret", archive.path, "Album"], in: base.appendingPathComponent("source"))
        do {
            try ArchiveExtractor.extract(archive, into: base.appendingPathComponent("out", isDirectory: true))
            Issue.record("extracted a protected archive")
        } catch ArchiveExtractor.ExtractError.encrypted(let name) {
            #expect(name == "locked.zip")
        }
    }

    @Test func readsJournalsWrittenBeforeArchives() throws {
        // Journals saved by earlier versions have no "trashed" list.
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"import","date":0,"entries":[],"createdFolders":[]}"#
        let journal = try JSONDecoder().decode(FileOperationJournal.self, from: Data(old.utf8))
        #expect(journal.trashed == nil)
    }
}
