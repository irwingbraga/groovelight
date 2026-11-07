using System.Text.Json.Serialization;

namespace Groovelight.Core.Library;

/// <summary>
/// The editable tag fields of a track. Used for proposed fixes, manual edits, overrides kept in the database (null means
/// "keep the current value") and for writing tags back to files. An empty string or a 0 number clears the field.
/// </summary>
public sealed record TrackMetadata
{
    public string? Title { get; init; }
    public string? Artist { get; init; }
    public string? Album { get; init; }
    public string? AlbumArtist { get; init; }
    public string? Genre { get; init; }
    public int? Year { get; init; }
    public int? TrackNumber { get; init; }
    public int? TrackTotal { get; init; }
    public int? DiscNumber { get; init; }
    public int? DiscTotal { get; init; }
    public bool? IsCompilation { get; init; }
    public string? MusicBrainzRecordingId { get; init; }
    public string? MusicBrainzReleaseId { get; init; }
    public string? Composer { get; init; }
    public string? Comment { get; init; }
    public int? Bpm { get; init; }
    public string? Lyrics { get; init; }

    [JsonIgnore] public bool IsEmpty => this == new TrackMetadata();

    /// <summary>Fields of <paramref name="other"/> that are set win.</summary>
    public TrackMetadata Merging(TrackMetadata other) => new()
    {
        Title = other.Title ?? Title, Artist = other.Artist ?? Artist, Album = other.Album ?? Album,
        AlbumArtist = other.AlbumArtist ?? AlbumArtist, Genre = other.Genre ?? Genre, Year = other.Year ?? Year,
        TrackNumber = other.TrackNumber ?? TrackNumber, TrackTotal = other.TrackTotal ?? TrackTotal,
        DiscNumber = other.DiscNumber ?? DiscNumber, DiscTotal = other.DiscTotal ?? DiscTotal,
        IsCompilation = other.IsCompilation ?? IsCompilation,
        MusicBrainzRecordingId = other.MusicBrainzRecordingId ?? MusicBrainzRecordingId,
        MusicBrainzReleaseId = other.MusicBrainzReleaseId ?? MusicBrainzReleaseId,
        Composer = other.Composer ?? Composer, Comment = other.Comment ?? Comment, Bpm = other.Bpm ?? Bpm, Lyrics = other.Lyrics ?? Lyrics,
    };
}

public static class TrackMetadataExtensions
{
    /// <summary>Current values of the editable fields.</summary>
    public static TrackMetadata Metadata(this Track track) => new()
    {
        Title = track.Title, Artist = track.Artist, Album = track.Album, AlbumArtist = track.AlbumArtist, Genre = track.Genre,
        Year = track.Year, TrackNumber = track.TrackNumber, TrackTotal = track.TrackTotal, DiscNumber = track.DiscNumber,
        DiscTotal = track.DiscTotal, IsCompilation = track.IsCompilation, MusicBrainzRecordingId = track.MusicBrainzRecordingId,
        MusicBrainzReleaseId = track.MusicBrainzReleaseId, Composer = track.Composer, Comment = track.Comment, Bpm = track.Bpm,
        Lyrics = track.Lyrics,
    };

    /// <summary>Sets every field present in <paramref name="metadata"/> (an empty string or 0 clears it) and recomputes the album key.</summary>
    public static void Apply(this Track track, TrackMetadata metadata)
    {
        static string? Text(string? value, string? current) => value is null ? current : value.Trim().Length == 0 ? null : value;
        static int? Number(int? value, int? current) => value is null ? current : value == 0 ? null : value;

        // A song always has a title; clearing it falls back to the file name, as for untagged files.
        if (metadata.Title is not null)
            track.Title = Text(metadata.Title, null) ?? Path.GetFileNameWithoutExtension(track.FilePath);
        track.Artist = Text(metadata.Artist, track.Artist);
        track.Album = Text(metadata.Album, track.Album);
        track.AlbumArtist = Text(metadata.AlbumArtist, track.AlbumArtist);
        track.Genre = Text(metadata.Genre, track.Genre);
        track.Year = Number(metadata.Year, track.Year);
        track.TrackNumber = Number(metadata.TrackNumber, track.TrackNumber);
        track.TrackTotal = Number(metadata.TrackTotal, track.TrackTotal);
        track.DiscNumber = Number(metadata.DiscNumber, track.DiscNumber);
        track.DiscTotal = Number(metadata.DiscTotal, track.DiscTotal);
        if (metadata.IsCompilation is { } compilation) track.IsCompilation = compilation;
        track.MusicBrainzRecordingId = Text(metadata.MusicBrainzRecordingId, track.MusicBrainzRecordingId);
        track.MusicBrainzReleaseId = Text(metadata.MusicBrainzReleaseId, track.MusicBrainzReleaseId);
        track.Composer = Text(metadata.Composer, track.Composer);
        track.Comment = Text(metadata.Comment, track.Comment);
        track.Bpm = Number(metadata.Bpm, track.Bpm);
        track.Lyrics = Text(metadata.Lyrics, track.Lyrics);
        track.AlbumKey = Track.MakeAlbumKey(track.Album, track.AlbumArtist, track.Artist, track.IsCompilation);
    }

    /// <summary>Overrides kept in the database for fixes not written to the file.</summary>
    public static TrackMetadata? GetOverrides(this Track track) => SwiftJson.Decode<TrackMetadata>(track.MetadataOverrides);

    public static void SetOverrides(this Track track, TrackMetadata? overrides) =>
        track.MetadataOverrides = overrides is null || overrides.IsEmpty ? null : SwiftJson.Encode(overrides);

    /// <summary>Lyrics to show: from the file first, then fetched online.</summary>
    public static string? DisplayLyrics(this Track track) => track.Lyrics.NonEmpty() ?? track.FetchedLyrics.NonEmpty();
}
