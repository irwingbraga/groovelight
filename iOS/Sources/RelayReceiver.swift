import Foundation
import Observation
import OSLog
import WirelessSync
import WirelessSyncClient

/// This device as a place other devices play music on, through the Mac: while the app runs, it waits there for their
/// commands, plays what they send with its own player, and tells the Mac what it plays after each change, so they
/// follow it. Off with Settings' "Let Other Devices Play Here".
@MainActor
@Observable
final class RelayReceiver {
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? start() : stop()
        }
    }

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var client: MacClient?
    /// The last command applied, and the last state sent (its version).
    @ObservationIgnored private var applied = 0
    @ObservationIgnored private var sentVersion: String?

    static let enabledKey = "relay.enabled"

    init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Starts waiting for commands (when paired and turned on); again after pairing.
    func start(model: AppModel) {
        self.model = model
        start()
    }

    private func start() {
        guard task == nil, isEnabled, let model, model.sync.isPaired else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        client = nil
    }

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            do {
                guard let model else { return }
                let client: MacClient
                if let connected = self.client {
                    client = connected
                } else {
                    client = try await model.sync.client()
                }
                self.client = client
                // Commands sent before this device was there are not for it.
                var last = try await client.relayCommands(after: nil).last
                applied = last
                sentVersion = nil
                try await report(force: true)
                failures = 0
                // Reports the player as it changes here, while waiting for commands.
                let reporter = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        try? await self?.report(force: false)
                    }
                }
                defer { reporter.cancel() }
                while !Task.isCancelled {
                    let answer = try await client.relayCommands(after: last)
                    guard !answer.commands.isEmpty else { continue }
                    for relayed in answer.commands {
                        Self.log.info("\(relayed.fromName, privacy: .public): \(String(describing: relayed.command), privacy: .public)")
                        model.applyRelayed(relayed.command)
                        last = relayed.seq
                    }
                    applied = last
                    // The player needs a moment to start a song before what it plays can be told.
                    try? await Task.sleep(for: .milliseconds(150))
                    try await report(force: true)
                }
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                failures += 1
                client = nil
                if failures == 1 { Self.log.error("Waiting for other devices failed: \(String(describing: error), privacy: .public)") }
                // The Mac is away: try again now and then, less often the longer it stays away.
                try? await Task.sleep(for: .seconds(min(5 * failures, 60)))
            }
        }
    }

    /// Tells the Mac what plays here, when it changed (a seek counts; steady playing does not) or when `force`d.
    private func report(force: Bool) async throws {
        guard let model, let client else { return }
        let state = model.player.remoteState()
        let version = state.signature(now: .now)
        guard force || version != sentVersion else { return }
        sentVersion = version
        try await client.relayState(state, applied: applied)
    }

    static let log = Logger(subsystem: "dev.irwingbraga.groovelight", category: "relay")
}
