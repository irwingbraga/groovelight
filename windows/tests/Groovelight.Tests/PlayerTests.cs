using Groovelight.Audio;

namespace Groovelight.Tests;

/// <summary>The player end to end, on a manual output (rendered only when pumped) and a manual dispatcher.</summary>
public class PlayerTests
{
    private sealed class Harness : IDisposable
    {
        public ManualOutput Output { get; }
        public ManualDispatcher Dispatcher { get; } = new();
        public PlaybackController Player { get; }
        public List<long> Started { get; } = [];
        public List<(long Id, double Listened)> Finished { get; } = [];
        public List<long> Failed { get; } = [];
        public bool StoppedAfterItem { get; private set; }

        public Harness(int deviceRate = 44_100, IReadOnlyList<int>? rates = null)
        {
            Output = new ManualOutput(deviceRate, rates);
            Player = new PlaybackController(Output, Dispatcher) { Volume = 1 };
            Player.ItemStarted += item => Started.Add(item.Id);
            Player.ItemFinished += (item, listened) => Finished.Add((item.Id, listened));
            Player.ItemFailed += item => Failed.Add(item.Id);
            Player.StoppedAfterItem += () => StoppedAfterItem = true;
        }

        /// <summary>Pumps the output 1/40 s at a time (once the decoders are ahead), with the 250 ms ticker every 10 pumps.</summary>
        public void Run(Func<bool> until, double maxSeconds = 10)
        {
            var format = Output.Format ?? new AudioFormat(44_100, 2);
            var chunk = format.SampleRate / 40;
            var pumps = 0;
            var deadline = DateTime.UtcNow.AddSeconds(30);
            while (!until() && pumps < maxSeconds * 40)
            {
                while (!Player.IsReadyToRender(chunk) && DateTime.UtcNow < deadline) Thread.Sleep(1);
                Output.Pump(chunk);
                Dispatcher.RunPending();
                if (++pumps % 10 == 0) Dispatcher.Tick();
                format = Output.Format ?? format;
                chunk = format.SampleRate / 40;
            }
        }

        public float[] Left() => Output.Rendered.Where((_, index) => index % 2 == 0).ToArray();

        public void Dispose() => Player.Dispose();
    }

    private static PlayableItem Item(long id, string fixture, string? album = null) => new()
    {
        Id = id, Path = Path.Combine(AudioFixtures.Directory, fixture), Title = fixture, Duration = 1, AlbumKey = album ?? $"album-{id}",
    };

    private static float[] Decode(string fixture, int? rate = null)
    {
        using var decoder = AudioDecoder.Open(Path.Combine(AudioFixtures.Directory, fixture), outputSampleRate: rate);
        var all = new List<float>();
        var buffer = new float[4096 * decoder.Channels];
        int frames;
        while ((frames = decoder.Read(buffer)) > 0)
            for (var index = 0; index < frames; index++) all.Add(buffer[index * decoder.Channels]);
        return [.. all];
    }

    /// <summary>Songs follow each other on the exact sample: the output is the two files back to back, untouched.</summary>
    [Fact]
    public void StopsWithTheReasonWhenTheOutputCannotOpen()
    {
        using var harness = new Harness();
        harness.Output.FailsToOpen = "No sound device";
        var failures = new List<string>();
        harness.Player.OutputFailed += failures.Add;
        harness.Player.Play([Item(1, "tone.flac"), Item(2, "tone.wav")]);
        // The device, not the songs: nothing is skipped or marked as failed.
        Assert.Equal(["No sound device"], failures);
        Assert.Equal(PlaybackState.Stopped, harness.Player.State);
        Assert.Empty(harness.Failed);
        Assert.Empty(harness.Started);
        Assert.Equal("No sound device", harness.Player.LastError);

        harness.Output.FailsToOpen = null;
        harness.Player.Play([Item(1, "tone.flac")]);
        Assert.Equal(PlaybackState.Playing, harness.Player.State);
        Assert.Equal([1L], harness.Started);
    }

    [Fact]
    public void PlaysAndAdvancesGaplessly()
    {
        using var harness = new Harness();
        harness.Player.Play([Item(1, "tone.flac"), Item(2, "tone.wav")]);
        harness.Run(() => harness.Player.State == PlaybackState.Stopped);
        Assert.Equal([1L, 2], harness.Started);
        Assert.Equal([1L, 2], harness.Finished.Select(finished => finished.Id));
        Assert.True(harness.Finished[0].Listened > 0.5, $"listened {harness.Finished[0].Listened}");
        var expected = Decode("tone.flac").Concat(Decode("tone.wav")).ToArray();
        var rendered = harness.Left();
        Assert.True(rendered.Length >= expected.Length);
        Assert.Equal(expected, rendered[..expected.Length]);
        Assert.Null(harness.Player.Current);
    }

    [Fact]
    public void CrossfadesBetweenSongs()
    {
        using var harness = new Harness();
        harness.Player.CrossfadeDuration = 0.3;
        harness.Player.Play([Item(1, "tone.flac"), Item(2, "tone.wav")]);
        harness.Run(() => harness.Player.State == PlaybackState.Stopped);
        Assert.Equal([1L, 2], harness.Started);
        // The second song started while the first still played: less than two seconds in all.
        var nonSilent = Array.FindLastIndex(harness.Left(), sample => Math.Abs(sample) > 1e-4) / 44_100.0;
        Assert.InRange(nonSilent, 1.5, 1.9);
    }

    [Fact]
    public void KeepsAlbumsGaplessWithCrossfadeOn()
    {
        using var harness = new Harness();
        harness.Player.CrossfadeDuration = 0.3;
        harness.Player.Play([Item(1, "tone.flac", "same"), Item(2, "tone.wav", "same")]);
        harness.Run(() => harness.Player.State == PlaybackState.Stopped);
        var expected = Decode("tone.flac").Concat(Decode("tone.wav")).ToArray();
        Assert.Equal(expected, harness.Left()[..expected.Length]);
    }

    [Fact]
    public void StopsAfterTheCurrentSong()
    {
        using var harness = new Harness();
        harness.Player.Play([Item(1, "tone.flac"), Item(2, "tone.wav")]);
        harness.Player.StopsAfterCurrentItem = true;
        harness.Run(() => harness.Player.State == PlaybackState.Stopped);
        Assert.True(harness.StoppedAfterItem);
        Assert.Equal([1L], harness.Started);
        // The next song is selected, ready to play.
        Assert.Equal(2, harness.Player.Current?.Id);
        Assert.False(harness.Player.StopsAfterCurrentItem);
    }

    [Fact]
    public void PositionFollowsTheHeardAudioAndSeeks()
    {
        using var harness = new Harness();
        harness.Player.Play([Item(1, "tone.flac")]);
        var pumped = 0;
        harness.Run(() => ++pumped > 10);
        Assert.InRange(harness.Player.CurrentTime, 0.2, 0.3);
        var beforeSeek = harness.Left().Length;
        harness.Player.Seek(0.5);
        pumped = 0;
        harness.Run(() => ++pumped > 10);
        Assert.InRange(harness.Player.CurrentTime, 0.7, 0.8);
        // What plays after the seek is the file from 0.5 s on.
        var full = Decode("tone.flac");
        var rendered = harness.Left();
        Assert.Equal(full.AsSpan(22_050, rendered.Length - beforeSeek).ToArray(), rendered[beforeSeek..]);
    }

    [Fact]
    public void StartsAtARestoredPosition()
    {
        using var harness = new Harness();
        // A position is restored only when it is not in the song's last second (as on the Mac).
        var item = Item(1, "tone.flac") with { Duration = 10 };
        harness.Player.Restore(new PlayQueue.Snapshot([1], [1], 0, false, RepeatMode.Off), new Dictionary<long, PlayableItem> { [1] = item }, 0.5);
        Assert.Equal(0.5, harness.Player.CurrentTime);
        harness.Player.TogglePlayPause();
        Assert.Equal(PlaybackState.Playing, harness.Player.State);
        harness.Run(() => harness.Player.State == PlaybackState.Stopped);
        Assert.Equal(Decode("tone.flac")[22_050..], harness.Left()[..22_050]);
    }

    [Fact]
    public void PlaysFasterKeepingThePitch()
    {
        using var harness = new Harness();
        harness.Player.Rate = 2;
        harness.Player.Play([Item(1, "tone.flac")]);
        harness.Run(() => harness.Player.State == PlaybackState.Stopped);
        var end = Array.FindLastIndex(harness.Left(), sample => Math.Abs(sample) > 1e-4) / 44_100.0;
        Assert.InRange(end, 0.4, 0.65);
        harness.Player.Rate = 5;
        Assert.Equal(2, harness.Player.Rate);
    }

    [Fact]
    public void LevelsSongsWithTheirGain()
    {
        using var harness = new Harness();
        harness.Player.Normalization = VolumeNormalization.Track;
        harness.Player.Play([Item(1, "tone.flac") with { TrackGain = -20 * Math.Log10(2) }]);
        harness.Run(() => harness.Player.State == PlaybackState.Stopped);
        var full = Decode("tone.flac");
        var rendered = harness.Left();
        Assert.InRange(rendered.Max() / full.Max(), 0.49, 0.51);
    }

    [Fact]
    public void AppliesTheEqualizerAndVolume()
    {
        using var harness = new Harness();
        harness.Player.EqualizerPreset = new EQPreset { Bands = [new EQBand { Frequency = 440, Gain = 6, Q = 1.4 }] };
        harness.Player.EqualizerEnabled = true;
        harness.Player.Volume = 0.5f;
        harness.Player.Play([Item(1, "tone.flac")]);
        harness.Run(() => harness.Player.State == PlaybackState.Stopped);
        var ratio = harness.Left().Skip(11_025).Max() / Decode("tone.flac").Max();
        // +6 dB at 440 Hz, then half the volume: about the original level.
        Assert.InRange(ratio, 0.9, 1.1);
    }

    [Fact]
    public void SkipsSongsThatCannotPlay()
    {
        using var harness = new Harness();
        harness.Player.Play([Item(1, "missing.flac"), Item(2, "tone.flac")]);
        Assert.Equal([1L], harness.Failed);
        Assert.Equal(2, harness.Player.Current?.Id);
        // The error is cleared once the next song plays.
        Assert.Null(harness.Player.LastError);
    }

    /// <summary>Bit-perfect: the device runs at each song's rate, exclusively, and the samples arrive untouched.</summary>
    [Fact]
    public void BitPerfectFollowsTheFileRate()
    {
        using var harness = new Harness(48_000, [44_100, 48_000, 96_000]);
        harness.Player.BitPerfect = true;
        harness.Player.Volume = 0.3f;
        harness.Player.EqualizerEnabled = true;
        harness.Player.Play([new PlayableItem { Id = 1, Path = Path.Combine(AudioFixtures.Directory, "tone-hires.flac"), Duration = 1 }, Item(2, "tone.flac")]);
        Assert.Equal(new AudioFormat(96_000, 2), harness.Output.Format);
        Assert.True(harness.Output.IsExclusive);
        Assert.True(harness.Player.Output.IsBitPerfect);
        // The volume moved the device's volume, not the samples.
        Assert.Equal(0.3f, harness.Output.DeviceVolume);
        var hires = Decode("tone-hires.flac");
        harness.Run(() => harness.Output.Format?.SampleRate == 44_100 && harness.Output.Rendered.Count > 0 && harness.Player.Current?.Id == 2);
        Assert.Equal(hires, harness.Left()[..hires.Length]);
        // The next song at another rate: the device switched to it.
        Assert.Equal(2, harness.Output.OpenCount);
        Assert.Equal(44_100, harness.Player.Output.DeviceRate);
        Assert.True(harness.Player.Output.IsBitPerfect);
    }

    [Fact]
    public void BitPerfectResamplesOnlyWhatTheDeviceCannotTake()
    {
        using var harness = new Harness(48_000, [48_000, 192_000]);
        harness.Player.BitPerfect = true;
        harness.Player.Play([Item(1, "tone.flac")]);
        // 44.1 kHz is not supported: the lowest rate above it.
        Assert.Equal(48_000, harness.Output.Format?.SampleRate);
        Assert.False(harness.Player.Output.IsBitPerfect);
        Assert.Contains(harness.Player.Output.Notes, note => note.Contains("44.1 kHz"));
    }
}

public class SleepTimerTests
{
    [Fact]
    public void EndOfSongStopsAfterTheCurrentSong()
    {
        var dispatcher = new ManualDispatcher();
        using var player = new PlaybackController(new ManualOutput(44_100), dispatcher);
        var timer = new SleepTimer(player, dispatcher);
        timer.Start(new SleepTimer.TimerMode.EndOfSong());
        Assert.True(player.StopsAfterCurrentItem);
        Assert.Equal("Stops after this song", timer.Summary);
        timer.Cancel();
        Assert.False(player.StopsAfterCurrentItem);
        Assert.False(timer.IsActive);
    }

    [Fact]
    public void MinutesSaysTheTimeLeft()
    {
        var dispatcher = new ManualDispatcher();
        using var player = new PlaybackController(new ManualOutput(44_100), dispatcher);
        var timer = new SleepTimer(player, dispatcher);
        timer.Start(new SleepTimer.TimerMode.Minutes(30));
        Assert.Equal("30 min left", timer.Summary);
        timer.Cancel();
        Assert.Null(timer.Summary);
    }
}
