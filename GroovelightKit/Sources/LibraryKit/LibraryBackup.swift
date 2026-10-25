import Foundation
import GRDB

/// Backups of everything Groovelight keeps outside the music files: the library database (play counts, ratings, loves,
/// playlists and covers, smart rules, metadata fixes, fetched lyrics, credits and backgrounds, library folders), the
/// artwork folder and the app's preferences.
///
/// A backup is a package (a folder that Finder shows as one file):
/// `Library.sqlite`, `Artwork/`, `Preferences.plist` and `Manifest.json`.
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
    /// backup API while the library stays open.
    @discardableResult
    /// `preferences` is property list data (a dictionary), kept as data so it can cross concurrency boundaries.
    public static func write(database: LibraryDatabase, artworkDirectory: URL, preferences: Data, appVersion: String,
                             to url: URL) throws -> Manifest {
        let fileManager = FileManager.default
        // Build in the temporary folder, then move into place, so a failed backup never leaves a half-written package
        // (and a sandboxed app may only write the chosen file itself, not next to it).
        let staging = fileManager.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let snapshot = try DatabaseQueue(path: staging.appendingPathComponent("Library.sqlite").path)
            try database.writer.backup(to: snapshot)
            // The copy inherits the library's WAL mode, which needs side files to be read: make it a single,
            // self-contained file.
            try snapshot.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode = DELETE") }
            try snapshot.close()

            let artwork = staging.appendingPathComponent("Artwork", isDirectory: true)
            try fileManager.createDirectory(at: artwork, withIntermediateDirectories: true)
            var artworkCount = 0
            for file in (try? fileManager.contentsOfDirectory(at: artworkDirectory, includingPropertiesForKeys: nil)) ?? [] {
                try fileManager.copyItem(at: file, to: artwork.appendingPathComponent(file.lastPathComponent))
                artworkCount += 1
            }

            try preferences.write(to: staging.appendingPathComponent("Preferences.plist"))

            let manifest = try database.writer.read { db in
                Manifest(formatVersion: formatVersion, appVersion: appVersion, createdAt: .now, computerName: Self.computerName,
                         trackCount: try Track.fetchCount(db), playlistCount: try Playlist.fetchCount(db),
                         lovedCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE isLoved") ?? 0,
                         playCount: try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(playCount), 0) FROM track") ?? 0,
                         artworkCount: artworkCount, folders: try LibraryDatabase.roots(db).map(\.path))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: staging.appendingPathComponent("Manifest.json"))

            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            try fileManager.moveItem(at: staging, to: url)
            return manifest
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
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
    public static func restore(from url: URL, into database: LibraryDatabase, artworkDirectory: URL) throws -> Data? {
        _ = try manifest(of: url)
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
        for file in (try? fileManager.contentsOfDirectory(at: url.appendingPathComponent("Artwork"), includingPropertiesForKeys: nil)) ?? [] {
            let destination = artworkDirectory.appendingPathComponent(file.lastPathComponent)
            // Content-addressed names: an existing file is the same image.
            if !fileManager.fileExists(atPath: destination.path) { try fileManager.copyItem(at: file, to: destination) }
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
