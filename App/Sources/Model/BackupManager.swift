import AppKit
import Foundation
import LibraryKit
import Observation
import UniformTypeIdentifiers

extension UTType {
    /// Groovelight backup package (declared in Info.plist).
    static let groovelightBackup = UTType(exportedAs: "dev.irwingbraga.groovelight.backup", conformingTo: .package)
}

/// Backups of the library data that is not in the music files, restores (with relinking of music folders), and
/// automatic backups.
@MainActor
@Observable
final class BackupManager {
    enum Keys {
        static let automatic = "backup.automatic"
        static let frequency = "backup.frequency"
        static let keep = "backup.keep"
        static let folder = "backup.folderBookmark"
        static let lastBackup = "backup.lastDate"
    }

    enum Frequency: String, CaseIterable, Identifiable {
        case daily, weekly
        var id: Self { self }
        var interval: TimeInterval { self == .daily ? 24 * 3600 : 7 * 24 * 3600 }
    }

    /// Preferences that travel with a backup (machine specific ones, like the backup folder, stay behind).
    static let preferencePrefixes = ["eq.", "metadata.", "visualizer.", "albums.", "player.", "appearance."]

    private(set) var isWorking = false
    private(set) var lastBackup: Date?
    /// Library folders that could not be opened after a restore: the user locates them again.
    var foldersToLocate: [LibraryRoot] = []

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private var timer: Timer?

    init(model: AppModel) {
        self.model = model
        UserDefaults.standard.register(defaults: [Keys.automatic: true, Keys.frequency: Frequency.weekly.rawValue, Keys.keep: 5])
        lastBackup = UserDefaults.standard.object(forKey: Keys.lastBackup) as? Date
        // Check for a due automatic backup a minute after launch, then hourly.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.backUpIfDue() }
        }
        Task {
            try? await Task.sleep(for: .seconds(60))
            backUpIfDue()
        }
    }

    // MARK: - Backing up

    func chooseAndBackUp() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.groovelightBackup]
        panel.nameFieldStringValue = Self.fileName(for: .now)
        panel.message = "Back up playlists, play counts, ratings, metadata fixes, lyrics, credits and settings."
        panel.prompt = "Back Up"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await backUp(to: url, isAutomatic: false) }
    }

    @discardableResult
    func backUp(to url: URL, isAutomatic: Bool) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        let database = model.database
        let artwork = model.artwork.directory
        let preferences = (try? PropertyListSerialization.data(fromPropertyList: Self.exportedPreferences(), format: .xml, options: 0)) ?? Data()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        do {
            _ = try await Task.detached(priority: .utility) {
                try LibraryBackup.write(database: database, artworkDirectory: artwork, preferences: preferences, appVersion: version, to: url)
            }.value
            lastBackup = .now
            UserDefaults.standard.set(lastBackup, forKey: Keys.lastBackup)
            return true
        } catch {
            if !isAutomatic { model.errorMessage = "The backup failed: \(error.localizedDescription)" }
            return false
        }
    }

    static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "Groovelight Backup \(formatter.string(from: date)).\(LibraryBackup.fileExtension)"
    }

    static func exportedPreferences() -> [String: Any] {
        UserDefaults.standard.dictionaryRepresentation().filter { key, _ in preferencePrefixes.contains { key.hasPrefix($0) } }
    }

    // MARK: - Automatic backups

    /// Where automatic backups go: the chosen folder, or the app's own Backups folder (protects against a damaged
    /// library, not a lost Mac).
    var automaticFolder: URL? {
        if let bookmark = UserDefaults.standard.data(forKey: Keys.folder), let access = try? FolderAccess.startAccessing(bookmark) {
            if let refreshed = access.refreshedBookmark { UserDefaults.standard.set(refreshed, forKey: Keys.folder) }
            return access.url
        }
        return nil
    }

    var defaultFolder: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Groovelight/Backups", isDirectory: true)
    }

    func chooseAutomaticFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where automatic backups go. A folder in iCloud Drive or on another disk survives losing this Mac."
        guard panel.runModal() == .OK, let url = panel.url, let bookmark = try? FolderAccess.makeBookmark(for: url) else { return }
        UserDefaults.standard.set(bookmark, forKey: Keys.folder)
    }

    func backUpIfDue() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Keys.automatic), !isWorking else { return }
        let frequency = Frequency(rawValue: defaults.string(forKey: Keys.frequency) ?? "") ?? .weekly
        if let last = lastBackup, Date.now.timeIntervalSince(last) < frequency.interval { return }
        Task { await backUpAutomatically() }
    }

    func backUpAutomatically() async {
        let folder = automaticFolder ?? defaultFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard await backUp(to: folder.appendingPathComponent(Self.fileName(for: .now)), isAutomatic: true) else { return }
        // Keep only the newest automatic backups.
        let keep = max(1, UserDefaults.standard.integer(forKey: Keys.keep))
        let backups = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("Groovelight Backup ") && $0.pathExtension == LibraryBackup.fileExtension }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in backups.dropFirst(keep) { try? FileManager.default.removeItem(at: old) }
    }

    // MARK: - Restoring

    func chooseAndRestore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.groovelightBackup]
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Restore"
        panel.message = "Choose a Groovelight backup."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let manifest = try LibraryBackup.manifest(of: url)
            guard confirmRestore(manifest) else { return }
            Task { await restore(from: url) }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func confirmRestore(_ manifest: LibraryBackup.Manifest) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Restore the library from this backup?"
        let made = manifest.createdAt.formatted(date: .long, time: .shortened)
        alert.informativeText = """
            Backup from \(made)\(manifest.computerName.map { " on \($0)" } ?? ""): \(manifest.trackCount) songs, \
            \(manifest.playlistCount) playlists, \(manifest.lovedCount) loved songs, \(manifest.playCount) plays.

            Your current playlists, play counts, metadata fixes and settings are replaced. Your music files are not touched.
            """
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    func restore(from url: URL) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        model.player.stop()
        model.path = []
        model.selection = .albums
        let database = model.database
        let artwork = model.artwork.directory
        do {
            let plist = try await Task.detached(priority: .userInitiated) {
                try LibraryBackup.restore(from: url, into: database, artworkDirectory: artwork)
            }.value
            let preferences = plist.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
            for (key, value) in preferences where Self.preferencePrefixes.contains(where: { key.hasPrefix($0) }) {
                UserDefaults.standard.set(value, forKey: key)
            }
            model.equalizer.reloadFromDefaults()
            AppTheme.current.apply()
            await model.reopenLibraryAfterRestore()
        } catch {
            model.errorMessage = "The restore failed: \(error.localizedDescription)"
        }
    }

    /// Asks for a library folder again (after restoring on another Mac) and points its songs there.
    func locate(_ root: LibraryRoot) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use This Folder"
        panel.message = "Locate the music folder that was at \(root.path)"
        panel.directoryURL = URL(fileURLWithPath: root.path).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url, let id = root.id else { return }
        do {
            let bookmark = try FolderAccess.makeBookmark(for: url)
            _ = url.startAccessingSecurityScopedResource()
            try model.database.relocateRoot(id, to: url.standardizedFileURL.path, bookmark: bookmark)
            foldersToLocate.removeAll { $0.id == id }
            model.rescanAll()
        } catch {
            model.errorMessage = "Could not use that folder: \(error.localizedDescription)"
        }
    }
}
