import Foundation
import GRDB
import Testing
@testable import LibraryKit
@testable import MetadataKit

// MARK: - Lyrics

struct LyricsParsingTests {
    @Test func parsesSyncedLyrics() {
        let lrc = """
            [ar:Radiohead]
            [ti:Karma Police]
            [00:26.78]Karma police
            [00:31.00]Arrest this man
            [01:02.50][02:10.00]Chorus line
            [00:33:39]He talks in maths
            """
        let lyrics = SyncedLyrics(parsing: lrc)
        #expect(lyrics.isSynced)
        #expect(lyrics.lines.map(\.text) == ["Karma police", "Arrest this man", "He talks in maths", "Chorus line", "Chorus line"])
        #expect(lyrics.lines[0].time == 26.78)
        #expect(lyrics.lines[2].time == 33.39)
        #expect(lyrics.lines[4].time == 130)
        #expect(lyrics.lineIndex(at: 10) == nil)
        #expect(lyrics.lineIndex(at: 31.5) == 1)
        #expect(lyrics.lineIndex(at: 500) == 4)
    }

    @Test func appliesOffset() {
        let lyrics = SyncedLyrics(parsing: "[offset:+500]\n[00:10.00]Line")
        #expect(lyrics.lines.first?.time == 9.5)
    }

    @Test func keepsPlainLyrics() {
        let lyrics = SyncedLyrics(parsing: "\nFirst line\n\nSecond line\n\n")
        #expect(!lyrics.isSynced)
        #expect(lyrics.plainText == "First line\n\nSecond line")
        #expect(lyrics.lineIndex(at: 5) == nil)
    }
}

// MARK: - Matching

struct MatchingTests {
    @Test func guessesFromFileNames() {
        let full = FileNameGuess("03 - Radiohead - Karma Police")
        #expect(full.trackNumber == 3 && full.artist == "Radiohead" && full.title == "Karma Police")
        let numbered = FileNameGuess("07. Lucky")
        #expect(numbered.trackNumber == 7 && numbered.artist == nil && numbered.title == "Lucky")
        let discTrack = FileNameGuess("1-04 Exit Music (For a Film)")
        #expect(discTrack.trackNumber == 4 && discTrack.title == "Exit Music (For a Film)")
        let plain = FileNameGuess("Radiohead - No Surprises")
        #expect(plain.trackNumber == nil && plain.artist == "Radiohead" && plain.title == "No Surprises")
        let numericTitle = FileNameGuess("1979")
        #expect(numericTitle.trackNumber == nil && numericTitle.title == "1979")
    }

    @Test func comparesLoosely() {
        #expect("The Beatles".matchKey == "beatles")
        #expect("Exit Music (For a Film)".matchKey == "exit music for a film")
        #expect("Simon & Garfunkel".matchKey == "simon and garfunkel")
        #expect("Beyoncé".matchKey == "beyonce")
        #expect("paranoid android".similarity(to: "paranoid androd") > 0.9)
        #expect("airbag".similarity(to: "lucky") < 0.3)
    }

    static func release() throws -> MBRelease {
        try JSONDecoder().decode(MBRelease.self, from: Data(Fixtures.releaseJSON.utf8))
    }

    @Test func pairsFilesWithTracks() throws {
        let release = try Self.release()
        // Out of order, one misspelled title, durations off by a second, one file without a number, one stray file.
        let local = [
            LocalTrackInfo(id: 1, title: "Paranoid Androd", artist: nil, trackNumber: 2, discNumber: nil, duration: 384),
            LocalTrackInfo(id: 2, title: "Airbag", artist: nil, trackNumber: 1, discNumber: nil, duration: 285),
            LocalTrackInfo(id: 3, title: "Subterranean Homesick Alien", artist: nil, trackNumber: nil, discNumber: nil, duration: 268),
            LocalTrackInfo(id: 4, title: "Voice Memo", artist: nil, trackNumber: 9, discNumber: nil, duration: 30),
        ]
        let match = ReleaseMatcher.match(local, to: release)
        #expect(match.match(for: 1)?.trackNumber == 2)
        #expect(match.match(for: 2)?.trackNumber == 1)
        #expect(match.match(for: 3)?.trackNumber == 3)
        #expect(match.unmatchedLocalIds == [4])
        #expect(match.score > 0.6 && match.score < 1)

        let proposal = ReleaseMatcher.proposal(for: match)
        let android = try #require(proposal[1])
        #expect(android.title == "Paranoid Android")
        #expect(android.album == "OK Computer" && android.albumArtist == "Radiohead" && android.artist == "Radiohead")
        #expect(android.year == 1997 && android.trackNumber == 2 && android.trackTotal == 3 && android.discNumber == 1 && android.discTotal == 1)
        #expect(android.genre == "Alternative Rock")
        #expect(android.musicBrainzReleaseId == "6a09041b-0f79-3278-88d9-0552dd28d37f")
        #expect(android.musicBrainzRecordingId == "rec-2")
        #expect(android.isCompilation == false)
        #expect(proposal[4] == nil)
    }

    @Test func ranksTheLikelyAlbumFirst() throws {
        func release(_ id: String, score: Int, tracks: Int, status: String = "Official", secondary: [String] = []) -> MBRelease {
            MBRelease(id: id, title: "OK Computer", score: score, status: status, trackCount: tracks,
                      releaseGroup: MBReleaseGroup(id: "g", primaryType: "Album", secondaryTypes: secondary))
        }
        let ranked = ReleaseMatcher.rank([
            release("live", score: 100, tracks: 12, secondary: ["Live"]),
            release("bootleg", score: 100, tracks: 12, status: "Bootleg"),
            release("deluxe", score: 100, tracks: 35),
            release("studio", score: 98, tracks: 12),
            release("studio", score: 98, tracks: 12),
        ], localCount: 12)
        #expect(ranked.map(\.id) == ["studio", "live", "bootleg", "deluxe"])
    }

    @Test func prefersTheClosestAudioEditionForLooseFiles() {
        func release(_ id: String, tracks: Int, format: String) -> MBRelease {
            MBRelease(id: id, title: "OK Computer", score: 100, status: "Official", trackCount: tracks,
                      releaseGroup: MBReleaseGroup(id: "g", primaryType: "Album", secondaryTypes: []),
                      media: [MBMedium(position: 1, format: format, trackCount: tracks)])
        }
        let ranked = ReleaseMatcher.rank([release("box", tracks: 33, format: "DVD-Video"), release("deluxe", tracks: 27, format: "CD"),
                                          release("cd", tracks: 12, format: "CD")], localCount: 4)
        #expect(ranked.map(\.id) == ["cd", "deluxe", "box"])
    }

    @Test func usesTheOriginalYear() {
        let reissue = MBRelease(id: "r", title: "OK Computer", date: "2009-03-24",
                                releaseGroup: MBReleaseGroup(id: "g", firstReleaseDate: "1997-05-21"))
        #expect(reissue.year == 1997)
        #expect(MBRelease(id: "r", title: "X", date: "2009").year == 2009)
    }
}

// MARK: - Clients

/// Serves canned responses by URL path and records the requests.
final class StubFetcher: HTTPFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: (Int, String)]
    private(set) var requests: [URLRequest] = []

    init(_ routes: [String: (Int, String)]) {
        self.routes = routes
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let (status, body) = lock.withLock {
            requests.append(request)
            return routes[url.path] ?? (404, "")
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

struct ClientTests {
    let identity = ClientIdentity(version: "1.0", contact: "me@example.com")

    @Test func retriesWhenMusicBrainzSaysSlowDown() async throws {
        final class Flaky: HTTPFetching, @unchecked Sendable {
            var calls = 0
            func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                calls += 1
                let status = calls == 1 ? 503 : 200
                return (Data(#"{"releases":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
        let flaky = Flaky()
        let client = MusicBrainzClient(fetcher: flaky, identity: identity, limiter: RateLimiter(interval: .zero))
        _ = try await client.searchReleases(album: "X", artist: nil)
        #expect(flaky.calls == 2)
    }

    @Test func searchesMusicBrainz() async throws {
        let stub = StubFetcher(["/ws/2/release": (200, #"{"releases":[\#(Fixtures.releaseJSON)]}"#)])
        let client = MusicBrainzClient(fetcher: stub, identity: identity, limiter: RateLimiter(interval: .zero))
        let releases = try await client.searchReleases(album: "OK Computer (Remastered)", artist: "Radiohead")
        #expect(releases.first?.title == "OK Computer")

        let request = try #require(stub.requests.first)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Groovelight/1.0 ( me@example.com )")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.first { $0.name == "query" }?.value == #"release:(OK Computer \(Remastered\)) AND artist:(Radiohead)"#)
        #expect(query.first { $0.name == "fmt" }?.value == "json")
    }

    @Test func rateLimitsRequests() async throws {
        let limiter = RateLimiter(interval: .milliseconds(150))
        let start = ContinuousClock.now
        for _ in 0..<3 { try await limiter.wait() }
        #expect(ContinuousClock.now - start >= .milliseconds(290))
    }

    @Test func fallsBackToLyricsSearch() async throws {
        let search = """
            [{"trackName":"Karma Police","artistName":"Someone Else","duration":264,"syncedLyrics":"[00:01.00]Wrong"},
             {"trackName":"Karma Police","artistName":"Radiohead","duration":263,"plainLyrics":"Plain only"},
             {"trackName":"Karma Police (Live)","artistName":"Radiohead","duration":264,"syncedLyrics":"[00:26.78]Karma police"}]
            """
        let stub = StubFetcher(["/api/search": (200, search)])
        let client = LRCLibClient(fetcher: stub, identity: identity)
        let lyrics = try await client.lyrics(title: "Karma Police", artist: "Radiohead", album: "OK Computer", duration: 264)
        #expect(lyrics?.synced == "[00:26.78]Karma police")
        #expect(stub.requests.map(\.url!.path) == ["/api/get", "/api/search"])
    }

    @Test func retriesWhenLRCLibIsBusy() async throws {
        final class Busy: HTTPFetching, @unchecked Sendable {
            var calls = 0
            func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                calls += 1
                let status = calls == 1 ? 503 : 200
                return (Data(#"{"plainLyrics":"Hi"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
        let busy = Busy()
        let client = LRCLibClient(fetcher: busy, identity: identity, limiter: RateLimiter(interval: .zero))
        let lyrics = try await client.lyrics(title: "A", artist: "B", album: nil, duration: 100)
        #expect(lyrics?.plain == "Hi" && busy.calls == 2)
    }

    @Test func returnsExactLyrics() async throws {
        let stub = StubFetcher(["/api/get": (200, #"{"instrumental":false,"plainLyrics":"Hi","syncedLyrics":""}"#)])
        let client = LRCLibClient(fetcher: stub, identity: identity)
        let lyrics = try await client.lyrics(title: "A", artist: "B", album: nil, duration: 100)
        #expect(lyrics == FetchedLyrics(synced: nil, plain: "Hi", isInstrumental: false))
        let query = URLComponents(url: stub.requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.first { $0.name == "duration" }?.value == "100")
    }

    @Test func picksITunesArtwork() async throws {
        let body = """
            {"results":[{"collectionName":"OK Computer OKNOTOK 1997 2017","artistName":"Radiohead","artworkUrl100":"https://x/a/100x100bb.jpg"},
                        {"collectionName":"OK Computer","artistName":"Radiohead","artworkUrl100":"https://x/b/100x100bb.jpg"}]}
            """
        let client = ArtworkClient(fetcher: StubFetcher(["/search": (200, body)]), identity: identity)
        let candidate = try await client.iTunes(album: "OK Computer", artist: "Radiohead")
        // Prefix matches count too, so the first result wins here; both are the same album.
        #expect(candidate?.url.absoluteString == "https://x/a/3000x3000bb.jpg")
        #expect(candidate?.source == .iTunes)
    }

    @Test func encodesPlusSigns() {
        let url = URL.build("https://example.com/s", ["q": "AC+DC"])
        #expect(url.absoluteString == "https://example.com/s?q=AC%2BDC")
    }
}

// MARK: - Library

struct MetadataLibraryTests {
    @Test func overridesSurviveRescans() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try ScannerIntegrationTests.makeFixtures(in: directory)
        let flac = try #require(files.first { $0.pathExtension == "flac" })

        let database = try LibraryDatabase.inMemory()
        let artwork = try ArtworkCache(directory: directory.appendingPathComponent("Artwork"))
        let root = try database.addRoot(path: directory.path, bookmark: Data())
        let scanner = LibraryScanner(database: database, artwork: artwork)
        _ = try await scanner.scan(root: root)
        let track = try #require(try await database.writer.read { db in try Track.filter(Column("path") == flac.path).fetchOne(db) })
        let id = try #require(track.id)

        try database.applyMetadata([id: TrackMetadata(title: "Fixed Title", album: "Fixed Album", year: 1997)], asOverrides: true)
        try database.setFetchedLyrics("[00:01.00]Hello", trackId: id)
        let coverHash = try #require(artwork.store(ScannerIntegrationTests.pngData()))
        try database.setFetchedArtwork(coverHash, trackIds: [id])

        // Touch the file so the scanner rereads its (unchanged) tags.
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(60)], ofItemAtPath: flac.path)
        let summary = try await scanner.scan(root: root)
        #expect(summary.updated == 1)

        let rescanned = try #require(try await database.writer.read { db in try Track.fetchOne(db, key: id) })
        #expect(rescanned.title == "Fixed Title" && rescanned.album == "Fixed Album" && rescanned.year == 1997)
        #expect(rescanned.albumKey == Track.makeAlbumKey(album: "Fixed Album", albumArtist: nil, artist: nil, isCompilation: false))
        #expect(rescanned.displayLyrics == "[00:01.00]Hello")
        #expect(rescanned.artworkHash == coverHash)

        // Writing to the file instead clears the overrides.
        try database.applyMetadata([id: TrackMetadata(title: "In File")], asOverrides: false)
        let cleared = try #require(try await database.writer.read { db in try Track.fetchOne(db, key: id) })
        #expect(cleared.overrides == nil && cleared.title == "In File")
    }

    @Test func manualEditsSetAndClearFields() throws {
        var track = LibraryDatabaseTests.makeTrack(rootId: 1, "Song", artist: "Artist", album: "Album", number: 3)
        track.comment = "old"
        track.apply(TrackMetadata(artist: "New Artist", year: 0, trackNumber: 0, composer: "Writer", comment: "", bpm: 120,
                                  lyrics: "[00:01.00]Hello"))
        #expect(track.artist == "New Artist" && track.composer == "Writer" && track.bpm == 120)
        #expect(track.year == nil && track.trackNumber == nil && track.comment == nil)
        #expect(track.lyrics == "[00:01.00]Hello")
        #expect(track.albumKey == Track.makeAlbumKey(album: "Album", albumArtist: nil, artist: "New Artist", isCompilation: false))
        // A cleared title falls back to the file name.
        track.apply(TrackMetadata(title: "  "))
        #expect(track.title == "3 Song")
    }

    @Test func writesAndClearsExtraTagsInFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        for url in try ScannerIntegrationTests.makeFixtures(in: directory) {
            let name = url.lastPathComponent
            try TagWriter.write(TrackMetadata(year: 1999, composer: "Writer", comment: "Remaster", bpm: 98, lyrics: "Plain words"), to: url)
            var tags = try TagReader.read(url)
            #expect(tags.composer == "Writer" && tags.comment == "Remaster" && tags.lyrics == "Plain words" && tags.year == 1999, "\(name)")
            #expect(tags.bpm == 98 || url.pathExtension == "wav", "\(name) bpm \(String(describing: tags.bpm))")
            try TagWriter.write(TrackMetadata(year: 0, comment: ""), to: url)
            tags = try TagReader.read(url)
            #expect(tags.year == nil && tags.comment == nil && tags.composer == "Writer", "\(name) after clearing: year \(String(describing: tags.year)) comment \(String(describing: tags.comment)) composer \(String(describing: tags.composer))")
        }
    }

    @Test func overlappingScansDoNotCollide() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try ScannerIntegrationTests.makeFixtures(in: directory)
        let database = try LibraryDatabase.inMemory()
        let root = try database.addRoot(path: directory.path, bookmark: Data())
        let scanner = LibraryScanner(database: database, artwork: try ArtworkCache(directory: directory.appendingPathComponent("Artwork")))
        async let first = scanner.scan(root: root)
        async let second = scanner.scan(root: root)
        let (a, b) = try await (first, second)
        #expect(a.added + b.added == files.count)
        #expect(try await database.writer.read { try Track.fetchCount($0) } == files.count)
    }

    @Test func writesTagsToFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = TrackMetadata(title: "Karma Police", artist: "Radiohead", album: "OK Computer", albumArtist: "Radiohead",
                                     genre: "Alternative Rock", year: 1997, trackNumber: 6, trackTotal: 12, discNumber: 1, discTotal: 1,
                                     musicBrainzRecordingId: "rec-6", musicBrainzReleaseId: "rel-1")
        for url in try ScannerIntegrationTests.makeFixtures(in: directory) {
            let result = try TagWriter.write(metadata, lyrics: "[00:01.00]Karma police", frontCover: ScannerIntegrationTests.pngData(), to: url)
            #expect(result.fileSize > 0)
            let tags = try TagReader.read(url)
            let name = url.lastPathComponent
            #expect(tags.title == "Karma Police" && tags.artist == "Radiohead" && tags.album == "OK Computer", "\(name)")
            #expect(tags.year == 1997, "\(name) year \(String(describing: tags.year))")
            #expect(tags.trackNumber == 6 && tags.trackTotal == 12, "\(name)")
            #expect(tags.genre == "Alternative Rock", "\(name)")
            #expect(tags.lyrics == "[00:01.00]Karma police", "\(name) lyrics \(String(describing: tags.lyrics))")
            #expect(tags.artwork != nil, "\(name) artwork")
        }
    }
}

enum Fixtures {
    /// Trimmed MusicBrainz release lookup (inc=recordings+artist-credits+release-groups+genres), three tracks.
    static let releaseJSON = """
        {"id":"6a09041b-0f79-3278-88d9-0552dd28d37f","title":"OK Computer","status":"Official","date":"1997-07-01","country":"US",
         "artist-credit":[{"name":"Radiohead","joinphrase":"","artist":{"id":"a74b1b7f-71a5-4011-9441-d0b5e4122711","name":"Radiohead"}}],
         "release-group":{"id":"b1392450-e666-3926-a536-22c65f834433","title":"OK Computer","primary-type":"Album","secondary-types":[],
                          "first-release-date":"1997-05-21",
                          "genres":[{"name":"alternative rock","count":27},{"name":"art rock","count":15}]},
         "genres":[],
         "media":[{"position":1,"format":"CD","track-count":3,"tracks":[
            {"id":"t1","number":"1","position":1,"title":"Airbag","length":284400,"recording":{"id":"rec-1","title":"Airbag"}},
            {"id":"t2","number":"2","position":2,"title":"Paranoid Android","length":383493,"recording":{"id":"rec-2","title":"Paranoid Android"}},
            {"id":"t3","number":"3","position":3,"title":"Subterranean Homesick Alien","length":267000,"recording":{"id":"rec-3","title":"Subterranean Homesick Alien"}}
         ]}]}
        """
}

/// Hits the real services. Opt in with `GL_LIVE_TESTS=1 swift test --filter LiveMetadataTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GL_LIVE_TESTS"] == "1"), .serialized)
struct LiveMetadataTests {
    let service = MetadataService(identity: ClientIdentity(version: "0.1.0-test"))

    static func track(_ id: Int64, _ fileName: String, duration: Double) -> Track {
        Track(id: id, rootId: 1, path: "/Music/Unknown/\(fileName).mp3", fileSize: 1, modifiedAt: .now, title: fileName,
              isCompilation: false, duration: duration, albumKey: "", rating: 0, isLoved: false, playCount: 0, skipCount: 0, dateAdded: .now)
    }

    @Test func identifiesUntaggedFiles() async throws {
        // No tags at all: only file names and durations.
        let tracks = [
            Self.track(1, "01 - Radiohead - Airbag", duration: 284),
            Self.track(2, "02 - Radiohead - Paranoid Android", duration: 383),
            Self.track(3, "06 - Radiohead - Karma Police", duration: 264),
        ]
        let candidates = try await service.candidates(for: tracks)
        let best = try #require(candidates.first)
        let match = try await service.match(tracks, releaseId: best.id)
        print("live: \(candidates.count) candidates, best '\(match.release.title)' by \(match.release.artistName) (\(match.release.totalTracks) tracks), score \(match.score)")
        #expect(match.release.title.lowercased().contains("ok computer"))
        #expect(match.match(for: 3)?.trackNumber == 6)

        let cover = await service.cover(for: match.release, album: match.release.title, artist: match.release.artistName)
        print("live: cover from \(cover?.0.source.rawValue ?? "none"), \(cover?.1.count ?? 0) bytes")
        #expect((cover?.1.count ?? 0) > 10_000)
    }

    @Test func fetchesSyncedLyrics() async throws {
        var track = Self.track(1, "Karma Police", duration: 264)
        track.artist = "Radiohead"
        track.album = "OK Computer"
        let lyrics = try await service.lyrics(for: track)
        print("live: synced=\(lyrics?.synced != nil) plain=\(lyrics?.plain != nil)")
        let parsed = SyncedLyrics(parsing: lyrics?.bestText ?? "")
        #expect(parsed.isSynced)
    }
}

// MARK: - Credits

struct CreditsTests {
    static func release() throws -> MBRelease {
        let url = try #require(Bundle.module.url(forResource: "ok-computer-credits", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(MBRelease.self, from: Data(contentsOf: url))
    }

    @Test func buildsAlbumAndTrackCredits() throws {
        let release = try Self.release()
        let local = [LocalTrackInfo(id: 7, title: "Karma Police", artist: nil, trackNumber: 6, discNumber: nil, duration: 264)]
        let match = ReleaseMatcher.match(local, to: release)
        let info = CreditsBuilder.albumInfo(release: release, match: match, about: nil)

        let kinds = info.sections.map(\.kind)
        #expect(kinds.contains(.musicians) && kinds.contains(.songwriting) && kinds.contains(.production))
        let musicians = try #require(info.sections.first { $0.kind == .musicians })
        let colin = try #require(musicians.credits.first { $0.name == "Colin Greenwood" })
        #expect(colin.roles.contains("bass guitar"), "\(colin.roles)")
        let production = try #require(info.sections.first { $0.kind == .production })
        let nigel = try #require(production.credits.first { $0.name == "Nigel Godrich" })
        #expect(nigel.roles.contains("producer"), "\(nigel.roles)")
        // Assistant engineers are labeled as such, and songwriters come from the works.
        #expect(production.credits.contains { $0.roles.contains("assistant engineer") })
        let writers = try #require(info.sections.first { $0.kind == .songwriting })
        #expect(writers.credits.contains { $0.name == "Thom Yorke" })

        // Per-song credits are mapped to the local song.
        var track = LibraryDatabaseTests.makeTrack(rootId: 1, "Karma Police", artist: "Radiohead", album: "OK Computer", number: 6)
        track.id = 7
        let songCredits = info.sections(forTrack: track)
        #expect(songCredits.contains { $0.kind == .musicians })
        #expect(songCredits.first { $0.kind == .production }?.credits.contains { $0.name == "Nick Ingman" } == false)
        #expect(songCredits.first { $0.kind == .musicians }?.credits.contains { $0.name == "Nick Ingman" && $0.roles == ["conductor"] } == true)
    }

    @Test func roundTripsThroughTheLibrary() throws {
        let database = try LibraryDatabase.inMemory()
        let info = CreditsBuilder.albumInfo(release: try Self.release(), match: nil,
                                            about: AlbumAbout(title: "OK Computer", summary: "Third album.",
                                                              url: URL(string: "https://en.wikipedia.org/wiki/OK_Computer")!, language: "en"))
        try database.setAlbumInfo(try JSONEncoder().encode(info), albumKey: "radiohead\u{1F}ok computer")
        let stored = try #require(try database.writer.read { try LibraryDatabase.albumInfo($0, albumKey: "radiohead\u{1F}ok computer") })
        let decoded = try JSONDecoder().decode(AlbumInfo.self, from: stored.data)
        #expect(decoded.sections == info.sections && decoded.about?.summary == "Third album.")
    }

    @Test func indexesPeopleAcrossTheLibrary() throws {
        let database = try LibraryDatabase.inMemory()
        let root = try database.addRoot(path: "/music", bookmark: Data())
        var ids: [Int64] = []
        try database.writer.write { db in
            for (number, title) in [(1, "Airbag"), (6, "Karma Police")] {
                var track = LibraryDatabaseTests.makeTrack(rootId: root.id!, title, artist: "Radiohead", album: "OK Computer", number: number)
                try track.insert(db)
                ids.append(track.id!)
            }
        }
        let release = try Self.release()
        let local = [LocalTrackInfo(id: ids[0], title: "Airbag", artist: nil, trackNumber: 1, discNumber: nil, duration: 284),
                     LocalTrackInfo(id: ids[1], title: "Karma Police", artist: nil, trackNumber: 6, discNumber: nil, duration: 264)]
        let info = CreditsBuilder.albumInfo(release: release, match: ReleaseMatcher.match(local, to: release), about: nil)
        let key = Track.makeAlbumKey(album: "OK Computer", albumArtist: nil, artist: "Radiohead", isCompilation: false)
        try database.setCredits(info.creditEntries(albumKey: key), albumKey: key)

        // Nigel Godrich: credited on both songs; the album appears once with his roles.
        let nigelId = try #require(info.sections.flatMap(\.credits).first { $0.name == "Nigel Godrich" }?.artistId)
        let nigel = try database.writer.read { try LibraryDatabase.credits($0, person: CreditPerson(name: "Nigel Godrich", artistId: nigelId)) }
        #expect(nigel.albums.map(\.album.title) == ["OK Computer"])
        #expect(nigel.tracks.map(\.track.title) == ["Airbag", "Karma Police"])
        #expect(nigel.roles.contains("producer"))

        // Stanley Donwood is only credited for the release (design): every song of the album.
        let stanley = try database.writer.read { try LibraryDatabase.credits($0, person: CreditPerson(name: "Stanley Donwood", artistId:
            info.sections.flatMap(\.credits).first { $0.name == "Stanley Donwood" }?.artistId)) }
        #expect(stanley.tracks.count == 2 && stanley.roles == ["design and illustration"])

        // Someone credited on the album but only on songs that are not in the library: the album, no songs.
        let localPeople = Set(info.localRecordings.values.flatMap { info.trackSections[$0] ?? [] }.flatMap(\.credits).map(\.name))
        let releasePeople = Set((info.releaseSections ?? []).flatMap(\.credits).map(\.name))
        if let elsewhere = info.sections.flatMap(\.credits).first(where: { !localPeople.contains($0.name) && !releasePeople.contains($0.name) }) {
            let credits = try database.writer.read { try LibraryDatabase.credits($0, person: CreditPerson(name: elsewhere.name, artistId: elsewhere.artistId)) }
            #expect(credits.albums.count == 1 && credits.tracks.isEmpty, "\(elsewhere.name)")
        }

        // Re-indexing replaces the album's rows.
        try database.setCredits(info.creditEntries(albumKey: key), albumKey: key)
        #expect(try database.writer.read { try LibraryDatabase.credits($0, person: CreditPerson(name: "Nigel Godrich", artistId: nigelId)) }.tracks.count == 2)
    }

    @Test func readsWikipediaThroughWikidata() async throws {
        let stub = StubFetcher([
            "/w/api.php": (200, #"{"entities":{"Q202996":{"sitelinks":{"enwiki":{"title":"OK Computer"}}}}}"#),
            "/api/rest_v1/page/summary/OK_Computer": (200, #"""
                {"type":"standard","title":"OK Computer","extract":"OK Computer is the third studio album by Radiohead.",
                 "content_urls":{"desktop":{"page":"https://en.wikipedia.org/wiki/OK_Computer"}}}
                """#),
        ])
        let client = WikipediaClient(fetcher: stub, identity: ClientIdentity(version: "1"))
        let about = try await client.summary(wikidataId: "Q202996", languages: ["pt", "en"])
        #expect(about?.summary.hasPrefix("OK Computer is the third") == true && about?.language == "en")
        #expect(about?.url.absoluteString == "https://en.wikipedia.org/wiki/OK_Computer")
    }
}

extension LiveMetadataTests {
    @Test func fetchesAlbumCreditsAndAbout() async throws {
        let tracks = [
            Self.track(1, "01 - Radiohead - Airbag", duration: 284),
            Self.track(2, "02 - Radiohead - Paranoid Android", duration: 383),
            Self.track(6, "06 - Radiohead - Karma Police", duration: 264),
        ]
        let info = try await service.albumInfo(for: tracks, languages: ["en"])
        print("live: release \(info.releaseTitle ?? "-"), sections \(info.sections.map { "\($0.kind.rawValue) (\($0.credits.count))" })")
        print("live: about \(info.about?.summary.prefix(80) ?? "-")")
        #expect(!info.sections.isEmpty)
    }
}

struct ArtistInfoTests {
    @Test func findsTheArtistThroughAnAlbum() async throws {
        // The release search names the exact artist; the name search would also return a namesake.
        let releases = """
            {"releases":[{"id":"r1","title":"Nevermind","score":100,"artist-credit":[{"name":"Nirvana","artist":{"id":"nirvana-us","name":"Nirvana"}}]}]}
            """
        let stub = StubFetcher([
            "/ws/2/release": (200, releases),
            "/ws/2/artist/nirvana-us": (200, #"{"id":"nirvana-us","name":"Nirvana","relations":[{"type":"wikidata","url":{"resource":"https://www.wikidata.org/wiki/Q11649"}}]}"#),
            "/w/api.php": (200, #"{"entities":{"Q11649":{"sitelinks":{"enwiki":{"title":"Nirvana (band)"}}}}}"#),
            "/api/rest_v1/page/summary/Nirvana_(band)": (200, #"{"type":"standard","title":"Nirvana (band)","extract":"Nirvana was an American rock band.","content_urls":{"desktop":{"page":"https://en.wikipedia.org/wiki/Nirvana_(band)"}}}"#),
        ])
        let identity = ClientIdentity(version: "1")
        let service = MetadataService(musicBrainz: MusicBrainzClient(fetcher: stub, identity: identity, limiter: RateLimiter(interval: .zero)),
                                      artwork: ArtworkClient(fetcher: stub, identity: identity), lyrics: LRCLibClient(fetcher: stub, identity: identity),
                                      wikipedia: WikipediaClient(fetcher: stub, identity: identity))
        let info = try await service.artistInfo(name: "Nirvana", albumTitles: ["Nevermind"], languages: ["en"])
        #expect(info.artistId == "nirvana-us")
        #expect(info.about?.summary == "Nirvana was an American rock band.")
        #expect(!stub.requests.contains { $0.url!.path == "/ws/2/artist" }, "no name search needed")
    }

    @Test func tidiesWikipediaSummaries() {
        #expect(WikipediaClient.tidy("The members are Thom Yorke ; brothers Jonny and Colin Greenwood (bass); Ed O'Brien ; and Philip Selway.")
                == "The members are Thom Yorke; brothers Jonny and Colin Greenwood (bass); Ed O'Brien; and Philip Selway.")
        #expect(WikipediaClient.tidy("Björk ( ) is a singer .") == "Björk is a singer.")
    }

    @Test func picksArtistPhotoSizes() {
        let thumb = "https://upload.wikimedia.org/wikipedia/commons/thumb/a/ab/Radiohead.jpg/330px-Radiohead.jpg"
        // A big original: a Commons thumbnail at a standard width (960 px).
        #expect(WikipediaClient.imageURL(thumbnail: thumb, original: "https://upload.wikimedia.org/x/Radiohead.jpg", originalWidth: 5940)?.absoluteString
                == "https://upload.wikimedia.org/wikipedia/commons/thumb/a/ab/Radiohead.jpg/960px-Radiohead.jpg")
        // A small original is used as is (Commons does not upscale).
        #expect(WikipediaClient.imageURL(thumbnail: thumb, original: "https://upload.wikimedia.org/x/Small.jpg", originalWidth: 367)?.absoluteString
                == "https://upload.wikimedia.org/x/Small.jpg")
        #expect(WikipediaClient.imageURL(thumbnail: nil, original: nil, originalWidth: nil) == nil)
    }

    @Test func storesArtistInfoByName() throws {
        let database = try LibraryDatabase.inMemory()
        try database.setArtistInfo(Data("{}".utf8), name: "Radiohead")
        #expect(try database.writer.read { try LibraryDatabase.artistInfo($0, name: "RADIOHEAD") } != nil)
    }
}

extension LiveMetadataTests {
    @Test func fetchesArtistAbout() async throws {
        let info = try await service.artistInfo(name: "Nirvana", albumTitles: ["Nevermind"], languages: ["en"])
        print("live: artist \(info.artistId ?? "-"): \(info.about?.summary.prefix(80) ?? "-")")
        #expect(info.about?.summary.lowercased().contains("grunge") == true || info.about?.summary.lowercased().contains("american rock band") == true)
    }
}

// MARK: - Backup and restore

struct BackupTests {
    @Test func backsUpAndRestoresEverythingOutsideTheFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try ScannerIntegrationTests.makeFixtures(in: directory.appendingPathComponent("Music"))
        let artworkDir = directory.appendingPathComponent("Artwork")
        let database = try LibraryDatabase(url: directory.appendingPathComponent("Library.sqlite"))
        let artwork = try ArtworkCache(directory: artworkDir)
        let root = try database.addRoot(path: directory.appendingPathComponent("Music").path, bookmark: Data([1, 2, 3]))
        _ = try await LibraryScanner(database: database, artwork: artwork).scan(root: root)

        // Library-only data: history, loves, a fix, fetched lyrics, a playlist with a custom cover, album info.
        let tracks = try await database.writer.read { try LibraryDatabase.allTracks($0) }
        let first = try #require(tracks.first?.id)
        try database.recordPlay(trackId: first)
        try database.setLoved(true, trackId: first)
        try database.applyMetadata([first: TrackMetadata(title: "Fixed")], asOverrides: true)
        try database.setFetchedLyrics("[00:01.00]Hi", trackId: first)
        let coverHash = try #require(artwork.store(ScannerIntegrationTests.pngData()))
        _ = try database.createPlaylist(named: "Mix", trackIds: tracks.compactMap(\.id), cover: PlaylistCover(kind: .image(hash: coverHash), showsTitle: true))
        try database.setAlbumInfo(Data("{}".utf8), albumKey: tracks[0].albumKey)

        let backup = directory.appendingPathComponent("Test.\(LibraryBackup.fileExtension)")
        let preferences = try PropertyListSerialization.data(fromPropertyList: ["eq.enabled": true], format: .xml, options: 0)
        let manifest = try LibraryBackup.write(database: database, artworkDirectory: artworkDir, preferences: preferences,
                                               appVersion: "1.0", to: backup)
        #expect(manifest.trackCount == files.count && manifest.playlistCount == 1 && manifest.lovedCount == 1 && manifest.playCount == 1)
        let read = try LibraryBackup.manifest(of: backup)
        #expect(read.trackCount == manifest.trackCount && read.folders == manifest.folders && abs(read.createdAt.timeIntervalSince(manifest.createdAt)) < 1)

        // A different, empty library on a "new Mac" with the music in another folder.
        let newMac = directory.appendingPathComponent("NewMac")
        try FileManager.default.createDirectory(at: newMac, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: directory.appendingPathComponent("Music"), to: newMac.appendingPathComponent("Música"))
        let restoredDB = try LibraryDatabase(url: newMac.appendingPathComponent("Library.sqlite"))
        let restoredArtwork = newMac.appendingPathComponent("Artwork")
        let restoredPreferences = try #require(try LibraryBackup.restore(from: backup, into: restoredDB, artworkDirectory: restoredArtwork))
        let decoded = try PropertyListSerialization.propertyList(from: restoredPreferences, format: nil) as? [String: Any]
        #expect(decoded?["eq.enabled"] as? Bool == true)
        #expect(FileManager.default.fileExists(atPath: restoredArtwork.appendingPathComponent("\(coverHash).img").path))

        // Locate the folder: paths move, history stays, and a rescan keeps everything.
        let restoredRoot = try #require(try await restoredDB.writer.read { try LibraryDatabase.roots($0) }.first)
        let moved = try restoredDB.relocateRoot(restoredRoot.id!, to: newMac.appendingPathComponent("Música").path, bookmark: Data())
        #expect(moved == files.count)
        let relocatedRoot = try #require(try await restoredDB.writer.read { try LibraryDatabase.roots($0) }.first)
        let summary = try await LibraryScanner(database: restoredDB, artwork: try ArtworkCache(directory: restoredArtwork)).scan(root: relocatedRoot)
        #expect(summary.removed == 0 && summary.added == 0)
        let after = try #require(try await restoredDB.writer.read { try Track.fetchOne($0, key: first) })
        #expect(after.title == "Fixed" && after.playCount == 1 && after.isLoved && after.displayLyrics == "[00:01.00]Hi")
        #expect(after.path.contains("/NewMac/Música/"))
        #expect(try await restoredDB.writer.read { try LibraryDatabase.playlists($0) }.first?.coverStyle?.showsTitle == true)
        #expect(try await restoredDB.writer.read { try LibraryDatabase.albumInfo($0, albumKey: tracks[0].albumKey) } != nil)
    }

    @Test func movedFilesKeepTheirHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try ScannerIntegrationTests.makeFixtures(in: directory.appendingPathComponent("Music"))
        let database = try LibraryDatabase.inMemory()
        let root = try database.addRoot(path: directory.appendingPathComponent("Music").path, bookmark: Data())
        let scanner = LibraryScanner(database: database, artwork: try ArtworkCache(directory: directory.appendingPathComponent("Artwork")))
        _ = try await scanner.scan(root: root)
        let track = try #require(try await database.writer.read { try LibraryDatabase.allTracks($0) }.first)
        try database.recordPlay(trackId: track.id!)
        try database.setLoved(true, trackId: track.id!)
        _ = try database.createPlaylist(named: "Mix", trackIds: [track.id!])

        // Rename the album folder: every file has a new path.
        let album = files[0].deletingLastPathComponent()
        try FileManager.default.moveItem(at: album, to: album.deletingLastPathComponent().appendingPathComponent("Renamed Album"))
        let summary = try await scanner.scan(root: root)
        #expect(summary.removed == 0 && summary.added == 0 && summary.updated == files.count)
        let after = try #require(try await database.writer.read { try Track.fetchOne($0, key: track.id!) })
        #expect(after.path.contains("/Renamed Album/") && after.playCount == 1 && after.isLoved)
        #expect(try await database.writer.read { try LibraryDatabase.tracks($0, playlistId: 1) }.map(\.id) == [track.id])
    }

    @Test func missingFoldersAreNotTreatedAsDeleted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try ScannerIntegrationTests.makeFixtures(in: directory.appendingPathComponent("Drive"))
        let database = try LibraryDatabase.inMemory()
        let artwork = try ArtworkCache(directory: directory.appendingPathComponent("Artwork"))
        let root = try database.addRoot(path: directory.appendingPathComponent("Drive").path, bookmark: Data())
        let scanner = LibraryScanner(database: database, artwork: artwork)
        _ = try await scanner.scan(root: root)
        // "Unplug the drive".
        try FileManager.default.moveItem(at: directory.appendingPathComponent("Drive"), to: directory.appendingPathComponent("Elsewhere"))
        await #expect(throws: LibraryScanner.ScanError.folderUnavailable(root.path)) { _ = try await scanner.scan(root: root) }
        #expect(try await database.writer.read { try Track.fetchCount($0) } == files.count)
    }

    @Test func rejectsFoldersThatAreNotBackups() throws {
        #expect(throws: LibraryBackup.BackupError.self) { try LibraryBackup.manifest(of: FileManager.default.temporaryDirectory) }
    }
}
