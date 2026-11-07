using System.Text.Json;
using Groovelight.Core;
using Groovelight.Core.Library;
using Groovelight.Metadata;

namespace Groovelight.Model;

/// <summary>
/// File operations on the library folders (the Mac's FilesStore): Organize (rename and move files with the naming
/// template), Import (identify, tag, name songs into the library), and undoing the last of either.
/// </summary>
public sealed class FilesStore : Support.Observable
{
    public const string OptionsKey = "files.organizeOptions";
    /// <summary>The library folder imports go to (its path), set in Settings, Library.</summary>
    public const string ImportRootKey = "files.importRoot";

    private readonly AppModel model;
    private OrganizeOptions options;
    private FileOperationJournal? undoable;
    private bool isWorking;
    private ImportSession? importSession;

    public FilesStore(AppModel model)
    {
        this.model = model;
        options = SwiftJson.Decode<OrganizeOptions>(model.Preferences.Data(OptionsKey)) ?? new OrganizeOptions();
        undoable = FileOrganizer.LatestJournal(JournalsFolder)?.Journal;
    }

    public string JournalsFolder => Path.Combine(model.DataDirectory, "File Operations");

    public OrganizeOptions Options
    {
        get => options;
        set
        {
            if (!Set(ref options, value)) return;
            model.Preferences.Set(OptionsKey, JsonSerializer.SerializeToUtf8Bytes(value, SwiftJson.Options));
        }
    }

    /// <summary>The last organize or import that can be undone.</summary>
    public FileOperationJournal? Undoable { get => undoable; private set => Set(ref undoable, value); }
    public bool IsWorking { get => isWorking; private set => Set(ref isWorking, value); }

    /// <summary>The import in progress (its dialog shows it).</summary>
    public ImportSession? ImportSession { get => importSession; set => Set(ref importSession, value); }

    // MARK: Organize

    /// <summary>Planned renames for songs (or the whole library), each under its own library folder.</summary>
    public Task<List<RenamePlanItem>> PlanAsync(IReadOnlyList<Track>? tracks)
    {
        var current = options;
        return Task.Run(() =>
        {
            var (songs, roots) = model.Database.Read(db => (tracks?.ToList() ?? db.AllTracks(), db.Roots()));
            return roots.SelectMany(root => RenamePlanner.Plan(songs.Where(track => track.RootId == root.Id).ToList(), root.Path, current)).ToList();
        });
    }

    public async Task ApplyAsync(IReadOnlyList<RenamePlanItem> plan)
    {
        if (IsWorking) return;
        IsWorking = true;
        try
        {
            var journal = await Task.Run(() => FileOrganizer.Apply(plan, model.Database));
            FileOrganizer.Save(journal, JournalsFolder);
            Undoable = journal;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or Microsoft.Data.Sqlite.SqliteException)
        {
            model.ErrorMessage = $"Could not rename the files (nothing was changed): {error.Message}";
        }
        finally
        {
            IsWorking = false;
        }
    }

    // MARK: Undo

    public string UndoTitle => Undoable?.Kind switch
    {
        FileOperationJournal.JournalKind.Import => "Undo Import",
        FileOperationJournal.JournalKind.Organize => "Undo Organize Files",
        _ => "Undo Last File Operation",
    };

    public async Task UndoLastAsync()
    {
        if (FileOrganizer.LatestJournal(JournalsFolder) is not { } latest || IsWorking) return;
        IsWorking = true;
        try
        {
            await Task.Run(() => FileOrganizer.Undo(latest.Journal, model.Database));
            File.Delete(latest.Path);
            Undoable = FileOrganizer.LatestJournal(JournalsFolder)?.Journal;
            await model.RescanAndWaitAsync();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or Microsoft.Data.Sqlite.SqliteException)
        {
            model.ErrorMessage = $"Could not undo: {error.Message}";
        }
        finally
        {
            IsWorking = false;
        }
    }

    // MARK: Import

    /// <summary>
    /// Imports songs, folders, cue sheets or archives of them (chosen or dropped on the window). Playlist files among
    /// them become playlists.
    /// </summary>
    public void ImportItems(IReadOnlyList<string> paths, bool interactive = true)
    {
        var playlists = paths.Where(PlaylistTransfer.IsPlaylistFile).ToList();
        if (playlists.Count > 0) model.PlaylistFiles.ImportFiles(playlists);
        var items = paths.Where(path => !PlaylistTransfer.IsPlaylistFile(path)).ToList();
        if (items.Count == 0 || ImportSession is not null) return;
        if (model.Database.Read(db => db.Roots()).Count == 0)
        {
            model.ErrorMessage = "Add a library folder first (Settings, Library): imported songs are moved there.";
            return;
        }
        var session = new ImportSession(items, model, this) { IsInteractive = interactive };
        ImportSession = session;
        _ = session.AnalyzeAsync();
    }

    public void FinishImport(FileOperationJournal journal)
    {
        FileOrganizer.Save(journal, JournalsFolder);
        Undoable = journal;
    }
}

/// <summary>One import: the chosen files, what was found for them, and where they will go (the Mac's ImportSession).</summary>
public sealed class ImportSession : Support.Observable
{
    public abstract record ImportPhase
    {
        public sealed record Extracting(string Name, int Done, int Total) : ImportPhase;
        public sealed record Reading(int Done, int Total) : ImportPhase;
        public sealed record Identifying(int Done, int Total) : ImportPhase;
        public sealed record Review : ImportPhase;
        public sealed record Importing(int Done, int Total) : ImportPhase;
        public sealed record Finished(int Imported, int Skipped, int Failed) : ImportPhase;
    }

    public const string DeleteArchivesKey = "files.import.trashArchives";

    public sealed class Item
    {
        public required long Id { get; init; }
        public required string Source { get; init; }
        public required FileTags Tags { get; init; }
        /// <summary>From the file's own tags.</summary>
        public required TrackMetadata FileMetadata { get; init; }
        /// <summary>From the MusicBrainz match, when the album was identified.</summary>
        public TrackMetadata? OnlineMetadata { get; set; }
        public bool HasArtwork { get; init; }
        public bool IsDuplicate { get; init; }
        public bool Include { get; set; }
        /// <summary>An album in one audio file with a cue sheet: imported as a unit, keeping the file names.</summary>
        public CueAlbum? Cue { get; init; }
    }

    /// <summary><paramref name="Sheet"/>: the external sheet (null when it is embedded in the audio file).</summary>
    public sealed record CueAlbum(string? Sheet, int Songs);

    public sealed class Group
    {
        public required string Id { get; init; }
        public string Title { get; set; } = "";
        public string Artist { get; set; } = "";
        /// <summary>"OK Computer (1997)" when matched on MusicBrainz.</summary>
        public string? MatchedRelease { get; set; }
        public byte[]? Cover { get; set; }
        public List<Item> Items { get; init; } = [];
    }

    private ImportPhase phase = new ImportPhase.Reading(0, 0);
    public ImportPhase Phase { get => phase; private set => Set(ref phase, value); }
    public List<Group> Groups { get; private set; } = [];
    public bool MoveFiles { get; set; } = true;
    public bool UseOnlineMetadata { get; set; } = true;
    public bool WriteTags { get; set; } = true;
    public long? RootId { get; set; }
    public List<LibraryRoot> Roots { get; private set; } = [];
    /// <summary>Off for imports from the command line: no alerts, and their options are not remembered.</summary>
    public bool IsInteractive { get; init; } = true;
    /// <summary>Archives that could not be extracted (or only in part).</summary>
    public List<string> Problems { get; private set; } = [];
    public int TrashedArchives { get; private set; }

    private bool deleteArchives;
    /// <summary>Moves each archive to the Recycle Bin once everything from it is imported (remembered).</summary>
    public bool DeleteArchives
    {
        get => deleteArchives;
        set
        {
            deleteArchives = value;
            if (IsInteractive) model.Preferences.Set(DeleteArchivesKey, value);
        }
    }

    private readonly List<string> paths;
    /// <summary>Archives among the chosen items, extracted into the staging folder before reading.</summary>
    public IReadOnlyList<string> Archives { get; }
    /// <summary>Whether only archives were chosen (their songs are always moved out of the temporary folder).</summary>
    public bool OnlyArchives { get; }
    private readonly List<(string Archive, string Folder)> extracted = [];
    private readonly string staging;
    private readonly AppModel model;
    private readonly FilesStore store;
    private readonly Dictionary<string, byte[]> firstArtwork = [];

    public ImportSession(IReadOnlyList<string> chosen, AppModel model, FilesStore store)
    {
        paths = chosen.Where(path => !ArchiveExtractor.IsArchive(path)).ToList();
        Archives = chosen.Where(ArchiveExtractor.IsArchive).ToList();
        OnlyArchives = Archives.Count == chosen.Count;
        staging = Path.Combine(Path.GetTempPath(), $"Groovelight Import {Guid.NewGuid():N}");
        this.model = model;
        this.store = store;
        deleteArchives = model.Preferences.Bool(DeleteArchivesKey);
    }

    public int IncludedCount => Groups.Sum(group => group.Items.Count(item => item.Include));
    public int DuplicateCount => Groups.Sum(group => group.Items.Count(item => item.IsDuplicate));

    /// <summary>Where a file comes from, for people: its path, or the archive and its path inside it.</summary>
    public string SourceDescription(string path)
    {
        foreach (var (archive, folder) in extracted)
        {
            if (path.StartsWith(folder + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                return archive + ": " + path[(folder.Length + 1)..];
        }
        return path;
    }

    private string? ArchiveOf(string path) =>
        extracted.FirstOrDefault(entry => path.StartsWith(entry.Folder + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)).Archive;

    public TrackMetadata MetadataOf(Item item) =>
        UseOnlineMetadata && item.OnlineMetadata is { } online ? item.FileMetadata.Merging(online) : item.FileMetadata;

    /// <summary>Where each included item will go, with " (2)" when the name is taken.</summary>
    public Dictionary<long, string> Destinations()
    {
        var result = new Dictionary<long, string>();
        if (Roots.FirstOrDefault(root => root.Id == RootId) is not { } root) return result;
        var naming = store.Options with { OrganizeFolders = true };
        var taken = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var item in Groups.SelectMany(group => group.Items).Where(item => item.Include))
        {
            var metadata = MetadataOf(item);
            var extension = Path.GetExtension(item.Source).TrimStart('.');
            if (item.Cue is not null)
            {
                // The album folder from the template, with the audio file's own name (the sheet refers to it).
                var fields = new NamingFields("", metadata.Artist, metadata.Album, metadata.AlbumArtist, metadata.Genre, metadata.Year, 1,
                                              metadata.DiscNumber, metadata.DiscTotal);
                var folder = Path.GetDirectoryName(Path.Combine(root.Path, FileNaming.RelativePath(fields, extension, naming)))!;
                var destination = Path.GetFullPath(Path.Combine(folder, Path.GetFileName(item.Source)));
                taken.Add(destination);
                result[item.Id] = destination;
                continue;
            }
            var named = new NamingFields(metadata.Title ?? Path.GetFileNameWithoutExtension(item.Source), metadata.Artist, metadata.Album,
                                         metadata.AlbumArtist, metadata.Genre, metadata.Year, metadata.TrackNumber, metadata.DiscNumber,
                                         metadata.DiscTotal, metadata.IsCompilation ?? false);
            var relative = FileNaming.RelativePath(named, extension, naming);
            var path = Path.GetFullPath(Path.Combine(root.Path, relative));
            for (var counter = 2; taken.Contains(path) || File.Exists(path); counter++)
            {
                var name = Path.GetFileNameWithoutExtension(relative);
                path = Path.GetFullPath(Path.Combine(root.Path, Path.GetDirectoryName(relative) ?? "", $"{name} ({counter}).{extension}"));
            }
            taken.Add(path);
            result[item.Id] = path;
        }
        return result;
    }

    // MARK: Analysis

    public async Task AnalyzeAsync()
    {
        var database = model.Database;
        Roots = await Task.Run(() => database.Read(db => db.Roots()));
        var preferred = model.Preferences.String(FilesStore.ImportRootKey);
        RootId = (Roots.FirstOrDefault(root => string.Equals(root.Path, preferred, StringComparison.OrdinalIgnoreCase)) ?? Roots.FirstOrDefault())?.Id;
        var problems = new List<string>();
        for (var index = 0; index < Archives.Count; index++)
        {
            var archive = Archives[index];
            Phase = new ImportPhase.Extracting(Path.GetFileName(archive), index, Archives.Count);
            var folder = Path.Combine(staging, $"{index + 1}");
            try
            {
                await Task.Run(() => ArchiveExtractor.Extract(archive, folder));
                extracted.Add((archive, folder));
            }
            catch (ArchiveExtractor.ExtractException error)
            {
                // What did come out is still offered, but the archive is never moved to the Recycle Bin.
                problems.Add(error.Message);
            }
            paths.Add(folder);
        }
        Problems = problems;
        if (problems.Count > 0 && IsInteractive) model.ErrorMessage = string.Join("\n", problems);
        var chosen = paths.ToList();
        var (files, cueFiles) = await Task.Run(() => AudioFiles(chosen));
        Phase = new ImportPhase.Reading(0, files.Count);
        var library = await Task.Run(() => database.Read(db => db.AllTracks()));

        // Cue sheets beside the chosen audio: a FILE with two or more tracks makes that file an album.
        var audioPaths = new HashSet<string>(files, StringComparer.OrdinalIgnoreCase);
        var sheets = new Dictionary<string, (string Path, CueSheet Sheet, int Songs)>(StringComparer.OrdinalIgnoreCase);
        foreach (var path in cueFiles)
        {
            if (CueSheet.Read(path) is not { } sheet) continue;
            foreach (var file in sheet.Files.Where(file => file.Tracks.Count >= 2))
            {
                if (CueSheet.Resolve(file.Name, Path.GetDirectoryName(path)!, audioPaths) is { } audio && !sheets.ContainsKey(audio))
                    sheets[audio] = (path, sheet, file.Tracks.Count);
            }
        }

        var items = new List<Item>();
        for (var index = 0; index < files.Count; index++)
        {
            var path = files[index];
            var tags = await Task.Run(() =>
            {
                try { return TagReader.Read(path); }
                catch (Exception error) when (error is not OutOfMemoryException) { return null; }
            });
            if (tags is not null)
            {
                var candidate = TrackCandidates.Candidate(-(index + 1), path, tags);
                CueAlbum? cue = null;
                var embedded = tags.CueSheet is { } text && CueSheet.Parse(text) is { } parsed && parsed.Files.FirstOrDefault() is { } first ? (parsed, first.Tracks.Count) : ((CueSheet, int)?)null;
                if (sheets.TryGetValue(path, out var external))
                {
                    cue = new CueAlbum(external.Path, external.Songs);
                    Describe(candidate, external.Sheet, external.Songs);
                }
                else if (embedded is var (sheet, songs) && songs >= 2)
                {
                    cue = new CueAlbum(null, songs);
                    Describe(candidate, sheet, songs);
                }
                var isDuplicate = cue is null ? IsInLibrary(candidate, library)
                    : library.Any(track => track.IsCueTrack && string.Equals(track.DisplayAlbum, candidate.DisplayAlbum, StringComparison.OrdinalIgnoreCase)
                                           && string.Equals(track.DisplayAlbumArtist, candidate.DisplayAlbumArtist, StringComparison.OrdinalIgnoreCase));
                var withoutArtwork = tags with { Artwork = null };
                items.Add(new Item
                {
                    Id = candidate.Id!.Value, Source = path, Tags = withoutArtwork, FileMetadata = candidate.Metadata(), HasArtwork = tags.Artwork is not null,
                    IsDuplicate = isDuplicate, Include = !isDuplicate, Cue = cue,
                });
                if (tags.Artwork is { } artwork && GroupKey(candidate) is { } key && !firstArtwork.ContainsKey(key)) firstArtwork[key] = artwork;
            }
            Phase = new ImportPhase.Reading(index + 1, files.Count);
        }

        // Group by album (tags), or by folder for untagged files.
        var grouped = new Dictionary<string, List<Item>>();
        var order = new List<string>();
        foreach (var item in items)
        {
            var key = GroupKey(TrackCandidates.Candidate(item.Id, item.Source, item.Tags)) ?? Path.GetDirectoryName(item.Source) ?? "";
            if (!grouped.ContainsKey(key)) { order.Add(key); grouped[key] = []; }
            grouped[key].Add(item);
        }
        Groups = order.Select(key =>
        {
            var members = grouped[key];
            var first = members[0].FileMetadata;
            return new Group
            {
                Id = key, Title = first.Album ?? Path.GetFileName(Path.GetDirectoryName(members[0].Source)) ?? "",
                Artist = first.AlbumArtist ?? first.Artist ?? "Unknown Artist", Cover = firstArtwork.GetValueOrDefault(key), Items = members,
            };
        }).ToList();

        // Identify each album online (confident matches only), with a cover when the files have none.
        if (model.Preferences.Bool(MetadataStore.FetchAlbumInfoKey))
        {
            var service = model.Metadata.Service;
            for (var index = 0; index < Groups.Count; index++)
            {
                Phase = new ImportPhase.Identifying(index, Groups.Count);
                var group = Groups[index];
                // Cue albums are described by their sheet: not identified online.
                var candidates = group.Items.Where(item => !item.IsDuplicate && item.Cue is null)
                    .Select(item => TrackCandidates.Candidate(item.Id, item.Source, item.Tags)).ToList();
                if (candidates.Count == 0) continue;
                if (await IdentifyAsync(candidates, service) is not var (match, proposal)) continue;
                foreach (var item in group.Items) item.OnlineMetadata = proposal.GetValueOrDefault(item.Id);
                group.MatchedRelease = match.Release.Title + (match.Release.Year is { } year ? $" ({year})" : "");
                group.Title = match.Release.Title;
                group.Artist = match.Release.ArtistName;
                if (group.Cover is null && await service.CoverAsync(match.Release, match.Release.Title, match.Release.ArtistName) is { } cover)
                    group.Cover = cover.Data;
            }
        }
        Phase = new ImportPhase.Review();
    }

    private static async Task<(ReleaseMatch, Dictionary<long, TrackMetadata>)?> IdentifyAsync(List<Track> tracks, MetadataService service)
    {
        try
        {
            foreach (var release in (await service.CandidatesAsync(tracks)).Take(2))
            {
                var match = await service.MatchAsync(tracks, release.Id);
                if (MetadataService.IsConfident(match, tracks.Count)) return (match, ReleaseMatcher.Proposal(match));
            }
        }
        catch (Exception error) when (MetadataStore.IsOffline(error))
        {
        }
        return null;
    }

    /// <summary>Audio files and cue sheets among the chosen files and folders (and, for chosen files, the sheets beside them).</summary>
    private static (List<string> Audio, List<string> Cues) AudioFiles(IReadOnlyList<string> chosen)
    {
        var extensions = TagReader.SupportedExtensions;
        bool IsAudio(string path) => extensions.Contains(Path.GetExtension(path).TrimStart('.'));
        bool IsCue(string path) => Path.GetExtension(path).Equals(".cue", StringComparison.OrdinalIgnoreCase);
        var files = new List<string>();
        var cues = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var path in chosen)
        {
            if (Directory.Exists(path))
            {
                foreach (var file in Directory.EnumerateFiles(path, "*", new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = FileAttributes.Hidden | FileAttributes.System, IgnoreInaccessible = true }))
                {
                    if (IsAudio(file)) files.Add(Path.GetFullPath(file));
                    else if (IsCue(file)) cues.Add(Path.GetFullPath(file));
                }
            }
            else if (File.Exists(path) && IsAudio(path))
            {
                files.Add(Path.GetFullPath(path));
                foreach (var sibling in Directory.EnumerateFiles(Path.GetDirectoryName(Path.GetFullPath(path))!).Where(IsCue)) cues.Add(sibling);
            }
            else if (File.Exists(path) && IsCue(path) && CueSheet.Read(path) is { } sheet)
            {
                // A sheet chosen on its own brings the audio it describes.
                var folder = Path.GetDirectoryName(Path.GetFullPath(path))!;
                var audio = new HashSet<string>(Directory.EnumerateFiles(folder).Where(IsAudio).Select(Path.GetFullPath), StringComparer.OrdinalIgnoreCase);
                foreach (var file in sheet.Files)
                {
                    if (CueSheet.Resolve(file.Name, folder, audio) is { } match) files.Add(match);
                }
                cues.Add(Path.GetFullPath(path));
            }
        }
        var comparer = StringComparer.Create(System.Globalization.CultureInfo.CurrentCulture, System.Globalization.CompareOptions.NumericOrdering | System.Globalization.CompareOptions.IgnoreCase);
        return (files.Distinct(StringComparer.OrdinalIgnoreCase).Order(comparer).ToList(), cues.Order(StringComparer.Ordinal).ToList());
    }

    /// <summary>A cue album's audio file as the import shows it: the sheet's album and performer.</summary>
    private static void Describe(Track candidate, CueSheet sheet, int songs)
    {
        candidate.Title = $"{songs} songs";
        candidate.Album = sheet.Title ?? candidate.Album;
        candidate.AlbumArtist = sheet.Performer ?? candidate.AlbumArtist;
        candidate.Artist = sheet.Performer ?? candidate.Artist;
        candidate.Year = sheet.Year ?? candidate.Year;
        candidate.Genre = sheet.Genre ?? candidate.Genre;
        candidate.TrackNumber = null;
        candidate.AlbumKey = Track.MakeAlbumKey(candidate.Album, candidate.AlbumArtist, candidate.Artist, false);
    }

    private static string? GroupKey(Track track) => string.IsNullOrEmpty(track.Album) ? null : track.AlbumKey;

    /// <summary>Same song already in the library: same MusicBrainz recording, or same title, artist, album and length.</summary>
    private static bool IsInLibrary(Track candidate, IReadOnlyList<Track> library) => library.Any(track =>
    {
        if (candidate.MusicBrainzRecordingId is { } recording && recording == track.MusicBrainzRecordingId
            && candidate.MusicBrainzReleaseId == track.MusicBrainzReleaseId) return true;
        return string.Equals(track.Title, candidate.Title, StringComparison.OrdinalIgnoreCase)
               && string.Equals(track.DisplayArtist, candidate.DisplayArtist, StringComparison.OrdinalIgnoreCase)
               && string.Equals(track.DisplayAlbum, candidate.DisplayAlbum, StringComparison.OrdinalIgnoreCase)
               && Math.Abs(track.Duration - candidate.Duration) < 2;
    });

    // MARK: Importing

    public async Task RunAsync()
    {
        var destinations = Destinations();
        var selected = Groups.SelectMany(group => group.Items.Where(item => item.Include).Select(item => (group, item))).ToList();
        if (selected.Count == 0) return;
        Phase = new ImportPhase.Importing(0, selected.Count);
        var entries = new List<FileOperationJournal.Entry>();
        var created = new List<string>();
        var failed = 0;
        // Archives with a song that could not be imported stay where they are; so do those nothing was imported from.
        var incomplete = new HashSet<string>();
        var importedFrom = new HashSet<string>();
        for (var index = 0; index < selected.Count; index++)
        {
            var (group, item) = selected[index];
            if (!destinations.TryGetValue(item.Id, out var destination)) continue;
            // Songs from an archive are moved out of the temporary folder; undo removes them (the archive has them).
            var fromArchive = ArchiveOf(item.Source);
            var move = MoveFiles || fromArchive is not null;
            var copied = !MoveFiles || fromArchive is not null;
            var metadata = MetadataOf(item);
            var cover = item.HasArtwork ? null : group.Cover;
            // A cue album's file holds every song: its tags are left alone.
            var write = WriteTags && item.Cue is null;
            var sheet = item.Cue?.Sheet;
            var sheetDestination = sheet is null ? null : Path.Combine(Path.GetDirectoryName(destination)!, Path.GetFileName(sheet));
            var (ok, folders) = await Task.Run(() =>
            {
                var createdFolders = new List<string>();
                try
                {
                    var missing = new List<string>();
                    for (var folder = Path.GetDirectoryName(destination); folder is not null && !Directory.Exists(folder); folder = Path.GetDirectoryName(folder))
                        missing.Add(folder);
                    missing.Reverse();
                    foreach (var folder in missing)
                    {
                        Directory.CreateDirectory(folder);
                        createdFolders.Add(folder);
                    }
                    // The sheet first: if its name is taken the album is not imported.
                    if (sheet is not null && sheetDestination is not null)
                    {
                        if (move) File.Move(sheet, sheetDestination); else File.Copy(sheet, sheetDestination);
                    }
                    try
                    {
                        if (move) File.Move(item.Source, destination); else File.Copy(item.Source, destination);
                    }
                    catch
                    {
                        if (sheet is not null && sheetDestination is not null)
                        {
                            try { if (move) File.Move(sheetDestination, sheet); else File.Delete(sheetDestination); }
                            catch (IOException) { }
                        }
                        throw;
                    }
                    // Tags and cover into the file now in the library (the source is left as it was when copying).
                    if (write)
                    {
                        try { TagWriter.Write(metadata, destination, frontCover: cover); }
                        catch (Exception error) when (error is not OutOfMemoryException) { }
                    }
                    return (true, createdFolders);
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                {
                    return (false, createdFolders);
                }
            });
            created.AddRange(folders);
            if (ok)
            {
                if (sheet is not null && sheetDestination is not null) entries.Add(new FileOperationJournal.Entry(null, sheet, sheetDestination, copied));
                entries.Add(new FileOperationJournal.Entry(null, item.Source, destination, copied));
                if (fromArchive is not null) importedFrom.Add(fromArchive);
            }
            else
            {
                failed++;
                if (fromArchive is not null) incomplete.Add(fromArchive);
            }
            Phase = new ImportPhase.Importing(index + 1, selected.Count);
        }

        // Scan so the songs join the library, then record their ids for undo.
        await model.RescanAndWaitAsync();
        var paths = entries.Select(entry => entry.To).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var library = await Task.Run(() => model.Database.Read(db => db.AllTracks()));
        var ids = library.Where(track => paths.Contains(track.Path)).GroupBy(track => track.Path, StringComparer.OrdinalIgnoreCase)
                         .ToDictionary(group => group.Key, group => group.First().Id, StringComparer.OrdinalIgnoreCase);
        entries = entries.Select(entry => entry with { TrackId = ids.GetValueOrDefault(entry.To) }).ToList();

        // Credits, backgrounds, missing covers and lyrics for what came in, in the background.
        var cuePaths = entries.Where(entry => entry.TrackId is null).Select(entry => entry.To).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var cueIds = library.Where(track => track.AudioPath is { } audio && cuePaths.Contains(audio)).Select(track => track.Id).OfType<long>();
        var importedIds = entries.Select(entry => entry.TrackId).OfType<long>().Concat(cueIds).ToHashSet();
        if (importedIds.Count > 0) model.Metadata.FetchMissingInfo(trackIds: importedIds);
        // Archives last, once their songs are in: to the Recycle Bin (not deleted), so they can come back.
        var trashed = new List<FileOperationJournal.Entry>();
        if (DeleteArchives)
        {
            foreach (var (archive, _) in extracted.Where(entry => importedFrom.Contains(entry.Archive) && !incomplete.Contains(entry.Archive)))
            {
                if (FileOrganizer.RecycleBin.Recycle(archive) is { } kept) trashed.Add(new FileOperationJournal.Entry(null, archive, kept, false));
            }
        }
        TrashedArchives = trashed.Count;
        CleanUp();
        store.FinishImport(new FileOperationJournal
        {
            Kind = FileOperationJournal.JournalKind.Import, Entries = entries, CreatedFolders = created, Trashed = trashed.Count > 0 ? trashed : null,
        });
        Phase = new ImportPhase.Finished(entries.Count(entry => !entry.To.EndsWith(".cue", StringComparison.OrdinalIgnoreCase)),
                                         Groups.Sum(group => group.Items.Count(item => !item.Include)), failed);
    }

    /// <summary>Removes the folder archives were extracted into.</summary>
    public void CleanUp()
    {
        try { if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
}
