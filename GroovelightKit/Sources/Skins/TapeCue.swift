import AVFoundation
import Foundation

/// The sound of a cassette deck cueing: holding Rewind or Fast Forward with the heads on the tape, the music racing by as
/// a high chatter over the motor and the hiss. It runs while the scan goes on (each step keeps it going) and fades out
/// a moment after the last; off when the user turns it off in Settings.
@MainActor final class TapeCue {
    static let shared = TapeCue()

    private var player: AVAudioPlayer?
    private var stopping: Task<Void, Never>?

    /// Whether the user wants it (on unless turned off).
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: NowPlayingSkin.tapeCueStorageKey) as? Bool ?? true
    }

    /// One step of a scan: starts the sound, or keeps it going.
    func cue() {
        guard Self.isEnabled else { return }
        if player == nil, let url = Bundle.module.url(forResource: "TapeCue", withExtension: "wav") {
            player = try? AVAudioPlayer(contentsOf: url)
            player?.numberOfLoops = -1
        }
        guard let player else { return }
        if !player.isPlaying {
            player.volume = 0
            player.currentTime = .random(in: 0..<max(player.duration, 0.01))
            player.play()
        }
        player.setVolume(0.55, fadeDuration: 0.06)
        stopping?.cancel()
        // The scan steps every 0.15 s: a little longer without one, the key was let go.
        stopping = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled, let player = self?.player else { return }
            player.setVolume(0, fadeDuration: 0.12)
            try? await Task.sleep(for: .milliseconds(140))
            if !Task.isCancelled { player.pause() }
        }
    }
}
