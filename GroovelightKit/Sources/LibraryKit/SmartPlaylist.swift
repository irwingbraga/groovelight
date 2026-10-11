import Foundation
import GRDB

/// Rules of a smart playlist, stored as JSON in `playlist.smartRules`. Evaluated as SQL, so the playlist stays current
/// as the library changes.
public struct SmartPlaylistRules: Codable, Hashable, Sendable {
    public enum Match: String, Codable, CaseIterable, Sendable {
        case all, any
    }

    public var match: Match
    public var rules: [SmartRule]
    public var limit: SmartLimit?

    public init(match: Match = .all, rules: [SmartRule] = [SmartRule()], limit: SmartLimit? = nil) {
        self.match = match
        self.rules = rules
        self.limit = limit
    }
}

// MARK: - Fields and operators

public enum SmartField: String, Codable, CaseIterable, Sendable, Identifiable {
    case title, artist, album, albumArtist, composer, genre, comment, kind
    case year, rating, plays, skips, time, bitrate, sampleRate, bitDepth, bpm
    case dateAdded, lastPlayed
    case loved, compilation, hasArtwork, hasLyrics
    case quality

    public var id: Self { self }

    public enum Kind: Sendable {
        case text, number, date, bool, quality
    }

    public var kind: Kind {
        switch self {
        case .title, .artist, .album, .albumArtist, .composer, .genre, .comment, .kind: .text
        case .year, .rating, .plays, .skips, .time, .bitrate, .sampleRate, .bitDepth, .bpm: .number
        case .dateAdded, .lastPlayed: .date
        case .loved, .compilation, .hasArtwork, .hasLyrics: .bool
        case .quality: .quality
        }
    }

    public var displayName: String {
        switch self {
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .albumArtist: "Album Artist"
        case .composer: "Composer"
        case .genre: "Genre"
        case .comment: "Comments"
        case .kind: "Format"
        case .year: "Year"
        case .rating: "Rating"
        case .plays: "Plays"
        case .skips: "Skips"
        case .time: "Time"
        case .bitrate: "Bit Rate"
        case .sampleRate: "Sample Rate"
        case .bitDepth: "Bit Depth"
        case .bpm: "BPM"
        case .dateAdded: "Date Added"
        case .lastPlayed: "Last Played"
        case .loved: "Loved"
        case .compilation: "Compilation"
        case .hasArtwork: "Has Artwork"
        case .hasLyrics: "Has Lyrics"
        case .quality: "Quality"
        }
    }

    /// Unit shown after a number value; values are entered in this unit.
    public var unit: String? {
        switch self {
        case .time: "minutes"
        case .bitrate: "kbps"
        case .sampleRate: "kHz"
        case .bitDepth: "bit"
        case .rating: "stars"
        default: nil
        }
    }

    /// Multiplier from the entered unit to the stored value (minutes to seconds, kHz to Hz).
    var scale: Double {
        switch self {
        case .time: 60
        case .sampleRate: 1000
        default: 1
        }
    }

    /// SQL expression over the `track` table. Only fixed strings: values are always bound as arguments.
    var sql: String {
        switch self {
        case .title: "title"
        case .artist: "COALESCE(artist, '')"
        case .album: "COALESCE(album, '')"
        case .albumArtist: "COALESCE(NULLIF(albumArtist, ''), artist, '')"
        case .composer: "COALESCE(composer, '')"
        case .genre: "COALESCE(genre, '')"
        case .comment: "COALESCE(comment, '')"
        case .kind: "COALESCE(format, '')"
        case .year: "year"
        case .rating: "rating"
        case .plays: "playCount"
        case .skips: "skipCount"
        case .time: "duration"
        case .bitrate: "bitrate"
        case .sampleRate: "sampleRate"
        case .bitDepth: "bitDepth"
        case .bpm: "bpm"
        case .dateAdded: "dateAdded"
        case .lastPlayed: "lastPlayedAt"
        case .loved: "isLoved"
        case .compilation: "isCompilation"
        case .hasArtwork: "(artworkHash IS NOT NULL)"
        case .hasLyrics: "(COALESCE(lyrics, '') != '' OR COALESCE(fetchedLyrics, '') != '')"
        case .quality: "\(SmartPlaylistSQL.qualityFunction)(format, sampleRate, bitDepth, bitrate)"
        }
    }
}

public enum SmartOperator: String, Codable, CaseIterable, Sendable, Identifiable {
    case contains, doesNotContain, `is`, isNot, beginsWith, endsWith
    case greaterThan, lessThan, inRange
    case inTheLast, notInTheLast, isBefore, isAfter
    case isTrue, isFalse
    case isAtLeast

    public var id: Self { self }

    public static func operators(for kind: SmartField.Kind) -> [SmartOperator] {
        switch kind {
        case .text: [.contains, .doesNotContain, .is, .isNot, .beginsWith, .endsWith]
        case .number: [.is, .isNot, .greaterThan, .lessThan, .inRange]
        case .date: [.inTheLast, .notInTheLast, .isAfter, .isBefore]
        case .bool: [.isTrue, .isFalse]
        case .quality: [.is, .isNot, .isAtLeast]
        }
    }

    public var displayName: String {
        switch self {
        case .contains: "contains"
        case .doesNotContain: "does not contain"
        case .is: "is"
        case .isNot: "is not"
        case .beginsWith: "begins with"
        case .endsWith: "ends with"
        case .greaterThan: "is greater than"
        case .lessThan: "is less than"
        case .inRange: "is in the range"
        case .inTheLast: "is in the last"
        case .notInTheLast: "is not in the last"
        case .isBefore: "is before"
        case .isAfter: "is after"
        case .isTrue: "is true"
        case .isFalse: "is false"
        case .isAtLeast: "is at least"
        }
    }
}

public enum PeriodUnit: String, Codable, CaseIterable, Sendable, Identifiable {
    case days, weeks, months

    public var id: Self { self }
    var days: Int {
        switch self {
        case .days: 1
        case .weeks: 7
        case .months: 30
        }
    }
}

extension QualityTier: Codable {}

/// One condition. Every value kind is stored so switching the field or operator in the editor keeps what was typed.
public struct SmartRule: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var field: SmartField
    public var op: SmartOperator
    public var text: String
    public var number: Double
    /// Upper bound for `inRange`.
    public var number2: Double
    public var date: Date
    public var period: Int
    public var periodUnit: PeriodUnit
    public var quality: QualityTier

    public init(field: SmartField = .artist, op: SmartOperator = .contains, text: String = "", number: Double = 0,
                number2: Double = 0, date: Date = .now, period: Int = 2, periodUnit: PeriodUnit = .weeks,
                quality: QualityTier = .lossless) {
        id = UUID()
        self.field = field
        self.op = op
        self.text = text
        self.number = number
        self.number2 = number2
        self.date = date
        self.period = period
        self.periodUnit = periodUnit
        self.quality = quality
    }

    /// Changes the field, keeping the operator when the new field supports it.
    public mutating func setField(_ newField: SmartField) {
        field = newField
        let allowed = SmartOperator.operators(for: newField.kind)
        if !allowed.contains(op) { op = allowed[0] }
    }
}

// MARK: - Limit

public struct SmartLimit: Codable, Hashable, Sendable {
    public enum Unit: String, Codable, CaseIterable, Sendable, Identifiable {
        case songs, minutes, hours, megabytes, gigabytes
        public var id: Self { self }
        public var displayName: String {
            switch self {
            case .songs: "songs"
            case .minutes: "minutes"
            case .hours: "hours"
            case .megabytes: "MB"
            case .gigabytes: "GB"
            }
        }
    }

    public enum Selection: String, Codable, CaseIterable, Sendable, Identifiable {
        case random, title, album, artist, genre
        case highestRated, lowestRated, mostPlayed, leastPlayed
        case mostRecentlyPlayed, leastRecentlyPlayed, mostRecentlyAdded, leastRecentlyAdded

        public var id: Self { self }
        public var displayName: String {
            switch self {
            case .random: "random"
            case .title: "title"
            case .album: "album"
            case .artist: "artist"
            case .genre: "genre"
            case .highestRated: "highest rating"
            case .lowestRated: "lowest rating"
            case .mostPlayed: "most played"
            case .leastPlayed: "least played"
            case .mostRecentlyPlayed: "most recently played"
            case .leastRecentlyPlayed: "least recently played"
            case .mostRecentlyAdded: "most recently added"
            case .leastRecentlyAdded: "least recently added"
            }
        }
    }

    public var count: Int
    public var unit: Unit
    public var selectedBy: Selection
    /// Seed for `random`: a stable shuffle, so the playlist does not reshuffle every time a play count changes.
    public var seed: Int

    public init(count: Int = 25, unit: Unit = .songs, selectedBy: Selection = .random, seed: Int = Int.random(in: 1...1_000_000)) {
        self.count = count
        self.unit = unit
        self.selectedBy = selectedBy
        self.seed = seed
    }

    func orderSQL() -> String {
        switch selectedBy {
        // Multiplicative hash of the id: a fixed pseudo-random order per seed.
        case .random: "((id + \(seed)) * 2654435761) % 4294967291"
        case .title: "title COLLATE NOCASE"
        case .album: "album COLLATE NOCASE, discNumber, trackNumber"
        case .artist: "artist COLLATE NOCASE, album COLLATE NOCASE, discNumber, trackNumber"
        case .genre: "genre COLLATE NOCASE, artist COLLATE NOCASE"
        case .highestRated: "rating DESC, playCount DESC"
        case .lowestRated: "rating, playCount"
        case .mostPlayed: "playCount DESC, lastPlayedAt DESC"
        case .leastPlayed: "playCount, lastPlayedAt"
        case .mostRecentlyPlayed: "lastPlayedAt IS NULL, lastPlayedAt DESC"
        case .leastRecentlyPlayed: "lastPlayedAt IS NOT NULL, lastPlayedAt"
        case .mostRecentlyAdded: "dateAdded DESC"
        case .leastRecentlyAdded: "dateAdded"
        }
    }

    /// Size of a track in the limit's unit.
    func size(of track: Track) -> Double {
        switch unit {
        case .songs: 1
        case .minutes: track.duration / 60
        case .hours: track.duration / 3600
        case .megabytes: Double(track.fileSize) / 1_000_000
        case .gigabytes: Double(track.fileSize) / 1_000_000_000
        }
    }
}

// MARK: - SQL

public enum SmartPlaylistSQL {
    static let qualityFunction = "glQualityTier"

    /// `glQualityTier(format, sampleRate, bitDepth, bitrate)`: the `QualityTier` raw value, computed by `AudioSpec` so
    /// smart playlists agree with the badges.
    static let qualityTierFunction = DatabaseFunction(qualityFunction, argumentCount: 4, pure: true) { values in
        let spec = AudioSpec(formatName: String.fromDatabaseValue(values[0]), sampleRate: Double.fromDatabaseValue(values[1]),
                             bitDepth: Int.fromDatabaseValue(values[2]), bitrate: Double.fromDatabaseValue(values[3]), channels: nil)
        return spec.tier.rawValue
    }

    /// WHERE clause and arguments for the rules (an empty rule list matches every track).
    static func whereClause(_ rules: SmartPlaylistRules, now: Date = .now) -> (String, StatementArguments) {
        var arguments = StatementArguments()
        let parts = rules.rules.map { condition($0, now: now, arguments: &arguments) }
        guard !parts.isEmpty else { return ("1", arguments) }
        let joiner = rules.match == .all ? " AND " : " OR "
        return (parts.map { "(\($0))" }.joined(separator: joiner), arguments)
    }

    static func condition(_ rule: SmartRule, now: Date, arguments: inout StatementArguments) -> String {
        let column = rule.field.sql
        func bind(_ value: (any DatabaseValueConvertible)?) -> String {
            _ = arguments.append(contentsOf: [value])
            return "?"
        }
        func like(_ pattern: String) -> String {
            "\(column) LIKE \(bind(pattern)) ESCAPE '\\'"
        }
        let escaped = rule.text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")

        switch (rule.field.kind, rule.op) {
        case (.text, .contains): return like("%\(escaped)%")
        case (.text, .doesNotContain): return "NOT (\(like("%\(escaped)%")))"
        case (.text, .is): return "\(column) = \(bind(rule.text)) COLLATE NOCASE"
        case (.text, .isNot): return "\(column) != \(bind(rule.text)) COLLATE NOCASE"
        case (.text, .beginsWith): return like("\(escaped)%")
        case (.text, .endsWith): return like("%\(escaped)")

        case (.number, let op):
            let value = rule.number * rule.field.scale
            let upper = rule.number2 * rule.field.scale
            // Whole units compare with a tolerance (a 3:59.6 song "is 4 minutes"; 44.1 kHz).
            let tolerance = rule.field == .time ? 30.0 : (rule.field == .bitrate ? 2 : 0.001)
            switch op {
            case .is: return "\(column) BETWEEN \(bind(value - tolerance)) AND \(bind(value + tolerance))"
            case .isNot: return "COALESCE(\(column) NOT BETWEEN \(bind(value - tolerance)) AND \(bind(value + tolerance)), 1)"
            case .greaterThan: return "\(column) > \(bind(value))"
            case .lessThan: return "COALESCE(\(column), 0) < \(bind(value))"
            case .inRange: return "\(column) BETWEEN \(bind(min(value, upper) - tolerance)) AND \(bind(max(value, upper) + tolerance))"
            default: return "1"
            }

        case (.date, let op):
            switch op {
            case .inTheLast, .notInTheLast:
                let since = now.addingTimeInterval(-Double(rule.period * rule.periodUnit.days) * 86_400)
                return op == .inTheLast ? "\(column) >= \(bind(since))" : "(\(column) IS NULL OR \(column) < \(bind(since)))"
            case .isAfter:
                return "\(column) >= \(bind(Calendar.current.startOfDay(for: rule.date).addingTimeInterval(86_400)))"
            case .isBefore:
                return "\(column) < \(bind(Calendar.current.startOfDay(for: rule.date)))"
            default: return "1"
            }

        case (.bool, .isTrue): return "\(column) = 1"
        case (.bool, .isFalse): return "\(column) = 0"

        case (.quality, .is): return "\(column) = \(bind(rule.quality.rawValue))"
        case (.quality, .isNot): return "\(column) != \(bind(rule.quality.rawValue))"
        // Tiers are ordered standard, high quality, lossless, Hi-Res, DSD: "at least Lossless" includes Hi-Res and DSD.
        case (.quality, .isAtLeast): return "\(column) >= \(bind(rule.quality.rawValue))"

        default: return "1"
        }
    }
}

extension LibraryDatabase {
    /// Tracks matching smart playlist rules: ordered by the limit's selection when there is a limit, otherwise like an
    /// album list (artist, album, disc, track).
    public static func tracks(_ db: Database, rules: SmartPlaylistRules, now: Date = .now) throws -> [Track] {
        let (whereSQL, arguments) = SmartPlaylistSQL.whereClause(rules, now: now)
        let defaultOrder = "COALESCE(NULLIF(albumArtist, ''), artist) COLLATE NOCASE, album COLLATE NOCASE, discNumber, trackNumber, title COLLATE NOCASE"
        guard let limit = rules.limit else {
            return try Track.fetchAll(db, sql: "SELECT * FROM track WHERE \(whereSQL) ORDER BY \(defaultOrder)", arguments: arguments)
        }
        let ordered = try Track.fetchAll(db, sql: "SELECT * FROM track WHERE \(whereSQL) ORDER BY \(limit.orderSQL()), id",
                                         arguments: arguments)
        if limit.unit == .songs { return Array(ordered.prefix(max(limit.count, 0))) }
        var total = 0.0
        var result: [Track] = []
        for track in ordered {
            let size = limit.size(of: track)
            if total + size > Double(limit.count) { break }
            total += size
            result.append(track)
        }
        return result
    }

    public func createSmartPlaylist(named name: String, rules: SmartPlaylistRules, cover: PlaylistCover? = nil) throws -> Playlist {
        try writer.write { db in
            var playlist = Playlist(name: name, smartRules: try JSONEncoder().encode(rules), cover: cover)
            try playlist.insert(db)
            return playlist
        }
    }

    public func updateSmartPlaylist(_ playlistId: Int64, name: String, rules: SmartPlaylistRules) throws {
        let data = try JSONEncoder().encode(rules)
        try writer.write { db in
            try db.execute(sql: "UPDATE playlist SET name = ?, smartRules = ? WHERE id = ?", arguments: [name, data, playlistId])
        }
    }
}

extension Playlist {
    public var rules: SmartPlaylistRules? {
        smartRules.flatMap { try? JSONDecoder().decode(SmartPlaylistRules.self, from: $0) }
    }
}
