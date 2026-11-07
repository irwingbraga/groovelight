using System.Text.Json;
using System.Text.Json.Serialization;

namespace Groovelight.Core.Library;

/// <summary>A library folder.</summary>
public sealed record LibraryRoot
{
    public long? Id { get; set; }
    public required string Path { get; set; }
    /// <summary>The Mac's security-scoped bookmark (empty on Windows, which reopens folders by path).</summary>
    public byte[] Bookmark { get; set; } = [];
    public DateTime AddedAt { get; set; } = DateTime.UtcNow;
    /// <summary>Last time anything in the folder was checked (a change was picked up, or a full scan).</summary>
    public DateTime? LastScanAt { get; set; }
    /// <summary>Change journal position up to which the folder's changes are in the library (null: a full scan is needed).</summary>
    public long? EventId { get; set; }
    /// <summary>The volume's change journal id when <see cref="EventId"/> was saved; a different one means it was reset.</summary>
    public string? EventsVolumeId { get; set; }
    /// <summary>Last time every file of the folder was checked.</summary>
    public DateTime? LastFullScanAt { get; set; }
}

/// <summary>A song in the library (one file, or one track of a CUE sheet).</summary>
public sealed record Track
{
    public long? Id { get; set; }
    public long RootId { get; set; }
    public required string Path { get; set; }
    public long FileSize { get; set; }
    public DateTime ModifiedAt { get; set; }

    public required string Title { get; set; }
    public string? Artist { get; set; }
    public string? Album { get; set; }
    public string? AlbumArtist { get; set; }
    public string? Composer { get; set; }
    public string? Genre { get; set; }
    public int? Year { get; set; }
    public int? TrackNumber { get; set; }
    public int? TrackTotal { get; set; }
    public int? DiscNumber { get; set; }
    public int? DiscTotal { get; set; }
    public bool IsCompilation { get; set; }
    public int? Bpm { get; set; }
    public string? Comment { get; set; }
    public string? Lyrics { get; set; }
    public string? MusicBrainzRecordingId { get; set; }
    public string? MusicBrainzReleaseId { get; set; }
    public double? ReplayGainTrackGain { get; set; }
    public double? ReplayGainAlbumGain { get; set; }

    public double Duration { get; set; }
    public string? Format { get; set; }
    public double? SampleRate { get; set; }
    public int? BitDepth { get; set; }
    public double? Bitrate { get; set; }
    public int? Channels { get; set; }

    public string? ArtworkHash { get; set; }
    /// <summary>Grouping key for albums: normalized album artist (or "compilation") and album title.</summary>
    public string AlbumKey { get; set; } = "";

    public int Rating { get; set; }
    public bool IsLoved { get; set; }
    public int PlayCount { get; set; }
    public int SkipCount { get; set; }
    public DateTime? LastPlayedAt { get; set; }
    public DateTime DateAdded { get; set; } = DateTime.UtcNow;

    /// <summary>JSON <see cref="TrackMetadata"/> fixes kept in the database (not written to the file), reapplied on every rescan.</summary>
    public byte[]? MetadataOverrides { get; set; }
    /// <summary>Lyrics fetched online (LRC or plain text); the file's own lyrics win.</summary>
    public string? FetchedLyrics { get; set; }
    /// <summary>Last online lyrics lookup, so misses are not retried on every play.</summary>
    public DateTime? LyricsCheckedAt { get; set; }
    /// <summary>Cover fetched online, used when the file and its folder have none.</summary>
    public string? FetchedArtworkHash { get; set; }
    /// <summary>When the song was loved, for Loved Songs' "most recently loved first" order.</summary>
    public DateTime? LovedAt { get; set; }
    /// <summary>For a track of a CUE sheet: the audio file holding it (<see cref="Path"/> is then "&lt;sheet path&gt;#NN").</summary>
    public string? AudioPath { get; set; }
    public double? StartTime { get; set; }
    public double? EndTime { get; set; }
    /// <summary>Measured integrated loudness (LUFS) for songs without ReplayGain tags, and when it was measured.</summary>
    public double? Loudness { get; set; }
    public DateTime? LoudnessCheckedAt { get; set; }

    /// <summary>The audio file (for a CUE track, the file holding the whole album).</summary>
    [JsonIgnore] public string FilePath => AudioPath ?? Path;

    /// <summary>A track of a CUE sheet (one of several songs in one audio file).</summary>
    [JsonIgnore] public bool IsCueTrack => AudioPath is not null;

    /// <summary>The cue sheet of a CUE track (the audio file itself for an embedded sheet).</summary>
    [JsonIgnore]
    public string? CueSheetPath
    {
        get
        {
            if (!IsCueTrack) return null;
            var hash = Path.LastIndexOf('#');
            return hash < 0 ? null : Path[..hash];
        }
    }

    /// <summary>Artist shown for album grouping: album artist, then track artist.</summary>
    [JsonIgnore]
    public string DisplayAlbumArtist => IsCompilation ? "Various Artists" : AlbumArtist.NonEmpty() ?? Artist.NonEmpty() ?? "Unknown Artist";

    [JsonIgnore] public string DisplayArtist => Artist.NonEmpty() ?? AlbumArtist.NonEmpty() ?? "Unknown Artist";
    [JsonIgnore] public string DisplayAlbum => Album.NonEmpty() ?? "Unknown Album";

    public static string MakeAlbumKey(string? album, string? albumArtist, string? artist, bool isCompilation)
    {
        var artistPart = isCompilation ? "\u0001compilation" : albumArtist.NonEmpty() ?? artist.NonEmpty() ?? "";
        return $"{artistPart.NormalizedKey()}\u001F{(album ?? "").NormalizedKey()}";
    }

    [JsonIgnore]
    public AudioSpec AudioSpec => new(Format, SampleRate, BitDepth, Bitrate, Channels);
}

/// <summary>One row per album, derived from tracks.</summary>
public sealed record AlbumSummary(string AlbumKey, string Title, string Artist, int? Year, string? Genre, int TrackCount, double Duration,
                                  string? ArtworkHash, DateTime DateAdded);

public sealed record ArtistSummary(string Name, int AlbumCount, int TrackCount, string? ArtworkHash)
{
    /// <summary>The "Compilations" entry of the artist list (various-artists albums), a name no artist can have.</summary>
    public const string Compilations = "\u0001compilations";

    public bool IsCompilations => Name == Compilations;
    /// <summary>The name to show: "Compilations" for the compilations entry.</summary>
    public string DisplayName => GetDisplayName(Name);

    public static string GetDisplayName(string name) => name == Compilations ? "Compilations" : name;
}

public sealed record Playlist
{
    public long? Id { get; set; }
    public required string Name { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    /// <summary>JSON <see cref="SmartPlaylistRules"/> for smart playlists, null for manual ones.</summary>
    public byte[]? SmartRules { get; set; }
    /// <summary>JSON <see cref="PlaylistCover"/>; null shows the songs' covers.</summary>
    public byte[]? Cover { get; set; }

    [JsonIgnore] public bool IsSmart => SmartRules is not null;
    [JsonIgnore] public PlaylistCover? CoverStyle => SwiftJson.Decode<PlaylistCover>(Cover);
    [JsonIgnore] public SmartPlaylistRules? Rules => SwiftJson.Decode<SmartPlaylistRules>(SmartRules);
}

public sealed record PlaylistItem(long? Id, long PlaylistId, long TrackId, int Position);

/// <summary>A playlist with what its card shows: song count, length and up to four covers.</summary>
public sealed record PlaylistSummary(Playlist Playlist, int TrackCount, double Duration, IReadOnlyList<string> ArtworkHashes)
{
    public long Id => Playlist.Id ?? -1;
}

/// <summary>Everything the All Playlists page lists: Loved Songs first, then the playlists.</summary>
public sealed record PlaylistOverview(int LovedCount, double LovedDuration, IReadOnlyList<string> LovedArtworkHashes,
                                      IReadOnlyList<PlaylistSummary> Playlists);

/// <summary>
/// How a playlist's cover looks: a generated design (a color palette and an optional pattern), a custom image, or the
/// songs' covers, optionally with the playlist name drawn in the top left corner. JSON as the Mac writes it:
/// <c>{"kind":{"generated":{"palette":"p","pattern":"q"}},"showsTitle":true}</c>.
/// </summary>
public sealed record PlaylistCover(PlaylistCoverKind Kind, bool ShowsTitle = false);

[JsonConverter(typeof(PlaylistCoverKindConverter))]
public abstract record PlaylistCoverKind
{
    /// <summary>Palette and pattern ids, resolved by the app.</summary>
    public sealed record Generated(string Palette, string Pattern) : PlaylistCoverKind;
    /// <summary>Image stored in the artwork cache.</summary>
    public sealed record Image(string Hash) : PlaylistCoverKind;
    /// <summary>Up to four covers of the playlist's songs.</summary>
    public sealed record SongCovers : PlaylistCoverKind;
}

/// <summary>Swift's encoding of an enum with associated values: the case name as the key of an object of its values.</summary>
internal sealed class PlaylistCoverKindConverter : JsonConverter<PlaylistCoverKind>
{
    public override PlaylistCoverKind Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var document = JsonDocument.ParseValue(ref reader);
        foreach (var property in document.RootElement.EnumerateObject())
        {
            var value = property.Value;
            string Field(string name) => value.TryGetProperty(name, out var field) ? field.GetString() ?? "" : "";
            switch (property.Name)
            {
                case "generated": return new PlaylistCoverKind.Generated(Field("palette"), Field("pattern"));
                case "image": return new PlaylistCoverKind.Image(Field("hash"));
                case "songCovers": return new PlaylistCoverKind.SongCovers();
            }
        }
        throw new JsonException("Unknown playlist cover kind.");
    }

    public override void Write(Utf8JsonWriter writer, PlaylistCoverKind value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        switch (value)
        {
            case PlaylistCoverKind.Generated generated:
                writer.WriteStartObject("generated");
                writer.WriteString("palette", generated.Palette);
                writer.WriteString("pattern", generated.Pattern);
                writer.WriteEndObject();
                break;
            case PlaylistCoverKind.Image image:
                writer.WriteStartObject("image");
                writer.WriteString("hash", image.Hash);
                writer.WriteEndObject();
                break;
            default:
                writer.WriteStartObject("songCovers");
                writer.WriteEndObject();
                break;
        }
        writer.WriteEndObject();
    }
}
