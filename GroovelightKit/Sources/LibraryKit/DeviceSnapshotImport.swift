import Foundation
import GRDB

/// The device's side of the snapshot (Groovelight for iOS): the library a sync brought, into the same database the Mac
/// keeps, so the device's screens and queries are the Mac's. Ids stay the Mac's, so what happens on the device maps back
/// to the same songs and playlists.
extension LibraryDatabase {
    /// Replaces the library with `snapshot`, in one transaction. Songs are in `musicFolder` at their snapshot paths.
    public func importSnapshot(_ snapshot: DeviceSnapshot, musicFolder: URL, now: Date = .now) throws {
        let albums = Dictionary(snapshot.albums.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        try writer.write { db in
            let rootId = try Self.deviceRoot(db, musicFolder: musicFolder)
            // Playlist items and the credits go with the songs; artist photos are all the snapshot's.
            try db.execute(sql: "DELETE FROM playlist")
            // Playlists made here are the Mac's now (with its ids): what they were made as no longer applies.
            try db.execute(sql: "DELETE FROM deviceHistoryEvent WHERE deviceId = ''")
            try db.execute(sql: "DELETE FROM track")
            try db.execute(sql: "DELETE FROM creditIndex")
            try db.execute(sql: "DELETE FROM artistInfo")
            for song in snapshot.songs {
                var track = Self.track(song, album: albums[song.albumKey], rootId: rootId, musicFolder: musicFolder)
                try track.insert(db)
            }
            let songIds = Set(snapshot.songs.map(\.id))
            for item in snapshot.playlists {
                var playlist = Playlist(id: item.id, name: item.name, smartRules: try item.rules.map { try JSONEncoder().encode($0) },
                                        cover: item.cover.flatMap(Self.cover))
                try playlist.insert(db)
                for (position, songId) in item.songIds.enumerated() where songIds.contains(songId) {
                    var entry = PlaylistItem(id: nil, playlistId: item.id, trackId: songId, position: position)
                    try entry.insert(db)
                }
            }
            for credit in snapshot.credits ?? [] where credit.trackId.map(songIds.contains) ?? true {
                try db.execute(sql: """
                    INSERT INTO creditIndex (name, nameKey, artistId, albumKey, trackId, roles, wholeRelease) VALUES (?, ?, NULL, ?, ?, ?, ?)
                    """, arguments: [credit.name, credit.name.lowercased(), credit.albumKey, credit.trackId,
                                     credit.roles.joined(separator: "\n"), credit.wholeRelease])
            }
            for artist in snapshot.artists ?? [] {
                let data = try JSONEncoder().encode(["imageHash": artist.artworkHash])
                try db.execute(sql: "INSERT OR REPLACE INTO artistInfo (artistKey, data, fetchedAt) VALUES (?, ?, ?)",
                               arguments: [artist.name.lowercased(), data, now])
            }
        }
    }

    /// The device's music folder moved (iOS gives an app's container a new path on updates and restores): the songs'
    /// paths follow it. Does nothing when it is where the library has it.
    public func relocateDeviceMusic(to musicFolder: URL) throws {
        try writer.write { db in
            guard let root = try LibraryRoot.fetchOne(db), root.path != musicFolder.path, let rootId = root.id else { return }
            let old = Self.folderPrefix(root.path), new = Self.folderPrefix(musicFolder.path)
            try db.execute(sql: "UPDATE track SET path = ? || substr(path, ?) WHERE rootId = ? AND substr(path, 1, ?) = ?",
                           arguments: [new, old.count + 1, rootId, old.count, old])
            try db.execute(sql: "UPDATE libraryRoot SET path = ? WHERE id = ?", arguments: [musicFolder.path, rootId])
        }
    }

    /// The artwork hashes the library refers to (covers, artist photos, playlist images), to keep in the artwork store.
    public static func artworkHashes(_ db: Database) throws -> Set<String> {
        var hashes = Set(try String.fetchAll(db, sql: "SELECT DISTINCT artworkHash FROM track WHERE artworkHash IS NOT NULL"))
        for row in try Row.fetchAll(db, sql: "SELECT data FROM artistInfo") {
            if let photo = try? JSONDecoder().decode([String: String].self, from: row["data"] as Data)["imageHash"] { hashes.insert(photo) }
        }
        for playlist in try Playlist.fetchAll(db) {
            if case .image(let hash) = playlist.coverStyle?.kind { hashes.insert(hash) }
        }
        return hashes
    }

    /// The one root of a device's library, at the music folder.
    private static func deviceRoot(_ db: Database, musicFolder: URL) throws -> Int64 {
        if var root = try LibraryRoot.fetchOne(db), let id = root.id {
            if root.path != musicFolder.path {
                root.path = musicFolder.path
                try root.update(db)
            }
            try db.execute(sql: "DELETE FROM libraryRoot WHERE id != ?", arguments: [id])
            return id
        }
        var root = LibraryRoot(path: musicFolder.path, bookmark: Data())
        try root.insert(db)
        return root.id!
    }

    private static func folderPrefix(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    static func track(_ song: DeviceSnapshot.Song, album: DeviceSnapshot.Album?, rootId: Int64, musicFolder: URL) -> Track {
        let isCompilation = album?.isCompilation ?? false
        let codec = AudioSpec.Codec(rawValue: song.codec) ?? .unknown
        return Track(id: song.id, rootId: rootId, path: musicFolder.appendingPathComponent(song.path).path, fileSize: 0,
                     modifiedAt: song.dateAdded, title: song.title, artist: song.artist, album: album?.title,
                     albumArtist: isCompilation ? nil : album?.artist, composer: nil, genre: song.genre, year: song.year ?? album?.year,
                     trackNumber: song.trackNumber, trackTotal: nil, discNumber: song.discNumber, discTotal: nil,
                     isCompilation: isCompilation, bpm: nil, comment: nil, lyrics: song.lyrics, musicBrainzRecordingId: nil,
                     musicBrainzReleaseId: nil, replayGainTrackGain: song.trackGain, replayGainAlbumGain: song.albumGain,
                     duration: song.duration, format: codec.formatName, sampleRate: song.sampleRate.map(Double.init),
                     bitDepth: song.bitDepth, bitrate: nil, channels: nil, artworkHash: song.artworkHash ?? album?.artworkHash,
                     albumKey: song.albumKey, rating: song.rating, isLoved: song.loved, playCount: song.playCount, skipCount: 0,
                     lastPlayedAt: song.lastPlayed, dateAdded: song.dateAdded, lovedAt: song.lovedAt, loudness: song.loudness)
    }

    static func cover(_ cover: DeviceSnapshot.Cover) -> PlaylistCover? {
        switch cover.style {
        case "generated":
            guard let palette = cover.palette, let pattern = cover.pattern else { return nil }
            return PlaylistCover(kind: .generated(palette: palette, pattern: pattern), showsTitle: cover.showsTitle)
        case "image":
            return cover.imageHash.map { PlaylistCover(kind: .image(hash: $0), showsTitle: cover.showsTitle) }
        case "songs":
            return PlaylistCover(kind: .songCovers, showsTitle: cover.showsTitle)
        default:
            return nil
        }
    }
}

extension AudioSpec.Codec {
    /// The format name the tag reader gives (`Track.format`), so `init(formatName:)` reads it back.
    var formatName: String? {
        switch self {
        case .flac: "FLAC"
        case .alac: "Apple Lossless"
        case .wav: "WAVE"
        case .aiff: "AIFF"
        case .wavPack: "WavPack"
        case .monkeysAudio: "Monkey's Audio"
        case .trueAudio: "True Audio"
        case .shorten: "Shorten"
        case .oggFLAC: "Ogg FLAC"
        case .dsf: "DSD Stream"
        case .dsdiff: "DSD Interchange"
        case .mp3: "MP3"
        case .aac: "AAC"
        case .vorbis: "Ogg Vorbis"
        case .opus: "Ogg Opus"
        case .musepack: "Musepack"
        case .speex: "Ogg Speex"
        case .mp1: "MPEG-1 Layer I"
        case .mp2: "MPEG-1 Layer II"
        case .module: "Module"
        case .unknown: nil
        }
    }
}
