import Foundation
import GRDB

public struct LibraryRoot: Codable, Hashable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "libraryRoot"

    public var id: Int64?
    public var path: String
    /// Security-scoped bookmark data so the sandboxed app can reopen the folder after relaunch.
    public var bookmark: Data
    public var addedAt: Date
    /// Last time anything in the folder was checked (a change was picked up, or a full scan).
    public var lastScanAt: Date?
    /// File system event id up to which the folder's changes are in the library (nil: unknown, a full scan is needed).
    public var eventId: Int64? = nil
    /// The volume's event history id when `eventId` was saved; a different one means the history was reset.
    public var eventsVolumeId: String? = nil
    /// Last time every file of the folder was checked.
    public var lastFullScanAt: Date? = nil

    public init(id: Int64? = nil, path: String, bookmark: Data, addedAt: Date = .now, lastScanAt: Date? = nil) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.addedAt = addedAt
        self.lastScanAt = lastScanAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct Track: Codable, Hashable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "track"

    public var id: Int64?
    public var rootId: Int64
    public var path: String
    public var fileSize: Int64
    public var modifiedAt: Date

    public var title: String
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var composer: String?
    public var genre: String?
    public var year: Int?
    public var trackNumber: Int?
    public var trackTotal: Int?
    public var discNumber: Int?
    public var discTotal: Int?
    public var isCompilation: Bool
    public var bpm: Int?
    public var comment: String?
    public var lyrics: String?
    public var musicBrainzRecordingId: String?
    public var musicBrainzReleaseId: String?
    public var replayGainTrackGain: Double?
    public var replayGainAlbumGain: Double?

    public var duration: Double
    public var format: String?
    public var sampleRate: Double?
    public var bitDepth: Int?
    public var bitrate: Double?
    public var channels: Int?

    public var artworkHash: String?
    /// Grouping key for albums: normalized album artist (or "compilation") + album title.
    public var albumKey: String

    public var rating: Int
    public var isLoved: Bool
    public var playCount: Int
    public var skipCount: Int
    public var lastPlayedAt: Date?
    public var dateAdded: Date

    /// JSON `TrackMetadata` fixes kept in the database (not written to the file), reapplied on every rescan.
    public var metadataOverrides: Data? = nil
    /// Lyrics fetched online (LRC or plain text); the file's own `lyrics` win.
    public var fetchedLyrics: String? = nil
    /// Last online lyrics lookup, so misses are not retried on every play.
    public var lyricsCheckedAt: Date? = nil
    /// Cover fetched online, used when the file and its folder have none.
    public var fetchedArtworkHash: String? = nil
    /// When the song was loved, for Loved Songs' "most recently loved first" order.
    public var lovedAt: Date? = nil
    /// For a track of a CUE sheet: the audio file holding it (`path` is then "<sheet path>#NN", unique per track),
    /// and where the track starts and ends in it (nil end: the end of the file).
    public var audioPath: String? = nil
    public var startTime: Double? = nil
    public var endTime: Double? = nil

    /// The audio file (for a CUE track, the file holding the whole album).
    public var url: URL { URL(fileURLWithPath: audioPath ?? path) }

    /// A track of a CUE sheet (one of several songs in one audio file).
    public var isCueTrack: Bool { audioPath != nil }

    /// The cue sheet of a CUE track (the audio file itself for an embedded sheet).
    public var cueSheetURL: URL? {
        guard isCueTrack, let hash = path.lastIndex(of: "#") else { return nil }
        return URL(fileURLWithPath: String(path[..<hash]))
    }

    /// Artist shown for album grouping: album artist, then track artist.
    public var displayAlbumArtist: String {
        if isCompilation { return "Various Artists" }
        return albumArtist.nonEmpty ?? artist.nonEmpty ?? "Unknown Artist"
    }

    public var displayArtist: String { artist.nonEmpty ?? albumArtist.nonEmpty ?? "Unknown Artist" }
    public var displayAlbum: String { album.nonEmpty ?? "Unknown Album" }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public static func makeAlbumKey(album: String?, albumArtist: String?, artist: String?, isCompilation: Bool) -> String {
        let artistPart = isCompilation ? "\u{1}compilation" : (albumArtist.nonEmpty ?? artist.nonEmpty ?? "")
        return "\(artistPart.normalizedKey)\u{1F}\((album ?? "").normalizedKey)"
    }
}

/// One row per album, derived from tracks.
public struct AlbumSummary: Codable, Hashable, Sendable, Identifiable, FetchableRecord {
    public var id: String { albumKey }
    public var albumKey: String
    public var title: String
    public var artist: String
    public var year: Int?
    public var genre: String?
    public var trackCount: Int
    public var duration: Double
    public var artworkHash: String?
    public var dateAdded: Date
}

public struct ArtistSummary: Codable, Hashable, Sendable, Identifiable, FetchableRecord {
    public var id: String { name }
    public var name: String
    public var albumCount: Int
    public var trackCount: Int
    public var artworkHash: String?
}

public struct Playlist: Codable, Hashable, Sendable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "playlist"

    public var id: Int64?
    public var name: String
    public var createdAt: Date
    /// JSON encoded `SmartPlaylistRules` for smart playlists, nil for manual ones.
    public var smartRules: Data?
    /// JSON encoded `PlaylistCover`; nil shows the songs' covers.
    public var cover: Data? = nil

    public var isSmart: Bool { smartRules != nil }

    public init(id: Int64? = nil, name: String, createdAt: Date = .now, smartRules: Data? = nil, cover: PlaylistCover? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.smartRules = smartRules
        self.cover = cover.flatMap { try? JSONEncoder().encode($0) }
    }

    public var coverStyle: PlaylistCover? {
        cover.flatMap { try? JSONDecoder().decode(PlaylistCover.self, from: $0) }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct PlaylistItem: Codable, Hashable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "playlistItem"

    public var id: Int64?
    public var playlistId: Int64
    public var trackId: Int64
    public var position: Int

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

extension String {
    /// Case, diacritic and width insensitive key, with a leading "The " removed.
    var normalizedKey: String {
        var value = folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("the ") { value.removeFirst(4) }
        return value
    }
}

/// A playlist with what its card shows: song count, length and up to four covers.
public struct PlaylistSummary: Hashable, Sendable, Identifiable {
    public var playlist: Playlist
    public var trackCount: Int
    public var duration: Double
    public var artworkHashes: [String]
    public var id: Int64 { playlist.id ?? -1 }
}

/// Everything the All Playlists page lists: Loved Songs first, then the playlists.
public struct PlaylistOverview: Hashable, Sendable {
    public var lovedCount: Int
    public var lovedDuration: Double
    public var lovedArtworkHashes: [String]
    public var playlists: [PlaylistSummary]
}

/// How a playlist's cover looks: a generated design (a color palette and an optional pattern), a custom image, or the
/// songs' covers, optionally with the playlist name drawn in the top left corner.
public struct PlaylistCover: Codable, Hashable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        /// Palette and pattern ids, resolved by the app.
        case generated(palette: String, pattern: String)
        /// Image stored in the artwork cache.
        case image(hash: String)
        /// Up to four covers of the playlist's songs.
        case songCovers
    }

    public var kind: Kind
    public var showsTitle: Bool

    public init(kind: Kind, showsTitle: Bool = false) {
        self.kind = kind
        self.showsTitle = showsTitle
    }
}
