import Foundation

extension Discovery {
    /// Song, Album and Artist of the Day. A day's pick, once made, is kept (`PastPick` with today's day), so it stays the
    /// same all day however the log changes; "Something else" draws the next ones with the same seed.
    public struct DailyPicks: Sendable {
        public let songs: [Song]
        public let taste: Taste
        public let today: Int
        public let past: [PastPick]
        private let byId: [Int64: Song]

        /// How long a pick stays out of the draw.
        public static let rest: [Kind: Int] = [.song: 90, .album: 30, .artist: 14]

        public init(songs: [Song], plays: [Play], past: [PastPick], today: Int) {
            self.songs = songs.sorted { $0.id < $1.id }
            taste = Taste(songs: songs, plays: plays, today: today)
            self.today = today
            self.past = past
            byId = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }

        /// Today's pick of a kind: the one kept for today, or the first draw.
        public func pick(_ kind: Kind) -> Pick? {
            if let kept = past.first(where: { $0.day == today && $0.kind == kind }),
               let pick = make(kind, key: kept.key, reason: kept.reason.flatMap(Reason.init(code:))) {
                return pick
            }
            return draw(kind, count: 1).first
        }

        /// The first `count` draws of the day for a kind (the pick, then "Something else").
        public func draw(_ kind: Kind, count: Int) -> [Pick] {
            let resting = Set(past.filter { $0.kind == kind && $0.day < today && today - $0.day < Self.rest[kind]! }.map(\.key))
            var pools = candidates(kind).map { pool in (pool.share, pool.items.filter { !resting.contains($0.key) }) }
            var random = Random(seed: Discovery.seed(today, kind))
            var picks: [Pick] = []
            while picks.count < count {
                let shares = pools.map { $0.1.isEmpty ? 0 : $0.0 }
                guard let poolIndex = random.weighted(shares),
                      let itemIndex = random.weighted(pools[poolIndex].1.map(\.weight)) else { break }
                let item = pools[poolIndex].1.remove(at: itemIndex)
                for index in pools.indices { pools[index].1.removeAll { $0.key == item.key } }
                if let pick = make(kind, key: item.key, reason: item.reason) { picks.append(pick) }
            }
            return picks
        }

        struct Candidate {
            var key: String
            var weight: Int
            var reason: Reason
        }

        struct Pool {
            /// How often the draw goes to this pool (out of all non-empty pools' shares).
            var share: Int
            var items: [Candidate]
        }

        func candidates(_ kind: Kind) -> [Pool] {
            switch kind {
            case .song: songCandidates()
            case .album: albumCandidates()
            case .artist: artistCandidates()
            }
        }

        // MARK: Songs

        private func songCandidates() -> [Pool] {
            var rediscover: [Candidate] = []
            var gems: [Candidate] = []
            var new: [Candidate] = []
            var unplayed: [Candidate] = []
            for song in songs {
                let score = taste[song.id]
                let key = String(song.id)
                if score.plays >= 3, let last = score.lastDay, today - last >= 60 {
                    let since = today - last
                    rediscover.append(Candidate(key: key, weight: (score.affinity + score.plays * 200) * min(since, 730) / 365 + 1,
                                                reason: .rediscover(plays: score.plays, daysSince: since)))
                } else if (song.loved || song.rating >= 4) && score.plays < 3 {
                    gems.append(Candidate(key: key, weight: 1000 + song.rating * 200 + (song.loved ? 1000 : 0),
                                          reason: .hiddenGem(loved: song.loved, rating: song.rating)))
                } else if today - song.addedDay <= 60 && score.plays < 2 {
                    new.append(Candidate(key: key, weight: max(1000 - (today - song.addedDay) * 10, 100),
                                         reason: .newToYou(daysSinceAdded: today - song.addedDay)))
                } else if score.plays == 0 {
                    unplayed.append(Candidate(key: key, weight: 1, reason: .unplayed))
                }
            }
            return [Pool(share: 60, items: rediscover), Pool(share: 30, items: gems), Pool(share: 10, items: new),
                    Pool(share: rediscover.isEmpty && gems.isEmpty && new.isEmpty ? 1 : 0, items: unplayed)]
        }

        // MARK: Albums

        struct Group {
            var key: String
            var songs: [Song] = []
            var affinity = 0
            var plays = 0
            var lastDay: Int?
        }

        private func groups(_ key: (Song) -> String?) -> [Group] {
            var groups: [String: Group] = [:]
            for song in songs {
                guard let name = key(song) else { continue }
                let score = taste[song.id]
                var group = groups[name] ?? Group(key: name)
                group.songs.append(song)
                group.affinity += score.affinity
                group.plays += score.plays
                if let last = score.lastDay { group.lastDay = max(group.lastDay ?? last, last) }
                groups[name] = group
            }
            return groups.values.sorted { Discovery.ordered($0.key, $1.key) }
        }

        private func albumCandidates() -> [Pool] {
            let thisYear = Discovery.year(ofDay: today)
            var rediscover: [Candidate] = []
            var anniversaries: [Candidate] = []
            var new: [Candidate] = []
            var any: [Candidate] = []
            for album in groups({ $0.albumKey.isEmpty ? nil : $0.albumKey }) {
                let years = album.songs.compactMap(\.year).min().map { thisYear - $0 }
                if album.plays >= 5, let last = album.lastDay, today - last >= 45 {
                    let since = today - last
                    rediscover.append(Candidate(key: album.key, weight: (album.affinity + album.plays * 100) * min(since, 730) / 365 + 1,
                                                reason: .rediscover(plays: album.plays, daysSince: since)))
                } else if let years, years >= 10, years % 5 == 0 {
                    anniversaries.append(Candidate(key: album.key, weight: album.plays > 0 ? 1000 + album.plays * 20 : 300,
                                                   reason: .anniversary(years: years)))
                } else if let added = album.songs.map(\.addedDay).max(), today - added <= 60, album.plays < 3 {
                    new.append(Candidate(key: album.key, weight: 1000, reason: .newToYou(daysSinceAdded: today - added)))
                } else {
                    any.append(Candidate(key: album.key, weight: 1, reason: album.plays == 0 ? .unplayed : .favorite(plays: album.plays)))
                }
            }
            return [Pool(share: 55, items: rediscover), Pool(share: 20, items: anniversaries), Pool(share: 25, items: new),
                    Pool(share: rediscover.isEmpty && anniversaries.isEmpty && new.isEmpty ? 1 : 0, items: any)]
        }

        // MARK: Artists

        private func artistCandidates() -> [Pool] {
            var favorites: [Candidate] = []
            var unplayed: [Candidate] = []
            for artist in groups({ $0.artist.isEmpty ? nil : $0.artist }) {
                if artist.plays > 0 {
                    favorites.append(Candidate(key: artist.key, weight: Discovery.squareRoot(artist.affinity) + 1,
                                               reason: .favorite(plays: artist.plays)))
                } else if artist.songs.count >= 3 {
                    unplayed.append(Candidate(key: artist.key, weight: 1, reason: .unplayed))
                }
            }
            return [Pool(share: 85, items: favorites), Pool(share: 15, items: unplayed)]
        }

        // MARK: Picks

        private func make(_ kind: Kind, key: String, reason: Reason? = nil) -> Pick? {
            switch kind {
            case .song:
                guard let id = Int64(key), byId[id] != nil else { return nil }
                return Pick(kind: .song, key: key, reason: reason ?? reasonFor(kind, key: key), trackIds: [id])
            case .album:
                let tracks = songs.filter { $0.albumKey == key }.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
                guard !tracks.isEmpty else { return nil }
                return Pick(kind: .album, key: key, reason: reason ?? reasonFor(kind, key: key), trackIds: tracks.map(\.id))
            case .artist:
                let essentials = essentials(of: key)
                guard !essentials.isEmpty else { return nil }
                return Pick(kind: .artist, key: key, reason: reason ?? reasonFor(kind, key: key), trackIds: essentials)
            }
        }

        /// The reason of a kept pick (worked out again from today's draw, or as a favorite).
        private func reasonFor(_ kind: Kind, key: String) -> Reason {
            candidates(kind).lazy.flatMap(\.items).first { $0.key == key }?.reason ?? .favorite(plays: 0)
        }

        /// An artist's most liked songs (up to 15), then up to 5 never played, for Artist of the Day.
        public func essentials(of artist: String) -> [Int64] {
            let theirs = songs.filter { $0.artist == artist }
            let liked = theirs.filter { taste[$0.id].affinity > 0 }
                .sorted { (taste[$0.id].affinity, -$0.id) > (taste[$1.id].affinity, -$1.id) }
                .prefix(15)
            var random = Random(seed: Discovery.seed(today, .artist) + "|" + artist)
            var unplayed = theirs.filter { taste[$0.id].plays == 0 && taste[$0.id].affinity == 0 }
            var extra: [Song] = []
            while extra.count < 5, !unplayed.isEmpty {
                extra.append(unplayed.remove(at: Int(random.below(UInt64(unplayed.count)))))
            }
            return (liked + extra).map(\.id)
        }
    }

    /// The whole number square root (rounded down).
    static func squareRoot(_ value: Int) -> Int {
        guard value > 0 else { return 0 }
        var x = Int(Double(value).squareRoot())
        while x * x > value { x -= 1 }
        while (x + 1) * (x + 1) <= value { x += 1 }
        return x
    }
}
