import Foundation
import GRDB

/// The whole library as the Android app browses it from the Mac (protocol v2): every song and album, with covers by
/// hash, so the device can show what it does not hold and ask for it. Lighter than the snapshot: no lyrics, history or
/// paths. `chosen` is what the device's selection holds now.
public struct DeviceCatalog: Codable, Hashable, Sendable {
    public static let version = 1

    public struct Song: Codable, Hashable, Sendable {
        public var id: Int64
        public var title: String
        public var artist: String
        public var albumKey: String
        public var discNumber: Int?
        public var trackNumber: Int?
        public var duration: Double
        /// `AudioSpec.Codec` raw value of the file on the Mac.
        public var codec: String
        public var sampleRate: Int?
        public var bitDepth: Int?
        public var genre: String?
        public var year: Int?
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

    /// What the device's selection on the Mac holds, as the app can change it.
    public struct Chosen: Codable, Hashable, Sendable {
        public var everything: Bool
        public var albumKeys: [String]
        public var artists: [String]
        public var trackIds: [Int64]
        /// Songs removed from the device: they stay off it whatever else is chosen.
        public var excludedTrackIds: [Int64]
        /// Playlists, genres or Loved Songs are chosen too (on the Mac, not from the app).
        public var hasOthers: Bool

        public init(_ selection: DeviceSelection) {
            everything = selection.everything
            albumKeys = selection.albumKeys.sorted()
            artists = selection.artists.sorted()
            trackIds = selection.trackIds.sorted()
            excludedTrackIds = selection.excludedTrackIds.sorted()
            hasOthers = selection.lovedSongs || !selection.playlistIds.isEmpty || !selection.genres.isEmpty
        }
    }

    public var version = DeviceCatalog.version
    public var songs: [Song]
    public var albums: [Album]
    public var chosen: Chosen

    public static func build(_ db: Database, selection: DeviceSelection) throws -> DeviceCatalog {
        var songs: [Song] = []
        var albums: [String: Album] = [:]
        for track in try LibraryDatabase.allTracks(db) {
            guard let id = track.id else { continue }
            let artwork = track.fetchedArtworkHash ?? track.artworkHash
            songs.append(Song(id: id, title: track.title, artist: track.displayArtist, albumKey: track.albumKey, discNumber: track.discNumber,
                              trackNumber: track.trackNumber, duration: track.duration, codec: AudioSpec.Codec(formatName: track.format).rawValue,
                              sampleRate: track.sampleRate.map { Int($0) }, bitDepth: track.bitDepth,
                              genre: track.genre.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 },
                              year: track.year, artworkHash: artwork))
            if albums[track.albumKey] == nil {
                albums[track.albumKey] = Album(key: track.albumKey, title: track.displayAlbum,
                                               artist: track.isCompilation ? "Various Artists" : track.displayAlbumArtist,
                                               year: track.year, isCompilation: track.isCompilation, artworkHash: artwork)
            } else if albums[track.albumKey]?.artworkHash == nil {
                albums[track.albumKey]?.artworkHash = artwork
            }
        }
        return DeviceCatalog(songs: songs.sorted { $0.id < $1.id }, albums: albums.values.sorted { $0.key < $1.key },
                             chosen: Chosen(selection))
    }
}

/// A change the Android app asks of its selection: add or remove an album, an artist or a song. Made on the device
/// (also while the Mac is away) and sent when it is reachable; applying one twice changes nothing.
public struct TransferRequest: Codable, Hashable, Sendable {
    public enum Action: String, Codable, Sendable { case add, remove }
    public enum Kind: String, Codable, Sendable { case album, artist, song, playlist }

    public var id: String
    public var action: Action
    public var kind: Kind
    /// The album key, the artist's name, the song's id or the playlist's id.
    public var key: String

    public init(id: String, action: Action, kind: Kind, key: String) {
        self.id = id
        self.action = action
        self.kind = kind
        self.key = key
    }
}

extension DeviceSelection {
    /// The selection with the requests applied, in order. Removing takes the album, artist, song or playlist off this
    /// device only (its songs, from `songs`, are left out from then on); adding chooses it and brings back its songs
    /// removed before. `songs` gives the songs of an album, artist, song or playlist.
    public func applying(_ requests: [TransferRequest], songs: (TransferRequest.Kind, String) -> [Int64] = { kind, key in
        kind == .song ? Int64(key).map { [$0] } ?? [] : []
    }) -> DeviceSelection {
        var selection = self
        for request in requests {
            let ids = songs(request.kind, request.key)
            switch request.action {
            case .add:
                selection.excludedTrackIds.subtract(ids)
                switch request.kind {
                case .album: selection.albumKeys.insert(request.key)
                case .artist: selection.artists.insert(request.key)
                case .song: if let id = Int64(request.key) { selection.trackIds.insert(id) }
                case .playlist: if let id = Int64(request.key) { selection.playlistIds.insert(id) }
                }
            case .remove:
                selection.excludedTrackIds.formUnion(ids)
                switch request.kind {
                case .album: selection.albumKeys.remove(request.key)
                case .artist: selection.artists.remove(request.key)
                case .song: if let id = Int64(request.key) { selection.trackIds.remove(id) }
                case .playlist: if let id = Int64(request.key) { selection.playlistIds.remove(id) }
                }
            }
        }
        return selection
    }
}

extension LibraryDatabase {
    /// The songs of what a device asks for: an album, an artist (their albums and their songs on others), a song or a
    /// playlist.
    public static func trackIds(_ db: Database, of kind: TransferRequest.Kind, key: String) throws -> [Int64] {
        switch kind {
        case .album:
            return try tracks(db, albumKey: key).compactMap(\.id)
        case .artist:
            var ids = try albums(db, sort: .year, artist: key).flatMap { try tracks(db, albumKey: $0.albumKey) }.compactMap(\.id)
            ids += try Int64.fetchAll(db, sql: "SELECT id FROM track WHERE artist = ?", arguments: [key])
            return ids
        case .song:
            return Int64(key).map { [$0] } ?? []
        case .playlist:
            return try Int64(key).map { try tracks(db, playlistId: $0).compactMap(\.id) } ?? []
        }
    }
}
