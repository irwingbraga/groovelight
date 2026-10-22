import CryptoKit
import Foundation
import GRDB
import ImageIO

// MARK: - Profile and selection

/// How music is laid out on a portable player or memory card. Kept per device (and in the device's manifest, so a
/// card keeps its layout on another Mac).
public struct DeviceProfile: Codable, Hashable, Sendable {
    /// Folder for the songs, from the device's root ("Music"; empty: the root itself).
    public var musicFolder = "Music"
    /// Path of each song inside it, as in Organize (tokens like {albumartist}, {album}, {track:02}, {title}).
    public var template = OrganizeOptions.defaultTemplate
    /// Folder for the playlists (M3U8), from the root.
    public var playlistFolder = "Playlists"
    public var writesPlaylists = true
    /// A cover.jpg in each album folder, for players that do not read embedded artwork.
    public var writesCovers = true
    /// Longest side of cover.jpg in pixels; 0 keeps the original image.
    public var coverSize = 600
    /// Synced lyrics as .lrc files beside the songs.
    public var writesLyrics = true
    /// Lossless songs go to the device in this lossy format (nil: as they are, or FLAC for players that need it).
    public var encoding: LossyEncoding?

    public static let coverSizes = [300, 500, 600, 1000, 0]

    public init() {}

    var naming: OrganizeOptions { OrganizeOptions(template: template, organizeFolders: true, portableNames: true) }
}

/// What a device holds: everything, or a mix of playlists, artists, albums and genres.
public struct DeviceSelection: Codable, Hashable, Sendable {
    public var everything = false
    public var lovedSongs = false
    public var playlistIds: Set<Int64> = []
    public var artists: Set<String> = []
    public var albumKeys: Set<String> = []
    public var genres: Set<String> = []
    /// Songs chosen one by one (from the Android app's view of the whole library).
    public var trackIds: Set<Int64> = []
    /// Songs removed from this device (from the Android app): left out whatever brings them (an album, an artist, a
    /// playlist, all music, a send), and their files deleted from the device. Only the device changes: the library
    /// keeps them. Adding them again (their album, artist or the song) brings them back.
    public var excludedTrackIds: Set<Int64> = []
    /// Formats chosen for parts of the selection, over the device's own: keys "album:<key>", "artist:<name>" or
    /// "song:<id>", values "original" or a `LossyEncoding` raw value (an album asked for as Opus on the phone).
    public var encodings: [String: String] = [:]

    public init() {}

    public var isEmpty: Bool {
        !everything && !lovedSongs && playlistIds.isEmpty && artists.isEmpty && albumKeys.isEmpty && genres.isEmpty && trackIds.isEmpty
    }

    private enum CodingKeys: String, CodingKey { case everything, lovedSongs, playlistIds, artists, albumKeys, genres, trackIds, excludedTrackIds, encodings }

    // Selections saved before a field existed decode with it empty.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        everything = try container.decodeIfPresent(Bool.self, forKey: .everything) ?? false
        lovedSongs = try container.decodeIfPresent(Bool.self, forKey: .lovedSongs) ?? false
        playlistIds = try container.decodeIfPresent(Set<Int64>.self, forKey: .playlistIds) ?? []
        artists = try container.decodeIfPresent(Set<String>.self, forKey: .artists) ?? []
        albumKeys = try container.decodeIfPresent(Set<String>.self, forKey: .albumKeys) ?? []
        genres = try container.decodeIfPresent(Set<String>.self, forKey: .genres) ?? []
        trackIds = try container.decodeIfPresent(Set<Int64>.self, forKey: .trackIds) ?? []
        excludedTrackIds = try container.decodeIfPresent(Set<Int64>.self, forKey: .excludedTrackIds) ?? []
        encodings = try container.decodeIfPresent([String: String].self, forKey: .encodings) ?? [:]
    }

    /// The format a song goes to the device in: the one chosen for it, else for its album, else for its artist, else
    /// the device's (`fallback`).
    public func encoding(for track: Track, fallback: LossyEncoding?) -> LossyEncoding? {
        let keys = ["song:\(track.id ?? -1)", "album:\(track.albumKey)", "artist:\(track.displayAlbumArtist)", "artist:\(track.displayArtist)"]
        guard let chosen = keys.lazy.compactMap({ encodings[$0] }).first else { return fallback }
        return LossyEncoding(rawValue: chosen)
    }
}

/// A playlist to write on the device, with its songs.
public struct DevicePlaylist: Hashable, Sendable {
    public var name: String
    public var tracks: [Track]

    public init(name: String, tracks: [Track]) {
        self.name = name
        self.tracks = tracks
    }
}

extension LibraryDatabase {
    /// The songs and playlists a selection puts on a device (songs once each, in library order).
    public static func deviceContents(_ db: Database, _ selection: DeviceSelection) throws -> (tracks: [Track], playlists: [DevicePlaylist]) {
        var playlists: [DevicePlaylist] = []
        if selection.lovedSongs {
            playlists.append(DevicePlaylist(name: "Loved Songs", tracks: try lovedTracks(db)))
        }
        for playlist in try self.playlists(db) where selection.playlistIds.contains(playlist.id ?? -1) {
            playlists.append(DevicePlaylist(name: playlist.name, tracks: try tracks(db, playlistId: playlist.id!)))
        }
        var tracks: [Track]
        if selection.everything {
            tracks = try allTracks(db)
        } else {
            tracks = playlists.flatMap(\.tracks)
            for artist in selection.artists.sorted() {
                for album in try albums(db, sort: .year, artist: artist) {
                    tracks += try self.tracks(db, albumKey: album.albumKey)
                }
            }
            for key in selection.albumKeys.sorted() {
                tracks += try self.tracks(db, albumKey: key)
            }
            for genre in selection.genres.sorted() {
                tracks += try Track.fetchAll(db, sql: "SELECT * FROM track WHERE TRIM(genre) = ? COLLATE NOCASE", arguments: [genre])
            }
            tracks += try Track.fetchAll(db, keys: Array(selection.trackIds)).sorted { $0.path < $1.path }
        }
        var seen = Set<Int64>()
        // Songs removed from the device stay off it, and out of its playlists.
        let excluded = selection.excludedTrackIds
        tracks = tracks.filter { !excluded.contains($0.id ?? -1) && seen.insert($0.id ?? -1).inserted }
        if !excluded.isEmpty { playlists = playlists.map { DevicePlaylist(name: $0.name, tracks: $0.tracks.filter { !excluded.contains($0.id ?? -1) }) } }
        return (tracks, playlists)
    }
}

// MARK: - Manifest

/// What Groovelight wrote on a device, kept there as `.groovelight-device.json`: lets a sync copy only what changed
/// and remove only its own files (never other files on the card).
public struct DeviceManifest: Codable, Hashable, Sendable {
    public static let fileName = ".groovelight-device.json"

    public enum Kind: String, Codable, Sendable {
        case song, cueSheet, cover, lyrics, playlist
    }

    public struct Entry: Codable, Hashable, Sendable {
        public var kind: Kind
        public var trackId: Int64?
        /// What the file was made from: the source file's path, size and date for songs, a content hash otherwise.
        public var fingerprint: String
        public var size: Int64
        /// Written by a sync (removed when no longer selected) rather than sent once (kept until removed by hand).
        public var synced: Bool
    }

    public var profile: DeviceProfile?
    /// Relative path on the device -> entry.
    public var entries: [String: Entry] = [:]
    public var lastSync: Date?

    public init() {}

    public static func read(from root: URL) -> DeviceManifest {
        let url = root.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return DeviceManifest() }
        return (try? decoder.decode(DeviceManifest.self, from: data)) ?? DeviceManifest()
    }

    public func write(to root: URL) throws {
        try Self.encoder.encode(self).write(to: root.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Space taken by Groovelight's files.
    public var musicBytes: Int64 { entries.values.reduce(0) { $0 + $1.size } }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - Planning

/// Everything a sync or send will do on a device.
public struct DeviceSyncPlan: Sendable {
    public enum Content: Hashable, Sendable {
        case file(URL)
        /// Made when written: cover.jpg from the artwork cache.
        case cover(hash: String)
        case data(Data)
        /// The song converted: to FLAC (for a player that cannot decode its format, or a song of a CUE album), or to
        /// the device's lossy format.
        case converted(FormatConverter.Source)
    }

    public struct Write: Hashable, Sendable {
        public var path: String
        public var content: Content
        public var entry: DeviceManifest.Entry
    }

    public var writes: [Write] = []
    /// Relative paths of Groovelight's files to remove.
    public var deletions: [String] = []
    /// Desired files already on the device and current.
    public var unchanged: [String: DeviceManifest.Entry] = [:]
    /// Songs left out, with the reason (a file over FAT32's 4 GB limit, a missing file).
    public var skipped: [(title: String, reason: String)] = []
    public var songCount = 0

    public var bytesToWrite: Int64 { writes.reduce(0) { $0 + $1.entry.size } }
    public var bytesToFree: Int64 = 0
    /// How much more (or less, when negative) of the device the music will take.
    public var netBytes: Int64 { bytesToWrite - bytesToFree }
    public var isEmpty: Bool { writes.isEmpty && deletions.isEmpty }
}

public enum DeviceSync {
    /// The format each song goes to a device in (chosen per album, artist or song over the device's own).
    public struct Formats: Sendable {
        public var choose: @Sendable (Track) -> LossyEncoding?

        public init(_ choose: @escaping @Sendable (Track) -> LossyEncoding?) {
            self.choose = choose
        }

        /// From a device's selection, over `fallback` (its own format).
        public static func of(_ selection: DeviceSelection, fallback: LossyEncoding?) -> Formats {
            Formats { selection.encoding(for: $0, fallback: fallback) }
        }
    }

    /// The codec a converted song has on the device, from its manifest fingerprint ("|flac", "|opus160"...); nil for a
    /// song copied as it is.
    public static func convertedCodec(fingerprint: String) -> String? {
        guard let suffix = fingerprint.split(separator: "|").last.map(String.init) else { return nil }
        if suffix == "flac" { return "flac" }
        return LossyEncoding(rawValue: suffix)?.codec
    }

    /// A device where Groovelight itself plays the music (Groovelight for Android in Player mode): it gets the songs
    /// only (their covers, lyrics and playlists come with the library snapshot), and songs in formats it cannot decode
    /// are converted to FLAC.
    public struct Player: Hashable, Sendable {
        /// `AudioSpec.Codec` raw values the device decodes ("flac", "mp3", "aac"...).
        public var decodes: Set<String>

        public init(decodes: Set<String>) {
            self.decodes = decodes
        }

        /// How the device gets a song: as it is, converted to FLAC, or not at all (with the reason).
        public func delivery(of track: Track) -> Delivery {
            let codec = AudioSpec.Codec(formatName: track.format)
            if decodes.contains(codec.rawValue) { return .asIs }
            switch codec {
            case .dsf, .dsdiff: return .skip("DSD is not supported on Android yet")
            case .module: return .skip("tracker modules do not play on Android")
            default: return .flac
            }
        }

        public enum Delivery: Equatable, Sendable {
            case asIs
            case flac
            case skip(String)
        }
    }

    public enum Mode: Sendable {
        /// The device ends up with exactly the selection: Groovelight's other synced files are removed.
        case sync
        /// Adds the songs (and updates them); nothing is removed.
        case send
    }

    /// FAT32's largest file.
    static let fat32Limit: Int64 = 4 * 1024 * 1024 * 1024 - 1

    /// Plans putting `tracks` and `playlists` on the device at `root`. `existing` answers whether a path is already
    /// taken by a file Groovelight did not write (another file with that name is then used); `fat32` enforces the
    /// 4 GB file limit.
    public static func plan(tracks: [Track], playlists: [DevicePlaylist], profile: DeviceProfile, manifest: DeviceManifest,
                            mode: Mode, root: URL, fat32: Bool = false, player: Player? = nil, excluded: Set<Int64> = [],
                            formats: Formats? = nil,
                            existing: (String) -> Bool = { _ in false }) -> DeviceSyncPlan {
        // Each song's format: chosen per album, artist or song (`formats`), else the device's.
        let format: (Track) -> LossyEncoding? = formats?.choose ?? { _ in profile.encoding }
        let tracks = excluded.isEmpty ? tracks : tracks.filter { !excluded.contains($0.id ?? -1) }
        var plan = DeviceSyncPlan()
        var desired: [String: (DeviceSyncPlan.Content, DeviceManifest.Entry)] = [:]
        /// Lowercased paths in use (FAT and exFAT ignore case).
        var taken = Set<String>()
        /// Where each song went, for playlists.
        var placed: [Int64: String] = [:]
        let musicFolder = clean(profile.musicFolder)
        let naming = profile.naming

        func inMusic(_ relative: String) -> String { musicFolder.isEmpty ? relative : "\(musicFolder)/\(relative)" }
        func isForeign(_ path: String) -> Bool { manifest.entries[path] == nil && existing(path) }
        /// A free name for `path`: " (2)", " (3)"... when another planned file or a file not ours holds it.
        func claim(_ path: String) -> String {
            var candidate = path
            var counter = 2
            while taken.contains(candidate.lowercased()) || isForeign(candidate) {
                let url = URL(fileURLWithPath: "/" + path)
                let ext = url.pathExtension
                let stem = url.deletingPathExtension().lastPathComponent
                let folder = (path as NSString).deletingLastPathComponent
                let name = "\(stem) (\(counter))" + (ext.isEmpty ? "" : ".\(ext)")
                candidate = folder.isEmpty ? name : "\(folder)/\(name)"
                counter += 1
            }
            taken.insert(candidate.lowercased())
            return candidate
        }
        func add(_ path: String, _ content: DeviceSyncPlan.Content, kind: DeviceManifest.Kind, trackId: Int64? = nil,
                 fingerprint: String, size: Int64) {
            desired[path] = (content, DeviceManifest.Entry(kind: kind, trackId: trackId, fingerprint: fingerprint, size: size,
                                                           synced: mode == .sync))
        }
        func songFingerprint(_ track: Track) -> String {
            "\(track.audioPath ?? track.path)|\(track.fileSize)|\(Int(track.modifiedAt.timeIntervalSince1970))"
        }
        // A CUE song's share of its album's file, by duration (its FLAC's size is known once converted).
        let cueDurations = Dictionary(grouping: tracks.filter(\.isCueTrack), by: \.url.path).mapValues { $0.reduce(0) { $0 + $1.duration } }
        func cueSize(_ track: Track) -> Int64 {
            guard let total = cueDurations[track.url.path], total > 0 else { return track.fileSize }
            return Int64(Double(track.fileSize) * min(track.duration / total, 1))
        }

        // Where each song was put last time (looked up once per song: a full device holds tens of thousands).
        var previousPaths: [Int64: String] = [:]
        for (path, entry) in manifest.entries where entry.kind == .song {
            if let id = entry.trackId { previousPaths[id] = path }
        }
        // Songs, each in its template path. The planned order is stable so names numbered for collisions stay put.
        var covers: [String: String] = [:]
        // A player device, or one set to a lossy format, gets each song of a CUE album as a file of its own.
        let splitsCue = player != nil || tracks.contains { $0.isCueTrack && format($0) != nil }
        for track in tracks.filter({ !$0.isCueTrack || splitsCue }).sorted(by: { $0.path < $1.path }) {
            guard let id = track.id else { continue }
            if fat32, track.fileSize > fat32Limit {
                plan.skipped.append((track.title, "larger than 4 GB, which FAT32 cards cannot hold"))
                continue
            }
            var delivery = track.isCueTrack ? .flac : player?.delivery(of: track) ?? .asIs
            if case .skip(let reason) = delivery {
                plan.skipped.append((track.title, reason))
                continue
            }
            // The device's lossy format for lossless songs (a player that cannot decode it gets FLAC instead).
            let codec = AudioSpec.Codec(formatName: track.format)
            var encoding: LossyEncoding?
            if let lossy = format(track), LossyEncoding.applies(to: codec) || track.isCueTrack,
               player.map({ $0.decodes.contains(lossy.codec) }) ?? true {
                encoding = lossy
                delivery = .flac
            }
            let converted = delivery == .flac
            let source = track.isCueTrack ? FormatConverter.Source.cueTrack(track, encoding: encoding) : FormatConverter.Source(url: track.url, encoding: encoding)
            let relative = inMusic(FileNaming.relativePath(for: NamingFields(track), fileExtension: converted ? source.fileExtension : track.url.pathExtension,
                                                           options: naming))
            // A song keeps the name it already has on the device (a numbered one too) while its intended name is the same.
            let final: String
            if let previous = previousPaths[id], previous.lowercased() == relative.lowercased() || stripCounter(previous).lowercased() == relative.lowercased(),
               !taken.contains(previous.lowercased()) {
                taken.insert(previous.lowercased())
                final = previous
            } else {
                final = claim(relative)
            }
            // A converted song's size is known once converted: the source's is close enough for planning space.
            // A converted song's fingerprint ends in "|flac" or the lossy format (the server tells the device's codec from it).
            let region = track.isCueTrack ? "|\(track.startTime ?? 0)-\(track.endTime ?? -1)" : ""
            let suffix = converted ? "|" + (encoding?.rawValue ?? "flac") : ""
            // An encoded song's size is about its bitrate times its length.
            let size = encoding.map { Int64($0.kbps * 125) * Int64(track.duration.rounded(.up)) } ?? (track.isCueTrack ? cueSize(track) : track.fileSize)
            add(final, converted ? .converted(source) : .file(track.url), kind: .song, trackId: id,
                fingerprint: songFingerprint(track) + region + suffix, size: size)
            placed[id] = final
            plan.songCount += 1
            let folder = (final as NSString).deletingLastPathComponent
            if covers[folder] == nil, let hash = track.fetchedArtworkHash ?? track.artworkHash { covers[folder] = hash }
            if profile.writesLyrics, let lyrics = track.displayLyrics, SyncedLyricsCheck.isSynced(lyrics) {
                let lrc = (final as NSString).deletingPathExtension + ".lrc"
                if !isForeign(lrc), !taken.contains(lrc.lowercased()) {
                    taken.insert(lrc.lowercased())
                    let data = Data(lyrics.utf8)
                    add(lrc, .data(data), kind: .lyrics, trackId: id, fingerprint: hash(data), size: Int64(data.count))
                }
            }
        }

        // CUE albums (not for a player device: it got their songs above): the audio file and its sheet, under their
        // own names, in the album's folder.
        for (audioPath, songs) in Dictionary(grouping: tracks.filter(\.isCueTrack), by: \.url.path).sorted(by: { $0.key < $1.key }) where !splitsCue {
            let first = songs.min { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }!
            let audio = URL(fileURLWithPath: audioPath)
            let size = (try? audio.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? first.fileSize
            if fat32, size > fat32Limit {
                plan.skipped.append((first.album ?? audio.lastPathComponent, "larger than 4 GB, which FAT32 cards cannot hold"))
                continue
            }
            let relative = inMusic(FileNaming.relativePath(for: NamingFields(first), fileExtension: audio.pathExtension, options: naming))
            let folder = (relative as NSString).deletingLastPathComponent
            let audioTarget = claim(folder.isEmpty ? audio.lastPathComponent : "\(folder)/\(audio.lastPathComponent)")
            add(audioTarget, .file(audio), kind: .song, fingerprint: "\(audio.path)|\(size)", size: size)
            for song in songs { if let id = song.id { placed[id] = audioTarget } }
            plan.songCount += songs.count
            if let sheet = first.cueSheetURL, sheet != audio {
                let sheetSize = (try? sheet.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                let sheetTarget = claim((audioTarget as NSString).deletingLastPathComponent + "/" + sheet.lastPathComponent)
                add(sheetTarget, .file(sheet), kind: .cueSheet, fingerprint: "\(sheet.path)|\(sheetSize)", size: sheetSize)
            }
            if covers[folder] == nil, let hash = first.fetchedArtworkHash ?? first.artworkHash { covers[folder] = hash }
        }

        if profile.writesCovers {
            for (folder, hash) in covers.sorted(by: { $0.key < $1.key }) {
                let path = folder.isEmpty ? "cover.jpg" : "\(folder)/cover.jpg"
                // A cover.jpg that came from elsewhere is left alone.
                guard !isForeign(path), !taken.contains(path.lowercased()) else { continue }
                taken.insert(path.lowercased())
                add(path, .cover(hash: hash), kind: .cover, fingerprint: "\(hash)|\(profile.coverSize)", size: 150_000)
            }
        }

        if profile.writesPlaylists {
            let playlistFolder = clean(profile.playlistFolder)
            for playlist in playlists {
                let name = FileNaming.sanitize(playlist.name, options: naming)
                let path = claim((playlistFolder.isEmpty ? "" : playlistFolder + "/") + (name.isEmpty ? "Playlist" : name) + ".m3u8")
                // The songs at their device paths, so the file's paths are relative to the playlist's own folder.
                let onDevice = playlist.tracks.compactMap { track -> Track? in
                    guard let id = track.id, let target = placed[id] else { return nil }
                    var copy = track
                    copy.path = root.appendingPathComponent(target).path
                    copy.audioPath = track.isCueTrack ? copy.path : nil
                    return copy
                }
                let folderURL = root.appendingPathComponent(path).deletingLastPathComponent()
                let data = PlaylistFile.write(name: playlist.name, tracks: onDevice, format: .m3u8, paths: .relative(to: folderURL))
                add(path, .data(data), kind: .playlist, fingerprint: hash(data), size: Int64(data.count))
            }
        }

        // Against what is there: new or changed files are written, current ones kept.
        for (path, (content, entry)) in desired.sorted(by: { $0.key < $1.key }) {
            if let old = manifest.entries[path], old.fingerprint == entry.fingerprint, existing(path) {
                var kept = old
                // A song sent once becomes part of the sync when the selection includes it.
                if mode == .sync { kept.synced = true }
                plan.unchanged[path] = kept
            } else {
                var entry = entry
                if mode == .send, let old = manifest.entries[path] { entry.synced = old.synced }
                plan.writes.append(DeviceSyncPlan.Write(path: path, content: content, entry: entry))
            }
        }
        // Groovelight's files no longer wanted: in a sync, the ones it synced; in any plan, songs removed from the
        // device (and their lyrics), even sent ones.
        for (path, entry) in manifest.entries where desired[path] == nil &&
            ((mode == .sync && entry.synced) || entry.trackId.map(excluded.contains) == true) {
            plan.deletions.append(path)
            plan.bytesToFree += entry.size
        }
        plan.deletions.sort()
        return plan
    }

    /// A sync of the selection and, in the same plan, songs sent to the device since (a wireless device only takes them
    /// when it next connects). Sent songs are added without making them part of the sync.
    public static func plan(syncing: (tracks: [Track], playlists: [DevicePlaylist]), sending: (tracks: [Track], playlists: [DevicePlaylist]),
                            profile: DeviceProfile, manifest: DeviceManifest, root: URL, fat32: Bool = false, player: Player? = nil,
                            excluded: Set<Int64> = [], formats: Formats? = nil,
                            existing: (String) -> Bool) -> DeviceSyncPlan {
        var plan = plan(tracks: syncing.tracks, playlists: syncing.playlists, profile: profile, manifest: manifest, mode: .sync,
                        root: root, fat32: fat32, player: player, excluded: excluded, formats: formats, existing: existing)
        let sending = (tracks: sending.tracks.filter { !excluded.contains($0.id ?? -1) }, playlists: sending.playlists)
        guard !sending.tracks.isEmpty || !sending.playlists.isEmpty else { return plan }
        // The device as the sync leaves it (files it would remove are still there), then the sends on top.
        var after = manifest
        for (path, entry) in plan.unchanged { after.entries[path] = entry }
        for write in plan.writes { after.entries[write.path] = write.entry }
        let written = Set(plan.writes.map(\.path))
        let sends = self.plan(tracks: sending.tracks, playlists: sending.playlists, profile: profile, manifest: after, mode: .send,
                              root: root, fat32: fat32, player: player, formats: formats) { path in written.contains(path) || existing(path) }
        plan.writes += sends.writes.filter { !written.contains($0.path) }
        // A sent song the sync was about to remove stays, as a sent file from now on (later syncs keep it).
        let removed = Set(plan.deletions)
        let kept = Set(sends.writes.map(\.path)).union(sends.unchanged.keys)
        plan.deletions.removeAll { kept.contains($0) }
        plan.bytesToFree = plan.deletions.reduce(0) { $0 + (manifest.entries[$1]?.size ?? 0) }
        for (path, var entry) in sends.unchanged where plan.unchanged[path] == nil && !written.contains(path) {
            if removed.contains(path) { entry.synced = false }
            plan.unchanged[path] = entry
        }
        plan.skipped += sends.skipped
        plan.songCount += sends.writes.filter { $0.entry.kind == .song }.count
        return plan
    }

    /// Carries out a plan: removals first (to make room), then the files, each copied under a temporary name and then
    /// renamed so a pulled card never holds half a song under its real name. The manifest is saved as it goes, so an
    /// interrupted sync resumes where it stopped. Returns the updated manifest.
    @discardableResult
    public static func run(_ plan: DeviceSyncPlan, root: URL, profile: DeviceProfile, manifest: DeviceManifest,
                           cover: (String, Int) -> Data?, progress: (Int, Int) -> Void = { _, _ in },
                           isCancelled: () -> Bool = { false }) throws -> DeviceManifest {
        var manifest = manifest
        manifest.profile = profile
        let fileManager = FileManager.default
        var emptied = Set<String>()
        for path in plan.deletions {
            try? fileManager.removeItem(at: root.appendingPathComponent(path))
            manifest.entries[path] = nil
            emptied.insert((path as NSString).deletingLastPathComponent)
        }
        for (path, entry) in plan.unchanged { manifest.entries[path] = entry }
        try manifest.write(to: root)

        for (index, write) in plan.writes.enumerated() {
            if isCancelled() { break }
            progress(index, plan.writes.count)
            let target = root.appendingPathComponent(write.path)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let partial = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).partial")
            try? fileManager.removeItem(at: partial)
            var entry = write.entry
            switch write.content {
            case .file(let source):
                try fileManager.copyItem(at: source, to: partial)
            case .data(let data):
                try data.write(to: partial)
            case .converted(let source):
                try FormatConverter.convert(source, to: partial)
                entry.size = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? entry.size
            case .cover(let hash):
                guard let data = cover(hash, profile.coverSize) else { continue }
                try data.write(to: partial)
                entry.size = Int64(data.count)
            }
            if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
            try fileManager.moveItem(at: partial, to: target)
            manifest.entries[write.path] = entry
            emptied.remove(target.deletingLastPathComponent().path)
            // Saved every so often: a pulled card loses at most a few songs of progress.
            if index % 25 == 24 { try? manifest.write(to: root) }
        }
        progress(plan.writes.count, plan.writes.count)
        manifest.lastSync = .now
        try manifest.write(to: root)
        removeEmptyFolders(emptied, root: root)
        return manifest
    }

    /// Folders left empty by removals, up to (not including) the root. Only folders holding nothing at all, or just
    /// the Finder's .DS_Store, are removed.
    static func removeEmptyFolders(_ folders: Set<String>, root: URL) {
        let fileManager = FileManager.default
        for folder in folders.sorted(by: { $0.count > $1.count }) {
            var current = folder
            while !current.isEmpty, current != "." {
                let url = root.appendingPathComponent(current)
                let contents = (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? ["?"]
                guard contents.allSatisfy({ $0 == ".DS_Store" }) else { break }
                try? fileManager.removeItem(at: url)
                current = (current as NSString).deletingLastPathComponent
            }
        }
    }

    /// "Music/A/01 x (2).flac" -> "Music/A/01 x.flac".
    static func stripCounter(_ path: String) -> String {
        guard path.contains(" (") else { return path }
        return counterPattern.stringByReplacingMatches(in: path, range: NSRange(path.startIndex..., in: path), withTemplate: "$1")
    }

    private static let counterPattern = try! NSRegularExpression(pattern: #" \(\d+\)(\.[^./]+)?$"#)

    /// A folder setting as a clean relative path ("/Music/" -> "Music").
    static func clean(_ folder: String) -> String {
        folder.split(separator: "/").map { FileNaming.cleanComponent(String($0), options: OrganizeOptions()) }
            .filter { !$0.isEmpty && $0 != ".." }.joined(separator: "/")
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// Whether lyrics carry LRC timestamps ("[01:23.45]").
enum SyncedLyricsCheck {
    static func isSynced(_ text: String) -> Bool {
        text.range(of: #"\[\d{1,2}:\d{2}([.:]\d{1,3})?\]"#, options: .regularExpression) != nil
    }
}

extension ArtworkCache {
    /// The image as JPEG with its longest side at most `maxPixels` (0: the original size), for cover.jpg files and
    /// devices. From the original, or its stored thumbnails when the original is missing or unreadable. Always 8-bit
    /// RGB: CMYK, 16-bit or wide-gamut covers (scans, some releases) do not decode on Android and some players.
    public func jpeg(for hash: String, maxPixels: Int) -> Data? {
        for candidate in [url(for: hash, size: nil), url(for: hash, size: .large), url(for: hash, size: .small)] {
            if let data = Self.jpeg(from: candidate, maxPixels: maxPixels) { return data }
        }
        return nil
    }

    static func jpeg(from url: URL, maxPixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        var options: [CFString: Any] = [kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceCreateThumbnailFromImageAlways: true]
        if maxPixels > 0 { options[kCGImageSourceThumbnailMaxPixelSize] = maxPixels }
        if maxPixels == 0, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            options[kCGImageSourceThumbnailMaxPixelSize] = max(properties[kCGImagePropertyPixelWidth] as? Int ?? 3000,
                                                               properties[kCGImagePropertyPixelHeight] as? Int ?? 3000)
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary), image.width > 0, image.height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // Over white, for covers with transparency (JPEG has none).
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let rgb = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, rgb, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
