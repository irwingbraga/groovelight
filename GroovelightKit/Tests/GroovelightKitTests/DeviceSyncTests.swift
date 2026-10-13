import Foundation
import Testing
@testable import LibraryKit

struct DeviceSyncTests {
    /// Source files on disk and a device folder, cleaned up after each test.
    final class Fixture {
        let base: URL
        let device: URL
        var tracks: [Track] = []

        init() throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-device-\(UUID().uuidString)")
            device = base.appendingPathComponent("SDCARD")
            try FileManager.default.createDirectory(at: device, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: base) }

        @discardableResult
        func addTrack(_ id: Int64, _ title: String, artist: String, album: String, number: Int, bytes: Int = 1000,
                      lyrics: String? = nil) throws -> Track {
            let source = base.appendingPathComponent("library/\(artist)/\(album)/\(number) \(title).flac")
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: UInt8(number), count: bytes).write(to: source)
            var track = LibraryDatabaseTests.makeTrack(rootId: 1, title, artist: artist, album: album, number: number)
            track.id = id
            track.path = source.path
            track.fileSize = Int64(bytes)
            track.modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
            track.lyrics = lyrics
            tracks.append(track)
            return track
        }

        func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: device.appendingPathComponent(path).path) }

        @discardableResult
        func sync(_ tracks: [Track], playlists: [DevicePlaylist] = [], mode: DeviceSync.Mode = .sync,
                  profile: DeviceProfile = DeviceProfile(), fat32: Bool = false) throws -> DeviceSyncPlan {
            let manifest = DeviceManifest.read(from: device)
            let plan = DeviceSync.plan(tracks: tracks, playlists: playlists, profile: profile, manifest: manifest, mode: mode,
                                       root: device, fat32: fat32) { [device] in
                FileManager.default.fileExists(atPath: device.appendingPathComponent($0).path)
            }
            try DeviceSync.run(plan, root: device, profile: profile, manifest: manifest, cover: { _, _ in Data([1, 2, 3]) })
            return plan
        }
    }

    @Test func copiesSongsLyricsAndPlaylistsThenOnlyWhatChanged() throws {
        let fixture = try Fixture()
        let a = try fixture.addTrack(1, "Come Together", artist: "The Beatles", album: "Abbey Road", number: 1,
                                     lyrics: "[00:10.00]Here come old flat-top")
        let b = try fixture.addTrack(2, "Something", artist: "The Beatles", album: "Abbey Road", number: 2)
        let c = try fixture.addTrack(3, "What: Why?", artist: "AC/DC", album: "Back in Black", number: 3)
        let first = try fixture.sync([a, b, c], playlists: [DevicePlaylist(name: "Road Trip", tracks: [c, a])])

        #expect(first.songCount == 3)
        #expect(fixture.exists("Music/The Beatles/Abbey Road (1969)/01 Come Together.flac"))
        #expect(fixture.exists("Music/The Beatles/Abbey Road (1969)/01 Come Together.lrc"))
        #expect(!fixture.exists("Music/The Beatles/Abbey Road (1969)/02 Something.lrc"))
        // Names safe on FAT and exFAT cards: no ":" "?" "/" in a name.
        #expect(fixture.exists("Music/AC-DC/Back in Black (1969)/03 What - Why_.flac"))
        #expect(fixture.exists(DeviceManifest.fileName))
        let playlist = try String(contentsOf: fixture.device.appendingPathComponent("Playlists/Road Trip.m3u8"), encoding: .utf8)
        #expect(playlist.contains("../Music/AC-DC/Back in Black (1969)/03 What - Why_.flac"))
        #expect(playlist.contains("../Music/The Beatles/Abbey Road (1969)/01 Come Together.flac"))
        // No partial files left behind.
        let leftovers = FileManager.default.enumerator(atPath: fixture.device.path)?.compactMap { $0 as? String }.filter { $0.hasSuffix(".partial") }
        #expect(leftovers?.isEmpty == true)

        // Nothing changed: nothing to do.
        let second = DeviceSync.plan(tracks: [a, b, c], playlists: [DevicePlaylist(name: "Road Trip", tracks: [c, a])],
                                     profile: DeviceProfile(), manifest: DeviceManifest.read(from: fixture.device), mode: .sync,
                                     root: fixture.device) { fixture.exists($0) }
        #expect(second.isEmpty)

        // A changed file is copied again, alone.
        var changed = b
        changed.modifiedAt = .now
        let third = try fixture.sync([a, changed, c], playlists: [DevicePlaylist(name: "Road Trip", tracks: [c, a])])
        #expect(third.writes.map(\.path) == ["Music/The Beatles/Abbey Road (1969)/02 Something.flac"])
    }

    @Test func removesOnlyItsOwnFilesWhenDeselected() throws {
        let fixture = try Fixture()
        let a = try fixture.addTrack(1, "One", artist: "Band", album: "First", number: 1)
        let b = try fixture.addTrack(2, "Two", artist: "Other", album: "Second", number: 1)
        // The user's own files on the card, one where Groovelight would put a song.
        let mine = fixture.device.appendingPathComponent("Music/Mine/keep.mp3")
        try FileManager.default.createDirectory(at: mine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([9]).write(to: mine)
        let clash = fixture.device.appendingPathComponent("Music/Other/Second (1969)/01 Two.flac")
        try FileManager.default.createDirectory(at: clash.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([7]).write(to: clash)

        try fixture.sync([a, b])
        #expect(fixture.exists("Music/Other/Second (1969)/01 Two (2).flac"))
        #expect(try Data(contentsOf: clash) == Data([7]))

        // Band deselected: its song and emptied folders go; everything not Groovelight's stays.
        let plan = try fixture.sync([b])
        #expect(plan.deletions == ["Music/Band/First (1969)/01 One.flac"])
        #expect(!fixture.exists("Music/Band"))
        #expect(fixture.exists("Music/Mine/keep.mp3"))
        #expect(fixture.exists("Music/Other/Second (1969)/01 Two.flac"))
        // The numbered name is kept on later syncs.
        #expect(try fixture.sync([b]).isEmpty)
    }

    @Test func sendingAddsWithoutRemoving() throws {
        let fixture = try Fixture()
        let a = try fixture.addTrack(1, "One", artist: "Band", album: "First", number: 1)
        let b = try fixture.addTrack(2, "Two", artist: "Band", album: "First", number: 2)
        try fixture.sync([a])
        try fixture.sync([b], mode: .send)
        #expect(fixture.exists("Music/Band/First (1969)/01 One.flac"))
        #expect(fixture.exists("Music/Band/First (1969)/02 Two.flac"))
        // A sync without the sent song keeps it: it was not part of the sync.
        let plan = try fixture.sync([a])
        #expect(plan.deletions.isEmpty)
        #expect(fixture.exists("Music/Band/First (1969)/02 Two.flac"))
    }

    @Test func respectsTheProfileAndFAT32() throws {
        let fixture = try Fixture()
        var big = try fixture.addTrack(1, "Long", artist: "Band", album: "Live", number: 1)
        big.fileSize = 5 * 1024 * 1024 * 1024
        var art = try fixture.addTrack(2, "Art", artist: "Band", album: "Live", number: 2)
        art.artworkHash = "abc"
        var profile = DeviceProfile()
        profile.musicFolder = "/MUSIC/"
        profile.template = "{albumartist} - {album}/{track:02} {title}"
        profile.playlistFolder = ""
        let plan = try fixture.sync([big, art], playlists: [DevicePlaylist(name: "Mix", tracks: [art])], profile: profile, fat32: true)
        #expect(plan.skipped.map(\.title) == ["Long"])
        #expect(fixture.exists("MUSIC/Band - Live/02 Art.flac"))
        #expect(fixture.exists("MUSIC/Band - Live/cover.jpg"))
        #expect(fixture.exists("Mix.m3u8"))
        #expect(DeviceManifest.read(from: fixture.device).profile == profile)
    }

    @Test func cleansFolderSettingsAndCounters() {
        #expect(DeviceSync.clean("/Music/../Songs/") == "Music/Songs")
        #expect(DeviceSync.stripCounter("Music/A/01 x (2).flac") == "Music/A/01 x.flac")
        #expect(DeviceSync.stripCounter("Music/A/01 x.flac") == "Music/A/01 x.flac")
    }
}
