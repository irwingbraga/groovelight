import AppKit
import Foundation
import IOKit.ps
import LibraryKit
import Observation
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

extension UTType {
    /// Groovelight backup package (declared in Info.plist).
    static let groovelightBackup = UTType(exportedAs: "dev.irwingbraga.groovelight.backup", conformingTo: .package)
}

/// Backups of the library data that is not in the music files, restores (with relinking of music folders), and
/// automatic backups: to a chosen folder (a NAS share, another disk, iCloud Drive; in its `Data` folder) or to the app's
/// own `Backups` folder, by default at night. With a chosen folder, the music library can be mirrored there too (in its
/// `Music` folder, see `LibraryMirror`), and Groovelight can connect to the NAS with a login of its own.
@MainActor
@Observable
final class BackupManager {
    enum Keys {
        static let automatic = "backup.automatic"
        static let frequency = "backup.frequency"
        static let keep = "backup.keep"
        static let folder = "backup.folderBookmark"
        static let lastBackup = "backup.lastDate"
        static let window = "backup.window"
        static let onlyOnPower = "backup.onlyOnPower"
        static let lastError = "backup.lastError"
        static let lastAttempt = "backup.lastAttempt"
        static let failures = "backup.failures"
        /// The NAS login: its shared folder (smb://host/share) and user; the password is in the Keychain.
        static let server = "backup.server"
        static let user = "backup.user"
        static let mirror = "backup.mirror.enabled"
        /// Library folders left out of the mirror (paths).
        static let mirrorExcluded = "backup.mirror.excluded"
        /// Days files gone from the library stay in the mirror's `.Removed` (0: forever).
        static let keepRemovedDays = "backup.mirror.keepRemovedDays"
        static let mirrorReport = "backup.mirror.lastReport"
        /// Library folders the user said to mirror although they lost many files (for the next run only).
        static let mirrorConfirmed = "backup.mirror.confirmed"
    }

    enum Frequency: String, CaseIterable, Identifiable {
        case daily, weekly
        var id: Self { self }
        var interval: TimeInterval { self == .daily ? 24 * 3600 : 7 * 24 * 3600 }
    }

    /// The chosen folder, as last checked.
    enum DestinationStatus: Equatable {
        /// None chosen: backups stay in Groovelight's data.
        case notChosen
        case checking
        case ready(path: String, available: Int64?)
        case unavailable(String)
    }

    /// Preferences that travel with a backup (machine specific ones, like the backup folder, stay behind).
    static let preferencePrefixes = ["eq.", "metadata.", "visualizer.", "albums.", "shelf.", "devices.", "player.", "appearance.", "shortcuts.", "lastfm."]
    static let unreachable = "Not reachable. Is the NAS or disk on, and its shared folder available?"
    /// The launch agent that runs backups while Groovelight is closed (Contents/Library/LaunchAgents).
    static let agentName = "dev.irwingbraga.groovelight.backup.plist"

    private(set) var isWorking = false {
        didSet {
            // "Quit When Done" while it ran.
            if !isWorking, quitWhenDone {
                quitWhenDone = false
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
    }
    /// What it is doing while it works ("backing up"), for the question on quitting.
    @ObservationIgnored private var work = "backing up"
    @ObservationIgnored private var quitWhenDone = false
    private(set) var lastBackup: Date?
    /// Why the last automatic backup failed (nil once one succeeds).
    private(set) var lastError: String?
    private(set) var lastAttempt: Date?
    private(set) var destinationStatus = DestinationStatus.notChosen
    /// How far the data backup's copy to the chosen folder is (files written, of all), while it runs.
    private(set) var dataProgress: (done: Int, total: Int)?
    /// What the music mirror is doing now ("Copying 120 of 3,400"), and how far along (0 to 1).
    private(set) var mirrorActivity: String?
    private(set) var mirrorFraction: Double?
    private(set) var mirrorReport: LibraryMirror.Report?
    /// Whether backups also run while Groovelight is closed (the launch agent), and whether macOS waits for the user to
    /// allow it in System Settings.
    private(set) var runsWhenClosed = false
    private(set) var whenClosedNeedsApproval = false
    /// Library folders that could not be opened after a restore: the user locates them again.
    var foldersToLocate: [LibraryRoot] = []

    @ObservationIgnored unowned let model: AppModel
    @ObservationIgnored private var scheduler: NSBackgroundActivityScheduler?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The chosen folder while it is open (security-scoped access started once, not per use).
    @ObservationIgnored private(set) var openFolder: URL?
    @ObservationIgnored private var mirrorTask: Task<LibraryMirror.Report, any Error>?
    /// Launched by the launch agent for a backup (`-GLLaunchedForBackup YES`): quits when done, unless the user came.
    @ObservationIgnored let launchedForBackup = UserDefaults.standard.bool(forKey: "GLLaunchedForBackup")
    @ObservationIgnored private var userCame = false

    init(model: AppModel) {
        self.model = model
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Keys.automatic: true, Keys.frequency: Frequency.weekly.rawValue, Keys.keep: 5,
                                     Keys.window: BackupSchedule.Window.night.rawValue, Keys.onlyOnPower: false,
                                     Keys.mirror: false, Keys.keepRemovedDays: 30])
        lastBackup = defaults.object(forKey: Keys.lastBackup) as? Date
        lastError = defaults.string(forKey: Keys.lastError)
        lastAttempt = defaults.object(forKey: Keys.lastAttempt) as? Date
        mirrorReport = defaults.data(forKey: Keys.mirrorReport).flatMap { try? JSONDecoder().decode(LibraryMirror.Report.self, from: $0) }
        if defaults.data(forKey: Keys.folder) != nil { destinationStatus = .checking }
        refreshWhenClosed()
        // Every 15 minutes (when the system finds it convenient), a minute after launch, and a little after waking: a
        // backup runs when one is due (see `BackupSchedule`).
        let scheduler = NSBackgroundActivityScheduler(identifier: "dev.irwingbraga.groovelight.backup")
        scheduler.repeats = true
        scheduler.interval = 15 * 60
        scheduler.tolerance = 5 * 60
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                await self?.backUpIfDue()
                completion(.finished)
            }
        }
        self.scheduler = scheduler
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(120))
                await self?.backUpIfDue()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.userCame = true }
        })
        // Launched for a backup, the command line tool asks for it; otherwise a minute after launch.
        if !launchedForBackup {
            Task {
                try? await Task.sleep(for: .seconds(60))
                await backUpIfDue()
            }
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
        work = "backing up"
        isWorking = true
        defer { isWorking = false }
        do {
            try await write(to: url)
            return true
        } catch {
            if !isAutomatic { model.errorMessage = "The backup failed: \(error.localizedDescription)" }
            return false
        }
    }

    /// Writes a backup package at `url` (off the main thread).
    private func write(to url: URL) async throws {
        let database = model.database
        let artwork = model.artwork.directory
        let preferences = (try? PropertyListSerialization.data(fromPropertyList: Self.exportedPreferences(), format: .xml, options: 0)) ?? Data()
        let version = Self.appVersion
        _ = try await Task.detached(priority: .utility) {
            try LibraryBackup.write(database: database, artworkDirectory: artwork, preferences: preferences, appVersion: version, to: url)
        }.value
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private func succeeded() {
        lastBackup = .now
        lastError = nil
        UserDefaults.standard.set(lastBackup, forKey: Keys.lastBackup)
        UserDefaults.standard.removeObject(forKey: Keys.lastError)
        UserDefaults.standard.removeObject(forKey: Keys.failures)
    }

    private func failed(_ message: String) {
        lastError = message
        UserDefaults.standard.set(message, forKey: Keys.lastError)
        let failures = UserDefaults.standard.integer(forKey: Keys.failures) + 1
        UserDefaults.standard.set(failures, forKey: Keys.failures)
        // Only when it needs the user: a backup failing night after night (not one NAS asleep at the wrong time).
        if let lastBackup, Date.now.timeIntervalSince(lastBackup) > schedule.interval + 2 * 24 * 3600, failures >= 3 {
            notify("Groovelight could not back up", body: message)
        }
    }

    static func fileName(for date: Date) -> String {
        BackupDestination.fileName(for: date)
    }

    static func exportedPreferences() -> [String: Any] {
        UserDefaults.standard.dictionaryRepresentation().filter { key, _ in preferencePrefixes.contains { key.hasPrefix($0) } }
    }

    // MARK: - The backup folder

    var hasChosenFolder: Bool { UserDefaults.standard.data(forKey: Keys.folder) != nil }

    var defaultFolder: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Groovelight/Backups", isDirectory: true)
    }

    func chooseAutomaticFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where automatic backups go: a folder on a NAS, another disk or iCloud Drive survives losing this Mac. Data backups go in its Data folder, the music in its Music folder."
        guard panel.runModal() == .OK, let url = panel.url, let bookmark = try? FolderAccess.makeBookmark(for: url) else { return }
        useFolder(url, bookmark: bookmark)
    }

    /// Makes `url` the backup folder. On a NAS share, its address is kept for connecting with a login of Groovelight's
    /// own (and the user it was mounted as, as a start).
    func useFolder(_ url: URL, bookmark: Data) {
        closeFolder()
        let defaults = UserDefaults.standard
        defaults.set(bookmark, forKey: Keys.folder)
        if let share = NASConnection.share(of: url) {
            if defaults.string(forKey: Keys.server) != share.absoluteString { defaults.set(share.absoluteString, forKey: Keys.server) }
            if (defaults.string(forKey: Keys.user) ?? "").isEmpty, let user = NASConnection.user(of: url) { defaults.set(user, forKey: Keys.user) }
        } else {
            defaults.removeObject(forKey: Keys.server)
        }
        // Another destination: what this Mac knew was copied is about the old one (the new one's own manifest is used).
        try? FileManager.default.removeItem(at: Self.mirrorState)
        Task { await checkDestination() }
    }

    /// Back to backing up inside Groovelight's data.
    func forgetAutomaticFolder() {
        closeFolder()
        UserDefaults.standard.removeObject(forKey: Keys.folder)
        UserDefaults.standard.removeObject(forKey: Keys.server)
        try? FileManager.default.removeItem(at: Self.mirrorState)
        destinationStatus = .notChosen
    }

    // MARK: - The NAS login

    /// The share Groovelight connects to (smb://host/share), when the backup folder is on one.
    var server: URL? { UserDefaults.standard.string(forKey: Keys.server).flatMap(URL.init(string:)) }
    var loginUser: String { UserDefaults.standard.string(forKey: Keys.user) ?? "" }
    var hasLogin: Bool { server != nil && !loginUser.isEmpty && NASConnection.password(user: loginUser, server: server!) != nil }

    /// Saves the login (the password in the Keychain; an empty one removes it), then connects to check it.
    func saveLogin(server text: String, user: String, password: String) async {
        let defaults = UserDefaults.standard
        guard let server = NASConnection.serverURL(from: text) else {
            destinationStatus = .unavailable("Type the NAS's shared folder as nas.local/Backups.")
            return
        }
        // Another share or user: the old password goes (the same one, typed another way, keeps it).
        if let old = self.server, !loginUser.isEmpty, old != server || loginUser != user {
            NASConnection.savePassword(nil, user: loginUser, server: old)
        }
        defaults.set(server.absoluteString, forKey: Keys.server)
        defaults.set(user, forKey: Keys.user)
        if !password.isEmpty { NASConnection.savePassword(password, user: user, server: server) }
        closeFolder()
        await checkDestination()
    }

    func forgetLogin() {
        if let server, !loginUser.isEmpty { NASConnection.savePassword(nil, user: loginUser, server: server) }
        UserDefaults.standard.removeObject(forKey: Keys.user)
    }

    /// Mounts the NAS share with Groovelight's login when it is not mounted. Throws why it could not.
    private func connect() async throws {
        guard let server, !loginUser.isEmpty, let password = NASConnection.password(user: loginUser, server: server) else { return }
        let login = NASConnection.Login(server: server, user: loginUser, password: password)
        _ = try await Task.detached(priority: .utility) { try NASConnection.mount(login) }.value
    }

    /// The chosen folder, opened. Connects to the NAS first (with Groovelight's login, when there is one); resolving
    /// the bookmark also mounts the share again when it is not mounted (with the password in the Keychain), so this
    /// runs off the main thread. Throws why it could not be reached.
    private func resolveFolder() async throws -> URL {
        guard let bookmark = UserDefaults.standard.data(forKey: Keys.folder) else { throw ControlError(Self.unreachable) }
        if let openFolder, BackupDestination(url: openFolder).isWritable { return openFolder }
        closeFolder()
        try await connect()
        let resolved = await Task.detached(priority: .utility) { try? FolderAccess.startAccessing(bookmark) }.value
        guard let resolved, FileManager.default.fileExists(atPath: resolved.url.path) else { throw ControlError(Self.unreachable) }
        if let refreshed = resolved.refreshedBookmark { UserDefaults.standard.set(refreshed, forKey: Keys.folder) }
        openFolder = resolved.url
        return resolved.url
    }

    private func closeFolder() {
        openFolder?.stopAccessingSecurityScopedResource()
        openFolder = nil
    }

    /// Checks the chosen folder (for Settings): there, writable, and the space left.
    func checkDestination() async {
        guard hasChosenFolder else {
            destinationStatus = .notChosen
            return
        }
        destinationStatus = .checking
        let url: URL
        do {
            url = try await resolveFolder()
        } catch {
            destinationStatus = .unavailable(error.localizedDescription)
            return
        }
        let destination = BackupDestination(url: url)
        let status: DestinationStatus = await Task.detached(priority: .utility) {
            destination.isWritable ? .ready(path: Self.displayName(of: url), available: destination.availableCapacity)
                                   : .unavailable("Groovelight cannot write to this folder. Check its permissions on the NAS.")
        }.value
        destinationStatus = status
    }

    /// "Groovelight on Backups" (a folder on a NAS share or another disk), or its path on this Mac's own disk.
    nonisolated static func displayName(of url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeIsInternalKey, .volumeURLKey])
        guard values?.volumeIsInternal != true, let volume = values?.volumeLocalizedName else {
            return (url.path as NSString).abbreviatingWithTildeInPath
        }
        return values?.volume?.standardizedFileURL == url.standardizedFileURL ? volume : "\(url.lastPathComponent) on \(volume)"
    }

    /// Shows the chosen folder (its Data folder when there is one) in the Finder.
    func showDestination() {
        guard let openFolder else { return }
        NSWorkspace.shared.open(openFolder)
    }

    // MARK: - Automatic backups

    var schedule: BackupSchedule {
        let defaults = UserDefaults.standard
        let frequency = Frequency(rawValue: defaults.string(forKey: Keys.frequency) ?? "") ?? .weekly
        let window = BackupSchedule.Window(rawValue: defaults.string(forKey: Keys.window) ?? "") ?? .night
        return BackupSchedule(interval: frequency.interval, window: window)
    }

    /// When the next automatic backup is due (nil: now, or automatic backups are off).
    var nextBackup: Date? {
        guard UserDefaults.standard.bool(forKey: Keys.automatic), let lastBackup else { return nil }
        return schedule.nextRun(after: lastBackup)
    }

    var isDue: Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Keys.automatic), schedule.isDue(lastBackup: lastBackup, now: .now) else { return false }
        return !defaults.bool(forKey: Keys.onlyOnPower) || Self.isOnPower
    }

    func backUpIfDue() async {
        guard !isWorking, isDue else { return }
        await backUpAutomatically()
    }

    var mirrorsMusic: Bool { hasChosenFolder && UserDefaults.standard.bool(forKey: Keys.mirror) }

    /// An automatic backup now (also "Back Up Now"): the data to the chosen folder (or inside Groovelight's data), then
    /// the music mirror when it is on. Returns whether the data backup was made.
    @discardableResult
    func backUpAutomatically(includeMusic: Bool = true) async -> Bool {
        guard !isWorking else { return false }
        work = "backing up"
        isWorking = true
        defer { isWorking = false }
        lastAttempt = .now
        UserDefaults.standard.set(lastAttempt, forKey: Keys.lastAttempt)
        let keep = max(1, UserDefaults.standard.integer(forKey: Keys.keep))
        do {
            if hasChosenFolder {
                let url: URL
                do {
                    url = try await resolveFolder()
                } catch {
                    destinationStatus = .unavailable(error.localizedDescription)
                    failed(error is NASConnection.Failure ? error.localizedDescription : "The backup folder was not reachable")
                    return false
                }
                let destination = BackupDestination(url: url)
                guard destination.isWritable else {
                    destinationStatus = .unavailable("Groovelight cannot write to this folder. Check its permissions on the NAS.")
                    failed("The backup folder could not be written to")
                    return false
                }
                let database = model.database
                let artwork = model.artwork.directory
                let preferences = (try? PropertyListSerialization.data(fromPropertyList: Self.exportedPreferences(), format: .xml, options: 0)) ?? Data()
                let version = Self.appVersion
                dataProgress = (0, 0)
                defer { dataProgress = nil }
                let report: @Sendable (Int, Int) -> Void = { [weak self] done, total in
                    Task { @MainActor in
                        guard let self, self.dataProgress != nil else { return }
                        self.dataProgress = (done, total)
                    }
                }
                _ = try await Task.detached(priority: .utility) {
                    try destination.backUp(keep: keep) { partial in
                        _ = try LibraryBackup.write(database: database, artworkDirectory: artwork, preferences: preferences,
                                                    appVersion: version, to: partial, sharedArtwork: destination.sharedArtwork,
                                                    progress: report)
                    }
                }.value
                if includeMusic, mirrorsMusic {
                    do {
                        try await mirror(to: url)
                    } catch is CancellationError {
                        // Stopped by the user: what was copied is kept, the next run goes on.
                    } catch {
                        destinationStatus = .ready(path: Self.displayName(of: url), available: destination.availableCapacity)
                        succeeded()
                        failed("Music: \(error.localizedDescription)")
                        return true
                    }
                }
                destinationStatus = .ready(path: Self.displayName(of: url), available: destination.availableCapacity)
            } else {
                let folder = defaultFolder
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await write(to: folder.appendingPathComponent(Self.fileName(for: .now)))
                BackupDestination.prune(folder, keeping: keep)
            }
            succeeded()
            return true
        } catch {
            failed(error.localizedDescription)
            return false
        }
    }

    /// Whether the Mac runs on its power adapter (or has no battery).
    static var isOnPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }

    // MARK: - The music mirror

    /// This Mac's record of what is on the mirror (a copy is on the NAS).
    static var mirrorState: URL {
        #if DEBUG
        if let folder = UserDefaults.standard.string(forKey: "GLDebugDataDir") {
            return URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("Mirror.json")
        }
        #endif
        return URL.applicationSupportDirectory.appendingPathComponent("Groovelight/Mirror.json")
    }

    /// Library folders and whether each is mirrored.
    func libraryFolders() async -> [LibraryRoot] {
        (try? await model.database.writer.read { try LibraryDatabase.roots($0) }) ?? []
    }

    func isMirrored(_ path: String) -> Bool {
        !(UserDefaults.standard.stringArray(forKey: Keys.mirrorExcluded) ?? []).contains(path)
    }

    func setMirrored(_ path: String, _ on: Bool) {
        var excluded = Set(UserDefaults.standard.stringArray(forKey: Keys.mirrorExcluded) ?? [])
        if on { excluded.remove(path) } else { excluded.insert(path) }
        UserDefaults.standard.set(excluded.sorted(), forKey: Keys.mirrorExcluded)
    }

    /// Mirrors the library folders into `url`'s Music folder.
    private func mirror(to url: URL) async throws {
        let roots = await libraryFolders().filter { isMirrored($0.path) }
        var sources: [String: URL?] = [:]
        for root in roots {
            let available = !model.unavailableFolders.contains(root.path) && FileManager.default.fileExists(atPath: root.path)
            sources[root.path] = available ? URL(fileURLWithPath: root.path, isDirectory: true) : nil
        }
        let defaults = UserDefaults.standard
        let days = defaults.integer(forKey: Keys.keepRemovedDays)
        let options = LibraryMirror.Options(keepRemovedDays: days > 0 ? days : nil,
                                            confirmed: Set(defaults.stringArray(forKey: Keys.mirrorConfirmed) ?? []),
                                            concurrency: Self.isOnPower ? 2 : 1)
        let state = Self.mirrorState
        mirrorActivity = "Looking for changes"
        mirrorFraction = nil
        defer {
            mirrorActivity = nil
            mirrorFraction = nil
            mirrorTask = nil
        }
        let task = Task.detached(priority: .utility) { [weak self] in
            try await LibraryMirror.run(sources: sources, destination: url, state: state, options: options) { phase in
                Task { @MainActor in self?.show(phase) }
            }
        }
        mirrorTask = task
        let report = try await task.value
        defaults.removeObject(forKey: Keys.mirrorConfirmed)
        mirrorReport = report
        if let data = try? JSONEncoder().encode(report) { defaults.set(data, forKey: Keys.mirrorReport) }
        if !report.needsConfirmation.isEmpty {
            let names = report.needsConfirmation.map { URL(fileURLWithPath: $0.folder).lastPathComponent }.joined(separator: ", ")
            notify("Music backup waiting for you", body: "\(names) lost many files since the last backup. Open Settings, Backups to mirror it anyway.")
        }
    }

    private func show(_ phase: LibraryMirror.Phase) {
        guard mirrorTask != nil else { return }
        switch phase {
        case .planning:
            mirrorActivity = "Looking for changes"
            mirrorFraction = nil
        case .moving(let done, let total):
            mirrorActivity = "Moving renamed files, \(done) of \(total)"
            mirrorFraction = total > 0 ? Double(done) / Double(total) : nil
        case .copying(let done, let total, let bytes, let totalBytes):
            let size = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            mirrorActivity = "Copying \(done.formatted()) of \(total.formatted()) files (\(size))"
            mirrorFraction = totalBytes > 0 ? Double(bytes) / Double(totalBytes) : nil
        case .checking(let done, let total):
            mirrorActivity = "Checking copies, \(done) of \(total)"
            mirrorFraction = total > 0 ? Double(done) / Double(total) : nil
        case .cleaning:
            mirrorActivity = "Cleaning up"
            mirrorFraction = nil
        }
    }

    func stopMirror() {
        mirrorTask?.cancel()
    }

    /// Mirrors the folders that lost many files anyway, now.
    func confirmMirror() {
        guard let drops = mirrorReport?.needsConfirmation, !drops.isEmpty else { return }
        UserDefaults.standard.set(drops.map(\.folder), forKey: Keys.mirrorConfirmed)
        Task { await backUpAutomatically() }
    }

    // MARK: - While Groovelight is closed

    private var agent: SMAppService { SMAppService.agent(plistName: Self.agentName) }

    func refreshWhenClosed() {
        let status = agent.status
        runsWhenClosed = status == .enabled || status == .requiresApproval
        whenClosedNeedsApproval = status == .requiresApproval
    }

    /// Registers (or removes) the launch agent that asks for a backup at night while Groovelight is closed.
    func setRunsWhenClosed(_ on: Bool) {
        do {
            if on { try agent.register() } else { try agent.unregister() }
        } catch {
            model.errorMessage = "Could not \(on ? "turn on" : "turn off") backups while Groovelight is closed: \(error.localizedDescription)"
        }
        refreshWhenClosed()
        if whenClosedNeedsApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// The launch agent's request (through the command line tool): a backup if one is due, then quitting when the app
    /// was opened only for it.
    func scheduledRunFinished() {
        guard launchedForBackup, !userCame else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            if !userCame { NSApp.terminate(nil) }
        }
    }

    // MARK: - Notifications

    private func notify(_ title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        Task {
            // Provisional: delivered quietly to Notification Center, without asking first.
            _ = try? await center.requestAuthorization(options: [.alert, .provisional])
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: "backup-\(title)", content: content, trigger: nil))
        }
    }

    // MARK: - Quitting

    /// Asked when the user quits while a backup, restore or copy runs: quit now (a backup goes on next time from
    /// where it can), quit once it is done, or keep Groovelight open.
    func shouldQuit() -> NSApplication.TerminateReply {
        guard isWorking else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Groovelight is still \(work)."
        var detail = ""
        if let progress = dataProgress, progress.total > 0 {
            detail = "Copying the data, \(progress.done.formatted()) of \(progress.total.formatted()) files. "
        } else if let activity = mirrorActivity {
            detail = "\(activity). "
        }
        switch work {
        case "backing up":
            detail += "If you quit now, the backup stops and does not count: the next one runs again, and the music goes on from where it stopped."
        case "restoring the library":
            detail += "Quitting now could leave the library half restored."
        default:
            detail += "If you quit now, the files not copied yet stay on the NAS only."
        }
        alert.informativeText = detail
        alert.addButton(withTitle: "Quit When Done")
        alert.addButton(withTitle: "Quit Now")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard isWorking else { return .terminateNow }
            quitWhenDone = true
            return .terminateLater
        case .alertSecondButtonReturn:
            stopMirror()
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    // MARK: - Restoring

    func chooseAndRestore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.groovelightBackup]
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Restore"
        panel.message = "Choose a Groovelight backup."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let manifest: LibraryBackup.Manifest
        do {
            manifest = try LibraryBackup.manifest(of: url)
        } catch {
            model.errorMessage = error.localizedDescription
            return
        }
        guard confirmRestore(manifest) else { return }
        Task {
            let artwork = await sharedArtwork(of: url, manifest: manifest)
            await restore(from: url, artworkFrom: artwork)
            artwork?.stopAccessingSecurityScopedResource()
        }
    }

    /// For a backup whose covers are in the folder shared by the backups beside it (on a NAS): that folder, readable.
    /// The open panel only lets Groovelight read the backup itself, so this goes through the chosen backup folder (when
    /// the backup is in it), or asks for the folder the backup is in. Nil: the covers are in the backup, or none are
    /// reachable (the restore goes on without them; they come back from the music files where they are embedded).
    private func sharedArtwork(of url: URL, manifest: LibraryBackup.Manifest) async -> URL? {
        guard manifest.artworkFiles != nil else { return nil }
        let folder = LibraryBackup.artworkFolder(of: url, manifest: manifest)
        if hasChosenFolder, (try? await resolveFolder()) != nil, FileManager.default.isReadableFile(atPath: folder.path) { return nil }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = url.deletingLastPathComponent()
        panel.prompt = "Restore Covers"
        panel.message = "This backup keeps its covers beside it. Choose the folder it is in (\(url.deletingLastPathComponent().lastPathComponent)) to restore them too."
        guard panel.runModal() == .OK, let chosen = panel.url, chosen.startAccessingSecurityScopedResource() else { return nil }
        // The folder the backup is in, or its Artwork folder itself.
        let shared = chosen.lastPathComponent == folder.lastPathComponent ? chosen : LibraryBackup.sharedArtwork(in: chosen)
        guard FileManager.default.isReadableFile(atPath: shared.path) else {
            chosen.stopAccessingSecurityScopedResource()
            return nil
        }
        return chosen
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

    /// `artworkFrom`: the folder the backup is in, or its shared Artwork folder, when the covers are there and the
    /// user chose it.
    func restore(from url: URL, artworkFrom: URL? = nil) async {
        guard !isWorking else { return }
        work = "restoring the library"
        isWorking = true
        defer { isWorking = false }
        model.player.stop()
        model.path = []
        model.selection = .albums
        let database = model.database
        let artwork = model.artwork.directory
        do {
            let plist = try await Task.detached(priority: .userInitiated) {
                let shared = artworkFrom.map { $0.lastPathComponent == "Artwork" ? $0 : LibraryBackup.sharedArtwork(in: $0) }
                return try LibraryBackup.restore(from: url, into: database, artworkDirectory: artwork, artworkFrom: shared)
            }.value
            let preferences = plist.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
            for (key, value) in preferences where Self.preferencePrefixes.contains(where: { key.hasPrefix($0) }) {
                UserDefaults.standard.set(value, forKey: key)
            }
            model.equalizer.reloadFromDefaults()
            AppTheme.current.apply()
            model.shortcuts.load()
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
            rootMoved(from: root.path, to: url.standardizedFileURL.path)
            foldersToLocate.removeAll { $0.id == id }
            model.unavailableFolders.remove(root.path)
            Task {
                await model.sync.foldersChanged()
                model.rescanAll()
            }
        } catch {
            model.errorMessage = "Could not use that folder: \(error.localizedDescription)"
        }
    }
}

// MARK: - Restoring music from the mirror

extension BackupManager {
    /// A library folder copied to the mirror.
    struct MirroredFolder: Identifiable, Hashable {
        var id: String { path }
        /// The library folder's path on this Mac (as it was when mirrored).
        var path: String
        /// Its folder in the mirror's Music folder.
        var name: String
        var files: Int
        var bytes: Int64
        var url: URL
    }

    /// The mirror's manifest: this Mac's, else the one on the NAS (a new Mac). Opens the backup folder.
    private func mirrorManifest() async throws -> (destination: URL, manifest: LibraryMirror.Manifest) {
        let destination = try await resolveFolder()
        let remote = destination.appendingPathComponent(LibraryMirror.folderName).appendingPathComponent(LibraryMirror.manifestName)
        let state = Self.mirrorState
        let manifest = await Task.detached(priority: .userInitiated) {
            LibraryMirror.Manifest.load(from: state) ?? LibraryMirror.Manifest.load(from: remote)
        }.value
        guard let manifest else { throw ControlError("There is no music backup in the backup folder yet.") }
        return (destination, manifest)
    }

    func mirroredFolders() async -> [MirroredFolder] {
        guard let (destination, manifest) = try? await mirrorManifest() else { return [] }
        let music = destination.appendingPathComponent(LibraryMirror.folderName)
        return manifest.roots.map { path, name in
            let files = manifest.files.filter { $0.key.hasPrefix(name + "/") }
            return MirroredFolder(path: path, name: name, files: files.count, bytes: files.values.reduce(0) { $0 + $1.size },
                                  url: music.appendingPathComponent(name, isDirectory: true))
        }
        .filter { $0.files > 0 }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Files set aside in the mirror's `.Removed` (gone from the library), newest first.
    func removedFiles() async -> [LibraryMirror.RemovedFile] {
        guard let destination = try? await resolveFolder() else { return [] }
        return await Task.detached(priority: .userInitiated) { LibraryMirror.removedFiles(in: destination) }.value
    }

    /// Puts files from `.Removed` back where they were in their library folder. Returns a summary.
    func putBack(_ files: [LibraryMirror.RemovedFile]) async -> String {
        guard !isWorking, let (_, manifest) = try? await mirrorManifest() else { return "The backup folder is not reachable." }
        let byName = Dictionary(manifest.roots.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        var pairs: [(from: URL, to: URL)] = []
        for file in files {
            let parts = file.key.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let root = byName[parts[0]], !model.unavailableFolders.contains(root) else { continue }
            pairs.append((file.url, URL(fileURLWithPath: root).appendingPathComponent(parts[1])))
        }
        let result = await copyingBack(pairs)
        model.rescanAll()
        return Self.summary(result, of: files.count)
    }

    /// Plays a library folder from its copy on the NAS (its own drive lost or away): the folder's songs point at the
    /// mirror, keeping their history.
    func useMirror(_ folder: MirroredFolder) async {
        guard let root = await libraryFolders().first(where: { $0.path == folder.path }), let id = root.id else {
            model.errorMessage = "\(folder.path) is not a library folder anymore."
            return
        }
        do {
            let bookmark = try FolderAccess.makeBookmark(for: folder.url)
            _ = folder.url.startAccessingSecurityScopedResource()
            try model.database.relocateRoot(id, to: folder.url.standardizedFileURL.path, bookmark: bookmark)
            rootMoved(from: root.path, to: folder.url.standardizedFileURL.path)
            foldersToLocate.removeAll { $0.id == id }
            model.unavailableFolders.remove(root.path)
            await model.sync.foldersChanged()
            model.rescanAll()
        } catch {
            model.errorMessage = "Could not use the copy on the NAS: \(error.localizedDescription)"
        }
    }

    /// Copies a mirrored library folder back to a folder the user chooses (a new drive), then points the library
    /// folder's songs there.
    func copyBack(_ folder: MirroredFolder) async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Copy Here"
        panel.message = "Choose where to copy \(folder.name) (\(ByteCountFormatter.string(fromByteCount: folder.bytes, countStyle: .file))): a folder named \(folder.name) is made in it."
        guard panel.runModal() == .OK, let parent = panel.url, let (destination, manifest) = try? await mirrorManifest() else { return }
        _ = parent.startAccessingSecurityScopedResource()
        let target = parent.appendingPathComponent(folder.name, isDirectory: true)
        let result = await copyingBack(LibraryMirror.files(of: folder.name, in: destination, manifest: manifest, onto: target))
        guard result.errors.isEmpty || result.copied > 0 else {
            model.errorMessage = "Nothing was copied: \(result.errors.first ?? "")"
            return
        }
        if let root = await libraryFolders().first(where: { $0.path == folder.path }), let id = root.id,
           let bookmark = try? FolderAccess.makeBookmark(for: target) {
            _ = target.startAccessingSecurityScopedResource()
            _ = try? model.database.relocateRoot(id, to: target.standardizedFileURL.path, bookmark: bookmark)
            rootMoved(from: root.path, to: target.standardizedFileURL.path)
            foldersToLocate.removeAll { $0.id == id }
            model.unavailableFolders.remove(root.path)
            await model.sync.foldersChanged()
        } else {
            model.addLibraryFolder(target)
        }
        model.rescanAll()
        if !result.errors.isEmpty { model.errorMessage = Self.summary(result, of: result.copied + result.errors.count) }
    }

    private func copyingBack(_ files: [(from: URL, to: URL)]) async -> (copied: Int, errors: [String]) {
        work = "copying music back"
        isWorking = true
        defer {
            isWorking = false
            mirrorActivity = nil
            mirrorFraction = nil
        }
        mirrorActivity = "Copying back"
        return await LibraryMirror.copyBack(files) { [weak self] done, total in
            Task { @MainActor in
                self?.mirrorActivity = "Copying back \(done.formatted()) of \(total.formatted()) files"
                self?.mirrorFraction = total > 0 ? Double(done) / Double(total) : nil
            }
        }
    }

    private static func summary(_ result: (copied: Int, errors: [String]), of total: Int) -> String {
        let copied = "Put back \(result.copied) of \(total) file\(total == 1 ? "" : "s")."
        guard let first = result.errors.first else { return copied }
        return copied + " \(result.errors.count) could not be copied (\(first))."
    }

    /// A library folder moved (located again, played from the NAS, copied back): its copy on the NAS stays its copy,
    /// instead of a new one being made under another name.
    func rootMoved(from old: String, to new: String) {
        let state = Self.mirrorState
        let remote = openFolder?.appendingPathComponent(LibraryMirror.folderName).appendingPathComponent(LibraryMirror.manifestName)
        guard old != new, var manifest = LibraryMirror.Manifest.load(from: state) ?? remote.flatMap(LibraryMirror.Manifest.load),
              let name = manifest.roots[old] else { return }
        manifest.roots[old] = nil
        manifest.roots[new] = name
        try? manifest.save(to: state)
    }

    /// The mirrored copy of a library folder, for locating it after a restore on another Mac.
    func mirroredFolder(for path: String) async -> MirroredFolder? {
        await mirroredFolders().first { $0.path == path }
    }
}
