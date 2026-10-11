import Foundation
import LibraryKit

/// Finds album metadata, covers and lyrics online for local tracks.
public final class MetadataService: Sendable {
    public let musicBrainz: MusicBrainzClient
    public let artwork: ArtworkClient
    public let lyrics: LRCLibClient
    public let wikipedia: WikipediaClient

    public init(identity: ClientIdentity, fetcher: any HTTPFetching = URLSessionFetcher()) {
        musicBrainz = MusicBrainzClient(fetcher: fetcher, identity: identity)
        artwork = ArtworkClient(fetcher: fetcher, identity: identity)
        lyrics = LRCLibClient(fetcher: fetcher, identity: identity)
        wikipedia = WikipediaClient(fetcher: fetcher, identity: identity)
    }

    public init(musicBrainz: MusicBrainzClient, artwork: ArtworkClient, lyrics: LRCLibClient, wikipedia: WikipediaClient) {
        self.musicBrainz = musicBrainz
        self.artwork = artwork
        self.lyrics = lyrics
        self.wikipedia = wikipedia
    }

    /// Credits and the Wikipedia summary for an album's songs.
    ///
    /// Uses the songs' MusicBrainz release id when they have one (from tags or Fix Metadata); otherwise searches and
    /// only accepts a confident match (most songs paired, closely). Returns `AlbumInfo.notFound()` when nothing fits.
    public func albumInfo(for tracks: [Track], languages: [String]) async throws -> AlbumInfo {
        let local = tracks.compactMap(LocalTrackInfo.init)
        var release: MBRelease?
        var match: ReleaseMatch?
        if let id = Self.commonReleaseId(tracks) {
            release = try await musicBrainz.releaseWithCredits(id: id)
            match = release.map { ReleaseMatcher.match(local, to: $0) }
        } else {
            for candidate in try await candidates(for: tracks).prefix(2) {
                let full = try await musicBrainz.releaseWithCredits(id: candidate.id)
                let attempt = ReleaseMatcher.match(local, to: full)
                if Self.isConfident(attempt, localCount: local.count) {
                    release = full
                    match = attempt
                    break
                }
            }
        }
        guard let release else { return .notFound() }

        var about: AlbumAbout?
        if let group = release.releaseGroup?.id, let wikidata = try? await musicBrainz.wikidataId(releaseGroupId: group) {
            about = try? await wikipedia.summary(wikidataId: wikidata, languages: languages)
        }
        return CreditsBuilder.albumInfo(release: release, match: match, about: about)
    }

    /// The Wikipedia summary of an artist.
    ///
    /// Names are ambiguous (two bands are called Nirvana), so the artist is found through one of their albums first: a
    /// release search for album and artist returns the exact artist id. A name search is the fallback, and only an
    /// exact, top scoring name is accepted.
    public func artistInfo(name: String, albumTitles: [String], languages: [String]) async throws -> ArtistInfo {
        let key = name.matchKey
        var artistId: String?
        for title in albumTitles.prefix(2) where artistId == nil {
            for release in try await musicBrainz.searchReleases(album: title, artist: name, limit: 5) where (release.score ?? 0) >= 90 {
                if let credit = release.artistCredit?.first(where: { $0.name.matchKey == key || $0.artist.name.matchKey == key }) {
                    artistId = credit.artist.id
                    break
                }
            }
        }
        if artistId == nil {
            artistId = try await musicBrainz.searchArtists(name: name)
                .first { ($0.score ?? 0) >= 100 && $0.name.matchKey == key }?.id
        }
        guard let artistId else { return ArtistInfo(artistId: nil, about: nil, fetchedAt: .now) }
        var about: AlbumAbout?
        if let wikidata = try await musicBrainz.wikidataId(artistId: artistId) {
            about = try? await wikipedia.summary(wikidataId: wikidata, languages: languages)
        }
        return ArtistInfo(artistId: artistId, about: about, fetchedAt: .now)
    }

    /// The release id shared by most of the songs, if any.
    static func commonReleaseId(_ tracks: [Track]) -> String? {
        let ids = tracks.compactMap(\.musicBrainzReleaseId)
        guard ids.count * 2 > tracks.count else { return nil }
        return Dictionary(grouping: ids, by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }

    /// At least 80% of the local songs paired with good scores.
    public static func isConfident(_ match: ReleaseMatch, localCount: Int) -> Bool {
        guard localCount > 0 else { return false }
        let good = match.matches.filter { $0.score >= 0.7 }
        return Double(good.count) >= Double(localCount) * 0.8
    }

    /// Candidate releases for a group of tracks (usually an album), best first.
    ///
    /// Tagged albums are searched by album title and artist. Files without an album are identified one by one by
    /// title and artist (from tags or the file name), and the releases those recordings appear on become candidates.
    public func candidates(for tracks: [Track], album: String? = nil, artist: String? = nil) async throws -> [MBRelease] {
        let albumTitle = album ?? tracks.lazy.compactMap { $0.album?.trimmed }.first { !$0.isEmpty }
        let albumArtist = artist ?? tracks.lazy.compactMap { ($0.albumArtist ?? $0.artist)?.trimmed }.first { !$0.isEmpty }
        if let albumTitle {
            let releases = try await musicBrainz.searchReleases(album: albumTitle, artist: albumArtist)
            if !releases.isEmpty { return ReleaseMatcher.rank(releases, localCount: tracks.count) }
        }
        var releases: [MBRelease] = []
        var hits: [String: Int] = [:]
        let sample = Array(tracks.compactMap(LocalTrackInfo.init).prefix(3))
        for info in sample {
            let artist = info.artist ?? albumArtist
            var recordings = try await musicBrainz.searchRecordings(title: info.title, artist: artist, officialAlbumsOnly: true)
            if recordings.isEmpty {
                recordings = try await musicBrainz.searchRecordings(title: info.title, artist: artist)
            }
            // Recordings that clearly are this song (title, and duration when known).
            let fitting = recordings.filter { recording in
                let titleFits = recording.title.matchKey.similarity(to: info.title.matchKey) >= 0.8
                let durationFits = recording.length.map { abs(Double($0) / 1000 - info.duration) <= 10 } ?? true
                return titleFits && (info.duration <= 0 || durationFits)
            }
            var found = Set<String>()
            for recording in fitting {
                for var release in recording.releases ?? [] {
                    // Carry the recording's score over to its releases for ranking.
                    release.score = recording.score
                    if release.artistCredit == nil { release.artistCredit = recording.artistCredit }
                    releases.append(release)
                    found.insert(release.id)
                }
            }
            for id in found { hits[id, default: 0] += 1 }
        }
        return ReleaseMatcher.rank(releases, localCount: tracks.count, hits: hits, sampled: sample.count)
    }

    /// Fetches the full release and pairs it with the tracks.
    public func match(_ tracks: [Track], releaseId: String) async throws -> ReleaseMatch {
        let release = try await musicBrainz.release(id: releaseId)
        return ReleaseMatcher.match(tracks.compactMap(LocalTrackInfo.init), to: release)
    }

    /// Downloads the first available cover: Cover Art Archive for the release, then the iTunes Search API.
    public func cover(for release: MBRelease?, album: String, artist: String?) async -> (ArtworkCandidate, Data)? {
        var candidates: [ArtworkCandidate] = []
        if let release {
            candidates += artwork.coverArtArchive(releaseId: release.id, releaseGroupId: release.releaseGroup?.id)
        }
        for candidate in candidates {
            if let data = try? await artwork.download(candidate), !data.isEmpty { return (candidate, data) }
        }
        if let candidate = try? await artwork.iTunes(album: album, artist: artist),
           let data = try? await artwork.download(candidate), !data.isEmpty {
            return (candidate, data)
        }
        return nil
    }

    /// Lyrics for a track (synced when available), or nil when LRCLIB has none.
    public func lyrics(for track: Track) async throws -> FetchedLyrics? {
        let info = LocalTrackInfo(track)
        let artist = info?.artist ?? track.albumArtist ?? ""
        guard !artist.isEmpty else { return nil }
        return try await lyrics.lyrics(title: info?.title ?? track.title, artist: artist, album: track.album, duration: track.duration)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
