import Foundation
import LibraryKit
import MetadataKit
import Observation
import PlayerCore
import WirelessSync

/// What the screens share: the library on the device, the Mac it syncs with, and the player.
@MainActor
@Observable
final class AppModel {
    let library: LibraryStore
    let sync: SyncStore
    let player: PlayerStore
    let remote: RemoteStore
    /// The Mac's whole library, to bring music here.
    let catalog: CatalogStore
    /// Other devices playing music here, through the Mac.
    let relay = RelayReceiver()
    /// The window last in front (what each window shows is its own `WindowModel`).
    @ObservationIgnored weak var activeWindow: WindowModel?

    /// Where music plays: this device, the paired Mac, or another device through the Mac (their player, controlled from
    /// here).
    enum Target: Equatable {
        case thisDevice
        case mac
        case device(WirelessProtocol.RemoteDevice)

        /// The Mac's id (nil) or the device's, as the remote store takes it.
        var deviceId: String? {
            if case .device(let device) = self { return device.id }
            return nil
        }
    }

    private(set) var target = Target.thisDevice

    /// Music plays elsewhere, controlled from here.
    var isRemote: Bool { target != .thisDevice }

    /// Where music plays, by name: "MacBook Air", "Pixel 9".
    var targetName: String {
        switch target {
        case .thisDevice: "This Device"
        case .mac: remote.macName ?? "Mac"
        case .device(let device): device.name
        }
    }

    init() {
        let folders = AppFolders()
        library = LibraryStore(folders: folders)
        sync = SyncStore(library: library)
        player = PlayerStore(library: library)
        remote = RemoteStore(sync: sync)
        catalog = CatalogStore(library: library, sync: sync, folders: folders)
        // A song playing elsewhere that is not here shows the Mac library's cover on the lock screen too.
        player.coverElsewhere = { [catalog] in catalog.cachedCoverURL($0) }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "GLDebugNowPlaying") { debugSample = .sample }
        #endif
        player.remoteRoute = PlayerStore.RemoteRoute(
            play: { [weak self] in self?.remote.send(.resume) },
            pause: { [weak self] in self?.remote.send(.pause) },
            next: { [weak self] in self?.remote.send(.next) },
            previous: { [weak self] in self?.remote.send(.previous) },
            seek: { [weak self] in self?.remote.send(.seek($0)) })
        showElsewhere()
    }

    /// The lock screen follows the music where it plays (the Mac, another device) while the app runs.
    private func showElsewhere() {
        withObservationTracking {
            player.elsewhere = isRemote ? remoteNowPlaying.map { item in
                PlayerStore.Elsewhere(title: item.title, artist: item.artist, album: "\(item.album) · \(targetName)",
                                      artworkHash: item.artworkHash, duration: duration, position: time(at: .now), playing: item.isPlaying)
            } : nil
        } onChange: { [weak self] in
            Task { @MainActor in self?.showElsewhere() }
        }
    }

    /// The song playing where music plays (a sample with `-GLDebugNowPlaying YES` when nothing plays, to check layouts).
    var nowPlaying: NowPlayingItem? {
        switch target {
        case .thisDevice: player.nowPlaying ?? debugSample
        case .mac, .device: remoteNowPlaying
        }
    }

    /// The song where music plays, with its love and lyrics from this device's library when the song is here too.
    private var remoteNowPlaying: NowPlayingItem? {
        guard let state = remote.state, let item = state.item else { return nil }
        let track = library.read { try LibraryDatabase.track($0, id: item.id) } ?? nil
        return NowPlayingItem(id: item.id, title: item.title, artist: item.artist, album: item.album, albumKey: item.albumKey,
                              artworkHash: item.artworkHash ?? track?.artworkHash, isPlaying: state.playing, isLoved: track?.isLoved ?? false,
                              lyrics: SyncedLyrics(parsing: track?.lyrics ?? ""), spec: track?.audioSpec)
    }

    // MARK: - Playing, here or elsewhere

    func play(_ tracks: [Track], startAt index: Int = 0, shuffle: Bool = false) {
        switch target {
        case .thisDevice: player.play(tracks, startAt: index, shuffle: shuffle)
        case .mac, .device: remote.send(.play(songIds: tracks.compactMap(\.id), startAt: index, position: 0, shuffle: shuffle))
        }
    }

    /// Whether the Mac plays: it has every song of its library, here or not.
    var playsOnMac: Bool { target == .mac }

    /// Songs of the Mac's library, by its ids, on the Mac (which has them all, here or not); only when it plays.
    func playOnMac(_ songIds: [Int64], startAt index: Int = 0, shuffle: Bool = false) {
        guard playsOnMac, !songIds.isEmpty else { return }
        remote.send(.play(songIds: songIds, startAt: index, position: 0, shuffle: shuffle))
    }

    func togglePlayPause() {
        switch target {
        case .thisDevice: player.togglePlayPause()
        case .mac, .device: remote.send(remote.state?.playing == true ? .pause : .resume)
        }
    }

    func next() {
        isRemote ? remote.send(.next) : player.next()
    }

    func previous() {
        isRemote ? remote.send(.previous) : player.previous()
    }

    func seek(to time: TimeInterval) {
        isRemote ? remote.send(.seek(time)) : player.seek(to: time)
    }

    var isShuffled: Bool {
        isRemote ? remote.state?.shuffle == true : player.controller.isShuffled
    }

    var repeatMode: RepeatMode {
        isRemote ? RepeatMode(rawValue: remote.state?.repeatMode ?? "off") ?? .off : player.controller.repeatMode
    }

    func toggleShuffle() {
        isRemote ? remote.send(.shuffle(!isShuffled)) : player.controller.setShuffle(!isShuffled)
    }

    /// Off, then the whole queue, then the song, as on the Mac.
    func cycleRepeat() {
        let next: RepeatMode = switch repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
        isRemote ? remote.send(.repeatMode(next.rawValue)) : (player.controller.repeatMode = next)
    }

    /// The page of the album playing: here, or on the Mac when it is not here. Nil when neither has it.
    func albumRoute(of item: NowPlayingItem) -> LibraryRoute? {
        guard let key = item.albumKey ?? (library.read { try LibraryDatabase.track($0, id: item.id) } ?? nil)?.albumKey else { return nil }
        if catalog.isHere(album: key) { return .album(key) }
        return catalog.album(key) != nil ? .macAlbum(key) : nil
    }

    /// The page of the artist playing: the album's artist (the song's own on a compilation), here or on the Mac.
    func artistRoute(of item: NowPlayingItem) -> LibraryRoute? {
        let key = item.albumKey ?? (library.read { try LibraryDatabase.track($0, id: item.id) } ?? nil)?.albumKey
        let album = key.flatMap { catalog.album($0) }
        let name = album.flatMap { $0.isCompilation || $0.artist == "Various Artists" ? nil : $0.artist } ?? item.artist
        if catalog.isHere(artist: name) { return .artist(name) }
        return catalog.artists.contains { $0.name == name } ? .macArtist(name) : nil
    }

    func toggleLove() {
        guard let item = nowPlaying, item.id >= 0 else { return }
        library.setLoved(!item.isLoved, trackId: item.id)
    }

    /// Where the song is at `date`, and how long it is.
    func time(at date: Date) -> TimeInterval {
        isRemote ? remote.estimatedTime(at: date) : player.controller.estimatedTime(at: date)
    }

    var duration: TimeInterval {
        isRemote ? remote.state?.item?.duration ?? 0 : player.controller.duration
    }

    /// The song playing where music plays, for marking it in lists.
    var currentSongId: Int64? {
        isRemote ? remote.state?.item?.id : player.controller.current?.id
    }

    /// Moves playback: what plays where music plays now goes on on the chosen one at the same place, and stops where it
    /// was. Songs a phone does not have are left out of a queue that comes to it.
    func choose(_ newTarget: Target) async {
        guard newTarget != target else { return }
        let from = target
        if newTarget == .thisDevice {
            await takeBack()
            return
        }
        switch from {
        case .thisDevice:
            let controller = player.controller
            remote.use(newTarget.deviceId)
            if controller.state == .playing, let index = controller.queue.currentIndex {
                let ids = controller.queue.items.map(\.id)
                let position = controller.estimatedTime(at: .now)
                // Quiet here first: both playing the same song a moment apart sounds broken.
                controller.pause()
                do {
                    try await remote.sendAndWait(.play(songIds: ids, startAt: index, position: position, shuffle: false))
                } catch {
                    RemoteStore.log.error("Handing over failed: \(String(describing: error), privacy: .public)")
                    controller.resume()
                    remote.use(from.deviceId)
                    return
                }
            }
        case .mac, .device:
            // From one place to another: the queue goes on there, then stops here.
            let state = remote.state
            let position = remote.estimatedTime(at: .now)
            remote.use(newTarget.deviceId)
            if let state, state.playing, let index = state.queueIndex {
                do {
                    try await remote.sendAndWait(.play(songIds: state.queue, startAt: index, position: position, shuffle: false))
                    remote.send(.pause, to: from.deviceId)
                } catch {
                    RemoteStore.log.error("Handing over failed: \(String(describing: error), privacy: .public)")
                    remote.use(from.deviceId)
                    remote.follow()
                    return
                }
            }
        }
        target = newTarget
        remote.follow()
    }

    /// A command from another device (through the Mac) for the player here. A queue it sends plays here, even while
    /// this device was playing elsewhere; songs not on this device are left out.
    func applyRelayed(_ command: WirelessProtocol.RemoteCommand) {
        let controller = player.controller
        switch command {
        case let .play(ids, startAt, position, shuffle):
            let found = library.read { db in try ids.map { try LibraryDatabase.track(db, id: $0) } } ?? []
            let tracks = found.compactMap { $0 }
            guard !tracks.isEmpty else { return }
            // The song asked for, or the next one here; its position only when it is that song.
            let wanted = found.indices.contains(startAt) ? found[startAt] : nil
            let start = found.indices.contains(startAt) ? found[startAt...].compactMap { $0 }.first.flatMap { first in
                tracks.firstIndex { $0.id == first.id }
            } ?? 0 : 0
            if isRemote {
                remote.stopFollowing()
                target = .thisDevice
            }
            player.play(tracks, startAt: start, shuffle: shuffle, position: wanted != nil ? position : 0)
        case .pause: controller.pause()
        case .resume: if controller.state != .playing { player.togglePlayPause() }
        case .next: player.next()
        case .previous: player.previous()
        case .seek(let time): player.seek(to: time)
        // The device's own volume buttons set the level here.
        case .volume: break
        case .shuffle(let on): controller.setShuffle(on)
        case .repeatMode(let mode): if let mode = RepeatMode(rawValue: mode) { controller.repeatMode = mode }
        case .stop: controller.stop()
        }
    }

    /// The queue where music plays comes here (the songs this device has), at the same place, and stops there.
    private func takeBack() async {
        guard let state = remote.state, let item = state.item else {
            remote.stopFollowing()
            target = .thisDevice
            return
        }
        let tracks = library.read { db in try state.queue.compactMap { try LibraryDatabase.track(db, id: $0) } } ?? []
        // Another song with that id (not synced since the Mac's library changed): the music stays where it is.
        guard let start = tracks.firstIndex(where: { $0.id == item.id }), tracks[start].title == item.title else { return }
        remote.stopFollowing()
        target = .thisDevice
        if state.playing { remote.send(.pause) }
        player.play(tracks, startAt: start, position: remote.estimatedTime(at: .now), paused: !state.playing)
    }

    @ObservationIgnored private var debugSample: NowPlayingItem?

    /// Starts watching the library, and syncs when the Mac asks (or `-GLDebugMacAddress` pairs with a Mac first).
    func start() async {
        await library.start()
        await sync.start(model: self)
        // Asked now, before any music: the first time the app reaches the Mac (its keychain item, the network) the
        // system loads what that needs, holding everything up for about a second, enough to break the sound. It also
        // has Play On know where the Mac is when it opens.
        if sync.isPaired { Task { await remote.check() } }
        relay.start(model: self)
        sync.sendHistory()
        #if DEBUG
        // `-GLDebugPlaylistEdits YES`: makes "Road Trip" here from the first album's songs, takes one out, adds it back,
        // renames it "Road Trip 2", then syncs (the Mac's tour should then have the playlist).
        if UserDefaults.standard.bool(forKey: "GLDebugPlaylistEdits") {
            for _ in 0..<40 where library.contents.albums.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
        }
        if UserDefaults.standard.bool(forKey: "GLDebugPlaylistEdits"), let album = library.contents.albums.first {
            let ids = (library.read { try LibraryDatabase.tracks($0, albumKey: album.albumKey) } ?? []).compactMap(\.id)
            if let id = library.createPlaylist(named: "Road Trip", trackIds: ids) {
                library.removeFromPlaylist(id, trackIds: [ids[0]])
                library.addToPlaylist(id, trackIds: [ids[0]])
                library.renamePlaylist(id, to: "Road Trip 2")
            }
            sync.syncNow()
        }
        // `-GLDebugCatalogRequest remove:<album title>` or `add:<album title>[:<format>]` asks the Mac, as the album page does.
        if let asked = UserDefaults.standard.string(forKey: "GLDebugCatalogRequest") {
            let parts = asked.split(separator: ":").map(String.init)
            await catalog.refresh()
            if parts.count >= 2, let album = catalog.albums().first(where: { $0.title == parts[1] }) {
                catalog.request(parts[0] == "remove" ? .remove : .add, .album, key: album.key, encoding: parts.count > 2 ? parts[2] : nil)
            }
        }
        // `-GLDebugPlay YES` plays the first album (with `-GLDebugSync YES`, once the sync is over; with
        // `-GLDebugPlayDelay <seconds>`, that much later).
        if UserDefaults.standard.bool(forKey: "GLDebugPlay") {
            while sync.isSyncing { try? await Task.sleep(for: .milliseconds(250)) }
            try? await Task.sleep(for: .seconds(max(1, UserDefaults.standard.double(forKey: "GLDebugPlayDelay"))))
            if let album = library.contents.albums.first {
                player.play(library.read { try LibraryDatabase.tracks($0, albumKey: album.albumKey) } ?? [])
            }
        }
        // `-GLDebugOpenPlaying album|artist` follows Now Playing's link to the song's album or artist, 3 seconds after
        // playing starts.
        if let page = UserDefaults.standard.string(forKey: "GLDebugOpenPlaying") {
            try? await Task.sleep(for: .seconds(3))
            if let item = nowPlaying, let route = page == "artist" ? artistRoute(of: item) : albumRoute(of: item) { activeWindow?.show(route) }
        }
        // `-GLDebugHandOff <seconds>`: that long after, playback moves to the Mac (the Mac's tour run with
        // `-GLDebugAllowRemote YES`), or with `-GLDebugHandOffTo <name>` to that device, and as long again after that,
        // back here.
        let handOff = UserDefaults.standard.double(forKey: "GLDebugHandOff")
        if handOff > 0 {
            try? await Task.sleep(for: .seconds(handOff))
            await remote.check()
            if let name = UserDefaults.standard.string(forKey: "GLDebugHandOffTo") {
                guard let device = remote.devices.first(where: { $0.name == name }) else {
                    RemoteStore.log.error("No device named \(name, privacy: .public) (there: \(self.remote.devices.map(\.name), privacy: .public))")
                    return
                }
                await choose(.device(device))
            } else {
                await choose(.mac)
            }
            try? await Task.sleep(for: .seconds(handOff))
            await choose(.thisDevice)
        }
        // `-GLDebugPlayOnMac <album>`: plays on the Mac, then that album of its library (here or not), as a tap on
        // its first song does.
        if let title = UserDefaults.standard.string(forKey: "GLDebugPlayOnMac") {
            await catalog.refresh()
            await remote.check()
            await choose(.mac)
            guard let album = catalog.catalog?.albums.first(where: { $0.title == title }) else {
                RemoteStore.log.error("No album \(title, privacy: .public) on the Mac")
                return
            }
            playOnMac(catalog.songsAnywhere(album: album.key).map(\.id))
        }
        #endif
    }
}

/// Where the app keeps its data, in Application Support: the database and covers (backed up) and the songs (not backed
/// up: they come back from the Mac).
struct AppFolders: Sendable {
    let root: URL
    let database: URL
    /// Plays, loves and edits made here, until the Mac has them.
    let history: URL
    let artwork: URL
    let music: URL

    init() {
        root = URL.applicationSupportDirectory.appendingPathComponent("Groovelight", isDirectory: true)
        database = root.appendingPathComponent("Library.sqlite")
        history = root.appendingPathComponent("History.json")
        artwork = root.appendingPathComponent("Artwork", isDirectory: true)
        var music = root.appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? music.setResourceValues(values)
        self.music = music
    }
}

/// The song playing, as the screens show it.
struct NowPlayingItem: Equatable, Sendable {
    var id: Int64
    var title: String
    var artist: String
    var album: String
    var albumKey: String?
    var artworkHash: String?
    var isPlaying: Bool
    var isLoved: Bool
    /// Synced (LRC) or plain.
    var lyrics: SyncedLyrics
    /// The file's format and resolution, when the song is on this device.
    var spec: AudioSpec?

    static let sample = NowPlayingItem(id: -1, title: "Living Inside Myself", artist: "Gino Vannelli", album: "Nightwalker", isPlaying: true,
                                       isLoved: false,
                                       lyrics: SyncedLyrics(parsing: "[00:01.00]Some sample lines\n[00:04.00]to see the lyrics beside the cover\n"
                                                            + "[00:08.00]on the inner display\n[00:12.00]and above or below it\n"
                                                            + "[00:16.00]when the device is closed."),
                                       spec: AudioSpec(formatName: "FLAC", sampleRate: 96_000, bitDepth: 24, bitrate: nil, channels: 2))

    init(id: Int64, title: String, artist: String, album: String, albumKey: String? = nil, artworkHash: String? = nil, isPlaying: Bool,
         isLoved: Bool, lyrics: SyncedLyrics, spec: AudioSpec? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumKey = albumKey
        self.artworkHash = artworkHash
        self.isPlaying = isPlaying
        self.isLoved = isLoved
        self.lyrics = lyrics
        self.spec = spec
    }
}
