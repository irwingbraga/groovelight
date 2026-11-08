using System.Diagnostics;
using System.Reflection;
using System.Text;
using System.Text.Json;
using Groovelight.ControlKit;

namespace Groovelight.Cli;

/// <summary>
/// <c>groovelight</c>: controls Groovelight from the terminal. Commands go to the running app (it starts when needed), so
/// the library, undo and the app's windows stay in step. <c>--json</c> on any command prints a result programs can read.
/// </summary>
public static class Program
{
    private sealed record Command(string Name, string Usage, string Summary, Func<string[], int> Run, string? Details = null);

    private static readonly Command[] Commands =
    [
        new("status", "status [--json]", "Show the library's size, its folders and what is playing.", args => Simple(args, new StatusRequest())),
        new("search", "search <words...> [--limit N] [--json]", "Search the library for artists, albums and songs.", Search),
        new("import", "import <paths...> [--folder NAME] [--copy] [--no-online] [--no-tags] [--trash-archives] [--dry-run] [--json]",
            "Import songs, folders or archives (zip, 7z, rar, tar) into the library.", Import,
            "Songs are identified on MusicBrainz, tagged and named like Organize Library Files names them, then moved into the library folder set in Settings, Library (--copy keeps the originals). --no-online keeps the files' own tags, --no-tags leaves the files' tags alone, --trash-archives moves each archive to the Recycle Bin once imported. Preview with --dry-run; undo with `groovelight undo`."),
        new("fix-metadata", "fix-metadata [--album TITLE] [--artist NAME] [--songs IDS...] [--search-album TEXT] [--search-artist TEXT] [--release ID] [--auto] [--include-unmatched] [--no-cover] [--write-tags | --no-write-tags] [--dry-run] [--json]",
            "Fix an album's tags with a release found on MusicBrainz.", FixMetadata,
            "Without --release, lists the releases found; preview the best one with --dry-run, then apply it with --release ID (or --auto to take the best match)."),
        new("organize", "organize [--album TITLE] [--artist NAME] [--dry-run] [--json]", "Rename and move files with the naming settings (Settings, Files).", Organize),
        new("undo", "undo [--json]", "Undo the last import or organize.", args => Simple(args, new UndoRequest())),
        new("rescan", "rescan [--json]", "Check every file of every library folder.", args => Simple(args, new RescanRequest())),
        new("play", "play [words...] [--song TITLE] [--album TITLE] [--artist NAME] [--playlist NAME] [--songs IDS...] [--shuffle] [--json]",
            "Play a song, what a search finds, an album, an artist or a playlist (or resume).", Play,
            "Names match ignoring case and accents; a part of the name is enough when only one thing matches. With --song or a search, --artist and --album narrow it down: play --song \"Karma Police\" --artist Radiohead."),
        new("pause", "pause [--json]", "Pause.", args => Simple(args, new PlaybackRequest(PlaybackAction.Pause))),
        new("resume", "resume [--json]", "Resume playing.", args => Simple(args, new PlaybackRequest(PlaybackAction.Resume))),
        new("play-pause", "play-pause [--json]", "Play or pause.", args => Simple(args, new PlaybackRequest(PlaybackAction.Toggle))),
        new("next", "next [--json]", "Skip to the next song.", args => Simple(args, new PlaybackRequest(PlaybackAction.Next))),
        new("previous", "previous [--json]", "Go back to the previous song.", args => Simple(args, new PlaybackRequest(PlaybackAction.Previous))),
        new("stop", "stop [--json]", "Stop playing.", args => Simple(args, new PlaybackRequest(PlaybackAction.Stop))),
        new("now-playing", "now-playing [--json]", "Show what is playing.", args => Simple(args, new NowPlayingRequest())),
        new("playlists", "playlists [--json]", "List the playlists.", args => Simple(args, new ListPlaylistsRequest())),
        new("today", "today [--json]", "Show Song, Album and Artist of the Day, and why each was picked.", args => Simple(args, new TodayRequest())),
        new("stats", "stats [--range week|month|year|all] [--json]", "Show what you listened to: time, plays, top songs, albums, artists and genres.", Stats),
        new("create-playlist", "create-playlist <name> --songs IDS... [--json]", "Create a playlist of songs, in order.", CreatePlaylist,
            "Song ids come from `groovelight search`: create-playlist \"Gino's Best\" --songs 2798 2765 2801"),
        new("add-to-playlist", "add-to-playlist <playlist> --songs IDS... [--json]", "Add songs at the end of a playlist.", AddToPlaylist),
        new("mcp", "mcp", "Serve Groovelight to Claude and other AI tools (Model Context Protocol, over stdin and stdout).", Mcp,
            "Claude Code: claude mcp add groovelight -- groovelight mcp\nClaude Desktop: install Groovelight.mcpb from the latest release, or add {\"mcpServers\": {\"groovelight\": {\"command\": \"<path of groovelight.com>\", \"args\": [\"mcp\"]}}} to its claude_desktop_config.json.\nChanges to files always go through a preview the user sees first."),
    ];

    public static int Main(string[] args)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        Console.InputEncoding = new UTF8Encoding(false);
        if (args.Length == 0 || args[0] is "--help" or "-h" or "help")
        {
            if (args.Length > 1 && Commands.FirstOrDefault(command => command.Name == args[1]) is { } topic) PrintHelp(topic);
            else PrintHelp();
            return 0;
        }
        if (args[0] == "--version")
        {
            Console.WriteLine($"groovelight {Version}");
            return 0;
        }
        if (Commands.FirstOrDefault(command => command.Name == args[0]) is not { } chosen)
        {
            PrintError($"Unknown command: {args[0]}. See groovelight --help.");
            return 64;
        }
        var rest = args[1..];
        if (rest.Contains("--help") || rest.Contains("-h"))
        {
            PrintHelp(chosen);
            return 0;
        }
        try
        {
            return chosen.Run(rest);
        }
        catch (UsageException error)
        {
            PrintError($"Error: {error.Message}\nUsage: groovelight {chosen.Usage}");
            return 64;
        }
        catch (ControlException error)
        {
            PrintError($"Error: {error.Message}");
            return 1;
        }
    }

    private static string Version =>
        typeof(Program).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "0";

    private static void PrintHelp()
    {
        Console.WriteLine("groovelight: control Groovelight, the music player, from the terminal.");
        Console.WriteLine();
        Console.WriteLine("Commands go to the running app (it starts when needed), so the library, undo and the app's windows stay in step. Add --json to any command for a result programs can read.");
        Console.WriteLine();
        Console.WriteLine("Commands:");
        foreach (var command in Commands) Console.WriteLine($"  {command.Name,-16}{command.Summary}");
        Console.WriteLine();
        Console.WriteLine("See groovelight <command> --help for a command's options.");
    }

    private static void PrintHelp(Command command)
    {
        Console.WriteLine(command.Summary);
        Console.WriteLine();
        Console.WriteLine($"Usage: groovelight {command.Usage}");
        if (command.Details is { } details)
        {
            Console.WriteLine();
            Console.WriteLine(details);
        }
    }

    // MARK: Commands

    private static int Simple(string[] args, ControlRequest request)
    {
        var parsed = new Arguments(args, ["json"], []);
        if (parsed.Positional.Count > 0) throw new UsageException($"Unexpected argument: {parsed.Positional[0]}");
        return Execute(request, parsed.Flag("json"));
    }

    private static int Search(string[] args)
    {
        var parsed = new Arguments(args, ["json"], ["limit"]);
        if (parsed.Positional.Count == 0) throw new UsageException("Say what to look for.");
        return Execute(new SearchRequest(string.Join(' ', parsed.Positional), parsed.Integer("limit", 10)), parsed.Flag("json"));
    }

    private static int Import(string[] args)
    {
        var parsed = new Arguments(args, ["json", "copy", "no-online", "no-tags", "trash-archives", "dry-run"], ["folder"]);
        if (parsed.Positional.Count == 0) throw new UsageException("Give the songs, folders or archives to import.");
        var paths = parsed.Positional.Select(path =>
        {
            var full = Path.GetFullPath(path);
            return File.Exists(full) || Directory.Exists(full) ? full : throw new ControlException($"No such file or folder: {path}");
        }).ToList();
        ImportPaths.Check(paths);
        return Execute(new ImportRequest(new ImportOptions
        {
            Paths = paths, Folder = parsed.Option("folder"), Copy = parsed.Flag("copy"), UseOnlineMetadata = !parsed.Flag("no-online"),
            WriteTags = !parsed.Flag("no-tags"), TrashArchives = parsed.Flag("trash-archives"), DryRun = parsed.Flag("dry-run"),
        }), parsed.Flag("json"));
    }

    private static int FixMetadata(string[] args)
    {
        var parsed = new Arguments(args, ["json", "auto", "include-unmatched", "no-cover", "write-tags", "no-write-tags", "dry-run"],
            ["album", "artist", "search-album", "search-artist", "release"], ["songs"]);
        var songs = parsed.Ids("songs");
        if (parsed.Option("album") is null && parsed.Option("artist") is null && songs.Count == 0) throw new UsageException("Say which songs: --album, --artist or --songs.");
        return Execute(new FixMetadataRequest(new FixMetadataOptions
        {
            Album = parsed.Option("album"), Artist = parsed.Option("artist"), SongIds = songs.Count == 0 ? null : songs,
            SearchAlbum = parsed.Option("search-album"), SearchArtist = parsed.Option("search-artist"), Release = parsed.Option("release"),
            Auto = parsed.Flag("auto"), IncludeUnmatched = parsed.Flag("include-unmatched"), Cover = !parsed.Flag("no-cover"),
            WriteTags = parsed.Flag("write-tags") ? true : parsed.Flag("no-write-tags") ? false : null, DryRun = parsed.Flag("dry-run"),
        }), parsed.Flag("json"));
    }

    private static int Organize(string[] args)
    {
        var parsed = new Arguments(args, ["json", "dry-run"], ["album", "artist"]);
        return Execute(new OrganizeRequest(new OrganizeOptions { Album = parsed.Option("album"), Artist = parsed.Option("artist"), DryRun = parsed.Flag("dry-run") }), parsed.Flag("json"));
    }

    private static int Play(string[] args)
    {
        var parsed = new Arguments(args, ["json", "shuffle"], ["album", "artist", "playlist", "song"], ["songs"]);
        var songs = parsed.Ids("songs");
        return Execute(new PlayRequest(new PlayOptions
        {
            SongIds = songs.Count == 0 ? null : songs, Album = parsed.Option("album"), Artist = parsed.Option("artist"), Playlist = parsed.Option("playlist"),
            Song = parsed.Option("song"), Query = parsed.Positional.Count == 0 ? null : string.Join(' ', parsed.Positional), Shuffle = parsed.Flag("shuffle"),
        }), parsed.Flag("json"));
    }

    private static int Stats(string[] args)
    {
        var parsed = new Arguments(args, ["json"], ["range"]);
        var range = parsed.Option("range") ?? "month";
        if (range is not ("week" or "month" or "year" or "all")) throw new UsageException("--range is week, month, year or all.");
        return Execute(new ListeningStatsRequest(range), parsed.Flag("json"));
    }

    private static int CreatePlaylist(string[] args)
    {
        var parsed = new Arguments(args, ["json"], [], ["songs"]);
        if (parsed.Positional.Count != 1) throw new UsageException("Give the playlist's name (in quotes when it has spaces).");
        return Execute(new CreatePlaylistRequest(parsed.Positional[0], parsed.Ids("songs")), parsed.Flag("json"));
    }

    private static int AddToPlaylist(string[] args)
    {
        var parsed = new Arguments(args, ["json"], [], ["songs"]);
        if (parsed.Positional.Count != 1) throw new UsageException("Give the playlist's name (in quotes when it has spaces).");
        return Execute(new AddToPlaylistRequest(parsed.Positional[0], parsed.Ids("songs")), parsed.Flag("json"));
    }

    private static int Mcp(string[] args)
    {
        if (args.Length > 0) throw new UsageException($"Unexpected argument: {args[0]}");
        var server = new McpServer(Version, (request, progress) =>
        {
            EnsureRunning();
            return ControlClient.Run(request, progress);
        });
        server.Run(Console.In, Console.Out);
        return 0;
    }

    // MARK: Reaching the app

    /// <summary>Starts Groovelight (next to this tool) when it is not running, and waits until it answers.</summary>
    private static void EnsureRunning()
    {
        if (ControlClient.IsAvailable()) return;
        var app = Path.Combine(AppContext.BaseDirectory, "Groovelight.exe");
        if (!File.Exists(app)) throw new ControlException($"Groovelight is not running, and it is not next to this tool ({app}).");
        PrintError("Starting Groovelight…");
        try
        {
            Process.Start(new ProcessStartInfo(app) { UseShellExecute = true, WindowStyle = ProcessWindowStyle.Minimized, WorkingDirectory = AppContext.BaseDirectory });
        }
        catch (System.ComponentModel.Win32Exception error)
        {
            throw new ControlException($"Could not start Groovelight: {error.Message}");
        }
        var deadline = DateTime.UtcNow.AddSeconds(30);
        while (!ControlClient.IsAvailable())
        {
            if (DateTime.UtcNow > deadline) throw new ControlException("Groovelight did not start in time.");
            Thread.Sleep(200);
        }
    }

    /// <summary>Sends the request, shows a job's progress, and prints the result (or its JSON).</summary>
    private static int Execute(ControlRequest request, bool json)
    {
        EnsureRunning();
        var progress = new ProgressLine();
        var reply = ControlClient.Run(request, update =>
        {
            foreach (var message in update.Messages) progress.Print(message);
            if (update.Progress is { } current) progress.Show(current);
        });
        progress.Clear();
        foreach (var message in reply.Messages) PrintError(message);
        var pretty = new JsonSerializerOptions(ControlPipe.Json) { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };
        if (json)
        {
            var output = reply.Error is null
                ? reply.Data?.ToJsonString(pretty) ?? "null"
                : new System.Text.Json.Nodes.JsonObject { ["data"] = reply.Data?.DeepClone(), ["error"] = reply.Error }.ToJsonString(pretty);
            Console.WriteLine(output);
        }
        else if (reply.Summary is { } summary)
        {
            Console.WriteLine(summary);
        }
        if (reply.Error is null) return 0;
        Console.Out.Flush();
        if (!json) PrintError($"Error: {reply.Error}");
        return 1;
    }

    internal static void PrintError(string text) => Console.Error.WriteLine(text);
}

/// <summary>A job's progress on one line of the terminal (or a line per step when the output is redirected).</summary>
internal sealed class ProgressLine
{
    private readonly bool isTerminal = !Console.IsErrorRedirected;
    private string? lastLabel;
    private bool isShowing;

    public void Show(JobProgress progress)
    {
        var count = progress.Total > 0 ? $" {progress.Done} of {progress.Total}" : "";
        if (isTerminal)
        {
            Console.Error.Write($"\r\u001b[K{progress.Label}…{count}");
            isShowing = true;
        }
        else if (progress.Label != lastLabel)
        {
            Program.PrintError($"{progress.Label}…");
        }
        lastLabel = progress.Label;
    }

    public void Print(string line)
    {
        Clear();
        Program.PrintError(line);
    }

    public void Clear()
    {
        if (!isShowing) return;
        Console.Error.Write("\r\u001b[K");
        isShowing = false;
    }
}
