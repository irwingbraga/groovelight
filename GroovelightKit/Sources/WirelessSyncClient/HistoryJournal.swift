import Foundation
import LibraryKit

/// What happened on the device that the Mac should know: plays, skips, loves, ratings and playlist edits, kept in a file
/// until the Mac has them (they survive the app ending), then forgotten (the Mac's next snapshot has how each song
/// stands there). Each event has its own id, so the Mac counts it once even when it is sent again after a lost answer.
public final class HistoryJournal: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var events: [DeviceHistoryEvent]

    public init(url: URL) {
        self.url = url
        events = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([DeviceHistoryEvent].self, from: $0) } ?? []
    }

    /// The events not sent yet, in the order they happened.
    public var pending: [DeviceHistoryEvent] { lock.withLock { events } }

    public func record(_ event: DeviceHistoryEvent) {
        lock.withLock {
            events.append(event)
            save()
        }
    }

    /// The Mac has these.
    public func remove(_ sent: [DeviceHistoryEvent]) {
        let ids = Set(sent.map(\.id))
        lock.withLock {
            events.removeAll { ids.contains($0.id) }
            save()
        }
    }

    /// Sends what is pending to the Mac and forgets it once the Mac answers. Returns how many were sent.
    @discardableResult
    public func send(with client: MacClient) async throws -> Int {
        let sent = pending
        guard !sent.isEmpty else { return 0 }
        try await client.history(sent)
        remove(sent)
        return sent.count
    }

    /// A new event's id: unique to this device and this moment.
    public static func newId() -> String { UUID().uuidString }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(events).write(to: url, options: .atomic)
    }
}
