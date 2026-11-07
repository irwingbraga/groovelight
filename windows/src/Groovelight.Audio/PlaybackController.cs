using System.Collections.Concurrent;
using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace Groovelight.Audio;

public enum PlaybackState { Stopped, Playing, Paused }

/// <summary>Where the sound goes and whether it gets there untouched (bit-perfect).</summary>
public sealed record OutputStatus
{
    public string? DeviceName { get; init; }
    public double DeviceRate { get; init; }
    public int? DeviceBitDepth { get; init; }
    public double? FileRate { get; init; }
    public int? FileBitDepth { get; init; }
    /// <summary>Bit-perfect mode is on and nothing changes the samples on the way.</summary>
    public bool IsBitPerfect { get; init; }
    /// <summary>Why the current song is not played bit-perfect (empty when it is, or when the mode is off).</summary>
    public IReadOnlyList<string> Notes { get; init; } = [];
}

/// <summary>How songs are leveled (Sound Check style), from their ReplayGain tags or measured loudness.</summary>
public enum VolumeNormalization
{
    Off,
    /// <summary>Every song at the same loudness.</summary>
    Track,
    /// <summary>Albums keep their own dynamics (album gain), songs without one use their track gain.</summary>
    Album,
}

/// <summary>
/// The player: queue, gapless transitions, crossfade, EQ, speed, loudness, volume and the spectrum tap (the Mac's
/// PlaybackController over SFBAudioEngine). Two decks, each <c>source -> speed -> loudness gain -> EQ</c>, mixed into
/// the output; one deck plays, and a crossfade starts the next song on the other deck and fades between them.
/// Its members are called on the dispatcher's thread (the UI thread); the output renders on its own thread.
/// </summary>
public sealed class PlaybackController : INotifyPropertyChanged, IDisposable
{
    private readonly IAudioOutput output;
    private readonly IPlayerDispatcher dispatcher;
    private readonly Mixer mixer;
    private readonly Deck[] decks;
    private int activeIndex;
    private readonly ConcurrentQueue<DeckEvent> events = new();
    private int eventsPosted;

    public event PropertyChangedEventHandler? PropertyChanged;
    /// <summary>An item started playing (manual start or gapless transition).</summary>
    public event Action<PlayableItem>? ItemStarted;
    /// <summary>An item stopped being current, with the seconds actually listened to.</summary>
    public event Action<PlayableItem, double>? ItemFinished;
    /// <summary>A song could not be opened (and was skipped).</summary>
    public event Action<PlayableItem>? ItemFailed;
    /// <summary>The output device could not be opened, so playback stopped (the reason, for people).</summary>
    public event Action<string>? OutputFailed;
    /// <summary>Playback stopped because of <see cref="StopsAfterCurrentItem"/>.</summary>
    public event Action? StoppedAfterItem;
    /// <summary>The volume changed (to remember it across launches).</summary>
    public event Action<float>? VolumeChanged;

    public SpectrumAnalyzer Analyzer { get; } = new();
    public PlayQueue Queue { get; } = new();

    public PlaybackController(IAudioOutput output, IPlayerDispatcher? dispatcher = null)
    {
        this.output = output;
        this.dispatcher = dispatcher ?? new SynchronizationContextDispatcher();
        decks = [new Deck(0, events, PostEvents), new Deck(1, events, PostEvents)];
        mixer = new Mixer(this);
        decks[0].TapOpen = true;
        decks[0].SetVolume(1);
        output.DeviceChanged += () => this.dispatcher.Post(HandleDeviceChange);
    }

    private Deck Deck => decks[activeIndex];

    // MARK: Properties

    private PlaybackState state = PlaybackState.Stopped;
    public PlaybackState State { get => state; private set => Set(ref state, value); }

    private double currentTime;
    private DateTime currentTimeUpdatedAt = DateTime.UtcNow;
    /// <summary>Position in the song as heard: what was rendered, less the output's latency.</summary>
    public double CurrentTime
    {
        get => currentTime;
        private set
        {
            currentTimeUpdatedAt = DateTime.UtcNow;
            Set(ref currentTime, value);
        }
    }

    private double duration;
    public double Duration { get => duration; private set => Set(ref duration, value); }

    private string? lastError;
    public string? LastError { get => lastError; private set => Set(ref lastError, value); }

    private float volume = 0.8f;
    public float Volume
    {
        get => volume;
        set
        {
            if (!Set(ref volume, value)) return;
            // Bit-perfect: the samples stay untouched; the device's own volume changes instead (when it has one).
            if (bitPerfect) { if (!isSyncingDeviceVolume) output.DeviceVolume = value; }
            else mixer.MasterVolume = value;
            VolumeChanged?.Invoke(value);
        }
    }

    private bool bitPerfect;
    /// <summary>
    /// Bit-perfect playback: the output device takes each song's own rate and nothing changes the samples (EQ, speed,
    /// normalization and crossfade are bypassed; the volume slider moves the device's volume). On Windows this takes the
    /// device in exclusive mode, the only way WASAPI plays at a song's rate.
    /// </summary>
    public bool BitPerfect
    {
        get => bitPerfect;
        set
        {
            if (Set(ref bitPerfect, value)) ApplyBitPerfect();
        }
    }

    private OutputStatus outputStatus = new();
    public OutputStatus Output { get => outputStatus; private set => Set(ref outputStatus, value); }
    private bool isSyncingDeviceVolume;

    private double crossfadeDuration;
    /// <summary>Seconds over which one song fades into the next (0: off, songs follow gaplessly).</summary>
    public double CrossfadeDuration
    {
        get => crossfadeDuration;
        set { if (Set(ref crossfadeDuration, value)) RefreshEnqueuedNext(force: true); }
    }

    private bool crossfadeSkipsSameAlbum = true;
    /// <summary>Songs that follow each other on the same album play gaplessly even with crossfade on.</summary>
    public bool CrossfadeSkipsSameAlbum
    {
        get => crossfadeSkipsSameAlbum;
        set { if (Set(ref crossfadeSkipsSameAlbum, value)) RefreshEnqueuedNext(force: true); }
    }

    private float rate = 1;
    /// <summary>Playback speed (0.5 to 2), keeping the pitch.</summary>
    public float Rate
    {
        get => rate;
        set
        {
            if (!Set(ref rate, Math.Clamp(value, 0.5f, 2f))) return;
            foreach (var deck in decks) deck.SetSpeed(bitPerfect ? 1 : rate);
        }
    }

    private bool stopsAfterCurrentItem;
    /// <summary>Stops when the current song ends (sleep timer): the next song is selected but does not start.</summary>
    public bool StopsAfterCurrentItem
    {
        get => stopsAfterCurrentItem;
        set { if (Set(ref stopsAfterCurrentItem, value)) RefreshEnqueuedNext(force: true); }
    }

    private VolumeNormalization normalization = VolumeNormalization.Off;
    public VolumeNormalization Normalization
    {
        get => normalization;
        set { if (Set(ref normalization, value)) Deck.SetGain(Gain(Queue.Current)); }
    }

    private EQPreset equalizerPreset = EQPreset.Flat;
    public EQPreset EqualizerPreset
    {
        get => equalizerPreset;
        set { if (Set(ref equalizerPreset, value)) ApplyEqualizer(); }
    }

    private bool equalizerEnabled;
    public bool EqualizerEnabled
    {
        get => equalizerEnabled;
        set { if (Set(ref equalizerEnabled, value)) ApplyEqualizer(); }
    }

    private void ApplyEqualizer()
    {
        foreach (var deck in decks) deck.Equalizer.Apply(equalizerPreset, equalizerEnabled && !bitPerfect);
    }

    public RepeatMode RepeatMode
    {
        get => Queue.RepeatMode;
        set
        {
            Queue.RepeatMode = value;
            OnPropertyChanged();
            RefreshEnqueuedNext();
        }
    }

    public bool IsShuffled => Queue.IsShuffled;
    public PlayableItem? Current => Queue.Current;

    /// <summary>The rate the output runs at (the device's in shared mode, the song's in bit-perfect mode).</summary>
    public double OutputSampleRate => output.Format?.SampleRate ?? output.Device?.SampleRate ?? 0;
    public string? OutputDeviceName => output.Device?.Name;

    /// <summary>Where a restored song starts when Play is pressed.</summary>
    private double? pendingStartTime;
    /// <summary>The item handed to the deck for gapless playback, and its entry (CUE tracks of one file share a path).</summary>
    private PlayableItem? enqueuedNext;
    private SourceEntry? enqueuedEntry;
    private SourceEntry? currentEntry;
    private double listenedSeconds;
    private double lastTickTime;
    private IDisposable? ticker;
    /// <summary>The crossfade in progress: the deck fading out.</summary>
    private Deck? fadingOut;

    // MARK: Transport

    /// <summary><paramref name="position"/>: seconds into the first song (a queue taken over from another device).</summary>
    public void Play(IReadOnlyList<PlayableItem> items, int startAt = 0, bool shuffle = false, double position = 0)
    {
        CompleteFade();
        FinishCurrentForReporting();
        Queue.Set(items, startAt, shuffle);
        OnPropertyChanged(nameof(IsShuffled));
        if (position > 0) pendingStartTime = position;
        StartCurrent();
    }

    /// <summary>Puts back a saved queue without playing: the current song shows at <paramref name="position"/> and starts there on Play.</summary>
    public void Restore(PlayQueue.Snapshot snapshot, IReadOnlyDictionary<long, PlayableItem> items, double position)
    {
        if (State != PlaybackState.Stopped || Queue.Current is not null) return;
        Queue.Restore(snapshot, items);
        if (Queue.Current is not { } item) return;
        Duration = item.Duration;
        var start = position > 0 && position < item.Duration - 1 ? position : 0;
        pendingStartTime = start;
        CurrentTime = start;
        OnPropertyChanged(nameof(Current));
    }

    public void TogglePlayPause()
    {
        switch (State)
        {
            case PlaybackState.Playing: Pause(); break;
            case PlaybackState.Paused: Resume(); break;
            default: StartCurrent(); break;
        }
    }

    public void Pause()
    {
        CompleteFade();
        if (State != PlaybackState.Playing) return;
        output.Pause();
        State = PlaybackState.Paused;
    }

    public void Resume()
    {
        if (State != PlaybackState.Paused) return;
        output.Start();
        State = PlaybackState.Playing;
    }

    public void Stop()
    {
        CompleteFade();
        FinishCurrentForReporting();
        output.Pause();
        foreach (var deck in decks) deck.Stop();
        currentEntry = enqueuedEntry = null;
        enqueuedNext = null;
        State = PlaybackState.Stopped;
        CurrentTime = 0;
        ticker?.Dispose();
        ticker = null;
        Analyzer.Reset();
    }

    public void Next()
    {
        CompleteFade();
        FinishCurrentForReporting();
        if (Queue.SkipForward() is not null) StartCurrent();
        else Stop();
    }

    /// <summary>iTunes behavior: restart the song if more than 3 s in, otherwise go to the previous one.</summary>
    public void Previous()
    {
        CompleteFade();
        if (CurrentTime > 3)
        {
            Seek(0);
            return;
        }
        FinishCurrentForReporting();
        Queue.SkipBackward();
        StartCurrent();
    }

    public void JumpToQueueIndex(int index)
    {
        CompleteFade();
        FinishCurrentForReporting();
        if (Queue.Jump(index) is not null) StartCurrent();
    }

    public void Seek(double time)
    {
        // A restored song not started yet: it will start there.
        if (State == PlaybackState.Stopped && Queue.Current is not null)
        {
            pendingStartTime = time;
            CurrentTime = time;
            return;
        }
        CompleteFade();
        Deck.Seek(Math.Max(0, time));
        CurrentTime = time;
        lastTickTime = time;
    }

    public void PlayNext(IReadOnlyList<PlayableItem> items)
    {
        var wasEmpty = Queue.Current is null;
        Queue.PlayNext(items);
        if (wasEmpty) StartCurrent(); else RefreshEnqueuedNext();
        OnPropertyChanged(nameof(Queue));
    }

    public void PlayLater(IReadOnlyList<PlayableItem> items)
    {
        var wasEmpty = Queue.Current is null;
        Queue.PlayLater(items);
        if (wasEmpty) StartCurrent(); else RefreshEnqueuedNext();
        OnPropertyChanged(nameof(Queue));
    }

    public void RemoveFromQueue(int index)
    {
        Queue.Remove(index);
        RefreshEnqueuedNext();
        OnPropertyChanged(nameof(Queue));
    }

    public void MoveInQueue(IReadOnlyCollection<int> source, int destination)
    {
        Queue.Move(source, destination);
        RefreshEnqueuedNext();
        OnPropertyChanged(nameof(Queue));
    }

    public void SetShuffle(bool enabled)
    {
        Queue.SetShuffle(enabled);
        RefreshEnqueuedNext();
        OnPropertyChanged(nameof(IsShuffled));
        OnPropertyChanged(nameof(Queue));
    }

    // MARK: Internals

    private void StartCurrent()
    {
        if (Queue.Current is not { } item)
        {
            Stop();
            return;
        }
        try
        {
            var entry = OpenEntry(item, forPlayback: true);
            Deck.SetGain(Gain(item));
            // A song taken over from another device starts where it was: its decoder moves there before it plays.
            double? startedAt = null;
            if (pendingStartTime is { } start && start > 0 && start < entry.Decoder.Duration)
            {
                entry.Decoder.Seek(start);
                startedAt = start;
            }
            Deck.SetVolume(1);
            Deck.Play(entry);
            currentEntry = entry;
            enqueuedNext = null;
            enqueuedEntry = null;
            output.Start();
            State = PlaybackState.Playing;
            LastError = null;
            BeginItem(item, entry);
            if (startedAt is { } at)
            {
                CurrentTime = at;
                lastTickTime = at;
            }
            pendingStartTime = null;
            EnqueueNextForGapless();
            StartTicker();
            UpdateOutputStatus();
        }
        catch (AudioOutputException exception)
        {
            // The device, not the song: every song would fail the same way, so playback stops with the reason.
            Stop();
            LastError = exception.Message;
            OutputFailed?.Invoke(exception.Message);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            LastError = $"{item.Title}: {exception.Message}";
            ItemFailed?.Invoke(item);
            // Skip unplayable files instead of stopping the whole queue.
            if (Queue.SkipForward() is { } next && next != item) StartCurrent(); else Stop();
        }
    }

    /// <summary>
    /// Opens a song's decoder at the engine's rate, first opening (or reopening) the output when it is not running at
    /// the rate the song needs (bit-perfect mode follows each song's rate).
    /// </summary>
    private SourceEntry OpenEntry(PlayableItem item, bool forPlayback)
    {
        if (forPlayback) EnsureOutput(item);
        var format = output.Format ?? throw new InvalidOperationException("The output device is not available.");
        var decoder = AudioDecoder.Open(item.Path, item.StartTime, item.EndTime, format.SampleRate);
        return new SourceEntry(item, decoder);
    }

    /// <summary>The rate an item plays at bit-perfect: its own when the device takes it, else the lowest supported rate above it.</summary>
    private int BitPerfectRate(PlayableItem item, out int? bits)
    {
        int fileRate;
        if (item.SampleRate is > 0 and var known && item.BitDepth is not null)
        {
            fileRate = (int)known;
            bits = item.BitDepth;
        }
        else
        {
            using var probe = AudioDecoder.Open(item.Path);
            fileRate = probe.FileSampleRate;
            bits = probe.FileBitDepth ?? item.BitDepth;
        }
        if (output.Device is not { } device || device.SupportedRates.Count == 0 || device.Supports(fileRate)) return fileRate;
        return ClosestRate(fileRate, device.SupportedRates) ?? fileRate;
    }

    /// <summary>The lowest supported rate at or above <paramref name="rate"/> (no information lost), else the highest one.</summary>
    internal static int? ClosestRate(int rate, IReadOnlyList<int> rates)
    {
        var sorted = rates.Order().ToList();
        return sorted.Count == 0 ? null : sorted.FirstOrDefault(candidate => candidate >= rate, sorted[^1]);
    }

    private void EnsureOutput(PlayableItem item)
    {
        OutputRequest request;
        if (bitPerfect)
        {
            var target = BitPerfectRate(item, out var bits);
            request = new OutputRequest(target, 2, Exclusive: true, BitDepth: bits);
            if (output.Format is { } running && running.SampleRate == target && output.IsExclusive) return;
        }
        else
        {
            if (output.Format is not null && !output.IsExclusive) return;
            request = new OutputRequest(output.Device?.SampleRate ?? 48_000, 2);
        }
        // A new stream: whatever the decks held was for the old format.
        output.Close();
        CompleteFade();
        foreach (var deck in decks) deck.Stop();
        var format = output.Open(request, mixer);
        foreach (var deck in decks)
        {
            deck.Configure(format);
            deck.SetSpeed(bitPerfect ? 1 : rate);
        }
        ApplyEqualizer();
        mixer.MasterVolume = bitPerfect ? 1 : volume;
        mixer.SnapVolume();
    }

    private void BeginItem(PlayableItem item, SourceEntry entry)
    {
        CurrentTime = 0;
        lastTickTime = 0;
        listenedSeconds = 0;
        Duration = entry.Decoder.Duration > 0 ? entry.Decoder.Duration : item.Duration;
        OnPropertyChanged(nameof(Current));
        ItemStarted?.Invoke(item);
    }

    private void FinishCurrentForReporting()
    {
        // Another song was picked: a restored position no longer applies.
        pendingStartTime = null;
        if (Queue.Current is not { } item || State == PlaybackState.Stopped) return;
        ItemFinished?.Invoke(item, listenedSeconds);
        listenedSeconds = 0;
    }

    private void EnqueueNextForGapless()
    {
        // A crossfade starts the next song on the other deck instead.
        if (stopsAfterCurrentItem || Queue.NextForAutoAdvance is not { } next || ShouldCrossfade(next)) return;
        try
        {
            // Bit-perfect: a song at another rate waits for the device to switch (a short gap), so it is not enqueued.
            if (bitPerfect && BitPerfectRate(next, out _) != output.Format?.SampleRate) return;
            var entry = OpenEntry(next, forPlayback: false);
            Deck.Enqueue(entry);
            enqueuedNext = next;
            enqueuedEntry = entry;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            enqueuedNext = null;
            enqueuedEntry = null;
        }
    }

    /// <summary>Queue order (or crossfade setting) changed: drop what the deck had pre-loaded and enqueue the new next item.</summary>
    private void RefreshEnqueuedNext(bool force = false)
    {
        if (State == PlaybackState.Stopped || (!force && Queue.NextForAutoAdvance == enqueuedNext)) return;
        Deck.ClearQueue();
        enqueuedNext = null;
        enqueuedEntry = null;
        EnqueueNextForGapless();
    }

    /// <summary>The position at <paramref name="date"/>, moved on from the last update at the playing speed (synced lyrics).</summary>
    public double EstimatedTime(DateTime date)
    {
        if (State != PlaybackState.Playing || pendingStartTime is not null) return CurrentTime;
        var elapsed = Math.Clamp((date - currentTimeUpdatedAt).TotalSeconds, 0, 0.5);
        return Math.Min(CurrentTime + elapsed * rate, Math.Max(Duration, CurrentTime));
    }

    private void StartTicker()
    {
        ticker?.Dispose();
        ticker = dispatcher.StartTimer(TimeSpan.FromMilliseconds(250), Tick);
    }

    internal void Tick()
    {
        if (fadingOut is not null && !Deck.IsFading) CompleteFade();
        if (State != PlaybackState.Playing) return;
        // The output's delay is in output time; at another speed it covers more (or less) of the song.
        var time = Math.Max(Deck.CurrentTime - output.Latency * (Deck.Speed == 1 ? 1 : Deck.Speed), 0);
        var delta = time - lastTickTime;
        // Only count forward progress at roughly real-time speed (ignores seeks).
        if (delta is > 0 and < 1) listenedSeconds += delta;
        lastTickTime = time;
        CurrentTime = time;
        StartCrossfadeIfDue();
    }

    // MARK: Crossfade

    /// <summary>Whether the move to <paramref name="next"/> fades (rather than following gaplessly).</summary>
    private bool ShouldCrossfade(PlayableItem next)
    {
        if (crossfadeDuration <= 0 || bitPerfect || Queue.Current is not { } current || next == current) return false;
        if (crossfadeSkipsSameAlbum && current.AlbumKey is { } album && album == next.AlbumKey) return false;
        return true;
    }

    /// <summary>Near the end of a song, starts the next one on the other deck and fades over.</summary>
    private void StartCrossfadeIfDue()
    {
        if (fadingOut is not null || stopsAfterCurrentItem || State != PlaybackState.Playing || Duration <= 0
            || Queue.NextForAutoAdvance is not { } next || !ShouldCrossfade(next)) return;
        // Short songs fade over at most half their length.
        var length = Math.Min(crossfadeDuration, Duration / 2);
        if (Duration - CurrentTime > length) return;

        var outgoing = Deck;
        var incoming = decks[1 - activeIndex];
        SourceEntry entry;
        try
        {
            entry = OpenEntry(next, forPlayback: false);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            // Unplayable: let the song end and the queue move on as usual.
            return;
        }
        incoming.SetVolume(0);
        incoming.SetGain(Gain(next));
        incoming.Play(entry);
        // The incoming deck is now the current one.
        FinishCurrentForReporting();
        Queue.AdvanceAfterEnd();
        Queue.SyncCurrent(next);
        activeIndex = incoming.Index;
        outgoing.TapOpen = false;
        incoming.TapOpen = true;
        currentEntry = entry;
        enqueuedNext = null;
        enqueuedEntry = null;
        BeginItem(next, entry);
        EnqueueNextForGapless();

        // Equal-power curves: the sum stays as loud through the fade.
        var realLength = length / rate;
        incoming.FadeTo(1, realLength);
        outgoing.FadeTo(0, realLength);
        fadingOut = outgoing;
    }

    /// <summary>Ends a crossfade now (it finished, or the user acted): the outgoing deck stops, the current one is at full volume.</summary>
    private void CompleteFade()
    {
        if (fadingOut is not { } outgoing) return;
        fadingOut = null;
        outgoing.Stop();
        outgoing.SetVolume(0);
        Deck.SetVolume(1);
    }

    // MARK: Bit-perfect output

    private void ApplyBitPerfect()
    {
        ApplyEqualizer();
        foreach (var deck in decks)
        {
            deck.SetSpeed(bitPerfect ? 1 : rate);
            deck.SetGain(bitPerfect ? null : Gain(Queue.Current));
        }
        CompleteFade();
        if (bitPerfect)
        {
            mixer.MasterVolume = 1;
            // The slider now shows the device's volume.
            if (output.DeviceVolume is { } deviceVolume)
            {
                isSyncingDeviceVolume = true;
                Volume = deviceVolume;
                isSyncingDeviceVolume = false;
            }
        }
        else
        {
            mixer.MasterVolume = volume;
        }
        // The song playing now moves to its own rate (or back) right away.
        if (State != PlaybackState.Stopped) RestartCurrent();
        else output.Close();
        UpdateOutputStatus();
    }

    /// <summary>Plays the current song again from where it was (after the output changed format).</summary>
    private void RestartCurrent()
    {
        var position = CurrentTime;
        var wasPaused = State == PlaybackState.Paused;
        pendingStartTime = position;
        StartCurrent();
        if (wasPaused) Pause();
    }

    private void HandleDeviceChange()
    {
        output.Close();
        if (State == PlaybackState.Stopped) return;
        RestartCurrent();
    }

    /// <summary>Gives the device back when the app quits.</summary>
    public void ReleaseOutputDevice() => output.Close();

    private void UpdateOutputStatus()
    {
        if (output.Device is not { } device)
        {
            Output = new OutputStatus();
            return;
        }
        var format = output.Format;
        var fileRate = currentEntry?.Decoder.FileSampleRate;
        var fileBits = currentEntry?.Decoder.FileBitDepth ?? Queue.Current?.BitDepth;
        var deviceRate = format?.SampleRate ?? device.SampleRate;
        var notes = new List<string>();
        var deviceBits = output.IsExclusive ? fileBits ?? device.BitDepth : device.BitDepth;
        if (bitPerfect && Queue.Current is not null)
        {
            if (fileRate is { } file && Math.Abs(file - deviceRate) >= 1)
                notes.Add(string.Create(System.Globalization.CultureInfo.InvariantCulture,
                    $"{device.Name} does not support {file / 1000.0:0.###} kHz: resampled to {deviceRate / 1000.0:0.###} kHz."));
            if (!output.IsExclusive) notes.Add("Another app holds the device: Windows mixes it with other sounds.");
        }
        Output = new OutputStatus
        {
            DeviceName = device.Name, DeviceRate = deviceRate, DeviceBitDepth = deviceBits, FileRate = fileRate, FileBitDepth = fileBits,
            IsBitPerfect = bitPerfect && Queue.Current is not null && notes.Count == 0, Notes = notes,
        };
    }

    // MARK: Loudness

    /// <summary>The gain normalization applies to <paramref name="item"/> (dB), null when off or unknown.</summary>
    private double? Gain(PlayableItem? item)
    {
        if (item is null || bitPerfect) return null;
        return normalization switch
        {
            VolumeNormalization.Track => item.TrackGain,
            VolumeNormalization.Album => item.AlbumGain ?? item.TrackGain,
            _ => null,
        };
    }

    // MARK: Engine callbacks (moved to the dispatcher's thread)

    private void PostEvents()
    {
        if (Interlocked.Exchange(ref eventsPosted, 1) == 0) dispatcher.Post(ProcessEvents);
    }

    private void ProcessEvents()
    {
        Interlocked.Exchange(ref eventsPosted, 0);
        while (events.TryDequeue(out var change))
        {
            switch (change)
            {
                case DeckEvent.Started started: EngineNowPlayingChanged(started.Deck, started.Entry); break;
                case DeckEvent.Ended ended: EngineEndOfAudio(ended.Deck); break;
            }
        }
    }

    private void EngineNowPlayingChanged(Deck source, SourceEntry entry)
    {
        if (source != Deck || entry == currentEntry) return;
        currentEntry = entry;
        if (entry != enqueuedEntry || Queue.Current is not { } current) return;
        // Gapless transition to the item we pre-enqueued (repeat one enqueues the same item again).
        FinishCurrentForReporting();
        if (Queue.RepeatMode == RepeatMode.One && enqueuedNext == current)
        {
            BeginItem(current, entry);
        }
        else if (enqueuedNext is { } enqueued)
        {
            Queue.AdvanceAfterEnd();
            Queue.SyncCurrent(enqueued);
            Deck.SetGain(Gain(enqueued));
            BeginItem(enqueued, entry);
        }
        UpdateOutputStatus();
        enqueuedNext = null;
        enqueuedEntry = null;
        EnqueueNextForGapless();
    }

    private void EngineEndOfAudio(Deck source)
    {
        // The deck that faded out reached its end: nothing to do, the other one plays on.
        if (source != Deck || State == PlaybackState.Stopped) return;
        FinishCurrentForReporting();
        if (stopsAfterCurrentItem)
        {
            // Sleep timer: the next song is ready, but playback stops here.
            StopsAfterCurrentItem = false;
            Queue.AdvanceAfterEnd();
            output.Pause();
            foreach (var deck in decks) deck.Stop();
            State = PlaybackState.Stopped;
            CurrentTime = 0;
            Duration = Queue.Current?.Duration ?? 0;
            ticker?.Dispose();
            ticker = null;
            Analyzer.Reset();
            OnPropertyChanged(nameof(Current));
            StoppedAfterItem?.Invoke();
            return;
        }
        if (Queue.AdvanceAfterEnd() is not null)
        {
            StartCurrent();
        }
        else
        {
            output.Pause();
            State = PlaybackState.Stopped;
            CurrentTime = 0;
            ticker?.Dispose();
            ticker = null;
            Analyzer.Reset();
            OnPropertyChanged(nameof(Current));
        }
    }

    private bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnPropertyChanged(name);
        return true;
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    /// <summary>Whether the decks have decoded enough for <paramref name="frames"/> frames (tests pump the output only then).</summary>
    internal bool IsReadyToRender(int frames) => decks.All(deck => deck.IsReady(frames));

    public void Dispose()
    {
        ticker?.Dispose();
        output.Close();
        foreach (var deck in decks) deck.Dispose();
    }

    /// <summary>The audio thread's side: both decks mixed, the master volume, and the analyzer fed from the current deck.</summary>
    private sealed class Mixer(PlaybackController owner) : IAudioSource
    {
        private float[] tap = [];
        private float masterVolume = 0.8f;
        private float appliedVolume = 0.8f;

        public float MasterVolume { get => masterVolume; set => masterVolume = value; }

        /// <summary>A new stream starts at the volume set, without a ramp from the old one.</summary>
        public void SnapVolume() => appliedVolume = masterVolume;

        public void Render(Span<float> buffer, int frames, AudioFormat format)
        {
            var samples = buffer[..(frames * format.Channels)];
            samples.Clear();
            if (tap.Length < samples.Length) tap = new float[samples.Length];
            foreach (var deck in owner.decks)
            {
                if (deck.Format != format) continue;
                deck.Render(samples, frames, tap);
                if (deck.TapOpen) owner.Analyzer.Process(tap.AsSpan(0, samples.Length), frames, format.Channels, format.SampleRate);
            }
            // The master volume, ramped over the buffer so a change does not click; untouched at 1 (bit-perfect).
            var target = masterVolume;
            if (target == 1 && appliedVolume == 1) return;
            var start = appliedVolume;
            for (var frame = 0; frame < frames; frame++)
            {
                var gain = start + (target - start) * (frame + 1) / frames;
                for (var channel = 0; channel < format.Channels; channel++) samples[frame * format.Channels + channel] *= gain;
            }
            appliedVolume = target;
        }
    }
}
