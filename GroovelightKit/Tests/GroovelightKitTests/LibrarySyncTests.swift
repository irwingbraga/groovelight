import Foundation
import GRDB
import Testing
@testable import LibraryKit

/// Watching library folders: events to scan work, scans of only some folders, and the file system event history.
struct LibrarySyncTests {
    private let audio: Set<String> = ["flac", "mp3", "m4a"]

    private func changes() -> LibraryChanges {
        LibraryChanges(roots: [(1, "/Music"), (2, "/Volumes/NAS/Music")])
    }

    @Test func eventsBecomeFolderScopes() {
        var changes = changes()
        changes.add([
            FolderEvent(path: "/Music/A/Album/01.flac", flags: [.isFile], id: 10),
            FolderEvent(path: "/Music/A/Album/02.flac", flags: [.isFile], id: 11),
            FolderEvent(path: "/Music/A/Album/notes.txt", flags: [.isFile], id: 12),
            FolderEvent(path: "/Music/A/Album/.DS_Store", flags: [.isFile], id: 13),
            FolderEvent(path: "/Music/B/Other/cover.jpg", flags: [.isFile], id: 14),
            FolderEvent(path: "/Music/B", flags: [.isDirectory], id: 15),
            FolderEvent(path: "/Elsewhere/song.flac", flags: [.isFile], id: 16),
        ], audioExtensions: audio)
        #expect(changes.latestEventId == 16)
        let work = changes.take()
        #expect(work.count == 1)
        // "/Music/B" covers "/Music/B/Other"; the cover image still marks its folder for new artwork.
        #expect(work.first?.rootId == 1)
        #expect(work.first?.scope == .folders(["/Music/A/Album", "/Music/B"], artworkFolders: ["/Music/B/Other"]))
        #expect(changes.isEmpty)
        #expect(changes.take().isEmpty)
    }

    @Test func lostEventsAndRootChangesNeedFullScans() {
        var changes = changes()
        changes.add([FolderEvent(path: "/Music/A/x.flac", flags: [.isFile], id: 1),
                     FolderEvent(path: "/Volumes/NAS/Music", flags: [.rootChanged], id: 2)], audioExtensions: audio)
        let work = changes.take()
        #expect(work.map(\.rootId) == [1, 2])
        #expect(work.last?.scope == .full)

        changes.add([FolderEvent(path: "/", flags: [.kernelDropped], id: 3)], audioExtensions: audio)
        #expect(changes.take().map(\.scope) == [.full, .full])

        // "Rescan below this folder" with the library folder itself, and a missing song's folder.
        changes.add([FolderEvent(path: "/Music/", flags: [.mustScanSubDirs], id: 4)], audioExtensions: audio)
        changes.addFolder("/Volumes/NAS/Music/X")
        let mixed = changes.take()
        #expect(mixed.first?.scope == .full)
        #expect(mixed.last?.scope == .folders(["/Volumes/NAS/Music/X"], artworkFolders: []))
    }

    @Test func eventPathsFollowSymbolicLinks() throws {
        // Temporary folders live under /var, a link to /private/var: events report the real path.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = LibraryChanges.realPath(directory.path)
        #expect(real.hasPrefix("/private/"))
        var changes = LibraryChanges(roots: [(1, directory.path)])
        changes.add([FolderEvent(path: real + "/Album/a.flac", flags: [.isFile], id: 1)], audioExtensions: audio)
        #expect(changes.take().first?.scope == .folders([directory.path + "/Album"], artworkFolders: []))
        // Also when the folders are set later (as the app does each time it starts watching).
        var later = LibraryChanges(roots: [])
        later.roots = [(1, directory.path + "/")]
        later.add([FolderEvent(path: real + "/Album/b.flac", flags: [.isFile], id: 2)], audioExtensions: audio)
        #expect(later.take().first?.scope == .folders([directory.path + "/Album"], artworkFolders: []))
    }

    @Test func scopedScansOnlyTouchTheirFolders() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try ScannerIntegrationTests.makeFixtures(in: directory)
        try #require(files.count >= 3)
        let albumOne = files[0].deletingLastPathComponent()
        // A second album folder with copies of two files.
        let albumTwo = directory.appendingPathComponent("Other Artist/Second Album", isDirectory: true)
        try FileManager.default.createDirectory(at: albumTwo, withIntermediateDirectories: true)
        for file in files.prefix(2) { try FileManager.default.copyItem(at: file, to: albumTwo.appendingPathComponent(file.lastPathComponent)) }

        let database = try LibraryDatabase.inMemory()
        let artwork = try ArtworkCache(directory: directory.appendingPathComponent(".artwork"))
        let root = try database.addRoot(path: directory.path, bookmark: Data())
        let scanner = LibraryScanner(database: database, artwork: artwork)
        let first = try await scanner.scan(root: root)
        #expect(first.added == files.count + 2)
        let full = try await database.writer.read { try LibraryRoot.fetchOne($0, key: root.id) }
        #expect(full?.lastFullScanAt != nil)

        // Remove a file from each album, but scan only the second album's folder: the first keeps its song.
        try FileManager.default.removeItem(at: albumOne.appendingPathComponent(files[2].lastPathComponent))
        try FileManager.default.removeItem(at: albumTwo.appendingPathComponent(files[1].lastPathComponent))
        let scoped = try await scanner.scan(root: root, scope: .folders([albumTwo.path]))
        #expect(scoped.removed == 1)
        #expect(scoped.unchanged == 1)
        var count = try await database.writer.read { try Track.fetchCount($0) }
        #expect(count == files.count + 1)

        // A cover image beside the songs: they are read again and pick it up.
        let before = try await database.writer.read { db in
            try Track.filter(sql: "path LIKE ?", arguments: [albumTwo.path + "/%"]).fetchAll(db)
        }
        #expect(before.allSatisfy { $0.artworkHash == nil })
        try ScannerIntegrationTests.pngData().write(to: albumTwo.appendingPathComponent("cover.png"))
        let cover = try await scanner.scan(root: root, scope: .folders([albumTwo.path], artworkFolders: [albumTwo.path]))
        #expect(cover.updated == 1)
        let after = try await database.writer.read { db in
            try Track.filter(sql: "path LIKE ?", arguments: [albumTwo.path + "/%"]).fetchAll(db)
        }
        #expect(after.allSatisfy { $0.artworkHash != nil })
        #expect(after.map(\.id) == before.map(\.id))

        // Renaming a folder: both its old and new paths are in the scope, and its songs keep their ids.
        let renamed = directory.appendingPathComponent("Other Artist/Renamed Album", isDirectory: true)
        try FileManager.default.moveItem(at: albumTwo, to: renamed)
        let move = try await scanner.scan(root: root, scope: .folders([albumTwo.path, renamed.path]))
        #expect(move.removed == 0)
        let moved = try await database.writer.read { db in
            try Track.filter(sql: "path LIKE ?", arguments: [renamed.path + "/%"]).fetchAll(db)
        }
        #expect(moved.map(\.id) == after.map(\.id))

        // A deleted folder: its songs go (the first album's deleted song stays until its folder is checked).
        try FileManager.default.removeItem(at: renamed)
        let gone = try await scanner.scan(root: root, scope: .folders([renamed.path]))
        #expect(gone.removed == 1)
        count = try await database.writer.read { try Track.fetchCount($0) }
        #expect(count == files.count)
    }

    @Test func watcherReportsLiveAndPastChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Album"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let received = Received()
        let watcher = FolderWatcher { events in Task { await received.add(events) } }
        let start = FolderWatcher.currentEventId
        watcher.watch([directory.path], latency: 0.2)
        try await Task.sleep(for: .seconds(0.5))
        try Data([1]).write(to: directory.appendingPathComponent("Album/live.flac"))
        #expect(await received.wait { $0.contains { $0.path.hasSuffix("/Album/live.flac") && $0.flags.contains(.isFile) } })
        watcher.stop()

        // Changed while nobody watched: a watcher started from an earlier event id replays it.
        try Data([2]).write(to: directory.appendingPathComponent("Album/offline.flac"))
        try await Task.sleep(for: .seconds(1))
        await received.reset()
        watcher.watch([directory.path], since: start, latency: 0.2)
        #expect(await received.wait { events in
            events.contains { $0.path.hasSuffix("/Album/offline.flac") } && events.contains { $0.flags.contains(.historyDone) }
        })
        watcher.stop()
        #expect(FolderWatcher.historyId(for: directory.path) != nil)
        #expect(FolderWatcher.isLocalVolume(directory.path))
    }
}

private actor Received {
    private var events: [FolderEvent] = []

    func add(_ new: [FolderEvent]) { events += new }
    func reset() { events = [] }

    /// Waits up to 10 s for the events to satisfy `condition`.
    func wait(_ condition: ([FolderEvent]) -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition(events) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition(events)
    }
}
