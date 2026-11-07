namespace Groovelight.Core.Library;

/// <summary>Tags and audio properties read from one file.</summary>
public sealed record FileTags
{
    public string? Title { get; set; }
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
    /// <summary>The format name the Mac's tag reader gives ("FLAC", "Apple Lossless", "Ogg Opus"...), see <see cref="Codecs.FormatName"/>.</summary>
    public string? Format { get; set; }
    public double? SampleRate { get; set; }
    public int? BitDepth { get; set; }
    public double? Bitrate { get; set; }
    public int? Channels { get; set; }

    /// <summary>Embedded front cover (or first picture) bytes.</summary>
    public byte[]? Artwork { get; set; }
    /// <summary>A cue sheet stored in the file (the CUESHEET tag of FLAC, Ogg, APE and WavPack files).</summary>
    public string? CueSheet { get; set; }
}

/// <summary>Reads tags with TagLib# (SFBAudioEngine's role on the Mac).</summary>
public static class TagReader
{
    /// <summary>Audio file extensions the library takes, lower case without the dot.</summary>
    public static readonly IReadOnlySet<string> SupportedExtensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "flac", "fla", "oga", "ogg", "opus", "spx", "m4a", "m4b", "mp4", "aac", "mp3", "mp2", "mp1", "mpga",
        "wav", "wave", "aif", "aiff", "aifc", "wv", "ape", "mpc", "mpp", "tta", "shn", "dsf", "dff",
        "mod", "xm", "it", "s3m", "mptm", "mo3", "669", "mtm", "med", "okt", "stm", "ult", "umx",
    };

    /// <summary>The codec of formats TagLib# cannot open, by extension (their properties come from the decoder).</summary>
    private static readonly Dictionary<string, Codec> CodecByExtension = new(StringComparer.OrdinalIgnoreCase)
    {
        ["tta"] = Codec.TrueAudio, ["shn"] = Codec.Shorten, ["dff"] = Codec.Dsdiff,
        ["mod"] = Codec.Module, ["xm"] = Codec.Module, ["it"] = Codec.Module, ["s3m"] = Codec.Module, ["mptm"] = Codec.Module,
        ["mo3"] = Codec.Module, ["669"] = Codec.Module, ["mtm"] = Codec.Module, ["med"] = Codec.Module, ["okt"] = Codec.Module,
        ["stm"] = Codec.Module, ["ult"] = Codec.Module, ["umx"] = Codec.Module,
    };

    public static bool IsSupported(string path) => SupportedExtensions.Contains(System.IO.Path.GetExtension(path).TrimStart('.'));

    public static FileTags Read(string path)
    {
        var extension = System.IO.Path.GetExtension(path).TrimStart('.');
        if (CodecByExtension.TryGetValue(extension, out var known))
        {
            // Not readable by TagLib#: the song is listed by its file name until the decoder reads it.
            if (!File.Exists(path)) throw new FileNotFoundException(path);
            return new FileTags { Format = known.FormatName() };
        }
        using var file = TagLib.File.Create(path, TagLib.ReadStyle.Average);
        var tag = file.Tag;
        var properties = file.Properties;

        // Some formats keep a removed text tag as an empty string: treat empty as missing.
        static string? Text(string? value) => string.IsNullOrWhiteSpace(value) ? null : value;
        static int? Positive(uint value) => value > 0 ? (int)value : null;
        static double? Gain(double value) => double.IsNaN(value) ? null : value;

        var format = FormatName(file);
        var codec = Codecs.FromFormatName(format);
        var tags = new FileTags
        {
            Title = Text(tag.Title),
            Artist = Text(tag.JoinedPerformers),
            Album = Text(tag.Album),
            AlbumArtist = Text(tag.JoinedAlbumArtists),
            Composer = Text(tag.JoinedComposers),
            Genre = Text(tag.JoinedGenres),
            Year = Positive(tag.Year),
            TrackNumber = Positive(tag.Track),
            TrackTotal = Positive(tag.TrackCount),
            DiscNumber = Positive(tag.Disc),
            DiscTotal = Positive(tag.DiscCount),
            IsCompilation = IsCompilation(file),
            Bpm = Positive(tag.BeatsPerMinute),
            Comment = Text(tag.Comment),
            Lyrics = Text(tag.Lyrics),
            MusicBrainzRecordingId = Text(tag.MusicBrainzTrackId),
            MusicBrainzReleaseId = Text(tag.MusicBrainzReleaseId),
            ReplayGainTrackGain = Gain(tag.ReplayGainTrackGain),
            ReplayGainAlbumGain = Gain(tag.ReplayGainAlbumGain),
            Duration = properties?.Duration.TotalSeconds ?? 0,
            Format = format,
            SampleRate = properties?.AudioSampleRate > 0 ? properties.AudioSampleRate : null,
            // A bit depth only means something for PCM (lossy codecs report the decoder's).
            BitDepth = codec.IsLossless() && properties?.BitsPerSample > 0 ? properties.BitsPerSample : null,
            Bitrate = properties?.AudioBitrate > 0 ? properties.AudioBitrate : null,
            Channels = properties?.AudioChannels > 0 ? properties.AudioChannels : null,
            CueSheet = CueSheetTag(file),
        };
        if (file is TagLib.WavPack.File && WavPackHeader(path) is { } header)
        {
            // TagLib# misreads the length of current WavPack files: the first block header has it exactly.
            tags.Duration = header.Samples / header.Rate;
            tags.SampleRate = header.Rate;
        }
        var pictures = tag.Pictures ?? [];
        var front = pictures.FirstOrDefault(picture => picture.Type == TagLib.PictureType.FrontCover) ?? pictures.FirstOrDefault();
        tags.Artwork = front?.Data?.Data;
        return tags;
    }

    /// <summary>The Mac's format name for the file (what SFBAudioEngine reports there).</summary>
    internal static string? FormatName(TagLib.File file)
    {
        switch (file)
        {
            case TagLib.Flac.File: return Codec.Flac.FormatName();
            case TagLib.Riff.File: return Codec.Wav.FormatName();
            case TagLib.Aiff.File: return Codec.Aiff.FormatName();
            case TagLib.WavPack.File: return Codec.WavPack.FormatName();
            case TagLib.Ape.File: return Codec.MonkeysAudio.FormatName();
            case TagLib.MusePack.File: return Codec.Musepack.FormatName();
            case TagLib.Dsf.File: return Codec.Dsf.FormatName();
            case TagLib.Aac.File: return Codec.Aac.FormatName();
        }
        var descriptions = string.Join(" ", file.Properties?.Codecs.Select(codec => codec?.Description ?? "") ?? []).ToLowerInvariant();
        return file switch
        {
            TagLib.Mpeg4.File => descriptions.Contains("alac") ? Codec.Alac.FormatName() : Codec.Aac.FormatName(),
            TagLib.Ogg.File when descriptions.Contains("opus") => Codec.Opus.FormatName(),
            TagLib.Ogg.File when descriptions.Contains("flac") => Codec.OggFlac.FormatName(),
            TagLib.Ogg.File when descriptions.Contains("speex") => Codec.Speex.FormatName(),
            TagLib.Ogg.File => Codec.Vorbis.FormatName(),
            TagLib.Mpeg.AudioFile mpeg => MpegLayer(mpeg),
            _ => null,
        };
    }

    private static readonly int[] WavPackRates =
        [6000, 8000, 9600, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 64000, 88200, 96000, 192000];

    /// <summary>Total samples and sample rate from the first WavPack block header ("wvpk"), when it states both.</summary>
    internal static (double Samples, double Rate)? WavPackHeader(string path)
    {
        Span<byte> header = stackalloc byte[32];
        using (var stream = File.OpenRead(path))
        {
            if (stream.ReadAtLeast(header, 32, throwOnEndOfStream: false) < 32) return null;
        }
        if (header[0] != 'w' || header[1] != 'v' || header[2] != 'p' || header[3] != 'k') return null;
        var totalSamples = BitConverter.ToUInt32(header[12..16]);
        var flags = BitConverter.ToUInt32(header[24..28]);
        var rateIndex = (int)((flags >> 23) & 0xF);
        if (totalSamples == uint.MaxValue || rateIndex >= WavPackRates.Length) return null;
        return (totalSamples, WavPackRates[rateIndex]);
    }

    private static string MpegLayer(TagLib.Mpeg.AudioFile file)
    {
        var header = file.Properties?.Codecs.OfType<TagLib.Mpeg.AudioHeader>().FirstOrDefault();
        return header?.AudioLayer switch
        {
            1 => Codec.Mp1.FormatName()!,
            2 => Codec.Mp2.FormatName()!,
            _ => Codec.Mp3.FormatName()!,
        };
    }

    private static bool IsCompilation(TagLib.File file)
    {
        static bool Yes(string? value) => value is not null && (value.Trim() == "1" || value.Trim().Equals("true", StringComparison.OrdinalIgnoreCase));
        if (file.GetTag(TagLib.TagTypes.Xiph) is TagLib.Ogg.XiphComment xiph && Yes(xiph.GetFirstField("COMPILATION"))) return true;
        if (file.GetTag(TagLib.TagTypes.Apple) is TagLib.Mpeg4.AppleTag apple && apple.IsCompilation) return true;
        if (file.GetTag(TagLib.TagTypes.Id3v2) is TagLib.Id3v2.Tag id3 &&
            Yes(TagLib.Id3v2.TextInformationFrame.Get(id3, "TCMP", false)?.Text.FirstOrDefault())) return true;
        if (file.GetTag(TagLib.TagTypes.Ape) is TagLib.Ape.Tag ape && Yes(ape.GetItem("Compilation")?.ToString())) return true;
        return false;
    }

    private static string? CueSheetTag(TagLib.File file)
    {
        if (file.GetTag(TagLib.TagTypes.Xiph) is TagLib.Ogg.XiphComment xiph && xiph.GetFirstField("CUESHEET") is { Length: > 0 } fromXiph)
            return fromXiph;
        if (file.GetTag(TagLib.TagTypes.Ape) is TagLib.Ape.Tag ape && ape.GetItem("Cuesheet")?.ToString() is { Length: > 0 } fromApe)
            return fromApe;
        return null;
    }

    /// <summary>Accepts "1999", "1999-03-02", "1999-03-02T00:00:00Z", "03/02/1999".</summary>
    public static int? ParseYear(string? value)
    {
        if (value is null) return null;
        var digits = "";
        foreach (var character in value)
        {
            if (char.IsDigit(character))
            {
                digits += character;
                if (digits.Length == 4 && int.TryParse(digits, out var year) && year is >= 1000 and <= 2999) return year;
            }
            else
            {
                digits = "";
            }
        }
        return null;
    }
}
