import Foundation
import Testing
@testable import LibraryKit
@testable import WirelessSync

/// The snapshot as the Mac sends it, kept as a file the Android app's test reads too
/// (android/library/src/test/resources/snapshot-v1.json): both sides agree on every field.
struct SnapshotFixtureTests {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../android/library/src/test/resources/snapshot-v1.json").standardizedFileURL

    static let snapshot = DeviceSnapshot(
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        songs: [
            DeviceSnapshot.Song(id: 101, path: "Music/Radiohead/OK Computer (1997)/01 Airbag.flac", title: "Airbag", artist: "Radiohead",
                                albumKey: "radiohead|ok computer", discNumber: 1, trackNumber: 1, genre: "Alternative", year: 1997, duration: 284.5,
                                codec: "flac", sampleRate: 96000, bitDepth: 24, trackGain: -7.25, albumGain: -6.5, loudness: nil, loved: true,
                                lovedAt: Date(timeIntervalSince1970: 1_700_000_000), rating: 5, playCount: 12,
                                lastPlayed: Date(timeIntervalSince1970: 1_750_000_000), dateAdded: Date(timeIntervalSince1970: 1_600_000_000),
                                lyrics: "[00:10.00]In the next world war", artworkHash: "abc123"),
            DeviceSnapshot.Song(id: 102, path: "Music/Radiohead/OK Computer (1997)/02 Paranoid Android.flac", title: "Paranoid Android",
                                artist: "Radiohead", albumKey: "radiohead|ok computer", discNumber: 1, trackNumber: 2, genre: nil, year: 1997,
                                duration: 383.0, codec: "flac", sampleRate: 44100, bitDepth: 16, trackGain: nil, albumGain: nil, loudness: -12.0,
                                loved: false, lovedAt: nil, rating: 0, playCount: 0, lastPlayed: nil, dateAdded: Date(timeIntervalSince1970: 1_600_000_000),
                                lyrics: nil, artworkHash: "abc123"),
            DeviceSnapshot.Song(id: 201, path: "Music/Compilations/Hits/01 Song.mp3", title: "Song", artist: "Someone",
                                albumKey: "compilation|hits", discNumber: nil, trackNumber: 1, genre: "Pop", year: nil, duration: 200.0,
                                codec: "mp3", sampleRate: 44100, bitDepth: nil, trackGain: nil, albumGain: nil, loudness: nil, loved: false,
                                lovedAt: nil, rating: 0, playCount: 3, lastPlayed: nil, dateAdded: Date(timeIntervalSince1970: 1_650_000_000),
                                lyrics: nil, artworkHash: nil),
        ],
        albums: [
            DeviceSnapshot.Album(key: "compilation|hits", title: "Hits", artist: "Various Artists", year: nil, isCompilation: true, artworkHash: nil),
            DeviceSnapshot.Album(key: "radiohead|ok computer", title: "OK Computer", artist: "Radiohead", year: 1997, isCompilation: false,
                                 artworkHash: "abc123"),
        ],
        playlists: [DeviceSnapshot.Playlist(id: 7, name: "Mix", isSmart: false, songIds: [201, 101],
                                            cover: DeviceSnapshot.Cover(style: "generated", palette: "ocean", pattern: "vinyl", showsTitle: true)),
                    DeviceSnapshot.Playlist(id: 8, name: "Most Played", isSmart: true, songIds: [101, 201])],
        credits: [DeviceSnapshot.Credit(name: "Nigel Godrich", roles: ["producer", "engineer"], albumKey: "radiohead|ok computer",
                                        trackId: nil, wholeRelease: false),
                  DeviceSnapshot.Credit(name: "Jonny Greenwood", roles: ["guitar"], albumKey: "radiohead|ok computer", trackId: 102,
                                        wholeRelease: false)],
        equalizer: DeviceSnapshot.Equalizer(
            presets: [DeviceSnapshot.EQPreset(name: "Headphones", preamp: -3.5, bands: [
                DeviceSnapshot.EQPreset.Band(isEnabled: true, type: "lowShelf", frequency: 105, gain: 5.5, q: 0.7),
                DeviceSnapshot.EQPreset.Band(isEnabled: false, type: "peak", frequency: 2_500, gain: -2, q: 1.41),
            ])],
            current: DeviceSnapshot.EQPreset(name: "Bass", preamp: -6, bands: [
                DeviceSnapshot.EQPreset.Band(isEnabled: true, type: "peak", frequency: 63, gain: 6, q: 2.15),
            ]),
            isEnabled: true))

    static let catalogFixture = fixture.deletingLastPathComponent().appendingPathComponent("catalog-v1.json")

    static var catalog: DeviceCatalog {
        var selection = DeviceSelection()
        selection.albumKeys = ["radiohead|ok computer"]
        selection.trackIds = [301]
        selection.excludedTrackIds = [201]
        return DeviceCatalog(songs: [
            DeviceCatalog.Song(id: 101, title: "Airbag", artist: "Radiohead", albumKey: "radiohead|ok computer", discNumber: 1, trackNumber: 1,
                               duration: 284.5, codec: "flac", sampleRate: 96000, bitDepth: 24, genre: "Alternative", year: 1997, artworkHash: "abc"),
            DeviceCatalog.Song(id: 201, title: "Idioteque", artist: "Radiohead", albumKey: "radiohead|kid a", discNumber: nil, trackNumber: 8,
                               duration: 309, codec: "alac", sampleRate: 44100, bitDepth: 16, genre: nil, year: 2000, artworkHash: nil),
            DeviceCatalog.Song(id: 301, title: "Song", artist: "Someone", albumKey: "compilation|hits", discNumber: nil, trackNumber: nil,
                               duration: 200, codec: "mp3", sampleRate: 44100, bitDepth: nil, genre: "Pop", year: nil, artworkHash: nil),
        ], albums: [
            DeviceCatalog.Album(key: "radiohead|ok computer", title: "OK Computer", artist: "Radiohead", year: 1997, isCompilation: false, artworkHash: "abc"),
            DeviceCatalog.Album(key: "radiohead|kid a", title: "Kid A", artist: "Radiohead", year: 2000, isCompilation: false, artworkHash: nil),
            DeviceCatalog.Album(key: "compilation|hits", title: "Hits", artist: "Various Artists", year: nil, isCompilation: true, artworkHash: nil),
        ], chosen: DeviceCatalog.Chosen(selection))
    }

    @Test func theMacWritesTheSharedCatalogFixture() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let json = try encoder.encode(Self.catalog)
        if ProcessInfo.processInfo.environment["GL_WRITE_FIXTURES"] == "1" { try json.write(to: Self.catalogFixture) }
        #expect(try Data(contentsOf: Self.catalogFixture) == json)
    }

    @Test func theMacWritesTheSharedFixture() throws {
        // The wire's encoding, pretty-printed for a readable file.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let json = try encoder.encode(Self.snapshot)
        // GL_WRITE_FIXTURES=1 writes it after a change to the snapshot (then update the Android test).
        if ProcessInfo.processInfo.environment["GL_WRITE_FIXTURES"] == "1" { try json.write(to: Self.fixture) }
        #expect(try Data(contentsOf: Self.fixture) == json)
        // What the wire carries (compact) decodes to the same.
        let decoded = try WirelessProtocol.decoder.decode(DeviceSnapshot.self, from: WirelessProtocol.encoder.encode(Self.snapshot))
        #expect(decoded == Self.snapshot)
    }
}
