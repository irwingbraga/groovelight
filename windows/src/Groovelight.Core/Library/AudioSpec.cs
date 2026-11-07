using System.Globalization;

namespace Groovelight.Core.Library;

/// <summary>Quality class of a file, from best to worst, used for badges (stored as its number, like the Mac's).</summary>
public enum QualityTier
{
    Standard = 0,
    HighQuality = 1,
    Lossless = 2,
    HiResLossless = 3,
    Dsd = 4,
}

public static class QualityTierExtensions
{
    public static string DisplayName(this QualityTier tier) => tier switch
    {
        QualityTier.Standard => "Standard",
        QualityTier.HighQuality => "High Quality",
        QualityTier.Lossless => "Lossless",
        QualityTier.HiResLossless => "Hi-Res Lossless",
        _ => "DSD",
    };

    public static bool IsLossless(this QualityTier tier) => tier >= QualityTier.Lossless;
}

public enum Codec
{
    Flac, Alac, Wav, Aiff, WavPack, MonkeysAudio, TrueAudio, Shorten, OggFlac,
    Dsf, Dsdiff,
    Mp3, Aac, Vorbis, Opus, Musepack, Speex, Mp1, Mp2,
    Module,
    Unknown,
}

public static class Codecs
{
    /// <summary>The codec of a format name as the tag reader gives it (<see cref="Track.Format"/>).</summary>
    public static Codec FromFormatName(string? formatName)
    {
        var name = (formatName ?? "").ToLowerInvariant();
        return name switch
        {
            "flac" => Codec.Flac,
            "apple lossless" => Codec.Alac,
            "wave" => Codec.Wav,
            "aiff" => Codec.Aiff,
            "wavpack" => Codec.WavPack,
            "monkey's audio" => Codec.MonkeysAudio,
            "true audio" => Codec.TrueAudio,
            "shorten" => Codec.Shorten,
            "ogg flac" => Codec.OggFlac,
            "dsd stream" => Codec.Dsf,
            "dsd interchange" => Codec.Dsdiff,
            "mp3" => Codec.Mp3,
            "aac" => Codec.Aac,
            "ogg vorbis" => Codec.Vorbis,
            "ogg opus" => Codec.Opus,
            "musepack" => Codec.Musepack,
            "ogg speex" => Codec.Speex,
            _ when name.EndsWith("layer iii", StringComparison.Ordinal) => Codec.Mp3,
            _ when name.EndsWith("layer ii", StringComparison.Ordinal) => Codec.Mp2,
            _ when name.EndsWith("layer i", StringComparison.Ordinal) => Codec.Mp1,
            _ when name.EndsWith("module", StringComparison.Ordinal) => Codec.Module,
            _ => Codec.Unknown,
        };
    }

    /// <summary>The format name stored for the codec, the same as the Mac's tag reader gives.</summary>
    public static string? FormatName(this Codec codec) => codec switch
    {
        Codec.Flac => "FLAC",
        Codec.Alac => "Apple Lossless",
        Codec.Wav => "WAVE",
        Codec.Aiff => "AIFF",
        Codec.WavPack => "WavPack",
        Codec.MonkeysAudio => "Monkey's Audio",
        Codec.TrueAudio => "True Audio",
        Codec.Shorten => "Shorten",
        Codec.OggFlac => "Ogg FLAC",
        Codec.Dsf => "DSD Stream",
        Codec.Dsdiff => "DSD Interchange",
        Codec.Mp3 => "MP3",
        Codec.Aac => "AAC",
        Codec.Vorbis => "Ogg Vorbis",
        Codec.Opus => "Ogg Opus",
        Codec.Musepack => "Musepack",
        Codec.Speex => "Ogg Speex",
        Codec.Mp1 => "MPEG-1 Layer I",
        Codec.Mp2 => "MPEG-1 Layer II",
        Codec.Module => "Module",
        _ => null,
    };

    /// <summary>Short, familiar name ("ALAC" rather than "Apple Lossless").</summary>
    public static string ShortName(this Codec codec) => codec switch
    {
        Codec.Flac => "FLAC",
        Codec.Alac => "ALAC",
        Codec.Wav => "WAV",
        Codec.Aiff => "AIFF",
        Codec.WavPack => "WavPack",
        Codec.MonkeysAudio => "APE",
        Codec.TrueAudio => "TTA",
        Codec.Shorten => "SHN",
        Codec.OggFlac => "Ogg FLAC",
        Codec.Dsf => "DSF",
        Codec.Dsdiff => "DFF",
        Codec.Mp3 => "MP3",
        Codec.Aac => "AAC",
        Codec.Vorbis => "Vorbis",
        Codec.Opus => "Opus",
        Codec.Musepack => "MPC",
        Codec.Speex => "Speex",
        Codec.Mp1 => "MP1",
        Codec.Mp2 => "MP2",
        Codec.Module => "Module",
        _ => "Audio",
    };

    public static bool IsLossless(this Codec codec) => codec is Codec.Flac or Codec.Alac or Codec.Wav or Codec.Aiff or Codec.WavPack
        or Codec.MonkeysAudio or Codec.TrueAudio or Codec.Shorten or Codec.OggFlac or Codec.Dsf or Codec.Dsdiff;

    public static bool IsDsd(this Codec codec) => codec is Codec.Dsf or Codec.Dsdiff;
}

/// <summary>Technical description of an audio file: codec, resolution and bitrate.</summary>
public sealed record AudioSpec
{
    public Codec Codec { get; init; }
    /// <summary>Original format name as the tag reader reports it (e.g. "Apple Lossless", "MPEG-1 Layer III").</summary>
    public string? FormatName { get; init; }
    public double? SampleRate { get; init; }
    public int? BitDepth { get; init; }
    /// <summary>Average bitrate in kbps.</summary>
    public double? Bitrate { get; init; }
    public int? Channels { get; init; }

    public AudioSpec(string? formatName, double? sampleRate, int? bitDepth, double? bitrate, int? channels)
    {
        Codec = Codecs.FromFormatName(formatName);
        FormatName = formatName;
        SampleRate = sampleRate > 0 ? sampleRate : null;
        BitDepth = bitDepth > 0 ? bitDepth : null;
        Bitrate = bitrate > 0 ? bitrate : null;
        Channels = channels > 0 ? channels : null;
    }

    public QualityTier Tier
    {
        get
        {
            if (Codec.IsDsd()) return QualityTier.Dsd;
            if (Codec.IsLossless())
            {
                // Hi-Res Audio (JAS): better than CD, i.e. more than 16-bit or above 48 kHz.
                var deep = (BitDepth ?? 16) > 16;
                var fast = (SampleRate ?? 44_100) > 48_000;
                return deep || fast ? QualityTier.HiResLossless : QualityTier.Lossless;
            }
            if (Bitrate is not { } bitrate) return QualityTier.Standard;
            var threshold = Codec == Codec.Opus ? 160.0 : 256.0;
            return bitrate >= threshold * 0.97 ? QualityTier.HighQuality : QualityTier.Standard;
        }
    }

    private static string Fixed(double value, int decimals) =>
        Math.Round(value, decimals, MidpointRounding.ToEven).ToString("F" + decimals, CultureInfo.InvariantCulture);

    /// <summary>"44.1 kHz", "96 kHz", or for DSD "DSD64 (2.8 MHz)".</summary>
    public string? SampleRateText
    {
        get
        {
            if (SampleRate is not { } rate) return null;
            if (Codec.IsDsd()) return $"DSD{(int)Math.Round(rate / 44_100)} ({Fixed(rate / 1_000_000, 1)} MHz)";
            var khz = rate / 1_000;
            return khz % 1 == 0 ? $"{Fixed(khz, 0)} kHz" : $"{Fixed(khz, 1)} kHz";
        }
    }

    public string? BitrateText => Bitrate is { } bitrate ? $"{Fixed(bitrate, 0)} kbps" : null;

    /// <summary>Resolution: "24-bit / 96 kHz" for PCM lossless, "DSD64 (2.8 MHz)" for DSD, "320 kbps · 44.1 kHz" for lossy.</summary>
    public string ResolutionText
    {
        get
        {
            if (Codec.IsDsd()) return SampleRateText ?? "DSD";
            if (Codec.IsLossless())
                return string.Join(" / ", new[] { BitDepth is { } depth ? $"{depth}-bit" : null, SampleRateText }.OfType<string>());
            return string.Join(" · ", new[] { BitrateText, SampleRateText }.OfType<string>());
        }
    }

    /// <summary>One line summary: "FLAC · 24-bit / 96 kHz", "MP3 · 320 kbps · 44.1 kHz".</summary>
    public string Summary => ResolutionText.Length == 0 ? Codec.ShortName() : $"{Codec.ShortName()} · {ResolutionText}";

    /// <summary>Very short form for list rows: "FLAC 24/96", "ALAC 16/44.1", "MP3 320", "DSD64".</summary>
    public string CompactText
    {
        get
        {
            if (Codec.IsDsd() && SampleRate is { } dsdRate) return $"DSD{(int)Math.Round(dsdRate / 44_100)}";
            if (Codec.IsLossless())
            {
                if (SampleRate is not { } rate) return Codec.ShortName();
                var khz = rate / 1_000;
                var text = khz % 1 == 0 ? Fixed(khz, 0) : Fixed(khz, 1);
                return $"{Codec.ShortName()} {(BitDepth is { } depth ? $"{depth}/" : "")}{text}";
            }
            return Bitrate is { } bitrate ? $"{Codec.ShortName()} {(int)Math.Round(bitrate)}" : Codec.ShortName();
        }
    }

    public string? ChannelsText => Channels switch
    {
        null => null,
        1 => "Mono",
        2 => "Stereo",
        6 => "5.1",
        8 => "7.1",
        { } count => $"{count} channels",
    };

    /// <summary>
    /// Key used to decide whether every track of an album shares the same configuration. Lossless bitrates vary with
    /// content, so they are ignored; lossy bitrates are snapped to the usual encoder settings (VBR averages wobble).
    /// </summary>
    public AudioSpec UniformityKey
    {
        get
        {
            double? bitrate = null;
            if (!Codec.IsLossless() && Bitrate is { } value)
            {
                double[] standard = [64, 96, 128, 160, 192, 224, 256, 320];
                bitrate = standard.MinBy(candidate => Math.Abs(candidate - value));
            }
            return this with { FormatName = null, Bitrate = bitrate };
        }
    }

    /// <summary>The shared spec when all <paramref name="specs"/> have the same configuration, otherwise null.</summary>
    public static AudioSpec? Uniform(IReadOnlyList<AudioSpec> specs)
    {
        if (specs.Count == 0) return null;
        var first = specs[0];
        var key = first.UniformityKey;
        if (!specs.All(spec => spec.UniformityKey == key)) return null;
        // Show the snapped bitrate for lossy albums so VBR averages read as one value.
        return key.Codec.IsLossless() ? first : new AudioSpec(first.FormatName, key.SampleRate, key.BitDepth, key.Bitrate, key.Channels);
    }
}
