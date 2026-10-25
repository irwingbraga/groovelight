import Foundation
import LibraryKit
import Observation
import OSLog
import PlayerCore
import WirelessSyncClient

/// The library on the device: the same database as the Mac's, filled by each sync's snapshot, watched so the screens
/// follow every change.
@MainActor
@Observable
final class LibraryStore {
    struct Contents: Sendable, Equatable {
        var albums: [AlbumSummary] = []
        var recentlyAdded: [AlbumSummary] = []
        var artists: [ArtistSummary] = []
        var compilations: ArtistSummary?
        var songs: [Track] = []
        var playlists: [PlaylistSummary] = []
        var lovedCount = 0
    }

    let database: LibraryDatabase
    let artwork: ArtworkCache
    let musicFolder: URL
    /// What happens here that the Mac should know (plays, skips, loves), sent with the next sync.
    let journal: HistoryJournal
    private(set) var contents = Contents()
    /// Set when the database could not be opened (the screens say so).
    private(set) var failure: String?

    init(folders: AppFolders) {
        musicFolder = folders.music
        journal = HistoryJournal(url: folders.history)
        do {
            database = try LibraryDatabase(url: folders.database)
        } catch {
            failure = error.localizedDescription
            database = try! LibraryDatabase.inMemory()
        }
        artwork = (try? ArtworkCache(directory: folders.artwork)) ?? (try! ArtworkCache(directory: URL.temporaryDirectory.appendingPathComponent("Artwork")))
        // The app's container gets a new path on updates and restores: the songs' paths follow it.
        try? database.relocateDeviceMusic(to: folders.music)
    }

    var isEmpty: Bool { contents.songs.isEmpty }

    /// Watches the library until the app ends.
    func start() async {
        let observation = database.observe { db in
            let overview = try LibraryDatabase.playlistOverview(db)
            return Contents(albums: try LibraryDatabase.albums(db), recentlyAdded: try LibraryDatabase.recentlyAddedAlbums(db),
                            artists: try LibraryDatabase.artists(db), compilations: try LibraryDatabase.compilations(db),
                            songs: try LibraryDatabase.allTracks(db), playlists: overview.playlists.filter { $0.trackCount > 0 || !$0.playlist.isSmart },
                            lovedCount: overview.lovedCount)
        }
        Task { [weak self] in
            do {
                for try await contents in observation {
                    self?.contents = contents
                }
            } catch {
                self?.failure = error.localizedDescription
            }
        }
    }

    func read<T: Sendable>(_ fetch: @Sendable (Database) throws -> T) -> T? {
        try? database.writer.read(fetch)
    }

    /// A song's cover, by its id.
    func artworkHash(trackId: Int64) -> String? {
        (read { try LibraryDatabase.track($0, id: trackId) } ?? nil)?.artworkHash
    }

    func artworkURL(_ hash: String?, size: ArtworkCache.Size = .small) -> URL? {
        guard let hash, artwork.has(hash) else { return nil }
        return artwork.url(for: hash, size: size)
    }

    /// The artist's photo from the Mac, if it has one.
    func artistPhoto(_ name: String) -> String? {
        read { try LibraryDatabase.artistPhotos($0, names: [name])[name] } ?? nil
    }

    func playable(_ track: Track) -> PlayableItem {
        PlayableItem(id: track.id ?? 0, url: track.url, title: track.title, artist: track.displayArtist, album: track.displayAlbum,
                     duration: track.duration, artworkURL: artworkURL(track.artworkHash, size: .large), sampleRate: track.sampleRate,
                     albumKey: track.albumKey, trackGain: track.replayGainTrackGain ?? track.loudness.map(LoudnessMeter.gain(forLoudness:)),
                     albumGain: track.replayGainAlbumGain, bitDepth: track.bitDepth)
    }

    func setLoved(_ loved: Bool, trackId: Int64) {
        try? database.setLoved(loved, trackId: trackId)
        journal.record(DeviceHistoryEvent(id: HistoryJournal.newId(), trackId: trackId, kind: .love, value: loved ? 1 : 0, atMs: Self.ms(.now)))
    }

    /// A song heard for `seconds` from `startedAt`, counted as the Mac counts it: a play from half of it (or 4 minutes), a
    /// skip under 20 seconds (or half of a short one), else nothing. Kept here, and in the journal for the Mac and Last.fm.
    func recordListen(trackId: Int64, duration: TimeInterval, startedAt: Date, seconds: TimeInterval) {
        guard duration > 0 else { return }
        let kind: DeviceHistoryEvent.Kind
        if seconds >= min(duration * 0.5, 240) {
            kind = .play
            try? database.recordPlay(trackId: trackId, at: startedAt)
        } else if seconds < min(20, duration * 0.5) {
            kind = .skip
            try? database.recordSkip(trackId: trackId)
        } else {
            return
        }
        journal.record(DeviceHistoryEvent(id: HistoryJournal.newId(), trackId: trackId, kind: kind, value: Int(seconds.rounded()),
                                          atMs: Self.ms(startedAt)))
    }

    // MARK: - Playlists edited here
    // Changed here at once, and the journal takes each edit to the Mac. A playlist made here is known to the Mac by the
    // negative id it was made with, until a sync brings the Mac's.

    /// Makes a playlist (empty, or with songs); returns its id here.
    @discardableResult
    func createPlaylist(named name: String, trackIds: [Int64] = []) -> Int64? {
        let now = Date.now
        let localId = -Self.ms(now)
        edit(DeviceHistoryEvent(id: HistoryJournal.newId(), kind: .playlistCreate, atMs: Self.ms(now), playlistId: localId,
                                name: name.trimmingCharacters(in: .whitespacesAndNewlines), trackIds: trackIds))
        return read { db in try Int64.fetchOne(db, sql: "SELECT playlistId FROM deviceHistoryEvent WHERE deviceId = '' AND localPlaylistId = ?",
                                                  arguments: [localId]) } ?? nil
    }

    func addToPlaylist(_ id: Int64, trackIds: [Int64]) {
        edit(.playlistAdd, playlist: id, trackIds: trackIds)
    }

    func removeFromPlaylist(_ id: Int64, trackIds: [Int64]) {
        edit(.playlistRemove, playlist: id, trackIds: trackIds)
    }

    func renamePlaylist(_ id: Int64, to name: String) {
        edit(.playlistRename, playlist: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func deletePlaylist(_ id: Int64) {
        edit(.playlistDelete, playlist: id)
    }

    /// Playlists songs can be added to (not smart ones), by name.
    var editablePlaylists: [PlaylistSummary] {
        contents.playlists.filter { !$0.playlist.isSmart }.sorted { $0.playlist.name.localizedStandardCompare($1.playlist.name) == .orderedAscending }
    }

    private func edit(_ kind: DeviceHistoryEvent.Kind, playlist id: Int64, name: String? = nil, trackIds: [Int64]? = nil) {
        let sent = read { try LibraryDatabase.sentPlaylistId($0, localId: id) } ?? id
        edit(DeviceHistoryEvent(id: HistoryJournal.newId(), kind: kind, atMs: Self.ms(.now), playlistId: sent, name: name, trackIds: trackIds))
    }

    /// Applies an edit here as the Mac will (same rules), and journals it for the Mac.
    private func edit(_ event: DeviceHistoryEvent) {
        do {
            try database.applyDeviceHistory([event])
            journal.record(event)
        } catch {
            Self.log.error("Playlist edit failed: \(String(describing: error), privacy: .public)")
        }
    }

    static let log = Logger(subsystem: "dev.irwingbraga.groovelight", category: "library")

    private static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}
