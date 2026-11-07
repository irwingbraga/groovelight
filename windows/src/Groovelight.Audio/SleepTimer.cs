using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace Groovelight.Audio;

/// <summary>Pauses playback after some minutes (fading out over the last seconds) or when the current song ends.</summary>
public sealed class SleepTimer : INotifyPropertyChanged
{
    public abstract record TimerMode
    {
        public sealed record Minutes(int Count) : TimerMode;
        public sealed record EndOfSong : TimerMode;
    }

    public static readonly IReadOnlyList<int> Choices = [15, 30, 45, 60, 90, 120];

    private readonly PlaybackController player;
    private readonly IPlayerDispatcher dispatcher;
    private IDisposable? timer;
    private float fadeFromVolume;
    private DateTime fadeStart;
    private double fadeSeconds;

    public event PropertyChangedEventHandler? PropertyChanged;

    public TimerMode? Mode { get; private set; }
    public DateTime? EndsAt { get; private set; }
    /// <summary>Refreshed every few seconds while a timer runs, for "23 min left".</summary>
    public DateTime Now { get; private set; } = DateTime.UtcNow;

    public SleepTimer(PlaybackController player, IPlayerDispatcher dispatcher)
    {
        this.player = player;
        this.dispatcher = dispatcher;
        player.StoppedAfterItem += Finished;
    }

    public bool IsActive => Mode is not null;

    /// <summary>"23 min left", "Stops after this song", or null when off.</summary>
    public string? Summary => Mode switch
    {
        null => null,
        TimerMode.EndOfSong => "Stops after this song",
        // Rounded up, but a timer just set for 30 minutes says 30 (not 31).
        _ => $"{Math.Max((int)Math.Ceiling(((EndsAt ?? Now) - Now).TotalMinutes - 0.01), 0)} min left",
    };

    public void Start(TimerMode mode)
    {
        Cancel();
        Mode = mode;
        Now = DateTime.UtcNow;
        switch (mode)
        {
            case TimerMode.EndOfSong:
                player.StopsAfterCurrentItem = true;
                break;
            case TimerMode.Minutes minutes:
                EndsAt = DateTime.UtcNow.AddMinutes(minutes.Count);
                timer = dispatcher.StartTimer(TimeSpan.FromSeconds(0.1), Tick);
                break;
        }
        Changed();
    }

    public void Cancel()
    {
        timer?.Dispose();
        timer = null;
        if (fadeSeconds > 0) player.Volume = fadeFromVolume;
        fadeSeconds = 0;
        if (Mode is TimerMode.EndOfSong) player.StopsAfterCurrentItem = false;
        Mode = null;
        EndsAt = null;
        Changed();
    }

    /// <summary>Every 100 ms: the summary, and over the last 10 s the volume down to silence, then pause.</summary>
    private void Tick()
    {
        Now = DateTime.UtcNow;
        if (EndsAt is not { } end) return;
        var left = (end - Now).TotalSeconds;
        if (left <= 10 && fadeSeconds == 0)
        {
            fadeFromVolume = player.Volume;
            fadeStart = Now;
            fadeSeconds = Math.Max(left, 0.1);
        }
        if (fadeSeconds > 0)
        {
            var progress = Math.Min((Now - fadeStart).TotalSeconds / fadeSeconds, 1);
            player.Volume = fadeFromVolume * (float)(1 - progress);
            if (progress >= 1)
            {
                // Lowers the volume to silence, pauses, and puts the volume back for next time.
                player.Pause();
                player.Volume = fadeFromVolume;
                fadeSeconds = 0;
                Finished();
                return;
            }
        }
        if ((int)(left * 10) % 50 == 0) Changed();
    }

    private void Finished()
    {
        timer?.Dispose();
        timer = null;
        Mode = null;
        EndsAt = null;
        Changed();
    }

    private void Changed([CallerMemberName] string? name = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Mode)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Summary)));
    }
}
