using Groovelight.Audio;

namespace Groovelight.Tests;

public class PlayQueueTests
{
    internal static List<PlayableItem> Items(int count) =>
        Enumerable.Range(1, count).Select(id => new PlayableItem { Id = id, Path = $"/m/{id}.flac", Title = $"T{id}", Artist = "A", Album = "B", Duration = 100 }).ToList();

    [Fact]
    public void AdvancesAndStopsAtEnd()
    {
        var queue = new PlayQueue();
        queue.Set(Items(3), 1);
        Assert.Equal(2, queue.Current?.Id);
        Assert.Equal(3, queue.NextForAutoAdvance?.Id);
        Assert.Equal(3, queue.AdvanceAfterEnd()?.Id);
        Assert.Null(queue.NextForAutoAdvance);
        Assert.Null(queue.AdvanceAfterEnd());
        Assert.Null(queue.Current);
    }

    [Fact]
    public void RepeatModes()
    {
        var queue = new PlayQueue();
        queue.Set(Items(2), 1);
        queue.RepeatMode = RepeatMode.All;
        Assert.Equal(1, queue.NextForAutoAdvance?.Id);
        Assert.Equal(1, queue.AdvanceAfterEnd()?.Id);
        queue.RepeatMode = RepeatMode.One;
        Assert.Equal(1, queue.NextForAutoAdvance?.Id);
        Assert.Equal(1, queue.AdvanceAfterEnd()?.Id);
        // Next escapes repeat-one.
        Assert.Equal(2, queue.SkipForward()?.Id);
    }

    [Fact]
    public void ShuffleKeepsStartFirstAndRestoresOrder()
    {
        var queue = new PlayQueue();
        queue.Set(Items(10), 4, shuffle: true, new Random(42));
        Assert.Equal(5, queue.Current?.Id);
        Assert.Equal(Enumerable.Range(1, 10).Select(id => (long)id).ToHashSet(), queue.Items.Select(item => item.Id).ToHashSet());
        queue.SetShuffle(false);
        Assert.Equal(Enumerable.Range(1, 10).Select(id => (long)id), queue.Items.Select(item => item.Id));
        Assert.Equal(5, queue.Current?.Id);
    }

    [Fact]
    public void PlayNextAndLater()
    {
        var queue = new PlayQueue();
        queue.Set(Items(3));
        var extra = new PlayableItem { Id = 99, Path = "/m/99.mp3", Title = "X", Duration = 1 };
        queue.PlayNext([extra]);
        Assert.Equal(99, queue.Upcoming[0].Id);
        queue.PlayLater([extra with { Id = 100 }]);
        Assert.Equal(100, queue.Items[^1].Id);
    }

    [Fact]
    public void RemovingBeforeCurrentKeepsCurrent()
    {
        var queue = new PlayQueue();
        queue.Set(Items(4), 2);
        queue.Remove(0);
        Assert.Equal(3, queue.Current?.Id);
        queue.Move([2], 0);
        Assert.Equal(3, queue.Current?.Id);
        Assert.Equal(4, queue.Items[0].Id);
    }

    [Fact]
    public void SnapshotRestoresTheQueue()
    {
        var queue = new PlayQueue();
        queue.Set(Items(6), 2, shuffle: true, new Random(7));
        queue.RepeatMode = RepeatMode.All;
        queue.PlayNext([Items(9)[8]]);
        var json = System.Text.Json.JsonSerializer.Serialize(queue.TakeSnapshot(), Groovelight.Core.SwiftJson.Options);
        var saved = System.Text.Json.JsonSerializer.Deserialize<PlayQueue.Snapshot>(json, Groovelight.Core.SwiftJson.Options)!;
        var restored = new PlayQueue();
        restored.Restore(saved, Items(9).ToDictionary(item => item.Id));
        Assert.Equal(queue.Items, restored.Items);
        Assert.Equal(queue.Current, restored.Current);
        Assert.True(restored.IsShuffled);
        Assert.Equal(RepeatMode.All, restored.RepeatMode);
        // Turning shuffle off goes back to the original order, as before the restart.
        restored.SetShuffle(false);
        queue.SetShuffle(false);
        Assert.Equal(queue.Items, restored.Items);
        // The Mac's snapshot keys.
        Assert.Contains("\"itemIds\"", json);
        Assert.Contains("\"repeatMode\":\"all\"", json);
    }

    [Fact]
    public void SnapshotSkipsRemovedSongs()
    {
        var queue = new PlayQueue();
        queue.Set(Items(5), 2);
        var available = Items(5).ToDictionary(item => item.Id);
        available.Remove(1);
        available.Remove(3);
        var restored = new PlayQueue();
        restored.Restore(queue.TakeSnapshot(), available);
        Assert.Equal([2L, 4, 5], restored.Items.Select(item => item.Id));
        Assert.Equal(4, restored.Current?.Id);
        restored.Restore(queue.TakeSnapshot(), new Dictionary<long, PlayableItem>());
        Assert.Empty(restored.Items);
        Assert.Null(restored.Current);
    }
}

public class EqualizerTests
{
    [Fact]
    public void QAndBandwidthRoundTrip()
    {
        foreach (var q in new[] { 0.3, 0.707, 1.41, 4.0, 10.0 }) Assert.True(Math.Abs(EQMath.QFromBandwidth(EQMath.Bandwidth(q)) - q) < 1e-9);
        // One octave is Q ~ 1.414.
        Assert.True(Math.Abs(EQMath.QFromBandwidth(1) - 1.4142) < 0.001);
    }

    [Fact]
    public void PeakBandHitsItsGainAtCenter()
    {
        var band = new EQBand { Frequency = 1_000, Gain = 6, Q = 1.4 };
        Assert.True(Math.Abs(EQMath.Response(band, 1_000) - 6) < 0.01);
        Assert.True(Math.Abs(EQMath.Response(band, 20)) < 0.1);
    }

    [Fact]
    public void DisabledAndFlatBandsAreNeutral()
    {
        Assert.Equal(0, EQMath.Response(new EQBand { IsEnabled = false, Frequency = 100, Gain = 12 }, 100));
        foreach (var frequency in EQMath.LogSpacedFrequencies(20)) Assert.True(Math.Abs(EQMath.Response(EQPreset.Flat, frequency)) < 1e-6);
    }

    [Fact]
    public void AutoPreampCancelsMaxBoost()
    {
        Assert.True(Math.Abs(EQMath.AutoPreamp([new EQBand { Frequency = 100, Gain = 9, Q = 1 }]) + 9) < 0.2);
        Assert.Equal(0, EQMath.AutoPreamp([new EQBand { Frequency = 100, Gain = -6 }]));
    }

    [Fact]
    public void BuiltInPresetsHaveFifteenBands()
    {
        foreach (var preset in EQPreset.BuiltIns)
        {
            Assert.Equal(EQMath.BandCount, preset.Bands.Count);
            Assert.True(preset.Preamp <= 0);
        }
    }

    [Fact]
    public void ParsesAutoEqFile()
    {
        var preset = ParametricEQFile.Parse("""
            Preamp: -6.2 dB
            Filter 1: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70
            Filter 2: ON PK Fc 160 Hz Gain -2.1 dB Q 0.83
            Filter 3: OFF HSC Fc 10000 Hz Gain 3.0 dB Q 0.70
            """, "HD 600")!;
        Assert.Equal(-6.2, preset.Preamp);
        Assert.Equal(15, preset.Bands.Count);
        Assert.Equal(new EQBand { Type = EQFilterType.LowShelf, Frequency = 105, Gain = 5.5, Q = 0.70 }, preset.Bands[0]);
        Assert.Equal(EQFilterType.Peak, preset.Bands[1].Type);
        Assert.False(preset.Bands[2].IsEnabled);
        Assert.False(preset.Bands[3].IsEnabled);
        var reparsed = ParametricEQFile.Parse(ParametricEQFile.Export(preset), "HD 600")!;
        Assert.Equal(105, reparsed.Bands[0].Frequency);
        Assert.Equal(-2.1, reparsed.Bands[1].Gain);
    }

    /// <summary>Presets saved by the Mac (in backups and preferences) read back here.</summary>
    [Fact]
    public void ReadsTheMacsPresetJson()
    {
        const string mac = """{"name":"Mine","preamp":-3.5,"bands":[{"isEnabled":true,"type":"lowShelf","frequency":105,"gain":5.5,"q":0.7}]}""";
        var preset = System.Text.Json.JsonSerializer.Deserialize<EQPreset>(mac, Groovelight.Core.SwiftJson.Options)!;
        Assert.Equal(("Mine", -3.5), (preset.Name, preset.Preamp));
        Assert.Equal(new EQBand { Type = EQFilterType.LowShelf, Frequency = 105, Gain = 5.5, Q = 0.7 }, preset.Bands[0]);
    }

    /// <summary>The processor follows the curve: a sine at a boosted band comes out louder by the band's gain.</summary>
    [Fact]
    public void ProcessorAppliesTheCurve()
    {
        var processor = new EqualizerProcessor();
        processor.Configure(48_000, 1);
        processor.Apply(new EQPreset { Bands = [new EQBand { Frequency = 1_000, Gain = 6, Q = 1.4 }] }, isEnabled: true);
        var samples = Enumerable.Range(0, 48_000).Select(index => (float)(0.25 * Math.Sin(2 * Math.PI * 1_000 * index / 48_000))).ToArray();
        processor.Process(samples, samples.Length);
        var peak = samples.Skip(24_000).Max();
        Assert.InRange(20 * Math.Log10(peak / 0.25), 5.8, 6.2);
        // Off: untouched.
        processor.Apply(EQPreset.Flat, isEnabled: false);
        var untouched = new[] { 0.5f, -0.25f };
        processor.Process(untouched, 2);
        Assert.Equal([0.5f, -0.25f], untouched);
    }
}

public class SignalTests
{
    [Fact]
    public void SineLightsUpTheMatchingBand()
    {
        var samples = new float[1024 * 2];
        for (var index = 0; index < 1024; index++) samples[index * 2] = samples[index * 2 + 1] = (float)(0.5 * Math.Sin(2 * Math.PI * 1_000 * index / 44_100));
        var analyzer = new SpectrumAnalyzer();
        analyzer.Process(samples, 1024, 2, 44_100);
        var frame = analyzer.LatestFrame;
        var loudest = Array.IndexOf(frame.Bands, frame.Bands.Max());
        // Band centers are log spaced from 30 Hz to 16 kHz; 1 kHz sits a bit past the middle.
        var expected = (int)(Math.Log10(1_000 / 30.0) / Math.Log10(16_000 / 30.0) * SpectrumFrame.BandCount);
        Assert.InRange(loudest, expected - 1, expected + 1);
        Assert.True(frame.Level > 0.3);
        Assert.Equal(SpectrumFrame.WaveformCount, frame.Waveform.Length);
        Assert.InRange(frame.LeftLevel, 0.34, 0.37);
    }

    /// <summary>A stereo 32-bit float WAV of a 997 Hz sine.</summary>
    private static string Tone(string folder, string name, float amplitude, double seconds = 5)
    {
        var path = Path.Combine(folder, name);
        const int rate = 48_000;
        var frames = (int)(rate * seconds);
        using var writer = new BinaryWriter(File.Create(path));
        writer.Write("RIFF"u8); writer.Write(36 + frames * 8); writer.Write("WAVE"u8);
        writer.Write("fmt "u8); writer.Write(16); writer.Write((short)3); writer.Write((short)2); writer.Write(rate); writer.Write(rate * 8);
        writer.Write((short)8); writer.Write((short)32);
        writer.Write("data"u8); writer.Write(frames * 8);
        for (var index = 0; index < frames; index++)
        {
            var sample = amplitude * (float)Math.Sin(2 * Math.PI * 997 * index / rate);
            writer.Write(sample); writer.Write(sample);
        }
        return path;
    }

    [Fact]
    public void MeasuresSineWavesAtKnownLevels()
    {
        using var scratch = new ScratchFolder();
        // BS.1770: a full scale 997 Hz sine on both channels of a stereo file measures 0 LUFS (-3.01 per channel).
        var full = LoudnessMeter.Measure(Tone(scratch.Path, "full.wav", 1))!.Value;
        Assert.True(Math.Abs(full) < 0.3, $"full scale measured {full} LUFS");
        var quiet = LoudnessMeter.Measure(Tone(scratch.Path, "quiet.wav", 0.1f))!.Value;
        Assert.True(Math.Abs(quiet + 20) < 0.3, $"-20 dBFS measured {quiet} LUFS");
        Assert.True(Math.Abs(LoudnessMeter.Gain(quiet) - 2) < 0.3);
        // A region of the file (cue tracks): the same level.
        var region = LoudnessMeter.Measure(Tone(scratch.Path, "region.wav", 0.1f), 1, 3)!.Value;
        Assert.True(Math.Abs(region + 20) < 0.3);
        // Silence has no loudness.
        Assert.Null(LoudnessMeter.Measure(Tone(scratch.Path, "silent.wav", 0)));
    }
}
