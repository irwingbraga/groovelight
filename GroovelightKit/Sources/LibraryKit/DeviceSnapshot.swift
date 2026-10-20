import Foundation
import GRDB

/// The library as a player device needs it, for the songs on that device: what the Mac knows about each song (tags as
/// shown, loudness, loves, ratings, play history, lyrics, cover), their albums, and the playlists holding them. The
/// device's own database is filled from it, so it shows the library as on the Mac without reading tags itself.
/// Ids are the Mac's, so what happens on the device maps back to the same songs.
public struct DeviceSnapshot: Codable, Hashable, Sendable {
    public static let version = 1

    public struct Song: Codable, Hashable, Sendable {
        public var id: Int64
        /// Where the song is on the device, relative to its music folder.
        public var path: String
        public var title: String
        public var artist: String
        public var albumKey: String
        public var discNumber: Int?
        public var trackNumber: Int?
        public var genre: String?
        public var year: Int?
        /// Seconds.
        public var duration: Double
        /// `AudioSpec.Codec` raw value of the file on the device ("flac" for a converted song).
        public var codec: String
        public var sampleRate: Int?
        public var bitDepth: Int?
        /// ReplayGain in dB from the file's tags.
        public var trackGain: Double?
        public var albumGain: Double?
        /// The Mac's EBU R128 measurement (LUFS) for songs without ReplayGain tags.
        public var loudness: Double?
        public var loved: Bool
        public var lovedAt: Date?
        public var rating: Int
        public var playCount: Int
        public var lastPlayed: Date?
        public var dateAdded: Date
        /// LRC text when synced, plain text otherwise.
        public var lyrics: String?
        public var artworkHash: String?
    }

    public struct Album: Codable, Hashable, Sendable {
        public var key: String
        public var title: String
        public var artist: String
        public var year: Int?
        public var isCompilation: Bool
        public var artworkHash: String?
    }

    public struct Playlist: Codable, Hashable, Sendable {
        public var id: Int64
        public var name: String
        public var isSmart: Bool
        /// The songs on the device, in order (smart playlists as the Mac evaluated them).
        public var songIds: [Int64]
        /// How its cover is drawn (nil: the songs' covers, with the name). Added after version 1.
        public var cover: Cover? = nil
    }

    /// A playlist's cover as the Mac draws it: a generated gradient and pattern, an image, or its songs' covers.
    public struct Cover: Codable, Hashable, Sendable {
        /// "generated", "image" or "songs".
        public var style: String
        /// `CoverPalette` and `CoverPattern` ids (generated covers).
        public var palette: String?
        public var pattern: String?
        /// The image in the artwork store (image covers).
        public var imageHash: String?
        public var showsTitle: Bool

        public init(style: String, palette: String? = nil, pattern: String? = nil, imageHash: String? = nil, showsTitle: Bool) {
            self.style = style
            self.palette = palette
            self.pattern = pattern
            self.imageHash = imageHash
            self.showsTitle = showsTitle
        }

        init(_ cover: PlaylistCover) {
            switch cover.kind {
            case let .generated(palette, pattern): self.init(style: "generated", palette: palette, pattern: pattern, showsTitle: true)
            case let .image(hash): self.init(style: "image", imageHash: hash, showsTitle: cover.showsTitle)
            case .songCovers: self.init(style: "songs", showsTitle: true)
            }
        }
    }

    /// Someone credited on an album (`trackId` nil) or on one of its songs on the device, from the Mac's credit index.
    public struct Credit: Codable, Hashable, Sendable {
        public var name: String
        public var roles: [String]
        public var albumKey: String
        public var trackId: Int64?
        /// Credited on the release itself (mastering, design...): it applies to every song of the album.
        public var wholeRelease: Bool
    }

    /// An equalizer curve as the Mac keeps it (the same fields as `PlayerCore.EQPreset`).
    public struct EQPreset: Codable, Hashable, Sendable {
        public struct Band: Codable, Hashable, Sendable {
            public var isEnabled: Bool
            /// `EQFilterType` raw value: peak, lowShelf, highShelf, lowPass, highPass, bandPass, notch.
            public var type: String
            public var frequency: Double
            public var gain: Double
            public var q: Double

            public init(isEnabled: Bool, type: String, frequency: Double, gain: Double, q: Double) {
                self.isEnabled = isEnabled
                self.type = type
                self.frequency = frequency
                self.gain = gain
                self.q = q
            }
        }

        public var name: String
        public var preamp: Double
        public var bands: [Band]

        public init(name: String, preamp: Double, bands: [Band]) {
            self.name = name
            self.preamp = preamp
            self.bands = bands
        }
    }

    /// The Mac's equalizer: its saved presets and the curve in use, offered on the device.
    public struct Equalizer: Codable, Hashable, Sendable {
        public var presets: [EQPreset]
        public var current: EQPreset?
        public var isEnabled: Bool

        public init(presets: [EQPreset], current: EQPreset?, isEnabled: Bool) {
            self.presets = presets
            self.current = current
            self.isEnabled = isEnabled
        }
    }

    public var version = DeviceSnapshot.version
    public var createdAt: Date
    public var songs: [Song]
    public var albums: [Album]
    public var playlists: [Playlist]
    /// Added after version 1 shipped: older readers ignore them.
    public var credits: [Credit]? = nil
    public var equalizer: Equalizer? = nil

    /// The snapshot for the songs on a device: `paths` maps each song's id to its path there, `codecs` the ones that
    /// were converted (id to the codec on the device).
    public static func build(_ db: Database, paths: [Int64: String], codecs: [Int64: String] = [:], equalizer: Equalizer? = nil,
                             now: Date = .now) throws -> DeviceSnapshot {
        let tracks = try Track.fetchAll(db, keys: Array(paths.keys))
        var songs: [Song] = []
        var albums: [String: Album] = [:]
        for track in tracks {
            guard let id = track.id, let path = paths[id] else { continue }
            let artwork = track.fetchedArtworkHash ?? track.artworkHash
            // An encoded song: its format's sample rate, no bit depth (lossy).
            let lossy = codecs[id].flatMap { codec in LossyEncoding.allCases.first { $0.codec == codec } }
            songs.append(Song(
                id: id, path: path, title: track.title, artist: track.displayArtist, albumKey: track.albumKey,
                discNumber: track.discNumber, trackNumber: track.trackNumber, genre: track.genre.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 },
                year: track.year, duration: track.duration,
                codec: codecs[id] ?? AudioSpec.Codec(formatName: track.format).rawValue,
                sampleRate: track.sampleRate.map { Int(lossy?.outputRate(for: $0) ?? $0) }, bitDepth: lossy == nil ? track.bitDepth : nil,
                trackGain: track.replayGainTrackGain, albumGain: track.replayGainAlbumGain, loudness: track.loudness,
                loved: track.isLoved, lovedAt: track.lovedAt, rating: track.rating, playCount: track.playCount,
                lastPlayed: track.lastPlayedAt, dateAdded: track.dateAdded, lyrics: track.displayLyrics, artworkHash: artwork))
            if albums[track.albumKey] == nil {
                albums[track.albumKey] = Album(key: track.albumKey, title: track.displayAlbum,
                                               artist: track.isCompilation ? "Various Artists" : track.displayAlbumArtist,
                                               year: track.year, isCompilation: track.isCompilation, artworkHash: artwork)
            } else if albums[track.albumKey]?.artworkHash == nil {
                albums[track.albumKey]?.artworkHash = artwork
            }
        }
        var playlists: [Playlist] = []
        for playlist in try LibraryDatabase.playlists(db) {
            guard let id = playlist.id else { continue }
            let songIds = try LibraryDatabase.tracks(db, playlistId: id).compactMap(\.id).filter { paths[$0] != nil }
            if !songIds.isEmpty {
                playlists.append(Playlist(id: id, name: playlist.name, isSmart: playlist.isSmart, songIds: songIds,
                                          cover: playlist.coverStyle.map(Cover.init)))
            }
        }
        // Credits of the albums on the device; song credits only for songs that are there.
        var credits: [Credit] = []
        let keys = Array(albums.keys)
        for start in stride(from: 0, to: keys.count, by: 500) {
            let chunk = Array(keys[start..<min(start + 500, keys.count)])
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for row in try Row.fetchAll(db, sql: "SELECT * FROM creditIndex WHERE albumKey IN (\(marks)) ORDER BY id",
                                        arguments: StatementArguments(chunk)) {
                let trackId: Int64? = row["trackId"]
                if let trackId, paths[trackId] == nil { continue }
                credits.append(Credit(name: row["name"], roles: (row["roles"] as String).split(separator: "\n").map(String.init),
                                      albumKey: row["albumKey"], trackId: trackId, wholeRelease: row["wholeRelease"]))
            }
        }
        return DeviceSnapshot(createdAt: now, songs: songs.sorted { $0.id < $1.id },
                              albums: albums.values.sorted { $0.key < $1.key }, playlists: playlists, credits: credits,
                              equalizer: equalizer)
    }
}
