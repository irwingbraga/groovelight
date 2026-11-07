using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace Groovelight.Core.Library;

/// <summary>How files are named and placed in the library folder (shared by Organize and Import).</summary>
public sealed record OrganizeOptions
{
    /// <summary>
    /// Path template relative to the library folder, without the extension. Tokens: {albumartist} {artist} {album}
    /// {title} {year} {genre} {track} {disc} (numbers accept a width, e.g. {track:02}); text in [ ] only appears when
    /// every token in it has a value; "/" separates folders. {disc} is empty for single-disc albums.
    /// </summary>
    public string Template { get; set; } = DefaultTemplate;
    /// <summary>Off: only the file name part of the template is used, files stay in their folder.</summary>
    public bool OrganizeFolders { get; set; } = true;
    /// <summary>Also replace characters Windows and many NAS shares reject (\ ? * " &lt; &gt; |). Always on, on Windows.</summary>
    public bool PortableNames { get; set; } = true;
    /// <summary>"ft." / "featuring" / "Feat" become "feat.".</summary>
    public bool NormalizeFeaturing { get; set; } = true;
    public bool TitleCase { get; set; }

    public const string DefaultTemplate = "{albumartist}/{album}[ ({year})]/[{disc}-]{track:02} {title}";

    public static readonly IReadOnlyList<(string Name, string Template)> Presets =
    [
        ("Artist / Album (Year) / 01 Title", DefaultTemplate),
        ("Artist / Year - Album / 01 Title", "{albumartist}/[{year} - ]{album}/[{disc}-]{track:02} {title}"),
        ("Artist / Album / 01 - Artist - Title", "{albumartist}/{album}/[{disc}-]{track:02} - {artist} - {title}"),
        ("Artist - Album / 01 Title", "{albumartist} - {album}/[{disc}-]{track:02} {title}"),
        ("Genre / Artist / Album / 01 Title", "{genre}/{albumartist}/{album}/[{disc}-]{track:02} {title}"),
    ];
}

/// <summary>The tag values a file name is built from.</summary>
public sealed record NamingFields(string Title, string? Artist = null, string? Album = null, string? AlbumArtist = null, string? Genre = null,
                                  int? Year = null, int? TrackNumber = null, int? DiscNumber = null, int? DiscTotal = null, bool IsCompilation = false)
{
    public static NamingFields Of(Track track) => new(track.Title, track.Artist, track.Album, track.AlbumArtist, track.Genre, track.Year,
                                                       track.TrackNumber, track.DiscNumber, track.DiscTotal, track.IsCompilation);
}

/// <summary>Templates and sanitizing.</summary>
public static partial class FileNaming
{
    /// <summary>Relative path (folders and file name, with the extension) for a song, folders separated by "/".</summary>
    public static string RelativePath(NamingFields fields, string fileExtension, OrganizeOptions options)
    {
        var components = Render(options.Template, fields, options).Split('/', StringSplitOptions.RemoveEmptyEntries).ToList();
        if (!options.OrganizeFolders) components = components.TakeLast(1).ToList();
        if (components.Count == 0) components = [Sanitize(fields.Title, options)];
        var extension = fileExtension.TrimStart('.').ToLowerInvariant();
        components[^1] = LimitLength(components[^1], extension.Length == 0 ? 0 : Encoding.UTF8.GetByteCount(extension) + 1);
        components = components.Select(component => LimitLength(component, 0)).ToList();
        return string.Join('/', components) + (extension.Length == 0 ? "" : "." + extension);
    }

    /// <summary>Renders the template; each token's value is sanitized so it cannot add folders or illegal characters.</summary>
    internal static string Render(string template, NamingFields fields, OrganizeOptions options)
    {
        var output = new StringBuilder();
        var index = 0;
        while (index < template.Length)
        {
            var close = template[index] == '[' ? template.IndexOf(']', index) : -1;
            if (close >= 0)
            {
                var (text, complete) = RenderTokens(template[(index + 1)..close], fields, options);
                if (complete) output.Append(text);
                index = close + 1;
            }
            else
            {
                var end = template.IndexOf('[', index + 1);
                if (end < 0) end = template.Length;
                output.Append(RenderTokens(template[index..end], fields, options).Text);
                index = end;
            }
        }
        // Folder parts are cleaned too (literal text from the template).
        return string.Join('/', output.ToString().Split('/', StringSplitOptions.RemoveEmptyEntries)
            .Select(component => CleanComponent(component)).Where(component => component.Length > 0));
    }

    /// <summary>Replaces {tokens}; Complete is false when a token had no value.</summary>
    private static (string Text, bool Complete) RenderTokens(string text, NamingFields fields, OrganizeOptions options)
    {
        var output = new StringBuilder();
        var complete = true;
        var rest = text;
        while (rest.IndexOf('{') is var open and >= 0 && rest.IndexOf('}', open) is var close and >= 0)
        {
            output.Append(rest[..open]);
            var spec = rest[(open + 1)..close].Split(':', 2);
            var value = TokenValue(spec[0].ToLowerInvariant(), spec.Length > 1 && int.TryParse(spec[1], out var width) ? width : null, fields, options);
            if (value.Length == 0) complete = false;
            output.Append(value);
            rest = rest[(close + 1)..];
        }
        output.Append(rest);
        return (output.ToString(), complete);
    }

    private static string TokenValue(string token, int? width, NamingFields fields, OrganizeOptions options)
    {
        string Text(string? value) => value is null ? "" : Sanitize(value, options);
        string Number(int? value) => value is > 0 ? value.Value.ToString(new string('0', Math.Max(width ?? 1, 1)), CultureInfo.InvariantCulture) : "";
        static string? NonEmpty(string? value) => string.IsNullOrWhiteSpace(value) ? null : value;
        return token switch
        {
            "title" => Text(fields.Title),
            "artist" => Text(NonEmpty(fields.Artist) ?? NonEmpty(fields.AlbumArtist) ?? "Unknown Artist"),
            "albumartist" => Text(fields.IsCompilation ? "Various Artists" : NonEmpty(fields.AlbumArtist) ?? NonEmpty(fields.Artist) ?? "Unknown Artist"),
            "album" => Text(NonEmpty(fields.Album) ?? "Unknown Album"),
            "genre" => Text(NonEmpty(fields.Genre) ?? "Unknown Genre"),
            "year" => Number(fields.Year),
            "track" => Number(fields.TrackNumber),
            // Only multi-disc albums get a disc number.
            "disc" => (fields.DiscTotal ?? 0) > 1 || (fields.DiscNumber ?? 0) > 1 ? Number(fields.DiscNumber) : "",
            _ => "",
        };
    }

    [GeneratedRegex(@"\s+(feat\.?|ft\.?|featuring)\s+", RegexOptions.IgnoreCase)]
    private static partial Regex FeaturingPattern();

    [GeneratedRegex(@"\s+")]
    private static partial Regex SpacesPattern();

    /// <summary>Makes a tag value safe as part of a file name.</summary>
    public static string Sanitize(string value, OrganizeOptions options)
    {
        var text = value.Normalize(NormalizationForm.FormC);
        if (options.NormalizeFeaturing && text.Contains('f', StringComparison.OrdinalIgnoreCase)) text = FeaturingPattern().Replace(text, " feat. ");
        if (options.TitleCase) text = TitleCased(text);
        // ":" is shown as "/" by the Finder and is a drive separator on Windows; "/" separates folders.
        text = text.Replace(": ", " - ").Replace(':', '-').Replace('/', '-');
        // Windows rejects these in names whatever the option says.
        if (options.PortableNames || OperatingSystem.IsWindows())
        {
            foreach (var character in "\\?*\"<>|") text = text.Replace(character, '_');
        }
        return string.Concat(text.Where(character => !char.IsControl(character)
            && CharUnicodeInfo.GetUnicodeCategory(character) != UnicodeCategory.Format));
    }

    private static readonly HashSet<string> ReservedNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    /// <summary>
    /// Trims and collapses spaces, removes leading dots (hidden files) and trailing dots (rejected on Windows), and keeps
    /// clear of the names Windows reserves for devices ("CON", "NUL", "COM1"...).
    /// </summary>
    internal static string CleanComponent(string component)
    {
        var text = component.Any(character => char.IsWhiteSpace(character) && character != ' ') || component.Contains("  ")
            ? SpacesPattern().Replace(component, " ")
            : component;
        text = text.Trim(' ').TrimStart('.').TrimEnd('.', ' ').Trim(' ');
        var stem = text.Split('.')[0];
        return ReservedNames.Contains(stem) ? stem + "_" + text[stem.Length..] : text;
    }

    /// <summary>Keeps a component within 255 UTF-8 bytes (the macOS limit, within Windows' 255 characters), leaving room for the extension.</summary>
    internal static string LimitLength(string component, int reserving, int limit = 255)
    {
        if (Encoding.UTF8.GetByteCount(component) + reserving <= limit) return component;
        var result = new StringBuilder();
        var bytes = 0;
        var enumerator = StringInfo.GetTextElementEnumerator(component);
        while (enumerator.MoveNext())
        {
            var element = enumerator.GetTextElement();
            var size = Encoding.UTF8.GetByteCount(element);
            if (bytes + size + reserving > limit) break;
            bytes += size;
            result.Append(element);
        }
        return result.ToString().Trim(' ');
    }

    private static readonly HashSet<string> MinorWords =
        ["a", "an", "the", "and", "but", "or", "nor", "for", "so", "yet", "of", "in", "on", "at", "to", "by", "from", "with", "as", "vs", "vs.", "feat."];

    internal static string TitleCased(string text)
    {
        var words = text.Split(' ');
        return string.Join(' ', words.Select((word, index) =>
        {
            var lower = word.ToLowerInvariant();
            if (index > 0 && index < words.Length - 1 && MinorWords.Contains(lower)) return lower;
            // Keep words already in caps (acronyms like "USA", "OK").
            if (word.Length > 1 && word == word.ToUpperInvariant() && word.Any(char.IsLetter)) return word;
            return word.Length == 0 ? word : char.ToUpperInvariant(word[0]) + word[1..];
        }));
    }
}

public enum RenameStatus
{
    Unchanged,
    Move,
    /// <summary>Renamed with " (2)" etc. because the name was taken.</summary>
    RenamedForConflict,
}

public sealed record RenamePlanItem(long? TrackId, string Source, string Destination, RenameStatus Status)
{
    public string Id => Source;
}

public static class RenamePlanner
{
    private static readonly StringComparer PathComparer = OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;

    private static string Combine(string root, string relative) => Path.GetFullPath(Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar)));

    /// <summary>
    /// Where each track should go under <paramref name="root"/>. Collisions with existing files (not being moved away) or
    /// with other planned files get " (2)", " (3)"...
    /// </summary>
    public static List<RenamePlanItem> Plan(IReadOnlyList<Track> tracks, string root, OrganizeOptions options)
    {
        var cueItems = PlanCueAlbums(tracks.Where(track => track.IsCueTrack).ToList(), root, options);
        // First pass: the ideal destination of every file.
        var ideal = tracks.Where(track => !track.IsCueTrack).OrderBy(track => track.Path, StringComparer.Ordinal).Select(track =>
        {
            var source = Path.GetFullPath(track.FilePath);
            // Without folder organizing, files stay in their folder and only the name changes.
            var @base = options.OrganizeFolders ? root : Path.GetDirectoryName(source)!;
            var relative = FileNaming.RelativePath(NamingFields.Of(track), Path.GetExtension(source), options);
            return (Track: track, Source: source, Base: @base, Relative: relative);
        }).ToList();
        // Files already at their destination keep it; the others may take the names of files that move away.
        var staying = ideal.Where(entry => Combine(entry.Base, entry.Relative) == entry.Source).Select(entry => entry.Source).ToHashSet();
        var movingAway = ideal.Select(entry => entry.Source).Where(source => !staying.Contains(source)).ToHashSet(PathComparer);
        var taken = staying.Concat(cueItems.Select(item => item.Destination)).Select(path => path.ToLowerInvariant()).ToHashSet();

        var items = new List<RenamePlanItem>(cueItems);
        foreach (var entry in ideal)
        {
            var destination = Combine(entry.Base, entry.Relative);
            if (staying.Contains(entry.Source))
            {
                items.Add(new RenamePlanItem(entry.Track.Id, entry.Source, destination, RenameStatus.Unchanged));
                continue;
            }
            var status = RenameStatus.Move;
            var counter = 2;
            // Taken by another planned file, or by a file on disk that is not moving away (case-insensitive file systems).
            while (taken.Contains(destination.ToLowerInvariant()) || (File.Exists(destination) && !movingAway.Contains(destination)))
            {
                destination = Numbered(Combine(entry.Base, entry.Relative), counter++);
                status = RenameStatus.RenamedForConflict;
            }
            taken.Add(destination.ToLowerInvariant());
            items.Add(new RenamePlanItem(entry.Track.Id, entry.Source, destination, status));
        }
        return items;
    }

    /// <summary>
    /// Albums stored as one audio file with a cue sheet move as a unit: the audio file and its sheet go into the
    /// template's album folder and keep their names, so the sheet's FILE line still finds the audio. Songs are not
    /// renamed (they are not files). Without folder organizing, or when the names are taken there, they stay put.
    /// </summary>
    internal static List<RenamePlanItem> PlanCueAlbums(List<Track> tracks, string root, OrganizeOptions options)
    {
        var items = new List<RenamePlanItem>();
        foreach (var group in tracks.GroupBy(track => Path.GetFullPath(track.FilePath)).OrderBy(group => group.Key, StringComparer.Ordinal))
        {
            var audio = group.Key;
            var first = group.MinBy(track => track.TrackNumber ?? 0)!;
            var files = new List<string> { audio };
            if (first.CueSheetPath is { } sheet && Path.GetFullPath(sheet) != audio) files.Add(Path.GetFullPath(sheet));
            var relative = FileNaming.RelativePath(NamingFields.Of(first), Path.GetExtension(audio), options);
            var folder = Path.GetDirectoryName(Combine(root, relative))!;
            var destinations = files.Select(file => Path.Combine(folder, Path.GetFileName(file))).ToList();
            var moves = options.OrganizeFolders && !PathComparer.Equals(folder, Path.GetDirectoryName(audio)) && !destinations.Any(File.Exists);
            for (var index = 0; index < files.Count; index++)
            {
                items.Add(new RenamePlanItem(null, files[index], moves ? destinations[index] : files[index], moves ? RenameStatus.Move : RenameStatus.Unchanged));
            }
        }
        return items;
    }

    /// <summary>"…/01 Title.flac" with 2 becomes "…/01 Title (2).flac".</summary>
    internal static string Numbered(string path, int counter) =>
        Path.Combine(Path.GetDirectoryName(path)!, $"{Path.GetFileNameWithoutExtension(path)} ({counter}){Path.GetExtension(path)}");
}

/// <summary>Record of a rename or import, for undo. Saved as JSON (the Mac's format).</summary>
public sealed record FileOperationJournal
{
    public enum JournalKind { Organize, Import }

    public sealed record Entry(long? TrackId, string From, string To, bool Copied);

    public string Id { get; init; } = Guid.NewGuid().ToString().ToUpperInvariant();
    public JournalKind Kind { get; init; }
    public DateTime Date { get; init; } = DateTime.UtcNow;
    public List<Entry> Entries { get; init; } = [];
    /// <summary>Folders the operation created (removed on undo when empty).</summary>
    public List<string> CreatedFolders { get; init; } = [];
    /// <summary>
    /// Archives an import came from that were moved to the Recycle Bin (From: where it was, To: where the bin keeps it).
    /// Undo puts them back, and recycles the imported songs instead of deleting them, so nothing is lost if that fails.
    /// </summary>
    public List<Entry>? Trashed { get; init; }
}

/// <summary>Where removed files go: the Recycle Bin on Windows, the Trash on the Mac.</summary>
public interface IRecycleBin
{
    /// <summary>Moves the file there; returns where it is kept, when known (to put it back later).</summary>
    string? Recycle(string path);

    /// <summary>Puts a recycled file back at <paramref name="originalPath"/>; false when it is not there any more.</summary>
    bool Restore(string originalPath, string? keptAt);
}

public static class FileOrganizer
{
    /// <summary>Set by the app (the Windows Recycle Bin); a folder in the temporary directory until then.</summary>
    public static IRecycleBin RecycleBin { get; set; } = new FolderRecycleBin(Path.Combine(Path.GetTempPath(), "Groovelight Recycled"));

    /// <summary>Extensions of files that travel with an album folder.</summary>
    internal static readonly HashSet<string> CompanionExtensions = new(StringComparer.OrdinalIgnoreCase)
        { "jpg", "jpeg", "png", "webp", "heic", "gif", "lrc", "cue", "log", "txt", "pdf", "nfo", "m3u", "m3u8" };

    private static string Extension(string path) => Path.GetExtension(path).TrimStart('.');

    /// <summary>
    /// Moves the files of a plan (through temporary names, so swaps and cycles are safe), updates the library paths,
    /// brings album images and other companion files along when a whole folder moves, and removes emptied folders.
    /// Stops and rolls back on the first failure.
    /// </summary>
    public static FileOperationJournal Apply(IReadOnlyList<RenamePlanItem> plan, LibraryDatabase database)
    {
        var moves = plan.Where(item => item.Status != RenameStatus.Unchanged).ToList();
        var entries = new List<FileOperationJournal.Entry>();
        var created = new List<string>();

        void CreateFolders(string path)
        {
            var missing = new List<string>();
            var folder = Path.GetDirectoryName(path);
            while (folder is not null && !Directory.Exists(folder))
            {
                missing.Add(folder);
                folder = Path.GetDirectoryName(folder);
            }
            for (var index = missing.Count - 1; index >= 0; index--)
            {
                Directory.CreateDirectory(missing[index]);
                created.Add(missing[index]);
            }
        }

        // Companion files: a source folder whose audio files all move to one destination folder.
        var movingSources = moves.Select(item => item.Source).ToHashSet();
        var companions = new List<(string From, string To)>();
        foreach (var group in moves.GroupBy(item => Path.GetDirectoryName(item.Source)!))
        {
            var destinations = group.Select(item => Path.GetDirectoryName(item.Destination)!).Distinct().ToList();
            if (destinations.Count != 1 || destinations[0] == group.Key) continue;
            string[] contents;
            try { contents = Directory.GetFiles(group.Key); }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { continue; }
            var movingNames = group.Select(item => Path.GetFileName(item.Source)).ToHashSet();
            if (contents.Any(file => TagReader.SupportedExtensions.Contains(Extension(file)) && !movingNames.Contains(Path.GetFileName(file)))) continue;
            foreach (var file in contents.Where(file => CompanionExtensions.Contains(Extension(file)) && !movingSources.Contains(Path.GetFullPath(file))))
            {
                var destination = Path.Combine(destinations[0], Path.GetFileName(file));
                if (!File.Exists(destination)) companions.Add((file, destination));
            }
        }

        var temporaries = new List<(RenamePlanItem Item, string Temporary)>();
        try
        {
            // Phase 1: every moving file to a temporary name next to it.
            foreach (var item in moves)
            {
                var temporary = Path.Combine(Path.GetDirectoryName(item.Source)!, $".groovelight-{Guid.NewGuid()}{Path.GetExtension(item.Source)}");
                File.Move(item.Source, temporary);
                temporaries.Add((item, temporary));
            }
            // Phase 2: temporary names to destinations.
            for (var index = 0; index < temporaries.Count; index++)
            {
                var (item, temporary) = temporaries[index];
                CreateFolders(item.Destination);
                File.Move(temporary, item.Destination);
                temporaries[index] = (item, item.Destination);
                entries.Add(new FileOperationJournal.Entry(item.TrackId, item.Source, item.Destination, false));
            }
            foreach (var (from, to) in companions)
            {
                CreateFolders(to);
                File.Move(from, to);
                entries.Add(new FileOperationJournal.Entry(null, from, to, false));
            }
        }
        catch
        {
            // Put everything back where it was.
            for (var index = temporaries.Count - 1; index >= 0; index--)
            {
                var (item, temporary) = temporaries[index];
                if (File.Exists(temporary)) TryMove(temporary, item.Source);
            }
            foreach (var entry in entries.Where(entry => entry.TrackId is null)) TryMove(entry.To, entry.From);
            for (var index = created.Count - 1; index >= 0; index--) TryDeleteFolder(created[index]);
            throw;
        }

        database.UpdatePaths(entries.Where(entry => entry.TrackId is not null).Select(entry => (entry.TrackId!.Value, entry.To)).ToList());
        database.RelocateCueFiles(entries.Where(entry => entry.TrackId is null).Select(entry => (entry.From, entry.To)).ToList());
        RemoveEmptyFolders(moves.Select(item => Path.GetDirectoryName(item.Source)!).ToHashSet());
        return new FileOperationJournal { Kind = FileOperationJournal.JournalKind.Organize, Entries = entries, CreatedFolders = created };
    }

    /// <summary>
    /// Reverses an organize or import: files go back (copies are deleted), library paths follow, created folders that
    /// end up empty are removed.
    /// </summary>
    public static void Undo(FileOperationJournal journal, LibraryDatabase database)
    {
        var restored = new List<(long, string)>();
        var removedTracks = new List<long>();
        var restoredFiles = new List<(string From, string To)>();
        var untracked = new List<string>();
        for (var index = journal.Entries.Count - 1; index >= 0; index--)
        {
            var entry = journal.Entries[index];
            if (!File.Exists(entry.To)) continue;
            if (entry.TrackId is null) untracked.Add(entry.To);
            if (entry.Copied)
            {
                if (journal.Trashed is { Count: > 0 }) RecycleBin.Recycle(entry.To);
                else File.Delete(entry.To);
                if (entry.TrackId is { } copiedId) removedTracks.Add(copiedId);
                continue;
            }
            Directory.CreateDirectory(Path.GetDirectoryName(entry.From)!);
            File.Move(entry.To, entry.From);
            if (entry.TrackId is { } id) restored.Add((id, entry.From));
            else restoredFiles.Add((entry.To, entry.From));
        }
        foreach (var archive in journal.Trashed ?? [])
        {
            if (!File.Exists(archive.From)) RecycleBin.Restore(archive.From, archive.To);
        }
        if (journal.Kind == FileOperationJournal.JournalKind.Import)
        {
            // Imported songs leave the library entirely (moved back out, or their copies deleted), cue albums included.
            removedTracks.AddRange(restored.Select(pair => pair.Item1));
            if (untracked.Count > 0)
            {
                removedTracks.AddRange(database.Read(db => db.Column<long>(
                    $"SELECT id FROM track WHERE audioPath IN ({string.Join(",", untracked.Select(_ => "?"))})", [.. untracked])));
            }
        }
        else
        {
            database.UpdatePaths(restored);
            database.RelocateCueFiles(restoredFiles);
        }
        if (removedTracks.Count > 0)
        {
            database.Write(db =>
            {
                foreach (var id in removedTracks) db.Execute("DELETE FROM track WHERE id = ?", id);
            });
        }
        RemoveEmptyFolders(journal.Entries.Select(entry => Path.GetDirectoryName(entry.To)!).Concat(journal.CreatedFolders).ToHashSet());
    }

    /// <summary>Removes folders left with nothing (or only .DS_Store, Thumbs.db, desktop.ini), walking up while parents empty too.</summary>
    internal static void RemoveEmptyFolders(IReadOnlySet<string> folders)
    {
        string[] ignorable = [".DS_Store", "Thumbs.db", "desktop.ini"];
        foreach (var folder in folders.OrderByDescending(folder => folder.Length))
        {
            var current = folder;
            for (var step = 0; step < 4 && current is not null; step++)
            {
                try
                {
                    if (!Directory.Exists(current) || Directory.EnumerateDirectories(current).Any()) break;
                    if (Directory.GetFiles(current).Any(file => !ignorable.Contains(Path.GetFileName(file), StringComparer.OrdinalIgnoreCase))) break;
                    Directory.Delete(current, recursive: true);
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                    break;
                }
                current = Path.GetDirectoryName(current);
            }
        }
    }

    private static void TryMove(string from, string to)
    {
        try { File.Move(from, to); } catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
    }

    private static void TryDeleteFolder(string folder)
    {
        try { Directory.Delete(folder); } catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
    }

    // MARK: Journals on disk

    private static readonly JsonSerializerOptions JournalJson = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    public static void Save(FileOperationJournal journal, string folder)
    {
        Directory.CreateDirectory(folder);
        var seconds = (long)(journal.Date - DateTime.UnixEpoch).TotalSeconds;
        File.WriteAllText(Path.Combine(folder, $"{seconds}-{journal.Id}.json"), JsonSerializer.Serialize(journal, JournalJson));
    }

    /// <summary>The newest journal that was not undone yet.</summary>
    public static (FileOperationJournal Journal, string Path)? LatestJournal(string folder)
    {
        if (!Directory.Exists(folder)) return null;
        foreach (var file in Directory.GetFiles(folder, "*.json").OrderByDescending(Path.GetFileName, StringComparer.Ordinal))
        {
            try
            {
                if (JsonSerializer.Deserialize<FileOperationJournal>(File.ReadAllText(file), JournalJson) is { } journal) return (journal, file);
            }
            catch (Exception exception) when (exception is JsonException or IOException) { }
        }
        return null;
    }
}

/// <summary>A recycle bin that is a plain folder (tests, and systems without one).</summary>
public sealed class FolderRecycleBin(string folder) : IRecycleBin
{
    public string? Recycle(string path)
    {
        Directory.CreateDirectory(folder);
        var destination = Path.Combine(folder, $"{Guid.NewGuid():N}-{Path.GetFileName(path)}");
        File.Move(path, destination);
        return destination;
    }

    public bool Restore(string originalPath, string? keptAt)
    {
        if (keptAt is null || !File.Exists(keptAt)) return false;
        Directory.CreateDirectory(Path.GetDirectoryName(originalPath)!);
        File.Move(keptAt, originalPath);
        return true;
    }
}

public sealed partial class LibraryDatabase
{
    /// <summary>Points songs at their new files (after a rename, an import or an undo).</summary>
    public void UpdatePaths(IReadOnlyList<(long TrackId, string Path)> changes)
    {
        if (changes.Count == 0) return;
        Write(db =>
        {
            // Through temporary values: swapped names would otherwise hit the unique path constraint.
            foreach (var (trackId, _) in changes) db.Execute("UPDATE track SET path = ? WHERE id = ?", $"\u0001moving-{trackId}", trackId);
            foreach (var (trackId, path) in changes) db.Execute("UPDATE track SET path = ? WHERE id = ?", path, trackId);
        });
    }

    /// <summary>
    /// Follows audio files and cue sheets that moved: songs of a cue sheet keep pointing at their audio file (audioPath)
    /// and are stored under the sheet's path ("&lt;sheet&gt;#NN").
    /// </summary>
    public void RelocateCueFiles(IReadOnlyList<(string From, string To)> moves)
    {
        if (moves.Count == 0) return;
        Write(db =>
        {
            foreach (var (from, to) in moves)
            {
                db.Execute("UPDATE track SET audioPath = ? WHERE audioPath = ?", to, from);
                // A range instead of LIKE: paths may contain "%" or "_". substr and length both count characters.
                db.Execute("""
                    UPDATE track SET path = ? || substr(path, length(?) + 1)
                    WHERE path >= ? || '#' AND path < ? || '$'
                    """, to, from, from, from);
            }
        });
    }
}

public static class TrackCandidates
{
    /// <summary>A provisional song built from a file's tags (not in the library), e.g. to identify files before importing them.</summary>
    public static Track Candidate(long id, string path, FileTags tags) => new()
    {
        Id = id, RootId = 0, Path = path, ModifiedAt = DateTime.UtcNow,
        Title = tags.Title.NonEmpty() ?? Path.GetFileNameWithoutExtension(path), Artist = tags.Artist.NonEmpty(), Album = tags.Album.NonEmpty(),
        AlbumArtist = tags.AlbumArtist.NonEmpty(), Composer = tags.Composer, Genre = tags.Genre, Year = tags.Year, TrackNumber = tags.TrackNumber,
        TrackTotal = tags.TrackTotal, DiscNumber = tags.DiscNumber, DiscTotal = tags.DiscTotal, IsCompilation = tags.IsCompilation, Bpm = tags.Bpm,
        Comment = tags.Comment, Lyrics = tags.Lyrics, MusicBrainzRecordingId = tags.MusicBrainzRecordingId, MusicBrainzReleaseId = tags.MusicBrainzReleaseId,
        Duration = tags.Duration, Format = tags.Format, SampleRate = tags.SampleRate, BitDepth = tags.BitDepth, Bitrate = tags.Bitrate,
        Channels = tags.Channels, AlbumKey = Track.MakeAlbumKey(tags.Album, tags.AlbumArtist, tags.Artist, tags.IsCompilation),
    };
}
