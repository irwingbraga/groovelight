import Foundation
import LibraryKit
import WirelessSync

/// One sync of a device where Groovelight plays the music (Groovelight for iOS): tells the Mac what the music folder
/// holds, gets the plan, removes and downloads files (each checked against the Mac's SHA-256), keeps the manifest
/// (`.groovelight-device.json`, the file Groovelight writes on memory cards) up to date as it goes. The library snapshot
/// comes first and is imported again as songs arrive, so each one can be played while the rest download.
public struct CompanionSync: Sendable {
    public struct Progress: Sendable {
        public var done: Int
        public var total: Int
        public var current: String
    }

    public struct Outcome: Sendable {
        public var written: Int
        public var deleted: Int
        public var failed: [String]
        public var songs: Int
        public var missingCovers: Int

        /// "Up to date", or "12 added, 1 failed".
        public var summary: String {
            var parts: [String] = []
            if written > 0 { parts.append("\(written) added") }
            if deleted > 0 { parts.append("\(deleted) removed") }
            if !failed.isEmpty { parts.append("\(failed.count) failed") }
            if missingCovers > 0 { parts.append(missingCovers == 1 ? "1 album without a cover" : "\(missingCovers) albums without a cover") }
            return parts.isEmpty ? "Up to date" : parts.joined(separator: ", ")
        }
    }

    /// The formats the device decodes (`AudioSpec.Codec` raw values): SFBAudioEngine reads all of the Mac's, so the
    /// Mac converts nothing for it.
    public static let decodes = ["flac", "alac", "wav", "aiff", "wavPack", "monkeysAudio", "trueAudio", "oggFLAC", "dsf", "dsdiff",
                                 "mp3", "aac", "vorbis", "opus", "musepack", "speex", "mp1", "mp2"]

    public let client: MacClient
    public let musicFolder: URL
    public let library: LibraryDatabase
    public let artwork: ArtworkCache
    public var deviceName: String
    public var model: String
    /// "original" or a `LossyEncoding` raw value chosen on the device; nil: as set on the Mac's device page.
    public var encoding: String?
    /// Who downloads the songs: the app's background downloads, or (nil) the sync's own, while it runs.
    public var downloads: FileDownloads?
    /// The device's plays, loves and edits, sent before anything else: the snapshot the Mac sends back then has them.
    public var journal: HistoryJournal?

    public init(client: MacClient, musicFolder: URL, library: LibraryDatabase, artwork: ArtworkCache, deviceName: String, model: String,
                encoding: String? = nil, downloads: FileDownloads? = nil, journal: HistoryJournal? = nil) {
        self.client = client
        self.musicFolder = musicFolder
        self.library = library
        self.artwork = artwork
        self.deviceName = deviceName
        self.model = model
        self.encoding = encoding
        self.downloads = downloads
        self.journal = journal
    }

    public func run(progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> Outcome {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: musicFolder, withIntermediateDirectories: true)
        progress(Progress(done: 0, total: 0, current: "Looking at the music folder…"))
        var manifest = DeviceManifest.read(from: musicFolder)
        // The folder is the app's own: a file the manifest does not list was left by a sync cut short (the app ended
        // between putting it in place and recording it). Gone, or the Mac would take it for someone else's and write
        // the song beside it under another name.
        let strays = Self.files(in: musicFolder).filter { manifest.entries[$0] == nil }
        for path in strays { try? fileManager.removeItem(at: musicFolder.appendingPathComponent(path)) }
        let files = Self.files(in: musicFolder)
        let (capacity, available) = Self.space(of: musicFolder)

        progress(Progress(done: 0, total: 0, current: "Asking the \(Host.word)…"))
        try await journal?.send(with: client)
        let request = WirelessProtocol.SyncRequest(
            manifest: manifest, files: files, capacity: capacity, available: available, model: model, name: deviceName,
            volumes: [WirelessProtocol.Volume(name: "Internal storage", removable: false, total: capacity, free: available, music: true)],
            mode: "player", decodes: Self.decodes, encoding: encoding)
        let plan = try await client.sync(request)
        guard let token = plan.token else { throw MacError("Update Groovelight on the \(Host.word): this device needs its secure connection.") }

        // Removals first, to make room.
        for path in plan.deletions {
            try? fileManager.removeItem(at: musicFolder.appendingPathComponent(path))
            manifest.entries[path] = nil
        }
        Self.pruneEmptyFolders(in: musicFolder, after: plan.deletions)
        manifest.entries.merge(plan.unchanged) { _, new in new }
        manifest.profile = plan.profile
        try manifest.write(to: musicFolder)

        // The library first: the songs already here (without the ones just removed) right away, then the ones that
        // arrive, every few seconds, so they can be played before the sync ends.
        let total = plan.writes.count
        progress(Progress(done: 0, total: total, current: "Getting the library…"))
        let snapshot = try await librarySnapshot(session: plan.session, token: token)
        var coversAsked = Set<String>()
        _ = try await importLibrary(snapshot, session: plan.session, token: token, coversAsked: &coversAsked) { isHere($0) }
        let refresher = Task { [self, coversAsked] in
            var coversAsked = coversAsked
            var imported = -1
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { break }
                let here = snapshot.songs.filter { isHere($0) }.count
                guard here != imported else { continue }
                imported = here
                _ = try? await importLibrary(snapshot, session: plan.session, token: token, coversAsked: &coversAsked) { isHere($0) }
            }
        }

        // Each file goes into the manifest as it arrives (see `FileDownloads`).
        var failed: [String] = []
        let writes = plan.writes
        let downloads = downloads ?? FileDownloads(configuration: .ephemeral, musicFolder: musicFolder)
        progress(Progress(done: 0, total: total, current: writes.first.map { ($0.path as NSString).lastPathComponent } ?? ""))
        let outcomes: [String: FileDownloads.Outcome]
        do {
            outcomes = try await downloads.download(writes, client: client, session: plan.session, token: token) { done, name in
                progress(Progress(done: done, total: total, current: name))
            }
        } catch {
            refresher.cancel()
            await refresher.value
            throw error
        }
        refresher.cancel()
        await refresher.value
        var written = 0
        for write in writes {
            switch outcomes[write.path] {
            case .success: written += 1
            case .failure(let error): failed.append("\(write.path): \(error.localizedDescription)")
            case nil: failed.append("\(write.path): not downloaded")
            }
        }
        manifest = DeviceManifest.read(from: musicFolder)
        manifest.lastSync = .now
        try manifest.write(to: musicFolder)

        progress(Progress(done: plan.writes.count, total: plan.writes.count, current: "Updating the library…"))
        let failedPaths = Set(failed.map { String($0.prefix { $0 != ":" }) })
        var allCovers = Set<String>()
        let (songs, missingCovers) = try await importLibrary(snapshot, session: plan.session, token: token, coversAsked: &allCovers,
                                                             final: true) { !failedPaths.contains($0.path) && isHere($0) }

        progress(Progress(done: plan.writes.count, total: plan.writes.count, current: "Finishing…"))
        let result = WirelessProtocol.SyncResult(written: written, deleted: plan.deletions.count, failed: failed,
                                                 available: Self.space(of: musicFolder).available)
        try? await client.done(session: plan.session, result: result)
        return Outcome(written: written, deleted: plan.deletions.count, failed: failed, songs: songs, missingCovers: missingCovers)
    }

    /// The library snapshot for the songs the device holds once this sync is done.
    private func librarySnapshot(session: String, token: String) async throws -> DeviceSnapshot {
        let data = try await client.snapshot(session: session, token: token)
        return try WirelessProtocol.decoder.decode(DeviceSnapshot.self, from: data)
    }

    /// Whether a song of the snapshot is in the music folder (downloads put a file in place only once it is whole).
    private func isHere(_ song: DeviceSnapshot.Song) -> Bool {
        FileManager.default.fileExists(atPath: musicFolder.appendingPathComponent(song.path).path)
    }

    /// Imports the snapshot's songs that `keep` takes (and their albums), fetching the covers and artist photos they
    /// need; covers already asked for in `coversAsked` are not asked again until the `final` import, which also lets go
    /// of covers nothing uses. Returns how many songs the library has and how many albums are left without a cover.
    private func importLibrary(_ full: DeviceSnapshot, session: String, token: String, coversAsked: inout Set<String>, final: Bool = false,
                               keep: (DeviceSnapshot.Song) -> Bool) async throws -> (Int, Int) {
        var snapshot = full
        snapshot.songs.removeAll { !keep($0) }
        let keys = Set(snapshot.songs.map(\.albumKey))
        snapshot.albums.removeAll { !keys.contains($0.key) }
        var hashes = Set(snapshot.songs.compactMap(\.artworkHash) + snapshot.albums.compactMap(\.artworkHash))
        hashes.formUnion(snapshot.artists?.map(\.artworkHash) ?? [])
        hashes.formUnion(snapshot.playlists.compactMap { $0.cover?.imageHash })
        for hash in hashes where !artwork.has(hash) && (final || !coversAsked.contains(hash)) {
            try Task.checkCancellation()
            coversAsked.insert(hash)
            // Every cover comes with its SHA-256: an empty or damaged one is not kept (the next sync asks again).
            if let image = try? await client.artwork(session: session, token: token, hash: hash), !image.isEmpty {
                artwork.store(image, as: hash)
            }
        }
        try library.importSnapshot(snapshot, musicFolder: musicFolder)
        if final { artwork.prune(keeping: hashes) }
        let missing = snapshot.albums.filter { album in album.artworkHash.map { !artwork.has($0) } ?? true }.count
        return (snapshot.songs.count, missing)
    }

    /// Every file under the music folder, relative to it (the manifest left out).
    static func files(in folder: URL) -> [String] {
        let base = folder.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var files: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            let relative = String(path.dropFirst(base.count + 1))
            if relative != DeviceManifest.fileName { files.append(relative) }
        }
        return files.sorted()
    }

    /// The device's capacity and the space apps may use.
    static func space(of folder: URL) -> (capacity: Int64, available: Int64) {
        let values = try? folder.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return (Int64(values?.volumeTotalCapacity ?? 0), values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    /// Removes folders left empty by deletions (album and artist folders).
    static func pruneEmptyFolders(in root: URL, after deletions: [String]) {
        let fileManager = FileManager.default
        var folders = Set(deletions.compactMap { path -> String? in
            let parent = (path as NSString).deletingLastPathComponent
            return parent.isEmpty ? nil : parent
        })
        while !folders.isEmpty {
            var parents = Set<String>()
            for folder in folders {
                let url = root.appendingPathComponent(folder)
                if (try? fileManager.contentsOfDirectory(atPath: url.path))?.isEmpty == true {
                    try? fileManager.removeItem(at: url)
                    let parent = (folder as NSString).deletingLastPathComponent
                    if !parent.isEmpty { parents.insert(parent) }
                }
            }
            folders = parents
        }
    }
}
