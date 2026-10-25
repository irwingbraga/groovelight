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

        public init(id: Int64, title: String, artist: String, albumKey: String, discNumber: Int? = nil, trackNumber: Int? = nil, duration: Double,
                    codec: String, sampleRate: Int? = nil, bitDepth: Int? = nil, genre: String? = nil, year: Int? = nil, artworkHash: String? = nil) {
            self.id = id
            self.title = title
            self.artist = artist
            self.albumKey = albumKey
            self.discNumber = discNumber
            self.trackNumber = trackNumber
            self.duration = duration
            self.codec = codec
            self.sampleRate = sampleRate
            self.bitDepth = bitDepth
            self.genre = genre
            self.year = year
            self.artworkHash = artworkHash
        }
    }

    public struct Album: Codable, Hashable, Sendable {
        public var key: String
        public var title: String
        public var artist: String
        public var year: Int?
        public var isCompilation: Bool
        public var artworkHash: String?

        public init(key: String, title: String, artist: String, year: Int? = nil, isCompilation: Bool = false, artworkHash: String? = nil) {
            self.key = key
            self.title = title
            self.artist = artist
            self.year = year
            self.isCompilation = isCompilation
            self.artworkHash = artworkHash
        }
    }

    /// What the device's selection on the Mac holds, as the app can change it.
    public struct Chosen: Codable, Hashable, Sendable {
        public var everything: Bool
        public var albumKeys: [String]
        public var artists: [String]
        public var trackIds: [Int64]
        /// Songs removed from the device: they stay off it whatever else is chosen.
        public var excludedTrackIds: [Int64]
        /// Formats chosen for albums, artists or songs ("album:<key>" to "opus160"...).
        public var encodings: [String: String]
        /// Playlists, genres or Loved Songs are chosen too (on the Mac, not from the app).
        public var hasOthers: Bool

        public init(_ selection: DeviceSelection) {
            everything = selection.everything
            albumKeys = selection.albumKeys.sorted()
            artists = selection.artists.sorted()
            trackIds = selection.trackIds.sorted()
            excludedTrackIds = selection.excludedTrackIds.sorted()
            encodings = selection.encodings
            hasOthers = selection.lovedSongs || !selection.playlistIds.isEmpty || !selection.genres.isEmpty
        }
    }

    public var version = DeviceCatalog.version
    public var songs: [Song]
    public var albums: [Album]
    public var chosen: Chosen
    /// The format this device gets lossless songs in (a `LossyEncoding` raw value; nil: as they are), for its settings.
    public var encoding: String? = nil
    /// Artists' photos (album artists), as in the snapshot. Added after version 1: older readers ignore them.
    public var artists: [DeviceSnapshot.Artist]? = nil

    public static func build(_ db: Database, selection: DeviceSelection, encoding: LossyEncoding? = nil) throws -> DeviceCatalog {
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
        let artists = try LibraryDatabase.artistPhotos(db, names: Set(albums.values.filter { !$0.isCompilation }.map(\.artist)))
            .map { DeviceSnapshot.Artist(name: $0.key, artworkHash: $0.value) }.sorted { $0.name < $1.name }
        return DeviceCatalog(songs: songs.sorted { $0.id < $1.id }, albums: albums.values.sorted { $0.key < $1.key },
                             chosen: Chosen(selection), encoding: encoding?.rawValue, artists: artists)
    }
}

extension DeviceCatalog.Chosen {
    /// With requests not sent yet applied, in order, as the Mac will apply them (`DeviceSelection.applying`): removing
    /// leaves out the songs of what is removed (from `songs`: an album's, an artist's...), adding brings them back.
    public func applying(_ requests: [TransferRequest], songs: (TransferRequest.Kind, String) -> [Int64] = { kind, key in
        kind == .song ? Int64(key).map { [$0] } ?? [] : []
    }) -> Self {
        var albumKeys = Set(albumKeys), artists = Set(artists), trackIds = Set(trackIds), excluded = Set(excludedTrackIds)
        var chosen = self
        for request in requests {
            let ids = songs(request.kind, request.key)
            let add = request.action == .add
            if add { excluded.subtract(ids) } else { excluded.formUnion(ids) }
            // Adding sets its format (or the device's again, without one); removing forgets it.
            if request.kind != .playlist { chosen.encodings[request.encodingKey] = add ? request.encoding : nil }
            switch request.kind {
            case .album: if add { albumKeys.insert(request.key) } else { albumKeys.remove(request.key) }
            case .artist: if add { artists.insert(request.key) } else { artists.remove(request.key) }
            case .song: if let id = Int64(request.key) { if add { trackIds.insert(id) } else { trackIds.remove(id) } }
            case .playlist: break
            }
        }
        chosen.albumKeys = albumKeys.sorted()
        chosen.artists = artists.sorted()
        chosen.trackIds = trackIds.sorted()
        chosen.excludedTrackIds = excluded.sorted()
        return chosen
    }

    /// Whether the album comes to the device (`songs`: its songs, to tell whether all were removed).
    public func holds(_ album: DeviceCatalog.Album, songs: Set<Int64> = []) -> Bool {
        (everything || albumKeys.contains(album.key) || artists.contains(album.artist)) && !(!songs.isEmpty && songs.isSubset(of: excludedTrackIds))
    }

    public func holds(_ song: DeviceCatalog.Song, album: DeviceCatalog.Album?) -> Bool {
        !excludedTrackIds.contains(song.id) && (everything || trackIds.contains(song.id) || albumKeys.contains(song.albumKey)
            || album.map { artists.contains($0.artist) } == true || artists.contains(song.artist))
    }

    /// The format chosen for an album (or its artist), nil for the device's own.
    public func encoding(of album: DeviceCatalog.Album) -> String? {
        encodings["album:\(album.key)"] ?? encodings["artist:\(album.artist)"]
    }
}

/// Where an album or a song of the Mac's library stands for a device, as its library shows it.
public enum CatalogAvailability: Sendable {
    /// Here, and kept by the selection (or by a playlist or genre chosen on the Mac).
    case onDevice
    /// Asked for: the next sync brings it.
    case arriving
    /// Asked for (or let go) while the Mac is away: sent when it is reachable.
    case waiting
    /// No longer asked for: the next sync removes it.
    case leaving
    /// Only on the Mac.
    case onMac

    /// `onDevice`: it is in the device's library; `chosen` and `chosenAfter`: whether the selection holds it as the Mac
    /// knows it and once the waiting requests are applied; `others`: playlists or genres chosen on the Mac may hold it
    /// (so not being chosen does not mean it leaves); `removed`: taken off the device.
    public static func of(onDevice: Bool, chosen: Bool, chosenAfter: Bool, others: Bool, removed: Bool = false) -> Self {
        if chosenAfter != chosen { return .waiting }
        if onDevice && removed { return .leaving }
        if onDevice && !chosen && !others { return .leaving }
        if onDevice { return .onDevice }
        return chosen ? .arriving : .onMac
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
    /// Adding: the format it comes in ("original" or a `LossyEncoding` raw value); nil: the device's.
    public var encoding: String?

    public init(id: String, action: Action, kind: Kind, key: String, encoding: String? = nil) {
        self.id = id
        self.action = action
        self.kind = kind
        self.key = key
        self.encoding = encoding
    }

    /// Its key among `DeviceSelection.encodings`.
    var encodingKey: String { "\(kind.rawValue):\(key)" }
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
                // A format asked for with it (or the device's again, when none).
                if request.kind != .playlist { selection.encodings[request.encodingKey] = request.encoding }
                switch request.kind {
                case .album: selection.albumKeys.insert(request.key)
                case .artist: selection.artists.insert(request.key)
                case .song: if let id = Int64(request.key) { selection.trackIds.insert(id) }
                case .playlist: if let id = Int64(request.key) { selection.playlistIds.insert(id) }
                }
            case .remove:
                selection.excludedTrackIds.formUnion(ids)
                selection.encodings[request.encodingKey] = nil
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

/// Something done on a device that the library should know: a love or unlove (`value` 1 or 0), a rating (0 to 5
/// stars), a play (`value`: seconds heard, `atMs`: when it started) or a skip, with when it happened; or a playlist
/// edit (`playlistId`, negative for one made on the device, with `name` or `trackIds`; `trackId` is 0). Sent by the
/// Android app (`POST /history`); applying one twice changes nothing (all but loves and ratings are applied once by `id`).
public struct DeviceHistoryEvent: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case love, rating, play, skip
        case playlistCreate, playlistAdd, playlistRemove, playlistRename, playlistDelete
        /// From a newer app: left alone.
        case unknown

        public init(from decoder: Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public var id: String
    public var trackId: Int64
    public var kind: Kind
    public var value: Int
    /// Milliseconds since 1970.
    public var atMs: Int64
    public var playlistId: Int64?
    public var name: String?
    public var trackIds: [Int64]?

    public init(id: String, trackId: Int64 = 0, kind: Kind, value: Int = 0, atMs: Int64, playlistId: Int64? = nil, name: String? = nil,
                trackIds: [Int64]? = nil) {
        self.id = id
        self.trackId = trackId
        self.kind = kind
        self.value = value
        self.atMs = atMs
        self.playlistId = playlistId
        self.name = name
        self.trackIds = trackIds
    }

    public var date: Date { Date(timeIntervalSince1970: Double(atMs) / 1000) }

    var isPlaylistEdit: Bool {
        switch kind {
        case .playlistCreate, .playlistAdd, .playlistRemove, .playlistRename, .playlistDelete: true
        default: false
        }
    }
}

/// What a device's history changed: loves (to tell Last.fm) and plays counted (to scrobble).
public struct DeviceHistoryChanges: Sendable {
    public var loves: [(trackId: Int64, loved: Bool)] = []
    public var plays: [(trackId: Int64, startedAt: Date, listened: TimeInterval)] = []

    public var isEmpty: Bool { loves.isEmpty && plays.isEmpty }
}

extension LibraryDatabase {
    /// Applies a device's history, in order. A love or unlove made on the device wins unless the song was loved here
    /// after it (the newer change stays). Plays and skips count once each (`deviceId` and the event's id are kept), and
    /// a play only moves Last Played forward. Returns the loves that changed and the plays counted.
    @discardableResult
    public func applyDeviceHistory(_ events: [DeviceHistoryEvent], deviceId: String = "") throws -> DeviceHistoryChanges {
        try writer.write { db in
            var changed: [Int64: Bool] = [:]
            var changes = DeviceHistoryChanges()
            // Playlist edits keep the device's order (a song added, then removed); the rest by time.
            let edits = events.filter(\.isPlaylistEdit)
            for event in edits {
                guard try Self.firstTime(db, event, deviceId: deviceId) else { continue }
                try Self.applyPlaylistEdit(db, event, deviceId: deviceId)
            }
            for event in events.filter({ !$0.isPlaylistEdit }).sorted(by: { $0.atMs < $1.atMs }) {
                guard let track = try Track.fetchOne(db, key: event.trackId) else { continue }
                switch event.kind {
                case .rating:
                    try db.execute(sql: "UPDATE track SET rating = ? WHERE id = ?", arguments: [min(max(event.value, 0), 5), event.trackId])
                case .love:
                    let loved = event.value == 1
                    guard loved != track.isLoved else { continue }
                    // Loved here after the device's change: the newer one stays.
                    if let lovedAt = track.lovedAt, track.isLoved, lovedAt > event.date { continue }
                    try db.execute(sql: "UPDATE track SET isLoved = ?, lovedAt = ? WHERE id = ?",
                                   arguments: [loved, loved ? event.date : nil, event.trackId])
                    changed[event.trackId] = loved
                case .play, .skip:
                    guard try Self.firstTime(db, event, deviceId: deviceId) else { continue }
                    if event.kind == .skip {
                        try db.execute(sql: "UPDATE track SET skipCount = skipCount + 1 WHERE id = ?", arguments: [event.trackId])
                    } else {
                        try db.execute(sql: """
                            UPDATE track SET playCount = playCount + 1,
                                lastPlayedAt = CASE WHEN lastPlayedAt IS NULL OR lastPlayedAt < ? THEN ? ELSE lastPlayedAt END
                            WHERE id = ?
                            """, arguments: [event.date, event.date, event.trackId])
                        changes.plays.append((event.trackId, event.date, TimeInterval(event.value)))
                    }
                case .unknown, .playlistCreate, .playlistAdd, .playlistRemove, .playlistRename, .playlistDelete:
                    continue
                }
            }
            // Counted plays are remembered for a year: a device resending older ones is not expected.
            try db.execute(sql: "DELETE FROM deviceHistoryEvent WHERE appliedAt < ?", arguments: [Date.now.addingTimeInterval(-365 * 86_400)])
            changes.loves = changed.map { ($0.key, $0.value) }.sorted { $0.trackId < $1.trackId }
            return changes
        }
    }

    /// On a device: the id the Mac knows one of its playlists by. A playlist made on the device (from an edit applied with
    /// `applyDeviceHistory`) is known by the negative id it was made with, until a snapshot brings the Mac's.
    public static func sentPlaylistId(_ db: Database, localId: Int64, deviceId: String = "") throws -> Int64 {
        try Int64.fetchOne(db, sql: """
            SELECT localPlaylistId FROM deviceHistoryEvent WHERE deviceId = ? AND playlistId = ? AND localPlaylistId IS NOT NULL
            """, arguments: [deviceId, localId]) ?? localId
    }

    /// Notes the event as applied; false when it was already (a resend after a lost answer).
    private static func firstTime(_ db: Database, _ event: DeviceHistoryEvent, deviceId: String) throws -> Bool {
        try db.execute(sql: "INSERT OR IGNORE INTO deviceHistoryEvent (deviceId, eventId, appliedAt) VALUES (?, ?, ?)",
                       arguments: [deviceId, event.id, Date.now])
        return db.changesCount > 0
    }

    /// The playlist an edit is about: a negative id is one the device made, found by what it was made as here.
    private static func playlist(_ db: Database, _ id: Int64?, deviceId: String) throws -> Playlist? {
        guard let id else { return nil }
        let resolved = id >= 0 ? id : try Int64.fetchOne(db, sql: """
            SELECT playlistId FROM deviceHistoryEvent WHERE deviceId = ? AND localPlaylistId = ? AND playlistId IS NOT NULL
            """, arguments: [deviceId, id])
        return try resolved.flatMap { try Playlist.fetchOne(db, key: $0) }
    }

    private static func applyPlaylistEdit(_ db: Database, _ event: DeviceHistoryEvent, deviceId: String) throws {
        // Songs the library still has, in the order given.
        let known = try Set(Int64.fetchAll(db, Track.select(Column("id")).filter(keys: event.trackIds ?? [])))
        let songs = (event.trackIds ?? []).filter(known.contains)
        if event.kind == .playlistCreate {
            guard let localId = event.playlistId, try playlist(db, localId, deviceId: deviceId) == nil else { return }
            let name = event.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            var made = Playlist(name: name?.isEmpty == false ? name! : "New Playlist", createdAt: event.date)
            try made.insert(db)
            try append(db, trackIds: songs, to: made.id!)
            try db.execute(sql: "UPDATE deviceHistoryEvent SET localPlaylistId = ?, playlistId = ? WHERE deviceId = ? AND eventId = ?",
                           arguments: [localId, made.id, deviceId, event.id])
            return
        }
        guard let target = try playlist(db, event.playlistId, deviceId: deviceId), let id = target.id else { return }
        switch event.kind {
        case .playlistAdd where !target.isSmart:
            try append(db, trackIds: songs, to: id)
        case .playlistRemove where !target.isSmart:
            let removed = Set(event.trackIds ?? [])
            let kept = try tracks(db, playlistId: id).compactMap(\.id).filter { !removed.contains($0) }
            try db.execute(sql: "DELETE FROM playlistItem WHERE playlistId = ?", arguments: [id])
            try append(db, trackIds: kept, to: id)
        case .playlistRename:
            guard let name = event.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            try db.execute(sql: "UPDATE playlist SET name = ? WHERE id = ?", arguments: [name, id])
        case .playlistDelete:
            _ = try Playlist.deleteOne(db, key: id)
        default:
            return
        }
    }
}
