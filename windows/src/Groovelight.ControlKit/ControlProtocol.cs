using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Groovelight.ControlKit;

/// <summary>
/// The command line tool (and AI connectors built on it) controls the running app: requests and replies travel as JSON
/// through a named pipe only the same Windows user can open. Each library (data folder) has its own pipe, like it has
/// its own copy of the app.
/// </summary>
public static class ControlPipe
{
    /// <summary>Bumped when requests or replies change in a way an older app or tool cannot read.</summary>
    public const int ProtocolVersion = 1;

    /// <summary>
    /// The pipe of the app using <paramref name="dataDirectory"/> (empty: the default library). <c>GROOVELIGHT_PORT</c>
    /// overrides it.
    /// </summary>
    public static string Name(string? dataDirectory = null)
    {
        if (Environment.GetEnvironmentVariable("GROOVELIGHT_PORT") is { Length: > 0 } name) return name;
        var data = dataDirectory ?? Environment.GetEnvironmentVariable("GROOVELIGHT_DATA") ?? "";
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(data.ToLowerInvariant())))[..16];
        return $"Groovelight.Control.{Environment.UserName}.{hash}";
    }

    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };
}

[JsonPolymorphic(TypeDiscriminatorPropertyName = "type")]
[JsonDerivedType(typeof(StatusRequest), "status")]
[JsonDerivedType(typeof(SearchRequest), "search")]
[JsonDerivedType(typeof(ImportRequest), "import")]
[JsonDerivedType(typeof(FixMetadataRequest), "fixMetadata")]
[JsonDerivedType(typeof(OrganizeRequest), "organize")]
[JsonDerivedType(typeof(UndoRequest), "undo")]
[JsonDerivedType(typeof(RescanRequest), "rescan")]
[JsonDerivedType(typeof(PlayRequest), "play")]
[JsonDerivedType(typeof(PlaybackRequest), "playback")]
[JsonDerivedType(typeof(ListPlaylistsRequest), "listPlaylists")]
[JsonDerivedType(typeof(CreatePlaylistRequest), "createPlaylist")]
[JsonDerivedType(typeof(AddToPlaylistRequest), "addToPlaylist")]
[JsonDerivedType(typeof(NowPlayingRequest), "nowPlaying")]
[JsonDerivedType(typeof(PollRequest), "poll")]
[JsonDerivedType(typeof(CancelRequest), "cancel")]
public abstract record ControlRequest;

/// <summary>App version, library size, folders, what is playing.</summary>
public sealed record StatusRequest : ControlRequest;
public sealed record SearchRequest(string Query, int Limit) : ControlRequest;
public sealed record ImportRequest(ImportOptions Options) : ControlRequest;
public sealed record FixMetadataRequest(FixMetadataOptions Options) : ControlRequest;
public sealed record OrganizeRequest(OrganizeOptions Options) : ControlRequest;
/// <summary>Undoes the last import or organize.</summary>
public sealed record UndoRequest : ControlRequest;
/// <summary>Checks every file of every library folder.</summary>
public sealed record RescanRequest : ControlRequest;
public sealed record PlayRequest(PlayOptions Options) : ControlRequest;
public sealed record PlaybackRequest(PlaybackAction Action) : ControlRequest;
public sealed record ListPlaylistsRequest : ControlRequest;
/// <summary>A new playlist of these songs, in this order.</summary>
public sealed record CreatePlaylistRequest(string Name, IReadOnlyList<long> SongIds) : ControlRequest;
/// <summary>Adds songs at the end of a playlist (by name).</summary>
public sealed record AddToPlaylistRequest(string Playlist, IReadOnlyList<long> SongIds) : ControlRequest;
public sealed record NowPlayingRequest : ControlRequest;
/// <summary>What a job did since the last poll, and its result when it is done.</summary>
public sealed record PollRequest(string Job) : ControlRequest;
public sealed record CancelRequest(string Job) : ControlRequest;

public sealed record ImportOptions
{
    public required IReadOnlyList<string> Paths { get; init; }
    /// <summary>The library folder to import into (its name or path); the one set in Settings, Library when null.</summary>
    public string? Folder { get; init; }
    public bool Copy { get; init; }
    public bool UseOnlineMetadata { get; init; } = true;
    public bool WriteTags { get; init; } = true;
    /// <summary>Moves archives to the Recycle Bin once everything from them is imported.</summary>
    public bool TrashArchives { get; init; }
    public bool DryRun { get; init; }
}

public sealed record FixMetadataOptions
{
    /// <summary>The songs to fix: an album (by title, with its artist to tell albums apart), or song ids.</summary>
    public string? Album { get; init; }
    public string? Artist { get; init; }
    public IReadOnlyList<long>? SongIds { get; init; }
    /// <summary>What to search MusicBrainz for, instead of the songs' own album and artist ("" leaves the field out).</summary>
    public string? SearchAlbum { get; init; }
    public string? SearchArtist { get; init; }
    /// <summary>The MusicBrainz release to apply; without it, <see cref="Auto"/> takes the best candidate.</summary>
    public string? Release { get; init; }
    public bool Auto { get; init; }
    /// <summary>Also gives the album's details to songs that are not on the release.</summary>
    public bool IncludeUnmatched { get; init; }
    public bool Cover { get; init; } = true;
    /// <summary>Writes the tags into the files too (the setting in Settings, Metadata when null).</summary>
    public bool? WriteTags { get; init; }
    public bool DryRun { get; init; }
}

public sealed record OrganizeOptions
{
    /// <summary>Only these songs' files (an album, an artist); the whole library when both are null.</summary>
    public string? Album { get; init; }
    public string? Artist { get; init; }
    public bool DryRun { get; init; }
}

public sealed record PlayOptions
{
    /// <summary>
    /// What to play: songs by id (in this order), an album, an artist, a playlist or a song, matched by name; or the
    /// first songs a search finds.
    /// </summary>
    public IReadOnlyList<long>? SongIds { get; init; }
    public string? Album { get; init; }
    public string? Artist { get; init; }
    public string? Playlist { get; init; }
    public string? Song { get; init; }
    public string? Query { get; init; }
    public bool Shuffle { get; init; }
}

public enum PlaybackAction { Pause, Resume, Toggle, Next, Previous, Stop }

/// <summary>A reply: a result (text for people, data for programs), an error, or a job to poll.</summary>
public sealed record ControlReply
{
    /// <summary>What happened, for people.</summary>
    public string? Summary { get; init; }
    /// <summary>The same for programs.</summary>
    public JsonNode? Data { get; init; }
    public string? Error { get; init; }
    /// <summary>A job that keeps running in the app: poll it until <see cref="Finished"/>.</summary>
    public string? Job { get; init; }
    public bool Finished { get; init; } = true;
    /// <summary>Lines a job printed since the last poll.</summary>
    public IReadOnlyList<string> Messages { get; init; } = [];
    public JobProgress? Progress { get; init; }

    public static ControlReply Failure(string message) => new() { Error = message };
}

public sealed record JobProgress(string Label, int Done, int Total);

/// <summary>A request with the protocol version it was written for.</summary>
internal sealed record Envelope(int Version, ControlRequest Request);

/// <summary>A failure to report to the user as is (the tool's ToolError, the app's ControlError).</summary>
public sealed class ControlException(string message) : Exception(message);
