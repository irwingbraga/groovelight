import Foundation
import LibraryKit

/// What the matcher needs to know about a local file.
public struct LocalTrackInfo: Hashable, Sendable {
    public var id: Int64
    public var title: String
    public var artist: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    /// Seconds.
    public var duration: Double

    public init(id: Int64, title: String, artist: String?, trackNumber: Int?, discNumber: Int?, duration: Double) {
        self.id = id
        self.title = title
        self.artist = artist
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
    }

    public init?(_ track: Track) {
        guard let id = track.id else { return nil }
        // Untagged files are titled after their file name: "03 - Artist - Title" gives a better title to compare.
        let guess = FileNameGuess(track.url.deletingPathExtension().lastPathComponent)
        let untitled = track.title == track.url.deletingPathExtension().lastPathComponent
        self.init(id: id, title: untitled ? guess.title : track.title, artist: track.artist ?? (untitled ? guess.artist : nil),
                  trackNumber: track.trackNumber ?? (untitled ? guess.trackNumber : nil), discNumber: track.discNumber,
                  duration: track.duration)
    }
}

/// A local file paired with a track of a release.
public struct TrackMatch: Hashable, Sendable {
    public var localId: Int64
    public var track: MBTrack
    public var discNumber: Int
    public var trackNumber: Int
    public var trackTotal: Int
    /// 0 to 1.
    public var score: Double
}

/// How a release fits a set of local files.
public struct ReleaseMatch: Hashable, Sendable {
    public var release: MBRelease
    public var matches: [TrackMatch]
    public var unmatchedLocalIds: [Int64]
    /// 0 to 1: matched quality over the larger of the two track counts.
    public var score: Double

    public func match(for localId: Int64) -> TrackMatch? { matches.first { $0.localId == localId } }
}

public enum ReleaseMatcher {
    /// Orders search results by how likely they are the local album: search score, same track count, official
    /// status, studio album over live or compilation releases.
    ///
    /// `hits` counts, per release id, how many of the sampled local files were found on that release (when files were
    /// identified one by one); a release holding all of them is very likely the album.
    public static func rank(_ releases: [MBRelease], localCount: Int, hits: [String: Int] = [:], sampled: Int = 0) -> [MBRelease] {
        func weight(_ release: MBRelease) -> Double {
            var value = Double(release.score ?? 50) / 100 * 0.5
            if sampled > 0 { value += Double(hits[release.id] ?? 0) / Double(sampled) * 0.6 }
            let count = release.totalTracks
            if count == localCount {
                value += 0.3
            } else if count > localCount {
                // Loose files of an album: the closer the size, the likelier (the plain album over a 33-track box set).
                value += 0.15 * Double(localCount) / Double(count)
            }
            // Audio releases over video editions (DVD-Video, Blu-ray) of the same album.
            let formats = release.media?.compactMap(\.format) ?? []
            if formats.contains(where: { $0.contains("Video") || $0.contains("Blu-ray") || $0 == "DVD" }) { value -= 0.1 }
            if release.status == "Official" { value += 0.1 }
            if release.releaseGroup?.primaryType == "Album" { value += 0.05 }
            if release.releaseGroup?.secondaryTypes?.isEmpty ?? true { value += 0.05 }
            return value
        }
        var seen = Set<String>()
        return releases.filter { seen.insert($0.id).inserted }
            .enumerated()
            .sorted { lhs, rhs in
                let (a, b) = (weight(lhs.element), weight(rhs.element))
                return a == b ? lhs.offset < rhs.offset : a > b
            }
            .map(\.element)
    }

    /// Pairs local files with the release's tracks (greedy on the best pair scores).
    public static func match(_ local: [LocalTrackInfo], to release: MBRelease) -> ReleaseMatch {
        struct Slot {
            var track: MBTrack
            var disc: Int
            var number: Int
            var total: Int
        }
        let slots: [Slot] = (release.media ?? []).enumerated().flatMap { index, medium in
            let tracks = medium.allTracks
            return tracks.enumerated().map { offset, track in
                Slot(track: track, disc: medium.position ?? index + 1, number: track.position ?? offset + 1,
                     total: medium.trackCount ?? tracks.count)
            }
        }
        let multiDisc = (release.media?.count ?? 0) > 1

        var pairs: [(local: Int, slot: Int, score: Double)] = []
        for (li, file) in local.enumerated() {
            for (si, slot) in slots.enumerated() {
                let score = pairScore(file, slot.track, disc: slot.disc, number: slot.number, multiDisc: multiDisc)
                if score >= 0.45 { pairs.append((li, si, score)) }
            }
        }
        pairs.sort { $0.score > $1.score }

        var usedLocal = Set<Int>()
        var usedSlot = Set<Int>()
        var matches: [TrackMatch] = []
        for pair in pairs where !usedLocal.contains(pair.local) && !usedSlot.contains(pair.slot) {
            usedLocal.insert(pair.local)
            usedSlot.insert(pair.slot)
            let slot = slots[pair.slot]
            matches.append(TrackMatch(localId: local[pair.local].id, track: slot.track, discNumber: slot.disc,
                                      trackNumber: slot.number, trackTotal: slot.total, score: pair.score))
        }
        matches.sort { ($0.discNumber, $0.trackNumber) < ($1.discNumber, $1.trackNumber) }
        let unmatched = local.enumerated().filter { !usedLocal.contains($0.offset) }.map(\.element.id)
        let total = max(local.count, slots.count, 1)
        let score = matches.reduce(0) { $0 + $1.score } / Double(total)
        return ReleaseMatch(release: release, matches: matches, unmatchedLocalIds: unmatched, score: score)
    }

    static func pairScore(_ file: LocalTrackInfo, _ track: MBTrack, disc: Int, number: Int, multiDisc: Bool) -> Double {
        let title = file.title.matchKey.similarity(to: track.title.matchKey)

        let durationScore: Double
        if let length = track.length, file.duration > 0 {
            let difference = abs(Double(length) / 1000 - file.duration)
            durationScore = difference <= 2 ? 1 : difference <= 5 ? 0.7 : difference <= 10 ? 0.3 : 0
        } else {
            durationScore = 0.5
        }

        let numberScore: Double
        if let trackNumber = file.trackNumber {
            let discMatches = !multiDisc || (file.discNumber ?? 1) == disc
            numberScore = trackNumber == number && discMatches ? 1 : 0
        } else {
            numberScore = 0.5
        }
        return title * 0.5 + durationScore * 0.3 + numberScore * 0.2
    }

    /// Proposed tags for every matched file.
    public static func proposal(for match: ReleaseMatch) -> [Int64: TrackMetadata] {
        let release = match.release
        let isVarious = release.artistCredit?.isVariousArtists ?? false
        let albumArtist = isVarious ? "Various Artists" : release.artistName
        let discTotal = release.media?.count
        var result: [Int64: TrackMetadata] = [:]
        for item in match.matches {
            let artist = item.track.artistCredit?.displayName ?? release.artistName
            result[item.localId] = TrackMetadata(
                title: item.track.title,
                artist: artist.isEmpty ? nil : artist,
                album: release.title,
                albumArtist: albumArtist.isEmpty ? nil : albumArtist,
                genre: release.primaryGenre,
                year: release.year,
                trackNumber: item.trackNumber,
                trackTotal: item.trackTotal,
                discNumber: item.discNumber,
                discTotal: discTotal,
                isCompilation: isVarious,
                musicBrainzRecordingId: item.track.recording?.id,
                musicBrainzReleaseId: release.id
            )
        }
        return result
    }
}

/// Artist, title and track number guessed from a file name such as "03 - Artist - Title" or "03. Title".
public struct FileNameGuess: Hashable, Sendable {
    public var trackNumber: Int?
    public var artist: String?
    public var title: String

    public init(_ name: String) {
        var rest = Substring(name.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces))
        // Leading track number ("03", "1-03" for disc-track), followed by a separator.
        let digits = rest.prefix { $0.isNumber || $0 == "-" }
        if !digits.isEmpty, digits.first?.isNumber == true, let last = digits.split(separator: "-").last, let number = Int(last),
           number > 0, number < 200, rest.dropFirst(digits.count).first.map({ " .-)".contains($0) }) ?? false {
            trackNumber = number
            rest = rest.dropFirst(digits.count).drop { " .-)".contains($0) }
        }
        let parts = rest.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.count >= 2 {
            artist = parts[0]
            title = parts.dropFirst().joined(separator: " - ")
        } else {
            title = parts.first ?? name
        }
    }
}

extension String {
    /// Loose comparison key: case and diacritics folded, "&" as "and", punctuation dropped, spaces collapsed,
    /// a leading "The" removed.
    var matchKey: String {
        let folded = folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
        let cleaned = String(folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
        var words = cleaned.split(separator: " ")
        if words.first == "the", words.count > 1 { words.removeFirst() }
        return words.joined(separator: " ")
    }

    /// 1 for equal strings, down to 0, from the Levenshtein distance.
    func similarity(to other: String) -> Double {
        if self == other { return 1 }
        let a = Array(self)
        let b = Array(other)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[b.count]) / Double(Swift.max(a.count, b.count))
    }
}
