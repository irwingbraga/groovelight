using System.Globalization;
using System.Text;

namespace Groovelight.Audio;

/// <summary>Filter shape of a single equalizer band (the Mac's names, also in saved presets).</summary>
public enum EQFilterType { Peak, LowShelf, HighShelf, LowPass, HighPass, BandPass, Notch }

public static class EQFilterTypes
{
    public static string DisplayName(this EQFilterType type) => type switch
    {
        EQFilterType.Peak => "Peak",
        EQFilterType.LowShelf => "Low Shelf",
        EQFilterType.HighShelf => "High Shelf",
        EQFilterType.LowPass => "Low Pass",
        EQFilterType.HighPass => "High Pass",
        EQFilterType.BandPass => "Band Pass",
        _ => "Notch",
    };

    /// <summary>Whether the gain parameter has any audible effect for this filter type.</summary>
    public static bool UsesGain(this EQFilterType type) => type is EQFilterType.Peak or EQFilterType.LowShelf or EQFilterType.HighShelf;
}

public sealed record EQBand
{
    public bool IsEnabled { get; init; } = true;
    public EQFilterType Type { get; init; } = EQFilterType.Peak;
    /// <summary>Center or corner frequency in Hz.</summary>
    public double Frequency { get; init; }
    /// <summary>Gain in dB, only used by peak and shelf filters.</summary>
    public double Gain { get; init; }
    /// <summary>Quality factor.</summary>
    public double Q { get; init; } = EQMath.DefaultQ;
}

public sealed record EQPreset
{
    public string Name { get; init; } = "";
    public double Preamp { get; init; }
    public List<EQBand> Bands { get; init; } = [];

    public string Id => Name;

    public bool Equals(EQPreset? other) =>
        other is not null && Name == other.Name && Preamp.Equals(other.Preamp) && Bands.SequenceEqual(other.Bands);

    public override int GetHashCode() => HashCode.Combine(Name, Preamp, Bands.Count);

    public static EQPreset Flat => new() { Name = "Flat", Bands = EQMath.IsoFrequencies.Select(frequency => new EQBand { Frequency = frequency }).ToList() };

    /// <summary>Builds a preset from 15 gains applied to the ISO bands.</summary>
    public static EQPreset Iso(string name, double[] gains)
    {
        var bands = EQMath.IsoFrequencies.Zip(gains, (frequency, gain) => new EQBand { Frequency = frequency, Gain = gain }).ToList();
        return new EQPreset { Name = name, Preamp = EQMath.AutoPreamp(bands), Bands = bands };
    }

    public static readonly IReadOnlyList<EQPreset> BuiltIns =
    [
        Flat,
        Iso("Bass Booster", [6, 5.5, 5, 4, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0]),
        Iso("Bass Reducer", [-6, -5.5, -5, -4, -3, -2, -1, 0, 0, 0, 0, 0, 0, 0, 0]),
        Iso("Treble Booster", [0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 5.5, 6]),
        Iso("Vocal Booster", [-2, -2, -1.5, -1, 0, 1.5, 3, 3.5, 3.5, 3, 2, 1, 0, -1, -1.5]),
        Iso("Loudness", [6, 5, 4, 2.5, 1, 0, -1, -1.5, -1, 0, 1, 2.5, 3.5, 4, 4]),
        Iso("Acoustic", [4.5, 4.5, 4, 3, 1.5, 1, 1.5, 2, 2.5, 3, 3, 3.5, 3, 2.5, 2]),
        Iso("Electronic", [4.5, 4, 3.5, 1.5, 0, -1.5, -1, 0, 1, 1.5, 0.5, 1.5, 3.5, 4, 4.5]),
        Iso("Rock", [5, 4.5, 4, 3, 1.5, -0.5, -1, -0.5, 0.5, 1.5, 2.5, 3, 3.5, 3.5, 3.5]),
        Iso("Jazz", [4, 3.5, 3, 2, 1.5, -1, -1.5, -1.5, 0, 1, 1.5, 2, 2.5, 3, 3]),
        Iso("Classical", [4.5, 4, 3.5, 3, 2.5, 1, -1, -1.5, -1.5, -1, 0, 1, 2, 3, 3.5]),
        Iso("Small Speakers", [5.5, 5, 4.5, 3.5, 2.5, 1.5, 0.5, 0, -0.5, -1, -1.5, -2, -2.5, -3, -3.5]),
    ];
}

public static class EQMath
{
    public const int BandCount = 15;
    /// <summary>ISO 2/3-octave center frequencies.</summary>
    public static readonly double[] IsoFrequencies = [25, 40, 63, 100, 160, 250, 400, 630, 1_000, 1_600, 2_500, 4_000, 6_300, 10_000, 16_000];
    /// <summary>Q of a 2/3-octave wide band.</summary>
    public static readonly double DefaultQ = QFromBandwidth(2.0 / 3.0);

    public static readonly (double Min, double Max) FrequencyRange = (20, 20_000);
    public static readonly (double Min, double Max) GainRange = (-24, 24);
    public static readonly (double Min, double Max) QRange = (0.1, 18);

    /// <summary>Converts a Q factor to a bandwidth in octaves.</summary>
    public static double Bandwidth(double q) => 2 / Math.Log(2) * Math.Asinh(1 / (2 * q));

    public static double QFromBandwidth(double octaves) => 1 / (2 * Math.Sinh(Math.Log(2) / 2 * octaves));

    /// <summary>Magnitude response in dB of a single band at <paramref name="frequency"/> (RBJ audio EQ cookbook biquads).</summary>
    public static double Response(EQBand band, double frequency, double sampleRate = 48_000)
    {
        if (!band.IsEnabled) return 0;
        var c = Coefficients(band, sampleRate);
        var w = 2 * Math.PI * frequency / sampleRate;
        double cos1 = Math.Cos(w), sin1 = Math.Sin(w), cos2 = Math.Cos(2 * w), sin2 = Math.Sin(2 * w);
        var numRe = c.B0 + c.B1 * cos1 + c.B2 * cos2;
        var numIm = -(c.B1 * sin1 + c.B2 * sin2);
        var denRe = c.A0 + c.A1 * cos1 + c.A2 * cos2;
        var denIm = -(c.A1 * sin1 + c.A2 * sin2);
        var magnitude = Math.Sqrt((numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm));
        return 20 * Math.Log10(Math.Max(magnitude, 1e-9));
    }

    /// <summary>Combined response in dB of all bands plus preamp at <paramref name="frequency"/>.</summary>
    public static double Response(EQPreset preset, double frequency, double sampleRate = 48_000) =>
        preset.Bands.Aggregate(preset.Preamp, (sum, band) => sum + Response(band, frequency, sampleRate));

    /// <summary>Preamp that keeps the loudest boost of the curve at or below 0 dB.</summary>
    public static double AutoPreamp(IReadOnlyList<EQBand> bands, double sampleRate = 48_000)
    {
        var flat = new EQPreset { Bands = [.. bands] };
        var peak = LogSpacedFrequencies(256).Select(frequency => Response(flat, frequency, sampleRate)).DefaultIfEmpty(0).Max();
        return Math.Min(0, -peak);
    }

    public static double[] LogSpacedFrequencies(int count, double low = 20, double high = 20_000)
    {
        if (count <= 1) return [low];
        double lo = Math.Log10(low), hi = Math.Log10(high);
        return Enumerable.Range(0, count).Select(index => Math.Pow(10, lo + (hi - lo) * index / (count - 1))).ToArray();
    }

    internal readonly record struct Biquad(double B0, double B1, double B2, double A0, double A1, double A2);

    internal static Biquad Coefficients(EQBand band, double sampleRate)
    {
        var f = Math.Min(band.Frequency, sampleRate / 2 * 0.999);
        var w0 = 2 * Math.PI * f / sampleRate;
        double cosw = Math.Cos(w0), sinw = Math.Sin(w0);
        var q = Math.Max(band.Q, 0.01);
        var alpha = sinw / (2 * q);
        var a = Math.Pow(10, band.Gain / 40);
        switch (band.Type)
        {
            case EQFilterType.Peak:
                return new(1 + alpha * a, -2 * cosw, 1 - alpha * a, 1 + alpha / a, -2 * cosw, 1 - alpha / a);
            case EQFilterType.LowShelf:
            {
                var s = 2 * Math.Sqrt(a) * alpha;
                return new(a * ((a + 1) - (a - 1) * cosw + s), 2 * a * ((a - 1) - (a + 1) * cosw), a * ((a + 1) - (a - 1) * cosw - s),
                           (a + 1) + (a - 1) * cosw + s, -2 * ((a - 1) + (a + 1) * cosw), (a + 1) + (a - 1) * cosw - s);
            }
            case EQFilterType.HighShelf:
            {
                var s = 2 * Math.Sqrt(a) * alpha;
                return new(a * ((a + 1) + (a - 1) * cosw + s), -2 * a * ((a - 1) + (a + 1) * cosw), a * ((a + 1) + (a - 1) * cosw - s),
                           (a + 1) - (a - 1) * cosw + s, 2 * ((a - 1) - (a + 1) * cosw), (a + 1) - (a - 1) * cosw - s);
            }
            case EQFilterType.LowPass:
                return new((1 - cosw) / 2, 1 - cosw, (1 - cosw) / 2, 1 + alpha, -2 * cosw, 1 - alpha);
            case EQFilterType.HighPass:
                return new((1 + cosw) / 2, -(1 + cosw), (1 + cosw) / 2, 1 + alpha, -2 * cosw, 1 - alpha);
            case EQFilterType.BandPass:
                return new(alpha, 0, -alpha, 1 + alpha, -2 * cosw, 1 - alpha);
            default:
                return new(1, -2 * cosw, 1, 1 + alpha, -2 * cosw, 1 - alpha);
        }
    }
}

/// <summary>
/// Parses and writes the Equalizer APO / AutoEq <c>ParametricEQ.txt</c> format, e.g.
/// <c>Preamp: -6.2 dB</c> and <c>Filter 1: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70</c>.
/// </summary>
public static class ParametricEQFile
{
    public static EQPreset? Parse(string text, string name)
    {
        var preamp = 0.0;
        var bands = new List<EQBand>();
        foreach (var rawLine in text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var line = rawLine.Trim(' ', '\t');
            var tokens = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (line.StartsWith("preamp:", StringComparison.OrdinalIgnoreCase) && tokens.Length >= 2 && Number(tokens[1]) is { } value)
            {
                preamp = value;
                continue;
            }
            var on = Array.FindIndex(tokens, token => token is "ON" or "OFF");
            if (!line.StartsWith("filter", StringComparison.OrdinalIgnoreCase) || on < 0 || on + 1 >= tokens.Length) continue;
            EQFilterType? type = tokens[on + 1].ToUpperInvariant() switch
            {
                "PK" or "PEQ" => EQFilterType.Peak,
                "LSC" or "LS" or "LSQ" => EQFilterType.LowShelf,
                "HSC" or "HS" or "HSQ" => EQFilterType.HighShelf,
                "LP" or "LPQ" => EQFilterType.LowPass,
                "HP" or "HPQ" => EQFilterType.HighPass,
                "BP" => EQFilterType.BandPass,
                "NO" => EQFilterType.Notch,
                _ => null,
            };
            if (type is not { } filter) continue;
            double? After(string key)
            {
                var index = Array.IndexOf(tokens, key);
                return index >= 0 && index + 1 < tokens.Length ? Number(tokens[index + 1]) : null;
            }
            if (After("Fc") is not { } frequency) continue;
            bands.Add(new EQBand
            {
                IsEnabled = tokens[on] == "ON", Type = filter, Frequency = frequency, Gain = After("Gain") ?? 0,
                Q = After("Q") ?? (filter == EQFilterType.Peak ? EQMath.DefaultQ : 0.707),
            });
        }
        if (bands.Count == 0) return null;
        // Keep exactly 15 bands: drop extras, pad with neutral peaks.
        bands = bands.Take(EQMath.BandCount).ToList();
        while (bands.Count < EQMath.BandCount) bands.Add(new EQBand { IsEnabled = false, Frequency = EQMath.IsoFrequencies[bands.Count] });
        return new EQPreset { Name = name, Preamp = preamp, Bands = bands };
    }

    private static double? Number(string text) => double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) ? value : null;

    public static string Export(EQPreset preset)
    {
        var builder = new StringBuilder();
        builder.Append(CultureInfo.InvariantCulture, $"Preamp: {preset.Preamp:0.0} dB\n");
        for (var index = 0; index < preset.Bands.Count; index++)
        {
            var band = preset.Bands[index];
            var code = band.Type switch
            {
                EQFilterType.Peak => "PK",
                EQFilterType.LowShelf => "LSC",
                EQFilterType.HighShelf => "HSC",
                EQFilterType.LowPass => "LPQ",
                EQFilterType.HighPass => "HPQ",
                EQFilterType.BandPass => "BP",
                _ => "NO",
            };
            builder.Append(CultureInfo.InvariantCulture,
                $"Filter {index + 1}: {(band.IsEnabled ? "ON" : "OFF")} {code} Fc {band.Frequency:0} Hz Gain {band.Gain:0.0} dB Q {band.Q:0.00}\n");
        }
        return builder.ToString();
    }
}

/// <summary>
/// The equalizer applied to audio: up to 15 biquads in series per channel plus the preamp, built from an
/// <see cref="EQPreset"/> (the Mac uses AVAudioUnitEQ; the curves are the same RBJ filters the editor draws).
/// Coefficients swap in atomically, so a preset changes without a click while it plays.
/// </summary>
public sealed class EqualizerProcessor
{
    private sealed record Setup(double[][] Coefficients, float Preamp, bool Enabled);

    private volatile Setup setup = new([], 1, false);
    private double[] state = [];
    private int channels;
    private double sampleRate;
    private EQPreset preset = EQPreset.Flat;
    private bool enabled;

    public void Apply(EQPreset newPreset, bool isEnabled)
    {
        preset = newPreset;
        enabled = isEnabled;
        Rebuild();
    }

    /// <summary>Called by the engine when the stream's format changes.</summary>
    public void Configure(double newSampleRate, int newChannels)
    {
        if (newSampleRate == sampleRate && newChannels == channels) return;
        sampleRate = newSampleRate;
        channels = newChannels;
        state = new double[EQMath.BandCount * 4 * Math.Max(channels, 1)];
        Rebuild();
    }

    private void Rebuild()
    {
        if (sampleRate <= 0) return;
        var coefficients = preset.Bands.Take(EQMath.BandCount).Where(band => band.IsEnabled).Select(band =>
        {
            var clamped = band with
            {
                Frequency = Math.Clamp(band.Frequency, EQMath.FrequencyRange.Min, EQMath.FrequencyRange.Max),
                Gain = Math.Clamp(band.Gain, EQMath.GainRange.Min, EQMath.GainRange.Max),
                Q = Math.Clamp(band.Q, EQMath.QRange.Min, EQMath.QRange.Max),
            };
            var c = EQMath.Coefficients(clamped, sampleRate);
            return new[] { c.B0 / c.A0, c.B1 / c.A0, c.B2 / c.A0, c.A1 / c.A0, c.A2 / c.A0 };
        }).ToArray();
        setup = new Setup(coefficients, (float)Math.Pow(10, Math.Clamp(preset.Preamp, -96, 24) / 20), enabled);
    }

    public bool IsActive => setup.Enabled;

    /// <summary>Processes interleaved samples in place.</summary>
    public void Process(Span<float> samples, int frames)
    {
        var current = setup;
        if (!current.Enabled || channels == 0) return;
        var bands = current.Coefficients;
        for (var frame = 0; frame < frames; frame++)
        {
            for (var channel = 0; channel < channels; channel++)
            {
                var index = frame * channels + channel;
                double x = samples[index] * current.Preamp;
                for (var band = 0; band < bands.Length; band++)
                {
                    var c = bands[band];
                    var s = (band * channels + channel) * 4;
                    var y = c[0] * x + c[1] * state[s] + c[2] * state[s + 1] - c[3] * state[s + 2] - c[4] * state[s + 3];
                    state[s + 1] = state[s];
                    state[s] = x;
                    state[s + 3] = state[s + 2];
                    state[s + 2] = y;
                    x = y;
                }
                samples[index] = (float)x;
            }
        }
    }

    public void Reset() => Array.Clear(state);
}
