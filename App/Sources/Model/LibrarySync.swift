import AppKit
import LibraryKit
import Observation

/// Keeps the library in step with its folders, actively:
/// - Watches them and rescans only the folders that changed, never dropping a change that comes in during a scan.
/// - At launch, catches up on what changed while the app was closed from the file system's event history, instead of
///   checking every file (a full check runs when that history cannot be used).
/// - Notices drives being plugged in or out, checks network folders (which report no changes) on a timer, checks
///   everything after waking from sleep or a day without a full check, and checks a song's folder when its file is gone.
@MainActor @Observable
final class LibrarySync {
    /// A short note about what the last quiet update changed ("Added 3 songs"), shown for a few seconds.
    private(set) var note: String?
    /// Library folders on network volumes, checked on a timer.
    private(set) var networkFolders: Set<String> = []

    /// How often network folders are checked, and how old a full check may get before another one.
    static let networkInterval: TimeInterval = 10 * 60
    static let fullCheckInterval: TimeInterval = 24 * 60 * 60
    static let wakeCheckInterval: TimeInterval = 6 * 60 * 60

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private let scanner: LibraryScanner
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var changes = LibraryChanges(roots: [])
    /// Library folders whose next scan shows progress (first scan of a new folder, Rescan Now).
    @ObservationIgnored private var loudRoots = Set<Int64>()
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var noteTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Event id each folder's changes are saved up to (mirrors the database, to avoid writes that change nothing).
    @ObservationIgnored private var savedEventIds: [Int64: UInt64] = [:]
    @ObservationIgnored private var lastNetworkCheck: [Int64: Date] = [:]
    /// What the scans did, for the debug tour.
    @ObservationIgnored private(set) var activity: [String] = []

    init(model: AppModel, scanner: LibraryScanner) {
        self.model = model
        self.scanner = scanner
    }

    // MARK: - Starting

    /// At launch (library folders already opened): catches up on changes, then watches.
    func start() async {
        let roots = await availableRoots()
        var since: UInt64?
        for root in roots {
            guard let id = root.id else { continue }
            let isLocal = FolderWatcher.isLocalVolume(root.path)
            let canReplay = isLocal && root.eventId != nil && root.eventsVolumeId == FolderWatcher.historyId(for: root.path)
                && root.lastFullScanAt.map { Date.now.timeIntervalSince($0) < Self.fullCheckInterval } == true
            if canReplay, let eventId = root.eventId {
                let saved = UInt64(bitPattern: eventId)
                savedEventIds[id] = saved
                since = min(since ?? saved, saved)
                log("replay \(root.path) since \(saved)")
            } else {
                if root.lastScanAt == nil { loudRoots.insert(id) }
                changes.addFull(rootId: id)
                log("full check \(root.path) (\(isLocal ? "no usable history" : "network folder"))")
            }
        }
        await watch(roots, since: since)
        kick()
        observeSystem()
        startTimer()
    }

    /// After folders were added, removed or relocated: watches the current set (new ones get a full scan first).
    func foldersChanged(newRootId: Int64? = nil) async {
        if let newRootId {
            loudRoots.insert(newRootId)
            changes.roots = (await availableRoots()).compactMap { root in root.id.map { ($0, root.path) } }
            changes.addFull(rootId: newRootId)
        }
        await watch(await availableRoots(), since: nil)
        kick()
    }

    // MARK: - Requests

    /// Checks every file of every folder now (Rescan Now: with progress).
    func checkEverything(loud: Bool) {
        Task {
            for root in await availableRoots() {
                guard let id = root.id else { continue }
                if loud { loudRoots.insert(id) }
                changes.addFull(rootId: id)
            }
            kick()
        }
    }

    /// Checks every folder and returns when done (after organizing or importing files).
    func checkEverythingAndWait() async {
        for root in await availableRoots() {
            guard let id = root.id else { continue }
            await scan(rootId: id, scope: .full)
        }
    }

    /// Checks the folder of a song whose file could not be opened.
    func checkFolder(of url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        log("missing file \(url.path)")
        changes.addFolder(url.deletingLastPathComponent().path)
        kick()
    }

    // MARK: - Watching

    private func watch(_ roots: [LibraryRoot], since: UInt64?) async {
        changes.roots = roots.compactMap { root in root.id.map { ($0, root.path) } }
        networkFolders = Set(roots.filter { !FolderWatcher.isLocalVolume($0.path) }.map(\.path))
        let local = roots.map(\.path).filter { !networkFolders.contains($0) }
        if watcher == nil {
            watcher = FolderWatcher { [weak self] events in
                Task { @MainActor in self?.received(events) }
            }
        }
        watcher?.watch(local, since: since)
    }

    private func received(_ events: [FolderEvent]) {
        #if DEBUG
        log("events: " + events.prefix(4).map { "\($0.path) [\($0.flags.rawValue)]" }.joined(separator: ", ") + (events.count > 4 ? " +\(events.count - 4)" : ""))
        #endif
        changes.add(events, audioExtensions: TagReader.supportedExtensions)
        if events.contains(where: { $0.flags.contains(.historyDone) }) { log("history replayed") }
        kick()
    }

    /// Runs the waiting work, and whatever comes in meanwhile, until nothing is left.
    private func kick() {
        guard drainTask == nil, !changes.isEmpty else { return }
        drainTask = Task {
            // A moment for a burst of events (copying an album) to arrive together.
            try? await Task.sleep(for: .milliseconds(500))
            var total = ScanSummary()
            while !changes.isEmpty {
                let upTo = changes.latestEventId
                for (rootId, scope) in changes.take() {
                    if let summary = await scan(rootId: rootId, scope: scope) {
                        total.added += summary.added
                        total.updated += summary.updated
                        total.removed += summary.removed
                    }
                }
                if let upTo { await saveEventId(upTo) }
            }
            drainTask = nil
            show(total)
            // Anything that came in after the last check (there is no suspension between it and here, but be sure).
            if !changes.isEmpty { kick() }
        }
    }

    /// Scans one folder; returns nil when it failed or the folder is unavailable.
    @discardableResult
    private func scan(rootId: Int64, scope: ScanScope) async -> ScanSummary? {
        guard let root = try? await model.database.writer.read({ try LibraryRoot.fetchOne($0, key: rootId) }) else { return nil }
        let loud = loudRoots.remove(rootId) != nil && scope == .full
        // A full check covers every change before it: its folder's history can start from here.
        let startId = FolderWatcher.currentEventId
        if loud { model.scanProgress = ScanProgress(filesFound: 0, filesProcessed: 0) }
        model.unavailableFolders.remove(root.path)
        defer { if loud { model.scanProgress = nil } }
        do {
            let summary = try await scanner.scan(root: root, scope: scope) { [weak model] progress in
                guard loud else { return }
                Task { @MainActor in
                    guard model?.scanProgress != nil else { return }
                    model?.scanProgress = progress
                }
            }
            log("scanned \(root.path) \(describe(scope)): +\(summary.added) ~\(summary.updated) -\(summary.removed)")
            if scope == .full {
                model.lastScanSummary = summary
                lastNetworkCheck[rootId] = .now
                if FolderWatcher.isLocalVolume(root.path) {
                    try? model.database.setWatchState(rootId: rootId, eventId: startId, volumeId: FolderWatcher.historyId(for: root.path))
                    savedEventIds[rootId] = startId
                }
            }
            return summary
        } catch LibraryScanner.ScanError.folderUnavailable(let path) {
            // Unplugged or moved: its songs and their history are kept until it is back.
            model.unavailableFolders.insert(path)
            log("unavailable \(path)")
        } catch {
            model.errorMessage = "Scan failed: \(error.localizedDescription)"
        }
        return nil
    }

    /// Records that every watched local folder's changes are in the library up to `eventId`.
    private func saveEventId(_ eventId: UInt64) async {
        for root in await availableRoots() where !networkFolders.contains(root.path) {
            guard let id = root.id, eventId > (savedEventIds[id] ?? 0) else { continue }
            try? model.database.setWatchState(rootId: id, eventId: eventId, volumeId: FolderWatcher.historyId(for: root.path))
            savedEventIds[id] = eventId
        }
    }

    // MARK: - Drives, sleep and timers

    private func observeSystem() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.volumesChanged(mounted: true) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.volumesChanged(mounted: false) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.didWake() }
        })
    }

    /// A drive came or went: folders that are back get a full check, and the watched set follows.
    private func volumesChanged(mounted: Bool) async {
        let all = (try? await model.database.writer.read { try LibraryDatabase.roots($0) }) ?? []
        if mounted {
            for root in all where model.unavailableFolders.contains(root.path) {
                guard let id = root.id, (try? FolderAccess.startAccessing(root.bookmark)) != nil,
                      FileManager.default.fileExists(atPath: root.path) else { continue }
                log("back: \(root.path)")
                model.unavailableFolders.remove(root.path)
                changes.addFull(rootId: id)
            }
        } else {
            for root in all where !FileManager.default.fileExists(atPath: root.path) {
                log("gone: \(root.path)")
                model.unavailableFolders.insert(root.path)
            }
        }
        await watch(await availableRoots(), since: nil)
        kick()
    }

    private func didWake() async {
        for root in await availableRoots() {
            guard let id = root.id else { continue }
            let stale = root.lastFullScanAt.map { Date.now.timeIntervalSince($0) > Self.wakeCheckInterval } ?? true
            if stale || networkFolders.contains(root.path) {
                log("after sleep: \(root.path)")
                changes.addFull(rootId: id)
            }
        }
        kick()
    }

    /// Every minute: network folders due for a check, and folders without a full check for a day.
    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.timerFired()
            }
        }
    }

    private func timerFired() async {
        for root in await availableRoots() {
            guard let id = root.id else { continue }
            let isNetwork = networkFolders.contains(root.path)
            let networkDue = isNetwork && Date.now.timeIntervalSince(lastNetworkCheck[id] ?? .distantPast) > Self.networkInterval
            let fullDue = root.lastFullScanAt.map { Date.now.timeIntervalSince($0) > Self.fullCheckInterval } ?? true
            if networkDue || fullDue {
                log("timer: \(root.path)")
                changes.addFull(rootId: id)
            }
        }
        kick()
    }

    // MARK: - Helpers

    private func availableRoots() async -> [LibraryRoot] {
        let roots = (try? await model.database.writer.read { try LibraryDatabase.roots($0) }) ?? []
        return roots.filter { !model.unavailableFolders.contains($0.path) }
    }

    /// Shows what a quiet update changed for a few seconds.
    private func show(_ summary: ScanSummary) {
        var parts: [String] = []
        func count(_ n: Int, _ verb: String) { if n > 0 { parts.append("\(verb) \(n) \(n == 1 ? "song" : "songs")") } }
        count(summary.added, "Added")
        count(summary.updated, "Updated")
        count(summary.removed, "Removed")
        guard !parts.isEmpty else { return }
        note = parts.joined(separator: ", ")
        noteTask?.cancel()
        noteTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            note = nil
        }
    }

    private func describe(_ scope: ScanScope) -> String {
        switch scope {
        case .full: "(all)"
        case .folders(let folders, let artwork): "(\(folders.count) folders\(artwork.isEmpty ? "" : ", \(artwork.count) new covers"))"
        }
    }

    private func log(_ line: String) {
        activity.append(line)
        if activity.count > 200 { activity.removeFirst(activity.count - 200) }
    }
}
