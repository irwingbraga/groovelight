import Foundation
import GRDB

public struct ScanProgress: Sendable {
    public var filesFound: Int
    public var filesProcessed: Int
    public var currentPath: String?

    public init(filesFound: Int, filesProcessed: Int, currentPath: String? = nil) {
        self.filesFound = filesFound
        self.filesProcessed = filesProcessed
        self.currentPath = currentPath
    }
}

public struct ScanSummary: Sendable, Equatable {
    public var added = 0
    public var updated = 0
    public var removed = 0
    public var unchanged = 0
    public var failed: [String] = []

    public init() {}
}

/// Walks a library root, reads tags of new or changed files and keeps the `track` table in sync.
public actor LibraryScanner {
    private let database: LibraryDatabase
    private let artwork: ArtworkCache
    private let parallelism: Int

    public init(database: LibraryDatabase, artwork: ArtworkCache, parallelism: Int = 8) {
        self.database = database
        self.artwork = artwork
        self.parallelism = parallelism
    }

    private struct FileInfo: Sendable {
        var url: URL
        var size: Int64
        var modifiedAt: Date
    }

    private struct Existing: Sendable {
        var id: Int64
        var size: Int64
        var modifiedAt: Date
        var dateAdded: Date
        var stats: (rating: Int, loved: Bool, plays: Int, skips: Int, lastPlayed: Date?)
        /// Online data and fixes that live only in the database, kept across rescans.
        var overrides: Data?
        var fetchedLyrics: String?
        var lyricsCheckedAt: Date?
        var fetchedArtworkHash: String?
        var lovedAt: Date?
    }

    /// Tail of the scans queued so far: scans run one at a time.
    private var lastScan: Task<Void, Never>?

    /// Scans `root`, all of it or only some of its folders. Calls are serialized: two overlapping scans (a folder
    /// change during a manual rescan, adding a folder at launch) would otherwise both insert the same new files and hit
    /// the unique path constraint.
    public func scan(root: LibraryRoot, scope: ScanScope = .full,
                     progress: (@Sendable (ScanProgress) -> Void)? = nil) async throws -> ScanSummary {
        let previous = lastScan
        let task = Task {
            await previous?.value
            return try await self.performScan(root: root, scope: scope, progress: progress)
        }
        lastScan = Task { _ = await task.result }
        return try await task.value
    }

    public enum ScanError: LocalizedError, Equatable {
        /// The folder is missing or unreadable (an unplugged drive, or a restored library not located yet).
        case folderUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .folderUnavailable(let path): "The folder \(path) is not available."
            }
        }
    }

    private func performScan(root: LibraryRoot, scope: ScanScope, progress: (@Sendable (ScanProgress) -> Void)?) async throws -> ScanSummary {
        guard let rootId = root.id else { return ScanSummary() }
        let rootURL = URL(fileURLWithPath: root.path, isDirectory: true)
        // A missing folder would look like every file was deleted, and removing its songs would lose their history.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: rootURL.path) else {
            throw ScanError.folderUnavailable(root.path)
        }
        // The folders to look at, and the songs the library has there.
        var allAudio: [FileInfo] = []
        var cueFiles: [FileInfo] = []
        var area = "rootId = ?"
        var arguments: StatementArguments = [rootId]
        var refreshArtwork = Set<String>()
        switch scope {
        case .full:
            (allAudio, cueFiles) = Self.enumerateFiles(in: rootURL)
        case .folders(let folders, let artworkFolders):
            refreshArtwork = artworkFolders
            for folder in folders.sorted() {
                let found = Self.enumerateFiles(in: URL(fileURLWithPath: folder, isDirectory: true))
                allAudio += found.audio
                cueFiles += found.cues
            }
            // Paths under each folder: from "folder/" up to (not including) "folder0", '0' being the character after '/'.
            area += " AND (" + folders.map { _ in "(path >= ? AND path < ?)" }.joined(separator: " OR ") + ")"
            for folder in folders.sorted() { arguments += [folder + "/", folder + "0"] }
        }
        progress?(ScanProgress(filesFound: allAudio.count, filesProcessed: 0))

        let existing: [String: Existing] = try await database.writer.read { [area, arguments] db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, path, fileSize, modifiedAt, dateAdded, rating, isLoved, playCount, skipCount, lastPlayedAt,
                       metadataOverrides, fetchedLyrics, lyricsCheckedAt, fetchedArtworkHash, lovedAt
                FROM track WHERE \(area)
                """, arguments: arguments)
            var map: [String: Existing] = [:]
            for row in rows {
                map[row["path"]] = Existing(id: row["id"], size: row["fileSize"], modifiedAt: row["modifiedAt"], dateAdded: row["dateAdded"],
                                            stats: (row["rating"], row["isLoved"], row["playCount"], row["skipCount"], row["lastPlayedAt"]),
                                            overrides: row["metadataOverrides"], fetchedLyrics: row["fetchedLyrics"],
                                            lyricsCheckedAt: row["lyricsCheckedAt"], fetchedArtworkHash: row["fetchedArtworkHash"],
                                            lovedAt: row["lovedAt"])
            }
            return map
        }
        // CUE tracks are stored as "<sheet>#NN": group them by sheet.
        var virtualByBase: [String: [String]] = [:]
        for path in existing.keys {
            if let hash = path.lastIndex(of: "#") { virtualByBase[String(path[..<hash]), default: []].append(path) }
        }

        // External cue sheets: a FILE with two or more tracks turns that audio file into one song per track.
        let audioByPath = Dictionary(allAudio.map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first })
        let audioPaths = Set(audioByPath.keys)
        var cueGroups: [CueGroup] = []
        var covered = Set<String>()
        for cue in cueFiles {
            guard let sheet = CueSheet.read(cue.url) else { continue }
            for file in sheet.files where file.tracks.count >= 2 {
                guard let audioURL = CueSheet.resolve(file.name, relativeTo: cue.url.deletingLastPathComponent(), audioFiles: audioPaths),
                      !covered.contains(audioURL.path), let audio = audioByPath[audioURL.path] else { continue }
                covered.insert(audioURL.path)
                cueGroups.append(CueGroup(base: cue.url.path, audio: audio, sheet: sheet, tracks: file.tracks,
                                          modifiedAt: max(cue.modifiedAt, audio.modifiedAt)))
            }
        }
        let files = allAudio.filter { !covered.contains($0.url.path) }

        var summary = ScanSummary()
        var seenPaths = Set<String>()
        var changed: [FileInfo] = []
        // Songs beside a new or changed cover image are read again for it.
        func coverChanged(_ url: URL) -> Bool { refreshArtwork.contains(url.deletingLastPathComponent().path) }
        for file in files {
            seenPaths.insert(file.url.path)
            if coverChanged(file.url) {
                changed.append(file)
            } else if let old = existing[file.url.path], old.size == file.size, abs(old.modifiedAt.timeIntervalSince(file.modifiedAt)) < 1 {
                summary.unchanged += 1
            } else if let virtual = virtualByBase[file.url.path], virtual.allSatisfy({ abs(existing[$0]!.modifiedAt.timeIntervalSince(file.modifiedAt)) < 1 }) {
                // A file with an embedded cue sheet, unchanged: keep its tracks.
                seenPaths.formUnion(virtual)
                summary.unchanged += virtual.count
            } else {
                changed.append(file)
            }
        }
        var changedCues: [CueGroup] = []
        for group in cueGroups {
            if !coverChanged(group.audio.url), let virtual = virtualByBase[group.base], virtual.count == group.tracks.count,
               virtual.allSatisfy({ abs(existing[$0]!.modifiedAt.timeIntervalSince(group.modifiedAt)) < 1 }) {
                seenPaths.formUnion(virtual)
                summary.unchanged += virtual.count
            } else {
                changedCues.append(group)
            }
        }

        // Moved or renamed folders, or a library relocated to another path: a new file and a missing song with the
        // same file name and size are the same song, which keeps its id and history (plays, loves, playlists, fixes).
        var missingByIdentity: [String: [Existing]] = [:]
        for (path, old) in existing where !seenPaths.contains(path) && !path.contains("#") {
            missingByIdentity[Self.identity(name: URL(fileURLWithPath: path).lastPathComponent, size: old.size), default: []].append(old)
        }
        var moved: [String: Existing] = [:]
        for file in changed where existing[file.url.path] == nil {
            let key = Self.identity(name: file.url.lastPathComponent, size: file.size)
            // Only unambiguous pairs: one missing song and one new file with that identity.
            guard let candidates = missingByIdentity[key], candidates.count == 1,
                  changed.filter({ existing[$0.url.path] == nil && Self.identity(name: $0.url.lastPathComponent, size: $0.size) == key }).count == 1
            else { continue }
            moved[file.url.path] = candidates[0]
            missingByIdentity[key] = nil
        }
        let movedIds = Set(moved.values.map(\.id))

        // Read tags in parallel, write in batches.
        var processed = summary.unchanged
        var batch: [Track] = []
        var folderArtwork: [URL: String?] = [:]
        let artwork = self.artwork
        // Files with an embedded cue sheet, handled after the parallel read (with the albums of external sheets).
        var cueAlbums: [(group: CueGroup, tags: FileTags)] = []

        try await withThrowingTaskGroup(of: (FileInfo, Result<FileTags, Error>).self) { group in
            var iterator = changed.makeIterator()
            func addNext() -> Bool {
                guard let file = iterator.next() else { return false }
                group.addTask {
                    (file, Result { try TagReader.read(file.url) })
                }
                return true
            }
            for _ in 0..<parallelism where !addNext() { break }

            while let (file, result) = try await group.next() {
                _ = addNext()
                processed += 1
                switch result {
                case .failure:
                    summary.failed.append(file.url.path)
                case .success(let tags):
                    // A cue sheet inside the file: one song per track, like an external sheet.
                    if let text = tags.cueSheet, let sheet = CueSheet.parse(text), let first = sheet.files.first, first.tracks.count >= 2 {
                        seenPaths.remove(file.url.path)
                        cueAlbums.append((CueGroup(base: file.url.path, audio: file, sheet: sheet, tracks: first.tracks, modifiedAt: file.modifiedAt),
                                          tags))
                    } else {
                        var tags = tags
                        let hash = Self.artworkHash(for: tags, file: file.url, artwork: artwork, folderCache: &folderArtwork)
                        tags.artwork = nil
                        let old = existing[file.url.path] ?? moved[file.url.path]
                        if old == nil { summary.added += 1 } else { summary.updated += 1 }
                        batch.append(Self.makeTrack(rootId: rootId, file: file, tags: tags, artworkHash: hash, existing: old))
                    }
                }
                if batch.count >= 200 {
                    try await save(batch)
                    batch.removeAll(keepingCapacity: true)
                }
                if processed % 25 == 0 {
                    progress?(ScanProgress(filesFound: allAudio.count, filesProcessed: processed, currentPath: file.url.path))
                }
            }
        }
        // Albums described by external cue sheets.
        for group in changedCues {
            do {
                cueAlbums.append((group, try TagReader.read(group.audio.url)))
            } catch {
                summary.failed.append(group.audio.url.path)
            }
        }
        for (group, tags) in cueAlbums {
            let tracks = Self.makeCueTracks(rootId: rootId, group: group, tags: tags, artworkHash: Self.artworkHash(for: tags, file: group.audio.url, artwork: artwork, folderCache: &folderArtwork),
                                            existing: existing)
            for track in tracks {
                seenPaths.insert(track.path)
                if existing[track.path] == nil { summary.added += 1 } else { summary.updated += 1 }
            }
            batch += tracks
        }
        try await save(batch)

        // Remove tracks whose files (or cue tracks) disappeared.
        let missing = existing.filter { !seenPaths.contains($0.key) && !movedIds.contains($0.value.id) }.map(\.value.id)
        if !missing.isEmpty {
            summary.removed = missing.count
            _ = try await database.writer.write { db in try Track.deleteAll(db, keys: missing) }
        }
        let isFull = scope == .full
        try await database.writer.write { db in
            if isFull {
                try db.execute(sql: "UPDATE libraryRoot SET lastScanAt = ?, lastFullScanAt = ? WHERE id = ?", arguments: [Date.now, Date.now, rootId])
            } else {
                try db.execute(sql: "UPDATE libraryRoot SET lastScanAt = ? WHERE id = ?", arguments: [Date.now, rootId])
            }
        }
        progress?(ScanProgress(filesFound: allAudio.count, filesProcessed: allAudio.count))
        return summary
    }

    /// The file's embedded cover, else a cover image in its folder (looked up once per folder).
    private static func artworkHash(for tags: FileTags, file: URL, artwork: ArtworkCache, folderCache: inout [URL: String?]) -> String? {
        if let data = tags.artwork, let hash = artwork.store(data) { return hash }
        let directory = file.deletingLastPathComponent()
        if let cached = folderCache[directory] { return cached }
        let hash = ArtworkCache.folderImage(in: directory).flatMap { try? Data(contentsOf: $0) }.flatMap { artwork.store($0) }
        folderCache[directory] = hash
        return hash
    }

    /// An album stored as one audio file, described by a cue sheet (external, or embedded in the file).
    private struct CueGroup {
        /// Tracks are stored as "<base>#NN": the sheet's path, or the audio file's for an embedded sheet.
        var base: String
        var audio: FileInfo
        var sheet: CueSheet
        var tracks: [CueSheet.Track]
        var modifiedAt: Date
    }

    /// One song per cue track, pointing at the shared audio file with its start and end.
    private static func makeCueTracks(rootId: Int64, group: CueGroup, tags: FileTags, artworkHash: String?,
                                      existing: [String: Existing]) -> [Track] {
        let sheet = group.sheet
        let total = tags.duration
        return group.tracks.enumerated().map { index, cue in
            let next = index + 1 < group.tracks.count ? group.tracks[index + 1].start : nil
            let duration = max(0, (next ?? total) - cue.start)
            let path = group.base + "#" + String(format: "%02d", cue.number)
            let old = existing[path]
            let albumArtist = sheet.performer ?? tags.albumArtist.nonEmpty
            let artist = cue.performer ?? sheet.performer ?? tags.artist.nonEmpty
            let album = sheet.title ?? tags.album.nonEmpty
            var track = Track(
                id: old?.id, rootId: rootId, path: path,
                // The file's size shared out by length (for size limits of smart playlists).
                fileSize: total > 0 ? Int64(Double(group.audio.size) * duration / total) : group.audio.size,
                modifiedAt: group.modifiedAt,
                title: cue.title ?? "Track \(cue.number)", artist: artist, album: album, albumArtist: albumArtist,
                composer: cue.songwriter ?? sheet.songwriter, genre: sheet.genre ?? tags.genre.nonEmpty, year: sheet.year ?? tags.year,
                trackNumber: cue.number, trackTotal: group.sheet.tracks.count, discNumber: sheet.discNumber ?? tags.discNumber,
                discTotal: sheet.discTotal ?? tags.discTotal, isCompilation: tags.isCompilation, bpm: nil, comment: sheet.comment,
                lyrics: nil, musicBrainzRecordingId: nil, musicBrainzReleaseId: tags.musicBrainzReleaseId,
                replayGainTrackGain: nil, replayGainAlbumGain: tags.replayGainAlbumGain,
                duration: duration, format: tags.format, sampleRate: tags.sampleRate, bitDepth: tags.bitDepth,
                bitrate: tags.bitrate, channels: tags.channels, artworkHash: artworkHash,
                albumKey: Track.makeAlbumKey(album: album, albumArtist: albumArtist, artist: artist, isCompilation: tags.isCompilation),
                rating: old?.stats.rating ?? 0, isLoved: old?.stats.loved ?? false,
                playCount: old?.stats.plays ?? 0, skipCount: old?.stats.skips ?? 0,
                lastPlayedAt: old?.stats.lastPlayed, dateAdded: old?.dateAdded ?? .now
            )
            track.audioPath = group.audio.url.path
            track.startTime = cue.start
            track.endTime = next
            if let old { applyExisting(old, to: &track) }
            return track
        }
    }

    private func save(_ tracks: [Track]) async throws {
        guard !tracks.isEmpty else { return }
        try await database.writer.write { db in
            for var track in tracks {
                if track.id != nil {
                    try track.update(db)
                } else {
                    try track.insert(db)
                }
            }
        }
    }

    /// Audio files and cue sheets under a folder.
    private static func enumerateFiles(in root: URL) -> (audio: [FileInfo], cues: [FileInfo]) {
        let extensions = TagReader.supportedExtensions
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ([], []) }
        var audio: [FileInfo] = []
        var cues: [FileInfo] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard ext == "cue" || extensions.contains(ext),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let info = FileInfo(url: url.standardizedFileURL, size: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate ?? .distantPast)
            if ext == "cue" { cues.append(info) } else { audio.append(info) }
        }
        return (audio, cues)
    }

    /// File identity for move detection: name (case and Unicode normalization insensitive) and size.
    static func identity(name: String, size: Int64) -> String {
        "\(name.precomposedStringWithCanonicalMapping.lowercased())\u{1F}\(size)"
    }

    /// Keeps what lives only in the library across rescans: fixes, fetched lyrics, the chosen online cover, love date.
    private static func applyExisting(_ existing: Existing, to track: inout Track) {
        track.metadataOverrides = existing.overrides
        if let overrides = track.overrides { track.apply(overrides) }
        track.fetchedLyrics = existing.fetchedLyrics
        track.lyricsCheckedAt = existing.lyricsCheckedAt
        track.fetchedArtworkHash = existing.fetchedArtworkHash
        track.lovedAt = existing.lovedAt
        // A cover chosen online wins over the file's: the user picked it in the review sheet.
        if let fetched = existing.fetchedArtworkHash { track.artworkHash = fetched }
    }

    private static func makeTrack(rootId: Int64, file: FileInfo, tags: FileTags, artworkHash: String?, existing: Existing?) -> Track {
        let title = tags.title.nonEmpty ?? file.url.deletingPathExtension().lastPathComponent
        var track = Track(
            id: existing?.id, rootId: rootId, path: file.url.path, fileSize: file.size, modifiedAt: file.modifiedAt,
            title: title, artist: tags.artist.nonEmpty, album: tags.album.nonEmpty, albumArtist: tags.albumArtist.nonEmpty,
            composer: tags.composer.nonEmpty, genre: tags.genre.nonEmpty, year: tags.year,
            trackNumber: tags.trackNumber, trackTotal: tags.trackTotal, discNumber: tags.discNumber, discTotal: tags.discTotal,
            isCompilation: tags.isCompilation, bpm: tags.bpm, comment: tags.comment, lyrics: tags.lyrics,
            musicBrainzRecordingId: tags.musicBrainzRecordingId, musicBrainzReleaseId: tags.musicBrainzReleaseId,
            replayGainTrackGain: tags.replayGainTrackGain, replayGainAlbumGain: tags.replayGainAlbumGain,
            duration: tags.duration, format: tags.format, sampleRate: tags.sampleRate, bitDepth: tags.bitDepth,
            bitrate: tags.bitrate, channels: tags.channels, artworkHash: artworkHash,
            albumKey: Track.makeAlbumKey(album: tags.album, albumArtist: tags.albumArtist, artist: tags.artist, isCompilation: tags.isCompilation),
            rating: existing?.stats.rating ?? 0, isLoved: existing?.stats.loved ?? false,
            playCount: existing?.stats.plays ?? 0, skipCount: existing?.stats.skips ?? 0,
            lastPlayedAt: existing?.stats.lastPlayed, dateAdded: existing?.dateAdded ?? .now
        )
        if let existing { applyExisting(existing, to: &track) }
        return track
    }
}
