using System.Numerics;

namespace Groovelight.Audio;

/// <summary>One snapshot of the audio being played, ready for visualizers and level meters.</summary>
public sealed record SpectrumFrame
{
    public const int BandCount = 64;
    public const int WaveformCount = 512;

    /// <summary>Log-spaced band magnitudes in 0...1, low to high frequency.</summary>
    public float[] Bands { get; init; } = new float[BandCount];
    /// <summary>Mono waveform samples in -1...1.</summary>
    public float[] Waveform { get; init; } = new float[WaveformCount];
    public float Bass { get; init; }
    public float Mid { get; init; }
    public float Treble { get; init; }
    /// <summary>Overall loudness in 0...1.</summary>
    public float Level { get; init; }
    /// <summary>True on the frame where an onset (beat) was detected.</summary>
    public bool IsBeat { get; init; }
    /// <summary>Increments on every detected beat, so readers polling at a different rate never miss one.</summary>
    public int BeatCount { get; init; }
    /// <summary>Each channel's RMS (linear, 0...1) over the last buffer, for level meters. A mono song has the same level in both.</summary>
    public float LeftLevel { get; init; }
    public float RightLevel { get; init; }

    public static readonly SpectrumFrame Silent = new();
}

/// <summary>
/// Runs an FFT over the audio being played and publishes the latest <see cref="SpectrumFrame"/>. <see cref="Process"/>
/// runs on the audio thread; <see cref="LatestFrame"/> can be read from any thread.
/// </summary>
public sealed class SpectrumAnalyzer
{
    public const int FftSize = 1024;

    private readonly Lock gate = new();
    private SpectrumFrame frame = SpectrumFrame.Silent;
    private float[] previousMagnitudes = new float[FftSize / 2];
    private readonly float[] fluxHistory = new float[43];
    private int fluxIndex;
    private int framesSinceBeat;
    private int beatCount;
    private readonly float[] window = Enumerable.Range(0, FftSize).Select(index => (float)(0.5 - 0.5 * Math.Cos(2 * Math.PI * index / FftSize))).ToArray();
    /// <summary>The newest samples (mono), filled as audio arrives; the FFT runs over the last <see cref="FftSize"/>.</summary>
    private readonly float[] ring = new float[FftSize];
    private int ringFill;

    public SpectrumFrame LatestFrame { get { lock (gate) return frame; } }

    public void Reset()
    {
        lock (gate)
        {
            frame = SpectrumFrame.Silent;
            previousMagnitudes = new float[FftSize / 2];
            Array.Clear(fluxHistory);
            fluxIndex = framesSinceBeat = beatCount = ringFill = 0;
            Array.Clear(ring);
        }
    }

    /// <summary>Takes interleaved samples as they are played.</summary>
    public void Process(ReadOnlySpan<float> samples, int frames, int channels, double sampleRate)
    {
        if (frames <= 0 || channels <= 0) return;
        // Each channel's RMS over the buffer, before the mix down.
        double left = 0, right = 0;
        for (var index = 0; index < frames; index++)
        {
            var l = samples[index * channels];
            var r = channels > 1 ? samples[index * channels + 1] : l;
            left += l * l;
            right += r * r;
        }
        // Mix down to mono into the ring of the newest samples.
        var count = Math.Min(frames, FftSize);
        var start = frames - count;
        Array.Copy(ring, count, ring, 0, FftSize - count);
        for (var index = 0; index < count; index++)
        {
            var sum = 0f;
            for (var channel = 0; channel < channels; channel++) sum += samples[(start + index) * channels + channel];
            ring[FftSize - count + index] = sum / channels;
        }
        ringFill = Math.Min(FftSize, ringFill + count);

        var mono = ring;
        var magnitudes = Magnitudes(mono);
        var waveform = new float[SpectrumFrame.WaveformCount];
        var stride = FftSize / SpectrumFrame.WaveformCount;
        for (var index = 0; index < waveform.Length; index++) waveform[index] = mono[index * stride];
        var bands = LogBands(magnitudes, sampleRate, SpectrumFrame.BandCount);
        double squares = 0;
        foreach (var sample in mono) squares += sample * sample;
        var rms = (float)Math.Sqrt(squares / FftSize);

        lock (gate)
        {
            // Spectral flux onset detection against a ~1 s moving average.
            var flux = 0f;
            for (var index = 0; index < Math.Min(magnitudes.Length, 128); index++)
            {
                var diff = magnitudes[index] - previousMagnitudes[index];
                if (diff > 0) flux += diff;
            }
            previousMagnitudes = magnitudes;
            var average = fluxHistory.Average();
            fluxHistory[fluxIndex] = flux;
            fluxIndex = (fluxIndex + 1) % fluxHistory.Length;
            framesSinceBeat++;
            var isBeat = flux > average * 1.5f && flux > 0.05f && framesSinceBeat > 8;
            if (isBeat)
            {
                framesSinceBeat = 0;
                beatCount++;
            }
            var third = bands.Length / 3;
            frame = new SpectrumFrame
            {
                Bands = bands, Waveform = waveform,
                Bass = bands[..third].Average(), Mid = bands[third..(2 * third)].Average(), Treble = bands[(2 * third)..].Average(),
                Level = Math.Min(1, rms * 2.5f), IsBeat = isBeat, BeatCount = beatCount,
                LeftLevel = (float)Math.Sqrt(left / frames), RightLevel = (float)Math.Sqrt(right / frames),
            };
        }
    }

    /// <summary>Hann-windowed FFT magnitudes, scaled as the Mac's (2 / N).</summary>
    private float[] Magnitudes(float[] samples)
    {
        var data = new Complex[FftSize];
        for (var index = 0; index < FftSize; index++) data[index] = new Complex(samples[index] * window[index], 0);
        Fft(data);
        var magnitudes = new float[FftSize / 2];
        const float norm = 2f / FftSize;
        for (var index = 0; index < magnitudes.Length; index++) magnitudes[index] = (float)data[index].Magnitude * norm;
        return magnitudes;
    }

    /// <summary>In-place iterative radix-2 FFT.</summary>
    internal static void Fft(Complex[] data)
    {
        var n = data.Length;
        for (int i = 1, j = 0; i < n; i++)
        {
            var bit = n >> 1;
            for (; (j & bit) != 0; bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) (data[i], data[j]) = (data[j], data[i]);
        }
        for (var length = 2; length <= n; length <<= 1)
        {
            var angle = -2 * Math.PI / length;
            var step = new Complex(Math.Cos(angle), Math.Sin(angle));
            for (var start = 0; start < n; start += length)
            {
                var w = Complex.One;
                for (var k = 0; k < length / 2; k++)
                {
                    var even = data[start + k];
                    var odd = data[start + k + length / 2] * w;
                    data[start + k] = even + odd;
                    data[start + k + length / 2] = even - odd;
                    w *= step;
                }
            }
        }
    }

    /// <summary>Groups linear FFT bins into log-spaced bands between 30 Hz and 16 kHz, normalized to 0...1.</summary>
    internal static float[] LogBands(float[] magnitudes, double sampleRate, int count)
    {
        var binWidth = sampleRate / FftSize;
        double lo = Math.Log10(30.0), hi = Math.Log10(Math.Min(16_000, sampleRate / 2));
        var bands = new float[count];
        for (var band = 0; band < count; band++)
        {
            var f0 = Math.Pow(10, lo + (hi - lo) * band / count);
            var f1 = Math.Pow(10, lo + (hi - lo) * (band + 1) / count);
            var start = Math.Max(1, (int)(f0 / binWidth));
            var end = Math.Max(start + 1, Math.Min(magnitudes.Length, (int)Math.Ceiling(f1 / binWidth)));
            var peak = 0f;
            for (var bin = start; bin < end; bin++) peak = Math.Max(peak, magnitudes[bin]);
            // Magnitude to dB, mapped from a -70...0 dB window into 0...1.
            var db = 20 * Math.Log10(Math.Max(peak, 1e-7));
            bands[band] = (float)Math.Min(1, Math.Max(0, (db + 70) / 70));
        }
        return bands;
    }
}
