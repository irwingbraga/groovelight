namespace Groovelight.Audio;

/// <summary>Where the player runs its work: the app's UI thread, or a manual one in tests.</summary>
public interface IPlayerDispatcher
{
    void Post(Action action);
    /// <summary>Calls <paramref name="tick"/> every <paramref name="interval"/> until disposed.</summary>
    IDisposable StartTimer(TimeSpan interval, Action tick);
}

/// <summary>Runs work on a synchronization context (the UI thread), or on the thread pool without one.</summary>
public sealed class SynchronizationContextDispatcher(SynchronizationContext? context = null) : IPlayerDispatcher
{
    private readonly SynchronizationContext? context = context ?? SynchronizationContext.Current;

    public void Post(Action action)
    {
        if (context is null) ThreadPool.QueueUserWorkItem(_ => action());
        else context.Post(_ => action(), null);
    }

    public IDisposable StartTimer(TimeSpan interval, Action tick) => new Timer(_ => Post(tick), null, interval, interval);
}

/// <summary>A dispatcher that runs work only when told to (tests).</summary>
public sealed class ManualDispatcher : IPlayerDispatcher
{
    private readonly Queue<Action> pending = new();
    private readonly List<ManualTimer> timers = [];
    private readonly Lock gate = new();

    public void Post(Action action)
    {
        lock (gate) pending.Enqueue(action);
    }

    public IDisposable StartTimer(TimeSpan interval, Action tick)
    {
        var timer = new ManualTimer(this, tick);
        lock (gate) timers.Add(timer);
        return timer;
    }

    /// <summary>Runs what was posted (and what that posts).</summary>
    public void RunPending()
    {
        while (true)
        {
            Action? action;
            lock (gate) if (!pending.TryDequeue(out action)) return;
            action();
        }
    }

    /// <summary>Fires every timer once, then runs what they posted.</summary>
    public void Tick()
    {
        List<ManualTimer> active;
        lock (gate) active = [.. timers];
        foreach (var timer in active) timer.Tick();
        RunPending();
    }

    private sealed class ManualTimer(ManualDispatcher owner, Action tick) : IDisposable
    {
        public void Tick() => tick();
        public void Dispose()
        {
            lock (owner.gate) owner.timers.Remove(this);
        }
    }
}
