using System.Globalization;
using System.Text;

namespace Groovelight.Core.Library;

public sealed record ScanProgress(int FilesFound, int FilesProcessed, string? CurrentPath = null);

public sealed record ScanSummary
{
    public int Added { get; set; }
    public int Updated { get; set; }
    public int Removed { get; set; }
    public int Unchanged { get; set; }
    public List<string> Failed { get; init; } = [];
}

/// <summary>What part of a library folder a scan looks at.</summary>
public abstract record ScanScope
{
    /// <summary>Every file of the folder.</summary>
    public sealed record Full : ScanScope;

    /// <summary>
    /// Only these folders (and what is below them). Songs in <paramref name="ArtworkFolders"/> are read again even if
    /// their files did not change, because a cover image beside them did.
    /// </summary>
    public sealed record Folders(IReadOnlySet<string> Paths, IReadOnlySet<string>? ArtworkFolders = null) : ScanScope;

    public static readonly ScanScope Everything = new Full();
}

public sealed class FolderUnavailableException(string path) : IOException($"The folder {path} is not available.")
{
    public string FolderPath { get; } = path;
}

/// <summary>Walks a library root, reads tags of new or changed files and keeps the track table in sync.</summary>
public sealed class LibraryScanner(LibraryDatabase database, ArtworkCache artwork, int parallelism = 8)
{
    private sealed record FileInfoEntry(string Path, long Size, DateTime ModifiedAt);

    private sealed record Existing(long Id, long Size, DateTime ModifiedAt, DateTime DateAdded, int Rating, bool Loved, int Plays, int Skips,
                                   DateTime? LastPlayed, byte[]? Overrides, string? FetchedLyrics, DateTime? LyricsCheckedAt,
                                   string? FetchedArtworkHash, DateTime? LovedAt);

    /// <summary>An album stored as one audio file, described by a cue sheet (external, or embedded in the file).</summary>
    private sealed record CueGroup(string Base, FileInfoEntry Audio, CueSheet Sheet, List<CueSheet.Track> Tracks, DateTime ModifiedAt);

    /// <summary>Scans run one at a time: two overlapping scans would both insert the same new files.</summary>
    private readonly SemaphoreSlim serial = new(1, 1);

    private static readonly char Separator = Path.DirectorySeparatorChar;

    public async Task<ScanSummary> ScanAsync(LibraryRoot root, ScanScope? scope = null, Action<ScanProgress>? progress = null,
                                             CancellationToken cancellation = default)
    {
        await serial.WaitAsync(cancellation);
        try
        {
            return await Task.Run(() => PerformScan(root, scope ?? ScanScope.Everything, progress, cancellation), cancellation);
        }
        finally
        {
            serial.Release();
        }
    }

    private ScanSummary PerformScan(LibraryRoot root, ScanScope scope, Action<ScanProgress>? progress, CancellationToken cancellation)
    {
        if (root.Id is not { } rootId) return new ScanSummary();
        // A missing folder would look like every file was deleted, and removing its songs would lose their history.
        if (!IsReadableFolder(root.Path)) throw new FolderUnavailableException(root.Path);

        // The folders to look at, and the songs the library has there.
        var allAudio = new List<FileInfoEntry>();
        var cueFiles = new List<FileInfoEntry>();
        var area = "rootId = ?";
        var arguments = new List<object?> { rootId };
        IReadOnlySet<string> refreshArtwork = new HashSet<string>();
        switch (scope)
        {
            case ScanScope.Folders folders:
                refreshArtwork = folders.ArtworkFolders ?? new HashSet<string>();
                var sorted = folders.Paths.Order(StringComparer.Ordinal).ToList();
                foreach (var folder in sorted)
                {
                    var (audio, cues) = EnumerateFiles(folder);
                    allAudio.AddRange(audio);
                    cueFiles.AddRange(cues);
                }
                // Paths under each folder: from "folder\" up to (not including) the character after the separator.
                area += " AND (" + string.Join(" OR ", sorted.Select(_ => "(path >= ? AND path < ?)")) + ")";
                foreach (var folder in sorted)
                {
                    arguments.Add(folder + Separator);
                    arguments.Add(folder + (char)(Separator + 1));
                }
                break;
            default:
                (allAudio, cueFiles) = EnumerateFiles(root.Path);
                break;
        }
        progress?.Invoke(new ScanProgress(allAudio.Count, 0));

        var existing = database.Read(db => db.Query($"""
            SELECT id, path, fileSize, modifiedAt, dateAdded, rating, isLoved, playCount, skipCount, lastPlayedAt,
                   metadataOverrides, fetchedLyrics, lyricsCheckedAt, fetchedArtworkHash, lovedAt
            FROM track WHERE {area}
            """, row => (Path: row.Required<string>("path"), Value: new Existing(
                row.Get<long>("id"), row.Get<long>("fileSize"), row.Get<DateTime>("modifiedAt"), row.Get<DateTime>("dateAdded"),
                row.Get<int>("rating"), row.Get<bool>("isLoved"), row.Get<int>("playCount"), row.Get<int>("skipCount"),
                row.Get<DateTime?>("lastPlayedAt"), row.Get<byte[]>("metadataOverrides"), row.Get<string>("fetchedLyrics"),
                row.Get<DateTime?>("lyricsCheckedAt"), row.Get<string>("fetchedArtworkHash"), row.Get<DateTime?>("lovedAt"))),
            [.. arguments])).ToDictionary(pair => pair.Path, pair => pair.Value);

        // CUE tracks are stored as "<sheet>#NN": group them by sheet.
        var virtualByBase = new Dictionary<string, List<string>>();
        foreach (var path in existing.Keys)
        {
            var hash = path.LastIndexOf('#');
            if (hash < 0) continue;
            var key = path[..hash];
            if (!virtualByBase.TryGetValue(key, out var list)) virtualByBase[key] = list = [];
            list.Add(path);
        }

        // External cue sheets: a FILE with two or more tracks turns that audio file into one song per track.
        var audioByPath = new Dictionary<string, FileInfoEntry>();
        foreach (var file in allAudio) audioByPath.TryAdd(file.Path, file);
        var audioPaths = audioByPath.Keys.ToHashSet();
        var cueGroups = new List<CueGroup>();
        var covered = new HashSet<string>();
        foreach (var cue in cueFiles)
        {
            if (CueSheet.Read(cue.Path) is not { } sheet) continue;
            foreach (var file in sheet.Files.Where(file => file.Tracks.Count >= 2))
            {
                var audioPath = CueSheet.Resolve(file.Name, Path.GetDirectoryName(cue.Path)!, audioPaths);
                if (audioPath is null || covered.Contains(audioPath) || !audioByPath.TryGetValue(audioPath, out var audio)) continue;
                covered.Add(audioPath);
                cueGroups.Add(new CueGroup(cue.Path, audio, sheet, file.Tracks, Max(cue.ModifiedAt, audio.ModifiedAt)));
            }
        }
        var files = allAudio.Where(file => !covered.Contains(file.Path)).ToList();

        var summary = new ScanSummary();
        var seenPaths = new HashSet<string>();
        var changed = new List<FileInfoEntry>();
        // Songs beside a new or changed cover image are read again for it.
        bool CoverChanged(string path) => refreshArtwork.Contains(Path.GetDirectoryName(path) ?? "");
        foreach (var file in files)
        {
            seenPaths.Add(file.Path);
            if (CoverChanged(file.Path))
            {
                changed.Add(file);
            }
            else if (existing.TryGetValue(file.Path, out var old) && old.Size == file.Size && SameTime(old.ModifiedAt, file.ModifiedAt))
            {
                summary.Unchanged++;
            }
            else if (virtualByBase.TryGetValue(file.Path, out var virtualPaths) && virtualPaths.All(path => SameTime(existing[path].ModifiedAt, file.ModifiedAt)))
            {
                // A file with an embedded cue sheet, unchanged: keep its tracks.
                seenPaths.UnionWith(virtualPaths);
                summary.Unchanged += virtualPaths.Count;
            }
            else
            {
                changed.Add(file);
            }
        }
        var changedCues = new List<CueGroup>();
        foreach (var group in cueGroups)
        {
            if (!CoverChanged(group.Audio.Path) && virtualByBase.TryGetValue(group.Base, out var virtualPaths) && virtualPaths.Count == group.Tracks.Count
                && virtualPaths.All(path => SameTime(existing[path].ModifiedAt, group.ModifiedAt)))
            {
                seenPaths.UnionWith(virtualPaths);
                summary.Unchanged += virtualPaths.Count;
            }
            else
            {
                changedCues.Add(group);
            }
        }

        // Moved or renamed folders, or a library relocated to another path: a new file and a missing song with the same
        // file name and size are the same song, which keeps its id and history (plays, loves, playlists, fixes).
        var missingByIdentity = new Dictionary<string, List<Existing>>();
        foreach (var (path, old) in existing)
        {
            if (seenPaths.Contains(path) || path.Contains('#')) continue;
            var key = Identity(Path.GetFileName(path), old.Size);
            if (!missingByIdentity.TryGetValue(key, out var list)) missingByIdentity[key] = list = [];
            list.Add(old);
        }
        var newFiles = changed.Where(file => !existing.ContainsKey(file.Path)).ToList();
        var newByIdentity = newFiles.GroupBy(file => Identity(Path.GetFileName(file.Path), file.Size)).ToDictionary(group => group.Key, group => group.Count());
        var moved = new Dictionary<string, Existing>();
        foreach (var file in newFiles)
        {
            var key = Identity(Path.GetFileName(file.Path), file.Size);
            // Only unambiguous pairs: one missing song and one new file with that identity.
            if (!missingByIdentity.TryGetValue(key, out var candidates) || candidates.Count != 1 || newByIdentity[key] != 1) continue;
            moved[file.Path] = candidates[0];
            missingByIdentity.Remove(key);
        }
        var movedIds = moved.Values.Select(old => old.Id).ToHashSet();

        // Read tags in parallel, a batch at a time, then store artwork and save in order.
        var processed = summary.Unchanged;
        var folderArtwork = new Dictionary<string, string?>();
        // Files with an embedded cue sheet, handled after the parallel read (with the albums of external sheets).
        var cueAlbums = new List<(CueGroup Group, FileTags Tags)>();
        foreach (var chunk in changed.Chunk(200))
        {
            cancellation.ThrowIfCancellationRequested();
            var results = new (FileTags? Tags, bool Failed)[chunk.Length];
            Parallel.For(0, chunk.Length, new ParallelOptions { MaxDegreeOfParallelism = parallelism, CancellationToken = cancellation }, index =>
            {
                try { results[index] = (TagReader.Read(chunk[index].Path), false); }
                catch (Exception exception) when (exception is not OperationCanceledException) { results[index] = (null, true); }
            });
            var batch = new List<Track>();
            for (var index = 0; index < chunk.Length; index++)
            {
                var file = chunk[index];
                processed++;
                if (results[index].Tags is not { } tags)
                {
                    summary.Failed.Add(file.Path);
                    continue;
                }
                // A cue sheet inside the file: one song per track, like an external sheet.
                if (tags.CueSheet is { } text && CueSheet.Parse(text) is { } sheet && sheet.Files[0].Tracks.Count >= 2)
                {
                    seenPaths.Remove(file.Path);
                    cueAlbums.Add((new CueGroup(file.Path, file, sheet, sheet.Files[0].Tracks, file.ModifiedAt), tags));
                    continue;
                }
                var hash = ArtworkHash(tags, file.Path, folderArtwork);
                tags.Artwork = null;
                var old = existing.GetValueOrDefault(file.Path) ?? moved.GetValueOrDefault(file.Path);
                if (old is null) summary.Added++; else summary.Updated++;
                batch.Add(MakeTrack(rootId, file, tags, hash, old));
            }
            Save(batch);
            progress?.Invoke(new ScanProgress(allAudio.Count, processed, chunk[^1].Path));
        }
        // Albums described by external cue sheets.
        foreach (var group in changedCues)
        {
            try { cueAlbums.Add((group, TagReader.Read(group.Audio.Path))); }
            catch (Exception) { summary.Failed.Add(group.Audio.Path); }
        }
        var cueBatch = new List<Track>();
        foreach (var (group, tags) in cueAlbums)
        {
            foreach (var track in MakeCueTracks(rootId, group, tags, ArtworkHash(tags, group.Audio.Path, folderArtwork), existing))
            {
                seenPaths.Add(track.Path);
                if (existing.ContainsKey(track.Path)) summary.Updated++; else summary.Added++;
                cueBatch.Add(track);
            }
        }
        Save(cueBatch);

        // Remove tracks whose files (or cue tracks) disappeared. Only when gone for sure: a drive with read errors can
        // hide whole folders from the listing, and removing their songs would lose their history. So a song stays when
        // its file or cue sheet could not be read, when its file still answers (with an error rather than "not found"),
        // or when the folder itself went away during the scan (an unplugged drive).
        var unreadable = summary.Failed.ToHashSet();
        var readCues = cueAlbums.Select(album => album.Group.Base).ToHashSet();
        var missing = existing.Where(pair =>
        {
            var (path, old) = pair;
            if (seenPaths.Contains(path) || movedIds.Contains(old.Id)) return false;
            if (CueBase(path) is { } cueBase) return readCues.Contains(cueBase) || IsGone(cueBase);
            return !unreadable.Contains(path) && IsGone(path);
        }).Select(pair => pair.Value.Id).ToList();
        if (missing.Count > 0)
        {
            if (!IsReadableFolder(root.Path)) throw new FolderUnavailableException(root.Path);
            summary.Removed = missing.Count;
            database.Write(db =>
            {
                foreach (var id in missing) db.Execute("DELETE FROM track WHERE id = ?", id);
            });
        }
        var now = DateTime.UtcNow;
        database.Write(db =>
        {
            if (scope is ScanScope.Full) db.Execute("UPDATE libraryRoot SET lastScanAt = ?, lastFullScanAt = ? WHERE id = ?", now, now, rootId);
            else db.Execute("UPDATE libraryRoot SET lastScanAt = ? WHERE id = ?", now, rootId);
        });
        progress?.Invoke(new ScanProgress(allAudio.Count, allAudio.Count));
        return summary;
    }

    private static DateTime Max(DateTime a, DateTime b) => a > b ? a : b;

    private static bool SameTime(DateTime a, DateTime b) => Math.Abs((a - b).TotalSeconds) < 1;

    /// <summary>The file's embedded cover, else a cover image in its folder (looked up once per folder).</summary>
    private string? ArtworkHash(FileTags tags, string file, Dictionary<string, string?> folderCache)
    {
        if (tags.Artwork is { } data && artwork.Store(data) is { } hash) return hash;
        var directory = Path.GetDirectoryName(file) ?? "";
        if (folderCache.TryGetValue(directory, out var cached)) return cached;
        string? found = null;
        if (ArtworkCache.FolderImage(directory) is { } image)
        {
            try { found = artwork.Store(File.ReadAllBytes(image)); }
            catch (IOException) { }
        }
        folderCache[directory] = found;
        return found;
    }

    /// <summary>One song per cue track, pointing at the shared audio file with its start and end.</summary>
    private static List<Track> MakeCueTracks(long rootId, CueGroup group, FileTags tags, string? artworkHash, Dictionary<string, Existing> existing)
    {
        var sheet = group.Sheet;
        var total = tags.Duration;
        var tracks = new List<Track>();
        for (var index = 0; index < group.Tracks.Count; index++)
        {
            var cue = group.Tracks[index];
            double? next = index + 1 < group.Tracks.Count ? group.Tracks[index + 1].Start : null;
            var duration = Math.Max(0, (next ?? total) - cue.Start);
            var path = group.Base + "#" + cue.Number.ToString("00", CultureInfo.InvariantCulture);
            var old = existing.GetValueOrDefault(path);
            var albumArtist = sheet.Performer ?? tags.AlbumArtist.NonEmpty();
            var artist = cue.Performer ?? sheet.Performer ?? tags.Artist.NonEmpty();
            var album = sheet.Title ?? tags.Album.NonEmpty();
            var track = new Track
            {
                Id = old?.Id, RootId = rootId, Path = path,
                // The file's size shared out by length (for size limits of smart playlists).
                FileSize = total > 0 ? (long)(group.Audio.Size * duration / total) : group.Audio.Size,
                ModifiedAt = group.ModifiedAt,
                Title = cue.Title ?? $"Track {cue.Number}", Artist = artist, Album = album, AlbumArtist = albumArtist,
                Composer = cue.Songwriter ?? sheet.Songwriter, Genre = sheet.Genre ?? tags.Genre.NonEmpty(), Year = sheet.Year ?? tags.Year,
                TrackNumber = cue.Number, TrackTotal = sheet.Tracks.Count(), DiscNumber = sheet.DiscNumber ?? tags.DiscNumber,
                DiscTotal = sheet.DiscTotal ?? tags.DiscTotal, IsCompilation = tags.IsCompilation, Comment = sheet.Comment,
                MusicBrainzReleaseId = tags.MusicBrainzReleaseId, ReplayGainAlbumGain = tags.ReplayGainAlbumGain,
                Duration = duration, Format = tags.Format, SampleRate = tags.SampleRate, BitDepth = tags.BitDepth,
                Bitrate = tags.Bitrate, Channels = tags.Channels, ArtworkHash = artworkHash,
                AlbumKey = Track.MakeAlbumKey(album, albumArtist, artist, tags.IsCompilation),
                Rating = old?.Rating ?? 0, IsLoved = old?.Loved ?? false, PlayCount = old?.Plays ?? 0, SkipCount = old?.Skips ?? 0,
                LastPlayedAt = old?.LastPlayed, DateAdded = old?.DateAdded ?? DateTime.UtcNow,
                AudioPath = group.Audio.Path, StartTime = cue.Start, EndTime = next,
            };
            if (old is not null) ApplyExisting(old, track);
            tracks.Add(track);
        }
        return tracks;
    }

    private void Save(List<Track> tracks)
    {
        if (tracks.Count == 0) return;
        database.Write(db =>
        {
            foreach (var track in tracks)
            {
                if (track.Id is not null) db.Update(track);
                else db.Insert(track);
            }
        });
    }

    /// <summary>Audio files and cue sheets under a folder (hidden and system files and folders skipped).</summary>
    private static (List<FileInfoEntry> Audio, List<FileInfoEntry> Cues) EnumerateFiles(string root)
    {
        var audio = new List<FileInfoEntry>();
        var cues = new List<FileInfoEntry>();
        var options = new EnumerationOptions
        {
            RecurseSubdirectories = true,
            IgnoreInaccessible = true,
            AttributesToSkip = FileAttributes.Hidden | FileAttributes.System,
            ReturnSpecialDirectories = false,
        };
        IEnumerable<FileInfo> entries;
        try { entries = new DirectoryInfo(root).EnumerateFiles("*", options); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { return (audio, cues); }
        foreach (var info in entries)
        {
            // Dot-files are hidden on the Mac (and on drives shared with it).
            if (info.Name.StartsWith('.')) continue;
            var extension = info.Extension.TrimStart('.');
            var isCue = extension.Equals("cue", StringComparison.OrdinalIgnoreCase);
            if (!isCue && !TagReader.SupportedExtensions.Contains(extension)) continue;
            var entry = new FileInfoEntry(Path.GetFullPath(info.FullName), info.Length, info.LastWriteTimeUtc);
            (isCue ? cues : audio).Add(entry);
        }
        return (audio, cues);
    }

    /// <summary>The file a cue track's virtual path ("album.cue#03") belongs to, or null for an ordinary file.</summary>
    internal static string? CueBase(string path)
    {
        var hash = path.LastIndexOf('#');
        if (hash < 0) return null;
        var number = path[(hash + 1)..];
        return number.Length >= 2 && number.All(char.IsDigit) ? path[..hash] : null;
    }

    /// <summary>
    /// Whether a file is certainly gone. A file on a drive with read errors answers with an I/O error, not "not found":
    /// only the latter counts.
    /// </summary>
    internal static bool IsGone(string path)
    {
        try
        {
            File.GetAttributes(path);
            return false;
        }
        catch (Exception exception) when (exception is FileNotFoundException or DirectoryNotFoundException)
        {
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static bool IsReadableFolder(string path)
    {
        try
        {
            if (!Directory.Exists(path)) return false;
            using var enumerator = Directory.EnumerateFileSystemEntries(path).GetEnumerator();
            enumerator.MoveNext();
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>File identity for move detection: name (case and Unicode normalization insensitive) and size.</summary>
    internal static string Identity(string name, long size) =>
        $"{name.Normalize(NormalizationForm.FormC).ToLowerInvariant()}\u001F{size}";

    /// <summary>Keeps what lives only in the library across rescans: fixes, fetched lyrics, the chosen online cover, love date.</summary>
    private static void ApplyExisting(Existing existing, Track track)
    {
        track.MetadataOverrides = existing.Overrides;
        if (track.GetOverrides() is { } overrides) track.Apply(overrides);
        track.FetchedLyrics = existing.FetchedLyrics;
        track.LyricsCheckedAt = existing.LyricsCheckedAt;
        track.FetchedArtworkHash = existing.FetchedArtworkHash;
        track.LovedAt = existing.LovedAt;
        // A cover chosen online wins over the file's: the user picked it in the review sheet.
        if (existing.FetchedArtworkHash is { } fetched) track.ArtworkHash = fetched;
    }

    private static Track MakeTrack(long rootId, FileInfoEntry file, FileTags tags, string? artworkHash, Existing? existing)
    {
        var track = new Track
        {
            Id = existing?.Id, RootId = rootId, Path = file.Path, FileSize = file.Size, ModifiedAt = file.ModifiedAt,
            Title = tags.Title.NonEmpty() ?? Path.GetFileNameWithoutExtension(file.Path),
            Artist = tags.Artist.NonEmpty(), Album = tags.Album.NonEmpty(), AlbumArtist = tags.AlbumArtist.NonEmpty(),
            Composer = tags.Composer.NonEmpty(), Genre = tags.Genre.NonEmpty(), Year = tags.Year,
            TrackNumber = tags.TrackNumber, TrackTotal = tags.TrackTotal, DiscNumber = tags.DiscNumber, DiscTotal = tags.DiscTotal,
            IsCompilation = tags.IsCompilation, Bpm = tags.Bpm, Comment = tags.Comment, Lyrics = tags.Lyrics,
            MusicBrainzRecordingId = tags.MusicBrainzRecordingId, MusicBrainzReleaseId = tags.MusicBrainzReleaseId,
            ReplayGainTrackGain = tags.ReplayGainTrackGain, ReplayGainAlbumGain = tags.ReplayGainAlbumGain,
            Duration = tags.Duration, Format = tags.Format, SampleRate = tags.SampleRate, BitDepth = tags.BitDepth,
            Bitrate = tags.Bitrate, Channels = tags.Channels, ArtworkHash = artworkHash,
            AlbumKey = Track.MakeAlbumKey(tags.Album, tags.AlbumArtist, tags.Artist, tags.IsCompilation),
            Rating = existing?.Rating ?? 0, IsLoved = existing?.Loved ?? false, PlayCount = existing?.Plays ?? 0,
            SkipCount = existing?.Skips ?? 0, LastPlayedAt = existing?.LastPlayed, DateAdded = existing?.DateAdded ?? DateTime.UtcNow,
        };
        if (existing is not null) ApplyExisting(existing, track);
        return track;
    }
}
