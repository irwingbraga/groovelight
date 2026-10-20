import Foundation
import SFBAudioEngine
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
        #expect(songs[2]?.content == .converted(FormatConverter.Source(url: alac.url)))
        #expect(songs[2]?.path.hasSuffix("02 Paranoid Android.flac") == true)
        #expect(songs[2]?.entry.fingerprint.hasSuffix("|flac") == true)
        #expect(songs[3] == nil)
        #expect(plan.skipped.map(\.reason) == ["DSD is not supported on Android yet"])
        // A song of a CUE album arrives as a FLAC of its own: its region of the album's file, with its own tags.
        #expect(songs[4]?.content == .converted(.cueTrack(cue)))
        #expect(songs[4]?.path.hasSuffix("04 Exit Music.flac") == true)
        #expect(songs[4]?.entry.fingerprint.hasSuffix("|0.0--1.0|flac") == true)
    }

    @Test func devicesSetToALossyFormatGetLosslessSongsEncoded() throws {
        let fixture = try Fixture()
        var flac = try fixture.addTrack(1, "Airbag", artist: "Radiohead", album: "OK Computer", number: 1)
        flac.format = "FLAC"
        flac.duration = 100
        var mp3 = try fixture.addTrack(2, "Lucky", artist: "Radiohead", album: "OK Computer", number: 2)
        mp3.format = "MP3"
        mp3.path = mp3.path.replacingOccurrences(of: ".flac", with: ".mp3")
        var cue = try fixture.addTrack(3, "Exit Music", artist: "Radiohead", album: "OK Computer", number: 3)
        cue.audioPath = cue.path
        cue.format = "FLAC"
        var profile = DeviceProfile()
        profile.encoding = .opus160
        // A memory card (no player): the FLAC song as Opus, the MP3 as it is, the CUE song split and encoded.
        let plan = DeviceSync.plan(tracks: [flac, mp3, cue], playlists: [], profile: profile, manifest: DeviceManifest(), mode: .sync,
                                   root: fixture.device)
        let songs = Dictionary(uniqueKeysWithValues: plan.writes.filter { $0.entry.kind == .song }.map { ($0.entry.trackId, $0) })
        #expect(songs[1]?.content == .converted(FormatConverter.Source(url: flac.url, encoding: .opus160)))
        #expect(songs[1]?.path.hasSuffix("01 Airbag.opus") == true)
        let planned = songs[1]?.entry.size ?? 0
        #expect(planned == 2_000_000, "planned \(planned)")
        #expect(DeviceSync.convertedCodec(fingerprint: songs[1]!.entry.fingerprint) == "opus")
        #expect(songs[2]?.content == .file(mp3.url))
        #expect(DeviceSync.convertedCodec(fingerprint: songs[2]!.entry.fingerprint) == nil)
        #expect(songs[3]?.content == .converted(.cueTrack(cue, encoding: .opus160)))
        #expect(!plan.writes.contains { $0.entry.kind == .cueSheet })

        // A player that cannot decode the format gets FLAC instead.
        let player = DeviceSync.Player(decodes: ["flac", "mp3"])
        let playerPlan = DeviceSync.plan(tracks: [flac], playlists: [], profile: profile, manifest: DeviceManifest(), mode: .sync,
                                         root: fixture.device, player: player)
        #expect(playerPlan.writes.first { $0.entry.trackId == 1 }?.content == .file(flac.url))
    }

    @Test func songsRemovedFromTheDeviceLeaveItAndStayOff() throws {
        let fixture = try Fixture()
        let one = try fixture.addTrack(1, "One", artist: "Band", album: "LP", number: 1)
        let two = try fixture.addTrack(2, "Two", artist: "Band", album: "LP", number: 2)
        let sent = try fixture.addTrack(3, "Sent", artist: "Other", album: "Single", number: 1)
        // The album synced and a song sent to the device.
        let first = DeviceSync.plan(syncing: ([one, two], []), sending: ([sent], []), profile: DeviceProfile(), manifest: DeviceManifest(),
                                    root: fixture.device) { _ in false }
        var manifest = DeviceManifest()
        for write in first.writes { manifest.entries[write.path] = write.entry }
        let onePath = try #require(first.writes.first { $0.entry.trackId == 1 }?.path)
        let sentPath = try #require(first.writes.first { $0.entry.trackId == 3 }?.path)
        #expect(manifest.entries[sentPath]?.synced == false)
        // Removed on the device: the album's first song and the sent one. Still chosen (the album), they leave anyway.
        let excluded: Set<Int64> = [1, 3]
        let next = DeviceSync.plan(syncing: ([one, two], []), sending: ([], []), profile: DeviceProfile(), manifest: manifest,
                                   root: fixture.device, excluded: excluded) { _ in true }
        #expect(Set(next.deletions) == [onePath, sentPath])
        #expect(next.writes.isEmpty && next.unchanged.keys.contains { $0.hasSuffix("02 Two.flac") })

        // Removing and adding change only the selection: removing an album leaves its songs out, adding brings them back.
        var selection = DeviceSelection()
        selection.everything = true
        let songs: (TransferRequest.Kind, String) -> [Int64] = { kind, key in kind == .album && key == "lp" ? [1, 2] : kind == .song ? [Int64(key)!] : [] }
        let removed = selection.applying([TransferRequest(id: "1", action: .remove, kind: .album, key: "lp")], songs: songs)
        #expect(removed.excludedTrackIds == [1, 2] && removed.everything)
        let back = removed.applying([TransferRequest(id: "2", action: .add, kind: .song, key: "2")], songs: songs)
        #expect(back.excludedTrackIds == [1] && back.trackIds == [2])
    }

    @Test func selectionsSavedBeforeSongsCouldBeChosenStillRead() throws {
        let old = Data(#"{"everything":false,"lovedSongs":true,"playlistIds":[],"artists":["Radiohead"],"albumKeys":[],"genres":[]}"#.utf8)
        let selection = try JSONDecoder().decode(DeviceSelection.self, from: old)
        #expect(selection.lovedSongs && selection.artists == ["Radiohead"] && selection.trackIds.isEmpty)
        var chosen = DeviceSelection()
        chosen.trackIds = [7]
        #expect(!chosen.isEmpty)
        #expect(try JSONDecoder().decode(DeviceSelection.self, from: JSONEncoder().encode(chosen)) == chosen)
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

    @Test func convertsWavPackAndSplitsCueSongs() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-cue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // A 16-bit 44.1 kHz album file (Ping is about 1.5 seconds), as WavPack.
        let aiff = base.appendingPathComponent("album.aiff")
        let wavPack = base.appendingPathComponent("album.wv")
        try run("/usr/bin/afconvert", ["-f", "AIFF", "-d", "BEI16@44100", "-c", "2", "/System/Library/Sounds/Ping.aiff", aiff.path])
        try AudioConverter.convert(aiff, to: wavPack)
        let total = try #require(AudioFile(readingPropertiesAndMetadataFrom: aiff).properties.frameLength)

        let cache = ConversionCache(folder: base.appendingPathComponent("cache"))
        let whole = try cache.flac(for: wavPack, fingerprint: "whole")
        #expect(try TagReader.read(whole).format == "FLAC")
        #expect(try AudioFile(readingPropertiesAndMetadataFrom: whole).properties.frameLength == total)

        // Two songs of a CUE album in that file: split at 0.5 s, each with its own tags, and not a sample lost.
        var first = LibraryDatabaseTests.makeTrack(rootId: 1, "Intro", artist: "Band", album: "Live", number: 1)
        first.path = base.path + "/album.cue#01"
        first.audioPath = wavPack.path
        first.startTime = 0
        first.endTime = 0.5
        var second = LibraryDatabaseTests.makeTrack(rootId: 1, "Outro", artist: "Band", album: "Live", number: 2)
        second.path = base.path + "/album.cue#02"
        second.audioPath = wavPack.path
        second.startTime = 0.5
        let one = try cache.flac(for: .cueTrack(first), fingerprint: "1")
        let two = try cache.flac(for: .cueTrack(second), fingerprint: "2")
        #expect(try AudioFile(readingPropertiesAndMetadataFrom: one).properties.frameLength == 22_050)
        #expect(try AudioFile(readingPropertiesAndMetadataFrom: two).properties.frameLength == total - 22_050)
        let tags = try TagReader.read(two)
        #expect(tags.title == "Outro" && tags.trackNumber == 2 && tags.album == "Live")
    }

    @Test func encodesLosslessSongsToEachLossyFormat() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-encode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // A hi-res song (24-bit 96 kHz) with tags.
        let aiff = base.appendingPathComponent("tone.aiff")
        let flac = base.appendingPathComponent("tone.flac")
        try run("/usr/bin/afconvert", ["-f", "AIFF", "-d", "BEI24@96000", "-c", "2", "/System/Library/Sounds/Ping.aiff", aiff.path])
        try FormatConverter.convertToFLAC(aiff, to: flac)
        try TagWriter.write(TrackMetadata(title: "Ping", artist: "Mac", album: "Sounds", trackNumber: 3), to: flac)

        let cache = ConversionCache(folder: base.appendingPathComponent("cache"))
        let expected: [LossyEncoding: (format: String, rate: Double)] = [.opus160: ("Ogg Opus", 48_000), .aac192: ("AAC", 48_000), .mp3_320: ("MP3", 48_000)]
        for encoding in LossyEncoding.allCases {
            let file = try cache.flac(for: FormatConverter.Source(url: flac, encoding: encoding), fingerprint: encoding.rawValue)
            #expect(file.pathExtension == encoding.fileExtension)
            let tags = try TagReader.read(file)
            #expect(tags.format?.hasSuffix(expected[encoding]!.format) == true || AudioSpec.Codec(formatName: tags.format).rawValue == encoding.codec,
                    "\(encoding): \(tags.format ?? "?")")
            #expect(tags.sampleRate == expected[encoding]!.rate, "\(encoding): \(tags.sampleRate ?? 0)")
            #expect(tags.title == "Ping" && tags.trackNumber == 3, "\(encoding) tags")
            // Much smaller than the FLAC, about its bitrate (Ping is about 1.5 seconds).
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let original = try flac.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            #expect(size > 0 && size < original)
        }
        #expect(LossyEncoding.applies(to: .alac) && !LossyEncoding.applies(to: .mp3))
        #expect(LossyEncoding.mp3_320.outputRate(for: 88_200) == 44_100 && LossyEncoding.aac192.outputRate(for: 44_100) == 44_100)
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
