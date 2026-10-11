import Foundation
import LibraryKit

// MARK: - MusicBrainz relationships

/// A MusicBrainz relationship: who did what (performer with instruments, producer, engineer, songwriter...), or a link
/// to a work (the composition), a place (studio) or a URL.
public struct MBRelation: Codable, Hashable, Sendable {
    public struct Work: Codable, Hashable, Sendable {
        public var id: String
        public var title: String?
        public var relations: [MBRelation]?
    }

    public struct Place: Codable, Hashable, Sendable {
        public var id: String
        public var name: String
    }

    public struct URLTarget: Codable, Hashable, Sendable {
        public var resource: String
    }

    public var type: String
    public var attributes: [String]?
    public var targetCredit: String?
    public var artist: MBArtistCredit.Artist?
    public var work: Work?
    public var place: Place?
    public var url: URLTarget?

    enum CodingKeys: String, CodingKey {
        case type, attributes, artist, work, place, url
        case targetCredit = "target-credit"
    }

    /// Name as credited on this release, falling back to the artist's name.
    var creditedName: String? {
        if let credit = targetCredit, !credit.isEmpty { return credit }
        return artist?.name
    }
}

// MARK: - Credits model (stored as JSON in the library)

/// One person (or group, or studio) and what they did, e.g. "Colin Greenwood: bass guitar, percussion".
public struct Credit: Codable, Hashable, Sendable {
    public var name: String
    /// MusicBrainz artist id, when the credit is an artist.
    public var artistId: String?
    public var roles: [String]
}

public struct CreditSection: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case musicians = "Musicians"
        case songwriting = "Songwriting"
        case production = "Production"
        case recordedAt = "Recorded At"
        case design = "Artwork & Design"
    }

    public var kind: Kind
    public var credits: [Credit]
    public var id: Kind { kind }
}

/// An album's background from Wikipedia.
public struct AlbumAbout: Codable, Hashable, Sendable {
    public var title: String
    public var summary: String
    public var url: URL
    /// Wikipedia language code ("en", "pt").
    public var language: String
    /// The article's main image (Wikimedia Commons), at a size suited to the app. Nil in info cached before images.
    public var imageURL: URL?

    public init(title: String, summary: String, url: URL, language: String, imageURL: URL? = nil) {
        self.title = title
        self.summary = summary
        self.url = url
        self.language = language
        self.imageURL = imageURL
    }
}

/// Everything fetched for an album page: credits for the whole album and for each song, and the Wikipedia summary.
public struct AlbumInfo: Codable, Hashable, Sendable {
    public var releaseId: String?
    public var releaseTitle: String?
    public var sections: [CreditSection]
    /// Credits per MusicBrainz recording id.
    public var trackSections: [String: [CreditSection]]
    /// Local track id (as a string, for JSON) to MusicBrainz recording id.
    public var localRecordings: [String: String]
    /// Credits of the release itself (mastering, design...), which apply to every song. Nil in info cached before
    /// this was kept.
    public var releaseSections: [CreditSection]?
    public var about: AlbumAbout?
    public var fetchedAt: Date

    public static func notFound(at date: Date = .now) -> AlbumInfo {
        AlbumInfo(releaseId: nil, releaseTitle: nil, sections: [], trackSections: [:], localRecordings: [:], releaseSections: [], about: nil,
                  fetchedAt: date)
    }

    public var isEmpty: Bool { sections.isEmpty && about == nil }

    /// Index entries: everyone credited on the album (track nil; `wholeRelease` for release credits), and on each local
    /// song.
    public func creditEntries(albumKey: String) -> [CreditIndexEntry] {
        let releaseWide = Set((releaseSections ?? []).flatMap(\.credits).map(\.name))
        var entries = sections.flatMap { section in
            section.credits.map { CreditIndexEntry(person: CreditPerson(name: $0.name, artistId: $0.artistId), albumKey: albumKey,
                                                   trackId: nil, roles: $0.roles, wholeRelease: releaseWide.contains($0.name)) }
        }
        for (local, recording) in localRecordings {
            guard let trackId = Int64(local) else { continue }
            for section in trackSections[recording] ?? [] {
                entries += section.credits.map {
                    CreditIndexEntry(person: CreditPerson(name: $0.name, artistId: $0.artistId), albumKey: albumKey, trackId: trackId, roles: $0.roles)
                }
            }
        }
        return entries
    }

    /// Credits of one local song.
    public func sections(forTrack track: Track) -> [CreditSection] {
        let recording = track.musicBrainzRecordingId ?? track.id.flatMap { localRecordings[String($0)] }
        return recording.flatMap { trackSections[$0] } ?? []
    }
}

// MARK: - Building credits

public enum CreditsBuilder {
    /// Attributes that qualify a role rather than name an instrument.
    private static let qualifiers: Set<String> = ["additional", "guest", "solo", "assistant", "co", "executive", "associate", "minor"]

    /// Section and display role for one relationship, nil for relationships that are not credits (links, copyright...).
    static func classify(_ relation: MBRelation, isWork: Bool) -> (CreditSection.Kind, [String])? {
        let attributes = relation.attributes ?? []
        let qualifier = attributes.filter { qualifiers.contains($0) }
        let details = attributes.filter { !qualifiers.contains($0) }
        func role(_ base: String) -> [String] {
            let prefix = qualifier.contains("assistant") ? "assistant " : qualifier.contains("co") ? "co-" :
                qualifier.contains("executive") ? "executive " : qualifier.contains("additional") ? "additional " : ""
            return [prefix + base]
        }
        if isWork {
            switch relation.type {
            case "writer": return (.songwriting, ["songwriter"])
            case "composer": return (.songwriting, ["composer"])
            case "lyricist": return (.songwriting, ["lyrics"])
            case "librettist": return (.songwriting, ["libretto"])
            case "arranger", "instrument arranger", "vocal arranger": return (.songwriting, ["arrangement"])
            case "translator": return (.songwriting, ["translation"])
            default: return nil
            }
        }
        switch relation.type {
        case "instrument": return (.musicians, details.isEmpty ? ["instruments"] : details)
        case "vocal": return (.musicians, details.isEmpty ? ["vocals"] : details.map { $0.hasSuffix("vocals") ? $0 : "\($0) vocals" })
        case "performer": return (.musicians, ["performer"])
        case "performing orchestra": return (.musicians, ["orchestra"])
        case "conductor": return (.musicians, ["conductor"])
        case "chorus master": return (.musicians, ["chorus master"])
        case "producer": return (.production, role("producer"))
        case "engineer", "audio": return (.production, role("engineer"))
        case "sound": return (.production, role("sound engineer"))
        case "recording": return (.production, role("recording engineer"))
        case "mix": return (.production, role("mixing"))
        case "mastering": return (.production, role("mastering"))
        case "editor": return (.production, role("editing"))
        case "programming": return (.production, role("programming"))
        case "instrument arranger", "vocal arranger", "arranger", "orchestrator": return (.production, ["arrangement"])
        case "design/illustration", "design", "illustration", "graphic design", "art direction", "photography", "artwork":
            return (.design, [relation.type == "design/illustration" ? "design and illustration" : relation.type])
        case "recorded at", "recording location": return (.recordedAt, ["recording"])
        case "mixed at": return (.recordedAt, ["mixing"])
        case "mastered at": return (.recordedAt, ["mastering"])
        default: return nil
        }
    }

    /// Groups relationships into sections, merging the roles of each person (in order of first appearance).
    static func sections(from relations: [(MBRelation, isWork: Bool)]) -> [CreditSection] {
        var grouped: [CreditSection.Kind: [Credit]] = [:]
        for (relation, isWork) in relations {
            guard let (kind, roles) = classify(relation, isWork: isWork) else { continue }
            let name: String
            let id: String?
            if kind == .recordedAt, let place = relation.place {
                name = place.name
                id = nil
            } else if let credited = relation.creditedName {
                name = credited
                id = relation.artist?.id
            } else {
                continue
            }
            var credits = grouped[kind] ?? []
            if let index = credits.firstIndex(where: { $0.name == name }) {
                for role in roles where !credits[index].roles.contains(role) { credits[index].roles.append(role) }
            } else {
                credits.append(Credit(name: name, artistId: id, roles: roles))
            }
            grouped[kind] = credits
        }
        return CreditSection.Kind.allCases.compactMap { kind in grouped[kind].map { CreditSection(kind: kind, credits: $0) } }
    }

    /// The relationships of one recording: its own, plus the songwriting credits of the works it performs.
    static func relations(ofRecording recording: MBRecordingRef) -> [(MBRelation, isWork: Bool)] {
        var result: [(MBRelation, isWork: Bool)] = []
        for relation in recording.relations ?? [] {
            if relation.type == "performance", let work = relation.work {
                result += (work.relations ?? []).map { ($0, true) }
            } else {
                result.append((relation, false))
            }
        }
        return result
    }

    /// Album credits (release relationships plus every track's) and per-track credits, mapped to local songs.
    public static func albumInfo(release: MBRelease, match: ReleaseMatch?, about: AlbumAbout?, at date: Date = .now) -> AlbumInfo {
        let recordings = (release.media ?? []).flatMap(\.allTracks).compactMap(\.recording)
        var all: [(MBRelation, isWork: Bool)] = (release.relations ?? []).map { ($0, false) }
        var trackSections: [String: [CreditSection]] = [:]
        for recording in recordings {
            let relations = relations(ofRecording: recording)
            all += relations
            let sections = sections(from: relations)
            if !sections.isEmpty { trackSections[recording.id] = sections }
        }
        var localRecordings: [String: String] = [:]
        for item in match?.matches ?? [] {
            if let recording = item.track.recording?.id { localRecordings[String(item.localId)] = recording }
        }
        return AlbumInfo(releaseId: release.id, releaseTitle: release.title, sections: sections(from: all),
                         trackSections: trackSections, localRecordings: localRecordings,
                         releaseSections: sections(from: (release.relations ?? []).map { ($0, false) }), about: about, fetchedAt: date)
    }
}

// MARK: - Wikipedia

/// Album summaries from Wikipedia, found through the album's Wikidata item.
public final class WikipediaClient: Sendable {
    private let fetcher: any HTTPFetching
    private let identity: ClientIdentity

    public init(fetcher: any HTTPFetching = URLSessionFetcher(), identity: ClientIdentity) {
        self.fetcher = fetcher
        self.identity = identity
    }

    /// Summary of the article linked to a Wikidata item, in the first of `languages` that has one.
    public func summary(wikidataId: String, languages: [String]) async throws -> AlbumAbout? {
        struct Entities: Codable {
            struct Entity: Codable {
                struct Sitelink: Codable { var title: String }
                var sitelinks: [String: Sitelink]?
            }
            var entities: [String: Entity]
        }
        let sites = languages.map { "\($0)wiki" }.joined(separator: "|")
        let data = try await fetcher.get(.build("https://www.wikidata.org/w/api.php", [
            "action": "wbgetentities", "ids": wikidataId, "props": "sitelinks", "sitefilter": sites, "format": "json",
        ]), identity: identity)
        let sitelinks = try JSONDecoder().decode(Entities.self, from: data).entities[wikidataId]?.sitelinks ?? [:]
        for language in languages {
            guard let title = sitelinks["\(language)wiki"]?.title else { continue }
            if let about = try await summary(title: title, language: language) { return about }
        }
        return nil
    }

    /// The image at about 960 px: the original when it is small enough, otherwise a Commons thumbnail of that width
    /// (thumbnail URLs end in "/330px-File.jpg"). Commons only renders standard widths (330, 500, 960, 1280...; 800 is
    /// refused) and never larger than the original.
    static func imageURL(thumbnail: String?, original: String?, originalWidth: Int?, width: Int = 960) -> URL? {
        if let original, let originalWidth, originalWidth <= width { return URL(string: original) }
        if let thumbnail, let range = thumbnail.range(of: #"/\d+px-"#, options: .regularExpression) {
            return URL(string: thumbnail.replacingCharacters(in: range, with: "/\(width)px-"))
        }
        return (original ?? thumbnail).flatMap(URL.init(string:))
    }

    /// Wikipedia's summaries drop some bracketed text (roles, pronunciations) and leave "Thom Yorke ;" or "()" behind.
    static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*\(\s*[;,]?\s*\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([;,.:!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
    }

    /// Wikipedia's REST summary (first paragraphs) of an article.
    public func summary(title: String, language: String) async throws -> AlbumAbout? {
        struct Summary: Codable {
            struct URLs: Codable {
                struct Desktop: Codable { var page: String }
                var desktop: Desktop
            }
            struct Image: Codable {
                var source: String
                var width: Int?
            }
            var type: String?
            var title: String
            var extract: String?
            var contentUrls: URLs?
            var thumbnail: Image?
            var originalimage: Image?

            enum CodingKeys: String, CodingKey {
                case type, title, extract, thumbnail, originalimage
                case contentUrls = "content_urls"
            }
        }
        let path = title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
            ?? title
        guard let url = URL(string: "https://\(language).wikipedia.org/api/rest_v1/page/summary/\(path)") else { return nil }
        do {
            let data = try await fetcher.get(url, identity: identity)
            let summary = try JSONDecoder().decode(Summary.self, from: data)
            guard summary.type != "disambiguation", let extract = summary.extract, !extract.isEmpty,
                  let page = summary.contentUrls.flatMap({ URL(string: $0.desktop.page) }) else { return nil }
            let image = Self.imageURL(thumbnail: summary.thumbnail?.source, original: summary.originalimage?.source,
                                      originalWidth: summary.originalimage?.width)
            return AlbumAbout(title: summary.title, summary: Self.tidy(extract), url: page, language: language, imageURL: image)
        } catch MetadataError.notFound {
            return nil
        }
    }
}

// MARK: - Artists

public struct MBArtist: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var score: Int?
    public var disambiguation: String?
    public var relations: [MBRelation]?
}

struct MBArtistSearch: Codable { var artists: [MBArtist] }

/// What an artist page shows from the web: the Wikipedia summary, found through the artist's MusicBrainz entry.
public struct ArtistInfo: Codable, Hashable, Sendable {
    public var artistId: String?
    public var about: AlbumAbout?
    public var fetchedAt: Date
    /// The artist's photo, stored in the artwork cache.
    public var imageHash: String?
    /// Whether a photo was looked for (nil in info cached before photos).
    public var imageChecked: Bool?

    public init(artistId: String?, about: AlbumAbout?, fetchedAt: Date, imageHash: String? = nil, imageChecked: Bool? = nil) {
        self.artistId = artistId
        self.about = about
        self.fetchedAt = fetchedAt
        self.imageHash = imageHash
        self.imageChecked = imageChecked
    }

    public var isEmpty: Bool { about == nil }
}
