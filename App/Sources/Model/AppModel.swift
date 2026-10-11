import AppKit
import Foundation
import LibraryKit
import Observation
import PlayerCore
import SwiftUI

enum SidebarItem: Hashable {
    case recentlyAdded
    case artists
    case albums
    case songs
    case genres
    case shelf
    case allPlaylists
    case lovedSongs
    case playlist(Int64)
}

/// App-wide state: library database, scanner, player and UI flags shared across windows.
@MainActor
@Observable
final class AppModel {
    let database: LibraryDatabase
    let artwork: ArtworkCache
    let player = PlaybackController()
    let equalizer: EqualizerStore
    let metadata: MetadataStore
    /// Set at the end of `init` (they need the model).
    private(set) var backup: BackupManager!
    private(set) var files: FilesStore!
    /// Library folders that could not be opened at the last scan (an unplugged drive, a moved folder).
    private(set) var unavailableFolders: Set<String> = []

    var selection: SidebarItem? = .albums {
        didSet { if selection != oldValue { path = [] } }
    }
    /// Pages pushed on the detail navigation stack.
    var path: [Route] = []

    enum Route: Hashable {
        case album(AlbumSummary)
        /// A musician, producer, songwriter or studio from the credits.
        case person(CreditPerson)
    }

    /// The pushed album pages (the common case; person pages are reached with `showPerson`).
    var albumPath: [AlbumSummary] {
        get { path.compactMap { if case let .album(album) = $0 { album } else { nil } } }
        set { path = newValue.map(Route.album) }
    }
    /// Artist selected on the Artists page (kept here so other pages can open an artist).
    var selectedArtist: String?
    /// Smart playlist editor sheet request (nil playlist creates a new one).
    var smartPlaylistEditor: SmartEditorRequest?

    struct SmartEditorRequest: Identifiable {
        let id = UUID()
        var playlist: Playlist?
    }

    /// All playlists, kept current for menus (menus cannot load data when they open).
    private(set) var playlists: [Playlist] = []
    var searchText = ""
    var isShowingNowPlaying = false
    /// What the right side panel shows, nil when it is closed.
    var sidePanel: SidePanel?

    enum SidePanel {
        case queue, lyrics
    }

    var isShowingQueue: Bool {
        get { sidePanel == .queue }
        set { sidePanel = newValue ? .queue : (sidePanel == .queue ? nil : sidePanel) }
    }

    var isShowingLyricsPanel: Bool {
        get { sidePanel == .lyrics }
        set { sidePanel = newValue ? .lyrics : (sidePanel == .lyrics ? nil : sidePanel) }
    }
    var isShowingLyrics = false
    var scanProgress: ScanProgress?
    var lastScanSummary: ScanSummary?
    var errorMessage: String?

    @ObservationIgnored private let scanner: LibraryScanner
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var rescanTask: Task<Void, Never>?
    @ObservationIgnored private let nowPlaying = NowPlayingCenter()

    static let volumeKey = "player.volume"

    init() {
        #if DEBUG
        // `-GLDebugResetPreferences YES` starts a debug run from clean preferences. Only in an unsandboxed debug build,
        // whose preferences are its own: the `defaults` tool resolves this bundle id to the installed app's container.
        if UserDefaults.standard.bool(forKey: "GLDebugResetPreferences"),
           ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil, let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        #endif
        let support = URL.applicationSupportDirectory.appendingPathComponent("Groovelight", isDirectory: true)
        do {
            database = try LibraryDatabase(url: support.appendingPathComponent("Library.sqlite"))
            artwork = try ArtworkCache(directory: support.appendingPathComponent("Artwork", isDirectory: true))
        } catch {
            fatalError("Could not open the library database: \(error)")
        }
        scanner = LibraryScanner(database: database, artwork: artwork)
        equalizer = EqualizerStore(player: player)
        // The volume of the last session.
        if let volume = UserDefaults.standard.object(forKey: Self.volumeKey) as? Float { player.volume = min(max(volume, 0), 1) }
        player.onVolumeChanged = { UserDefaults.standard.set($0, forKey: AppModel.volumeKey) }
        metadata = MetadataStore(database: database, artwork: artwork)

        player.onItemStarted = { [weak self] item in
            guard let self else { return }
            self.nowPlaying.update(item: item, artworkURL: item.artworkURL, player: self.player)
            self.prefetchLyrics(trackId: item.id)
        }
        player.onItemFinished = { [weak self] item, listened in
            self?.recordListen(item: item, seconds: listened)
        }
        nowPlaying.attach(to: player)
        ArtworkLoader.shared.cache = artwork

        backup = BackupManager(model: self)
        files = FilesStore(model: self)
        AppTheme.current.apply()
        restoreQueue()
        startSavingQueue()
        Task { await openLibraryRoots() }
        Task { [database] in
            do {
                for try await value in database.observe({ try LibraryDatabase.playlists($0) }) { self.playlists = value }
            } catch {}
        }
        #if DEBUG
        // Lets unsandboxed debug builds be pointed at a fixture library: `-GLDebugLibraryPath /path/to/music`.
        if let path = UserDefaults.standard.string(forKey: "GLDebugLibraryPath") {
            addLibraryFolder(URL(fileURLWithPath: path, isDirectory: true))
        }
        #endif
    }

    // MARK: - Library folders

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Folder"
        panel.message = "Choose a folder that contains your music."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addLibraryFolder(url)
    }

    func addLibraryFolder(_ url: URL) {
        do {
            let bookmark = try FolderAccess.makeBookmark(for: url)
            _ = url.startAccessingSecurityScopedResource()
            let root = try database.addRoot(path: url.standardizedFileURL.path, bookmark: bookmark)
            Task {
                await scan(root)
                await watchRoots()
            }
        } catch {
            errorMessage = "Could not add folder: \(error.localizedDescription)"
        }
    }

    func removeRoot(_ root: LibraryRoot) {
        guard let id = root.id else { return }
        do {
            try database.removeRoot(id)
            Task { await watchRoots() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rescanAll() {
        Task {
            for root in (try? await roots()) ?? [] { await scan(root) }
        }
    }

    /// Rescans every library folder and returns when done (after an import).
    func rescanAndWait() async {
        for root in (try? await roots()) ?? [] { await scan(root) }
    }

    private func roots() async throws -> [LibraryRoot] {
        try await database.writer.read { try LibraryDatabase.roots($0) }
    }

    private func openLibraryRoots() async {
        guard let roots = try? await roots() else { return }
        for root in roots {
            do {
                let access = try FolderAccess.startAccessing(root.bookmark)
                if let refreshed = access.refreshedBookmark {
                    _ = try? database.addRoot(path: root.path, bookmark: refreshed)
                }
            } catch {
                // Restored from another Mac, or the folder moved: Settings, Library offers to locate it.
                unavailableFolders.insert(root.path)
                continue
            }
        }
        for root in roots { await scan(root) }
        await watchRoots()
    }

    private func scan(_ root: LibraryRoot) async {
        scanProgress = ScanProgress(filesFound: 0, filesProcessed: 0)
        unavailableFolders.remove(root.path)
        do {
            let summary = try await scanner.scan(root: root) { [weak self] progress in
                Task { @MainActor in
                    guard self?.scanProgress != nil else { return }
                    self?.scanProgress = progress
                }
            }
            lastScanSummary = summary
        } catch LibraryScanner.ScanError.folderUnavailable(let path) {
            // Not an error worth an alert: the folder's songs and their history are kept until it is back.
            unavailableFolders.insert(path)
        } catch {
            errorMessage = "Scan failed: \(error.localizedDescription)"
        }
        scanProgress = nil
    }

    /// After a restore: reopen each library folder from its bookmark (works on the same Mac); folders that cannot be
    /// opened (another Mac, moved music) are listed for the user to locate. Then rescans what is available.
    func reopenLibraryAfterRestore() async {
        guard let roots = try? await roots() else { return }
        var missing: [LibraryRoot] = []
        for root in roots {
            guard let id = root.id, let access = try? FolderAccess.startAccessing(root.bookmark),
                  FileManager.default.fileExists(atPath: access.url.path) else {
                missing.append(root)
                continue
            }
            // The bookmark may point somewhere else now (the folder was moved or renamed): follow it.
            let resolved = access.url.standardizedFileURL.path
            if resolved != root.path || access.refreshedBookmark != nil {
                _ = try? database.relocateRoot(id, to: resolved, bookmark: access.refreshedBookmark ?? root.bookmark)
            }
        }
        backup.foldersToLocate = missing
        for root in (try? await self.roots()) ?? [] where !missing.contains(where: { $0.id == root.id }) {
            await scan(root)
        }
        await watchRoots()
    }

    private func watchRoots() async {
        let paths = ((try? await roots()) ?? []).map(\.path)
        if watcher == nil {
            watcher = FolderWatcher { [weak self] _ in
                Task { @MainActor in self?.scheduleRescan() }
            }
        }
        watcher?.watch(paths)
    }

    /// Debounces bursts of file system events (copying an album) into one incremental rescan.
    private func scheduleRescan() {
        rescanTask?.cancel()
        rescanTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, scanProgress == nil else { return }
            for root in (try? await roots()) ?? [] { await scan(root) }
        }
    }

    // MARK: - Queue across launches

    static let queueKey = "player.queue"
    static let positionKey = "player.position"

    /// The queue and song of the last session, paused where it was (Play resumes there).
    private func restoreQueue() {
        guard let data = UserDefaults.standard.data(forKey: Self.queueKey),
              let snapshot = try? JSONDecoder().decode(PlayQueue.Snapshot.self, from: data) else { return }
        let tracks = (try? database.writer.read { db in try Track.fetchAll(db, keys: Array(Set(snapshot.itemIds))) }) ?? []
        let items = Dictionary(tracks.compactMap { track in track.id.map { ($0, playableItem(for: track)) } }, uniquingKeysWith: { first, _ in first })
        player.restore(snapshot, items: items, position: UserDefaults.standard.double(forKey: Self.positionKey))
    }

    /// Saves the queue when it changes and the position every few seconds, and once more when the app quits.
    private func startSavingQueue() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                self?.saveQueue()
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveQueue() }
        }
    }

    @ObservationIgnored private var savedQueue: PlayQueue.Snapshot?

    func saveQueue() {
        let defaults = UserDefaults.standard
        let queue = player.queue
        guard queue.current != nil else {
            if savedQueue != nil || defaults.data(forKey: Self.queueKey) != nil {
                defaults.removeObject(forKey: Self.queueKey)
                defaults.removeObject(forKey: Self.positionKey)
                savedQueue = nil
            }
            return
        }
        let snapshot = queue.snapshot
        if snapshot != savedQueue, let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.queueKey)
            savedQueue = snapshot
        }
        defaults.set(player.currentTime, forKey: Self.positionKey)
    }

    // MARK: - Playback

    func playableItem(for track: Track) -> PlayableItem {
        PlayableItem(id: track.id ?? 0, url: track.url, title: track.title, artist: track.displayArtist,
                     album: track.displayAlbum, duration: track.duration,
                     artworkURL: track.artworkHash.map { artwork.url(for: $0, size: .large) },
                     // A cue track plays only its range of the shared audio file.
                     startTime: track.startTime, endTime: track.endTime, sampleRate: track.sampleRate)
    }

    func play(_ tracks: [Track], startAt index: Int = 0, shuffle: Bool = false) {
        guard !tracks.isEmpty else { return }
        player.play(tracks.map(playableItem), startAt: index, shuffle: shuffle)
    }

    func playNext(_ tracks: [Track]) {
        player.playNext(tracks.map(playableItem))
    }

    /// Adds songs to the end of Up Next.
    func addToUpNext(_ tracks: [Track]) {
        player.playLater(tracks.map(playableItem))
    }

    /// A group of songs that menus can play or queue.
    enum SongSource {
        case album(String)
        case playlist(Int64)
        case lovedSongs
    }

    func tracks(of source: SongSource) async -> [Track] {
        (try? await database.writer.read { db in
            switch source {
            case .album(let key): try LibraryDatabase.tracks(db, albumKey: key)
            case .playlist(let id): try LibraryDatabase.tracks(db, playlistId: id)
            case .lovedSongs: try LibraryDatabase.lovedTracks(db)
            }
        }) ?? []
    }

    /// Queues an album or playlist right after the current song (`next`) or at the end of Up Next.
    func enqueue(_ source: SongSource, next: Bool) {
        Task {
            let tracks = await tracks(of: source)
            if next { playNext(tracks) } else { addToUpNext(tracks) }
        }
    }

    func playAlbum(_ album: AlbumSummary, shuffle: Bool = false) {
        Task {
            do {
                let tracks = try await database.writer.read { try LibraryDatabase.tracks($0, albumKey: album.albumKey) }
                play(tracks, shuffle: shuffle)
            } catch {
                errorMessage = "Could not load \(album.title): \(error.localizedDescription)"
            }
        }
    }

    func currentTrack() async -> Track? {
        guard let id = player.current?.id else { return nil }
        return try? await database.writer.read { try Track.fetchOne($0, key: id) }
    }

    /// Looks up lyrics online as soon as a song starts, so they are ready when the lyrics panel opens.
    private func prefetchLyrics(trackId: Int64) {
        Task {
            guard let track = try? await database.writer.read({ try Track.fetchOne($0, key: trackId) }) else { return }
            await metadata.ensureLyrics(for: track)
        }
    }

    /// Switches to the Artists page with `name` selected.
    func showArtist(_ name: String) {
        searchText = ""
        selectedArtist = name
        selection = .artists
    }

    /// Opens the page of a person from the credits (what they did in the library), on top of the current page.
    func showPerson(_ person: CreditPerson) {
        isShowingNowPlaying = false
        path.append(.person(person))
    }

    /// Creates a playlist of songs (e.g. everything a person is credited on) with a generated cover showing its name,
    /// and opens it.
    func createPlaylist(named name: String, tracks: [Track]) {
        do {
            var cover = PlaylistCover.randomGenerated()
            cover.showsTitle = true
            let playlist = try database.createPlaylist(named: name, trackIds: tracks.compactMap(\.id), cover: cover)
            if let id = playlist.id { selection = .playlist(id) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Opens an album's page on top of the current section.
    func showAlbum(albumKey: String) {
        Task {
            guard let album = try? await database.writer.read({ db in
                try LibraryDatabase.albums(db).first { $0.albumKey == albumKey }
            }) else { return }
            if !albumPath.isEmpty {
                // Replacing the pushed page in place leaves a stale page; going back first, then pushing, works.
                albumPath = []
                try? await Task.sleep(for: .milliseconds(350))
            }
            albumPath = [album]
        }
    }

    /// Opens the album page of a track (after its album changed, the old page would be empty).
    func showAlbum(containing trackId: Int64?) async {
        guard !albumPath.isEmpty, let trackId,
              let album = try? await database.writer.read({ db -> AlbumSummary? in
                  guard let track = try Track.fetchOne(db, key: trackId) else { return nil }
                  return try LibraryDatabase.albums(db).first { $0.albumKey == track.albumKey }
              }) else { return }
        // Replacing the pushed page in place leaves a stale page; going back first, then pushing, works.
        albumPath = []
        try? await Task.sleep(for: .milliseconds(350))
        albumPath = [album]
    }

    /// Plays count when at least half the track (or 4 minutes) was heard; early skips count as skips.
    private func recordListen(item: PlayableItem, seconds: TimeInterval) {
        let threshold = min(item.duration * 0.5, 240)
        if seconds >= threshold, item.duration > 0 {
            try? database.recordPlay(trackId: item.id)
        } else if seconds < min(20, item.duration * 0.5) {
            try? database.recordSkip(trackId: item.id)
        }
    }

    func toggleLoved(_ track: Track) {
        guard let id = track.id else { return }
        try? database.setLoved(!track.isLoved, trackId: id)
    }

    // MARK: - Playlists

    func newPlaylist(with tracks: [Track] = []) {
        do {
            let playlist = try database.createPlaylist(named: "Untitled Playlist", trackIds: tracks.compactMap(\.id),
                                                       cover: .randomGenerated())
            if let id = playlist.id { selection = .playlist(id) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Edit Playlist sheet (name and cover).
    var playlistEditor: PlaylistEditRequest?

    struct PlaylistEditRequest: Identifiable {
        let id = UUID()
        var playlist: Playlist
    }

    /// Get Info sheet (manual tag editor) for one or more songs.
    var infoEditor: InfoRequest?

    struct InfoRequest: Identifiable {
        let id = UUID()
        var tracks: [Track]
    }

    func getInfo(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        infoEditor = InfoRequest(tracks: tracks)
    }

    /// Song credits sheet.
    var creditsTrack: Track?

    func getInfo(albumKey: String) {
        Task { getInfo(await tracks(of: .album(albumKey))) }
    }

    func editPlaylist(_ playlist: Playlist) {
        playlistEditor = PlaylistEditRequest(playlist: playlist)
    }

    func newSmartPlaylist() {
        smartPlaylistEditor = SmartEditorRequest(playlist: nil)
    }

    func editSmartPlaylist(_ playlist: Playlist) {
        smartPlaylistEditor = SmartEditorRequest(playlist: playlist)
    }

    func playPlaylist(_ id: Int64, shuffle: Bool = false) {
        Task {
            let tracks = (try? await database.writer.read { try LibraryDatabase.tracks($0, playlistId: id) }) ?? []
            play(tracks, shuffle: shuffle)
        }
    }

    func deletePlaylist(_ id: Int64) {
        try? database.deletePlaylist(id)
        if selection == .playlist(id) { selection = .allPlaylists }
    }

    /// Loves songs (dropping them on Loved Songs).
    func love(trackIds: [Int64]) {
        try? database.setLoved(true, trackIds: trackIds)
    }

    func add(_ tracks: [Track], to playlist: Playlist) {
        guard let id = playlist.id else { return }
        try? database.addTracks(tracks.compactMap(\.id), toPlaylist: id)
    }

    func showInFinder(_ tracks: [Track]) {
        NSWorkspace.shared.activateFileViewerSelecting(tracks.map(\.url))
    }
}
