import Foundation
import GRDB

/// Playlist files of other players: M3U / M3U8, PLS, XSPF, Windows Media Player (WPL) and Music / iTunes XML. Read into
/// entries (a location and whatever the file says about the song), written from library songs.
public enum PlaylistFormat: String, CaseIterable, Sendable, Identifiable {
    case m3u8, m3u, pls, xspf, wpl, musicXML

    public var id: String { rawValue }

    /// Formats a playlist can be saved in (WPL is read only: little else reads it).
    public static let exportable: [PlaylistFormat] = [.m3u8, .m3u, .pls, .xspf, .musicXML]

    public var fileExtension: String {
        switch self {
        case .m3u8: "m3u8"
        case .m3u: "m3u"
        case .pls: "pls"
        case .xspf: "xspf"
        case .wpl: "wpl"
        case .musicXML: "xml"
        }
    }

    public var name: String {
        switch self {
        case .m3u8: "M3U8 (Unicode)"
        case .m3u: "M3U"
        case .pls: "PLS"
        case .xspf: "XSPF"
        case .wpl: "Windows Media Player"
        case .musicXML: "Music / iTunes XML"
        }
    }

    /// Every extension read (ZPL is the Zune variant of WPL).
    public static let readableExtensions: Set<String> = ["m3u8", "m3u", "pls", "xspf", "wpl", "zpl", "xml"]

    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "m3u8": self = .m3u8
        case "m3u": self = .m3u
        case "pls": self = .pls
        case "xspf": self = .xspf
        case "wpl", "zpl": self = .wpl
        case "xml": self = .musicXML
        default: return nil
        }
    }
}

/// One song of a playlist file: where it was, and what the file says about it (used when the path no longer matches).
public struct PlaylistEntry: Equatable, Sendable {
    /// Absolute path, when the file gave a usable one (relative paths are resolved against the playlist's folder).
    public var path: String?
    public var title: String?
    public var artist: String?
    public var album: String?
    /// Seconds.
    public var duration: Double?

    public init(path: String? = nil, title: String? = nil, artist: String? = nil, album: String? = nil, duration: Double? = nil) {
        self.path = path
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }

    /// How the entry is described to the user when it is not found.
    public var label: String {
        if let title, !title.isEmpty { return [artist, title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " - ") }
        return path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Unknown song"
    }
}

/// A playlist read from a file (a Music XML file can hold several).
public struct PlaylistDocument: Equatable, Sendable {
    public var name: String
    public var entries: [PlaylistEntry]

    public init(name: String, entries: [PlaylistEntry]) {
        self.name = name
        self.entries = entries
    }
}

public enum PlaylistFileError: LocalizedError {
    case unreadable(String)
    case unknownFormat(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): "\(name) is not a playlist Groovelight can read."
        case .unknownFormat(let name): "\(name) is not a playlist file (M3U, M3U8, PLS, XSPF, WPL or Music XML)."
        }
    }
}

public enum PlaylistFile {
    // MARK: - Reading

    public static func read(_ url: URL) throws -> [PlaylistDocument] {
        guard let format = PlaylistFormat(fileExtension: url.pathExtension) else {
            throw PlaylistFileError.unknownFormat(url.lastPathComponent)
        }
        let data = try Data(contentsOf: url)
        return try parse(data, format: format, name: url.deletingPathExtension().lastPathComponent,
                         folder: url.deletingLastPathComponent())
    }

    /// `name` is used when the file has no title of its own; relative locations resolve against `folder`.
    public static func parse(_ data: Data, format: PlaylistFormat, name: String, folder: URL) throws -> [PlaylistDocument] {
        let documents: [PlaylistDocument]
        switch format {
        case .m3u8, .m3u: documents = [parseM3U(text(data), name: name, folder: folder)]
        case .pls: documents = [parsePLS(text(data), name: name, folder: folder)]
        case .xspf: documents = [try XMLPlaylistParser.xspf(data, name: name, folder: folder)]
        case .wpl: documents = [try XMLPlaylistParser.wpl(data, name: name, folder: folder)]
        case .musicXML: documents = try parseMusicXML(data, folder: folder)
        }
        guard !documents.isEmpty else { throw PlaylistFileError.unreadable(name) }
        return documents
    }

    /// UTF-8 (with or without a byte order mark), else Windows Latin-1, as older M3U and PLS files are.
    static func text(_ data: Data) -> String {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        return String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .windowsCP1252) ?? ""
    }

    static func parseM3U(_ text: String, name: String, folder: URL) -> PlaylistDocument {
        var document = PlaylistDocument(name: name, entries: [])
        var pending = PlaylistEntry()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if line.hasPrefix("#EXTINF:") {
                    // #EXTINF:<seconds>[ attributes],<artist> - <title>
                    let info = line.dropFirst("#EXTINF:".count)
                    let comma = info.firstIndex(of: ",")
                    let seconds = info[..<(comma ?? info.endIndex)].split(separator: " ").first.flatMap { Double($0) }
                    pending.duration = seconds.flatMap { $0 > 0 ? $0 : nil }
                    if let comma {
                        let label = info[info.index(after: comma)...].trimmingCharacters(in: .whitespaces)
                        if let dash = label.range(of: " - ") {
                            pending.artist = String(label[..<dash.lowerBound])
                            pending.title = String(label[dash.upperBound...])
                        } else {
                            pending.title = label
                        }
                    }
                } else if line.hasPrefix("#EXTALB:") {
                    pending.album = String(line.dropFirst("#EXTALB:".count)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("#EXTART:") {
                    pending.artist = String(line.dropFirst("#EXTART:".count)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("#PLAYLIST:") {
                    let title = line.dropFirst("#PLAYLIST:".count).trimmingCharacters(in: .whitespaces)
                    if !title.isEmpty { document.name = title }
                }
                continue
            }
            pending.path = resolve(line, folder: folder)
            document.entries.append(pending)
            pending = PlaylistEntry()
        }
        return document
    }

    static func parsePLS(_ text: String, name: String, folder: URL) -> PlaylistDocument {
        var files: [Int: PlaylistEntry] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].lowercased(), value = String(line[line.index(after: equals)...])
            for (prefix, apply) in [
                ("file", { (entry: inout PlaylistEntry) in entry.path = resolve(value, folder: folder) }),
                ("title", { (entry: inout PlaylistEntry) in entry.title = value }),
                ("length", { (entry: inout PlaylistEntry) in entry.duration = Double(value).flatMap { $0 > 0 ? $0 : nil } }),
            ] as [(String, (inout PlaylistEntry) -> Void)] {
                if key.hasPrefix(prefix), let number = Int(key.dropFirst(prefix.count)) {
                    apply(&files[number, default: PlaylistEntry()])
                }
            }
        }
        // A title written as "Artist - Title", as most players do.
        let entries = files.keys.sorted().compactMap { files[$0] }.filter { $0.path != nil }.map { entry in
            var entry = entry
            if let title = entry.title, let dash = title.range(of: " - ") {
                entry.artist = String(title[..<dash.lowerBound])
                entry.title = String(title[dash.upperBound...])
            }
            return entry
        }
        return PlaylistDocument(name: name, entries: entries)
    }

    static func parseMusicXML(_ data: Data, folder: URL) throws -> [PlaylistDocument] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let playlists = plist["Playlists"] as? [[String: Any]] else {
            throw PlaylistFileError.unreadable("The XML file")
        }
        let tracks = plist["Tracks"] as? [String: [String: Any]] ?? [:]
        return playlists.compactMap { playlist in
            // The library itself, Music's built-in lists (Music, Movies, Downloaded...) and folders are left out.
            if playlist["Master"] as? Bool == true || playlist["Distinguished Kind"] != nil || playlist["Folder"] as? Bool == true
                || playlist["Visible"] as? Bool == false { return nil }
            let items = playlist["Playlist Items"] as? [[String: Any]] ?? []
            let entries = items.compactMap { item -> PlaylistEntry? in
                guard let id = item["Track ID"].map({ "\($0)" }), let track = tracks[id] else { return nil }
                return PlaylistEntry(path: (track["Location"] as? String).flatMap { resolve($0, folder: folder) },
                                     title: track["Name"] as? String, artist: track["Artist"] as? String,
                                     album: track["Album"] as? String,
                                     duration: (track["Total Time"] as? Int).map { Double($0) / 1000 })
            }
            return PlaylistDocument(name: playlist["Name"] as? String ?? "Playlist", entries: entries)
        }
    }

    /// An absolute path from a file URL, an absolute path or a path relative to the playlist (Windows separators too).
    /// Nil for web addresses and Windows drive paths, which cannot point into this Mac's library.
    static func resolve(_ location: String, folder: URL) -> String? {
        let location = location.trimmingCharacters(in: .whitespaces)
        guard !location.isEmpty else { return nil }
        if location.lowercased().hasPrefix("file:") {
            return URL(string: location)?.standardizedFileURL.path
                ?? location.dropFirst("file://".count).removingPercentEncoding
        }
        if location.contains("://") { return nil }
        if location.count > 1, location.dropFirst().first == ":" { return nil }
        let path = location.replacingOccurrences(of: "\\", with: "/")
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL.path }
        return folder.appendingPathComponent(path).standardizedFileURL.path
    }

    // MARK: - Writing

    /// Where songs are written in the file: absolute paths, or paths relative to the playlist's folder (for a playlist
    /// kept next to the music, or on a drive mounted elsewhere).
    public enum PathStyle: Sendable {
        case absolute
        case relative(to: URL)
    }

    public static func write(name: String, tracks: [Track], format: PlaylistFormat, paths: PathStyle = .absolute) -> Data {
        switch format {
        case .m3u8, .m3u, .wpl:
            var lines = ["#EXTM3U", "#PLAYLIST:\(name)"]
            for track in tracks {
                lines.append("#EXTINF:\(Int(track.duration.rounded())),\(label(track))")
                if let album = track.album { lines.append("#EXTALB:\(album)") }
                lines.append(location(track, paths))
            }
            let text = lines.joined(separator: "\n") + "\n"
            // Plain M3U is read as Windows Latin-1 by older players: kept to it when every character fits.
            if format == .m3u, let latin = text.data(using: .windowsCP1252) { return latin }
            return Data(text.utf8)
        case .pls:
            var lines = ["[playlist]"]
            for (index, track) in tracks.enumerated() {
                let number = index + 1
                lines += ["File\(number)=\(location(track, paths))", "Title\(number)=\(label(track))",
                          "Length\(number)=\(Int(track.duration.rounded()))"]
            }
            lines += ["NumberOfEntries=\(tracks.count)", "Version=2"]
            return Data((lines.joined(separator: "\n") + "\n").utf8)
        case .xspf:
            var xml = """
                <?xml version="1.0" encoding="UTF-8"?>
                <playlist version="1" xmlns="http://xspf.org/ns/0/">
                  <title>\(escape(name))</title>
                  <trackList>

                """
            for track in tracks {
                xml += "    <track>\n"
                xml += "      <location>\(escape(uri(track, paths)))</location>\n"
                xml += "      <title>\(escape(track.title))</title>\n"
                if let artist = track.artist { xml += "      <creator>\(escape(artist))</creator>\n" }
                if let album = track.album { xml += "      <album>\(escape(album))</album>\n" }
                xml += "      <duration>\(Int((track.duration * 1000).rounded()))</duration>\n"
                xml += "    </track>\n"
            }
            xml += "  </trackList>\n</playlist>\n"
            return Data(xml.utf8)
        case .musicXML:
            return musicXML(name: name, tracks: tracks)
        }
    }

    /// A playlist as Music exports it (File > Library > Export Playlist), which Music and iTunes import back.
    static func musicXML(name: String, tracks: [Track]) -> Data {
        var trackTable: [String: Any] = [:]
        var items: [[String: Any]] = []
        for (index, track) in tracks.enumerated() {
            let id = (track.id.map(Int.init) ?? index + 1)
            var info: [String: Any] = ["Track ID": id, "Name": track.title, "Total Time": Int((track.duration * 1000).rounded()),
                                       "Location": URL(fileURLWithPath: track.audioPath ?? track.path).absoluteString,
                                       "Kind": "\(track.format ?? "Audio") audio file"]
            if let artist = track.artist { info["Artist"] = artist }
            if let album = track.album { info["Album"] = album }
            if let albumArtist = track.albumArtist { info["Album Artist"] = albumArtist }
            if let genre = track.genre { info["Genre"] = genre }
            if let year = track.year { info["Year"] = year }
            if let number = track.trackNumber { info["Track Number"] = number }
            if let disc = track.discNumber { info["Disc Number"] = disc }
            trackTable["\(id)"] = info
            items.append(["Track ID": id])
        }
        let plist: [String: Any] = [
            "Major Version": 1, "Minor Version": 1, "Application Version": "Groovelight", "Date": Date.now,
            "Tracks": trackTable,
            "Playlists": [["Name": name, "Playlist ID": 1, "All Items": true, "Playlist Items": items]],
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
    }

    /// "Artist - Title", what M3U and PLS players show.
    private static func label(_ track: Track) -> String {
        [track.artist, track.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " - ")
    }

    /// The song's audio file (for a CUE track, the file holding the album: the entry's title tells the songs apart).
    private static func location(_ track: Track, _ paths: PathStyle) -> String {
        let path = track.audioPath ?? track.path
        guard case .relative(let folder) = paths else { return path }
        return relativePath(path, from: folder.standardizedFileURL.path)
    }

    private static func uri(_ track: Track, _ paths: PathStyle) -> String {
        let path = track.audioPath ?? track.path
        guard case .relative(let folder) = paths else { return URL(fileURLWithPath: path).absoluteString }
        let relative = relativePath(path, from: folder.standardizedFileURL.path)
        return relative.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? String($0) }
            .joined(separator: "/")
    }

    /// `path` as seen from `folder`, with ".." steps (absolute when they share nothing but the root).
    static func relativePath(_ path: String, from folder: String) -> String {
        let target = path.split(separator: "/").map(String.init), base = folder.split(separator: "/").map(String.init)
        var common = 0
        while common < min(target.count, base.count), target[common] == base[common] { common += 1 }
        guard common > 0 else { return path }
        return (Array(repeating: "..", count: base.count - common) + target[common...]).joined(separator: "/")
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// XSPF and WPL, both XML.
private final class XMLPlaylistParser: NSObject, XMLParserDelegate {
    private var document: PlaylistDocument
    private let folder: URL
    private let isWPL: Bool
    private var text = ""
    private var entry: PlaylistEntry?
    private var stack: [String] = []

    private init(name: String, folder: URL, isWPL: Bool) {
        document = PlaylistDocument(name: name, entries: [])
        self.folder = folder
        self.isWPL = isWPL
    }

    static func xspf(_ data: Data, name: String, folder: URL) throws -> PlaylistDocument {
        try run(XMLPlaylistParser(name: name, folder: folder, isWPL: false), data, name)
    }

    static func wpl(_ data: Data, name: String, folder: URL) throws -> PlaylistDocument {
        try run(XMLPlaylistParser(name: name, folder: folder, isWPL: true), data, name)
    }

    private static func run(_ delegate: XMLPlaylistParser, _ data: Data, _ name: String) throws -> PlaylistDocument {
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw PlaylistFileError.unreadable(name) }
        return delegate.document
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let name = name.lowercased()
        stack.append(name)
        text = ""
        if isWPL, name == "media", let source = attributes["src"] {
            document.entries.append(PlaylistEntry(path: PlaylistFile.resolve(source, folder: folder)))
        } else if !isWPL, name == "track" {
            entry = PlaylistEntry()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let name = name.lowercased()
        defer { stack.removeLast() }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        // The playlist's own title: directly under <playlist> (XSPF) or <head> (WPL), not a song's.
        if name == "title", entry == nil, !value.isEmpty, stack.dropLast().last == (isWPL ? "head" : "playlist") {
            document.name = value
            return
        }
        guard !isWPL, entry != nil else { return }
        switch name {
        case "location" where entry?.path == nil:
            // A URI: relative ones are percent-encoded too.
            let location = value.lowercased().hasPrefix("file:") ? value : (value.removingPercentEncoding ?? value)
            entry?.path = PlaylistFile.resolve(location, folder: folder)
        case "title": entry?.title = value
        case "creator": entry?.artist = value
        case "album": entry?.album = value
        case "duration": entry?.duration = Double(value).map { $0 / 1000 }
        case "track":
            if let entry { document.entries.append(entry) }
            entry = nil
        default: break
        }
    }
}

// MARK: - Matching entries to library songs

extension LibraryDatabase {
    /// The library song for each entry (nil when none fits): by path first (for a CUE album file, the track whose title
    /// matches), then by title and artist, preferring the same album and a close length.
    public static func matchPlaylistEntries(_ db: Database, _ entries: [PlaylistEntry]) throws -> [Int64?] {
        try entries.map { entry in
            if let path = entry.path {
                for candidate in pathVariants(path) {
                    if let id = try Int64.fetchOne(db, sql: "SELECT id FROM track WHERE path = ?", arguments: [candidate]) {
                        return id
                    }
                    let cueTracks = try Track.fetchAll(db, sql: "SELECT * FROM track WHERE audioPath = ? ORDER BY startTime",
                                                       arguments: [candidate])
                    if !cueTracks.isEmpty {
                        return (cueTracks.first { fold($0.title) == fold(entry.title) } ?? cueTracks.first)?.id
                    }
                }
            }
            guard let title = entry.title, !title.isEmpty else { return nil }
            let candidates = try Track.fetchAll(db, sql: "SELECT * FROM track WHERE title = ? COLLATE NOCASE", arguments: [title])
            let fitting = candidates.filter { track in
                guard let artist = entry.artist, !artist.isEmpty else { return true }
                return fold(track.artist) == fold(artist) || fold(track.albumArtist) == fold(artist)
            }
            return fitting.max { score($0, entry) < score($1, entry) }?.id
        }
    }

    /// The path as written, decomposed and precomposed (HFS+ and other systems disagree on accents), and with links
    /// resolved (/tmp is /private/tmp).
    private static func pathVariants(_ path: String) -> [String] {
        var variants = [path, path.precomposedStringWithCanonicalMapping, path.decomposedStringWithCanonicalMapping]
        if let real = realpath(path, nil) {
            variants.append(String(cString: real))
            free(real)
        }
        var seen = Set<String>()
        return variants.filter { seen.insert($0).inserted }
    }

    private static func fold(_ text: String?) -> String {
        (text ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func score(_ track: Track, _ entry: PlaylistEntry) -> Int {
        var score = 0
        if let album = entry.album, fold(track.album) == fold(album) { score += 2 }
        if let duration = entry.duration, abs(track.duration - duration) <= 3 { score += 1 }
        return score
    }
}
