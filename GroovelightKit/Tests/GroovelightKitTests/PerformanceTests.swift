import Foundation
import GRDB
import Testing
@testable import LibraryKit

/// A 50,000-song library: how long the queries behind each page take. Opt in with `GL_PERF=1` (it takes a while);
/// `GL_PERF_KEEP=/path/Library.sqlite` keeps the database for opening the app on it (`-GLDebugDataDir`).
struct PerformanceTests {
    static let enabled = ProcessInfo.processInfo.environment["GL_PERF"] == "1"

    @Test(.enabled(if: enabled), .timeLimit(.minutes(10))) func fiftyThousandSongs() throws {
        let keep = ProcessInfo.processInfo.environment["GL_PERF_KEEP"]
        let url = keep.map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-perf-\(UUID().uuidString).sqlite")
        try? FileManager.default.removeItem(at: url)
        defer { if keep == nil { try? FileManager.default.removeItem(at: url) } }
        let database = try LibraryDatabase(url: url)
        // A folder that does not exist: the app keeps its songs as "not available" instead of removing them.
        let root = try database.addRoot(path: "/Volumes/Groovelight Performance Library", bookmark: Data())

        var timings: [(String, Double)] = []
        func measure<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
            let start = Date.now
            let value = try work()
            timings.append((label, Date.now.timeIntervalSince(start)))
            return value
        }

        let genres = ["Rock", "Jazz", "Classical", "Electronic", "Hip-Hop", "Folk", "Soul", "Ambient", "Metal", "Pop"]
            .flatMap { genre in (0..<4).map { $0 == 0 ? genre : "\(genre) \($0)" } }
        try measure("insert 50,000 songs") {
            try database.writer.write { db in
                for album in 0..<5_000 {
                    let artist = "Artist \(album % 800)"
                    for number in 1...10 {
                        var track = LibraryDatabaseTests.makeTrack(rootId: root.id!, "Song \(number) of Album \(album)", artist: artist,
                                                                   album: "Album \(album)", number: number)
                        track.path = "/Volumes/Groovelight Performance Library/\(artist)/Album \(album)/\(number).flac"
                        track.genre = genres[album % genres.count]
                        track.year = 1960 + album % 65
                        track.duration = Double(120 + (album * 7 + number * 13) % 300)
                        track.isLoved = (album + number) % 17 == 0
                        track.playCount = (album * number) % 40
                        track.dateAdded = Date(timeIntervalSince1970: 1_600_000_000 + Double(album * 3_600))
                        try track.insert(db)
                    }
                }
            }
        }
        let ids = try database.writer.read { try Int64.fetchAll($0, sql: "SELECT id FROM track ORDER BY random() LIMIT 3000") }
        for index in 0..<30 {
            _ = try database.createPlaylist(named: "Playlist \(index)", trackIds: Array(ids[(index * 100)..<(index * 100 + 100)]))
        }
        var rules = SmartPlaylistRules()
        rules.rules = [SmartRule(field: .genre, op: .contains, text: "Jazz")]
        _ = try database.createSmartPlaylist(named: "Jazz", rules: rules)

        try database.writer.read { db in
            _ = try measure("Albums page (all albums)") { try LibraryDatabase.albums(db, sort: .artist) }
            _ = try measure("Artists list") { try LibraryDatabase.artists(db) }
            _ = try measure("Songs page (all songs)") { try LibraryDatabase.allTracks(db) }
            _ = try measure("Genres list") { try LibraryDatabase.genres(db) }
            _ = try measure("Recently Added") { try LibraryDatabase.recentlyAddedAlbums(db) }
            _ = try measure("All Playlists (with smart)") { try LibraryDatabase.playlistOverview(db) }
            _ = try measure("Loved Songs") { try LibraryDatabase.lovedTracks(db) }
            _ = try measure("Artist page") { try LibraryDatabase.albums(db, sort: .year, artist: "Artist 7") }
            _ = try measure("Search \"song 4\"") { try LibraryDatabase.search(db, query: "song 4", limit: 50) }
            _ = try measure("Search \"artist 12\"") { try LibraryDatabase.search(db, query: "artist 12", limit: 50) }
        }
        let everything = try database.writer.read { db in
            try measure("Device contents (all music)") { () throws -> (tracks: [Track], playlists: [DevicePlaylist]) in
                var selection = DeviceSelection()
                selection.everything = true
                return try LibraryDatabase.deviceContents(db, selection)
            }
        }
        let first = measure("Device sync plan (50,000 songs)") {
            DeviceSync.plan(tracks: everything.tracks, playlists: everything.playlists, profile: DeviceProfile(),
                            manifest: DeviceManifest(), mode: .sync, root: URL(fileURLWithPath: "/device")) { _ in false }
        }
        // The same device synced again: every song is already there.
        var full = DeviceManifest()
        for write in first.writes { full.entries[write.path] = write.entry }
        let again = measure("Device re-sync plan (all there)") {
            DeviceSync.plan(tracks: everything.tracks, playlists: everything.playlists, profile: DeviceProfile(),
                            manifest: full, mode: .sync, root: URL(fileURLWithPath: "/device")) { full.entries[$0] != nil }
        }
        #expect(again.writes.isEmpty)

        let report = timings.map { String(format: "%-34@ %8.3f s", $0.0 as NSString, $0.1) }.joined(separator: "\n")
        print("PERFORMANCE\n" + report)
        // Pages must open without a visible wait.
        for (label, seconds) in timings where !label.hasPrefix("insert") {
            #expect(seconds < (label.hasPrefix("Device") ? 3.0 : 1.0), "\(label) took \(seconds) s")
        }
    }
}
