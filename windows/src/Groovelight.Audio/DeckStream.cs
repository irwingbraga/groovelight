namespace Groovelight.Audio;

/// <summary>A song on its way to a deck: its decoder (opened at the engine's rate) and an identity for transitions.</summary>
public sealed class SourceEntry(PlayableItem item, AudioDecoder decoder) : IDisposable
{
    public PlayableItem Item { get; } = item;
    public AudioDecoder Decoder { get; } = decoder;
    public void Dispose() => Decoder.Dispose();
}

/// <summary>
/// A deck's source: a background thread decodes the current song, then the songs queued after it, into a ring buffer,
/// marking where each one starts, so the audio thread never waits on a disk and the next song begins on the exact sample
/// after the last one (SFBAudioEngine's decoder queue on the Mac).
/// </summary>
internal sealed class DeckStream : IDisposable
{
    private readonly int channels;
    private readonly float[] ring;
    private readonly int capacity;
    /// <summary>Frames ever written and read; ring positions are these modulo the capacity.</summary>
    private long written, read;
    /// <summary>Songs whose samples are in the ring, with the frame (in written count) where each starts.</summary>
    private readonly LinkedList<(long Start, SourceEntry Entry)> starts = new();
    /// <summary>The song being decoded, and the songs queued after it.</summary>
    private SourceEntry? decoding;
    private readonly Queue<SourceEntry> queued = new();
    /// <summary>Written count where the last song ended with nothing after it (end of audio), if so.</summary>
    private long? endAt;
    private readonly Lock gate = new();
    private readonly Thread thread;
    private volatile bool disposed;
    private readonly AutoResetEvent wake = new(false);

    /// <summary>The song the reader is in, and frames read of it.</summary>
    public SourceEntry? Current { get; private set; }
    public long CurrentFrames { get; private set; }

    public DeckStream(int channels, int sampleRate, double seconds = 2)
    {
        this.channels = channels;
        capacity = Math.Max(4096, (int)(sampleRate * seconds));
        ring = new float[capacity * channels];
        thread = new Thread(Produce) { IsBackground = true, Name = "Groovelight decoder", Priority = ThreadPriority.AboveNormal };
        thread.Start();
    }

    /// <summary>Plays <paramref name="entry"/> from its start (or its decoder's position), dropping everything else.</summary>
    public void Start(SourceEntry entry)
    {
        List<SourceEntry> dropped;
        lock (gate)
        {
            dropped = DropAll();
            decoding = entry;
            starts.AddLast((written, entry));
            Current = entry;
            CurrentFrames = entry.Decoder.Position;
        }
        foreach (var old in dropped) old.Dispose();
        wake.Set();
    }

    /// <summary>Drops everything: nothing plays until the next <see cref="Start"/>.</summary>
    public void Stop()
    {
        List<SourceEntry> dropped;
        lock (gate) dropped = DropAll();
        foreach (var old in dropped) old.Dispose();
    }

    /// <summary>Queues a song to follow the last one without a gap.</summary>
    public void Enqueue(SourceEntry entry)
    {
        lock (gate)
        {
            if (decoding is null && endAt is { } end)
            {
                // The last song is decoded already: this one starts where it ended.
                endAt = null;
                decoding = entry;
                starts.AddLast((end, entry));
            }
            else
            {
                queued.Enqueue(entry);
            }
        }
        wake.Set();
    }

    /// <summary>Drops the queued songs (and what was decoded of them), keeping the current one.</summary>
    public void ClearQueue()
    {
        var dropped = new List<SourceEntry>();
        lock (gate)
        {
            dropped.AddRange(queued);
            queued.Clear();
            // A queued song already being decoded: cut the ring back to where it started.
            while (starts.Last is { } last && last.Value.Entry != Current)
            {
                written = Math.Max(read, last.Value.Start);
                dropped.Add(last.Value.Entry);
                if (decoding == last.Value.Entry) decoding = null;
                starts.RemoveLast();
                endAt = written;
            }
            if (decoding is null && Current is not null && endAt is null) endAt = written;
        }
        foreach (var entry in dropped) entry.Dispose();
        wake.Set();
    }

    /// <summary>Moves the current song to <paramref name="seconds"/>: the ring restarts from there, queued songs follow again.</summary>
    public void Seek(double seconds)
    {
        lock (gate)
        {
            if (Current is not { } current) return;
            // Songs decoded after the current one go back to the queue, from their start.
            var later = starts.Where(start => start.Entry != current).Select(start => start.Entry).ToList();
            if (decoding is not null && decoding != current && !later.Contains(decoding)) later.Add(decoding);
            var rest = queued.ToList();
            queued.Clear();
            foreach (var entry in later.Concat(rest).Distinct())
            {
                if (later.Contains(entry)) entry.Decoder.Seek(0);
                queued.Enqueue(entry);
            }
            starts.Clear();
            current.Decoder.Seek(seconds);
            written = read;
            endAt = null;
            decoding = current;
            starts.AddLast((written, current));
            CurrentFrames = current.Decoder.Position;
        }
        wake.Set();
    }

    /// <summary>
    /// Reads up to <paramref name="frames"/> frames into <paramref name="output"/>. Returns the frames read, the songs
    /// that started in them (gapless transitions), and whether the audio ended.
    /// </summary>
    public (int Frames, List<SourceEntry>? Started, bool Ended) Read(Span<float> output, int frames)
    {
        List<SourceEntry>? started = null;
        int count;
        bool ended;
        lock (gate)
        {
            count = (int)Math.Min(frames, written - read);
            var done = 0;
            while (done < count)
            {
                // Stop at the next song's start to switch over.
                var next = starts.First?.Next;
                var chunk = count - done;
                if (next is not null && next.Value.Start > read) chunk = (int)Math.Min(chunk, next.Value.Start - read);
                else if (next is not null && next.Value.Start <= read)
                {
                    starts.RemoveFirst();
                    Current = next.Value.Entry;
                    CurrentFrames = 0;
                    (started ??= []).Add(Current);
                    continue;
                }
                var offset = (int)(read % capacity);
                var contiguous = Math.Min(chunk, capacity - offset);
                ring.AsSpan(offset * channels, contiguous * channels).CopyTo(output[(done * channels)..]);
                read += contiguous;
                done += contiguous;
                CurrentFrames += contiguous;
            }
            // A song starting exactly at the end of this read.
            if (starts.First?.Next is { } boundary && boundary.Value.Start <= read)
            {
                starts.RemoveFirst();
                Current = boundary.Value.Entry;
                CurrentFrames = 0;
                (started ??= []).Add(Current);
            }
            ended = endAt is { } end && read >= end && decoding is null;
        }
        wake.Set();
        return (count, started, ended);
    }

    /// <summary>Whether <paramref name="frames"/> frames can be read without running dry (or nothing more will come).</summary>
    internal bool IsReady(int frames)
    {
        lock (gate) return written - read >= frames || decoding is null;
    }

    /// <summary>Frames decoded but not read yet.</summary>
    public long Buffered { get { lock (gate) return written - read; } }

    private List<SourceEntry> DropAll()
    {
        var dropped = new List<SourceEntry>();
        foreach (var start in starts) dropped.Add(start.Entry);
        if (decoding is not null) dropped.Add(decoding);
        dropped.AddRange(queued);
        queued.Clear();
        starts.Clear();
        decoding = null;
        Current = null;
        CurrentFrames = 0;
        endAt = null;
        written = read;
        return dropped.Distinct().ToList();
    }

    private void Produce()
    {
        var chunkFrames = 4096;
        var mono = new float[chunkFrames];
        var buffer = new float[chunkFrames * channels];
        while (!disposed)
        {
            SourceEntry? entry;
            int space;
            lock (gate)
            {
                entry = decoding;
                space = (int)(capacity - (written - read));
            }
            if (entry is null || space < 1024)
            {
                wake.WaitOne(20);
                continue;
            }
            var frames = Math.Min(chunkFrames, space);
            int got;
            try
            {
                // Decoders give mono or stereo; the deck runs in stereo.
                if (entry.Decoder.Channels == channels)
                {
                    got = entry.Decoder.Read(buffer.AsSpan(0, frames * channels));
                }
                else
                {
                    got = entry.Decoder.Read(mono.AsSpan(0, frames));
                    for (var index = 0; index < got; index++)
                        for (var channel = 0; channel < channels; channel++) buffer[index * channels + channel] = mono[index];
                }
            }
            catch (Exception)
            {
                // A file that fails partway (a disconnected drive): treat it as ended.
                got = 0;
            }
            lock (gate)
            {
                if (decoding != entry) continue;
                if (got > 0)
                {
                    var done = 0;
                    while (done < got)
                    {
                        var offset = (int)(written % capacity);
                        var contiguous = Math.Min(got - done, capacity - offset);
                        buffer.AsSpan(done * channels, contiguous * channels).CopyTo(ring.AsSpan(offset * channels));
                        written += contiguous;
                        done += contiguous;
                    }
                    continue;
                }
                // The song ended: the next queued one starts right here.
                if (queued.TryDequeue(out var next))
                {
                    decoding = next;
                    starts.AddLast((written, next));
                }
                else
                {
                    decoding = null;
                    endAt = written;
                }
            }
        }
    }

    public void Dispose()
    {
        disposed = true;
        wake.Set();
        thread.Join(1000);
        List<SourceEntry> dropped;
        lock (gate) dropped = DropAll();
        foreach (var entry in dropped) entry.Dispose();
    }
}
