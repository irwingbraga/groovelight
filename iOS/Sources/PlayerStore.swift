import AVFAudio
import Foundation
import LibraryKit
import MetadataKit
import MediaPlayer
import Observation
import OSLog
import PlayerCore
import UIKit
import WirelessSync

/// Playback on the device: the Mac's engine (gapless, Sound Check, the equalizer), the audio session (background audio,
/// interruptions, headphones unplugged), and the lock screen and Control Center.
@MainActor
@Observable
final class PlayerStore {
    let controller = PlaybackController()
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// When each song playing (or about to) started, for its history.
    @ObservationIgnored private var startedAt: [Int64: Date] = [:]
    /// Audio session calls block while the system sets the audio up, so they run here, in order, off the main thread.
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "dev.irwingbraga.groovelight.audio-session", qos: .userInitiated)
    /// Active since the last activation (an interruption ends it), so playing again need not wait for the session.
    @ObservationIgnored private var sessionActive = false

    /// Music playing elsewhere (the Mac, another device), shown on the lock screen and in Control Center while the app
    /// runs, with their buttons acting there (`remoteRoute`).
    struct Elsewhere: Equatable {
        var title: String
        var artist: String
        var album: String
        var artworkHash: String?
        var duration: TimeInterval
        var position: TimeInterval
        var playing: Bool
    }

    /// Where the lock screen's buttons go while music plays elsewhere.
    struct RemoteRoute {
        var play: @MainActor () -> Void
        var pause: @MainActor () -> Void
        var next: @MainActor () -> Void
        var previous: @MainActor () -> Void
        var seek: @MainActor (TimeInterval) -> Void
    }

    var elsewhere: Elsewhere? {
        didSet { if elsewhere != oldValue { updateNowPlayingInfo() } }
    }
    @ObservationIgnored var remoteRoute: RemoteRoute?
    /// The cover of a song playing elsewhere that is not here (the Mac library's), for the lock screen.
    @ObservationIgnored var coverElsewhere: (String?) -> URL? = { _ in nil }

    /// The lock screen's buttons act elsewhere.
    private var routed: RemoteRoute? { elsewhere != nil ? remoteRoute : nil }

    /// The Mac's 15-band equalizer, with its presets (saved as the Mac saves them).
    let equalizer: EqualizerStore
    /// Pauses after some minutes or at the end of the song.
    let sleepTimer: SleepTimer

    /// Seconds songs fade into each other (0: none, gapless).
    var crossfade: Double {
        didSet {
            controller.crossfadeDuration = crossfade
            UserDefaults.standard.set(crossfade, forKey: "player.crossfade")
        }
    }

    /// Songs of the same album follow each other without a fade even with crossfade on (live albums, DJ mixes).
    var crossfadeSkipsAlbum: Bool {
        didSet {
            controller.crossfadeSkipsSameAlbum = crossfadeSkipsAlbum
            UserDefaults.standard.set(crossfadeSkipsAlbum, forKey: "player.crossfadeSkipsAlbum")
        }
    }

    /// The playing speed, the pitch kept.
    var speed: Float {
        didSet {
            controller.rate = speed
            UserDefaults.standard.set(speed, forKey: "player.rate")
        }
    }

    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    static func speedLabel(_ rate: Float) -> String {
        rate == 1 ? "Normal" : (rate.formatted(.number.precision(.fractionLength(0...2))) + "×")
    }

    /// Sound Check: songs at the same loudness, albums keeping their own dynamics.
    var soundCheck: Bool {
        didSet {
            controller.normalization = soundCheck ? .album : .off
            UserDefaults.standard.set(soundCheck, forKey: "player.soundCheck")
        }
    }

    init(library: LibraryStore) {
        self.library = library
        soundCheck = UserDefaults.standard.object(forKey: "player.soundCheck") as? Bool ?? true
        equalizer = EqualizerStore(player: controller)
        sleepTimer = SleepTimer(player: controller)
        crossfade = UserDefaults.standard.double(forKey: "player.crossfade")
        crossfadeSkipsAlbum = UserDefaults.standard.object(forKey: "player.crossfadeSkipsAlbum") as? Bool ?? true
        speed = UserDefaults.standard.object(forKey: "player.rate") as? Float ?? 1
        controller.crossfadeDuration = crossfade
        controller.crossfadeSkipsSameAlbum = crossfadeSkipsAlbum
        controller.rate = speed
        controller.normalization = soundCheck ? .album : .off
        // The device's own volume (buttons, Control Center) sets the level: the engine stays at full scale.
        controller.volume = 1
        configureSession()
        configureRemoteCommands()
        // Each song heard here goes into the history (a play or a skip), from when it started.
        controller.onItemFinished = { [weak self] item, seconds in
            guard let self else { return }
            let startedAt = self.startedAt.removeValue(forKey: item.id) ?? .now.addingTimeInterval(-seconds)
            self.library.recordListen(trackId: item.id, duration: item.duration, startedAt: startedAt, seconds: seconds)
        }
        controller.onItemStarted = { [weak self] item in
            self?.startedAt[item.id] = .now
            Self.log.info("Playing \(item.title, privacy: .public) (\(item.album, privacy: .public))")
            self?.updateNowPlayingInfo()
        }
        watchState()
    }

    /// The song playing, as the screens show it.
    var nowPlaying: NowPlayingItem? {
        guard let item = controller.current else { return nil }
        let track = library.read { try LibraryDatabase.track($0, id: item.id) } ?? nil
        return NowPlayingItem(id: item.id, title: item.title, artist: item.artist, album: item.album, albumKey: item.albumKey,
                              artworkHash: track?.artworkHash, isPlaying: controller.state == .playing, isLoved: track?.isLoved ?? false,
                              lyrics: SyncedLyrics(parsing: track?.lyrics ?? ""), spec: track?.audioSpec)
    }

    /// `position`: seconds into the first song (a queue taken over from the Mac); `paused`: shown there, not started.
    func play(_ tracks: [Track], startAt index: Int = 0, shuffle: Bool = false, position: TimeInterval = 0, paused: Bool = false) {
        guard !tracks.isEmpty else { return }
        let items = tracks.map(library.playable)
        withActiveSession { store in
            store.controller.play(items, startAt: index, shuffle: shuffle, position: position > 1 ? position : 0)
            if paused { store.controller.pause() }
        }
    }

    func togglePlayPause() {
        if controller.state == .playing {
            controller.togglePlayPause()
        } else {
            withActiveSession { $0.controller.togglePlayPause() }
        }
    }

    /// What plays here, as other devices following this one see it.
    func remoteState() -> WirelessProtocol.RemoteState {
        let item = controller.current.map { item in
            let hash = (library.read { try LibraryDatabase.track($0, id: item.id) } ?? nil)?.artworkHash
            return WirelessProtocol.RemoteState.Item(id: item.id, title: item.title, artist: item.artist, album: item.album,
                                                     albumKey: item.albumKey, artworkHash: hash, duration: controller.duration > 0 ? controller.duration : item.duration)
        }
        return WirelessProtocol.RemoteState(item: item, playing: controller.state == .playing, position: controller.estimatedTime(at: .now),
                                            rate: Double(controller.rate), volume: 1, shuffle: controller.isShuffled,
                                            repeatMode: controller.repeatMode.rawValue, queue: controller.queue.items.prefix(5000).map(\.id),
                                            queueIndex: controller.queue.currentIndex)
    }

    func next() { controller.next() }
    func previous() { controller.previous() }
    func seek(to time: TimeInterval) { controller.seek(to: time) }

    func toggleLove() {
        guard let item = nowPlaying else { return }
        library.setLoved(!item.isLoved, trackId: item.id)
    }

    // MARK: - Audio session

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        sessionQueue.async {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            MainActor.assumeIsolated {
                switch type {
                case .began:
                    self?.sessionActive = false
                    self?.controller.pause()
                case .ended where options?.contains(.shouldResume) == true:
                    self?.withActiveSession { $0.controller.resume() }
                default: break
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            // Headphones unplugged: pause rather than play out loud.
            if reason == .oldDeviceUnavailable { MainActor.assumeIsolated { self?.controller.pause() } }
        })
    }

    /// Runs `body` once the audio session is active: at once when it already is, else after activating it off the main
    /// thread (the category is set first, as the queue keeps the order).
    private func withActiveSession(_ body: @escaping @MainActor (PlayerStore) -> Void) {
        if sessionActive {
            body(self)
            return
        }
        sessionQueue.async { [weak self] in
            let active = (try? AVAudioSession.sharedInstance().setActive(true)) != nil
            Task { @MainActor in
                guard let self else { return }
                self.sessionActive = active
                body(self)
            }
        }
    }

    // MARK: - Lock screen and Control Center

    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                if let route = self?.routed { return route.play() }
                self?.withActiveSession { $0.controller.resume() }
            }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                if let route = self?.routed { return route.pause() }
                self?.controller.pause()
            }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                if let self, let route = self.routed { return self.elsewhere?.playing == true ? route.pause() : route.play() }
                self?.togglePlayPause()
            }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                if let route = self?.routed { return route.next() }
                self?.next()
            }
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                if let route = self?.routed { return route.previous() }
                self?.previous()
            }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated {
                if let route = self?.routed { return route.seek(event.positionTime) }
                self?.seek(to: event.positionTime)
            }
            return .success
        }
    }

    /// Follows the state and the song (and seeks), so the lock screen's position and play state stay right.
    private func watchState() {
        withObservationTracking {
            _ = controller.state
            _ = controller.current?.id
            _ = controller.duration
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateNowPlayingInfo()
                self?.watchState()
            }
        }
    }

    private func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()
        if let elsewhere {
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: elsewhere.title,
                MPMediaItemPropertyArtist: elsewhere.artist,
                MPMediaItemPropertyAlbumTitle: elsewhere.album,
                MPMediaItemPropertyPlaybackDuration: elsewhere.duration,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: elsewhere.position,
                MPNowPlayingInfoPropertyPlaybackRate: elsewhere.playing ? 1.0 : 0,
                MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
                MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            ]
            if let url = coverElsewhere(elsewhere.artworkHash) ?? library.artworkURL(elsewhere.artworkHash, size: .large), let artwork = Self.artwork(url) {
                info[MPMediaItemPropertyArtwork] = artwork
            }
            center.nowPlayingInfo = info
            return
        }
        guard let item = controller.current else {
            center.nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.artist,
            MPMediaItemPropertyAlbumTitle: item.album,
            MPMediaItemPropertyPlaybackDuration: controller.duration > 0 ? controller.duration : item.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: controller.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: controller.state == .playing ? Double(controller.rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let url = item.artworkURL, let artwork = Self.artwork(url) { info[MPMediaItemPropertyArtwork] = artwork }
        // The playback rate tells iOS whether it plays (`playbackState` is the Mac's: on iOS it needs an entitlement).
        center.nowPlayingInfo = info
    }

    /// The cover for the lock screen. Not on the main actor: MediaPlayer asks for the image on its own queue.
    nonisolated private static func artwork(_ url: URL) -> MPMediaItemArtwork? {
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    static let log = Logger(subsystem: "dev.irwingbraga.groovelight", category: "player")
}
