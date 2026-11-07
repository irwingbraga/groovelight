namespace Groovelight.Core.Library;

/// <summary>
/// Watches library folders recursively and reports their changes in batches (every <c>latency</c>). The Mac replays
/// what changed while the app was closed from the file system's history; Windows keeps none an app can read without
/// administrator rights, so the app catches up with an incremental scan at launch instead (only changed files are read).
/// </summary>
public sealed class FolderWatcher(Action<IReadOnlyList<FolderEvent>> onChange) : IDisposable
{
    private readonly List<FileSystemWatcher> watchers = [];
    private readonly List<FolderEvent> pending = [];
    private readonly Lock gate = new();
    private Timer? timer;
    private TimeSpan latency = TimeSpan.FromSeconds(1.5);

    /// <summary>Watches <paramref name="paths"/> (replacing what was watched).</summary>
    public void Watch(IEnumerable<string> paths, TimeSpan? latency = null)
    {
        Stop();
        this.latency = latency ?? TimeSpan.FromSeconds(1.5);
        foreach (var path in paths)
        {
            // A folder that is not there (an unplugged drive) is watched from its parent when that exists, to see it come back.
            if (!Directory.Exists(path))
            {
                WatchParent(path);
                continue;
            }
            var watcher = new FileSystemWatcher(path)
            {
                IncludeSubdirectories = true,
                NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size,
                InternalBufferSize = 64 * 1024,
            };
            watcher.Created += (_, change) => Report(change.FullPath, KindOf(change.FullPath));
            watcher.Changed += (_, change) => Report(change.FullPath, KindOf(change.FullPath));
            watcher.Deleted += (_, change) => Report(change.FullPath, FolderEventKind.Unknown);
            watcher.Renamed += (_, change) =>
            {
                Report(change.OldFullPath, FolderEventKind.Unknown);
                Report(change.FullPath, KindOf(change.FullPath));
            };
            watcher.Error += (_, _) => Report(path, FolderEventKind.Overflow);
            watcher.EnableRaisingEvents = true;
            watchers.Add(watcher);
        }
    }

    private void WatchParent(string path)
    {
        var parent = Path.GetDirectoryName(Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar));
        if (parent is null || !Directory.Exists(parent)) return;
        var watcher = new FileSystemWatcher(parent, Path.GetFileName(path.TrimEnd(Path.DirectorySeparatorChar)))
        {
            NotifyFilter = NotifyFilters.DirectoryName,
        };
        watcher.Created += (_, _) => Report(path, FolderEventKind.RootChanged);
        watcher.Renamed += (_, _) => Report(path, FolderEventKind.RootChanged);
        watcher.EnableRaisingEvents = true;
        watchers.Add(watcher);
    }

    private static FolderEventKind KindOf(string path) => Directory.Exists(path) ? FolderEventKind.Directory : FolderEventKind.File;

    private void Report(string path, FolderEventKind kind)
    {
        lock (gate)
        {
            pending.Add(new FolderEvent(path, kind));
            timer ??= new Timer(_ => Flush(), null, latency, Timeout.InfiniteTimeSpan);
        }
    }

    private void Flush()
    {
        List<FolderEvent> batch;
        lock (gate)
        {
            batch = [.. pending];
            pending.Clear();
            timer?.Dispose();
            timer = null;
        }
        if (batch.Count > 0) onChange(batch);
    }

    public void Stop()
    {
        foreach (var watcher in watchers) watcher.Dispose();
        watchers.Clear();
        lock (gate)
        {
            timer?.Dispose();
            timer = null;
            pending.Clear();
        }
    }

    /// <summary>Whether the folder is on a local drive; network shares may not report changes, so they are checked on a timer.</summary>
    public static bool IsLocalVolume(string path)
    {
        try
        {
            var root = Path.GetPathRoot(Path.GetFullPath(path));
            if (string.IsNullOrEmpty(root) || root.StartsWith(@"\\", StringComparison.Ordinal)) return root is null || !root.StartsWith(@"\\", StringComparison.Ordinal);
            return new DriveInfo(root).DriveType != DriveType.Network;
        }
        catch (Exception exception) when (exception is ArgumentException or IOException)
        {
            return true;
        }
    }

    public void Dispose() => Stop();
}
