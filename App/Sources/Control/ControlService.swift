import AppKit
import ControlKit
import LibraryKit
import MetadataKit
import PlayerCore

/// Does what the command line tool asks (see ControlKit): library questions and playback are answered at once;
/// imports, fixes and file operations run as jobs the tool polls for progress. Everything goes through the same code
/// as the windows, so the library, undo and the windows stay in step.
@MainActor
final class ControlService {
    private unowned let model: AppModel
    private var server: ControlServer?
    private var jobs: [String: Job] = [:]
    private var nextJob = 1
    /// Paths the tool is about to open with the app (to give it access), and when it said so.
    private var expected: [String: Date] = [:]
    /// Paths the app was given access to that way.
    private var granted: Set<String> = []

    init(model: AppModel) {
        self.model = model
    }

    /// Whether this copy of the app answers the command line (false when another copy took the port).
    var isListening: Bool { server != nil }

    func start() {
        let server = ControlServer { [weak self] request in
            self?.handle(request) ?? .failure("Groovelight is quitting.")
        }
        if server.start() {
            self.server = server
        } else {
            NSLog("Groovelight: the command line port \(ControlPort.name) is in use (another copy of the app is running)")
        }
    }

    // MARK: - Opened files

    /// Files the app was opened with: from the tool (taken in silently, its import follows), or from Finder's Open
    /// With and the Dock icon (imported like a drop on the window).
    func open(_ urls: [URL]) {
        let now = Date.now
        expected = expected.filter { now.timeIntervalSince($0.value) < 60 }
        var others: [URL] = []
        for url in urls {
            let path = Self.normalized(url.path)
            if expected.removeValue(forKey: path) != nil {
                _ = url.startAccessingSecurityScopedResource()
                granted.insert(path)
            } else {
                others.append(url)
            }
        }
        guard !others.isEmpty else { return }
        NSApp.activate()
        model.files.importItems(others)
    }

    /// One spelling per path: the tool resolves "/private/tmp/x" to "/tmp/x", while Launch Services hands the app
    /// "/private/tmp/x" (the same for /var and /etc).
    static func normalized(_ path: String) -> String {
        var path = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        for link in ["/tmp", "/var", "/etc"] where path == "/private" + link || path.hasPrefix("/private" + link + "/") {
            path.removeFirst("/private".count)
        }
        return path
    }

    // MARK: - Requests

    func handle(_ request: ControlRequest) -> ControlReply {
        do {
            switch request {
            case .status: return try status()
            case .search(let query, let limit): return try search(query, limit: limit)
            case .importFiles(let options): return startJob { try await self.importFiles(options, job: $0) }
            case .fixMetadata(let options): return startJob { try await self.fixMetadata(options, job: $0) }
            case .organize(let options): return startJob { try await self.organize(options, job: $0) }
            case .undo: return startJob { _ in try await self.undo() }
            case .rescan: return startJob { try await self.rescan(job: $0) }
            case .play(let options): return try play(options)
            case .playback(let action): return playback(action)
            case .listPlaylists: return try listPlaylists()
            case .createPlaylist(let name, let songIds): return try createPlaylist(named: name, songIds: songIds)
            case .addToPlaylist(let playlist, let songIds): return try addToPlaylist(playlist, songIds: songIds)
            case .nowPlaying: return nowPlaying()
            case .expectFiles(let paths):
                for path in paths { expected[Self.normalized(path)] = .now }
                return ControlReply()
            case .poll(let id): return poll(id)
            case .cancel(let id):
                jobs[id]?.task?.cancel()
                return ControlReply(summary: "Cancelling job \(id).")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Jobs

    @MainActor
    final class Job {
        let id: String
        var messages: [String] = []
        var progress: JobProgress?
        var result: ControlReply?
        var task: Task<Void, Never>?

        init(id: String) {
            self.id = id
        }

        func report(_ label: String, _ done: Int = 0, _ total: Int = 0) {
            progress = JobProgress(label: label, done: done, total: total)
        }
    }

    /// One job at a time: they move files and write tags.
    private func startJob(_ work: @escaping @MainActor (Job) async throws -> ControlReply) -> ControlReply {
        if let busy = jobs.values.first(where: { $0.result == nil }) {
            return .failure("Groovelight is busy with another command (job \(busy.id)). Try again when it is done.")
        }
        // Results nobody came back for.
        jobs = jobs.filter { $0.value.result == nil }
        let job = Job(id: String(nextJob))
        nextJob += 1
        jobs[job.id] = job
        job.task = Task {
            do {
                job.result = try await work(job)
            } catch {
                job.result = .failure(error.localizedDescription)
            }
        }
        return ControlReply(job: job.id, finished: false)
    }

    private func poll(_ id: String) -> ControlReply {
        guard let job = jobs[id] else { return .failure("There is no job \(id).") }
        let messages = job.messages
        job.messages = []
        guard var result = job.result else { return ControlReply(job: id, finished: false, messages: messages, progress: job.progress) }
        jobs[id] = nil
        result.job = id
        result.finished = true
        result.messages = messages + result.messages
        return result
    }

    // MARK: - Library

    private func status() throws -> ControlReply {
        let (songs, albums, artists, roots, counts) = try model.database.writer.read { db in
            (try Track.fetchCount(db), try LibraryDatabase.albums(db).count, try LibraryDatabase.artists(db).count,
             try LibraryDatabase.roots(db), try LibraryDatabase.trackCountsByRoot(db))
        }
        let importRoot = importRoot(in: roots)
        let folders = roots.map { root in
            FolderResult(path: root.path, songs: root.id.flatMap { counts[$0] } ?? 0, available: !model.unavailableFolders.contains(root.path),
                         importsHere: root.id == importRoot?.id)
        }
        let info = Bundle.main.infoDictionary
        let status = StatusResult(version: info?["CFBundleShortVersionString"] as? String ?? "?", build: info?["CFBundleVersion"] as? String ?? "?",
                                  songs: songs, albums: albums, artists: artists, folders: folders, nowPlaying: currentSong())
        var lines = ["Groovelight \(status.version): \(Self.count(songs, "song")), \(Self.count(albums, "album")), \(Self.count(artists, "artist"))"]
        lines += folders.map { "  \($0.path) (\(Self.count($0.songs, "song"))\($0.available ? "" : ", not available")\($0.importsHere ? ", imports go here" : ""))" }
        if let playing = status.nowPlaying { lines.append("\(playing.state.capitalized): \(playing.title) by \(playing.artist)") }
        return ControlReply(summary: lines.joined(separator: "\n"), data: try JSONValue(encoding: status))
    }

    private func search(_ query: String, limit: Int) throws -> ControlReply {
        let limit = min(max(limit, 1), 200)
        let results = try model.database.writer.read { try LibraryDatabase.search($0, query: query, limit: limit) }
        let found = SearchResult(artists: results.artists.prefix(limit).map(\.name), albums: results.albums.prefix(limit).map(AlbumResult.init),
                                 songs: results.songs.prefix(limit).map(SongResult.init))
        var lines: [String] = []
        if !found.artists.isEmpty { lines.append("Artists: " + found.artists.joined(separator: ", ")) }
        if !found.albums.isEmpty { lines.append("Albums:"); lines += found.albums.map { "  \($0.description)" } }
        if !found.songs.isEmpty { lines.append("Songs:"); lines += found.songs.map { "  \($0.description)" } }
        return ControlReply(summary: lines.isEmpty ? "Nothing found for “\(query)”." : lines.joined(separator: "\n"), data: try JSONValue(encoding: found))
    }

    // MARK: - Import

    private func importFiles(_ options: ImportOptions, job: Job) async throws -> ControlReply {
        try ImportPaths.check(options.paths)
        // The access the tool asked for arrives as the app is opened with the files: wait for it a moment.
        let wanted = Set(options.paths.map(Self.normalized))
        for _ in 0..<50 where !wanted.isSubset(of: granted) { try await Task.sleep(for: .milliseconds(100)) }
        let roots = try await model.database.writer.read { try LibraryDatabase.roots($0) }
        guard !roots.isEmpty else { throw ControlError("Add a library folder first (Settings, Library): imported songs go there.") }
        var root = importRoot(in: roots)
        if let folder = options.folder {
            root = try Self.pick(roots, named: folder, what: "library folder", key: { URL(fileURLWithPath: $0.path).lastPathComponent },
                                 alsoMatching: { $0.path == folder }, describe: \.path)
        }

        let session = ImportSession(urls: options.paths.map { URL(fileURLWithPath: $0) }, model: model, store: model.files)
        session.isInteractive = false
        session.deleteArchives = options.trashArchives
        session.moveFiles = !options.copy
        session.useOnlineMetadata = options.useOnlineMetadata
        session.writeTags = options.writeTags
        let watcher = Task {
            while !Task.isCancelled {
                Self.describe(session.phase).map { job.report($0.0, $0.1, $0.2) }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        defer { watcher.cancel() }
        await session.analyze()
        job.messages += session.problems
        session.rootId = root?.id

        let destinations = session.destinations()
        let albums = session.groups.map { group in
            ImportAlbumResult(album: group.title, artist: group.artist, matchedRelease: session.useOnlineMetadata ? group.matchedRelease : nil,
                              songs: group.items.map { item in
                                  ImportSongResult(source: session.sourceDescription(item.source), destination: destinations[item.id]?.path,
                                                   alreadyInLibrary: item.isDuplicate)
                              })
        }
        let folderPath = root?.path ?? ""
        func planLines() -> [String] {
            albums.flatMap { album in
                ["\(album.album) by \(album.artist)\(album.matchedRelease.map { " (matched \($0))" } ?? " (file tags)")"]
                    + album.songs.map { song in
                        "  " + (song.destination.map { String($0.dropFirst(folderPath.count + 1)) } ?? "already in your library: \(song.source)")
                    }
            }
        }
        guard session.includedCount > 0 else {
            let reason = session.groups.isEmpty ? "No songs found in \(options.paths.joined(separator: ", "))." : "Every song is already in your library."
            return ControlReply(summary: ([reason] + planLines()).joined(separator: "\n"),
                                data: try JSONValue(encoding: ImportResult(dryRun: options.dryRun, folder: folderPath, albums: albums)))
        }
        if options.dryRun {
            let summary = ["Would import \(session.includedCount) songs into \(folderPath):"] + planLines()
            return ControlReply(summary: summary.joined(separator: "\n"),
                                data: try JSONValue(encoding: ImportResult(dryRun: true, folder: folderPath, albums: albums)))
        }

        await session.run()
        guard case .finished(let imported, let skipped, let failed) = session.phase else { throw ControlError("The import stopped.") }
        var result = ImportResult(dryRun: false, folder: folderPath, albums: albums)
        result.imported = imported
        result.skipped = skipped
        result.failed = failed
        result.trashedArchives = session.trashedArchives
        var lines = ["Imported \(imported) songs into \(folderPath)."]
        if skipped > 0 { lines.append("\(skipped) left out (already in your library).") }
        if failed > 0 { lines.append("\(failed) could not be imported.") }
        if session.trashedArchives > 0 { lines.append(session.trashedArchives == 1 ? "The archive was moved to the Trash." : "\(session.trashedArchives) archives were moved to the Trash.") }
        lines.append("Undo with: groovelight undo")
        return ControlReply(summary: (lines + planLines()).joined(separator: "\n"), data: try JSONValue(encoding: result))
    }

    private static func describe(_ phase: ImportSession.Phase) -> (String, Int, Int)? {
        switch phase {
        case .extracting(let name, let done, let total): ("Extracting \(name)", done, total)
        case .reading(let done, let total): ("Reading files", done, total)
        case .identifying(let done, let total): ("Identifying albums on MusicBrainz", done, total)
        case .importing(let done, let total): ("Importing songs", done, total)
        case .review, .finished: nil
        }
    }

    private func importRoot(in roots: [LibraryRoot]) -> LibraryRoot? {
        let preferred = UserDefaults.standard.string(forKey: FilesStore.importRootKey)
        return roots.first { $0.path == preferred } ?? roots.first
    }

    // MARK: - Fix metadata

    private func fixMetadata(_ options: FixMetadataOptions, job: Job) async throws -> ControlReply {
        let tracks = try songs(album: options.album, artist: options.artist, ids: options.songIds)
        let service = model.metadata.service
        job.report("Searching MusicBrainz")
        let candidates = try await service.candidates(for: tracks, album: options.searchAlbum, artist: options.searchArtist)
        let candidateResults = candidates.prefix(10).map(ReleaseResult.init)
        let candidateLines = candidateResults.map { "  \($0.id)  \($0.description)" }
        let releaseId: String
        if let release = options.release {
            releaseId = release
        } else if let first = candidates.first, options.auto || options.dryRun {
            releaseId = first.id
        } else if candidates.isEmpty {
            throw ControlError("No release found on MusicBrainz for these songs. Search with other words: --search-album, --search-artist.")
        } else {
            return ControlReply(summary: (["Releases found on MusicBrainz:"] + candidateLines).joined(separator: "\n"),
                                data: try JSONValue(encoding: ["candidates": candidateResults]),
                                error: "Choose a release with --release ID, or pass --auto to take the best match (preview with --dry-run first).")
        }

        job.report("Matching the songs to the release")
        let match = try await service.match(tracks, releaseId: releaseId)
        let proposal = ReleaseMatcher.proposal(for: match, includingUnmatched: true)
        let accepted = options.includeUnmatched ? Set(proposal.keys) : Set(match.matches.map(\.localId))
        var changes: [Int64: TrackMetadata] = [:]
        var songChanges: [SongChangeResult] = []
        for track in tracks {
            guard let id = track.id, accepted.contains(id), let proposed = proposal[id] else { continue }
            let diff = proposed.changes(from: track.metadata)
            guard !diff.isEmpty else { continue }
            changes[id] = diff
            songChanges.append(SongChangeResult(id: id, title: track.title, path: track.path,
                                                changes: try Self.fieldChanges(from: track.metadata, to: diff)))
        }
        var cover: Data?
        if options.cover {
            job.report("Looking for the cover")
            cover = await service.cover(for: match.release, album: match.release.title, artist: match.release.artistName)?.1
        }
        var result = FixResult(dryRun: options.dryRun, release: ReleaseResult(match.release), matched: match.matches.count, songs: tracks.count,
                               changes: songChanges, cover: cover != nil, candidates: options.release == nil ? Array(candidateResults) : [])
        var lines = ["\(match.release.title) by \(match.release.artistName)\(match.release.year.map { " (\($0))" } ?? ""), release \(match.release.id)",
                     "\(match.matches.count) of \(tracks.count) songs matched"]
        for song in songChanges {
            lines.append("  \(song.title)")
            lines += song.changes.map { "    \($0.field): \($0.from ?? "empty") -> \($0.to)" }
        }
        if cover != nil { lines.append("  New cover from \(match.release.title)") }
        if changes.isEmpty, cover == nil { lines.append("Nothing to change.") }
        if options.dryRun {
            if options.release == nil, candidateLines.count > 1 { lines += ["Other releases (choose one by its id):"] + candidateLines.dropFirst() }
            return ControlReply(summary: lines.joined(separator: "\n"), data: try JSONValue(encoding: result))
        }
        guard !changes.isEmpty || cover != nil else { return ControlReply(summary: lines.joined(separator: "\n"), data: try JSONValue(encoding: result)) }

        let writeToFiles = options.writeTags ?? UserDefaults.standard.bool(forKey: MetadataStore.Keys.writeTags)
        let applied = await model.metadata.apply(changes, cover: cover, coverTrackIds: tracks.compactMap(\.id), writeToFiles: writeToFiles) { done, total in
            job.report("Saving songs", done, total)
        }
        result.updated = applied.updated
        result.failedWrites = applied.failedWrites
        lines.insert("Fixed \(changes.count) songs\(writeToFiles ? " (tags written into the files)" : " (in the library; files unchanged)").", at: 0)
        if !applied.failedWrites.isEmpty {
            lines.append("Could not write the tags of \(applied.failedWrites.count) files (the fix is kept in the library): \(applied.failedWrites.prefix(5).joined(separator: ", "))")
        }
        return ControlReply(summary: lines.joined(separator: "\n"), data: try JSONValue(encoding: result))
    }

    /// Each changed field, as text: from (nil when empty) and to.
    private static func fieldChanges(from current: TrackMetadata, to diff: TrackMetadata) throws -> [FieldChangeResult] {
        guard case .object(let new) = try JSONValue(encoding: diff), case .object(let old) = try JSONValue(encoding: current) else { return [] }
        return new.keys.sorted().map { key in
            FieldChangeResult(field: key, from: old[key].flatMap(Self.text), to: new[key].flatMap(Self.text) ?? "")
        }
    }

    private static func text(_ value: JSONValue) -> String? {
        switch value {
        case .null: nil
        case .bool(let value): value ? "yes" : "no"
        case .number(let value): value.rounded() == value ? String(Int64(value)) : String(value)
        case .string(let value): value
        default: value.prettyPrinted
        }
    }

    // MARK: - Files

    private func organize(_ options: OrganizeFilesOptions, job: Job) async throws -> ControlReply {
        let tracks = options.album != nil || options.artist != nil ? try songs(album: options.album, artist: options.artist, ids: nil) : nil
        job.report("Planning new names")
        let plan = await model.files.plan(for: tracks)
        let moving = plan.filter { $0.status != .unchanged }
        let renames = moving.map { RenameResult(from: $0.source.path, to: $0.destination.path, numbered: $0.status == .renamedForConflict) }
        var lines = moving.isEmpty ? ["Every file already has its name (\(plan.count) checked)."]
            : ["\(options.dryRun ? "Would rename" : "Renamed") \(moving.count) of \(plan.count) files:"]
        lines += renames.prefix(200).map { "  \($0.from) -> \($0.to)" }
        if renames.count > 200 { lines.append("  and \(renames.count - 200) more") }
        let data = try JSONValue(encoding: ["dryRun": JSONValue.bool(options.dryRun), "checked": .number(Double(plan.count)),
                                            "renames": try JSONValue(encoding: renames)])
        guard !options.dryRun, !moving.isEmpty else { return ControlReply(summary: lines.joined(separator: "\n"), data: data) }
        let before = model.files.undoable?.id
        job.report("Renaming files", 0, moving.count)
        await model.files.apply(plan)
        guard model.files.undoable?.id != before else { throw ControlError(model.errorMessage ?? "Could not rename the files (nothing was changed).") }
        lines.append("Undo with: groovelight undo")
        return ControlReply(summary: lines.joined(separator: "\n"), data: data)
    }

    private func undo() async throws -> ControlReply {
        guard model.files.undoable != nil else { throw ControlError("There is no import or organize to undo.") }
        let title = model.files.undoTitle
        await model.files.undoLast()
        return ControlReply(summary: "Done: \(title).", data: .object(["undone": .string(title)]))
    }

    private func rescan(job: Job) async throws -> ControlReply {
        job.report("Checking every file of the library")
        await model.rescanAndWait()
        guard let summary = model.lastScanSummary else { return ControlReply(summary: "Checked the library.") }
        let data = JSONValue.object(["added": .number(Double(summary.added)), "updated": .number(Double(summary.updated)),
                                     "removed": .number(Double(summary.removed)), "unreadable": .array(summary.failed.map(JSONValue.string))])
        return ControlReply(summary: "Checked the library: \(summary.added) added, \(summary.updated) updated, \(summary.removed) removed, \(summary.failed.count) unreadable.",
                            data: data)
    }

    // MARK: - Playback

    private func play(_ options: PlayOptions) throws -> ControlReply {
        let database = model.database
        let what: String
        if let ids = options.songIds, !ids.isEmpty {
            let songs = try songs(withIds: ids)
            model.play(songs, shuffle: options.shuffle)
            what = songs.count == 1 ? "\(songs[0].title) by \(songs[0].artist ?? "Unknown Artist")" : "\(songs.count) songs, from \(songs[0].title)"
            return ControlReply(summary: "Playing \(what)\(options.shuffle ? ", shuffled" : "").", data: try? JSONValue(encoding: ["playing": what]))
        }
        // A song (or a search) comes first: an artist or album given with it only narrows it down ("Living Inside
        // Myself" by Gino Vannelli is that song, not every song of his).
        if let query = options.song ?? options.query {
            var songs = try database.writer.read { try LibraryDatabase.search($0, query: query, limit: 300).songs }
            if let artist = options.artist {
                songs = songs.filter { Self.matches($0.artist ?? "", artist, exact: false) || Self.matches($0.albumArtist ?? "", artist, exact: false) }
            }
            if let album = options.album { songs = songs.filter { Self.matches($0.album ?? "", album, exact: false) } }
            if let title = options.song {
                // The song with that title before songs that only mention it ("Living Inside Myself (Live)" after).
                let exact = songs.filter { Self.matches($0.title, title, exact: true) }
                if !exact.isEmpty { songs = exact }
            }
            let narrowed = [options.artist.map { "by \($0)" }, options.album.map { "on \($0)" }].compactMap { $0 }.joined(separator: " ")
            guard !songs.isEmpty else { throw ControlError("No songs found for “\(query)”\(narrowed.isEmpty ? "" : " " + narrowed).") }
            let chosen = options.song != nil ? [songs[0]] : songs
            model.play(chosen, shuffle: options.shuffle)
            what = chosen.count == 1 ? "\(chosen[0].title) by \(chosen[0].artist ?? "Unknown Artist")\(chosen[0].album.map { ", \($0)" } ?? "")"
                : "\(chosen.count) songs matching “\(query)”"
        } else if let name = options.album {
            let album = try Self.pickAlbum(try database.writer.read { try LibraryDatabase.albums($0) }, named: name, artist: options.artist)
            model.playAlbum(album, shuffle: options.shuffle)
            what = "\(album.title) by \(album.artist)"
        } else if let name = options.artist {
            let artist = try Self.pick(try database.writer.read { try LibraryDatabase.artists($0) }, named: name, what: "artist", key: \.name, describe: \.name)
            let tracks = try database.writer.read { try LibraryDatabase.tracks($0, artist: artist.name) }
            model.play(tracks, shuffle: options.shuffle)
            what = artist.name
        } else if let name = options.playlist {
            let playlist = try Self.pick(try database.writer.read { try LibraryDatabase.playlists($0) }, named: name, what: "playlist", key: \.name, describe: \.name)
            guard let id = playlist.id else { throw ControlError("That playlist cannot be played.") }
            model.playPlaylist(id, shuffle: options.shuffle)
            what = "the playlist \(playlist.name)"
        } else {
            model.player.resume()
            return nowPlaying()
        }
        return ControlReply(summary: "Playing \(what)\(options.shuffle ? ", shuffled" : "").", data: try? JSONValue(encoding: ["playing": what]))
    }

    // MARK: - Playlists

    private func listPlaylists() throws -> ControlReply {
        let found = try model.database.writer.read { db in
            try LibraryDatabase.playlists(db).map { playlist in
                PlaylistResult(id: playlist.id ?? 0, name: playlist.name, smart: playlist.isSmart,
                               songs: try playlist.id.map { try LibraryDatabase.tracks(db, playlistId: $0).count } ?? 0)
            }
        }
        let lines = found.map { "  \($0.name) (\(Self.count($0.songs, "song"))\($0.smart ? ", smart" : ""))" }
        return ControlReply(summary: found.isEmpty ? "No playlists yet." : (["Playlists:"] + lines).joined(separator: "\n"),
                            data: try JSONValue(encoding: ["playlists": found]))
    }

    private func createPlaylist(named name: String, songIds: [Int64]) throws -> ControlReply {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ControlError("Give the playlist a name.") }
        let existing = try model.database.writer.read { try LibraryDatabase.playlists($0) }
        if let same = existing.first(where: { Self.matches($0.name, name, exact: true) }) {
            throw ControlError("There is already a playlist called “\(same.name)”: add songs to it, or choose another name.")
        }
        let songs = try songs(withIds: songIds)
        var cover = PlaylistCover.randomGenerated()
        cover.showsTitle = true
        let playlist = try model.database.createPlaylist(named: name, trackIds: songs.compactMap(\.id), cover: cover)
        let lines = songs.enumerated().map { "  \($0.offset + 1). \($0.element.title) by \($0.element.artist ?? "Unknown Artist")" }
        return ControlReply(summary: (["Created the playlist “\(name)” with \(Self.count(songs.count, "song")):"] + lines).joined(separator: "\n"),
                            data: try JSONValue(encoding: PlaylistResult(id: playlist.id ?? 0, name: name, smart: false, songs: songs.count)))
    }

    private func addToPlaylist(_ name: String, songIds: [Int64]) throws -> ControlReply {
        let playlist = try Self.pick(try model.database.writer.read { try LibraryDatabase.playlists($0) }, named: name, what: "playlist",
                                     key: \.name, describe: \.name)
        guard let id = playlist.id, !playlist.isSmart else {
            throw ControlError("“\(playlist.name)” is a smart playlist: its songs come from its rules, so songs cannot be added to it.")
        }
        let songs = try songs(withIds: songIds)
        try model.database.addTracks(songs.compactMap(\.id), toPlaylist: id)
        let total = try model.database.writer.read { try LibraryDatabase.tracks($0, playlistId: id).count }
        return ControlReply(summary: "Added \(Self.count(songs.count, "song")) to “\(playlist.name)” (now \(Self.count(total, "song"))).",
                            data: try JSONValue(encoding: PlaylistResult(id: id, name: playlist.name, smart: false, songs: total)))
    }

    /// Songs by id, in the order given; every id must be a song.
    private func songs(withIds ids: [Int64]) throws -> [Track] {
        guard !ids.isEmpty else { throw ControlError("Give the songs' ids (search finds them).") }
        let byId = Dictionary(uniqueKeysWithValues: try model.database.writer.read { try Track.fetchAll($0, keys: ids) }.compactMap { track in
            track.id.map { ($0, track) }
        })
        let missing = ids.filter { byId[$0] == nil }
        guard missing.isEmpty else { throw ControlError("No songs with the ids \(missing.map(String.init).joined(separator: ", ")) (search finds them).") }
        return ids.compactMap { byId[$0] }
    }

    private func playback(_ action: PlaybackAction) -> ControlReply {
        let player = model.player
        switch action {
        case .pause: player.pause()
        case .resume: player.resume()
        case .toggle: player.togglePlayPause()
        case .next: player.next()
        case .previous: player.previous()
        case .stop: player.stop()
        }
        return nowPlaying()
    }

    private func nowPlaying() -> ControlReply {
        guard let song = currentSong() else { return ControlReply(summary: "Nothing is playing.", data: .null) }
        let summary = "\(song.state.capitalized): \(song.title) by \(song.artist), \(song.album) (\(Self.time(song.position)) of \(Self.time(song.duration)))"
        return ControlReply(summary: summary, data: try? JSONValue(encoding: song))
    }

    private func currentSong() -> NowPlayingResult? {
        let player = model.player
        guard let item = player.current else { return nil }
        let state = switch player.state {
        case .playing: "playing"
        case .paused: "paused"
        case .stopped: "stopped"
        }
        return NowPlayingResult(id: item.id, title: item.title, artist: item.artist, album: item.album, state: state,
                                position: player.currentTime, duration: item.duration)
    }

    private static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    private static func time(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Finding things by name

    /// Songs by id, or an album's songs by its title (and artist, to tell albums apart).
    private func songs(album: String?, artist: String?, ids: [Int64]?) throws -> [Track] {
        let database = model.database
        if let ids, !ids.isEmpty {
            let tracks = try database.writer.read { try Track.fetchAll($0, keys: ids) }
            guard !tracks.isEmpty else { throw ControlError("No songs with the ids \(ids.map(String.init).joined(separator: ", ")).") }
            return tracks
        }
        if let album {
            let found = try Self.pickAlbum(try database.writer.read { try LibraryDatabase.albums($0) }, named: album, artist: artist)
            return try database.writer.read { try LibraryDatabase.tracks($0, albumKey: found.albumKey) }
        }
        if let artist {
            let found = try Self.pick(try database.writer.read { try LibraryDatabase.artists($0) }, named: artist, what: "artist", key: \.name, describe: \.name)
            return try database.writer.read { try LibraryDatabase.tracks($0, artist: found.name) }
        }
        throw ControlError("Say which songs: --album (with --artist when several albums share the title), or --songs with their ids (from groovelight search).")
    }

    private static func pickAlbum(_ albums: [AlbumSummary], named name: String, artist: String?) throws -> AlbumSummary {
        var albums = albums
        if let artist {
            let byArtist = albums.filter { matches($0.artist, artist, exact: true) }
            albums = byArtist.isEmpty ? albums.filter { matches($0.artist, artist, exact: false) } : byArtist
        }
        return try pick(albums, named: name, what: "album", key: \.title, describe: { "\($0.title) by \($0.artist)\($0.year.map { " (\($0))" } ?? "")" })
    }

    /// The one item called `name` (ignoring case and accents), or the one whose name contains it.
    private static func pick<T>(_ items: [T], named name: String, what: String, key: (T) -> String, alsoMatching: (T) -> Bool = { _ in false },
                                describe: (T) -> String) throws -> T {
        for exact in [true, false] {
            let found = items.filter { matches(key($0), name, exact: exact) || alsoMatching($0) }
            if found.count == 1 { return found[0] }
            if found.count > 1 {
                throw ControlError("Several \(what)s match “\(name)”: \(found.prefix(10).map(describe).joined(separator: "; ")). Be more specific.")
            }
        }
        throw ControlError("No \(what) matches “\(name)”.")
    }

    private static func matches(_ value: String, _ name: String, exact: Bool) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return exact ? value.compare(name, options: options) == .orderedSame : value.range(of: name, options: options) != nil
    }
}

struct ControlError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: - Results (the `data` of replies)

struct StatusResult: Encodable {
    var version: String
    var build: String
    var songs: Int
    var albums: Int
    var artists: Int
    var folders: [FolderResult]
    var nowPlaying: NowPlayingResult?
}

struct FolderResult: Encodable {
    var path: String
    var songs: Int
    var available: Bool
    var importsHere: Bool
}

struct NowPlayingResult: Encodable {
    var id: Int64
    var title: String
    var artist: String
    var album: String
    var state: String
    var position: Double
    var duration: Double
}

struct SearchResult: Encodable {
    var artists: [String]
    var albums: [AlbumResult]
    var songs: [SongResult]
}

struct AlbumResult: Encodable {
    var title: String
    var artist: String
    var year: Int?
    var songs: Int

    init(_ album: AlbumSummary) {
        title = album.title
        artist = album.artist
        year = album.year
        songs = album.trackCount
    }

    var description: String { "\(title) by \(artist)\(year.map { " (\($0))" } ?? ""), \(songs) songs" }
}

struct SongResult: Encodable {
    var id: Int64
    var title: String
    var artist: String?
    var album: String?
    var albumArtist: String?
    var year: Int?
    var trackNumber: Int?
    var discNumber: Int?
    var genre: String?
    var duration: Double
    var path: String
    var loved: Bool
    var plays: Int

    init(_ track: Track) {
        id = track.id ?? 0
        title = track.title
        artist = track.artist
        album = track.album
        albumArtist = track.albumArtist
        year = track.year
        trackNumber = track.trackNumber
        discNumber = track.discNumber
        genre = track.genre
        duration = track.duration
        path = track.path
        loved = track.isLoved
        plays = track.playCount
    }

    var description: String { "[\(id)] \(title) by \(artist ?? "Unknown Artist")\(album.map { ", \($0)" } ?? "")" }
}

struct ImportResult: Encodable {
    var dryRun: Bool
    var folder: String
    var albums: [ImportAlbumResult]
    var imported: Int?
    var skipped: Int?
    var failed: Int?
    var trashedArchives: Int?
}

struct ImportAlbumResult: Encodable {
    var album: String
    var artist: String
    var matchedRelease: String?
    var songs: [ImportSongResult]
}

struct ImportSongResult: Encodable {
    var source: String
    var destination: String?
    var alreadyInLibrary: Bool
}

struct ReleaseResult: Encodable {
    var id: String
    var title: String
    var artist: String
    var year: Int?
    var country: String?
    var tracks: Int
    var format: String?

    init(_ release: MBRelease) {
        id = release.id
        title = release.title
        artist = release.artistName
        year = release.year
        country = release.country
        tracks = release.totalTracks
        format = release.media?.first?.format
    }

    var description: String {
        "\(title) by \(artist)" + ([year.map(String.init), country, "\(tracks) tracks", format].compactMap { $0 }.map { ", \($0)" }.joined())
    }
}

struct FixResult: Encodable {
    var dryRun: Bool
    var release: ReleaseResult
    var matched: Int
    var songs: Int
    var changes: [SongChangeResult]
    var cover: Bool
    var candidates: [ReleaseResult]
    var updated: Int?
    var failedWrites: [String]?
}

struct SongChangeResult: Encodable {
    var id: Int64
    var title: String
    var path: String
    var changes: [FieldChangeResult]
}

struct FieldChangeResult: Encodable {
    var field: String
    var from: String?
    var to: String
}

struct PlaylistResult: Encodable {
    var id: Int64
    var name: String
    var smart: Bool
    var songs: Int
}

struct RenameResult: Encodable {
    var from: String
    var to: String
    var numbered: Bool
}
