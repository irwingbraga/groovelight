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

    @Test func playerDevicesGetSongsTheyCanDecodeOrFLAC() throws {
        let fixture = try Fixture()
        var flac = try fixture.addTrack(1, "Airbag", artist: "Radiohead", album: "OK Computer", number: 1)
        flac.format = "FLAC"
        var alac = try fixture.addTrack(2, "Paranoid Android", artist: "Radiohead", album: "OK Computer", number: 2)
        alac.format = "Apple Lossless"
        alac.path = alac.path.replacingOccurrences(of: ".flac", with: ".m4a")
        var dsd = try fixture.addTrack(3, "Subterranean", artist: "Radiohead", album: "OK Computer", number: 3)
        dsd.format = "DSD Stream"
        var cue = try fixture.addTrack(4, "Exit Music", artist: "Radiohead", album: "OK Computer", number: 4)
        cue.audioPath = cue.path

        let player = DeviceSync.Player(decodes: ["flac", "mp3", "aac"])
        #expect(player.delivery(of: flac) == .asIs)
        #expect(player.delivery(of: alac) == .flac)
        let plan = DeviceSync.plan(tracks: [flac, alac, dsd, cue], playlists: [], profile: DeviceProfile(), manifest: DeviceManifest(),
                                   mode: .sync, root: fixture.device, player: player)
        let songs = Dictionary(uniqueKeysWithValues: plan.writes.filter { $0.entry.kind == .song }.map { ($0.entry.trackId, $0) })
        #expect(songs[1]?.content == .file(flac.url))
        // The ALAC song arrives as FLAC, under a .flac name, and its fingerprint changes with the conversion.
        #expect(songs[2]?.content == .flac(alac.url))
        #expect(songs[2]?.path.hasSuffix("02 Paranoid Android.flac") == true)
        #expect(songs[2]?.entry.fingerprint.hasSuffix("|flac") == true)
        #expect(songs[3] == nil && songs[4] == nil)
        #expect(plan.skipped.map(\.reason).sorted() == ["DSD is not supported on Android yet", "albums with a CUE sheet are not supported in the player yet"])
    }

    @Test func convertsToFLACKeepingTheResolution() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-convert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // One second of 24-bit 96 kHz stereo silence as AIFF, then ALAC (afconvert comes with macOS).
        let aiff = base.appendingPathComponent("tone.aiff")
        let alac = base.appendingPathComponent("tone.m4a")
        try run("/usr/bin/afconvert", ["-f", "AIFF", "-d", "BEI24@96000", "-c", "2", "/System/Library/Sounds/Ping.aiff", aiff.path])
        try run("/usr/bin/afconvert", ["-f", "m4af", "-d", "alac", aiff.path, alac.path])

        let cache = ConversionCache(folder: base.appendingPathComponent("cache"))
        for source in [aiff, alac] {
            let flac = try cache.flac(for: source, fingerprint: source.path)
            let properties = try TagReader.read(flac)
            #expect(properties.format == "FLAC")
            #expect(properties.sampleRate == 96000)
            #expect(properties.bitDepth == 24)
            // Converted once: asking again gives the same file.
            #expect(try cache.flac(for: source, fingerprint: source.path) == flac)
        }
        cache.prune(keeping: [alac.path])
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.folder.path).count == 1)
    }

    private func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
