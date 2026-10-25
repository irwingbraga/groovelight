import Foundation
import Observation

/// Pauses playback after some minutes (fading out over the last seconds) or when the current song ends.
@MainActor @Observable
public final class SleepTimer {
    public enum Mode: Hashable, Sendable {
        case minutes(Int)
        case endOfSong
    }

    public static let choices = [15, 30, 45, 60, 90, 120]

    public private(set) var mode: Mode?
    public private(set) var endsAt: Date?
    /// Refreshed every few seconds while a timer runs, for "23 min left".
    public private(set) var now = Date.now

    @ObservationIgnored private weak var player: PlaybackController?
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(player: PlaybackController) {
        self.player = player
        player.onStoppedAfterItem = { [weak self] in self?.finished() }
    }

    public var isActive: Bool { mode != nil }

    /// "23 min left", "Ends with this song", or nil when off.
    public var summary: String? {
        switch mode {
        case .none: return nil
        case .endOfSong: return "Stops after this song"
        case .minutes:
            // Rounded up, but a timer just set for 30 minutes says 30 (not 31).
            let left = max(Int(((endsAt ?? now).timeIntervalSince(now) / 60 - 0.01).rounded(.up)), 0)
            return "\(left) min left"
        }
    }

    public func start(_ mode: Mode) {
        cancel()
        self.mode = mode
        now = .now
        switch mode {
        case .endOfSong:
            player?.stopsAfterCurrentItem = true
        case .minutes(let minutes):
            let end = Date.now.addingTimeInterval(Double(minutes) * 60)
            endsAt = end
            task = Task { [weak self] in
                while let self, !Task.isCancelled {
                    self.now = .now
                    let left = end.timeIntervalSinceNow
                    if left <= 10 {
                        await self.fadeOutAndPause(over: max(left, 0))
                        return
                    }
                    try? await Task.sleep(for: .seconds(min(left - 10, 5)))
                }
            }
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        if mode == .endOfSong { player?.stopsAfterCurrentItem = false }
        mode = nil
        endsAt = nil
    }

    /// Lowers the volume to silence, pauses, and puts the volume back for next time.
    private func fadeOutAndPause(over seconds: TimeInterval) async {
        guard let player else { return }
        let volume = player.volume
        let steps = max(Int(seconds / 0.1), 1)
        for step in 1...steps {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else {
                player.volume = volume
                return
            }
            player.volume = volume * Float(1 - Double(step) / Double(steps))
        }
        player.pause()
        player.volume = volume
        finished()
    }

    private func finished() {
        task = nil
        mode = nil
        endsAt = nil
    }
}
