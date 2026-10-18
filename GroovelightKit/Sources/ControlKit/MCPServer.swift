import Foundation

/// Groovelight as an MCP server (Model Context Protocol), for Claude and other AI tools: `groovelight mcp` speaks
/// JSON-RPC over stdin and stdout, and each tool call becomes a request to the app.
///
/// Changes to files go in two steps: a preview tool shows what would happen and returns a `preview_id`, and the
/// matching apply tool takes only that id, so a change is always one the user could see first.
public final class MCPServer {
    /// Runs a request in the app, passing job updates along.
    public typealias Execute = (ControlRequest, (ControlReply) -> Void) throws -> ControlReply

    public static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private let version: String
    private let execute: Execute
    /// Gives the app access to files before an import (opens them with it).
    private let grantAccess: ([String]) throws -> Void
    /// What each preview would apply.
    private var previews: [String: ControlRequest] = [:]

    public init(version: String, execute: @escaping Execute, grantAccess: @escaping ([String]) throws -> Void = { _ in }) {
        self.version = version
        self.execute = execute
        self.grantAccess = grantAccess
    }

    /// Reads messages from stdin until it closes, answering on stdout.
    public func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let reply: JSONValue?
            if let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) {
                reply = handle(message, notify: Self.write)
            } else {
                reply = Self.error(id: .null, code: -32700, message: "Parse error")
            }
            if let reply { Self.write(reply) }
        }
    }

    private static func write(_ message: JSONValue) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(message) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    /// The reply to one message (nil for notifications); `notify` sends progress while a tool runs.
    public func handle(_ message: JSONValue, notify: (JSONValue) -> Void) -> JSONValue? {
        guard let method = message["method"]?.stringValue else { return nil }
        guard let id = message["id"], !id.isNull else { return nil }
        let params = message["params"] ?? .object([:])
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? ""
            return Self.result(id: id, .object([
                "protocolVersion": .string(Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[1]),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string("groovelight"), "title": .string("Groovelight"), "version": .string(version)]),
                "instructions": .string(Self.instructions),
            ]))
        case "ping":
            return Self.result(id: id, .object([:]))
        case "tools/list":
            return Self.result(id: id, .object(["tools": .array(Self.tools)]))
        case "tools/call":
            guard let name = params["name"]?.stringValue else { return Self.error(id: id, code: -32602, message: "Missing tool name") }
            let token = params["_meta"]?["progressToken"]
            var step = 0
            var last = ""
            let result = call(name, arguments: params["arguments"] ?? .object([:])) { update in
                guard let token, !token.isNull, let progress = update.progress else { return }
                let count = progress.total > 0 ? " (\(progress.done) of \(progress.total))" : ""
                // Only when something changed: jobs are polled several times a second.
                guard progress.label + count != last else { return }
                last = progress.label + count
                step += 1
                notify(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/progress"),
                                "params": .object(["progressToken": token, "progress": .number(Double(step)),
                                                   "message": .string(progress.label + count)])]))
            }
            return Self.result(id: id, result)
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Tools

    private func call(_ name: String, arguments: JSONValue, progress: (ControlReply) -> Void) -> JSONValue {
        do {
            switch name {
            case "library_status": return try snapshot(.status, progress)
            case "search_library":
                guard let query = arguments["query"]?.stringValue else { return Self.toolError("Give a query.") }
                return try snapshot(.search(query: query, limit: arguments["limit"]?.intValue ?? 20), progress)
            case "preview_import":
                let paths = (arguments["paths"]?.arrayValue ?? []).compactMap(\.stringValue).map { ($0 as NSString).expandingTildeInPath }
                guard !paths.isEmpty else { return Self.toolError("Give the paths of the songs, folders or archives to import.") }
                var options = ImportOptions(paths: paths, folder: arguments["folder"]?.stringValue, copy: arguments["copy"]?.boolValue ?? false,
                                            useOnlineMetadata: arguments["use_online_metadata"]?.boolValue ?? true,
                                            writeTags: arguments["write_tags"]?.boolValue ?? true,
                                            trashArchives: arguments["trash_archives"]?.boolValue ?? false, dryRun: true)
                try ImportPaths.check(paths)
                try grantAccess(paths)
                let reply = try execute(.importFiles(options), progress)
                options.dryRun = false
                return preview(reply, applying: .importFiles(options), with: "import_music")
            case "preview_fix_metadata":
                var options = FixMetadataOptions(album: arguments["album"]?.stringValue, artist: arguments["artist"]?.stringValue,
                                                 songIds: arguments["song_ids"] == nil ? nil : Self.ids(arguments["song_ids"]),
                                                 searchAlbum: arguments["search_album"]?.stringValue, searchArtist: arguments["search_artist"]?.stringValue,
                                                 release: arguments["release"]?.stringValue, includeUnmatched: arguments["include_unmatched"]?.boolValue ?? false,
                                                 cover: arguments["cover"]?.boolValue ?? true, writeTags: arguments["write_tags"]?.boolValue, dryRun: true)
                guard options.album != nil || options.artist != nil || options.songIds?.isEmpty == false else {
                    return Self.toolError("Say which songs: album (with artist when several albums share the title), artist, or song_ids.")
                }
                let reply = try execute(.fixMetadata(options), progress)
                // Apply exactly the release that was previewed.
                guard let release = reply.data?["release"]?["id"]?.stringValue else { return Self.toolResult(reply) }
                options.release = release
                options.dryRun = false
                return preview(reply, applying: .fixMetadata(options), with: "apply_fix_metadata")
            case "preview_organize":
                let options = OrganizeFilesOptions(album: arguments["album"]?.stringValue, artist: arguments["artist"]?.stringValue, dryRun: true)
                let reply = try execute(.organize(options), progress)
                let renames = reply.data?["renames"]?.arrayValue ?? []
                guard !renames.isEmpty else { return Self.toolResult(reply) }
                return preview(reply, applying: .organize(OrganizeFilesOptions(album: options.album, artist: options.artist)), with: "organize_files")
            case "import_music", "apply_fix_metadata", "organize_files":
                guard let id = arguments["preview_id"]?.stringValue, let request = previews[id] else {
                    return Self.toolError("Unknown preview_id. Run the matching preview tool first and show the user what it found.")
                }
                guard Self.applyTool(for: request) == name else { return Self.toolError("That preview_id belongs to \(Self.applyTool(for: request)).") }
                if case .importFiles(let options) = request { try grantAccess(options.paths) }
                let reply = try execute(request, progress)
                if reply.error == nil { previews[id] = nil }
                return Self.toolResult(reply)
            case "undo_last_file_operation": return try run(.undo, progress)
            case "rescan_library": return try run(.rescan, progress)
            case "list_playlists": return try snapshot(.listPlaylists, progress)
            case "create_playlist":
                guard let name = arguments["name"]?.stringValue else { return Self.toolError("Give the playlist a name.") }
                return try run(.createPlaylist(name: name, songIds: Self.ids(arguments["song_ids"])), progress)
            case "add_to_playlist":
                guard let playlist = arguments["playlist"]?.stringValue else { return Self.toolError("Say which playlist (its name).") }
                return try run(.addToPlaylist(playlist: playlist, songIds: Self.ids(arguments["song_ids"])), progress)
            case "play":
                let songIds = Self.ids(arguments["song_ids"])
                return try run(.play(PlayOptions(songIds: songIds.isEmpty ? nil : songIds, album: arguments["album"]?.stringValue, artist: arguments["artist"]?.stringValue,
                                                 playlist: arguments["playlist"]?.stringValue, song: arguments["song"]?.stringValue,
                                                 query: arguments["query"]?.stringValue, shuffle: arguments["shuffle"]?.boolValue ?? false)), progress)
            case "playback_control":
                guard let action = arguments["action"]?.stringValue.flatMap(PlaybackAction.init) else {
                    return Self.toolError("action must be one of: \(PlaybackAction.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                return try run(.playback(action), progress)
            case "now_playing": return try snapshot(.nowPlaying, progress)
            default: return Self.toolError("Unknown tool: \(name)")
            }
        } catch {
            return Self.toolError((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    private func run(_ request: ControlRequest, _ progress: (ControlReply) -> Void) throws -> JSONValue {
        Self.toolResult(try execute(request, progress))
    }

    /// A result about state that changes outside the conversation (the user also plays and imports in the app), with the
    /// time it was read, so the model can tell how old it is.
    private func snapshot(_ request: ControlRequest, _ progress: (ControlReply) -> Void) throws -> JSONValue {
        Self.stamped(Self.toolResult(try execute(request, progress)), at: Date())
    }

    static func stamped(_ result: JSONValue, at date: Date) -> JSONValue {
        guard case .object(var fields) = result, fields["isError"] == nil else { return result }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        let time = formatter.string(from: date)
        var data: [String: JSONValue] = [:]
        if case .object(let existing)? = fields["structuredContent"] { data = existing }
        data["as_of"] = .string(time)
        fields["structuredContent"] = .object(data)
        if case .array(var content)? = fields["content"], case .object(var first)? = content.first, let text = first["text"]?.stringValue {
            first["text"] = .string(text + "\n\nAs of \(time).")
            content[0] = .object(first)
            fields["content"] = .array(content)
        }
        return .object(fields)
    }

    /// A preview's result, with the id its apply tool takes (none when it failed).
    private func preview(_ reply: ControlReply, applying request: ControlRequest, with tool: String) -> JSONValue {
        guard reply.error == nil else { return Self.toolResult(reply) }
        let id = "p" + UUID().uuidString.prefix(8).lowercased()
        previews[id] = request
        var reply = reply
        reply.summary = (reply.summary ?? "") + "\n\npreview_id: \(id) (show this to the user; apply with \(tool) only after they agree)"
        var data: [String: JSONValue] = ["preview_id": .string(id)]
        if let existing = reply.data { data["preview"] = existing }
        reply.data = .object(data)
        return Self.toolResult(reply)
    }

    private static func ids(_ value: JSONValue?) -> [Int64] {
        (value?.arrayValue ?? []).compactMap { $0.intValue.map(Int64.init) }
    }

    private static func applyTool(for request: ControlRequest) -> String {
        switch request {
        case .importFiles: "import_music"
        case .fixMetadata: "apply_fix_metadata"
        default: "organize_files"
        }
    }

    // MARK: - Messages

    static func toolResult(_ reply: ControlReply) -> JSONValue {
        var text = reply.summary ?? ""
        if !reply.messages.isEmpty { text = (reply.messages + [text]).joined(separator: "\n") }
        if let error = reply.error { text = text.isEmpty ? error : text + "\n\nError: " + error }
        var result: [String: JSONValue] = ["content": .array([.object(["type": .string("text"), "text": .string(text.isEmpty ? "Done." : text)])])]
        if let data = reply.data, !data.isNull {
            if case .object = data { result["structuredContent"] = data } else { result["structuredContent"] = .object(["result": data]) }
        }
        if reply.error != nil { result["isError"] = .bool(true) }
        return .object(result)
    }

    static func toolError(_ message: String) -> JSONValue {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(message)])]), "isError": .bool(true)])
    }

    private static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    private static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }

    // MARK: - Descriptions

    static let instructions = """
        Groovelight is the user's music player and library on their Mac. Use search_library and library_status to \
        answer questions about the music. Changes to files go in two steps: call a preview tool (preview_import, \
        preview_fix_metadata, preview_organize), show the user what it would change, and call the matching apply \
        tool with its preview_id only after they agree. Imports and organizing can be undone with \
        undo_last_file_operation; metadata fixes cannot. To make a playlist, find each song with search_library \
        (songs come with their ids) and pass the ids to create_playlist, in order; play takes song_ids too. Paths are \
        absolute paths on the user's Mac.

        The user also uses Groovelight directly, so the song playing, playlists and the library change outside this \
        conversation. A result shows the state when the tool ran (its as_of time). Before answering about what is \
        playing, playlists or what is in the library, call the tool again rather than relying on an earlier result.
        """

    static let tools: [JSONValue] = {
        let json = #"""
        [
          {"name": "library_status", "title": "Library status",
           "description": "The library's size (songs, albums, artists), its music folders (and which one imports go to), and what is playing.",
           "inputSchema": {"type": "object", "properties": {}},
           "annotations": {"readOnlyHint": true}},
          {"name": "search_library", "title": "Search the library",
           "description": "Searches the library for artists, albums and songs (title, artist, album, lyrics, credits). Songs come with their id and file path.",
           "inputSchema": {"type": "object", "properties": {
             "query": {"type": "string", "description": "What to look for."},
             "limit": {"type": "integer", "description": "How many of each kind (default 20, at most 200)."}}, "required": ["query"]},
           "annotations": {"readOnlyHint": true}},
          {"name": "preview_import", "title": "Preview an import",
           "description": "Shows what importing songs, folders or archives (zip, 7z, rar, tar) would do: each album as identified on MusicBrainz and where each file would go. Changes nothing. Returns a preview_id for import_music.",
           "inputSchema": {"type": "object", "properties": {
             "paths": {"type": "array", "items": {"type": "string"}, "description": "Absolute paths of songs, folders or archives."},
             "folder": {"type": "string", "description": "Library folder to import into (name or path); default: the one set in Settings."},
             "copy": {"type": "boolean", "description": "Copy instead of moving the files (default false)."},
             "use_online_metadata": {"type": "boolean", "description": "Use the metadata found on MusicBrainz (default true)."},
             "write_tags": {"type": "boolean", "description": "Write tags and covers into the files (default true)."},
             "trash_archives": {"type": "boolean", "description": "Move archives to the Trash once imported (default false)."}}, "required": ["paths"]},
           "annotations": {"readOnlyHint": true, "openWorldHint": true}},
          {"name": "import_music", "title": "Import music",
           "description": "Imports what preview_import showed: moves (or copies) the files into the library, tags and names them. Call only after the user agreed to the preview. Undo with undo_last_file_operation.",
           "inputSchema": {"type": "object", "properties": {
             "preview_id": {"type": "string", "description": "The preview_id from preview_import."}}, "required": ["preview_id"]},
           "annotations": {"readOnlyHint": false, "destructiveHint": true, "idempotentHint": false}},
          {"name": "preview_fix_metadata", "title": "Preview a metadata fix",
           "description": "Finds an album's release on MusicBrainz and shows the tag changes it would make (song by song) and the releases found. Songs from one album with mixed-up tags can be fixed together with song_ids. Changes nothing. Returns a preview_id for apply_fix_metadata.",
           "inputSchema": {"type": "object", "properties": {
             "album": {"type": "string", "description": "The album's title."},
             "artist": {"type": "string", "description": "The album's artist (to tell albums apart), or alone: every song of the artist."},
             "song_ids": {"type": "array", "items": {"type": "integer"}, "description": "Song ids (from search_library) to fix as one album."},
             "search_album": {"type": "string", "description": "Search MusicBrainz for this title instead of the songs' own (empty: leave it out)."},
             "search_artist": {"type": "string", "description": "Search MusicBrainz for this artist instead of the songs' own (empty: leave it out)."},
             "release": {"type": "string", "description": "A MusicBrainz release id to use instead of the best match (from the releases a preview lists)."},
             "include_unmatched": {"type": "boolean", "description": "Also give the album's details to songs not on the release (default false)."},
             "cover": {"type": "boolean", "description": "Also replace the cover (default true)."},
             "write_tags": {"type": "boolean", "description": "Write the tags into the files (default: the user's setting)."}}},
           "annotations": {"readOnlyHint": true, "openWorldHint": true}},
          {"name": "apply_fix_metadata", "title": "Apply a metadata fix",
           "description": "Applies the changes preview_fix_metadata showed. Call only after the user agreed. This cannot be undone.",
           "inputSchema": {"type": "object", "properties": {
             "preview_id": {"type": "string", "description": "The preview_id from preview_fix_metadata."}}, "required": ["preview_id"]},
           "annotations": {"readOnlyHint": false, "destructiveHint": true, "idempotentHint": true}},
          {"name": "preview_organize", "title": "Preview organizing files",
           "description": "Shows how files would be renamed and moved with the user's naming settings (the whole library, an album or an artist). Changes nothing. Returns a preview_id for organize_files.",
           "inputSchema": {"type": "object", "properties": {
             "album": {"type": "string", "description": "Only this album's files."},
             "artist": {"type": "string", "description": "Only this artist's files (or the album's artist)."}}},
           "annotations": {"readOnlyHint": true}},
          {"name": "organize_files", "title": "Organize files",
           "description": "Renames and moves the files as preview_organize showed. Call only after the user agreed. Undo with undo_last_file_operation.",
           "inputSchema": {"type": "object", "properties": {
             "preview_id": {"type": "string", "description": "The preview_id from preview_organize."}}, "required": ["preview_id"]},
           "annotations": {"readOnlyHint": false, "destructiveHint": true, "idempotentHint": false}},
          {"name": "undo_last_file_operation", "title": "Undo the last import or organize",
           "description": "Undoes the last import (its songs leave the library, archives come back from the Trash) or organize (files get their old names).",
           "inputSchema": {"type": "object", "properties": {}},
           "annotations": {"readOnlyHint": false, "destructiveHint": true, "idempotentHint": false}},
          {"name": "rescan_library", "title": "Rescan the library",
           "description": "Checks every file of every library folder and reports what was added, updated and removed.",
           "inputSchema": {"type": "object", "properties": {}},
           "annotations": {"readOnlyHint": false, "destructiveHint": false, "idempotentHint": true}},
          {"name": "play", "title": "Play",
           "description": "Plays one song, the songs a search finds, an album, an artist or a playlist (names match ignoring case; a part is enough when only one thing matches). With nothing, resumes. For a song by an artist, give song and artist: the artist only narrows the song down.",
           "inputSchema": {"type": "object", "properties": {
             "song": {"type": "string", "description": "One song, by its title (with artist or album to pick the right one)."},
             "query": {"type": "string", "description": "Play the songs a search finds (artist and album narrow them down)."},
             "song_ids": {"type": "array", "items": {"type": "integer"}, "description": "Play these songs (ids from search_library), in this order."},
             "album": {"type": "string", "description": "An album (with artist to tell albums apart), when no song or query is given."},
             "artist": {"type": "string", "description": "Every song of the artist when alone; otherwise narrows down song, query or album."},
             "playlist": {"type": "string"},
             "shuffle": {"type": "boolean"}}},
           "annotations": {"readOnlyHint": false, "destructiveHint": false}},
          {"name": "list_playlists", "title": "List playlists",
           "description": "The library's playlists, with their song counts (smart playlists fill themselves from rules). The user can change playlists in the app at any time: list them again rather than relying on an earlier result.",
           "inputSchema": {"type": "object", "properties": {}},
           "annotations": {"readOnlyHint": true}},
          {"name": "create_playlist", "title": "Create a playlist",
           "description": "Creates a playlist of songs from the library, in the order given. Find the songs with search_library first: it gives their ids. Songs not in the library cannot be added.",
           "inputSchema": {"type": "object", "properties": {
             "name": {"type": "string", "description": "The playlist's name."},
             "song_ids": {"type": "array", "items": {"type": "integer"}, "description": "Song ids from search_library, in playlist order."}}, "required": ["name", "song_ids"]},
           "annotations": {"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false}},
          {"name": "add_to_playlist", "title": "Add to a playlist",
           "description": "Adds songs (ids from search_library) at the end of an existing playlist, found by name.",
           "inputSchema": {"type": "object", "properties": {
             "playlist": {"type": "string", "description": "The playlist's name."},
             "song_ids": {"type": "array", "items": {"type": "integer"}, "description": "Song ids from search_library."}}, "required": ["playlist", "song_ids"]},
           "annotations": {"readOnlyHint": false, "destructiveHint": false, "idempotentHint": false}},
          {"name": "playback_control", "title": "Control playback",
           "description": "Pause, resume, toggle (play or pause), next, previous or stop.",
           "inputSchema": {"type": "object", "properties": {
             "action": {"type": "string", "enum": ["pause", "resume", "toggle", "next", "previous", "stop"]}}, "required": ["action"]},
           "annotations": {"readOnlyHint": false, "destructiveHint": false}},
          {"name": "now_playing", "title": "Now playing",
           "description": "The song playing now (or paused), with its position. Changes as the music plays and as the user uses the app: call it again each time the user asks.",
           "inputSchema": {"type": "object", "properties": {}},
           "annotations": {"readOnlyHint": true}}
        ]
        """#
        return (try? JSONDecoder().decode([JSONValue].self, from: Data(json.utf8))) ?? []
    }()
}
