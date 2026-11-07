using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Groovelight.Core.Library;

namespace Groovelight.Core.Devices;

/// <summary>
/// A lossy format lossless songs can be sent in, to fit more music on a device: each at the bitrate where it is about as
/// transparent as the others (Opus at 160 kbps, AAC at 192 kbps, MP3 at 320 kbps). Raw values as on the Mac.
/// </summary>
[JsonConverter(typeof(LossyEncodingConverter))]
public enum LossyEncoding { Opus160, Aac192, Mp3320 }

public static class LossyEncodings
{
    public static IReadOnlyList<LossyEncoding> All { get; } = [LossyEncoding.Opus160, LossyEncoding.Aac192, LossyEncoding.Mp3320];

    public static string RawValue(this LossyEncoding encoding) => encoding switch
    {
        LossyEncoding.Opus160 => "opus160",
        LossyEncoding.Aac192 => "aac192",
        _ => "mp3_320",
    };

    public static LossyEncoding? Parse(string? raw) => raw switch
    {
        "opus160" => LossyEncoding.Opus160,
        "aac192" => LossyEncoding.Aac192,
        "mp3_320" => LossyEncoding.Mp3320,
        _ => null,
    };

    public static string DisplayName(this LossyEncoding encoding) => encoding switch
    {
        LossyEncoding.Opus160 => "Opus 160 kbps",
        LossyEncoding.Aac192 => "AAC 192 kbps",
        _ => "MP3 320 kbps",
    };

    public static string FileExtension(this LossyEncoding encoding) => encoding switch
    {
        LossyEncoding.Opus160 => "opus",
        LossyEncoding.Aac192 => "m4a",
        _ => "mp3",
    };

    /// <summary>The codec (raw value, as <see cref="Codecs.RawValue"/>) of the files it makes.</summary>
    public static string Codec(this LossyEncoding encoding) => encoding switch
    {
        LossyEncoding.Opus160 => "opus",
        LossyEncoding.Aac192 => "aac",
        _ => "mp3",
    };

    public static int Kbps(this LossyEncoding encoding) => encoding switch
    {
        LossyEncoding.Opus160 => 160,
        LossyEncoding.Aac192 => 192,
        _ => 320,
    };

    /// <summary>
    /// The sample rate a song of <paramref name="rate"/> is encoded at: Opus always works at 48 kHz; AAC and MP3 go up to
    /// 48 kHz, so hi-res songs come down to 44.1 or 48 kHz (whichever divides their rate).
    /// </summary>
    public static double OutputRate(this LossyEncoding encoding, double rate) => encoding == LossyEncoding.Opus160 ? 48_000
        : rate <= 48_000 ? rate : (int)rate % 44_100 == 0 ? 44_100 : 48_000;

    /// <summary>Codecs of the songs it applies to: lossless ones (lossy songs are never encoded again).</summary>
    public static bool AppliesTo(Codec codec) => codec is Library.Codec.Flac or Library.Codec.Alac or Library.Codec.Wav or Library.Codec.Aiff
        or Library.Codec.WavPack or Library.Codec.MonkeysAudio or Library.Codec.TrueAudio or Library.Codec.Shorten or Library.Codec.OggFlac;
}

public sealed class LossyEncodingConverter : JsonConverter<LossyEncoding>
{
    public override LossyEncoding Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        LossyEncodings.Parse(reader.GetString()) ?? throw new JsonException("Not a lossy encoding.");

    public override void Write(Utf8JsonWriter writer, LossyEncoding value, JsonSerializerOptions options) => writer.WriteStringValue(value.RawValue());
}

/// <summary>
/// What to convert: a whole file, or one song of a CUE album (its region of the album's file, with its own tags, since
/// the file's tags describe the whole album); to FLAC (no encoding) or a lossy format.
/// </summary>
public sealed record ConversionSource(string Path, double? StartTime = null, double? EndTime = null, TrackMetadata? Tags = null, LossyEncoding? Encoding = null)
{
    public string FileExtension => Encoding?.FileExtension() ?? "flac";

    /// <summary>The song of a CUE album, as a file of its own (FLAC, or <paramref name="encoding"/>).</summary>
    public static ConversionSource CueTrack(Track track, LossyEncoding? encoding = null) => new(track.FilePath, track.StartTime ?? 0, track.EndTime, new TrackMetadata
    {
        Title = track.Title, Artist = track.Artist.NonEmpty(), Album = track.Album, AlbumArtist = track.AlbumArtist, Genre = track.Genre, Year = track.Year,
        TrackNumber = track.TrackNumber, TrackTotal = track.TrackTotal, DiscNumber = track.DiscNumber, DiscTotal = track.DiscTotal, IsCompilation = track.IsCompilation,
    }, encoding);
}

public sealed class ConversionException(string message) : Exception(message);

/// <summary>
/// Lossless conversion to FLAC, for players that cannot decode a song's format (ALAC, AIFF and WavPack on Android): the
/// same audio, sample rate and bit depth, with the tags and artwork copied over; or lossy encoding for devices set to
/// it. Done by FFmpeg's command-line tool (beside the app as <c>ffmpeg\ffmpeg.exe</c>, the same LGPL build as the DLLs).
/// </summary>
public static class FormatConverter
{
    /// <summary>Where ffmpeg is: <c>GROOVELIGHT_FFMPEG</c>, beside the app, or on the PATH.</summary>
    public static string Tool
    {
        get
        {
            if (Environment.GetEnvironmentVariable("GROOVELIGHT_FFMPEG") is { Length: > 0 } configured) return configured;
            var beside = System.IO.Path.Combine(AppContext.BaseDirectory, "ffmpeg", OperatingSystem.IsWindows() ? "ffmpeg.exe" : "ffmpeg");
            if (File.Exists(beside)) return beside;
            foreach (var candidate in new[] { "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg" })
                if (File.Exists(candidate)) return candidate;
            return "ffmpeg";
        }
    }

    /// <summary>Converts <paramref name="source"/> into <paramref name="destination"/> (any name: it works on a temporary file beside it).</summary>
    public static void Convert(ConversionSource source, string destination)
    {
        var folder = System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(destination))!;
        Directory.CreateDirectory(folder);
        var temporary = System.IO.Path.Combine(folder, $".{Guid.NewGuid():N}.{source.FileExtension}");
        try
        {
            var arguments = Arguments(source, temporary);
            var start = new ProcessStartInfo(Tool) { RedirectStandardError = true, RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true };
            foreach (var argument in arguments) start.ArgumentList.Add(argument);
            using var process = Process.Start(start) ?? throw new ConversionException($"Could not convert “{System.IO.Path.GetFileName(source.Path)}”: FFmpeg did not start.");
            var errors = process.StandardError.ReadToEndAsync();
            process.StandardOutput.ReadToEnd();
            process.WaitForExit();
            if (process.ExitCode != 0 || !File.Exists(temporary))
            {
                var reason = errors.Result.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).LastOrDefault() ?? "FFmpeg failed";
                throw new ConversionException($"Could not convert “{System.IO.Path.GetFileName(source.Path)}” to {source.Encoding?.DisplayName() ?? "FLAC"}: {reason}");
            }
            File.Move(temporary, destination, true);
        }
        catch (System.ComponentModel.Win32Exception error)
        {
            throw new ConversionException($"Could not convert “{System.IO.Path.GetFileName(source.Path)}”: FFmpeg is missing ({error.Message}).");
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    /// <summary>The FFmpeg command for a conversion: the region of a CUE song sample accurately, the tags and cover kept.</summary>
    public static List<string> Arguments(ConversionSource source, string destination)
    {
        var arguments = new List<string> { "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", source.Path };
        var filters = new List<string>();
        if (source.StartTime is { } startTime)
        {
            // Sample accurate, as CUE tracks play: consecutive songs join without a gap or an overlap.
            var end = source.EndTime is { } endTime ? $":end={endTime.ToString("0.######", CultureInfo.InvariantCulture)}" : "";
            filters.Add($"atrim=start={startTime.ToString("0.######", CultureInfo.InvariantCulture)}{end}");
            filters.Add("asetpts=PTS-STARTPTS");
        }
        // The audio, and the cover where the format holds one (Ogg Opus does not take a picture stream).
        arguments.AddRange(["-map", "0:a:0"]);
        var keepsCover = source.Encoding != LossyEncoding.Opus160;
        if (keepsCover) arguments.AddRange(["-map", "0:v:0?", "-c:v", "copy", "-disposition:v:0", "attached_pic"]);
        arguments.AddRange(["-map_metadata", "0"]);
        if (filters.Count > 0) arguments.AddRange(["-af", string.Join(",", filters)]);
        switch (source.Encoding)
        {
            case LossyEncoding.Opus160:
                arguments.AddRange(["-c:a", "libopus", "-b:a", "160k", "-vbr", "on", "-application", "audio", "-compression_level", "10", "-ar", "48000"]);
                break;
            case LossyEncoding.Aac192:
                arguments.AddRange(["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]);
                break;
            case LossyEncoding.Mp3320:
                // LAME tops out at 48 kHz: FFmpeg brings hi-res songs down to the nearest rate it takes.
                arguments.AddRange(["-c:a", "libmp3lame", "-b:a", "320k", "-joint_stereo", "1", "-id3v2_version", "3"]);
                break;
            default:
                arguments.AddRange(["-c:a", "flac", "-compression_level", "8"]);
                break;
        }
        if (source.Tags is { } tags)
        {
            void Tag(string name, object? value)
            {
                if (value is not null && value.ToString() is { Length: > 0 } text) arguments.AddRange(["-metadata", $"{name}={text}"]);
            }
            Tag("title", tags.Title);
            Tag("artist", tags.Artist);
            Tag("album", tags.Album);
            Tag("album_artist", tags.AlbumArtist);
            Tag("genre", tags.Genre);
            Tag("date", tags.Year);
            Tag("track", tags.TrackNumber is { } number ? tags.TrackTotal is { } total ? $"{number}/{total}" : number.ToString(CultureInfo.InvariantCulture) : null);
            Tag("disc", tags.DiscNumber is { } disc ? tags.DiscTotal is { } discs ? $"{disc}/{discs}" : disc.ToString(CultureInfo.InvariantCulture) : null);
            if (tags.IsCompilation == true) Tag("compilation", 1);
            // The album's CUE file tags would name the whole album's position: cleared where not given.
            if (tags.TrackNumber is null) arguments.AddRange(["-metadata", "track="]);
        }
        arguments.Add(destination);
        return arguments;
    }
}

/// <summary>
/// Conversions kept in a folder by the song's fingerprint (path, size, date), so a device syncing again, or a download
/// that resumes, does not convert again. One conversion at a time.
/// </summary>
public sealed class ConversionCache
{
    private readonly Lock gate = new();

    public string Folder { get; }

    public ConversionCache(string folder)
    {
        Folder = folder;
        Directory.CreateDirectory(folder);
    }

    /// <summary>The conversion of <paramref name="source"/> with this <paramref name="fingerprint"/>, converted now if it is not there yet.</summary>
    public string Converted(ConversionSource source, string fingerprint)
    {
        var target = System.IO.Path.Combine(Folder, Key(fingerprint) + "." + source.FileExtension);
        lock (gate)
        {
            if (File.Exists(target)) return target;
            FormatConverter.Convert(source, target);
            return target;
        }
    }

    /// <summary>Removes conversions no fingerprint in <paramref name="keeping"/> refers to.</summary>
    public void Prune(IEnumerable<string> keeping)
    {
        var keys = keeping.Select(Key).ToHashSet();
        lock (gate)
        {
            foreach (var file in Directory.EnumerateFiles(Folder))
            {
                var name = System.IO.Path.GetFileName(file);
                if (!name.StartsWith('.') && !keys.Contains(System.IO.Path.GetFileNameWithoutExtension(name))) File.Delete(file);
            }
        }
    }

    public static string Key(string fingerprint) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(fingerprint)).AsSpan(0, 16));
}
