import Foundation
import GRDB

/// Backups of everything Groovelight keeps outside the music files: the library database (play counts, ratings, loves,
/// playlists and covers, smart rules, metadata fixes, fetched lyrics, credits and backgrounds, library folders), the
/// artwork folder and the app's preferences.
///
/// A backup is a package (a folder that Finder shows as one file):
/// `Library.sqlite`, `Artwork/`, `Preferences.plist` and `Manifest.json`. Backups on a NAS keep their covers in an
/// `Artwork` folder beside them instead, shared by all of them (`Manifest.artworkFiles`).
public enum LibraryBackup {
    public static let fileExtension = "groovelightbackup"

    public struct Manifest: Codable, Hashable, Sendable {
        public var formatVersion: Int
        public var appVersion: String
        public var createdAt: Date
        public var computerName: String?
        public var trackCount: Int
        public var playlistCount: Int
        public var lovedCount: Int
        public var playCount: Int
        public var artworkCount: Int
        /// Library folders at backup time; they must be located again after restoring on another Mac.
        public var folders: [String]
        /// For a backup whose covers are in the folder shared by the backups beside it (on a NAS): the covers it uses.
        /// Nil when they are in the package (older readers ignore it).
        public var artworkFiles: [String]?
    }

    public enum BackupError: LocalizedError {
        case notABackup
        case newerFormat(Int)

        public var errorDescription: String? {
            switch self {
            case .notABackup: "This is not a Groovelight backup."
            case .newerFormat(let version): "This backup was made by a newer version of Groovelight (format \(version))."
            }
        }
    }

    static let formatVersion = 1

    /// Writes a backup package at `url` (replacing it). The database copy is a consistent snapshot, taken with SQLite's
    /// backup API while the library stays open. `preferences` is property list data (a dictionary), kept as data so it
    /// can cross concurrency boundaries.
    ///
    /// With `sharedArtwork` (a folder beside the backups, on a NAS), the covers go there instead of in the package:
    /// only the originals (thumbnails are made again on restore), and only those not there yet, since their names are
    /// their contents' hash. Each file on a NAS costs a fraction of a second, so this turns minutes into seconds. The
    /// manifest lists the covers the backup uses. `progress` gets the files written so far and their total.
    @discardableResult
    public static func write(database: LibraryDatabase, artworkDirectory: URL, preferences: Data, appVersion: String,
                             to url: URL, sharedArtwork: URL? = nil,
                             progress: ((_ done: Int, _ total: Int) -> Void)? = nil) throws -> Manifest {
        let fileManager = FileManager.default
        // Build in the temporary folder, then move into place, so a failed backup never leaves a half-written package
        // (and a sandboxed app may only write the chosen file itself, not next to it).
        let staging = fileManager.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let snapshot = try DatabaseQueue(path: staging.appendingPathComponent("Library.sqlite").path)
        try database.writer.backup(to: snapshot)
        // The copy inherits the library's WAL mode, which needs side files to be read: make it a single,
        // self-contained file.
        try snapshot.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode = DELETE") }
        try snapshot.close()
        try preferences.write(to: staging.appendingPathComponent("Preferences.plist"))

        let covers = ((try? fileManager.contentsOfDirectory(atPath: artworkDirectory.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        // What goes where: the package's own files, then the covers (in the package, or the missing ones in the shared
        // folder, through a temporary name), then the manifest last.
        var copies: [(from: URL, to: URL, through: URL?)] = ["Library.sqlite", "Preferences.plist"].map {
            (staging.appendingPathComponent($0), url.appendingPathComponent($0), nil)
        }
        let artworkFiles: [String]?
        if let sharedArtwork {
            try fileManager.createDirectory(at: sharedArtwork, withIntermediateDirectories: true)
            let there = Set((try? fileManager.contentsOfDirectory(atPath: sharedArtwork.path)) ?? [])
            let originals = covers.filter { $0.hasSuffix(ArtworkCache.originalSuffix) }
            artworkFiles = originals
            for name in originals where !there.contains(name) {
                copies.append((artworkDirectory.appendingPathComponent(name), sharedArtwork.appendingPathComponent(name),
                               sharedArtwork.appendingPathComponent(".\(name).partial")))
            }
        } else {
            artworkFiles = nil
            for name in covers {
                copies.append((artworkDirectory.appendingPathComponent(name), url.appendingPathComponent("Artwork").appendingPathComponent(name), nil))
            }
        }

        let manifest = try database.writer.read { db in
            Manifest(formatVersion: formatVersion, appVersion: appVersion, createdAt: .now, computerName: Self.computerName,
                     trackCount: try Track.fetchCount(db), playlistCount: try Playlist.fetchCount(db),
                     lovedCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE isLoved") ?? 0,
                     playCount: try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(playCount), 0) FROM track") ?? 0,
                     artworkCount: artworkFiles?.count ?? covers.count, folders: try LibraryDatabase.roots(db).map(\.path),
                     artworkFiles: artworkFiles)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("Manifest.json"))
        copies.append((staging.appendingPathComponent("Manifest.json"), url.appendingPathComponent("Manifest.json"), nil))

        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            if artworkFiles == nil { try fileManager.createDirectory(at: url.appendingPathComponent("Artwork"), withIntermediateDirectories: true) }
            progress?(0, copies.count)
            for (index, copy) in copies.enumerated() {
                try Task.checkCancellation()
                if let through = copy.through {
                    try? fileManager.removeItem(at: through)
                    try fileManager.copyItem(at: copy.from, to: through)
                    if fileManager.fileExists(atPath: copy.to.path) { try? fileManager.removeItem(at: through) } else { try fileManager.moveItem(at: through, to: copy.to) }
                } else {
                    try fileManager.copyItem(at: copy.from, to: copy.to)
                }
                progress?(index + 1, copies.count)
            }
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
        return manifest
    }

    /// The folder of covers shared by the backups in `folder` (on a NAS).
    public static func sharedArtwork(in folder: URL) -> URL {
        folder.appendingPathComponent("Artwork", isDirectory: true)
    }

    /// Removes the shared covers that none of `backups` uses (and copies left half-written). Does nothing when one
    /// of them cannot be read, so a cover is never removed while a backup might still need it.
    public static func pruneSharedArtwork(_ folder: URL, keepingFor backups: [URL]) {
        var used = Set<String>()
        for backup in backups {
            guard let manifest = try? manifest(of: backup) else { return }
            used.formUnion(manifest.artworkFiles ?? [])
        }
        let fileManager = FileManager.default
        for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] where !used.contains(name) {
            try? fileManager.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Where a backup's covers are: its own `Artwork` folder, or the shared one beside it.
    public static func artworkFolder(of url: URL, manifest: Manifest) -> URL {
        manifest.artworkFiles == nil ? url.appendingPathComponent("Artwork") : sharedArtwork(in: url.deletingLastPathComponent())
    }

    public static func manifest(of url: URL) throws -> Manifest {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Manifest.json")),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("Library.sqlite").path) else { throw BackupError.notABackup }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Manifest.self, from: data)
        if manifest.formatVersion > formatVersion { throw BackupError.newerFormat(manifest.formatVersion) }
        return manifest
    }

    /// Replaces the library with the backup's (in place, while it stays open; observers see the new data), brings the
    /// schema up to date, and adds the backup's artwork. Returns the backup's preferences (property list data) for the
    /// app to apply.
    ///
    /// `artworkFrom` is where the covers are when not in the default place (the shared folder chosen by the user).
    /// Covers without thumbnails (from a shared folder, which keeps only originals) get them made again.
    public static func restore(from url: URL, into database: LibraryDatabase, artworkDirectory: URL, artworkFrom: URL? = nil) throws -> Data? {
        let manifest = try manifest(of: url)
        // Read from a temporary copy: the backup itself is never modified, and SQLite may need to write side files.
        let fileManager = FileManager.default
        let temporary = fileManager.temporaryDirectory.appendingPathComponent("restore-\(UUID().uuidString).sqlite")
        try fileManager.copyItem(at: url.appendingPathComponent("Library.sqlite"), to: temporary)
        defer { try? fileManager.removeItem(at: temporary) }
        let source = try DatabaseQueue(path: temporary.path)
        try source.backup(to: database.writer)
        try source.close()
        // Backups from older versions get the newer tables and columns.
        try LibraryDatabase.migrator.migrate(database.writer)

        try fileManager.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        let folder = artworkFrom ?? artworkFolder(of: url, manifest: manifest)
        let names = manifest.artworkFiles ?? ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [])
        let cache = try ArtworkCache(directory: artworkDirectory)
        for name in names where !name.hasPrefix(".") {
            let destination = artworkDirectory.appendingPathComponent(name)
            // Content-addressed names: an existing file is the same image.
            if !fileManager.fileExists(atPath: destination.path) {
                try? fileManager.copyItem(at: folder.appendingPathComponent(name), to: destination)
            }
            if name.hasSuffix(ArtworkCache.originalSuffix) {
                cache.makeThumbnails(String(name.dropLast(ArtworkCache.originalSuffix.count)))
            }
        }

        return try? Data(contentsOf: url.appendingPathComponent("Preferences.plist"))
    }
}

extension LibraryDatabase {
    /// Points a library folder (and all its songs) at a new location, e.g. after restoring on another Mac, keeping
    /// every song's history. Returns the number of songs moved.
    @discardableResult
    public func relocateRoot(_ rootId: Int64, to newPath: String, bookmark: Data) throws -> Int {
        try writer.write { db in
            guard let root = try LibraryRoot.fetchOne(db, key: rootId) else { return 0 }
            let old = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
            let new = newPath.hasSuffix("/") ? String(newPath.dropLast()) : newPath
            try db.execute(sql: "UPDATE libraryRoot SET path = ?, bookmark = ?, eventId = NULL, eventsVolumeId = NULL WHERE id = ?", arguments: [new, bookmark, rootId])
            guard old != new else { return 0 }
            try db.execute(sql: """
                UPDATE track SET path = ? || substr(path, ?) WHERE rootId = ? AND (path = ? OR path LIKE ? ESCAPE '\\')
                """, arguments: [new, old.unicodeScalars.count + 1, rootId, old, Self.likePrefix(old) + "/%"])
            // SQLite's substr counts code points (macOS file names are often decomposed: "é" is two), not characters.
            let moved = db.changesCount
            // CUE tracks also point at their audio file.
            try db.execute(sql: """
                UPDATE track SET audioPath = ? || substr(audioPath, ?) WHERE rootId = ? AND audioPath LIKE ? ESCAPE '\\'
                """, arguments: [new, old.unicodeScalars.count + 1, rootId, Self.likePrefix(old) + "/%"])
            return moved
        }
    }

    static func likePrefix(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }
}

extension LibraryBackup {
    /// The name of the Mac (or device) a backup comes from.
    static var computerName: String? {
        #if os(macOS)
        Host.current().localizedName
        #else
        ProcessInfo.processInfo.hostName
        #endif
    }
}
