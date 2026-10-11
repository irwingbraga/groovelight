import Foundation

/// Lyrics with optional line timings, parsed from LRC ("[01:23.45]line") or plain text.
public struct SyncedLyrics: Hashable, Sendable {
    public struct Line: Hashable, Sendable {
        /// Seconds from the start of the track, nil for unsynced lyrics.
        public var time: Double?
        public var text: String
    }

    public var lines: [Line]
    public var isSynced: Bool { lines.contains { $0.time != nil } }

    public init(lines: [Line]) {
        self.lines = lines
    }

    /// Parses LRC, including several time tags on one line and the `[offset:+/-ms]` tag. Text without any time tags is
    /// returned as unsynced lines.
    public init(parsing text: String) {
        var timed: [Line] = []
        var plain: [Line] = []
        var offset = 0.0
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            var rest = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let time = Self.parseTime(tag) {
                    times.append(time)
                } else if tag.lowercased().hasPrefix("offset:"), let ms = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    // Positive offset means the lyrics come sooner.
                    offset = ms / 1000
                } else if times.isEmpty, tag.contains(":") {
                    // Metadata tag such as [ar:Artist]; the whole line is skipped.
                    rest = ""
                    break
                } else {
                    break
                }
                rest = rest[rest.index(after: close)...]
            }
            let lineText = rest.trimmingCharacters(in: .whitespaces)
            if times.isEmpty {
                plain.append(Line(time: nil, text: lineText))
            } else {
                timed += times.map { Line(time: $0, text: lineText) }
            }
        }
        if timed.isEmpty {
            // Trim leading and trailing blank lines of plain lyrics.
            while plain.first?.text.isEmpty == true { plain.removeFirst() }
            while plain.last?.text.isEmpty == true { plain.removeLast() }
            lines = plain
        } else {
            lines = timed.map { Line(time: max(0, ($0.time ?? 0) - offset), text: $0.text) }.sorted { ($0.time ?? 0) < ($1.time ?? 0) }
        }
    }

    /// Index of the line being sung at `time`, or nil before the first line.
    public func lineIndex(at time: Double) -> Int? {
        guard isSynced else { return nil }
        var low = 0
        var high = lines.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if (lines[mid].time ?? 0) <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    public var plainText: String { lines.map(\.text).joined(separator: "\n") }

    /// "mm:ss.xx", "mm:ss:xx" or "mm:ss".
    static func parseTime(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, let minutes = Int(parts[0]), minutes >= 0 else { return nil }
        let secondsPart = parts.count == 3 ? "\(parts[1]).\(parts[2])" : String(parts[1])
        guard let seconds = Double(secondsPart), seconds >= 0, seconds < 60 else { return nil }
        return Double(minutes) * 60 + seconds
    }
}

/// Lyrics found online: synced LRC when available, otherwise plain text.
public struct FetchedLyrics: Hashable, Sendable {
    public var synced: String?
    public var plain: String?
    public var isInstrumental: Bool

    /// Text to store: LRC when synced lyrics exist.
    public var bestText: String? { synced ?? plain }
}

/// LRCLIB (https://lrclib.net): free synced lyrics, no API key.
public final class LRCLibClient: Sendable {
    private let fetcher: any HTTPFetching
    private let identity: ClientIdentity
    private let limiter: RateLimiter

    /// LRCLIB answers bursts with 503: requests are spaced by `limiter` (share one per app) and retried when busy.
    public init(fetcher: any HTTPFetching = URLSessionFetcher(), identity: ClientIdentity,
                limiter: RateLimiter = RateLimiter(interval: .milliseconds(400))) {
        self.fetcher = fetcher
        self.identity = identity
        self.limiter = limiter
    }

    struct Record: Codable {
        var trackName: String?
        var artistName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?

        var lyrics: FetchedLyrics {
            FetchedLyrics(synced: syncedLyrics.flatMap { $0.isEmpty ? nil : $0 },
                          plain: plainLyrics.flatMap { $0.isEmpty ? nil : $0 },
                          isInstrumental: instrumental ?? false)
        }
    }

    /// Exact lookup by signature (LRCLIB matches the duration within 2 seconds), then a search fallback that keeps only
    /// results with the same artist and a close duration. Nil when nothing is found.
    public func lyrics(title: String, artist: String, album: String?, duration: Double) async throws -> FetchedLyrics? {
        do {
            let data = try await fetcher.get(.build("https://lrclib.net/api/get", [
                "track_name": title, "artist_name": artist, "album_name": album ?? "", "duration": String(Int(duration.rounded())),
            ]), identity: identity, limiter: limiter)
            return try JSONDecoder().decode(Record.self, from: data).lyrics
        } catch MetadataError.notFound {
            // Fall through to search.
        }
        let data = try await fetcher.get(.build("https://lrclib.net/api/search", ["track_name": title, "artist_name": artist]),
                                         identity: identity, limiter: limiter)
        let records = try JSONDecoder().decode([Record].self, from: data)
        let artistKey = artist.matchKey
        let candidates = records.filter { record in
            let sameArtist = record.artistName?.matchKey == artistKey
            let closeDuration = abs((record.duration ?? 0) - duration) <= 3
            return sameArtist && closeDuration
        }
        // Prefer synced lyrics, then plain, then an instrumental marker.
        let match = candidates.first { $0.syncedLyrics?.isEmpty == false }
            ?? candidates.first { $0.plainLyrics?.isEmpty == false }
            ?? candidates.first { $0.instrumental == true }
        return match?.lyrics
    }
}
