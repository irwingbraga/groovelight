using System.Collections.Concurrent;
using SoundTouch;

namespace Groovelight.Audio;

/// <summary>Something that happened on the audio thread, handed to the player.</summary>
internal abstract record DeckEvent(Deck Deck)
{
    /// <summary>A queued song started right after the previous one (a gapless transition).</summary>
    public sealed record Started(Deck Deck, SourceEntry Entry) : DeckEvent(Deck);
    /// <summary>The deck played everything it had.</summary>
    public sealed record Ended(Deck Deck) : DeckEvent(Deck);
}

/// <summary>
/// One player and its processing chain: <c>source -> speed (SoundTouch) -> loudness gain -> equalizer -> volume</c>.
/// Two decks let a song fade into the next one.
/// </summary>
internal sealed class Deck : IDisposable
{
    public int Index { get; }
    public EqualizerProcessor Equalizer { get; } = new();
    private DeckStream? stream;
    private AudioFormat format;
    private SoundTouchProcessor? stretch;
    private volatile float speed = 1;
    private volatile float gain = 1;
    private readonly ConcurrentQueue<DeckEvent> events;
    private readonly Action notify;
    private bool endReported;
    private float[] input = [];

    /// <summary>The deck's volume and where a ramp takes it (equal power for crossfades).</summary>
    private float volume;
    private float rampFrom, rampTo;
    private long rampFrames, rampDone;
    private bool rampEqualPower;
    private readonly Lock rampGate = new();
    /// <summary>Held while rendering and while the player changes the chain (SoundTouch is not thread safe).</summary>
    private readonly Lock renderGate = new();

    /// <summary>Whether this deck feeds the analyzer (the deck playing the current song).</summary>
    public volatile bool TapOpen;

    public Deck(int index, ConcurrentQueue<DeckEvent> events, Action notify)
    {
        Index = index;
        this.events = events;
        this.notify = notify;
    }

    public AudioFormat Format => format;
    public bool IsActive => stream?.Current is not null;
    public SourceEntry? Current => stream?.Current;

    /// <summary>Sets the format the deck renders at (a new stream when it changes).</summary>
    public void Configure(AudioFormat newFormat)
    {
        lock (renderGate)
        {
            if (newFormat == format && stream is not null) return;
            format = newFormat;
            stream?.Dispose();
            stream = new DeckStream(format.Channels, format.SampleRate);
            Equalizer.Configure(format.SampleRate, format.Channels);
            stretch = null;
            SetSpeed(speed);
        }
    }

    public void Play(SourceEntry entry)
    {
        lock (renderGate)
        {
            stretch?.Clear();
            Equalizer.Reset();
            endReported = false;
            stream!.Start(entry);
        }
    }

    public void Enqueue(SourceEntry entry)
    {
        endReported = false;
        stream!.Enqueue(entry);
    }

    public void ClearQueue() => stream?.ClearQueue();

    public void Seek(double seconds)
    {
        lock (renderGate)
        {
            stretch?.Clear();
            endReported = false;
            stream?.Seek(seconds);
        }
    }

    public void Stop()
    {
        lock (renderGate)
        {
            stretch?.Clear();
            stream?.Stop();
            endReported = false;
        }
    }

    /// <summary>Speed with the pitch kept (1: not processed at all, so the sound stays untouched).</summary>
    public void SetSpeed(float rate)
    {
        lock (renderGate)
        {
            speed = rate;
            if (rate == 1 || format.SampleRate == 0) return;
            stretch ??= new SoundTouchProcessor { SampleRate = format.SampleRate, Channels = format.Channels };
            stretch.Tempo = rate;
        }
    }

    public float Speed => speed;

    /// <summary>Loudness gain in dB (null: none). Boosts are limited, as the songs' peaks are not known.</summary>
    public void SetGain(double? decibels) => gain = decibels is { } db ? (float)Math.Pow(10, Math.Clamp(db, -24, 6) / 20) : 1;

    public void SetVolume(float value)
    {
        lock (rampGate)
        {
            volume = rampTo = value;
            rampFrames = 0;
        }
    }

    /// <summary>Moves the volume to <paramref name="target"/> over <paramref name="seconds"/>, on an equal-power curve.</summary>
    public void FadeTo(float target, double seconds)
    {
        lock (rampGate)
        {
            rampFrom = volume;
            rampTo = target;
            rampFrames = Math.Max(1, (long)(seconds * Math.Max(format.SampleRate, 1)));
            rampDone = 0;
            rampEqualPower = true;
        }
    }

    public bool IsFading { get { lock (rampGate) return rampFrames > 0 && rampDone < rampFrames; } }

    /// <summary>Frames of the current song heard so far (read from the stream, less what speed processing still holds).</summary>
    public double CurrentTime
    {
        get
        {
            if (stream?.Current is null || format.SampleRate == 0) return 0;
            var held = stretch is not null && speed != 1 ? stretch.UnprocessedSampleCount : 0;
            return Math.Max(0, (stream.CurrentFrames - held) / (double)format.SampleRate);
        }
    }

    /// <summary>Renders into <paramref name="mix"/>, adding to what is there; the deck's own output (before volume) goes to <paramref name="tap"/>.</summary>
    public void Render(Span<float> mix, int frames, Span<float> tap)
    {
        lock (renderGate)
        {
            tap[..(frames * format.Channels)].Clear();
            if (stream is null || stream.Current is null)
            {
                return;
            }
            var channels = format.Channels;
            var produced = speed == 1 && (stretch is null || stretch.AvailableSamples == 0) ? ReadSource(tap, frames) : ReadStretched(tap, frames);
            if (produced == 0 && !endReported && stream.Current is not null && stream.Buffered == 0 && endOfSource)
            {
                endReported = true;
                events.Enqueue(new DeckEvent.Ended(this));
                notify();
            }
            var samples = tap[..(frames * channels)];
            if (gain != 1)
            {
                for (var index = 0; index < produced * channels; index++) samples[index] *= gain;
            }
            Equalizer.Process(samples, produced);
            lock (rampGate)
            {
                for (var frame = 0; frame < frames; frame++)
                {
                    if (rampFrames > 0 && rampDone < rampFrames)
                    {
                        rampDone++;
                        var progress = rampDone / (double)rampFrames;
                        volume = rampEqualPower
                            ? (float)(rampTo > rampFrom ? rampTo * Math.Sin(progress * Math.PI / 2) + rampFrom * Math.Cos(progress * Math.PI / 2)
                                                        : rampFrom * Math.Cos(progress * Math.PI / 2) + rampTo * Math.Sin(progress * Math.PI / 2))
                            : (float)(rampFrom + (rampTo - rampFrom) * progress);
                        if (rampDone == rampFrames) volume = rampTo;
                    }
                    for (var channel = 0; channel < channels; channel++) mix[frame * channels + channel] += samples[frame * channels + channel] * volume;
                }
            }
        }
    }

    private bool endOfSource;

    private int ReadSource(Span<float> output, int frames)
    {
        var (count, started, ended) = stream!.Read(output, frames);
        Report(started);
        endOfSource = ended;
        return count;
    }

    private int ReadStretched(Span<float> output, int frames)
    {
        var channels = format.Channels;
        stretch ??= new SoundTouchProcessor { SampleRate = format.SampleRate, Channels = channels, Tempo = speed };
        if (stretch.Tempo != speed && speed != 1) stretch.Tempo = speed;
        var needed = frames;
        if (input.Length < 2048 * channels) input = new float[2048 * channels];
        while (stretch.AvailableSamples < needed)
        {
            var (count, started, ended) = stream!.Read(input, 2048);
            Report(started);
            if (count == 0)
            {
                endOfSource = ended;
                if (ended) stretch.Flush();
                break;
            }
            stretch.PutSamples(input.AsSpan(0, count * channels), count);
        }
        var span = output[..(frames * channels)];
        var received = stretch.ReceiveSamples(span, frames);
        if (speed == 1 && stretch.AvailableSamples == 0) stretch.Clear();
        return received;
    }

    private void Report(List<SourceEntry>? started)
    {
        if (started is null) return;
        foreach (var entry in started) events.Enqueue(new DeckEvent.Started(this, entry));
        notify();
    }

    public long Buffered => stream?.Buffered ?? 0;

    /// <summary>Whether a render of <paramref name="frames"/> frames will not run dry (tests pump the output only then).</summary>
    internal bool IsReady(int frames) => stream is null || stream.Current is null || stream.IsReady((int)Math.Ceiling(frames * Math.Max(speed, 1f)) + 4096);

    public void Dispose() => stream?.Dispose();
}
