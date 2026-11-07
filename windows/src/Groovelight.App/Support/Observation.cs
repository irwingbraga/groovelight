using Groovelight.Core.Library;
using Microsoft.Data.Sqlite;
using Microsoft.UI.Dispatching;

namespace Groovelight.Support;

/// <summary>
/// A database query kept current for a view (GRDB's ValueObservation on the Mac): fetched off the UI thread, delivered on
/// it, and fetched again after each write to the library. Writes that come in while a fetch runs are folded into one
/// more fetch. Dispose it when the view goes away.
/// </summary>
public sealed class Observation<T> : IDisposable
{
    private readonly LibraryDatabase database;
    private readonly Func<SqliteConnection, T> fetch;
    private readonly Action<T> update;
    private readonly DispatcherQueue queue;
    private readonly Lock gate = new();
    private bool running;
    private bool dirty;
    private bool disposed;

    public Observation(LibraryDatabase database, Func<SqliteConnection, T> fetch, Action<T> update)
    {
        this.database = database;
        this.fetch = fetch;
        this.update = update;
        queue = DispatcherQueue.GetForCurrentThread();
        database.Changed += OnChanged;
        Refresh();
    }

    private void OnChanged() => Refresh();

    /// <summary>Fetches again now.</summary>
    public void Refresh()
    {
        lock (gate)
        {
            if (disposed) return;
            if (running)
            {
                dirty = true;
                return;
            }
            running = true;
        }
        _ = Task.Run(async () =>
        {
            while (true)
            {
                // A burst of writes (a scan) is fetched once.
                await Task.Delay(30);
                T value;
                try
                {
                    value = database.Read(fetch);
                }
                catch (Exception error) when (error is SqliteException or InvalidOperationException or IOException)
                {
                    lock (gate) running = false;
                    return;
                }
                queue.TryEnqueue(() =>
                {
                    lock (gate) if (disposed) return;
                    update(value);
                });
                lock (gate)
                {
                    if (!dirty || disposed)
                    {
                        running = false;
                        return;
                    }
                    dirty = false;
                }
            }
        });
    }

    public void Dispose()
    {
        lock (gate) disposed = true;
        database.Changed -= OnChanged;
    }
}

/// <summary>Disposes a set of observations together (a page's).</summary>
public sealed class Observations : IDisposable
{
    private readonly List<IDisposable> items = [];

    public Observation<T> Add<T>(LibraryDatabase database, Func<SqliteConnection, T> fetch, Action<T> update)
    {
        var observation = new Observation<T>(database, fetch, update);
        items.Add(observation);
        return observation;
    }

    public void Add(IDisposable item) => items.Add(item);

    public void Dispose()
    {
        foreach (var item in items) item.Dispose();
        items.Clear();
    }
}
