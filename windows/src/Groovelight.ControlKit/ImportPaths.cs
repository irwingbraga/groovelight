namespace Groovelight.ControlKit;

/// <summary>
/// What the command line tool and AI connectors may import from. A request (typed, scripted, or made by an AI model that
/// read a malicious instruction somewhere) must not reach the home folder as a whole, a whole drive, app data, hidden
/// folders or Windows' own folders. Imports move files by default, so a wrong folder would scatter the user's files.
/// </summary>
public static class ImportPaths
{
    /// <summary>The folders the rules are about; <see cref="Current"/> on this PC.</summary>
    public sealed record Folders(string Home, IReadOnlyList<string> System);

    public static Folders Current => new(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        }.Where(folder => folder.Length > 0).ToList());

    /// <summary>Why <paramref name="path"/> may not be imported from, or null when it may.</summary>
    public static string? Refusal(string path, Folders? folders = null)
    {
        folders ??= Current;
        var resolved = Normalize(Resolve(path));
        var home = Normalize(folders.Home);
        bool Within(string folder) => resolved.Equals(folder, StringComparison.OrdinalIgnoreCase)
            || resolved.StartsWith(folder + "\\", StringComparison.OrdinalIgnoreCase);

        if (IsRoot(resolved) || resolved.Equals(home, StringComparison.OrdinalIgnoreCase) || home.StartsWith(resolved + "\\", StringComparison.OrdinalIgnoreCase))
            return $"{path} is too broad to import from: choose the folder or archive with the music.";
        if (Within(home))
        {
            var inside = resolved[(home.Length + 1)..].Split('\\', StringSplitOptions.RemoveEmptyEntries);
            if (inside.Length > 0 && inside[0].Equals("AppData", StringComparison.OrdinalIgnoreCase))
                return $"{path} is app data, not music: Groovelight does not import from AppData.";
            if (inside.Any(part => part.StartsWith('.')))
                return $"{path} is in a hidden folder: Groovelight does not import from hidden folders.";
            return null;
        }
        if (folders.System.Select(Normalize).Any(Within))
            return $"{path} is a system folder: Groovelight does not import from it.";
        return null;
    }

    /// <summary>Throws the first refusal.</summary>
    public static void Check(IEnumerable<string> paths, Folders? folders = null)
    {
        if (paths.Select(path => Refusal(path, folders)).FirstOrDefault(reason => reason is not null) is { } reason) throw new ControlException(reason);
    }

    /// <summary>The full path, through a link (junction or symbolic link) when the item is one.</summary>
    private static string Resolve(string path)
    {
        if (!OperatingSystem.IsWindows()) return path;
        try
        {
            path = Environment.ExpandEnvironmentVariables(path);
            // "D:" (or "D:Music") is relative to the current folder on that drive; people mean the drive itself.
            if (path.Length >= 2 && path[1] == ':' && char.IsAsciiLetter(path[0]) && (path.Length == 2 || path[2] is not ('\\' or '/')))
                path = path[..2] + "\\" + path[2..];
            var full = Path.GetFullPath(path);
            FileSystemInfo item = Directory.Exists(full) ? new DirectoryInfo(full) : new FileInfo(full);
            return item.ResolveLinkTarget(returnFinalTarget: true)?.FullName ?? full;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return path;
        }
    }

    /// <summary>A Windows path with backslashes, without "." and ".." parts or a trailing backslash (a drive keeps its own).</summary>
    internal static string Normalize(string path)
    {
        var text = path.Replace('/', '\\');
        var unc = text.StartsWith(@"\\", StringComparison.Ordinal);
        var parts = new List<string>();
        foreach (var part in text.Split('\\', StringSplitOptions.RemoveEmptyEntries))
        {
            if (part == ".") continue;
            if (part == "..")
            {
                if (parts.Count > (unc ? 2 : 1)) parts.RemoveAt(parts.Count - 1);
                continue;
            }
            parts.Add(part);
        }
        var joined = string.Join('\\', parts);
        if (unc) return @"\\" + joined;
        return parts.Count == 1 && joined.EndsWith(':') ? joined + "\\" : joined;
    }

    /// <summary>A drive ("D:\") or a network share ("\\server\share").</summary>
    private static bool IsRoot(string normalized) =>
        (normalized.Length <= 3 && normalized.Length >= 2 && normalized[1] == ':')
        || (normalized.StartsWith(@"\\", StringComparison.Ordinal) && normalized[2..].Split('\\').Length <= 2);
}
