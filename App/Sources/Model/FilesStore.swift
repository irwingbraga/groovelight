import AppKit
import Foundation
import LibraryKit
import MetadataKit
import Observation

/// File operations on the library folder: Organize (rename and move files with the naming template), Import (bring
/// songs into the library: identify, tag, name), and undoing the last of either.
@MainActor
@Observable
final class FilesStore {
    static let optionsKey = "files.organizeOptions"

    var options: OrganizeOptions {
        didSet { if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: Self.optionsKey) } }
    }

    /// Organize sheet request (songs to organize, nil for the whole library).
    var organizeRequest: OrganizeRequest?
    struct OrganizeRequest: Identifiable {
        let id = UUID()
        var tracks: [Track]?
    }

    /// The import in progress (the sheet shows it).
    var importSession: ImportSession?

    /// The last organize or import that can be undone.
    private(set) var undoable: FileOperationJournal?
    private(set) var isWorking = false

    @ObservationIgnored private unowned let model: AppModel

    var journalsFolder: URL { URL.applicationSupportDirectory.appendingPathComponent("Groovelight/File Operations", isDirectory: true) }

    init(model: AppModel) {
        self.model = model
        options = UserDefaults.standard.data(forKey: Self.optionsKey).flatMap { try? JSONDecoder().decode(OrganizeOptions.self, from: $0) }
            ?? OrganizeOptions()
        undoable = FileOrganizer.latestJournal(in: journalsFolder)?.0
    }

    // MARK: - Organize

    func organize(_ tracks: [Track]? = nil) {
        organizeRequest = OrganizeRequest(tracks: tracks)
    }

    /// Planned renames for songs (or the whole library), each under its own library folder.
    func plan(for tracks: [Track]?) async -> [RenamePlanItem] {
        let database = model.database
        let options = options
        return await Task.detached(priority: .userInitiated) {
            let (songs, roots) = (try? database.writer.read { db in
                (try tracks ?? LibraryDatabase.allTracks(db), try LibraryDatabase.roots(db))
            }) ?? ([], [])
            return roots.flatMap { root in
                RenamePlanner.plan(tracks: songs.filter { $0.rootId == root.id }, root: URL(fileURLWithPath: root.path, isDirectory: true),
                                   options: options)
            }
        }.value
    }

    func apply(_ plan: [RenamePlanItem]) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let database = model.database
        do {
            let journal = try await Task.detached(priority: .userInitiated) { try FileOrganizer.apply(plan, database: database) }.value
            try FileOrganizer.save(journal, in: journalsFolder)
            undoable = journal
        } catch {
            model.errorMessage = "Could not rename the files (nothing was changed): \(error.localizedDescription)"
        }
    }

    // MARK: - Undo

    var undoTitle: String {
        switch undoable?.kind {
        case .import: "Undo Import"
        case .organize: "Undo Organize Files"
        case nil: "Undo Last File Operation"
        }
    }

    func undoLast() async {
        guard let (journal, file) = FileOrganizer.latestJournal(in: journalsFolder), !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let database = model.database
        do {
            try await Task.detached(priority: .userInitiated) { try FileOrganizer.undo(journal, database: database) }.value
            try? FileManager.default.removeItem(at: file)
            undoable = FileOrganizer.latestJournal(in: journalsFolder)?.0
        } catch {
            model.errorMessage = "Could not undo: \(error.localizedDescription)"
        }
    }

    // MARK: - Import

    func chooseAndImport(folders: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folders
        panel.canChooseFiles = !folders
        panel.allowsMultipleSelection = true
        if !folders { panel.allowedContentTypes = [.audio] }
        panel.prompt = "Import"
        panel.message = folders ? "Choose folders of music to import into your library." : "Choose songs to import into your library."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        guard !((try? model.database.writer.read { try LibraryDatabase.roots($0) }) ?? []).isEmpty else {
            model.errorMessage = "Add a library folder first (Settings, Library): imported songs are moved there."
            return
        }
        for url in panel.urls { _ = url.startAccessingSecurityScopedResource() }
        let session = ImportSession(urls: panel.urls, model: model, store: self)
        importSession = session
        Task { await session.analyze() }
    }

    func finishImport(_ journal: FileOperationJournal) {
        try? FileOrganizer.save(journal, in: journalsFolder)
        undoable = journal
    }
}

/// One import: the chosen files, what was found for them, and where they will go.
@MainActor
@Observable
final class ImportSession: Identifiable {
    enum Phase: Equatable {
        case reading(done: Int, total: Int)
        case identifying(done: Int, total: Int)
        case review
        case importing(done: Int, total: Int)
        case finished(imported: Int, skipped: Int, failed: Int)
    }

    struct Item: Identifiable {
        let id: Int64
        var source: URL
        var tags: FileTags
        /// From the file's own tags.
        var fileMetadata: TrackMetadata
        /// From the MusicBrainz match, when the album was identified.
        var onlineMetadata: TrackMetadata?
        var hasArtwork: Bool
        var isDuplicate: Bool
        var include: Bool
        /// An album in one audio file with a cue sheet: imported as a unit, keeping the file names.
        var cue: CueAlbum?
    }

    struct CueAlbum {
        /// The external sheet (nil when it is embedded in the audio file).
        var sheet: URL?
        var songs: Int
    }

    struct Group: Identifiable {
        let id: String
        var title: String
        var artist: String
        /// "OK Computer (1997)" when matched on MusicBrainz.
        var matchedRelease: String?
        var cover: Data?
        var items: [Item]
    }

    var phase: Phase = .reading(done: 0, total: 0)
    var groups: [Group] = []
    var moveFiles = true
    var useOnlineMetadata = true
    var writeTags = true
    var rootId: Int64?
    var roots: [LibraryRoot] = []

    private let urls: [URL]
    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private unowned let store: FilesStore

    init(urls: [URL], model: AppModel, store: FilesStore) {
        self.urls = urls
        self.model = model
        self.store = store
    }

    var includedCount: Int { groups.reduce(0) { $0 + $1.items.filter(\.include).count } }
    var duplicateCount: Int { groups.reduce(0) { $0 + $1.items.filter(\.isDuplicate).count } }

    func metadata(of item: Item) -> TrackMetadata {
        guard useOnlineMetadata, let online = item.onlineMetadata else { return item.fileMetadata }
        return item.fileMetadata.merging(online)
    }

    /// Where an item will go (relative to the library folder), with " (2)" when taken.
    func destinations() -> [Int64: URL] {
        guard let root = roots.first(where: { $0.id == rootId }) else { return [:] }
        let base = URL(fileURLWithPath: root.path, isDirectory: true)
        var options = store.options
        options.organizeFolders = true
        var taken = Set<String>()
        var result: [Int64: URL] = [:]
        for item in groups.flatMap(\.items) where item.include {
            let metadata = metadata(of: item)
            if item.cue != nil {
                // The album folder from the template, with the audio file's own name (the sheet refers to it).
                let fields = NamingFields(title: "", artist: metadata.artist, album: metadata.album, albumArtist: metadata.albumArtist,
                                          genre: metadata.genre, year: metadata.year, trackNumber: 1, discNumber: metadata.discNumber,
                                          discTotal: metadata.discTotal, isCompilation: false)
                let folder = base.appendingPathComponent(FileNaming.relativePath(for: fields, fileExtension: item.source.pathExtension, options: options))
                    .deletingLastPathComponent()
                let destination = folder.appendingPathComponent(item.source.lastPathComponent).standardizedFileURL
                taken.insert(destination.path.lowercased())
                result[item.id] = destination
                continue
            }
            let fields = NamingFields(title: metadata.title ?? item.source.deletingPathExtension().lastPathComponent, artist: metadata.artist,
                                      album: metadata.album, albumArtist: metadata.albumArtist, genre: metadata.genre, year: metadata.year,
                                      trackNumber: metadata.trackNumber, discNumber: metadata.discNumber, discTotal: metadata.discTotal,
                                      isCompilation: metadata.isCompilation ?? false)
            let relative = FileNaming.relativePath(for: fields, fileExtension: item.source.pathExtension, options: options)
            var destination = base.appendingPathComponent(relative).standardizedFileURL
            var counter = 2
            while taken.contains(destination.path.lowercased()) || FileManager.default.fileExists(atPath: destination.path) {
                let name = base.appendingPathComponent(relative).deletingPathExtension().lastPathComponent
                destination = base.appendingPathComponent(relative).deletingLastPathComponent()
                    .appendingPathComponent("\(name) (\(counter))").appendingPathExtension(item.source.pathExtension).standardizedFileURL
                counter += 1
            }
            taken.insert(destination.path.lowercased())
            result[item.id] = destination
        }
        return result
    }

    // MARK: Analysis

    func analyze() async {
        let database = model.database
        roots = (try? await database.writer.read { try LibraryDatabase.roots($0) }) ?? []
        rootId = roots.first?.id
        let urls = urls
        let (files, cueFiles) = await Task.detached { Self.audioFiles(in: urls) }.value
        phase = .reading(done: 0, total: files.count)
        let library = (try? await database.writer.read { try LibraryDatabase.allTracks($0) }) ?? []

        // Cue sheets beside the chosen audio: a FILE with two or more tracks makes that file an album.
        let audioPaths = Set(files.map(\.path))
        var sheets: [String: (url: URL, sheet: CueSheet, songs: Int)] = [:]
        for url in cueFiles {
            guard let sheet = CueSheet.read(url) else { continue }
            for file in sheet.files where file.tracks.count >= 2 {
                if let audio = CueSheet.resolve(file.name, relativeTo: url.deletingLastPathComponent(), audioFiles: audioPaths),
                   sheets[audio.path] == nil {
                    sheets[audio.path] = (url, sheet, file.tracks.count)
                }
            }
        }

        var items: [Item] = []
        for (index, url) in files.enumerated() {
            if let tags = await Task.detached(operation: { try? TagReader.read(url) }).value {
                var candidate = Track.candidate(id: Int64(-(index + 1)), url: url, tags: tags)
                var cue: CueAlbum?
                let embedded = tags.cueSheet.flatMap(CueSheet.parse).flatMap { sheet in sheet.files.first.map { (sheet, $0.tracks.count) } }
                if let external = sheets[url.path] {
                    cue = CueAlbum(sheet: external.url, songs: external.songs)
                    Self.describe(&candidate, with: external.sheet, songs: external.songs)
                } else if let (sheet, songs) = embedded, songs >= 2 {
                    cue = CueAlbum(sheet: nil, songs: songs)
                    Self.describe(&candidate, with: sheet, songs: songs)
                }
                let isDuplicate = cue == nil ? Self.isInLibrary(candidate, library: library)
                    : library.contains { $0.isCueTrack && $0.displayAlbum.lowercased() == candidate.displayAlbum.lowercased()
                                         && $0.displayAlbumArtist.lowercased() == candidate.displayAlbumArtist.lowercased() }
                items.append(Item(id: candidate.id!, source: url, tags: Self.withoutArtwork(tags), fileMetadata: candidate.metadata,
                                  onlineMetadata: nil, hasArtwork: tags.artwork != nil,
                                  isDuplicate: isDuplicate, include: true, cue: cue))
                if let artwork = tags.artwork, let group = Self.groupKey(candidate), firstArtwork[group] == nil { firstArtwork[group] = artwork }
            }
            phase = .reading(done: index + 1, total: files.count)
        }
        for index in items.indices where items[index].isDuplicate { items[index].include = false }

        // Group by album (tags), or by folder for untagged files.
        var grouped: [String: [Item]] = [:]
        var order: [String] = []
        for item in items {
            let key = Self.groupKey(Track.candidate(id: item.id, url: item.source, tags: item.tags)) ?? item.source.deletingLastPathComponent().path
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(item)
        }
        groups = order.map { key in
            let members = grouped[key]!
            let first = members[0].fileMetadata
            return Group(id: key, title: first.album ?? members[0].source.deletingLastPathComponent().lastPathComponent,
                         artist: first.albumArtist ?? first.artist ?? "Unknown Artist", matchedRelease: nil, cover: firstArtwork[key], items: members)
        }

        // Identify each album online (confident matches only), with a cover when the files have none.
        if UserDefaults.standard.bool(forKey: MetadataStore.Keys.fetchAlbumInfo) {
            let service = model.metadata.service
            for index in groups.indices {
                phase = .identifying(done: index, total: groups.count)
                // Cue albums are described by their sheet: not identified online.
                let candidates = groups[index].items.filter { !$0.isDuplicate && $0.cue == nil }
                    .map { Track.candidate(id: $0.id, url: $0.source, tags: $0.tags) }
                guard !candidates.isEmpty else { continue }
                if let (match, proposal) = await Self.identify(candidates, service: service) {
                    for itemIndex in groups[index].items.indices {
                        groups[index].items[itemIndex].onlineMetadata = proposal[groups[index].items[itemIndex].id]
                    }
                    groups[index].matchedRelease = match.release.title + (match.release.year.map { " (\($0))" } ?? "")
                    groups[index].title = match.release.title
                    groups[index].artist = match.release.artistName
                    if groups[index].cover == nil,
                       let (_, data) = await service.cover(for: match.release, album: match.release.title, artist: match.release.artistName) {
                        groups[index].cover = data
                    }
                }
            }
        }
        phase = .review
    }

    @ObservationIgnored private var firstArtwork: [String: Data] = [:]

    private static func identify(_ tracks: [Track], service: MetadataService) async -> (ReleaseMatch, [Int64: TrackMetadata])? {
        guard let candidates = try? await service.candidates(for: tracks) else { return nil }
        for release in candidates.prefix(2) {
            guard let match = try? await service.match(tracks, releaseId: release.id) else { continue }
            if MetadataService.isConfident(match, localCount: tracks.count) {
                return (match, ReleaseMatcher.proposal(for: match))
            }
        }
        return nil
    }

    /// Audio files and cue sheets among the chosen files and folders (and, for chosen files, the sheets beside them).
    nonisolated private static func audioFiles(in urls: [URL]) -> (audio: [URL], cues: [URL]) {
        let extensions = TagReader.supportedExtensions
        var files: [URL] = []
        var cues = Set<URL>()
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let file = enumerator?.nextObject() as? URL {
                    let ext = file.pathExtension.lowercased()
                    if extensions.contains(ext) { files.append(file.standardizedFileURL) } else if ext == "cue" { cues.insert(file.standardizedFileURL) }
                }
            } else if extensions.contains(url.pathExtension.lowercased()) {
                files.append(url.standardizedFileURL)
                let folder = url.deletingLastPathComponent()
                let siblings = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
                cues.formUnion(siblings.filter { $0.pathExtension.lowercased() == "cue" }.map(\.standardizedFileURL))
            }
        }
        let sorted = files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return (sorted, cues.sorted { $0.path < $1.path })
    }

    /// A cue album's audio file as the import shows it: the sheet's album and performer.
    private static func describe(_ candidate: inout Track, with sheet: CueSheet, songs: Int) {
        candidate.title = "\(songs) songs"
        candidate.album = sheet.title ?? candidate.album
        candidate.albumArtist = sheet.performer ?? candidate.albumArtist
        candidate.artist = sheet.performer ?? candidate.artist
        candidate.year = sheet.year ?? candidate.year
        candidate.genre = sheet.genre ?? candidate.genre
        candidate.trackNumber = nil
        candidate.albumKey = Track.makeAlbumKey(album: candidate.album, albumArtist: candidate.albumArtist, artist: candidate.artist,
                                                isCompilation: false)
    }

    private static func groupKey(_ track: Track) -> String? {
        guard let album = track.album, !album.isEmpty else { return nil }
        return track.albumKey
    }

    private static func withoutArtwork(_ tags: FileTags) -> FileTags {
        var tags = tags
        tags.artwork = nil
        return tags
    }

    /// Same song already in the library: same MusicBrainz recording, or same title, artist, album and length.
    private static func isInLibrary(_ candidate: Track, library: [Track]) -> Bool {
        library.contains { track in
            if let recording = candidate.musicBrainzRecordingId, recording == track.musicBrainzRecordingId,
               candidate.musicBrainzReleaseId == track.musicBrainzReleaseId { return true }
            return track.title.lowercased() == candidate.title.lowercased()
                && track.displayArtist.lowercased() == candidate.displayArtist.lowercased()
                && track.displayAlbum.lowercased() == candidate.displayAlbum.lowercased()
                && abs(track.duration - candidate.duration) < 2
        }
    }

    // MARK: Importing

    func run() async {
        let destinations = destinations()
        let selected = groups.flatMap { group in group.items.filter(\.include).map { (group, $0) } }
        guard !selected.isEmpty else { return }
        phase = .importing(done: 0, total: selected.count)
        var entries: [FileOperationJournal.Entry] = []
        var created: [String] = []
        var failed = 0
        let move = moveFiles
        for (index, (group, item)) in selected.enumerated() {
            guard let destination = destinations[item.id] else { continue }
            let metadata = metadata(of: item)
            let cover = item.hasArtwork ? nil : group.cover
            // A cue album's file holds every song: its tags are left alone.
            let write = writeTags && item.cue == nil
            let sheet = item.cue?.sheet
            let sheetDestination = sheet.map { destination.deletingLastPathComponent().appendingPathComponent($0.lastPathComponent) }
            let result = await Task.detached(priority: .userInitiated) { () -> (Bool, [String]) in
                let fileManager = FileManager.default
                var createdFolders: [String] = []
                do {
                    var folder = destination.deletingLastPathComponent()
                    var missing: [URL] = []
                    while !FileManager.default.fileExists(atPath: folder.path) {
                        missing.append(folder)
                        folder = folder.deletingLastPathComponent()
                    }
                    for folder in missing.reversed() {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                        createdFolders.append(folder.path)
                    }
                    // The sheet first: if its name is taken the album is not imported.
                    if let sheet, let sheetDestination {
                        if move { try fileManager.moveItem(at: sheet, to: sheetDestination) } else { try fileManager.copyItem(at: sheet, to: sheetDestination) }
                    }
                    do {
                        if move { try fileManager.moveItem(at: item.source, to: destination) } else { try fileManager.copyItem(at: item.source, to: destination) }
                    } catch {
                        if let sheet, let sheetDestination {
                            if move { try? fileManager.moveItem(at: sheetDestination, to: sheet) } else { try? fileManager.removeItem(at: sheetDestination) }
                        }
                        throw error
                    }
                    // Tags and cover into the file now in the library (the source is left as it was when copying).
                    if write { _ = try? TagWriter.write(metadata, frontCover: cover, to: destination) }
                    return (true, createdFolders)
                } catch {
                    return (false, createdFolders)
                }
            }.value
            created += result.1
            if result.0 {
                if let sheet, let sheetDestination {
                    entries.append(.init(trackId: nil, from: sheet.path, to: sheetDestination.path, copied: !move))
                }
                entries.append(.init(trackId: nil, from: item.source.path, to: destination.path, copied: !move))
            } else {
                failed += 1
            }
            phase = .importing(done: index + 1, total: selected.count)
        }

        // Scan so the songs join the library, then record their ids for undo.
        await model.rescanAndWait()
        let paths = entries.map(\.to)
        let ids = (try? await model.database.writer.read { db in
            try LibraryDatabase.allTracks(db).filter { paths.contains($0.path) }.reduce(into: [String: Int64]()) { $0[$1.path] = $1.id }
        }) ?? [:]
        for index in entries.indices { entries[index].trackId = ids[entries[index].to] }

        // Credits, album and artist backgrounds, missing covers and lyrics for what came in, in the background (queued
        // behind a library job if one is running, under the same rate limits).
        let cuePaths = Set(entries.filter { $0.trackId == nil }.map(\.to))
        let cueIds = (try? await model.database.writer.read { db in
            try LibraryDatabase.allTracks(db).filter { $0.audioPath.map(cuePaths.contains) ?? false }.compactMap(\.id)
        }) ?? []
        let importedIds = Set(entries.compactMap(\.trackId) + cueIds)
        if !importedIds.isEmpty { model.metadata.fetchMissingInfo(scope: .tracks(importedIds)) }
        store.finishImport(FileOperationJournal(id: UUID(), kind: .import, date: .now, entries: entries, createdFolders: created))
        phase = .finished(imported: entries.filter { !$0.to.lowercased().hasSuffix(".cue") }.count, skipped: groups.reduce(0) { $0 + $1.items.filter { !$0.include }.count }, failed: failed)
    }
}
