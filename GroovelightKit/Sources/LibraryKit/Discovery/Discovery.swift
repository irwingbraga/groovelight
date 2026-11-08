import Foundation

/// Home's picks of the day, worked out from the listening log. Everything here is integer math over a seeded random
/// generator, so the same library, log and day give the same picks on the Mac and on Windows (`Discovery.cs`), which
/// check it against the same fixtures.
public enum Discovery {
    // MARK: - Input

    /// What the picks need of a song.
    public struct Song: Codable, Hashable, Sendable {
        public var id: Int64
        public var title: String
        public var artist: String
        /// The album's artist (Various Artists for compilations), what Artist of the Day goes by.
        public var albumArtist: String
        public var album: String
        public var albumKey: String
        public var genre: String?
        public var year: Int?
        public var loved: Bool
        public var rating: Int
        /// Days since 1970 (local calendar) the song was added.
        public var addedDay: Int
        public var duration: Double
        /// Disc and track number (disc * 1000 + track), for the album's order.
        public var order: Int

        public init(id: Int64, title: String, artist: String, albumArtist: String, album: String, albumKey: String, genre: String?,
                    year: Int?, loved: Bool, rating: Int, addedDay: Int, duration: Double, order: Int) {
            self.id = id
            self.title = title
            self.artist = artist
            self.albumArtist = albumArtist
            self.album = album
            self.albumKey = albumKey
            self.genre = genre
            self.year = year
            self.loved = loved
            self.rating = rating
            self.addedDay = addedDay
            self.duration = duration
            self.order = order
        }
    }

    /// What the picks need of a listen.
    public struct Play: Codable, Hashable, Sendable {
        public var trackId: Int64
        /// Days since 1970 (local calendar).
        public var day: Int
        public var counted: Bool
        public var skipped: Bool
        public var count: Int
        public var source: String

        public init(trackId: Int64, day: Int, counted: Bool, skipped: Bool, count: Int = 1, source: String) {
            self.trackId = trackId
            self.day = day
            self.counted = counted
            self.skipped = skipped
            self.count = count
            self.source = source
        }
    }

    /// An earlier pick, so picks do not come back too soon.
    public struct PastPick: Codable, Hashable, Sendable {
        public var day: Int
        public var kind: Kind
        public var key: String
        /// Why it was picked (`Reason.code`).
        public var reason: String?

        public init(day: Int, kind: Kind, key: String, reason: String? = nil) {
            self.day = day
            self.kind = kind
            self.key = key
            self.reason = reason
        }
    }

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case song, album, artist
    }

    // MARK: - Output

    /// Why something was picked, for the line under it.
    public enum Reason: Codable, Hashable, Sendable {
        /// Much played, not lately: plays and the days since.
        case rediscover(plays: Int, daysSince: Int)
        /// Loved or rated, hardly played.
        case hiddenGem(loved: Bool, rating: Int)
        /// Added recently, hardly played.
        case newToYou(daysSinceAdded: Int)
        /// Released a round number of years ago.
        case anniversary(years: Int)
        /// Among the most played lately.
        case favorite(plays: Int)
        /// Never played yet.
        case unplayed

        /// As stored with a pick ("rediscover,12,90"), the same on Windows.
        public var code: String {
            switch self {
            case .rediscover(let plays, let daysSince): "rediscover,\(plays),\(daysSince)"
            case .hiddenGem(let loved, let rating): "hiddenGem,\(loved ? 1 : 0),\(rating)"
            case .newToYou(let days): "newToYou,\(days)"
            case .anniversary(let years): "anniversary,\(years)"
            case .favorite(let plays): "favorite,\(plays)"
            case .unplayed: "unplayed"
            }
        }

        public init?(code: String) {
            let parts = code.split(separator: ",").map(String.init)
            let numbers = parts.dropFirst().compactMap { Int($0) }
            switch (parts.first, numbers.count) {
            case ("rediscover", 2): self = .rediscover(plays: numbers[0], daysSince: numbers[1])
            case ("hiddenGem", 2): self = .hiddenGem(loved: numbers[0] == 1, rating: numbers[1])
            case ("newToYou", 1): self = .newToYou(daysSinceAdded: numbers[0])
            case ("anniversary", 1): self = .anniversary(years: numbers[0])
            case ("favorite", 1): self = .favorite(plays: numbers[0])
            case ("unplayed", 0): self = .unplayed
            default: return nil
            }
        }
    }

    public struct Pick: Codable, Hashable, Sendable {
        public var kind: Kind
        /// The song id, the album key or the artist name.
        public var key: String
        public var reason: Reason
        /// Songs to play for it: the song, the album's songs in order, the artist's essentials.
        public var trackIds: [Int64]
    }

    /// Days since 1970 of a date in the local calendar.
    public static func day(of date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return daysFromCivil(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    /// Days since 1970-01-01 of a calendar date (Howard Hinnant's algorithm, also in Discovery.cs).
    public static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// The year of a day number.
    public static func year(ofDay days: Int) -> Int {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let month = mp + (mp < 10 ? 3 : -9)
        return yoe + era * 400 + (month <= 2 ? 1 : 0)
    }
}

// MARK: - Taste

extension Discovery {
    /// Each song's standing from the log: plays (recent ones weigh more), loves, ratings, skips, and when it was last heard.
    public struct Taste: Sendable {
        public struct Score: Sendable, Equatable {
            /// Plays and skips weighed by how recent they are, plus loves and ratings (0 or more).
            public var affinity: Int = 0
            /// All counted plays.
            public var plays: Int = 0
            public var skips: Int = 0
            /// The day of the last counted play (nil if never).
            public var lastDay: Int?
        }

        public var scores: [Int64: Score]

        /// Plays a half-life of 90 days apart weigh half as much. Summary rows (play counts from before the log) are left
        /// out for songs with Last.fm history, which has those plays already.
        public init(songs: [Song], plays: [Play], today: Int) {
            let withLastFM = Set(plays.lazy.filter { $0.source == Listen.Source.lastfm }.map(\.trackId))
            var scores: [Int64: Score] = [:]
            var weighted: [Int64: Int] = [:]
            for play in plays {
                if play.source == Listen.Source.summary, withLastFM.contains(play.trackId) { continue }
                let age = max(today - play.day, 0)
                var score = scores[play.trackId] ?? Score()
                if play.counted {
                    score.plays += play.count
                    score.lastDay = max(score.lastDay ?? play.day, play.day)
                    weighted[play.trackId, default: 0] += Discovery.decayed(1000, age: age) * play.count
                } else if play.skipped {
                    score.skips += play.count
                    weighted[play.trackId, default: 0] -= Discovery.decayed(400, age: age) * play.count
                }
                scores[play.trackId] = score
            }
            for song in songs {
                var score = scores[song.id] ?? Score()
                var value = weighted[song.id] ?? 0
                if song.loved { value += 3000 }
                value += max(song.rating - 2, 0) * 1000
                score.affinity = max(value, 0)
                scores[song.id] = score
            }
            self.scores = scores
        }

        public subscript(id: Int64) -> Score { scores[id] ?? Score() }
    }

    /// `value` halved every 90 days of `age` (straight lines in between), in whole numbers.
    static func decayed(_ value: Int, age: Int) -> Int {
        let halvings = age / 90
        guard halvings < 20 else { return 0 }
        let start = value >> halvings
        return start - (start / 2) * (age % 90) / 90
    }
}

// MARK: - Random

extension Discovery {
    /// SplitMix64, seeded from text with FNV-1a: the same numbers on every platform.
    public struct Random: Sendable {
        private var state: UInt64

        public init(seed text: String) {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in text.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            state = hash
        }

        public mutating func next() -> UInt64 {
            state = state &+ 0x9e37_79b9_7f4a_7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
            z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
            return z ^ (z >> 31)
        }

        /// 0 up to (not including) `bound`.
        public mutating func below(_ bound: UInt64) -> UInt64 {
            bound == 0 ? 0 : next() % bound
        }

        /// An index of `weights` drawn in proportion to them (nil when all are 0).
        public mutating func weighted(_ weights: [Int]) -> Int? {
            let total = weights.reduce(UInt64(0)) { $0 + UInt64(max($1, 0)) }
            guard total > 0 else { return nil }
            var target = below(total)
            for (index, weight) in weights.enumerated() where weight > 0 {
                if target < UInt64(weight) { return index }
                target -= UInt64(weight)
            }
            return nil
        }
    }

    /// Code point order (what Windows compares too), for lists drawn from to be in the same order everywhere.
    static func ordered(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars) { $0.value < $1.value }
    }

    /// The text a day's picks are seeded with.
    static func seed(_ today: Int, _ kind: Kind) -> String { "groovelight|\(today)|\(kind.rawValue)" }
}
