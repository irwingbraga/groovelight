using SkiaSharp;

namespace Groovelight.Skins;

/// <summary>What Now Playing shows in the cover's place: the cover, or one of the vintage players, the cover on them.</summary>
public enum NowPlayingSkin { Cover, Vinyl, Cassette, CompactDisc, PcPlayer }

/// <summary>The PC Player's themes: the classic two-window skin of the late 1990s, or Corona, the glassy blue player of 2002.</summary>
public enum PcTheme { Classic, Corona }

public static class SkinInfo
{
    /// <summary>The keys the choices are kept under (the Mac's <c>@AppStorage</c> keys).</summary>
    public const string StorageKey = "nowPlaying.skin";
    public const string CassetteStorageKey = "nowPlaying.cassette";
    /// <summary>Whether the cassette deck plays the tape's sound while Rewind or Fast Forward is held (on unless turned off).</summary>
    public const string TapeCueStorageKey = "nowPlaying.tapeCue";
    public const string PcThemeStorageKey = "nowPlaying.pcTheme";
    public const string CoronaVisualizationKey = "nowPlaying.coronaVisualization";

    public static string RawValue(this NowPlayingSkin skin) => skin switch
    {
        NowPlayingSkin.Vinyl => "vinyl",
        NowPlayingSkin.Cassette => "cassette",
        NowPlayingSkin.CompactDisc => "compactDisc",
        NowPlayingSkin.PcPlayer => "pcPlayer",
        _ => "cover",
    };

    public static NowPlayingSkin ParseSkin(string? raw) =>
        Enum.GetValues<NowPlayingSkin>().FirstOrDefault(skin => skin.RawValue() == raw, NowPlayingSkin.Cover);

    public static string DisplayName(this NowPlayingSkin skin) => skin switch
    {
        NowPlayingSkin.Vinyl => "Vinyl",
        NowPlayingSkin.Cassette => "Cassette",
        NowPlayingSkin.CompactDisc => "CD",
        NowPlayingSkin.PcPlayer => "PC Player",
        _ => "Cover",
    };

    public static string RawValue(this PcTheme theme) => theme == PcTheme.Corona ? "corona" : "classic";
    public static PcTheme ParseTheme(string? raw) => raw == "corona" ? PcTheme.Corona : PcTheme.Classic;
    public static string DisplayName(this PcTheme theme) => theme == PcTheme.Corona ? "Corona" : "Classic";

    /// <summary>Minutes and seconds, as the displays and counters show them.</summary>
    public static string ClockText(double seconds)
    {
        var whole = (int)Math.Max(seconds, 0);
        return $"{whole / 60 % 100:00}:{whole % 60:00}";
    }
}

/// <summary>A song file's bit rate (kbps), sample rate (kHz) and channels, as the PC Player shows them.</summary>
public sealed record SkinFormat(int? Kbps, int? KHz, int? Channels)
{
    /// <summary>
    /// From a file's sample rate, bit depth and channels, its bit rate when known (a lossless file's is the PCM rate, as
    /// the classic players show it: 1411 for a CD).
    /// </summary>
    public static SkinFormat From(double? sampleRate, int? bitDepth, int? bitrate, int? channels)
    {
        int? pcm = sampleRate is { } rate && bitDepth is { } depth ? (int)Math.Round(rate * depth * (channels ?? 2) / 1000) : null;
        return new SkinFormat(bitrate is { } value ? (value >= 10_000 ? value / 1000 : value) : pcm,
            sampleRate is { } hz ? (int)Math.Round(hz / 1000) : null, channels);
    }
}

/// <summary>The songs in the queue for the PC Player's playlist, the one playing, and how to play another.</summary>
public sealed record SkinPlaylist(IReadOnlyList<SkinPlaylistEntry> Entries, int? Current, Action<int>? Play = null);

public sealed record SkinPlaylistEntry(string Title, string Artist, double Duration);

/// <summary>What a skin needs of the song: what it is, whether it plays, and where it is (read at each frame).</summary>
public sealed class SkinPlayback
{
    public string Title { get; init; } = "Not Playing";
    public string Artist { get; init; } = "";
    public string Album { get; init; } = "";
    public bool IsPlaying { get; init; }
    public double Duration { get; init; }
    /// <summary>The song's time in seconds now.</summary>
    public Func<double> Time { get; init; } = () => 0;
    /// <summary>Each channel's RMS now (linear, full scale 1), for the VU meters; null where the meters swing on their own.</summary>
    public Func<(float Left, float Right)>? Levels { get; init; }
    /// <summary>The analyzer's bands now, low to high (0 to 1), for the PC Player's spectrum; null where it dances on its own.</summary>
    public Func<float[]>? Spectrum { get; init; }
    public SkinFormat? Format { get; init; }
    /// <summary>The cover, on the record's label, the disc, the cassette's label and Corona's screen (a placeholder without one).</summary>
    public SKImage? Artwork { get; init; }

    public double Progress => Duration > 0 ? Math.Clamp(Time() / Duration, 0, 1) : 0;
}

/// <summary>A value read and written through the app (the volume, the equalizer, the song loved).</summary>
public sealed class SkinBinding<T>(Func<T> get, Action<T> set)
{
    public T Value
    {
        get => get();
        set => set(value);
    }
}

public enum DeckRepeat { Off, All, One }

/// <summary>What the player's keys and knobs do: the app's transport, its seek, its volume, shuffle and repeat.</summary>
public sealed class DeckControls
{
    /// <summary>Held, the rewind and fast forward keys move through the song this far at each step (of 0.15 s).</summary>
    public const double ScanStep = 5;

    public Action PlayPause { get; init; } = () => { };
    public Action Previous { get; init; } = () => { };
    public Action Next { get; init; } = () => { };
    public Action<double> Seek { get; init; } = _ => { };
    public SkinBinding<double>? Volume { get; init; }
    /// <summary>The equalizer on or off (the PC Player's EQ key); null where it is not offered.</summary>
    public SkinBinding<bool>? Equalizer { get; init; }
    /// <summary>Leaves Now Playing (the PC Player's eject key).</summary>
    public Action? Eject { get; init; }
    /// <summary>The song loved or not (the heart keys); null where it cannot be loved.</summary>
    public SkinBinding<bool>? Love { get; init; }
    public bool IsShuffled { get; init; }
    public Action ToggleShuffle { get; init; } = () => { };
    public DeckRepeat RepeatMode { get; init; }
    public Action CycleRepeat { get; init; } = () => { };
    /// <summary>A step of a cassette scan: the tape's sound (when on).</summary>
    public Action? TapeCue { get; init; }
    /// <summary>The Love key's tooltip hint (the shortcut).</summary>
    public string LoveHint { get; init; } = "";

    public static DeckControls Inert { get; } = new() { Volume = new SkinBinding<double>(() => 0.7, _ => { }), RepeatMode = DeckRepeat.All };
}
