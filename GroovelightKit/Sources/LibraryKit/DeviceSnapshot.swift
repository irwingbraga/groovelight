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
    }

    public var version = DeviceSnapshot.version
    public var createdAt: Date
    public var songs: [Song]
    public var albums: [Album]
    public var playlists: [Playlist]

    /// The snapshot for the songs on a device: `paths` maps each song's id to its path there, `codecs` the ones that
    /// were converted (id to the codec on the device).
    public static func build(_ db: Database, paths: [Int64: String], codecs: [Int64: String] = [:], now: Date = .now) throws -> DeviceSnapshot {
        let tracks = try Track.fetchAll(db, keys: Array(paths.keys))
        var songs: [Song] = []
        var albums: [String: Album] = [:]
        for track in tracks {
            guard let id = track.id, let path = paths[id] else { continue }
            let artwork = track.fetchedArtworkHash ?? track.artworkHash
            songs.append(Song(
                id: id, path: path, title: track.title, artist: track.displayArtist, albumKey: track.albumKey,
                discNumber: track.discNumber, trackNumber: track.trackNumber, genre: track.genre.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 },
                year: track.year, duration: track.duration,
                codec: codecs[id] ?? AudioSpec.Codec(formatName: track.format).rawValue,
                sampleRate: track.sampleRate.map { Int($0) }, bitDepth: track.bitDepth,
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
            if !songIds.isEmpty { playlists.append(Playlist(id: id, name: playlist.name, isSmart: playlist.isSmart, songIds: songIds)) }
        }
        return DeviceSnapshot(createdAt: now, songs: songs.sorted { $0.id < $1.id },
                              albums: albums.values.sorted { $0.key < $1.key }, playlists: playlists)
    }
}
