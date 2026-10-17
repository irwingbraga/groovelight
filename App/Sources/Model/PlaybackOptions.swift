import Foundation
import LibraryKit
import Observation
import PlayerCore

/// Playback preferences (Settings, Playback and the Controls menu), saved under "player." so backups include them.
enum PlaybackPrefs {
    static let crossfade = "player.crossfade"
    static let crossfadeSkipsAlbum = "player.crossfadeSkipsAlbum"
    static let normalization = "player.normalization"
    static let rate = "player.rate"
    static let bitPerfect = "player.bitPerfect"
    static let exclusive = "player.exclusive"

    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    static func register() {
        UserDefaults.standard.register(defaults: [crossfade: 0.0, crossfadeSkipsAlbum: true,
                                                  normalization: VolumeNormalization.off.rawValue, rate: 1.0,
                                                  bitPerfect: false, exclusive: false])
    }

    /// Puts the saved preferences on the player.
    @MainActor static func apply(to player: PlaybackController) {
        let defaults = UserDefaults.standard
        player.crossfadeDuration = defaults.double(forKey: crossfade)
        player.crossfadeSkipsSameAlbum = defaults.bool(forKey: crossfadeSkipsAlbum)
        player.normalization = VolumeNormalization(rawValue: defaults.string(forKey: normalization) ?? "") ?? .off
        player.rate = Float(defaults.double(forKey: rate))
        player.exclusiveAccess = defaults.bool(forKey: exclusive)
        player.bitPerfect = defaults.bool(forKey: bitPerfect)
    }

    static func speedLabel(_ rate: Float) -> String {
        rate == 1 ? "Normal" : (rate.formatted(.number.precision(.fractionLength(0...2))) + "×")
    }
}

/// Pauses playback after some minutes (fading out over the last seconds) or when the current song ends.
@MainActor @Observable
final class SleepTimer {
    enum Mode: Hashable {
        case minutes(Int)
        case endOfSong
    }

    static let choices = [15, 30, 45, 60, 90, 120]

    private(set) var mode: Mode?
    private(set) var endsAt: Date?
    /// Refreshed every few seconds while a timer runs, for "23 min left".
    private(set) var now = Date.now

    @ObservationIgnored private weak var player: PlaybackController?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(player: PlaybackController) {
        self.player = player
        player.onStoppedAfterItem = { [weak self] in self?.finished() }
    }

    var isActive: Bool { mode != nil }

    /// "23 min left", "Ends with this song", or nil when off.
    var summary: String? {
        switch mode {
        case .none: return nil
        case .endOfSong: return "Stops after this song"
        case .minutes:
            // Rounded up, but a timer just set for 30 minutes says 30 (not 31).
            let left = max(Int(((endsAt ?? now).timeIntervalSince(now) / 60 - 0.01).rounded(.up)), 0)
            return "\(left) min left"
        }
    }

    func start(_ mode: Mode) {
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

    func cancel() {
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

/// Measures the loudness of songs without ReplayGain tags in the background while volume normalization is on, one song
/// at a time, the playing and next songs first.
@MainActor @Observable
final class LoudnessStore {
    private(set) var measured = 0
    private(set) var total = 0
    private(set) var isRunning = false

    @ObservationIgnored private let database: LibraryDatabase
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var priority: [Int64] = []
    /// Songs that could not be read this session.
    @ObservationIgnored private var skipped = Set<Int64>()

    init(database: LibraryDatabase) {
        self.database = database
        Task { [weak self, database] in
            do {
                for try await progress in database.observe({ try LibraryDatabase.loudnessProgress($0) }) {
                    self?.measured = progress.measured
                    self?.total = progress.total
                }
            } catch {}
        }
    }

    /// Starts measuring (normalization on) or stops.
    func setEnabled(_ enabled: Bool) {
        if enabled { start() } else { stop() }
    }

    /// Measures these songs next (the one playing and the one after it).
    func prioritize(_ ids: [Int64]) {
        priority = ids + priority.filter { !ids.contains($0) }
        if task == nil, isEnabled { start() }
    }

    private var isEnabled: Bool {
        (VolumeNormalization(rawValue: UserDefaults.standard.string(forKey: PlaybackPrefs.normalization) ?? "") ?? .off) != .off
    }

    /// Songs failing in a row after which the job stops for the session.
    private static let failureLimit = 8

    private func start() {
        guard task == nil else { return }
        isRunning = true
        task = Task { [weak self, database] in
            var failuresInARow = 0
            while let self, !Task.isCancelled {
                let wanted = self.priority
                self.priority = []
                let skipped = self.skipped
                var ids = (try? await database.writer.read { try LibraryDatabase.trackIdsNeedingLoudness($0, among: wanted) }) ?? []
                if ids.isEmpty {
                    ids = (try? await database.writer.read { try LibraryDatabase.trackIdsNeedingLoudness($0, limit: 10 + skipped.count) }) ?? []
                }
                ids.removeAll { skipped.contains($0) }
                guard !ids.isEmpty else { break }
                for id in ids where !Task.isCancelled {
                    guard let track = try? await database.writer.read({ try Track.fetchOne($0, key: id) }) else { continue }
                    let (url, start, end) = (track.url, track.startTime, track.endTime)
                    let result = await Task.detached(priority: .utility) {
                        Result { try LoudnessMeter.measure(url: url, start: start, end: end) }
                    }.value
                    switch result {
                    case .success(let loudness):
                        // A level, or nil for silence: either way it is known now.
                        try? database.setLoudness(loudness, trackId: id)
                        failuresInARow = 0
                    case .failure:
                        // Unreadable now (an unplugged drive): skipped this session, tried again next time.
                        self.skipped.insert(id)
                        failuresInARow += 1
                    }
                    if !self.priority.isEmpty || failuresInARow >= Self.failureLimit { break }
                }
                // Song after song failing: a drive that cannot be read right now. Opening every song on it would only
                // keep the struggling drive busy, so the job waits for the next session (or a song asked for by playback).
                if failuresInARow >= Self.failureLimit, self.priority.isEmpty { break }
            }
            self?.task = nil
            self?.isRunning = false
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }
}
