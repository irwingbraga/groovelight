import Foundation

/// A cover image found online.
public struct ArtworkCandidate: Hashable, Sendable {
    public enum Source: String, Sendable {
        case coverArtArchive = "Cover Art Archive"
        case iTunes = "Apple Music"
        case wikimedia = "Wikimedia Commons"
    }

    public var source: Source
    public var url: URL

    public init(source: Source, url: URL) {
        self.source = source
        self.url = url
    }
}

/// Album covers from the Cover Art Archive (by MusicBrainz release) and the iTunes Search API (by artist and album).
public final class ArtworkClient: Sendable {
    private let fetcher: any HTTPFetching
    private let identity: ClientIdentity

    public init(fetcher: any HTTPFetching = URLSessionFetcher(), identity: ClientIdentity) {
        self.fetcher = fetcher
        self.identity = identity
    }

    /// Front cover of a release (1200 px), falling back to its release group's cover.
    public func coverArtArchive(releaseId: String, releaseGroupId: String?) -> [ArtworkCandidate] {
        var candidates = [ArtworkCandidate(source: .coverArtArchive, url: URL(string: "https://coverartarchive.org/release/\(releaseId)/front-1200")!)]
        if let releaseGroupId {
            candidates.append(ArtworkCandidate(source: .coverArtArchive,
                                               url: URL(string: "https://coverartarchive.org/release-group/\(releaseGroupId)/front-1200")!))
        }
        return candidates
    }

    /// Best matching album cover from the iTunes Search API, at up to 3000 px.
    public func iTunes(album: String, artist: String?) async throws -> ArtworkCandidate? {
        struct Response: Codable {
            struct Result: Codable {
                var collectionName: String?
                var artistName: String?
                var artworkUrl100: String?
            }
            var results: [Result]
        }
        let term = [artist, album].compactMap { $0 }.joined(separator: " ")
        let data = try await fetcher.get(.build("https://itunes.apple.com/search", ["term": term, "entity": "album", "limit": "10"]),
                                         identity: identity)
        let results = try JSONDecoder().decode(Response.self, from: data).results
        let wantedAlbum = album.matchKey
        let wantedArtist = artist?.matchKey
        let best = results.first { result in
            guard let name = result.collectionName?.matchKey else { return false }
            let albumMatches = name == wantedAlbum || name.hasPrefix(wantedAlbum)
            let artistMatches = wantedArtist == nil || result.artistName?.matchKey == wantedArtist
            return albumMatches && artistMatches
        }
        guard let small = best?.artworkUrl100 else { return nil }
        // "…/100x100bb.jpg" is a resizable template.
        let large = small.replacingOccurrences(of: "100x100bb", with: "3000x3000bb")
        return URL(string: large).map { ArtworkCandidate(source: .iTunes, url: $0) }
    }

    /// Downloads a candidate; nil when the service has no image.
    public func download(_ candidate: ArtworkCandidate) async throws -> Data? {
        do {
            return try await fetcher.get(candidate.url, identity: identity, accept: "image/*")
        } catch MetadataError.notFound {
            return nil
        }
    }
}
