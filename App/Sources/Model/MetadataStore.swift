import Foundation
import LibraryKit
import MetadataKit
import Observation
import SwiftUI

/// Online metadata for the app: lyrics lookups, the Fix Metadata review sheet and the missing artwork job.
@MainActor
@Observable
final class MetadataStore {
    enum Keys {
        static let fetchLyrics = "metadata.fetchLyrics"
        static let writeTags = "metadata.writeTags"
        static let contact = "metadata.contact"
        static let fetchAlbumInfo = "metadata.fetchAlbumInfo"
    }

    /// Tracks whose online lyrics lookup is running, for a "Searching" state.
    private(set) var lyricsInFlight: Set<Int64> = []
    /// Tracks shown in the review sheet.
    var reviewTracks: ReviewRequest?

    struct ReviewRequest: Identifiable {
        let id = UUID()
        var tracks: [Track]
    }

    @ObservationIgnored private let database: LibraryDatabase
    @ObservationIgnored private let artworkCache: ArtworkCache

    init(database: LibraryDatabase, artwork: ArtworkCache) {
        self.database = database
        self.artworkCache = artwork
        UserDefaults.standard.register(defaults: [Keys.fetchLyrics: true, Keys.writeTags: false, Keys.fetchAlbumInfo: true])
        Task { await indexSavedCredits() }
    }

    /// Fills the credits index from album info saved before the index existed.
    private func indexSavedCredits() async {
        guard (try? await database.writer.read({ try LibraryDatabase.creditIndexCount($0) })) == 0,
              let rows = try? await database.writer.read({ try LibraryDatabase.allAlbumInfo($0) }) else { return }
        for (albumKey, data) in rows {
            guard let info = try? JSONDecoder().decode(AlbumInfo.self, from: data) else { continue }
            try? database.setCredits(info.creditEntries(albumKey: albumKey), albumKey: albumKey)
        }
    }

    /// Built per use so the contact setting applies right away. Clients are stateless apart from the shared rate limiter.
    var service: MetadataService {
        MetadataService(musicBrainz: MusicBrainzClient(identity: identity, limiter: Self.musicBrainzLimiter),
                        artwork: ArtworkClient(identity: identity), lyrics: LRCLibClient(identity: identity, limiter: Self.lrclibLimiter),
                        wikipedia: WikipediaClient(identity: identity))
    }

    /// One limiter for the whole app: MusicBrainz allows one request per second per client.
    private static let musicBrainzLimiter = RateLimiter(interval: .milliseconds(1100))
    /// LRCLIB answers bursts with "busy": one shared pace for every lyrics lookup.
    private static let lrclibLimiter = RateLimiter(interval: .milliseconds(400))

    private var identity: ClientIdentity {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let contact = UserDefaults.standard.string(forKey: Keys.contact)?.trimmingCharacters(in: .whitespaces)
        return ClientIdentity(version: version, contact: contact)
    }

    var writesTags: Bool { UserDefaults.standard.bool(forKey: Keys.writeTags) }

    // MARK: - Lyrics

    /// Looks up lyrics online for a track without any, at most once a week per track. Returns true when lyrics were found.
    @discardableResult
    func ensureLyrics(for track: Track) async -> Bool {
        guard UserDefaults.standard.bool(forKey: Keys.fetchLyrics), let id = track.id, track.displayLyrics == nil,
              !lyricsInFlight.contains(id) else { return false }
        if let checked = track.lyricsCheckedAt, checked > .now.addingTimeInterval(-7 * 24 * 3600) { return false }
        lyricsInFlight.insert(id)
        defer { lyricsInFlight.remove(id) }
        do {
            let lyrics = try await service.lyrics(for: track)
            try database.setFetchedLyrics(lyrics?.bestText, trackId: id)
            return lyrics?.bestText != nil
        } catch {
            // Offline or service error: try again next time.
            return false
        }
    }

    // MARK: - Album credits and background

    /// Albums whose credits are being looked up, for a "Looking up credits" state.
    private(set) var albumInfoInFlight: Set<String> = []

    /// Fetches an album's credits and Wikipedia summary unless they are cached. Albums without a match are retried after
    /// 30 days; errors (offline) are not cached, so the next visit tries again.
    func loadAlbumInfo(albumKey: String, force: Bool = false) async {
        guard UserDefaults.standard.bool(forKey: Keys.fetchAlbumInfo) || force, !albumInfoInFlight.contains(albumKey) else { return }
        if !force, let cached = try? await database.writer.read({ try LibraryDatabase.albumInfo($0, albumKey: albumKey) }) {
            let info = try? JSONDecoder().decode(AlbumInfo.self, from: cached.data)
            let isMiss = info?.isEmpty ?? true
            if !isMiss || cached.fetchedAt > .now.addingTimeInterval(-30 * 24 * 3600) { return }
        }
        let tracks = (try? await database.writer.read { try LibraryDatabase.tracks($0, albumKey: albumKey) }) ?? []
        guard !tracks.isEmpty else { return }
        albumInfoInFlight.insert(albumKey)
        defer { albumInfoInFlight.remove(albumKey) }
        do {
            let info = try await service.albumInfo(for: tracks, languages: Self.wikipediaLanguages)
            try database.setAlbumInfo(try JSONEncoder().encode(info), albumKey: albumKey)
            try database.setCredits(info.creditEntries(albumKey: albumKey), albumKey: albumKey)
        } catch {
            // Offline or service error: try again next time.
        }
    }

    /// Artists whose background is being looked up.
    private(set) var artistInfoInFlight: Set<String> = []

    /// Fetches an artist's Wikipedia summary unless cached (misses retried after 30 days, errors not cached).
    func loadArtistInfo(name: String, force: Bool = false) async {
        guard UserDefaults.standard.bool(forKey: Keys.fetchAlbumInfo) || force, !artistInfoInFlight.contains(name),
              !["various artists", "unknown artist"].contains(name.lowercased()) else { return }
        if !force, let cached = try? await database.writer.read({ try LibraryDatabase.artistInfo($0, name: name) }) {
            let info = try? JSONDecoder().decode(ArtistInfo.self, from: cached.data)
            let isMiss = info?.isEmpty ?? true
            // Info found before photos were fetched gets one more lookup for the photo.
            let needsPhoto = info.map { !$0.isEmpty && $0.imageChecked == nil } ?? false
            if !needsPhoto, !isMiss || cached.fetchedAt > .now.addingTimeInterval(-30 * 24 * 3600) { return }
        }
        // Their albums in the library identify the artist exactly (names are ambiguous).
        let albums = (try? await database.writer.read { try LibraryDatabase.albums($0, sort: .year, artist: name) }) ?? []
        artistInfoInFlight.insert(name)
        defer { artistInfoInFlight.remove(name) }
        do {
            var info = try await service.artistInfo(name: name, albumTitles: albums.map(\.title).filter { $0 != "Unknown Album" },
                                                    languages: Self.wikipediaLanguages)
            // The photo from the Wikipedia article, kept with the other artwork (offline, and in backups).
            if let imageURL = info.about?.imageURL,
               let data = try? await service.artwork.download(ArtworkCandidate(source: .wikimedia, url: imageURL)) {
                info.imageHash = artworkCache.store(data)
            }
            info.imageChecked = true
            try database.setArtistInfo(try JSONEncoder().encode(info), name: name)
        } catch {
            // Offline or service error: try again next time.
        }
    }

    /// The user's languages as Wikipedia codes ("pt-BR" to "pt"), then English.
    static var wikipediaLanguages: [String] {
        var codes = Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
        codes.append("en")
        var seen = Set<String>()
        return codes.filter { seen.insert($0).inserted }
    }

    // MARK: - Fixing metadata

    func review(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        reviewTracks = ReviewRequest(tracks: tracks)
    }

    struct ApplyResult {
        var updated = 0
        var written = 0
        var failedWrites: [String] = []
    }

    /// Applies accepted changes. When writing to files is on, tags (and the cover) go into the files and the database
    /// follows; files that cannot be written keep the fix as a database override. `progress` hears how many songs are
    /// done out of how many, after each one.
    func apply(_ changes: [Int64: TrackMetadata], cover: Data?, coverTrackIds: [Int64], writeToFiles: Bool,
               progress: @MainActor (_ done: Int, _ total: Int) -> Void = { _, _ in }) async -> ApplyResult {
        var result = ApplyResult()
        let tracks = (try? await database.writer.read { db in try Track.fetchAll(db, keys: Array(changes.keys) + coverTrackIds) }) ?? []
        let byId = Dictionary(tracks.compactMap { track in track.id.map { ($0, track) } }, uniquingKeysWith: { first, _ in first })

        var coverHash: String?
        if let cover {
            coverHash = artworkCache.store(cover)
        }

        var overrides: [Int64: TrackMetadata] = [:]
        var inFiles: [Int64: TrackMetadata] = [:]
        let ids = Set(changes.keys).union(coverHash == nil ? [] : coverTrackIds)
        var done = 0
        progress(0, ids.count)
        for id in ids {
            defer {
                done += 1
                progress(done, ids.count)
            }
            #if DEBUG
            // `-GLDebugSlowApply YES`: a second per song, to see the progress.
            if UserDefaults.standard.bool(forKey: "GLDebugSlowApply") { try? await Task.sleep(for: .seconds(1)) }
            #endif
            let metadata = changes[id] ?? TrackMetadata()
            // A cue track shares its audio file with the rest of the album: its fixes stay in the library.
            guard writeToFiles, let track = byId[id], !track.isCueTrack else {
                overrides[id] = metadata
                continue
            }
            let embedCover = coverHash != nil && coverTrackIds.contains(id) ? cover : nil
            let url = track.url
            // Earlier fixes kept only in the database go into the file too, since its overrides are cleared after.
            let toWrite = (track.overrides ?? TrackMetadata()).merging(metadata)
            do {
                let written = try await Task.detached(priority: .userInitiated) {
                    try TagWriter.write(toWrite, frontCover: embedCover, to: url)
                }.value
                try database.updateFileInfo(trackId: id, fileSize: written.fileSize, modifiedAt: written.modifiedAt)
                inFiles[id] = toWrite
                result.written += 1
            } catch {
                result.failedWrites.append(url.lastPathComponent)
                overrides[id] = metadata
            }
        }
        do {
            try database.applyMetadata(overrides.filter { !$0.value.isEmpty }, asOverrides: true)
            try database.applyMetadata(inFiles, asOverrides: false)
            if let coverHash { try database.setFetchedArtwork(coverHash, trackIds: coverTrackIds) }
        } catch {
            result.failedWrites.append(error.localizedDescription)
        }
        result.updated = ids.count
        return result
    }

    // MARK: - Fetching missing info for the whole library

    /// One step of the library job, in the order it runs.
    enum LibraryStep: String, CaseIterable, Sendable {
        case albums = "Album credits and info"
        case artists = "Artist info"
        case artwork = "Missing artwork"
        case lyrics = "Lyrics"
    }

    struct LibraryJobProgress: Equatable {
        var step: LibraryStep
        var done: Int
        var total: Int
        /// Steps still to run after this one.
        var remaining: [LibraryStep]
    }

    /// Progress of the background job, nil when idle.
    private(set) var libraryJob: LibraryJobProgress?
    @ObservationIgnored private var libraryTask: Task<Void, Never>?

    var isFetchingLibraryInfo: Bool { libraryTask != nil }

    /// What a job covers: the whole library, or some songs (those just imported) with their albums and artists.
    enum JobScope: Sendable {
        case library
        case tracks(Set<Int64>)
    }

    /// Jobs waiting for the one running (an import while the library job runs, say).
    @ObservationIgnored private var queuedJobs: [(steps: [LibraryStep], scope: JobScope)] = []

    /// Fetches what is missing in the library, one request at a time: album credits and backgrounds, artist backgrounds,
    /// covers, then lyrics. Every MusicBrainz request (from here or from pages being opened) shares one limiter, so the
    /// job never exceeds the rate limit. Steps whose features are turned off in Settings are skipped. A job asked for
    /// while another runs is queued after it.
    func fetchMissingInfo(steps: [LibraryStep] = LibraryStep.allCases, scope: JobScope = .library) {
        let defaults = UserDefaults.standard
        let enabled = steps.filter { step in
            switch step {
            case .albums, .artists: defaults.bool(forKey: Keys.fetchAlbumInfo)
            case .lyrics: defaults.bool(forKey: Keys.fetchLyrics)
            case .artwork: true
            }
        }
        guard !enabled.isEmpty else { return }
        queuedJobs.append((enabled, scope))
        guard libraryTask == nil else { return }
        libraryTask = Task {
            defer {
                libraryJob = nil
                libraryTask = nil
                queuedJobs = []
            }
            while !queuedJobs.isEmpty, !Task.isCancelled {
                let job = queuedJobs.removeFirst()
                await runJob(steps: job.steps, scope: job.scope)
            }
        }
    }

    private func runJob(steps: [LibraryStep], scope: JobScope) async {
        // For some songs: their albums and their artists (album artists and song artists, as the Artists list names them).
        let limit: (ids: Set<Int64>, albumKeys: Set<String>, artists: Set<String>)? = await {
            guard case .tracks(let ids) = scope else { return nil }
            let tracks = (try? await database.writer.read { db in try Track.fetchAll(db, keys: Array(ids)) }) ?? []
            let artists = Set(tracks.flatMap { [$0.displayAlbumArtist, $0.displayArtist] }.map { $0.lowercased() })
            return (ids, Set(tracks.map(\.albumKey)), artists)
        }()
        for (index, step) in steps.enumerated() where !Task.isCancelled {
            let remaining = Array(steps.dropFirst(index + 1))
            switch step {
            case .albums:
                var keys = (try? await database.writer.read { try LibraryDatabase.albumKeysWithoutInfo($0) }) ?? []
                if let limit { keys = keys.filter(limit.albumKeys.contains) }
                await run(step, items: keys, remaining: remaining) { await self.loadAlbumInfo(albumKey: $0, force: true) }
            case .artists:
                var names = (try? await database.writer.read { db -> [String] in
                    // Never looked up, or looked up before photos were fetched.
                    let withoutPhoto = try LibraryDatabase.allArtistInfo(db).compactMap { row -> String? in
                        guard let info = try? JSONDecoder().decode(ArtistInfo.self, from: row.data), !info.isEmpty, info.imageChecked == nil
                        else { return nil }
                        return try LibraryDatabase.artists(db).first { $0.name.lowercased() == row.artistKey }?.name
                    }
                    return try LibraryDatabase.artistNamesWithoutInfo(db) + withoutPhoto
                }) ?? []
                if let limit { names = names.filter { limit.artists.contains($0.lowercased()) } }
                await run(step, items: names, remaining: remaining) { await self.loadArtistInfo(name: $0, force: true) }
            case .artwork:
                let albums = (try? await database.writer.read { db in
                    try LibraryDatabase.albums(db).filter { $0.artworkHash == nil && $0.title != "Unknown Album" }
                }) ?? []
                await run(step, items: albums.filter { limit?.albumKeys.contains($0.albumKey) ?? true }, remaining: remaining) {
                    await self.fetchCover(for: $0)
                }
            case .lyrics:
                var ids = (try? await database.writer.read { try LibraryDatabase.trackIdsNeedingLyrics($0) }) ?? []
                if let limit { ids = ids.filter(limit.ids.contains) }
                await run(step, items: ids, remaining: remaining) { id in
                    guard let track = try? await self.database.writer.read({ try Track.fetchOne($0, key: id) }) else { return }
                    await self.ensureLyrics(for: track)
                }
            }
        }
    }

    private func run<Item: Sendable>(_ step: LibraryStep, items: [Item], remaining: [LibraryStep],
                                     _ work: @MainActor (Item) async -> Void) async {
        libraryJob = LibraryJobProgress(step: step, done: 0, total: items.count, remaining: remaining)
        for (index, item) in items.enumerated() {
            if Task.isCancelled { return }
            await work(item)
            libraryJob?.done = index + 1
        }
    }

    func stopFetchingMissingInfo() {
        libraryTask?.cancel()
    }

    /// Looks for an album's cover: Cover Art Archive for its MusicBrainz release (from the songs' tags or the credits
    /// lookup), otherwise the iTunes Search API.
    private func fetchCover(for album: AlbumSummary) async {
        let tracks = (try? await database.writer.read { db in try LibraryDatabase.tracks(db, albumKey: album.albumKey) }) ?? []
        var releaseId = tracks.lazy.compactMap(\.musicBrainzReleaseId).first
        if releaseId == nil, let cached = try? await database.writer.read({ try LibraryDatabase.albumInfo($0, albumKey: album.albumKey) }) {
            releaseId = (try? JSONDecoder().decode(AlbumInfo.self, from: cached.data))?.releaseId
        }
        let release = releaseId.map { MBRelease(id: $0, title: album.title) }
        let artist = album.artist == "Various Artists" ? nil : album.artist
        if let (_, data) = await service.cover(for: release, album: album.title, artist: artist), let hash = artworkCache.store(data) {
            try? database.setFetchedArtwork(hash, trackIds: tracks.compactMap(\.id))
        }
    }
}
