import Foundation
import GRDB

// MARK: - Options

/// How files are named and placed in the library folder (shared by Organize and Import).
public struct OrganizeOptions: Codable, Hashable, Sendable {
    /// Path template relative to the library folder, without the extension. Tokens: {albumartist} {artist} {album}
    /// {title} {year} {genre} {track} {disc} (numbers accept a width, e.g. {track:02}); text in [ ] only appears when
    /// every token in it has a value; "/" separates folders. {disc} is empty for single-disc albums.
    public var template: String
    /// Off: only the file name part of the template is used, files stay in their folder.
    public var organizeFolders: Bool
    /// Also replace characters Windows and many NAS shares reject (\ ? * " < > |).
    public var portableNames: Bool
    /// "ft." / "featuring" / "Feat" become "feat.".
    public var normalizeFeaturing: Bool
    public var titleCase: Bool

    public static let defaultTemplate = "{albumartist}/{album}[ ({year})]/[{disc}-]{track:02} {title}"

    public static let presets: [(name: String, template: String)] = [
        ("Artist / Album (Year) / 01 Title", defaultTemplate),
        ("Artist / Year - Album / 01 Title", "{albumartist}/[{year} - ]{album}/[{disc}-]{track:02} {title}"),
        ("Artist / Album / 01 - Artist - Title", "{albumartist}/{album}/[{disc}-]{track:02} - {artist} - {title}"),
        ("Artist - Album / 01 Title", "{albumartist} - {album}/[{disc}-]{track:02} {title}"),
        ("Genre / Artist / Album / 01 Title", "{genre}/{albumartist}/{album}/[{disc}-]{track:02} {title}"),
    ]

    public init(template: String = OrganizeOptions.defaultTemplate, organizeFolders: Bool = true, portableNames: Bool = true,
                normalizeFeaturing: Bool = true, titleCase: Bool = false) {
        self.template = template
        self.organizeFolders = organizeFolders
        self.portableNames = portableNames
        self.normalizeFeaturing = normalizeFeaturing
        self.titleCase = titleCase
    }
}

/// The tag values a file name is built from.
public struct NamingFields: Hashable, Sendable {
    public var title: String
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var year: Int?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var discTotal: Int?
    public var isCompilation: Bool

    public init(title: String, artist: String? = nil, album: String? = nil, albumArtist: String? = nil, genre: String? = nil,
                year: Int? = nil, trackNumber: Int? = nil, discNumber: Int? = nil, discTotal: Int? = nil, isCompilation: Bool = false) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.isCompilation = isCompilation
    }

    public init(_ track: Track) {
        self.init(title: track.title, artist: track.artist, album: track.album, albumArtist: track.albumArtist, genre: track.genre,
                  year: track.year, trackNumber: track.trackNumber, discNumber: track.discNumber, discTotal: track.discTotal,
                  isCompilation: track.isCompilation)
    }
}

// MARK: - Templates and sanitizing

public enum FileNaming {
    /// Relative path (folders and file name, with the extension) for a song.
    public static func relativePath(for fields: NamingFields, fileExtension: String, options: OrganizeOptions) -> String {
        let rendered = render(options.template, fields: fields, options: options)
        var components = rendered.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if !options.organizeFolders { components = components.suffix(1).map { $0 } }
        if components.isEmpty { components = [sanitize(fields.title, options: options)] }
        let ext = fileExtension.lowercased()
        components[components.count - 1] = limitLength(components[components.count - 1], reserving: ext.isEmpty ? 0 : ext.utf8.count + 1)
        components = components.map { limitLength($0, reserving: 0) }
        return components.joined(separator: "/") + (ext.isEmpty ? "" : ".\(ext)")
    }

    /// Renders the template; each token's value is sanitized so it cannot add folders or illegal characters.
    static func render(_ template: String, fields: NamingFields, options: OrganizeOptions) -> String {
        var output = ""
        var index = template.startIndex
        while index < template.endIndex {
            let character = template[index]
            if character == "[", let close = template[index...].firstIndex(of: "]") {
                let group = String(template[template.index(after: index)..<close])
                let (text, complete) = renderTokens(group, fields: fields, options: options)
                if complete { output += text }
                index = template.index(after: close)
            } else {
                let end = template[index...].firstIndex(of: "[") ?? template.endIndex
                output += renderTokens(String(template[index..<end]), fields: fields, options: options).text
                index = end
            }
        }
        // Folder parts are cleaned too (literal text from the template).
        return output.split(separator: "/", omittingEmptySubsequences: true)
            .map { cleanComponent(String($0), options: options) }
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }

    /// Replaces {tokens}; `complete` is false when a token had no value.
    private static func renderTokens(_ text: String, fields: NamingFields, options: OrganizeOptions) -> (text: String, complete: Bool) {
        var output = ""
        var complete = true
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            output += rest[rest.startIndex..<open]
            let spec = rest[rest.index(after: open)..<close].split(separator: ":", maxSplits: 1).map(String.init)
            let value = tokenValue(spec[0].lowercased(), width: spec.count > 1 ? Int(spec[1]) : nil, fields: fields, options: options)
            if value.isEmpty { complete = false }
            output += value
            rest = rest[rest.index(after: close)...]
        }
        output += rest
        return (output, complete)
    }

    private static func tokenValue(_ token: String, width: Int?, fields: NamingFields, options: OrganizeOptions) -> String {
        func text(_ value: String?) -> String { value.map { sanitize($0, options: options) } ?? "" }
        func number(_ value: Int?) -> String {
            guard let value, value > 0 else { return "" }
            return String(format: "%0\(max(width ?? 1, 1))d", value)
        }
        func nonEmpty(_ value: String?) -> String? {
            guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return value
        }
        switch token {
        case "title": return text(fields.title)
        case "artist": return text(nonEmpty(fields.artist) ?? nonEmpty(fields.albumArtist) ?? "Unknown Artist")
        case "albumartist":
            return text(fields.isCompilation ? "Various Artists" : (nonEmpty(fields.albumArtist) ?? nonEmpty(fields.artist) ?? "Unknown Artist"))
        case "album": return text(nonEmpty(fields.album) ?? "Unknown Album")
        case "genre": return text(nonEmpty(fields.genre) ?? "Unknown Genre")
        case "year": return number(fields.year)
        case "track": return number(fields.trackNumber)
        case "disc":
            // Only multi-disc albums get a disc number.
            let isMultiDisc = (fields.discTotal ?? 0) > 1 || (fields.discNumber ?? 0) > 1
            return isMultiDisc ? number(fields.discNumber) : ""
        default: return ""
        }
    }

    /// Compiled once: names are built for every song of a library or a device.
    private static let featuringPattern = try! NSRegularExpression(pattern: #"(?i)\s+(feat\.?|ft\.?|featuring)\s+"#)
    private static let spacesPattern = try! NSRegularExpression(pattern: #"\s+"#)

    /// Makes a tag value safe as part of a file name.
    public static func sanitize(_ value: String, options: OrganizeOptions) -> String {
        var text = value.precomposedStringWithCanonicalMapping
        if options.normalizeFeaturing, text.range(of: "f", options: .caseInsensitive) != nil {
            text = featuringPattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " feat. ")
        }
        if options.titleCase { text = titleCased(text) }
        // ":" is shown as "/" by the Finder and "/" separates folders.
        text = text.replacingOccurrences(of: ": ", with: " - ").replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
        if options.portableNames {
            for character in ["\\", "?", "*", "\"", "<", ">", "|"] { text = text.replacingOccurrences(of: character, with: "_") }
        }
        text = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(Character.init))
        return text
    }

    /// Trims and collapses spaces, and removes leading dots (hidden files) and trailing dots (rejected on some systems).
    static func cleanComponent(_ component: String, options: OrganizeOptions) -> String {
        var text = component.contains(where: { $0.isWhitespace && $0 != " " }) || component.contains("  ")
            ? spacesPattern.stringByReplacingMatches(in: component, range: NSRange(component.startIndex..., in: component), withTemplate: " ")
            : component
        text = text.trimmingCharacters(in: .whitespaces)
        while text.hasPrefix(".") { text.removeFirst() }
        while text.hasSuffix(".") || text.hasSuffix(" ") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Keeps a component within 255 UTF-8 bytes (the macOS limit), leaving room for the extension.
    static func limitLength(_ component: String, reserving: Int, limit: Int = 255) -> String {
        guard component.utf8.count + reserving > limit else { return component }
        var result = ""
        for character in component {
            if (result + String(character)).utf8.count + reserving > limit { break }
            result.append(character)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static let minorWords: Set<String> = ["a", "an", "the", "and", "but", "or", "nor", "for", "so", "yet", "of", "in", "on", "at",
                                                  "to", "by", "from", "with", "as", "vs", "vs.", "feat."]

    static func titleCased(_ text: String) -> String {
        let words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        return words.enumerated().map { index, word in
            let lower = word.lowercased()
            if index > 0, index < words.count - 1, minorWords.contains(lower) { return lower }
            // Keep words already in caps (acronyms like "USA", "OK").
            if word.count > 1, word == word.uppercased(), word.contains(where: \.isLetter) { return word }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }
}

// MARK: - Planning

public struct RenamePlanItem: Hashable, Sendable, Identifiable {
    public enum Status: Hashable, Sendable {
        case unchanged
        case move
        /// Renamed with " (2)" etc. because the name was taken.
        case renamedForConflict
    }

    public var trackId: Int64?
    public var source: URL
    public var destination: URL
    public var status: Status
    public var id: String { source.path }
}

public enum RenamePlanner {
    /// Where each track should go under `root`. Collisions with existing files (not being moved away) or with other
    /// planned files get " (2)", " (3)"...
    public static func plan(tracks: [Track], root: URL, options: OrganizeOptions) -> [RenamePlanItem] {
        let cueItems = planCueAlbums(tracks.filter(\.isCueTrack), root: root, options: options)
        // First pass: the ideal destination of every file.
        let ideal: [(track: Track, source: URL, base: URL, relative: String)] = tracks.filter { !$0.isCueTrack }.sorted(by: { $0.path < $1.path }).map { track in
            let source = track.url.standardizedFileURL
            // Without folder organizing, files stay in their folder and only the name changes.
            let base = options.organizeFolders ? root : source.deletingLastPathComponent()
            let relative = FileNaming.relativePath(for: NamingFields(track), fileExtension: source.pathExtension, options: options)
            return (track, source, base, relative)
        }
        // Files already at their destination keep it; the others may take the names of files that move away.
        let staying = Set(ideal.filter { $0.base.appendingPathComponent($0.relative).standardizedFileURL.path == $0.source.path }.map(\.source.path))
        let movingAway = Set(ideal.map(\.source.path)).subtracting(staying)
        var taken = Set(staying.map { $0.lowercased() }).union(cueItems.map { $0.destination.path.lowercased() })

        return cueItems + ideal.map { entry in
            var destination = entry.base.appendingPathComponent(entry.relative).standardizedFileURL
            if staying.contains(entry.source.path) {
                return RenamePlanItem(trackId: entry.track.id, source: entry.source, destination: destination, status: .unchanged)
            }
            var status: RenamePlanItem.Status = .move
            var counter = 2
            // Taken by another planned file, or by a file on disk that is not moving away (case-insensitive file system).
            while taken.contains(destination.path.lowercased())
                    || (FileManager.default.fileExists(atPath: destination.path) && !movingAway.contains(destination.path)) {
                destination = numbered(entry.base.appendingPathComponent(entry.relative), counter)
                counter += 1
                status = .renamedForConflict
            }
            taken.insert(destination.path.lowercased())
            return RenamePlanItem(trackId: entry.track.id, source: entry.source, destination: destination, status: status)
        }
    }

    /// Albums stored as one audio file with a cue sheet move as a unit: the audio file and its sheet go into the
    /// template's album folder and keep their names, so the sheet's FILE line still finds the audio. Songs are not
    /// renamed (they are not files). Without folder organizing, or when the names are taken there, they stay put.
    static func planCueAlbums(_ tracks: [Track], root: URL, options: OrganizeOptions) -> [RenamePlanItem] {
        var items: [RenamePlanItem] = []
        for (audioPath, songs) in Dictionary(grouping: tracks, by: \.url.standardizedFileURL.path).sorted(by: { $0.key < $1.key }) {
            let audio = URL(fileURLWithPath: audioPath)
            let first = songs.min { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }!
            var files = [audio]
            if let sheet = first.cueSheetURL?.standardizedFileURL, sheet != audio { files.append(sheet) }
            let relative = FileNaming.relativePath(for: NamingFields(first), fileExtension: audio.pathExtension, options: options)
            let folder = root.appendingPathComponent(relative).deletingLastPathComponent().standardizedFileURL
            let destinations = files.map { folder.appendingPathComponent($0.lastPathComponent).standardizedFileURL }
            let moves = options.organizeFolders && folder != audio.deletingLastPathComponent().standardizedFileURL
                && !destinations.contains { FileManager.default.fileExists(atPath: $0.path) }
            for (file, destination) in zip(files, destinations) {
                items.append(RenamePlanItem(trackId: nil, source: file, destination: moves ? destination : file, status: moves ? .move : .unchanged))
            }
        }
        return items
    }

    /// "/a/01 Title.flac" with 2 becomes "/a/01 Title (2).flac".
    static func numbered(_ url: URL, _ counter: Int) -> URL {
        let ext = url.pathExtension
        let name = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(name) (\(counter))").appendingPathExtension(ext).standardizedFileURL
    }
}

// MARK: - Applying and undoing

/// Record of a rename or import, for undo. Saved as JSON.
public struct FileOperationJournal: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case organize, `import`
    }

    public struct Entry: Codable, Hashable, Sendable {
        public var trackId: Int64?
        public var from: String
        public var to: String
        /// Imports that copied the file: undo deletes the copy instead of moving it back.
        public var copied: Bool

        public init(trackId: Int64?, from: String, to: String, copied: Bool) {
            self.trackId = trackId
            self.from = from
            self.to = to
            self.copied = copied
        }
    }

    public var id: UUID
    public var kind: Kind
    public var date: Date
    public var entries: [Entry]
    /// Folders the operation created (removed on undo when empty).
    public var createdFolders: [String]

    public init(id: UUID, kind: Kind, date: Date, entries: [Entry], createdFolders: [String]) {
        self.id = id
        self.kind = kind
        self.date = date
        self.entries = entries
        self.createdFolders = createdFolders
    }
}

public enum FileOrganizer {
    /// Extensions of files that travel with an album folder.
    static let companionExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "gif", "lrc", "cue", "log", "txt", "pdf", "nfo", "m3u", "m3u8"]

    /// Moves the files of a plan (through temporary names, so swaps and cycles are safe), updates the library paths,
    /// brings album images and other companion files along when a whole folder moves, and removes emptied folders.
    /// Stops and rolls back on the first failure.
    public static func apply(_ plan: [RenamePlanItem], database: LibraryDatabase) throws -> FileOperationJournal {
        let fileManager = FileManager.default
        let moves = plan.filter { $0.status != .unchanged }
        var entries: [FileOperationJournal.Entry] = []
        var created: [String] = []

        func createFolders(for url: URL) throws {
            var missing: [URL] = []
            var folder = url.deletingLastPathComponent()
            while !fileManager.fileExists(atPath: folder.path) {
                missing.append(folder)
                folder = folder.deletingLastPathComponent()
            }
            for folder in missing.reversed() {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
                created.append(folder.path)
            }
        }

        // Companion files: a source folder whose audio files all move to one destination folder.
        let audioExtensions = TagReader.supportedExtensions
        let movingSources = Set(moves.map(\.source.path))
        var companions: [(from: URL, to: URL)] = []
        for (folder, items) in Dictionary(grouping: moves, by: { $0.source.deletingLastPathComponent().path }) {
            let destinations = Set(items.map { $0.destination.deletingLastPathComponent().path })
            guard destinations.count == 1, let target = destinations.first, target != folder,
                  let contents = try? fileManager.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
            else { continue }
            let movingNames = Set(items.map { $0.source.lastPathComponent })
            let audioLeft = contents.filter { audioExtensions.contains($0.pathExtension.lowercased()) && !movingNames.contains($0.lastPathComponent) }
            guard audioLeft.isEmpty else { continue }
            for file in contents where companionExtensions.contains(file.pathExtension.lowercased()) && !movingSources.contains(file.standardizedFileURL.path) {
                let destination = URL(fileURLWithPath: target).appendingPathComponent(file.lastPathComponent)
                if !fileManager.fileExists(atPath: destination.path) { companions.append((file, destination)) }
            }
        }

        var temporaries: [(item: RenamePlanItem, temporary: URL)] = []
        do {
            // Phase 1: every moving file to a temporary name next to it.
            for item in moves {
                let temporary = item.source.deletingLastPathComponent()
                    .appendingPathComponent(".groovelight-\(UUID().uuidString).\(item.source.pathExtension)")
                try fileManager.moveItem(at: item.source, to: temporary)
                temporaries.append((item, temporary))
            }
            // Phase 2: temporary names to destinations.
            for (index, pair) in temporaries.enumerated() {
                try createFolders(for: pair.item.destination)
                try fileManager.moveItem(at: pair.temporary, to: pair.item.destination)
                temporaries[index].temporary = pair.item.destination
                entries.append(.init(trackId: pair.item.trackId, from: pair.item.source.path, to: pair.item.destination.path, copied: false))
            }
            for companion in companions {
                try createFolders(for: companion.to)
                try fileManager.moveItem(at: companion.from, to: companion.to)
                entries.append(.init(trackId: nil, from: companion.from.path, to: companion.to.path, copied: false))
            }
        } catch {
            // Put everything back where it was.
            for pair in temporaries.reversed() where fileManager.fileExists(atPath: pair.temporary.path) {
                try? fileManager.moveItem(at: pair.temporary, to: pair.item.source)
            }
            for entry in entries where entry.trackId == nil { try? fileManager.moveItem(atPath: entry.to, toPath: entry.from) }
            for folder in created.reversed() { try? fileManager.removeItem(atPath: folder) }
            throw error
        }

        try database.updatePaths(entries.compactMap { entry in entry.trackId.map { ($0, entry.to) } })
        try database.relocateCueFiles(entries.filter { $0.trackId == nil }.map { ($0.from, $0.to) })
        removeEmptyFolders(Set(moves.map { $0.source.deletingLastPathComponent().path }))
        return FileOperationJournal(id: UUID(), kind: .organize, date: .now, entries: entries, createdFolders: created)
    }

    /// Reverses an organize or import: files go back (copies are deleted), library paths follow, created folders that
    /// end up empty are removed.
    public static func undo(_ journal: FileOperationJournal, database: LibraryDatabase) throws {
        let fileManager = FileManager.default
        var restored: [(Int64, String)] = []
        var removedTracks: [Int64] = []
        var restoredFiles: [(from: String, to: String)] = []
        var untracked: [String] = []
        for entry in journal.entries.reversed() {
            guard fileManager.fileExists(atPath: entry.to) else { continue }
            if entry.trackId == nil { untracked.append(entry.to) }
            if entry.copied {
                try fileManager.removeItem(atPath: entry.to)
                if let id = entry.trackId { removedTracks.append(id) }
                continue
            }
            let source = URL(fileURLWithPath: entry.from)
            try fileManager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(atPath: entry.to, toPath: entry.from)
            if let id = entry.trackId { restored.append((id, entry.from)) } else { restoredFiles.append((entry.to, entry.from)) }
        }
        if journal.kind == .import {
            // Imported songs leave the library entirely (moved back out, or their copies deleted), cue albums included.
            removedTracks += restored.map(\.0)
            if !untracked.isEmpty {
                removedTracks += try database.writer.read { db in
                    try Int64.fetchAll(db, sql: "SELECT id FROM track WHERE audioPath IN (\(untracked.map { _ in "?" }.joined(separator: ",")))",
                                       arguments: StatementArguments(untracked))
                }
            }
        } else {
            try database.updatePaths(restored)
            try database.relocateCueFiles(restoredFiles)
        }
        if !removedTracks.isEmpty {
            _ = try database.writer.write { db in try Track.deleteAll(db, keys: removedTracks) }
        }
        removeEmptyFolders(Set(journal.entries.map { URL(fileURLWithPath: $0.to).deletingLastPathComponent().path } + journal.createdFolders))
    }

    /// Removes folders left with nothing (or only .DS_Store), walking up while parents empty too.
    static func removeEmptyFolders(_ folders: Set<String>) {
        let fileManager = FileManager.default
        for folder in folders.sorted(by: { $0.count > $1.count }) {
            var current = URL(fileURLWithPath: folder)
            for _ in 0..<4 {
                guard let contents = try? fileManager.contentsOfDirectory(atPath: current.path),
                      contents.allSatisfy({ $0 == ".DS_Store" }) else { break }
                try? fileManager.removeItem(at: current)
                current = current.deletingLastPathComponent()
            }
        }
    }

    // MARK: Journals on disk

    public static func save(_ journal: FileOperationJournal, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(journal).write(to: folder.appendingPathComponent("\(Int(journal.date.timeIntervalSince1970))-\(journal.id).json"))
    }

    /// The newest journal that was not undone yet.
    public static func latestJournal(in folder: URL) -> (FileOperationJournal, URL)? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for file in files {
            if let data = try? Data(contentsOf: file), let journal = try? decoder.decode(FileOperationJournal.self, from: data) {
                return (journal, file)
            }
        }
        return nil
    }
}

extension LibraryDatabase {
    /// Points songs at their new files (after a rename, an import or an undo).
    public func updatePaths(_ changes: [(trackId: Int64, path: String)]) throws {
        guard !changes.isEmpty else { return }
        try writer.write { db in
            // Through temporary values: swapped names would otherwise hit the unique path constraint.
            for change in changes {
                try db.execute(sql: "UPDATE track SET path = ? WHERE id = ?", arguments: ["\u{1}moving-\(change.trackId)", change.trackId])
            }
            for change in changes {
                try db.execute(sql: "UPDATE track SET path = ? WHERE id = ?", arguments: [change.path, change.trackId])
            }
        }
    }

    /// Follows audio files and cue sheets that moved: songs of a cue sheet keep pointing at their audio file
    /// (`audioPath`) and are stored under the sheet's path ("<sheet>#NN").
    public func relocateCueFiles(_ moves: [(from: String, to: String)]) throws {
        guard !moves.isEmpty else { return }
        try writer.write { db in
            for move in moves {
                try db.execute(sql: "UPDATE track SET audioPath = ? WHERE audioPath = ?", arguments: [move.to, move.from])
                // A range instead of LIKE: paths may contain "%" or "_". `substr` and `length` both count characters.
                try db.execute(sql: """
                    UPDATE track SET path = ? || substr(path, length(?) + 1)
                    WHERE path >= ? || '#' AND path < ? || '$'
                    """, arguments: [move.to, move.from, move.from, move.from])
            }
        }
    }
}

extension Track {
    /// A provisional song built from a file's tags (not in the library), e.g. to identify files before importing them.
    public static func candidate(id: Int64, url: URL, tags: FileTags) -> Track {
        Track(id: id, rootId: 0, path: url.path, fileSize: 0, modifiedAt: .now,
              title: tags.title.nonEmpty ?? url.deletingPathExtension().lastPathComponent, artist: tags.artist.nonEmpty,
              album: tags.album.nonEmpty, albumArtist: tags.albumArtist.nonEmpty, composer: tags.composer, genre: tags.genre,
              year: tags.year, trackNumber: tags.trackNumber, trackTotal: tags.trackTotal, discNumber: tags.discNumber,
              discTotal: tags.discTotal, isCompilation: tags.isCompilation, bpm: tags.bpm, comment: tags.comment, lyrics: tags.lyrics,
              musicBrainzRecordingId: tags.musicBrainzRecordingId, musicBrainzReleaseId: tags.musicBrainzReleaseId,
              replayGainTrackGain: nil, replayGainAlbumGain: nil, duration: tags.duration, format: tags.format,
              sampleRate: tags.sampleRate, bitDepth: tags.bitDepth, bitrate: tags.bitrate, channels: tags.channels, artworkHash: nil,
              albumKey: Track.makeAlbumKey(album: tags.album, albumArtist: tags.albumArtist, artist: tags.artist, isCompilation: tags.isCompilation),
              rating: 0, isLoved: false, playCount: 0, skipCount: 0, lastPlayedAt: nil, dateAdded: .now)
    }
}
