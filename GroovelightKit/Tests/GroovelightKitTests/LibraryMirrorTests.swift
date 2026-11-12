import Foundation
import Testing
@testable import LibraryKit

/// The music mirror on a NAS: copies, renames and moves, files set aside instead of deleted, offline folders and big
/// drops left alone, runs cut short resumed, damaged copies repaired, and putting files back.
struct LibraryMirrorTests {
    private let fileManager = FileManager.default

    private struct Setup {
        let base: URL
        let library: URL
        let nas: URL
        let state: URL
        var music: URL { nas.appendingPathComponent("Music") }
        var mirror: URL { music.appendingPathComponent(library.lastPathComponent) }
    }

    private func setup(files: Int = 3) throws -> Setup {
        let base = fileManager.temporaryDirectory.appendingPathComponent("mirror-\(UUID().uuidString)", isDirectory: true)
        let setup = Setup(base: base, library: base.appendingPathComponent("Library/FLAC"), nas: base.appendingPathComponent("NAS/Groovelight"),
                          state: base.appendingPathComponent("State/Mirror.json"))
        try fileManager.createDirectory(at: setup.library, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: setup.nas, withIntermediateDirectories: true)
        for index in 0..<files { try write("Artist/Album/0\(index + 1) Song.flac", "song \(index)", in: setup) }
        return setup
    }

    private func write(_ path: String, _ text: String, in setup: Setup, date: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws {
        let url = setup.library.appendingPathComponent(path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func run(_ setup: Setup, sources: [String: URL?]? = nil, options: LibraryMirror.Options = .init(sampleInterval: 1e9),
                     now: Date = .now) async throws -> LibraryMirror.Report {
        try await LibraryMirror.run(sources: sources ?? [setup.library.path: setup.library], destination: setup.nas, state: setup.state,
                                    options: options, now: now)
    }

    private func text(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func copiesTheLibraryThenOnlyWhatChanged() async throws {
        let setup = try setup()
        defer { try? fileManager.removeItem(at: setup.base) }
        let first = try await run(setup)
        #expect(first.copied == 3 && first.finished && first.errors.isEmpty)
        let copy = setup.mirror.appendingPathComponent("Artist/Album/01 Song.flac")
        #expect(text(copy) == "song 0")
        // The library file's date is kept.
        #expect((try? copy.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) == Date(timeIntervalSince1970: 1_700_000_000))
        // The manifest on this computer and on the NAS.
        #expect(fileManager.fileExists(atPath: setup.state.path))
        #expect(fileManager.fileExists(atPath: setup.music.appendingPathComponent(".groovelight-mirror.json").path))
        #expect(LibraryMirror.Manifest.load(from: setup.state)?.files.values.allSatisfy { $0.sha256 != nil && $0.verified != nil } == true)

        let again = try await run(setup)
        #expect(again.copied == 0 && again.moved == 0 && again.removed == 0)
        #expect(again.totalFiles == 3)
    }

    @Test func aTagEditCopiesOneFileAndARenameMovesOne() async throws {
        let setup = try setup()
        defer { try? fileManager.removeItem(at: setup.base) }
        _ = try await run(setup)
        // A tag edit: new content and date.
        try write("Artist/Album/01 Song.flac", "song 0 with new tags", in: setup, date: Date(timeIntervalSince1970: 1_700_100_000))
        // The renamer: same file, new name and folder.
        try fileManager.createDirectory(at: setup.library.appendingPathComponent("Artist/Album (2001)"), withIntermediateDirectories: true)
        try fileManager.moveItem(at: setup.library.appendingPathComponent("Artist/Album/02 Song.flac"),
                                 to: setup.library.appendingPathComponent("Artist/Album (2001)/02 Renamed.flac"))
        let report = try await run(setup)
        #expect(report.copied == 1)
        #expect(report.moved == 1)
        #expect(report.removed == 0)
        #expect(text(setup.mirror.appendingPathComponent("Artist/Album/01 Song.flac")) == "song 0 with new tags")
        #expect(text(setup.mirror.appendingPathComponent("Artist/Album (2001)/02 Renamed.flac")) == "song 1")
        #expect(!fileManager.fileExists(atPath: setup.mirror.appendingPathComponent("Artist/Album/02 Song.flac").path))
    }

    @Test func removedFilesAreSetAsideThenPurged() async throws {
        let setup = try setup()
        defer { try? fileManager.removeItem(at: setup.base) }
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try await run(setup, now: start)
        try fileManager.removeItem(at: setup.library.appendingPathComponent("Artist/Album/03 Song.flac"))
        let report = try await run(setup, now: start)
        #expect(report.removed == 1)
        let removed = LibraryMirror.removedFiles(in: setup.nas)
        #expect(removed.map(\.key) == ["FLAC/Artist/Album/03 Song.flac"])
        #expect(text(removed[0].url) == "song 2")

        // Put back.
        let back = await LibraryMirror.copyBack([(removed[0].url, setup.library.appendingPathComponent("Artist/Album/03 Song.flac"))])
        #expect(back.copied == 1)
        #expect(text(setup.library.appendingPathComponent("Artist/Album/03 Song.flac")) == "song 2")

        // 31 days later, gone for good.
        let later = try await run(setup, options: .init(keepRemovedDays: 30, sampleInterval: 1e9), now: start.addingTimeInterval(31 * 24 * 3600))
        #expect(later.purged == 1)
        #expect(LibraryMirror.removedFiles(in: setup.nas).isEmpty)
    }

    @Test func anOfflineFolderIsLeftAlone() async throws {
        let setup = try setup()
        defer { try? fileManager.removeItem(at: setup.base) }
        _ = try await run(setup)
        // The drive is unplugged: no URL (or a path that is not there).
        let report = try await run(setup, sources: [setup.library.path: nil])
        #expect(report.skipped[setup.library.path] == "offline")
        #expect(report.removed == 0)
        #expect(LibraryMirror.Manifest.load(from: setup.state)?.files.count == 3)
        #expect(LibraryMirror.removedFiles(in: setup.nas).isEmpty)
    }

    @Test func aFolderThatLostMostFilesAsksFirst() async throws {
        let setup = try setup(files: 30)
        defer { try? fileManager.removeItem(at: setup.base) }
        _ = try await run(setup)
        for index in 0..<20 { try fileManager.removeItem(at: setup.library.appendingPathComponent("Artist/Album/0\(index + 1) Song.flac")) }
        let report = try await run(setup)
        #expect(report.needsConfirmation == [LibraryMirror.Drop(folder: setup.library.path, before: 30, now: 10)])
        #expect(report.removed == 0)
        let confirmed = try await run(setup, options: .init(confirmed: [setup.library.path], sampleInterval: 1e9))
        #expect(confirmed.removed == 20)
        #expect(confirmed.needsConfirmation.isEmpty)
    }

    @Test func aRunCutShortResumesWithoutCopyingAgain() async throws {
        let setup = try setup()
        defer { try? fileManager.removeItem(at: setup.base) }
        _ = try await run(setup)
        // A new Mac: no manifest here, the NAS's is used.
        try fileManager.removeItem(at: setup.state)
        #expect(try await run(setup).copied == 0)
        // Both lost (a crash before the manifest was saved): files already there with the same size and date are kept.
        try fileManager.removeItem(at: setup.state)
        try fileManager.removeItem(at: setup.music.appendingPathComponent(".groovelight-mirror.json"))
        let report = try await run(setup)
        #expect(report.copied == 0)
        #expect(report.totalFiles == 3)
    }

    @Test func aDamagedCopyIsFoundAndCopiedAgain() async throws {
        let setup = try setup()
        defer { try? fileManager.removeItem(at: setup.base) }
        let start = Date.now
        _ = try await run(setup, now: start)
        let copy = setup.mirror.appendingPathComponent("Artist/Album/02 Song.flac")
        try Data("song X".utf8).write(to: copy)
        let report = try await run(setup, options: .init(sampleInterval: 60, sampleFraction: 1), now: start.addingTimeInterval(120))
        #expect(report.repaired == 1)
        #expect(report.verified == 3)
        #expect(text(copy) == "song 1")
    }

    @Test func foldersWithTheSameNameGetTheirOwnFolder() {
        var manifest = LibraryMirror.Manifest()
        #expect(manifest.name(for: "/Volumes/A/Music") == "Music")
        #expect(manifest.name(for: "/Volumes/B/Music") == "Music 2")
        #expect(manifest.name(for: "/Volumes/A/Music") == "Music")
    }

    @Test func copyBackAWholeFolder() async throws {
        let setup = try setup()
        defer { try? fileManager.removeItem(at: setup.base) }
        _ = try await run(setup)
        let manifest = try #require(LibraryMirror.Manifest.load(from: setup.state))
        let target = setup.base.appendingPathComponent("New Drive/FLAC")
        let files = LibraryMirror.files(of: "FLAC", in: setup.nas, manifest: manifest, onto: target)
        #expect(files.count == 3)
        let result = await LibraryMirror.copyBack(files)
        #expect(result.copied == 3 && result.errors.isEmpty)
        #expect(text(target.appendingPathComponent("Artist/Album/03 Song.flac")) == "song 2")
    }
}
