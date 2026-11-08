import Foundation
import GRDB

/// Home as the hosts make it: the day's picks (each with the next ones drawn for "Something Else") and the dashboard for
/// every range. The Mac shows it, and the phones get it over wireless sync (`GET /home`) and keep it for when the Mac
/// is away. Windows makes the same JSON (`HomeSnapshot.cs`).
public struct HomeSnapshot: Codable, Hashable, Sendable {
    public struct Card: Codable, Hashable, Sendable, Identifiable {
        public var kind: Discovery.Kind
        /// The song id, the album key or the artist name.
        public var key: String
        /// `Discovery.Reason.code`.
        public var reason: String
        /// The line under the card ("8 plays, last heard 2 months ago").
        public var reasonText: String
        public var title: String
        public var subtitle: String
        public var artworkHash: String?
        /// The songs to play for it, in order.
        public var trackIds: [Int64]

        public var id: String { "\(kind.rawValue)|\(key)" }

        public init(kind: Discovery.Kind, key: String, reason: String, reasonText: String, title: String, subtitle: String,
                    artworkHash: String?, trackIds: [Int64]) {
            self.kind = kind
            self.key = key
            self.reason = reason
            self.reasonText = reasonText
            self.title = title
            self.subtitle = subtitle
            self.artworkHash = artworkHash
            self.trackIds = trackIds
        }
    }

    /// Days since 1970 (local calendar) the picks are for.
    public var day: Int
    /// The day's pick first, then up to five more, for each kind.
    public var song: [Card] = []
    public var album: [Card] = []
    public var artist: [Card] = []
    /// Week, month, year and all time.
    public var stats: [ListeningStats] = []

    public init(day: Int) {
        self.day = day
    }

    public func cards(_ kind: Discovery.Kind) -> [Card] {
        switch kind {
        case .song: song
        case .album: album
        case .artist: artist
        }
    }

    public mutating func setCards(_ cards: [Card], for kind: Discovery.Kind) {
        switch kind {
        case .song: song = cards
        case .album: album = cards
        case .artist: artist = cards
        }
    }

    public func stats(_ range: ListeningStats.Range) -> ListeningStats? {
        stats.first { $0.range == range }
    }
}

extension LibraryDatabase {
    /// Today's Home: the picks (made and kept on the first call of the day) with five more of each kind, and, with
    /// `stats`, the dashboard for every range.
    public func homeSnapshot(now: Date = .now, zone: TimeZone = .current, stats: Bool = true, choices: Int = 6) throws -> HomeSnapshot {
        let (picks, picker) = try dailyPicks(on: now, zone: zone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return try writer.read { db in
            var snapshot = HomeSnapshot(day: Discovery.day(of: now, in: zone))
            for kind in Discovery.Kind.allCases {
                let first = picks.first { $0.kind == kind }
                let others = picker.draw(kind, count: choices).filter { $0.key != first?.key }
                let cards = try ([first].compactMap { $0 } + others).prefix(choices).compactMap { try Self.homeCard($0, db) }
                snapshot.setCards(cards, for: kind)
            }
            if stats {
                snapshot.stats = try ListeningStats.Range.allCases.map { try Self.listeningStats(db, range: $0, now: now, calendar: calendar) }
            }
            return snapshot
        }
    }

    /// A pick as Home shows it (nil when its songs are gone).
    public static func homeCard(_ pick: Discovery.Pick, _ db: Database) throws -> HomeSnapshot.Card? {
        let tracks = try tracks(db, ids: pick.trackIds)
        guard let first = tracks.first else { return nil }
        func cover(_ track: Track) -> String? { track.fetchedArtworkHash ?? track.artworkHash }
        let title: String, subtitle: String, artwork: String?
        switch pick.kind {
        case .song:
            (title, subtitle, artwork) = (first.title, first.displayArtist, cover(first))
        case .album:
            let compilation = tracks.contains(where: \.isCompilation)
            (title, subtitle, artwork) = (first.displayAlbum, compilation ? "Various Artists" : first.displayAlbumArtist, cover(first))
        case .artist:
            let photo = try artistPhotos(db, names: [pick.key])[pick.key]
            let songs = tracks.count == 1 ? "1 song" : "\(tracks.count) songs"
            (title, subtitle, artwork) = (pick.key, "Essentials, \(songs)", photo ?? tracks.lazy.compactMap(cover).first)
        }
        return HomeSnapshot.Card(kind: pick.kind, key: pick.key, reason: pick.reason.code, reasonText: pick.reason.text(for: pick.kind),
                                 title: title, subtitle: subtitle, artworkHash: artwork, trackIds: pick.trackIds)
    }
}

extension Discovery.Reason {
    /// The line under a pick (the same words on Windows).
    public func text(for kind: Discovery.Kind) -> String {
        switch self {
        case .rediscover(let plays, let days):
            return "\(plays) plays, last heard \(Self.ago(days))"
        case .hiddenGem(let loved, let rating):
            return loved ? "You love it, and have hardly played it" : "Rated \(rating) stars, hardly played"
        case .newToYou(let days):
            return days == 0 ? "Added today, not played much yet" : "Added \(Self.ago(days)), not played much yet"
        case .anniversary(let years):
            return "Released \(years) years ago"
        case .favorite(let plays):
            return plays > 1 ? "One of your favorites, \(plays) plays" : plays == 1 ? "One of your favorites, 1 play" : "One of your favorites"
        case .unplayed:
            return kind == .artist ? "Not played yet: a good day to start" : "Not played yet"
        }
    }

    public static func ago(_ days: Int) -> String {
        switch days {
        case ..<1: "today"
        case 1: "yesterday"
        case ..<14: "\(days) days ago"
        case ..<60: "\(days / 7) weeks ago"
        case ..<730: "\(days / 30) months ago"
        default: "\(days / 365) years ago"
        }
    }
}

extension Discovery.Kind {
    public var title: String {
        switch self {
        case .song: "Song of the Day"
        case .album: "Album of the Day"
        case .artist: "Artist of the Day"
        }
    }
}

/// Places as JSON object keys ({"here": 12.5}), not as a flat list, so Android and Windows read them as maps.
extension ListeningStats.Place: CodingKeyRepresentable {}
