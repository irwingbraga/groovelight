import AppKit
import LibraryKit
import Observation
import WirelessSync

/// Portable players and memory cards: removable drives the Mac mounts (DAPs in USB disk mode, SD cards, USB sticks).
/// Each has a profile (folder layout, covers, lyrics, playlists) and a selection to sync, saved under "devices.".
@MainActor
@Observable
final class DeviceStore {
    struct Device: Identifiable, Hashable {
        /// The volume's UUID (its name when it has none), so the same card is known again.
        let id: String
        var name: String
        var root: URL
        var capacity: Int64
        var available: Int64
        /// "MS-DOS (FAT32)", "ExFAT"...
        var format: String
        var isFAT32: Bool
        /// A paired phone, tablet or player (the Android or iOS app), synced over the local network.
        var isWireless = false
        /// Groovelight plays the music (the iOS app, or the Android app in Player mode), rather than another app.
        var isPlayer = false
        var isOnline = true
        /// Its storages (internal memory, SD cards), the one with the music folder marked.
        var volumes: [WirelessProtocol.Volume] = []
    }

    /// A sync, send or export in progress or just finished.
    struct Job: Equatable {
        enum Phase: Equatable {
            /// A wireless device syncs when it next checks in.
            case waiting
            case planning
            case copying(done: Int, total: Int)
            case finished(String)
            case failed(String)
        }

        var deviceId: String
        var title: String
        var phase: Phase

        var isRunning: Bool {
            switch phase {
            case .waiting, .planning, .copying: true
            case .finished, .failed: false
            }
        }
    }

    /// What a sync of the current selection would do, for the device page.
    struct Preview: Equatable {
        var songs: Int
        var bytesToWrite: Int64
        var filesToWrite: Int
        var filesToRemove: Int
        var netBytes: Int64
        var musicBytes: Int64
        var skipped: [String]
    }

    private(set) var devices: [Device] = []
    private(set) var job: Job?
    /// Devices this app may write to (access was granted, or the app is not sandboxed).
    private(set) var accessible: Set<String> = []
    private(set) var previews: [String: Preview] = [:]

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let cancelFlag = CancelFlag()
    @ObservationIgnored private var previewTasks: [String: Task<Void, Never>] = [:]

    init(model: AppModel) {
        self.model = model
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    // MARK: - Finding devices

    func refresh() {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey, .volumeIsReadOnlyKey,
                                      .volumeIsLocalKey, .volumeUUIDStringKey, .volumeNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey, .volumeIsRootFileSystemKey]
        let libraryRoots = ((try? model.database.writer.read { try LibraryDatabase.roots($0) }) ?? []).map(\.path)
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        devices = volumes.compactMap { url -> Device? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsLocal == true, values.volumeIsRootFileSystem != true, values.volumeIsReadOnly != true,
                  values.volumeIsRemovable == true || values.volumeIsEjectable == true else { return nil }
            // A drive holding a library folder is the library, not a player.
            let path = url.standardizedFileURL.path
            if libraryRoots.contains(where: { $0 == path || $0.hasPrefix(path.hasSuffix("/") ? path : path + "/") }) { return nil }
            let fileSystem = Self.fileSystemName(url)
            return Device(id: values.volumeUUIDString ?? values.volumeName ?? path, name: values.volumeName ?? url.lastPathComponent,
                          root: url, capacity: Int64(values.volumeTotalCapacity ?? 0),
                          available: Int64(values.volumeAvailableCapacity ?? 0),
                          format: values.volumeLocalizedFormatDescription ?? fileSystem, isFAT32: fileSystem == "msdos")
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let wireless = model.wireless, wireless.isEnabled {
            devices += wireless.paired.map { device in
                Device(id: Self.wirelessId(device.id), name: device.name, root: URL(fileURLWithPath: "/"), capacity: device.capacity,
                       available: device.available, format: ["Wi-Fi", device.model].compactMap { $0 }.joined(separator: " · "),
                       isFAT32: false, isWireless: true, isPlayer: device.isPlayer, isOnline: wireless.isOnline(device),
                       volumes: device.volumes ?? [])
            }
        }
        accessible = Set(devices.filter { $0.isWireless || access($0, asking: false) != nil }.map(\.id))
        // A device page whose device was unplugged goes back to the library.
        if case .device(let id) = model.selection, !devices.contains(where: { $0.id == id }) {
            model.selection = .albums
        }
        for device in devices where accessible.contains(device.id) { updatePreview(device) }
    }

    static func wirelessId(_ id: String) -> String { "wifi:" + id }

    private static func pairedId(_ device: Device) -> String { String(device.id.dropFirst("wifi:".count)) }

    func device(_ id: String) -> Device? { devices.first { $0.id == id } }

    private static func fileSystemName(_ url: URL) -> String {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return "" }
        return withUnsafeBytes(of: info.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    // MARK: - Settings

    private func key(_ id: String, _ name: String) -> String { "devices.\(id).\(name)" }

    static let layoutKey = "devices.layout"

    /// The layout on every device (Settings, Devices).
    var layout: DeviceProfile {
        get {
            UserDefaults.standard.data(forKey: Self.layoutKey).flatMap { try? JSONDecoder().decode(DeviceProfile.self, from: $0) }
                ?? DeviceProfile()
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Self.layoutKey)
            for device in devices where accessible.contains(device.id) { updatePreview(device) }
        }
    }

    /// The layout for one device: the shared one, except that the Android app writes into the folder picked there
    /// (Android does not let apps pick a drive's root), so songs go at its top.
    func profile(_ id: String) -> DeviceProfile {
        var profile = layout
        if id.hasPrefix("wifi:") { profile.musicFolder = "" }
        profile.encoding = encoding(id)
        return profile
    }

    /// The lossy format this device gets lossless songs in (nil: as they are).
    func encoding(_ id: String) -> LossyEncoding? {
        #if DEBUG
        // `-GLDebugEncoding opus160` (tours): every device gets that format.
        if let value = UserDefaults.standard.string(forKey: "GLDebugEncoding") { return LossyEncoding(rawValue: value) }
        #endif
        return UserDefaults.standard.string(forKey: key(id, "encoding")).flatMap(LossyEncoding.init(rawValue:))
    }

    func setEncoding(_ encoding: LossyEncoding?, for id: String) {
        UserDefaults.standard.set(encoding?.rawValue, forKey: key(id, "encoding"))
        selectionRevision += 1
        if let device = device(id) { updatePreview(device) }
    }

    /// Changes whenever a selection or format is set (the device page reloads when the Android app changed it).

    func selection(_ id: String) -> DeviceSelection {
        UserDefaults.standard.data(forKey: key(id, "selection")).flatMap { try? JSONDecoder().decode(DeviceSelection.self, from: $0) }
            ?? DeviceSelection()
    }

    private(set) var selectionRevision = 0

    func setSelection(_ selection: DeviceSelection, for id: String) {
        guard selection != self.selection(id) else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(selection), forKey: key(id, "selection"))
        selectionRevision += 1
        if let device = device(id) { updatePreview(device) }
    }

    // MARK: - Access

    /// The device's root, readable and writable, or nil. The sandbox only lets the app write where the user chose:
    /// the first time, an open panel asks for the drive (when `asking`), and a bookmark remembers it.
    @discardableResult
    func access(_ device: Device, asking: Bool) -> URL? {
        if let data = UserDefaults.standard.data(forKey: key(device.id, "bookmark")) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale),
               url.standardizedFileURL == device.root.standardizedFileURL {
                _ = url.startAccessingSecurityScopedResource()
                if stale { saveBookmark(url, for: device) }
                if FileManager.default.isWritableFile(atPath: url.path) { return url }
            }
        }
        // Outside the sandbox (debug builds) the drive is writable as is.
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil, FileManager.default.isWritableFile(atPath: device.root.path) {
            return device.root
        }
        guard asking else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = device.root
        panel.prompt = "Allow"
        panel.message = "Groovelight needs your permission to put music on “\(device.name)”. Select the drive itself and click Allow."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard url.standardizedFileURL == device.root.standardizedFileURL else {
            model.errorMessage = "Choose the drive “\(device.name)” itself (not a folder on it) to allow Groovelight to sync with it."
            return nil
        }
        saveBookmark(url, for: device)
        accessible.insert(device.id)
        updatePreview(device)
        return url
    }

    private func saveBookmark(_ url: URL, for device: Device) {
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: key(device.id, "bookmark"))
        }
    }

    // MARK: - Preview

    /// Plans a sync of the current selection in the background, for the capacity bar and the Sync button.
    func updatePreview(_ device: Device) {
        if device.isWireless {
            updateWirelessPreview(device)
            return
        }
        guard let root = access(device, asking: false) else { return }
        let selection = selection(device.id), profile = profile(device.id), database = model.database
        previewTasks[device.id]?.cancel()
        previewTasks[device.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let preview = await Task.detached(priority: .utility) { () -> Preview? in
                guard let contents = try? await database.writer.read({ try LibraryDatabase.deviceContents($0, selection) }) else { return nil }
                let manifest = DeviceManifest.read(from: root)
                let plan = DeviceSync.plan(tracks: contents.tracks, playlists: contents.playlists, profile: profile, manifest: manifest,
                                           mode: .sync, root: root, fat32: device.isFAT32, excluded: selection.excludedTrackIds,
                                           formats: .of(selection, fallback: profile.encoding)) {
                    FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
                }
                return Preview(songs: plan.songCount, bytesToWrite: plan.bytesToWrite, filesToWrite: plan.writes.count,
                               filesToRemove: plan.deletions.count, netBytes: plan.netBytes, musicBytes: manifest.musicBytes,
                               skipped: plan.skipped.map { "\($0.title): \($0.reason)" })
            }.value
            guard !Task.isCancelled, let self else { return }
            self.previews[device.id] = preview
        }
    }

    /// From what the device reported at its last sync (nothing until it has synced once).
    private func updateWirelessPreview(_ device: Device) {
        guard let request = model.wireless.lastRequests[Self.pairedId(device)] else { return }
        let selection = selection(device.id), profile = profile(device.id), database = model.database
        previewTasks[device.id]?.cancel()
        previewTasks[device.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let files = Set(request.files.map { $0.lowercased() })
            let manifest = request.manifest ?? DeviceManifest()
            let preview = await Task.detached(priority: .utility) { () -> Preview? in
                guard let contents = try? await database.writer.read({ try LibraryDatabase.deviceContents($0, selection) }) else { return nil }
                let plan = DeviceSync.plan(tracks: contents.tracks, playlists: contents.playlists, profile: profile, manifest: manifest,
                                           mode: .sync, root: URL(fileURLWithPath: "/device"), excluded: selection.excludedTrackIds,
                                           formats: .of(selection, fallback: profile.encoding)) { files.contains($0.lowercased()) }
                return Preview(songs: plan.songCount, bytesToWrite: plan.bytesToWrite, filesToWrite: plan.writes.count,
                               filesToRemove: plan.deletions.count, netBytes: plan.netBytes, musicBytes: manifest.musicBytes,
                               skipped: plan.skipped.map { "\($0.title): \($0.reason)" })
            }.value
            guard !Task.isCancelled, let self else { return }
            self.previews[device.id] = preview
        }
    }

    // MARK: - Wireless progress

    func wirelessSyncStarted(_ id: String, files: Int) {
        guard let device = device(id) else { return }
        job = Job(deviceId: id, title: "Syncing \(device.name)", phase: files == 0 ? .planning : .copying(done: 0, total: files))
        if files == 0 { job?.phase = .finished("Already up to date.") }
    }

    func wirelessProgress(_ id: String, done: Int, total: Int) {
        guard job?.deviceId == id else { return }
        job?.phase = .copying(done: done, total: total)
    }

    func wirelessSyncFinished(_ id: String, summary: String, failed: [String]) {
        guard let device = device(id) else { return }
        job = Job(deviceId: id, title: "Syncing \(device.name)",
                  phase: failed.isEmpty ? .finished(summary) : .failed(summary + " " + failed.prefix(3).joined(separator: "; ")))
        refresh()
    }

    // MARK: - Sync, send, export

    /// Makes the device hold exactly its selection.
    func sync(_ device: Device) {
        let selection = selection(device.id)
        guard !selection.isEmpty else {
            model.errorMessage = "Choose what to sync to “\(device.name)” first."
            return
        }
        if device.isWireless {
            model.wireless.requestSync(Self.pairedId(device))
            job = Job(deviceId: device.id, title: "Syncing \(device.name)", phase: .waiting)
            return
        }
        run(on: device, title: "Syncing", mode: .sync) { db in try LibraryDatabase.deviceContents(db, selection) }
    }

    /// Songs or albums dropped on a device in the sidebar: they join what it holds (as if chosen on its page), and it
    /// syncs (a wireless one when its app next checks in).
    func add(_ items: [TrackTransfer], to device: Device) {
        let requests = items.flatMap { item in
            item.albumKey.map { [TransferRequest(id: UUID().uuidString, action: .add, kind: .album, key: $0)] }
                ?? item.ids.map { TransferRequest(id: UUID().uuidString, action: .add, kind: .song, key: String($0)) }
        }
        guard !requests.isEmpty else { return }
        let database = model.database
        let selection = selection(device.id).applying(requests) { kind, key in
            (try? database.writer.read { try LibraryDatabase.trackIds($0, of: kind, key: key) }) ?? []
        }
        setSelection(selection, for: device.id)
        if job?.isRunning == true, !device.isWireless {
            model.errorMessage = "Added to what “\(device.name)” holds. Sync it when the current copy has finished."
            return
        }
        sync(device)
    }

    /// Copies songs (and a playlist) to a device, without removing anything.
    func send(_ source: SendSource, to device: Device) {
        if device.isWireless {
            model.wireless.send(source, to: Self.pairedId(device))
            job = Job(deviceId: device.id, title: "Sending to \(device.name)",
                      phase: .finished("Queued: \(device.name) gets it at its next sync."))
            return
        }
        run(on: device, title: "Sending", mode: .send) { db in try source.contents(db) }
    }

    /// Copies songs to a folder (another player's folder, a card in a reader the app does not list).
    func export(_ source: SendSource) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose where to copy the songs. They are arranged in folders like on a player, with covers, lyrics and playlists."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folder = Device(id: "folder:" + url.path, name: url.lastPathComponent, root: url, capacity: 0,
                            available: Self.availableBytes(url), format: "", isFAT32: Self.fileSystemName(url) == "msdos")
        run(on: folder, title: "Exporting", mode: .send, root: url) { db in try source.contents(db) }
    }

    func cancel() {
        cancelFlag.isSet = true
        // A wireless sync not started yet is simply no longer asked for.
        if let job, job.phase == .waiting, let device = device(job.deviceId), device.isWireless {
            model.wireless.cancelRequest(Self.pairedId(device))
            self.job = nil
        }
    }

    func dismissJob() { if job?.isRunning == false { job = nil } }

    func eject(_ device: Device) {
        guard !device.isWireless, job?.isRunning != true || job?.deviceId != device.id else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: device.root)
        } catch {
            model.errorMessage = "Could not eject “\(device.name)”: \(error.localizedDescription)"
        }
    }

    private func run(on device: Device, title: String, mode: DeviceSync.Mode, root: URL? = nil,
                     contents: @escaping @Sendable (Database) throws -> (tracks: [Track], playlists: [DevicePlaylist])) {
        guard job?.isRunning != true else {
            model.errorMessage = "Wait for the current copy to finish first."
            return
        }
        guard let root = root ?? access(device, asking: true) else { return }
        _ = root.startAccessingSecurityScopedResource()
        let profile = device.id.hasPrefix("folder:") ? DeviceProfile() : profile(device.id)
        // Songs removed from the device stay off it, and their files go.
        let chosen = device.id.hasPrefix("folder:") ? DeviceSelection() : selection(device.id)
        let excluded = chosen.excludedTrackIds
        let formats = DeviceSync.Formats.of(chosen, fallback: profile.encoding)
        let database = model.database, artwork = model.artwork
        cancelFlag.isSet = false
        job = Job(deviceId: device.id, title: "\(title) to \(device.name)", phase: .planning)
        Task {
            defer { if device.id.hasPrefix("folder:") { root.stopAccessingSecurityScopedResource() } }
            do {
                let (tracks, playlists) = try await database.writer.read(contents)
                let manifest = DeviceManifest.read(from: root)
                let plan = await Task.detached(priority: .userInitiated) {
                    DeviceSync.plan(tracks: tracks, playlists: playlists, profile: profile, manifest: manifest, mode: mode, root: root,
                                    fat32: device.isFAT32, excluded: excluded, formats: formats) {
                        FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
                    }
                }.value
                // Room for the songs, with a little to spare for the card's own bookkeeping.
                let available = Self.availableBytes(root)
                if plan.netBytes > 0, available > 0, plan.netBytes > available - 32 * 1024 * 1024 {
                    let formatter = ByteCountFormatter()
                    job?.phase = .failed("Not enough space: \(formatter.string(fromByteCount: plan.netBytes)) needed, "
                                         + "\(formatter.string(fromByteCount: available)) free.")
                    return
                }
                job?.phase = .copying(done: 0, total: plan.writes.count)
                let progress = ProgressRelay { done, total in self.job?.phase = .copying(done: done, total: total) }
                let cancelled = cancelFlag
                _ = try await Task.detached(priority: .userInitiated) {
                    try DeviceSync.run(plan, root: root, profile: profile, manifest: manifest,
                                       cover: { artwork.jpeg(for: $0, maxPixels: $1) },
                                       progress: { progress.send($0, $1) }, isCancelled: { cancelled.isSet })
                }.value
                job?.phase = .finished(Self.summary(plan, cancelled: cancelFlag.isSet))
            } catch {
                job?.phase = .failed(error.localizedDescription)
            }
            refresh()
        }
    }

    private static func summary(_ plan: DeviceSyncPlan, cancelled: Bool) -> String {
        let formatter = ByteCountFormatter()
        var parts: [String] = []
        if cancelled { parts.append("Stopped.") }
        func files(_ count: Int) -> String { "\(count) \(count == 1 ? "file" : "files")" }
        if plan.isEmpty {
            parts.append("Already up to date.")
        } else {
            var changes: [String] = []
            if !plan.writes.isEmpty {
                changes.append("copied \(files(plan.writes.count)) (\(formatter.string(fromByteCount: plan.bytesToWrite)))")
            }
            if !plan.deletions.isEmpty { changes.append("removed \(files(plan.deletions.count))") }
            parts.append(changes.joined(separator: ", ").prefix(1).uppercased() + changes.joined(separator: ", ").dropFirst())
        }
        if !plan.skipped.isEmpty { parts.append("\(plan.skipped.count) left out (over 4 GB for FAT32)") }
        return parts.joined(separator: ". ") + (parts.last?.hasSuffix(".") == true ? "" : ".")
    }

    static func availableBytes(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity) ?? 0)
    }
}

/// What "Send to" copies: songs, an album, or a playlist (written as a playlist too).
enum SendSource: Sendable {
    case tracks([Track])
    case album(String)
    case playlist(Int64)
    case lovedSongs

    func contents(_ db: Database) throws -> (tracks: [Track], playlists: [DevicePlaylist]) {
        switch self {
        case .tracks(let tracks): return (tracks, [])
        case .album(let key): return (try LibraryDatabase.tracks(db, albumKey: key), [])
        case .playlist(let id):
            let tracks = try LibraryDatabase.tracks(db, playlistId: id)
            let name = try LibraryKit.Playlist.fetchOne(db, key: id)?.name ?? "Playlist"
            return (tracks, [DevicePlaylist(name: name, tracks: tracks)])
        case .lovedSongs:
            let tracks = try LibraryDatabase.lovedTracks(db)
            return (tracks, [DevicePlaylist(name: "Loved Songs", tracks: tracks)])
        }
    }
}

/// Hands copy progress from the background copy to the main actor.
private final class ProgressRelay: Sendable {
    private let handler: @MainActor @Sendable (Int, Int) -> Void

    init(_ handler: @escaping @MainActor @Sendable (Int, Int) -> Void) { self.handler = handler }

    func send(_ done: Int, _ total: Int) {
        Task { @MainActor in handler(done, total) }
    }
}

/// The Cancel button, read by the background copy.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

extension AppModel.SongSource {
    var sendSource: SendSource {
        switch self {
        case .album(let key): .album(key)
        case .playlist(let id): .playlist(id)
        case .lovedSongs: .lovedSongs
        }
    }
}
