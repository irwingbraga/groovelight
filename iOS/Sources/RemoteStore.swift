import Foundation
import Observation
import OSLog
import WirelessSync
import WirelessSyncClient

/// The paired Mac, and the other devices reached through it, as places to play music: whether the Mac lets this device
/// control playback, the devices there now, what the chosen one plays (followed as it changes, by waiting on its state),
/// and the commands sent to it.
@MainActor
@Observable
final class RemoteStore {
    enum Availability: Equatable {
        case unknown
        case checking
        case available
        /// The Mac's device page has not turned it on.
        case notAllowed
        case unreachable(String)
    }

    private(set) var availability = Availability.unknown
    /// The Mac's player, as of `receivedAt` (this device's clock).
    private(set) var state: WirelessProtocol.RemoteState?
    private(set) var receivedAt = Date.now
    /// Following the Mac (it is where music plays).
    private(set) var isFollowing = false
    /// The other devices music can play on now (phones with Groovelight open), as of the last check.
    private(set) var devices: [WirelessProtocol.RemoteDevice] = []
    /// The device followed and sent commands: nil for the Mac.
    private(set) var device: String?
    /// Songs of the last queue sent there that it does not have (left out), to say so.
    private(set) var skipped = 0

    @ObservationIgnored private let sync: SyncStore
    @ObservationIgnored private var client: MacClient?
    @ObservationIgnored private var follower: Task<Void, Never>?

    init(sync: SyncStore) {
        self.sync = sync
    }

    var macName: String? { sync.mac?.name }

    /// Asks the Mac whether this device may play music there (when the device picker opens).
    func check() async {
        guard sync.isPaired else {
            availability = .unknown
            return
        }
        if availability != .available { availability = .checking }
        do {
            let client = try await connected()
            if device == nil {
                state = try await client.remoteState()
                receivedAt = .now
            }
            availability = .available
            devices = (try? await client.remoteDevices()) ?? []
        } catch {
            availability = Self.availability(after: error)
            devices = []
            client = nil
        }
    }

    /// Follows (and sends commands to) the Mac, or another device; what was known of the last one is dropped.
    func use(_ device: String?) {
        guard device != self.device else { return }
        stopFollowing()
        self.device = device
        state = nil
        skipped = 0
    }

    /// Follows the Mac's player until `stopFollowing`.
    func follow() {
        guard follower == nil else { return }
        isFollowing = true
        follower = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let client = try await self.connected()
                    let next = try await client.remoteState(after: self.state?.version, device: self.device)
                    guard !Task.isCancelled else { return }
                    self.apply(next)
                    self.availability = .available
                    failures = 0
                } catch is CancellationError {
                    return
                } catch {
                    if Task.isCancelled { return }
                    failures += 1
                    self.client = nil
                    Self.log.error("Following the Mac failed: \(String(describing: error), privacy: .public)")
                    if failures >= 3 { self.availability = Self.availability(after: error) }
                    try? await Task.sleep(for: .seconds(min(failures, 5)))
                }
            }
        }
    }

    func stopFollowing() {
        follower?.cancel()
        follower = nil
        isFollowing = false
    }

    /// Sends a command; the Mac answers with its state after it, shown at once.
    func send(_ command: WirelessProtocol.RemoteCommand) {
        send(command, to: device)
    }

    /// Sends a command to the Mac (nil) or a device; its answer is shown only when that is the one followed.
    func send(_ command: WirelessProtocol.RemoteCommand, to device: String?) {
        Task {
            do {
                let answer = try await connected().remote(command, device: device)
                if device == self.device {
                    apply(answer)
                    countSkipped(command, answer)
                }
            } catch {
                Self.log.error("Command failed: \(String(describing: error), privacy: .public)")
                availability = Self.availability(after: error)
                client = nil
            }
        }
    }

    /// Sends a command and waits for the Mac (handing over a queue, before this device stops its own).
    func sendAndWait(_ command: WirelessProtocol.RemoteCommand) async throws {
        let answer = try await connected().remote(command, device: device)
        apply(answer)
        countSkipped(command, answer)
    }

    /// A queue sent: the songs not in the queue there are ones it does not have.
    private func countSkipped(_ command: WirelessProtocol.RemoteCommand, _ answer: WirelessProtocol.RemoteState) {
        guard case let .play(ids, _, _, _) = command else { return }
        skipped = max(ids.count - answer.queue.count, 0)
    }

    /// Where the Mac's song is at `date`, moved on from the last state.
    func estimatedTime(at date: Date) -> TimeInterval {
        guard let state else { return 0 }
        guard state.playing else { return state.position }
        let moved = state.position + date.timeIntervalSince(receivedAt) * state.rate
        return min(moved, state.item?.duration ?? moved)
    }

    private func apply(_ state: WirelessProtocol.RemoteState) {
        self.state = state
        receivedAt = .now
    }

    private func connected() async throws -> MacClient {
        if let client { return client }
        let client = try await sync.client()
        self.client = client
        return client
    }

    private static func availability(after error: any Error) -> Availability {
        if let error = error as? MacError, error.status == 403 { return .notAllowed }
        return .unreachable(error.localizedDescription)
    }

    static let log = Logger(subsystem: "dev.irwingbraga.groovelight", category: "remote")
}
