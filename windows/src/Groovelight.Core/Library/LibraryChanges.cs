namespace Groovelight.Core.Library;

/// <summary>One change reported by <see cref="FolderWatcher"/>.</summary>
public sealed record FolderEvent(string Path, FolderEventKind Kind);

public enum FolderEventKind
{
    /// <summary>A file was created, changed, deleted or renamed.</summary>
    File,
    /// <summary>A folder was created, deleted or renamed: everything in it (or that was) must be checked.</summary>
    Directory,
    /// <summary>Not known whether a file or a folder (a deleted entry): its folder and itself are checked.</summary>
    Unknown,
    /// <summary>Events were lost (the watcher's buffer overflowed): the whole library folder must be checked.</summary>
    Overflow,
    /// <summary>The watched folder itself went away or came back (a drive unplugged or plugged in).</summary>
    RootChanged,
}

/// <summary>
/// Library folder changes waiting to be scanned, gathered from file system events. Nothing is dropped: events that come
/// in while a scan runs wait here for the next one.
/// </summary>
public sealed class LibraryChanges(IEnumerable<(long Id, string Path)> roots)
{
    private static readonly StringComparison Comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
    private static readonly char Separator = System.IO.Path.DirectorySeparatorChar;

    private List<(long Id, string Path)> roots = roots.Select(root => (root.Id, Trimmed(root.Path))).ToList();
    private readonly HashSet<long> full = [];
    private readonly Dictionary<long, HashSet<string>> folders = [];
    private readonly Dictionary<long, HashSet<string>> artworkFolders = [];
    private readonly Lock gate = new();

    internal static readonly HashSet<string> ImageExtensions = new(StringComparer.OrdinalIgnoreCase) { "jpg", "jpeg", "png", "webp", "gif", "heic", "tif", "tiff", "bmp" };

    /// <summary>The library folders (id and path) events are matched against.</summary>
    public IReadOnlyList<(long Id, string Path)> Roots
    {
        get { lock (gate) return roots.ToList(); }
        set { lock (gate) roots = value.Select(root => (root.Id, Trimmed(root.Path))).ToList(); }
    }

    public bool IsEmpty { get { lock (gate) return full.Count == 0 && folders.Count == 0; } }

    /// <summary>Adds file system events.</summary>
    public void Add(IEnumerable<FolderEvent> events)
    {
        lock (gate)
        {
            foreach (var change in events)
            {
                var path = Trimmed(change.Path);
                switch (change.Kind)
                {
                    case FolderEventKind.Overflow:
                        foreach (var root in roots.Where(root => Contains(root.Path, path) || Contains(path, root.Path))) full.Add(root.Id);
                        continue;
                    case FolderEventKind.RootChanged:
                        // The library folder itself (or its drive) changed: check all of it.
                        foreach (var root in roots.Where(root => root.Path.Equals(path, Comparison) || Contains(path, root.Path) || Contains(root.Path, path)))
                            full.Add(root.Id);
                        continue;
                }
                if (RootContaining(path) is not { } owner) continue;
                var name = System.IO.Path.GetFileName(path);
                if (name.StartsWith('.')) continue;
                switch (change.Kind)
                {
                    case FolderEventKind.Directory:
                        // A folder created, removed or renamed: what is in it (or was).
                        AddFolder(path, owner);
                        break;
                    case FolderEventKind.Unknown:
                        AddFolder(System.IO.Path.GetDirectoryName(path) ?? path, owner);
                        break;
                    default:
                        var extension = System.IO.Path.GetExtension(name).TrimStart('.');
                        var folder = System.IO.Path.GetDirectoryName(path) ?? path;
                        if (extension.Equals("cue", StringComparison.OrdinalIgnoreCase) || TagReader.SupportedExtensions.Contains(extension))
                        {
                            AddFolder(folder, owner);
                        }
                        else if (ImageExtensions.Contains(extension))
                        {
                            AddFolder(folder, owner);
                            if (!artworkFolders.TryGetValue(owner.Id, out var set)) artworkFolders[owner.Id] = set = [];
                            set.Add(folder);
                        }
                        break;
                }
            }
        }
    }

    /// <summary>Checks a folder (a song that would not play because its file is gone).</summary>
    public void AddFolder(string path)
    {
        lock (gate)
        {
            path = Trimmed(path);
            if (RootContaining(path) is { } root) AddFolder(path, root);
        }
    }

    /// <summary>Checks every file of a library folder.</summary>
    public void AddFull(long rootId)
    {
        lock (gate) full.Add(rootId);
    }

    /// <summary>Hands out the waiting work, one scope per library folder, and starts over empty.</summary>
    public List<(long RootId, ScanScope Scope)> Take()
    {
        lock (gate)
        {
            var work = new List<(long, ScanScope)>();
            foreach (var root in roots)
            {
                if (full.Contains(root.Id)) work.Add((root.Id, ScanScope.Everything));
                else if (folders.TryGetValue(root.Id, out var set) && set.Count > 0)
                    work.Add((root.Id, new ScanScope.Folders(Outermost(set), artworkFolders.GetValueOrDefault(root.Id) ?? [])));
            }
            full.Clear();
            folders.Clear();
            artworkFolders.Clear();
            return work;
        }
    }

    private (long Id, string Path)? RootContaining(string path)
    {
        var matches = roots.Where(root => root.Path.Equals(path, Comparison) || Contains(root.Path, path)).ToList();
        return matches.Count == 0 ? null : matches.MaxBy(root => root.Path.Length);
    }

    private void AddFolder(string path, (long Id, string Path) root)
    {
        if (path.Equals(root.Path, Comparison) || !Contains(root.Path, path))
        {
            full.Add(root.Id);
            return;
        }
        if (!folders.TryGetValue(root.Id, out var set)) folders[root.Id] = set = new HashSet<string>(OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
        set.Add(path);
    }

    /// <summary>Whether <paramref name="path"/> is inside <paramref name="folder"/>.</summary>
    private static bool Contains(string folder, string path) =>
        path.Length > folder.Length && path.StartsWith(folder, Comparison) && (path[folder.Length] == Separator || folder.EndsWith(Separator));

    /// <summary>Folders not inside another one of the set (scanning a folder covers what is below it).</summary>
    internal static HashSet<string> Outermost(IEnumerable<string> folders)
    {
        var result = new List<string>();
        foreach (var folder in folders.Order(StringComparer.Ordinal))
        {
            if (!result.Any(kept => folder.Equals(kept, Comparison) || Contains(kept, folder))) result.Add(folder);
        }
        return result.ToHashSet();
    }

    internal static string Trimmed(string path) => path.Length > 3 ? path.TrimEnd('/', '\\') : path;
}
