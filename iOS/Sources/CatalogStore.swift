import Foundation
import LibraryKit
import Observation
import OSLog
import UIKit
import WirelessSync
import WirelessSyncClient

/// The Mac's whole library, shown in the Library with this device's music when Downloaded is off (as on Android):
/// every album, artist and song there (`DeviceCatalog`), kept on the device between launches and fetched again only when
/// it changed; what this device's selection holds; and the requests that change it, kept here until the Mac is
/// reachable (the Mac then has this device sync).
@MainActor
@Observable
final class CatalogStore {
    private(set) var catalog: DeviceCatalog?
    private(set) var isLoading = false
    private(set) var error: String?
    /// Whether the Mac answered the last time (nil: not asked yet).
    private(set) var reachable: Bool?
    /// Requests made here that the Mac has not taken yet.
    private(set) var pending: [TransferRequest]
    /// Only this device's music in the Library (on), or the Mac's too (off, the default, and again on pairing). Kept between launches.
    var downloadedOnly: Bool {
        didSet {
            UserDefaults.standard.set(downloadedOnly, forKey: "library.downloadedOnly")
            if !downloadedOnly { Task { await refresh() } }
        }
    }

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let sync: SyncStore
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let pendingFile: URL
    @ObservationIgnored private let covers: ArtworkCache?
    @ObservationIgnored private var fetching: [String: Task<URL?, Never>] = [:]
    /// The connection covers are fetched with, and the one being opened.
    @ObservationIgnored private var connection: MacClient?
    @ObservationIgnored private var connecting: Task<MacClient?, Never>?
    @ObservationIgnored private var unreachableUntil = Date.distantPast
    /// Covers the Mac does not have.
    @ObservationIgnored private var missing: Set<String> = []

    init(library: LibraryStore, sync: SyncStore, folders: AppFolders) {
        // Set first, so this does not count as a change (which would keep it).
        // `-GLDebugShowMac YES` turns Downloaded off for this launch, for layout checks.
        downloadedOnly = UserDefaults.standard.bool(forKey: "GLDebugShowMac") ? false
            // `bool(forKey:)` also reads a launch argument's "YES" or "1".
            : UserDefaults.standard.object(forKey: "library.downloadedOnly") != nil && UserDefaults.standard.bool(forKey: "library.downloadedOnly")
        self.library = library
        self.sync = sync
        file = folders.root.appendingPathComponent("Catalog.json")
        pendingFile = folders.root.appendingPathComponent("Requests.json")
        covers = try? ArtworkCache(directory: folders.root.appendingPathComponent("CatalogArtwork", isDirectory: true))
        catalog = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(DeviceCatalog.self, from: $0) }
        pending = (try? Data(contentsOf: pendingFile)).flatMap { try? JSONDecoder().decode([TransferRequest].self, from: $0) } ?? []
    }

    /// Whether the Library shows the Mac's music with this device's.
    var showsMac: Bool { sync.isPaired && !downloadedOnly }

    /// Sends the requests waiting for the Mac, then fetches its library when it changed since the last time.
    func refresh() async {
        guard sync.isPaired, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try await sync.client()
            // The Mac is back: covers use this connection, and try again those that failed.
            connection = client
            unreachableUntil = .distantPast
            missing.removeAll()
            try await send(with: client)
            let tag = catalog == nil ? nil : UserDefaults.standard.string(forKey: "catalog.tag")
            if let (fetched, newTag) = try await client.catalog(tag: tag) {
                catalog = fetched
                UserDefaults.standard.set(newTag, forKey: "catalog.tag")
                try? JSONEncoder().encode(fetched).write(to: file, options: .atomic)
            }
            error = nil
            reachable = true
        } catch {
            // The Mac answered (with an error) or could not be reached.
            let answered = (error as? MacError).map { $0.status > 0 } ?? false
            reachable = answered
            if !answered { connection = nil }
            self.error = answered ? error.localizedDescription : nil
            Self.log.error("The Mac's library: \(String(describing: error), privacy: .public)")
        }
    }

    /// Asks for an album, an artist or a song on this device (in `encoding`, nil: this device's format), or to take it
    /// off: sent now, or when the Mac is reachable; the marks show it at once.
    func request(_ action: TransferRequest.Action, _ kind: TransferRequest.Kind, key: String, encoding: String? = nil) {
        pending.append(TransferRequest(id: UUID().uuidString, action: action, kind: kind, key: key, encoding: action == .add ? encoding : nil))
        savePending()
        Task { await refresh() }
    }

    private func send(with client: MacClient) async throws {
        let sent = pending
        guard !sent.isEmpty else { return }
        let chosen = try await client.requests(sent)
        catalog?.chosen = chosen
        if let catalog { try? JSONEncoder().encode(catalog).write(to: file, options: .atomic) }
        // Requests made while these were on their way stay for the next time.
        pending.removeFirst(min(sent.count, pending.count))
        savePending()
        sync.syncNow()
    }

    private func savePending() {
        try? JSONEncoder().encode(pending).write(to: pendingFile, options: .atomic)
    }

    // MARK: - The Library with the Mac's music

    /// Every album, the Mac's and this device's that the Mac's list does not have yet (a device's cover when it has
    /// one), by artist then title; `recentFirst`: the ones here newest first, then the rest (the Mac's list has no dates).
    func albums(recentFirst: Bool = false) -> [DeviceCatalog.Album] {
        let mac = catalog?.albums ?? []
        let here = library.contents.albums
        let local = Dictionary(here.map { ($0.albumKey, $0) }, uniquingKeysWith: { first, _ in first })
        let known = Set(mac.map(\.key))
        var all = mac.map { album in
            var album = album
            if let hash = local[album.key]?.artworkHash { album.artworkHash = hash }
            return album
        }
        all += here.filter { !known.contains($0.albumKey) }.map {
            DeviceCatalog.Album(key: $0.albumKey, title: $0.title, artist: $0.artist, year: $0.year, isCompilation: false, artworkHash: $0.artworkHash)
        }
        let byArtist = all.sorted {
            let order = $0.artist.localizedStandardCompare($1.artist)
            return order == .orderedSame ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : order == .orderedAscending
        }
        guard recentFirst else { return byArtist }
        let rank = Dictionary(library.contents.recentlyAdded.enumerated().map { ($0.element.albumKey, $0.offset) }, uniquingKeysWith: min)
        return byArtist.enumerated().sorted { (rank[$0.element.key] ?? Int.max, $0.offset) < (rank[$1.element.key] ?? Int.max, $1.offset) }.map(\.element)
    }

    /// Album artists, the Mac's and this device's, with their number of albums and a cover.
    var artists: [(name: String, albums: Int, artworkHash: String?)] {
        Dictionary(grouping: albums().filter { !Self.isCompilation($0) }, by: \.artist)
            .map { (name: $0.key, albums: $0.value.count, artworkHash: photo(of: $0.key) ?? $0.value.first?.artworkHash) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Every song on the Mac, by title (with this device's songs the Mac's list does not have yet).
    var songs: [DeviceCatalog.Song] {
        let mac = catalog?.songs ?? []
        let known = Set(mac.map(\.id))
        let local = library.contents.songs.filter { $0.id.map { !known.contains($0) } ?? false }.map(Self.song)
        return (mac + local).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// A song of this device, as the Mac's list has its songs.
    private static func song(_ track: Track) -> DeviceCatalog.Song {
        DeviceCatalog.Song(id: track.id ?? 0, title: track.title, artist: track.displayArtist, albumKey: track.albumKey, discNumber: track.discNumber,
                           trackNumber: track.trackNumber, duration: track.duration, codec: AudioSpec.Codec(formatName: track.format).rawValue,
                           sampleRate: track.sampleRate.map { Int($0) }, bitDepth: track.bitDepth,
                           genre: track.genre.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }, year: track.year,
                           artworkHash: track.artworkHash)
    }

    /// An album's songs: the Mac's, or (an album the Mac's list does not have yet) this device's.
    func songsAnywhere(album key: String) -> [DeviceCatalog.Song] {
        let mac = songs(album: key)
        guard mac.isEmpty else { return mac }
        return (library.read { try LibraryDatabase.tracks($0, albumKey: key) } ?? []).filter { $0.id != nil }.map(Self.song)
    }

    /// Every genre, the Mac's and this device's (one of each, whatever its case), by name.
    var genres: [String] {
        var seen: [String: String] = [:]
        for genre in songs.compactMap(\.genre) where seen[genre.lowercased()] == nil { seen[genre.lowercased()] = genre }
        return seen.values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// A genre's songs, by artist, album and track, as the device's genre page orders them.
    func songs(genre: String) -> [DeviceCatalog.Song] {
        let albums = Dictionary((catalog?.albums ?? []).map { ($0.key, $0.title) }, uniquingKeysWith: { first, _ in first })
        return songs.filter { $0.genre?.caseInsensitiveCompare(genre) == .orderedSame }
            .sorted { ($0.artist.lowercased(), albums[$0.albumKey]?.lowercased() ?? "", $0.discNumber ?? 1, $0.trackNumber ?? 0)
                < ($1.artist.lowercased(), albums[$1.albumKey]?.lowercased() ?? "", $1.discNumber ?? 1, $1.trackNumber ?? 0) }
    }

    func songs(album key: String) -> [DeviceCatalog.Song] {
        (catalog?.songs ?? []).filter { $0.albumKey == key }
            .sorted { (($0.discNumber ?? 1), ($0.trackNumber ?? 0), $0.title) < (($1.discNumber ?? 1), ($1.trackNumber ?? 0), $1.title) }
    }

    func album(_ key: String) -> DeviceCatalog.Album? {
        catalog?.albums.first { $0.key == key } ?? library.contents.albums.first { $0.albumKey == key }.map {
            DeviceCatalog.Album(key: $0.albumKey, title: $0.title, artist: $0.artist, year: $0.year, isCompilation: false, artworkHash: $0.artworkHash)
        }
    }

    /// An artist's albums by year; for the compilations entry (`ArtistSummary.compilations`), the albums by various
    /// artists, by title.
    func albums(artist name: String) -> [DeviceCatalog.Album] {
        if name == ArtistSummary.compilations { return compilations }
        return albums().filter { $0.artist == name && !Self.isCompilation($0) }.sorted { ($0.year ?? 0, $0.title) < ($1.year ?? 0, $1.title) }
    }

    /// Albums by various artists, the Mac's and this device's.
    var compilations: [DeviceCatalog.Album] {
        albums().filter(Self.isCompilation).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// A device's album lacks the flag: its artist is the Mac's name for them.
    static func isCompilation(_ album: DeviceCatalog.Album) -> Bool { album.isCompilation || album.artist == "Various Artists" }

    /// The artist's photo on the Mac (or this device's).
    func photo(of artist: String) -> String? {
        library.artistPhoto(artist) ?? catalog?.artists?.first { $0.name == artist }?.artworkHash
    }

    // MARK: - What is where

    /// The selection as the Mac knows it, and as it will be once the waiting requests reach it.
    private var chosen: DeviceCatalog.Chosen? { catalog?.chosen }

    private var after: DeviceCatalog.Chosen? {
        guard let chosen else { return nil }
        guard !pending.isEmpty else { return chosen }
        let catalogSongs = catalog?.songs ?? []
        return chosen.applying(pending) { kind, key in
            switch kind {
            case .album: return catalogSongs.filter { $0.albumKey == key }.map(\.id)
            case .artist:
                let keys = Set((self.catalog?.albums ?? []).filter { $0.artist == key }.map(\.key))
                return catalogSongs.filter { $0.artist == key || keys.contains($0.albumKey) }.map(\.id)
            case .song: return Int64(key).map { [$0] } ?? []
            case .playlist: return []
            }
        }
    }

    func isHere(album key: String) -> Bool { library.contents.albums.contains { $0.albumKey == key } }
    func isHere(song id: Int64) -> Bool { here.contains(id) }
    func isHere(artist name: String) -> Bool { library.contents.artists.contains { $0.name == name } }

    private var here: Set<Int64> { Set(library.contents.songs.compactMap(\.id)) }

    func availability(album: DeviceCatalog.Album) -> CatalogAvailability {
        let songs = Set(songs(album: album.key).map(\.id))
        guard let chosen, let after else { return isHere(album: album.key) ? .onDevice : .onMac }
        return .of(onDevice: isHere(album: album.key), chosen: chosen.holds(album, songs: songs), chosenAfter: after.holds(album, songs: songs),
                   others: chosen.hasOthers, removed: !songs.isEmpty && songs.isSubset(of: after.excludedTrackIds))
    }

    func availability(song: DeviceCatalog.Song) -> CatalogAvailability {
        guard let chosen, let after else { return isHere(song: song.id) ? .onDevice : .onMac }
        let album = album(song.albumKey)
        return .of(onDevice: isHere(song: song.id), chosen: chosen.holds(song, album: album), chosenAfter: after.holds(song, album: album),
                   others: chosen.hasOthers, removed: after.excludedTrackIds.contains(song.id))
    }

    /// Whether the artist was asked for (or let go) while the Mac is away.
    func isWaiting(artist name: String) -> Bool {
        guard let chosen, let after else { return false }
        return chosen.artists.contains(name) != after.artists.contains(name)
    }

    func isChosen(artist name: String) -> Bool {
        guard let after else { return false }
        return after.everything || after.artists.contains(name)
    }

    /// Everything on the Mac comes here (removing one album does nothing).
    var holdsEverything: Bool { after?.everything ?? false }

    /// Whether removing the album from here would do anything: it is chosen as an album (or all its artist's).
    func canRemove(album: DeviceCatalog.Album) -> Bool {
        guard let after, !after.everything else { return false }
        return after.albumKeys.contains(album.key) || after.artists.contains(album.artist)
    }

    func canRemove(song: DeviceCatalog.Song) -> Bool {
        guard let after, !after.everything else { return false }
        return after.trackIds.contains(song.id)
    }

    /// The format chosen for an album (or its artist), nil for this device's own.
    func encoding(of album: DeviceCatalog.Album) -> String? { after?.encoding(of: album) }

    /// The format this device gets lossless songs in, as the Mac has it.
    var deviceEncoding: String? { catalog?.encoding }

    // MARK: - Covers

    /// A cover: this device's when it has it, else the Mac's (fetched once, then kept).
    /// A cover already here: this device's, or the Mac's library's fetched before (nil otherwise, without fetching).
    func cachedCoverURL(_ hash: String?) -> URL? {
        guard let hash else { return nil }
        if let local = library.artworkURL(hash, size: .large) { return local }
        return covers?.has(hash) == true ? covers?.url(for: hash, size: .small) : nil
    }

    func coverURL(_ hash: String?) async -> URL? {
        guard let hash else { return nil }
        if let local = library.artworkURL(hash) { return local }
        guard let covers else { return nil }
        if covers.has(hash) { return covers.url(for: hash, size: .small) }
        guard !missing.contains(hash) else { return nil }
        // Several covers asking for the same one at once wait for the same download.
        if let fetch = fetching[hash] { return await fetch.value }
        let fetch = Task { () -> URL? in
            defer { fetching[hash] = nil }
            guard let client = await coverClient() else { return nil }
            do {
                guard let data = try await client.catalogArtwork(hash) else {
                    missing.insert(hash)
                    return nil
                }
                covers.store(data, as: hash)
            } catch {
                connection = nil
                return nil
            }
            return covers.has(hash) ? covers.url(for: hash, size: .small) : nil
        }
        fetching[hash] = fetch
        return await fetch.value
    }

    /// One connection to the Mac for every cover (as on Android): finding the Mac and opening a secure connection per
    /// cover made a page of them slow. After failing to reach it, covers wait a minute before trying again.
    private func coverClient() async -> MacClient? {
        if let connection { return connection }
        guard Date.now >= unreachableUntil else { return nil }
        if let connecting { return await connecting.value }
        let task = Task { () -> MacClient? in
            defer { connecting = nil }
            let client = try? await sync.client()
            if client == nil { unreachableUntil = .now.addingTimeInterval(60) }
            connection = client
            return client
        }
        connecting = task
        return await task.value
    }

    static let log = Logger(subsystem: "dev.irwingbraga.groovelight", category: "catalog")
}
