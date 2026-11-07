using Groovelight.Core.Library;
using Microsoft.UI.Dispatching;

namespace Groovelight.Model;

/// <summary>
/// Keeps the library in step with its folders (the Mac's LibrarySync):
/// - Watches them and rescans only the folders that changed, never dropping a change that comes in during a scan.
/// - At launch, catches up on what changed while the app was closed with an incremental check of every folder (only
///   changed files are read; Windows keeps no change history an app can replay).
/// - Notices drives being plugged in or out, checks network folders (which may report no changes) on a timer, checks
///   everything after a day without a full check, and checks a song's folder when its file is gone.
/// </summary>
public sealed class LibrarySync : Support.Observable, IDisposable
{
    /// <summary>A short note about what the last quiet update changed ("Added 3 songs"), shown for a few seconds.</summary>
    private string? note;
    public string? Note { get => note; private set => Set(ref note, value); }

    public static readonly TimeSpan NetworkInterval = TimeSpan.FromMinutes(10);
    public static readonly TimeSpan FullCheckInterval = TimeSpan.FromHours(24);

    private readonly AppModel model;
    private readonly FolderWatcher watcher;
    private readonly LibraryChanges changes = new([]);
    /// <summary>Library folders whose next scan shows progress (first scan of a new folder, Rescan Now).</summary>
    private readonly HashSet<long> loudRoots = [];
    private readonly Dictionary<long, DateTime> lastNetworkCheck = [];
    private HashSet<string> networkFolders = new(StringComparer.OrdinalIgnoreCase);
    private Task? drain;
    private DispatcherQueueTimer? minuteTimer;
    private DispatcherQueueTimer? drivesTimer;
    private DispatcherQueueTimer? noteTimer;

    public LibrarySync(AppModel model)
    {
        this.model = model;
        watcher = new FolderWatcher(events => model.Queue.TryEnqueue(() => Received(events)));
    }

    /// <summary>At launch: catches up on changes, then watches.</summary>
    public async Task StartAsync()
    {
        foreach (var root in await AvailableRootsAsync())
        {
            if (root.Id is not { } id) continue;
            if (root.LastScanAt is null) loudRoots.Add(id);
            changes.AddFull(id);
        }
        await WatchAsync();
        Kick();
        minuteTimer = model.Queue.CreateTimer();
        minuteTimer.Interval = TimeSpan.FromSeconds(60);
        minuteTimer.Tick += async (_, _) => await TimerFiredAsync();
        minuteTimer.Start();
        drivesTimer = model.Queue.CreateTimer();
        drivesTimer.Interval = TimeSpan.FromSeconds(5);
        drivesTimer.Tick += async (_, _) => await CheckDrivesAsync();
        drivesTimer.Start();
    }

    /// <summary>After folders were added, removed or relocated: watches the current set (new ones get a full scan first).</summary>
    public async Task FoldersChangedAsync(long? newRootId = null)
    {
        if (newRootId is { } id)
        {
            loudRoots.Add(id);
            changes.Roots = (await AvailableRootsAsync()).Where(root => root.Id is not null).Select(root => (root.Id!.Value, root.Path)).ToList();
            changes.AddFull(id);
        }
        await WatchAsync();
        Kick();
    }

    /// <summary>Checks every file of every folder now (Rescan Now: with progress).</summary>
    public async void CheckEverything(bool loud)
    {
        foreach (var root in await AvailableRootsAsync())
        {
            if (root.Id is not { } id) continue;
            if (loud) loudRoots.Add(id);
            changes.AddFull(id);
        }
        Kick();
    }

    /// <summary>Checks every folder and returns when done (after organizing or importing files).</summary>
    public async Task CheckEverythingAndWaitAsync()
    {
        foreach (var root in await AvailableRootsAsync())
        {
            if (root.Id is { } id) await ScanAsync(id, ScanScope.Everything);
        }
    }

    /// <summary>Checks the folder of a song whose file could not be opened.</summary>
    public void CheckFolder(string path)
    {
        if (File.Exists(path) || Path.GetDirectoryName(path) is not { } folder) return;
        changes.AddFolder(folder);
        Kick();
    }

    private async Task WatchAsync()
    {
        var roots = await AvailableRootsAsync();
        changes.Roots = roots.Where(root => root.Id is not null).Select(root => (root.Id!.Value, root.Path)).ToList();
        networkFolders = new HashSet<string>(roots.Where(root => !FolderWatcher.IsLocalVolume(root.Path)).Select(root => root.Path),
                                             StringComparer.OrdinalIgnoreCase);
        watcher.Watch(roots.Select(root => root.Path).Where(path => !networkFolders.Contains(path)));
    }

    private void Received(IReadOnlyList<FolderEvent> events)
    {
        changes.Add(events);
        Kick();
    }

    /// <summary>Runs the waiting work, and whatever comes in meanwhile, until nothing is left.</summary>
    private void Kick()
    {
        if (drain is not null || changes.IsEmpty) return;
        drain = DrainAsync();
    }

    private async Task DrainAsync()
    {
        // A moment for a burst of events (copying an album) to arrive together.
        await Task.Delay(500);
        var total = new ScanSummary();
        while (!changes.IsEmpty)
        {
            foreach (var (rootId, scope) in changes.Take())
            {
                if (await ScanAsync(rootId, scope) is { } summary)
                {
                    total.Added += summary.Added;
                    total.Updated += summary.Updated;
                    total.Removed += summary.Removed;
                }
            }
        }
        drain = null;
        Show(total);
        if (!changes.IsEmpty) Kick();
    }

    /// <summary>Scans one folder; returns null when it failed or the folder is unavailable.</summary>
    private async Task<ScanSummary?> ScanAsync(long rootId, ScanScope scope)
    {
        var root = await Task.Run(() => model.Database.Read(db => db.Roots().FirstOrDefault(root => root.Id == rootId)));
        if (root is null) return null;
        var loud = scope is ScanScope.Full && loudRoots.Remove(rootId);
        if (loud) model.ScanProgress = new ScanProgress(0, 0);
        model.UnavailableFolders.Remove(root.Path);
        try
        {
            var summary = await model.Scanner.ScanAsync(root, scope, progress =>
            {
                if (!loud) return;
                model.Queue.TryEnqueue(() => { if (model.ScanProgress is not null) model.ScanProgress = progress; });
            });
            if (scope is ScanScope.Full)
            {
                model.LastScanSummary = summary;
                lastNetworkCheck[rootId] = DateTime.UtcNow;
            }
            return summary;
        }
        catch (FolderUnavailableException error)
        {
            // Unplugged or moved: its songs and their history are kept until it is back.
            model.UnavailableFolders.Add(error.FolderPath);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or Microsoft.Data.Sqlite.SqliteException)
        {
            model.ErrorMessage = $"Scan failed: {error.Message}";
        }
        finally
        {
            if (loud) model.ScanProgress = null;
        }
        return null;
    }

    /// <summary>Drives come and go: folders that are back get a full check, gone ones are marked unavailable.</summary>
    private async Task CheckDrivesAsync()
    {
        var all = await Task.Run(() => model.Database.Read(db => db.Roots()));
        var changed = false;
        foreach (var root in all)
        {
            var exists = await Task.Run(() => Directory.Exists(root.Path));
            if (exists && model.UnavailableFolders.Contains(root.Path))
            {
                model.UnavailableFolders.Remove(root.Path);
                if (root.Id is { } id) changes.AddFull(id);
                changed = true;
            }
            else if (!exists && !model.UnavailableFolders.Contains(root.Path))
            {
                model.UnavailableFolders.Add(root.Path);
                changed = true;
            }
        }
        if (!changed) return;
        await WatchAsync();
        Kick();
    }

    /// <summary>Every minute: network folders due for a check, and folders without a full check for a day.</summary>
    private async Task TimerFiredAsync()
    {
        foreach (var root in await AvailableRootsAsync())
        {
            if (root.Id is not { } id) continue;
            var networkDue = networkFolders.Contains(root.Path)
                && DateTime.UtcNow - lastNetworkCheck.GetValueOrDefault(id, DateTime.MinValue) > NetworkInterval;
            var fullDue = root.LastFullScanAt is not { } last || DateTime.UtcNow - last > FullCheckInterval;
            if (networkDue || fullDue) changes.AddFull(id);
        }
        Kick();
    }

    private async Task<List<LibraryRoot>> AvailableRootsAsync()
    {
        var roots = await Task.Run(() => model.Database.Read(db => db.Roots()));
        return roots.Where(root => !model.UnavailableFolders.Contains(root.Path)).ToList();
    }

    /// <summary>Shows what a quiet update changed for a few seconds.</summary>
    private void Show(ScanSummary summary)
    {
        var parts = new List<string>();
        void Count(int count, string verb) { if (count > 0) parts.Add($"{verb} {count} {(count == 1 ? "song" : "songs")}"); }
        Count(summary.Added, "Added");
        Count(summary.Updated, "Updated");
        Count(summary.Removed, "Removed");
        if (parts.Count == 0) return;
        Note = string.Join(", ", parts);
        noteTimer?.Stop();
        noteTimer = model.Queue.CreateTimer();
        noteTimer.Interval = TimeSpan.FromSeconds(4);
        noteTimer.IsRepeating = false;
        noteTimer.Tick += (_, _) => Note = null;
        noteTimer.Start();
    }

    public void Dispose()
    {
        minuteTimer?.Stop();
        drivesTimer?.Stop();
        watcher.Dispose();
    }
}
