using Groovelight.Audio;
using Groovelight.Core.Library;

namespace Groovelight.Model;

/// <summary>
/// Measures the loudness of songs without ReplayGain tags in the background while volume normalization is on, one song
/// at a time, the playing and next songs first (the Mac's LoudnessStore).
/// </summary>
public sealed class LoudnessStore : Support.Observable
{
    private int measured, total;
    private bool isRunning;
    public int Measured { get => measured; private set => Set(ref measured, value); }
    public int Total { get => total; private set => Set(ref total, value); }
    public bool IsRunning { get => isRunning; private set => Set(ref isRunning, value); }

    private readonly AppModel model;
    private CancellationTokenSource? job;
    private List<long> priority = [];
    /// <summary>Songs that could not be read this session.</summary>
    private readonly HashSet<long> skipped = [];
    /// <summary>Songs failing in a row after which the job stops for the session.</summary>
    private const int FailureLimit = 8;

    public LoudnessStore(AppModel model)
    {
        this.model = model;
        new Support.Observation<(int, int)>(model.Database, db => db.LoudnessProgress(), value => (Measured, Total) = value);
    }

    private bool IsEnabled => PlaybackPrefs.ParseNormalization(model.Preferences.String(PlaybackPrefs.Normalization)) != VolumeNormalization.Off;

    /// <summary>Starts measuring (normalization on) or stops.</summary>
    public void SetEnabled(bool enabled)
    {
        if (enabled) Start();
        else Stop();
    }

    /// <summary>Measures these songs next (the one playing and the one after it).</summary>
    public void Prioritize(IReadOnlyList<long> ids)
    {
        priority = ids.Concat(priority.Where(id => !ids.Contains(id))).ToList();
        if (job is null && IsEnabled) Start();
    }

    private async void Start()
    {
        if (job is not null) return;
        job = new CancellationTokenSource();
        var token = job.Token;
        IsRunning = true;
        var failuresInARow = 0;
        try
        {
            while (!token.IsCancellationRequested)
            {
                var wanted = priority;
                priority = [];
                var skip = skipped.ToHashSet();
                var ids = await Task.Run(() => model.Database.Read(db => db.TrackIdsNeedingLoudness(wanted)));
                if (ids.Count == 0) ids = await Task.Run(() => model.Database.Read(db => db.TrackIdsNeedingLoudness(10 + skip.Count)));
                ids.RemoveAll(skip.Contains);
                if (ids.Count == 0) break;
                foreach (var id in ids)
                {
                    if (token.IsCancellationRequested) break;
                    if (await Task.Run(() => model.Database.Read(db => db.FetchTrack(id))) is not { } track) continue;
                    try
                    {
                        // A level, or null for silence: either way it is known now.
                        var loudness = await Task.Run(() => LoudnessMeter.Measure(track.FilePath, track.StartTime, track.EndTime), token);
                        await Task.Run(() => model.Database.SetLoudness(loudness, id));
                        failuresInARow = 0;
                    }
                    catch (Exception error) when (error is not OperationCanceledException)
                    {
                        // Unreadable now (an unplugged drive): skipped this session, tried again next time.
                        skipped.Add(id);
                        failuresInARow++;
                    }
                    if (priority.Count > 0 || failuresInARow >= FailureLimit) break;
                }
                // Song after song failing: a drive that cannot be read right now; wait for the next session.
                if (failuresInARow >= FailureLimit && priority.Count == 0) break;
            }
        }
        catch (OperationCanceledException)
        {
        }
        finally
        {
            job = null;
            IsRunning = false;
        }
    }

    private void Stop()
    {
        job?.Cancel();
        job = null;
        IsRunning = false;
    }
}
