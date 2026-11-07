namespace Groovelight.Audio;

/// <summary>
/// Integrated loudness of a song (EBU R128 / ITU-R BS.1770, in LUFS), for volume normalization of songs without
/// ReplayGain tags: K-weighting, 400 ms blocks every 100 ms, then the absolute (-70 LUFS) and relative (-10 LU) gates.
/// </summary>
public static class LoudnessMeter
{
    /// <summary>ReplayGain 2 reference level: a song measured at -18 LUFS needs no gain.</summary>
    public const double ReferenceLufs = -18.0;

    /// <summary>The gain (dB) that brings a song of <paramref name="loudness"/> LUFS to the reference.</summary>
    public static double Gain(double loudness) => ReferenceLufs - loudness;

    /// <summary>Measures a file, or the region of it a cue track covers (seconds). Null for silence.</summary>
    public static double? Measure(string path, double? start = null, double? end = null)
    {
        using var decoder = AudioDecoder.Open(path, start, end);
        var meter = new Meter(decoder.SampleRate, decoder.Channels);
        var buffer = new float[16_384 * decoder.Channels];
        int frames;
        while ((frames = decoder.Read(buffer)) > 0) meter.Add(buffer, frames);
        return meter.IntegratedLoudness();
    }

    /// <summary>The meter itself, fed with interleaved float samples.</summary>
    public sealed class Meter
    {
        private readonly Biquad[][] filters;
        private readonly int step;
        /// <summary>Mean square energy of each 100 ms step, per channel summed.</summary>
        private readonly List<double> stepEnergies = [];
        private double current;
        private int inStep;

        public Meter(double sampleRate, int channels)
        {
            filters = Enumerable.Range(0, Math.Max(channels, 1)).Select(_ => Biquad.KWeighting(sampleRate)).ToArray();
            step = Math.Max((int)(sampleRate / 10), 1);
        }

        public void Add(ReadOnlySpan<float> samples, int frames)
        {
            var channels = filters.Length;
            for (var frame = 0; frame < frames; frame++)
            {
                var energy = 0.0;
                for (var channel = 0; channel < channels; channel++)
                {
                    double sample = samples[frame * channels + channel];
                    foreach (ref var stage in filters[channel].AsSpan()) sample = stage.Process(sample);
                    // Channel weights are 1 for left, right and center (surround channels are rare in music libraries).
                    energy += sample * sample;
                }
                current += energy;
                if (++inStep == step)
                {
                    stepEnergies.Add(current / step);
                    current = 0;
                    inStep = 0;
                }
            }
        }

        public double? IntegratedLoudness()
        {
            // 400 ms blocks, overlapping by 75%: four consecutive 100 ms steps.
            if (stepEnergies.Count < 4) return null;
            var blocks = Enumerable.Range(0, stepEnergies.Count - 3).Select(index => (stepEnergies[index] + stepEnergies[index + 1] + stepEnergies[index + 2] + stepEnergies[index + 3]) / 4).ToList();
            static double Loudness(double energy) => -0.691 + 10 * Math.Log10(energy);
            var absolute = blocks.Where(energy => energy > 0 && Loudness(energy) > -70).ToList();
            if (absolute.Count == 0) return null;
            var relativeGate = Loudness(absolute.Average()) - 10;
            var gated = absolute.Where(energy => Loudness(energy) > relativeGate).ToList();
            return gated.Count == 0 ? null : Loudness(gated.Average());
        }
    }

    /// <summary>A second order filter (direct form I).</summary>
    internal struct Biquad(double b0, double b1, double b2, double a1, double a2)
    {
        private double x1, x2, y1, y2;

        public double Process(double x)
        {
            var y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
            x2 = x1; x1 = x;
            y2 = y1; y1 = y;
            return y;
        }

        /// <summary>BS.1770 K-weighting at any sample rate (libebur128's formulas): a high shelf, then a high pass.</summary>
        public static Biquad[] KWeighting(double fs)
        {
            // High shelf: about +4 dB above 1.7 kHz.
            const double f0 = 1681.974450955533, gain = 3.999843853973347, q = 0.7071752369554196;
            var k = Math.Tan(Math.PI * f0 / fs);
            var vh = Math.Pow(10, gain / 20);
            var vb = Math.Pow(vh, 0.4996667741545416);
            var a0 = 1 + k / q + k * k;
            var shelf = new Biquad((vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0,
                                   2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0);
            // High pass at about 38 Hz.
            const double hf = 38.13547087602444, hq = 0.5003270373238773;
            k = Math.Tan(Math.PI * hf / fs);
            a0 = 1 + k / hq + k * k;
            var pass = new Biquad(1, -2, 1, 2 * (k * k - 1) / a0, (1 - k / hq + k * k) / a0);
            return [shelf, pass];
        }
    }
}
