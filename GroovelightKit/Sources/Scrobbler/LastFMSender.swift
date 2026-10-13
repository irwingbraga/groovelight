import Foundation
import LibraryKit

/// Sends what waits in the Last.fm queue: scrobbles in batches of 50, then loves and unloves. Sent items leave the
/// queue; when Last.fm or the network is down they stay for the next try; items Last.fm keeps refusing are dropped after
/// a few attempts. One send at a time.
public actor LastFMSender {
    public enum Outcome: Sendable, Equatable {
        /// Everything waiting was sent (`ignored`: scrobbles Last.fm accepted but did not count, too old for example).
        case sent(scrobbles: Int, loves: Int, ignored: Int)
        /// Stopped early; the rest waits for the next try.
        case postponed(String)
        /// The session is not valid any more: connect to Last.fm again.
        case needsReconnect(String)
    }

    /// Items refused this many times (bad data, not outages) are dropped.
    public static let maxAttempts = 3

    private let database: LibraryDatabase

    public init(database: LibraryDatabase) {
        self.database = database
    }

    public func send(with client: LastFMClient) async -> Outcome {
        var scrobbled = 0, loved = 0, ignored = 0
        // Scrobbles, oldest first.
        while true {
            guard let batch = try? database.pendingLastFM(kinds: [.scrobble], limit: 50), !batch.isEmpty else { break }
            do {
                let response = try await client.scrobble(batch.map { (Self.track(of: $0), $0.timestamp) })
                try? database.removeLastFM(batch.compactMap(\.id))
                scrobbled += response.accepted
                ignored += response.ignored
            } catch {
                // A refused batch is sent again one song at a time, so only the bad one is held back.
                let lastFM = error as? LastFMError ?? .invalidResponse
                if lastFM.needsReconnect || lastFM.isTemporary || batch.count == 1 {
                    if let outcome = handle(error, ids: batch.compactMap(\.id)) { return outcome }
                    continue
                }
                for item in batch {
                    guard let id = item.id else { continue }
                    do {
                        let response = try await client.scrobble([(Self.track(of: item), item.timestamp)])
                        try? database.removeLastFM([id])
                        scrobbled += response.accepted
                        ignored += response.ignored
                    } catch {
                        if let outcome = handle(error, ids: [id]) { return outcome }
                    }
                }
            }
        }
        // Loves and unloves.
        while true {
            guard let batch = try? database.pendingLastFM(kinds: [.love, .unlove], limit: 20), !batch.isEmpty else { break }
            for item in batch {
                guard let id = item.id else { continue }
                do {
                    try await client.setLoved(item.kind == .love, artist: item.artist, track: item.track)
                    try? database.removeLastFM([id])
                    loved += 1
                } catch {
                    if let outcome = handle(error, ids: [id]) { return outcome }
                }
            }
        }
        return .sent(scrobbles: scrobbled, loves: loved, ignored: ignored)
    }

    /// Decides what a failure means: stop for now, stop and reconnect, or count the attempt and go on.
    private func handle(_ error: Error, ids: [Int64]) -> Outcome? {
        let lastFM = error as? LastFMError ?? .invalidResponse
        if lastFM.needsReconnect { return .needsReconnect(Self.describe(lastFM)) }
        if lastFM.isTemporary { return .postponed(Self.describe(lastFM)) }
        try? database.failedLastFM(ids, maxAttempts: Self.maxAttempts)
        return nil
    }

    static func track(of item: LastFMQueueItem) -> LastFMTrack {
        LastFMTrack(artist: item.artist, track: item.track, album: item.album, albumArtist: item.albumArtist,
                    duration: item.duration, trackNumber: item.trackNumber)
    }

    public static func describe(_ error: LastFMError) -> String {
        switch error {
        case .api(_, let message) where !message.isEmpty: message
        case .api(let code, _): "Last.fm error \(code)"
        case .http(let status): "Last.fm answered HTTP \(status)"
        case .invalidResponse: "Unexpected answer from Last.fm"
        case .offline: "Last.fm is not reachable"
        }
    }
}
