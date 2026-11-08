using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Groovelight.ControlKit;

/// <summary>
/// Groovelight as an MCP server (Model Context Protocol), for Claude and other AI tools: <c>groovelight mcp</c> speaks
/// JSON-RPC over stdin and stdout, and each tool call becomes a request to the app.
///
/// Changes to files go in two steps: a preview tool shows what would happen and returns a <c>preview_id</c>, and the
/// matching apply tool takes only that id, so a change is always one the user could see first.
/// </summary>
public sealed class McpServer(string version, Func<ControlRequest, Action<ControlReply>, ControlReply> execute)
{
    public static readonly IReadOnlyList<string> SupportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];

    private static readonly JsonSerializerOptions Output = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
    /// <summary>What each preview would apply.</summary>
    private readonly Dictionary<string, ControlRequest> previews = [];

    /// <summary>Reads messages from <paramref name="input"/> until it closes, answering on <paramref name="output"/>.</summary>
    public void Run(TextReader input, TextWriter output)
    {
        void Write(JsonNode message)
        {
            lock (output)
            {
                output.Write(message.ToJsonString(Output) + "\n");
                output.Flush();
            }
        }
        while (input.ReadLine() is { } line)
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            JsonNode? reply;
            try
            {
                reply = JsonNode.Parse(line) is { } message ? Handle(message, Write) : Error(null, -32700, "Parse error");
            }
            catch (JsonException)
            {
                reply = Error(null, -32700, "Parse error");
            }
            if (reply is not null) Write(reply);
        }
    }

    /// <summary>The reply to one message (null for notifications); <paramref name="notify"/> sends progress while a tool runs.</summary>
    public JsonNode? Handle(JsonNode message, Action<JsonNode> notify)
    {
        if (message is not JsonObject request || request["method"]?.GetValueKind() != JsonValueKind.String) return null;
        var method = request["method"]!.GetValue<string>();
        var id = request["id"];
        if (id is null || id.GetValueKind() == JsonValueKind.Null) return null;
        var parameters = request["params"] as JsonObject ?? [];
        switch (method)
        {
            case "initialize":
                var requested = Text(parameters["protocolVersion"]) ?? "";
                return Result(id, new JsonObject
                {
                    ["protocolVersion"] = SupportedVersions.Contains(requested) ? requested : SupportedVersions[1],
                    ["capabilities"] = new JsonObject { ["tools"] = new JsonObject { ["listChanged"] = false } },
                    ["serverInfo"] = new JsonObject { ["name"] = "groovelight", ["title"] = "Groovelight", ["version"] = version },
                    ["instructions"] = Instructions,
                });
            case "ping":
                return Result(id, new JsonObject());
            case "tools/list":
                return Result(id, new JsonObject { ["tools"] = Tools() });
            case "tools/call":
                if (Text(parameters["name"]) is not { } name) return Error(id, -32602, "Missing tool name");
                var token = parameters["_meta"]?["progressToken"];
                var step = 0;
                var last = "";
                var result = Call(name, parameters["arguments"] as JsonObject ?? [], update =>
                {
                    if (token is null || token.GetValueKind() == JsonValueKind.Null || update.Progress is not { } progress) return;
                    var count = progress.Total > 0 ? $" ({progress.Done} of {progress.Total})" : "";
                    // Only when something changed: jobs are polled several times a second.
                    if (progress.Label + count == last) return;
                    last = progress.Label + count;
                    step++;
                    notify(new JsonObject
                    {
                        ["jsonrpc"] = "2.0", ["method"] = "notifications/progress",
                        ["params"] = new JsonObject { ["progressToken"] = token.DeepClone(), ["progress"] = step, ["message"] = progress.Label + count },
                    });
                });
                return Result(id, result);
            default:
                return Error(id, -32601, $"Method not found: {method}");
        }
    }

    // MARK: Tools

    private JsonNode Call(string name, JsonObject arguments, Action<ControlReply> progress)
    {
        try
        {
            switch (name)
            {
                case "library_status": return Snapshot(new StatusRequest(), progress);
                case "search_library":
                    if (Text(arguments["query"]) is not { } query) return ToolError("Give a query.");
                    return Snapshot(new SearchRequest(query, Integer(arguments["limit"]) ?? 20), progress);
                case "preview_import":
                {
                    var paths = Strings(arguments["paths"]).Select(path => Environment.ExpandEnvironmentVariables(path)).ToList();
                    if (paths.Count == 0) return ToolError("Give the paths of the songs, folders or archives to import.");
                    ImportPaths.Check(paths);
                    var options = new ImportOptions
                    {
                        Paths = paths, Folder = Text(arguments["folder"]), Copy = Bool(arguments["copy"]) ?? false,
                        UseOnlineMetadata = Bool(arguments["use_online_metadata"]) ?? true, WriteTags = Bool(arguments["write_tags"]) ?? true,
                        TrashArchives = Bool(arguments["trash_archives"]) ?? false, DryRun = true,
                    };
                    var reply = execute(new ImportRequest(options), progress);
                    return Preview(reply, new ImportRequest(options with { DryRun = false }), "import_music");
                }
                case "preview_fix_metadata":
                {
                    var options = new FixMetadataOptions
                    {
                        Album = Text(arguments["album"]), Artist = Text(arguments["artist"]),
                        SongIds = arguments["song_ids"] is null ? null : Ids(arguments["song_ids"]),
                        SearchAlbum = Text(arguments["search_album"]), SearchArtist = Text(arguments["search_artist"]), Release = Text(arguments["release"]),
                        IncludeUnmatched = Bool(arguments["include_unmatched"]) ?? false, Cover = Bool(arguments["cover"]) ?? true,
                        WriteTags = Bool(arguments["write_tags"]), DryRun = true,
                    };
                    if (options.Album is null && options.Artist is null && options.SongIds is not { Count: > 0 })
                        return ToolError("Say which songs: album (with artist when several albums share the title), artist, or song_ids.");
                    var reply = execute(new FixMetadataRequest(options), progress);
                    // Apply exactly the release that was previewed.
                    if (Text(reply.Data?["release"]?["id"]) is not { } release) return ToolResult(reply);
                    return Preview(reply, new FixMetadataRequest(options with { Release = release, DryRun = false }), "apply_fix_metadata");
                }
                case "preview_organize":
                {
                    var options = new OrganizeOptions { Album = Text(arguments["album"]), Artist = Text(arguments["artist"]), DryRun = true };
                    var reply = execute(new OrganizeRequest(options), progress);
                    if (reply.Data?["renames"] is not JsonArray { Count: > 0 }) return ToolResult(reply);
                    return Preview(reply, new OrganizeRequest(options with { DryRun = false }), "organize_files");
                }
                case "import_music" or "apply_fix_metadata" or "organize_files":
                {
                    if (Text(arguments["preview_id"]) is not { } id || !previews.TryGetValue(id, out var request))
                        return ToolError("Unknown preview_id. Run the matching preview tool first and show the user what it found.");
                    if (ApplyTool(request) != name) return ToolError($"That preview_id belongs to {ApplyTool(request)}.");
                    if (request is ImportRequest import) ImportPaths.Check(import.Options.Paths);
                    var reply = execute(request, progress);
                    if (reply.Error is null) previews.Remove(id);
                    return ToolResult(reply);
                }
                case "undo_last_file_operation": return ToolResult(execute(new UndoRequest(), progress));
                case "rescan_library": return ToolResult(execute(new RescanRequest(), progress));
                case "list_playlists": return Snapshot(new ListPlaylistsRequest(), progress);
                case "create_playlist":
                    if (Text(arguments["name"]) is not { } playlistName) return ToolError("Give the playlist a name.");
                    return ToolResult(execute(new CreatePlaylistRequest(playlistName, Ids(arguments["song_ids"])), progress));
                case "add_to_playlist":
                    if (Text(arguments["playlist"]) is not { } playlist) return ToolError("Say which playlist (its name).");
                    return ToolResult(execute(new AddToPlaylistRequest(playlist, Ids(arguments["song_ids"])), progress));
                case "play":
                {
                    var ids = Ids(arguments["song_ids"]);
                    return ToolResult(execute(new PlayRequest(new PlayOptions
                    {
                        SongIds = ids.Count == 0 ? null : ids, Album = Text(arguments["album"]), Artist = Text(arguments["artist"]),
                        Playlist = Text(arguments["playlist"]), Song = Text(arguments["song"]), Query = Text(arguments["query"]),
                        Shuffle = Bool(arguments["shuffle"]) ?? false,
                    }), progress));
                }
                case "playback_control":
                    if (!Enum.TryParse<PlaybackAction>(Text(arguments["action"]), ignoreCase: true, out var action) || int.TryParse(Text(arguments["action"]), out _))
                        return ToolError("action must be one of: " + string.Join(", ", Enum.GetNames<PlaybackAction>().Select(value => value.ToLowerInvariant())) + ".");
                    return ToolResult(execute(new PlaybackRequest(action), progress));
                case "now_playing": return Snapshot(new NowPlayingRequest(), progress);
                case "todays_picks": return Snapshot(new TodayRequest(), progress);
                case "listening_stats": return Snapshot(new ListeningStatsRequest(Text(arguments["range"]) ?? "month"), progress);
                default: return ToolError($"Unknown tool: {name}");
            }
        }
        catch (ControlException error)
        {
            return ToolError(error.Message);
        }
    }

    /// <summary>
    /// A result about state that changes outside the conversation (the user also plays and imports in the app), with the
    /// time it was read, so the model can tell how old it is.
    /// </summary>
    private JsonNode Snapshot(ControlRequest request, Action<ControlReply> progress) => Stamped(ToolResult(execute(request, progress)), DateTimeOffset.Now);

    internal static JsonNode Stamped(JsonNode result, DateTimeOffset date)
    {
        if (result is not JsonObject fields || fields.ContainsKey("isError")) return result;
        var time = date.ToString("yyyy-MM-dd'T'HH:mm:sszzz", CultureInfo.InvariantCulture);
        if (fields["structuredContent"] is not JsonObject data)
        {
            data = [];
            fields["structuredContent"] = data;
        }
        data["as_of"] = time;
        if (fields["content"] is JsonArray { Count: > 0 } content && content[0] is JsonObject first && Text(first["text"]) is { } text)
            first["text"] = text + $"\n\nAs of {time}.";
        return fields;
    }

    /// <summary>A preview's result, with the id its apply tool takes (none when it failed).</summary>
    private JsonNode Preview(ControlReply reply, ControlRequest applying, string tool)
    {
        if (reply.Error is not null) return ToolResult(reply);
        var id = "p" + Guid.NewGuid().ToString("N")[..8];
        previews[id] = applying;
        var data = new JsonObject { ["preview_id"] = id };
        if (reply.Data is { } existing) data["preview"] = existing.DeepClone();
        return ToolResult(reply with
        {
            Summary = (reply.Summary ?? "") + $"\n\npreview_id: {id} (show this to the user; apply with {tool} only after they agree)",
            Data = data,
        });
    }

    private static string ApplyTool(ControlRequest request) => request switch
    {
        ImportRequest => "import_music",
        FixMetadataRequest => "apply_fix_metadata",
        _ => "organize_files",
    };

    // MARK: Messages

    internal static JsonNode ToolResult(ControlReply reply)
    {
        var text = reply.Summary ?? "";
        if (reply.Messages.Count > 0) text = string.Join("\n", reply.Messages.Append(text));
        if (reply.Error is { } error) text = text.Length == 0 ? error : text + "\n\nError: " + error;
        var result = new JsonObject
        {
            ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = text.Length == 0 ? "Done." : text }),
        };
        if (reply.Data is { } data && data.GetValueKind() != JsonValueKind.Null)
            result["structuredContent"] = data is JsonObject ? data.DeepClone() : new JsonObject { ["result"] = data.DeepClone() };
        if (reply.Error is not null) result["isError"] = true;
        return result;
    }

    internal static JsonNode ToolError(string message) => new JsonObject
    {
        ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = message }),
        ["isError"] = true,
    };

    private static JsonNode Result(JsonNode id, JsonNode result) => new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id.DeepClone(), ["result"] = result };

    private static JsonNode Error(JsonNode? id, int code, string message) => new JsonObject
    {
        ["jsonrpc"] = "2.0", ["id"] = id?.DeepClone(), ["error"] = new JsonObject { ["code"] = code, ["message"] = message },
    };

    private static string? Text(JsonNode? node) => node is JsonValue value && value.GetValueKind() == JsonValueKind.String ? value.GetValue<string>() : null;

    private static bool? Bool(JsonNode? node) => node?.GetValueKind() switch
    {
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        _ => null,
    };

    private static int? Integer(JsonNode? node) =>
        node is JsonValue value && value.GetValueKind() == JsonValueKind.Number && value.TryGetValue<double>(out var number) ? (int)number : null;

    private static List<string> Strings(JsonNode? node) => node is JsonArray array ? array.Select(Text).OfType<string>().ToList() : [];

    private static List<long> Ids(JsonNode? node) =>
        node is JsonArray array
            ? array.Select(item => item is JsonValue value && value.GetValueKind() == JsonValueKind.Number && value.TryGetValue<double>(out var number) ? (long?)number : null)
                .OfType<long>().ToList()
            : [];

    // MARK: Descriptions

    public const string Instructions = """
        Groovelight is the user's music player and library on their PC. Use search_library and library_status to answer questions about the music. Changes to files go in two steps: call a preview tool (preview_import, preview_fix_metadata, preview_organize), show the user what it would change, and call the matching apply tool with its preview_id only after they agree. Imports and organizing can be undone with undo_last_file_operation; metadata fixes cannot. To make a playlist, find each song with search_library (songs come with their ids) and pass the ids to create_playlist, in order; play takes song_ids too. Paths are absolute Windows paths on the user's PC.

        The user also uses Groovelight directly, so the song playing, playlists and the library change outside this conversation. A result shows the state when the tool ran (its as_of time). Before answering about what is playing, playlists or what is in the library, call the tool again rather than relying on an earlier result.

        todays_picks gives Song, Album and Artist of the Day (as the app's Home shows them, the same all day) with their song ids for play; listening_stats summarizes what the user listened to (time, plays, top songs, albums, artists, genres) over a week, a month, a year or all time.
        """;

    public static JsonArray Tools() => (JsonNode.Parse(ToolsJson) as JsonArray)!;

    private const string ToolsJson = """
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
             "trash_archives": {"type": "boolean", "description": "Move archives to the Recycle Bin once imported (default false)."}}, "required": ["paths"]},
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
           "description": "Undoes the last import (its songs leave the library, archives come back from the Recycle Bin) or organize (files get their old names).",
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
           "annotations": {"readOnlyHint": true}},
          {"name": "todays_picks", "title": "Today's picks",
           "description": "Song, Album and Artist of the Day, picked from the user's listening (songs they used to love, loved songs they rarely play, new additions, release anniversaries), with why each was picked and its song ids (play them with play and song_ids). The picks stay the same all day.",
           "inputSchema": {"type": "object", "properties": {}},
           "annotations": {"readOnlyHint": true}},
          {"name": "listening_stats", "title": "Listening stats",
           "description": "What the user listened to over a range: listening time, plays, songs, songs new to them, their streak of days, top songs, albums and artists, genres, decades, plays by hour and weekday, and where (this computer, phones, Last.fm).",
           "inputSchema": {"type": "object", "properties": {
             "range": {"type": "string", "enum": ["week", "month", "year", "all"], "description": "The last 7 days, 30 days, 12 months, or all time (default month)."}}},
           "annotations": {"readOnlyHint": true}}
        ]
        """;
}
