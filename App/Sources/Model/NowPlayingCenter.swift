import AppKit
import MediaPlayer
import PlayerCore

/// Publishes the current track to Control Center / media keys and routes remote commands to the player.
@MainActor
final class NowPlayingCenter {
    private weak var player: PlaybackController?
    private var observation: Task<Void, Never>?

    func attach(to player: PlaybackController) {
        self.player = player
        Self.registerCommands { [weak self] command in
            Task { @MainActor in self?.perform(command) }
        }
        observeState()
    }

    enum Command: Sendable {
        case play, pause, toggle, next, previous, seek(TimeInterval)
    }

    private func perform(_ command: Command) {
        guard let player else { return }
        switch command {
        case .play: player.resume()
        case .pause: player.pause()
        case .toggle: player.togglePlayPause()
        case .next: player.next()
        case .previous: player.previous()
        case .seek(let time): player.seek(to: time)
        }
    }

    /// Handlers are built outside the main actor because MediaPlayer may invoke them on its own queue.
    nonisolated private static func registerCommands(_ send: @escaping @Sendable (Command) -> Void) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in send(.play); return .success }
        center.pauseCommand.addTarget { _ in send(.pause); return .success }
        center.togglePlayPauseCommand.addTarget { _ in send(.toggle); return .success }
        center.nextTrackCommand.addTarget { _ in send(.next); return .success }
        center.previousTrackCommand.addTarget { _ in send(.previous); return .success }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            send(.seek(event.positionTime))
            return .success
        }
    }

    func update(item: PlayableItem, artworkURL: URL?, player: PlaybackController) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.artist,
            MPMediaItemPropertyAlbumTitle: item.album,
            MPMediaItemPropertyPlaybackDuration: item.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        if let artworkURL, let artwork = Self.makeArtwork(contentsOf: artworkURL) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// MediaPlayer calls the image handler on its own queue, so the closure must not be main-actor isolated.
    nonisolated private static func makeArtwork(contentsOf url: URL) -> MPMediaItemArtwork? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    /// Keeps state and elapsed time in sync (Control Center interpolates between updates using the rate).
    private func observeState() {
        observation = Task { [weak self] in
            while !Task.isCancelled {
                guard let player = self?.player else { return }
                let center = MPNowPlayingInfoCenter.default()
                center.playbackState = switch player.state {
                case .playing: .playing
                case .paused: .paused
                case .stopped: .stopped
                }
                if var info = center.nowPlayingInfo {
                    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
                    info[MPNowPlayingInfoPropertyPlaybackRate] = player.state == .playing ? 1.0 : 0.0
                    center.nowPlayingInfo = info
                }
                if player.state == .stopped, player.current == nil { center.nowPlayingInfo = nil }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
