using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Groovelight.Audio;
using Groovelight.ControlKit;
using Groovelight.Core.Library;
using Groovelight.Metadata;
using OrganizeOptions = Groovelight.ControlKit.OrganizeOptions;

namespace Groovelight.Model;

/// <summary>
/// Does what the command line tool asks (see Groovelight.ControlKit; the Mac's ControlService): library questions and
/// playback are answered at once; imports, fixes and file operations run as jobs the tool polls for progress.
/// Everything goes through the same code as the window, so the library, undo and the window stay in step.
/// </summary>
public sealed class ControlService
{
    private readonly AppModel model;
    private readonly Dictionary<string, Job> jobs = [];
    private ControlServer? server;
    private int nextJob = 1;

    public ControlService(AppModel model) => this.model = model;

    /// <summary>Whether this copy of the app answers the command line (false when another copy took the pipe).</summary>
    public bool IsListening => server is not null;

    public void Start()
    {
        var data = Support.DebugOptions.DataDirectory ?? Environment.GetEnvironmentVariable("GROOVELIGHT_DATA") ?? "";
        var candidate = new ControlServer(OnMainAsync);
        if (candidate.Start(ControlPipe.Name(data))) server = candidate;
        else System.Diagnostics.Debug.WriteLine("Groovelight: the command line pipe is in use (another copy of the app is running)");
    }

    public void Stop()
    {
        server?.Dispose();
        server = null;
    }

    /// <summary>Requests arrive on the pipe's threads; the model lives on the UI thread.</summary>
    private Task<ControlReply> OnMainAsync(ControlRequest request)
    {
        var done = new TaskCompletionSource<ControlReply>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!model.Queue.TryEnqueue(() =>
            {
                try
                {
                    done.SetResult(Handle(request));
                }
                catch (Exception error)
                {
                    done.SetResult(ControlReply.Failure(error.Message));
                }
            }))
            done.SetResult(ControlReply.Failure("Groovelight is quitting."));
        return done.Task;
    }

    // MARK: Requests

    public ControlReply Handle(ControlRequest request)
    {
        try
        {
            return request switch
            {
                StatusRequest => Status(),
                SearchRequest search => Search(search.Query, search.Limit),
                ImportRequest import => StartJob(job => ImportAsync(import.Options, job)),
                FixMetadataRequest fix => StartJob(job => FixMetadataAsync(fix.Options, job)),
                OrganizeRequest organize => StartJob(job => OrganizeAsync(organize.Options, job)),
                UndoRequest => StartJob(_ => UndoAsync()),
                RescanRequest => StartJob(RescanAsync),
                PlayRequest play => Play(play.Options),
                PlaybackRequest playback => Playback(playback.Action),
                ListPlaylistsRequest => ListPlaylists(),
                CreatePlaylistRequest create => CreatePlaylist(create.Name, create.SongIds),
                AddToPlaylistRequest add => AddToPlaylist(add.Playlist, add.SongIds),
                NowPlayingRequest => NowPlaying(),
                PollRequest poll => Poll(poll.Job),
                CancelRequest cancel => Cancel(cancel.Job),
                _ => ControlReply.Failure("Groovelight does not know this request. Update the app and the tool together."),
            };
        }
        catch (ControlException error)
        {
            return ControlReply.Failure(error.Message);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or Microsoft.Data.Sqlite.SqliteException)
        {
            return ControlReply.Failure(error.Message);
        }
    }

    // MARK: Jobs

    private sealed class Job(string id)
    {
        public string Id { get; } = id;
        public List<string> Messages { get; } = [];
        public JobProgress? Progress { get; set; }
        public ControlReply? Result { get; set; }
        public CancellationTokenSource Cancellation { get; } = new();

        public void Report(string label, int done = 0, int total = 0) => Progress = new JobProgress(label, done, total);
    }

    /// <summary>One job at a time: they move files and write tags.</summary>
    private ControlReply StartJob(Func<Job, Task<ControlReply>> work)
    {
        if (jobs.Values.FirstOrDefault(job => job.Result is null) is { } busy)
            return ControlReply.Failure($"Groovelight is busy with another command (job {busy.Id}). Try again when it is done.");
        // Results nobody came back for.
        jobs.Clear();
        var job = new Job((nextJob++).ToString(CultureInfo.InvariantCulture));
        jobs[job.Id] = job;
        Run();
        return new ControlReply { Job = job.Id, Finished = false };

        async void Run()
        {
            try
            {
                job.Result = await work(job);
            }
            catch (OperationCanceledException)
            {
                job.Result = ControlReply.Failure("Cancelled.");
            }
            catch (Exception error) when (error is ControlException or IOException or UnauthorizedAccessException or HttpRequestException
                                          or Microsoft.Data.Sqlite.SqliteException or InvalidOperationException or JsonException)
            {
                job.Result = ControlReply.Failure(error.Message);
            }
        }
    }

    private ControlReply Poll(string id)
    {
        if (!jobs.TryGetValue(id, out var job)) return ControlReply.Failure($"There is no job {id}.");
        var messages = job.Messages.ToList();
        job.Messages.Clear();
        if (job.Result is not { } result) return new ControlReply { Job = id, Finished = false, Messages = messages, Progress = job.Progress };
        jobs.Remove(id);
        return result with { Job = id, Finished = true, Messages = [.. messages, .. result.Messages] };
    }

    private ControlReply Cancel(string id)
    {
        if (jobs.TryGetValue(id, out var job)) job.Cancellation.Cancel();
        return new ControlReply { Summary = $"Cancelling job {id}." };
    }

    // MARK: Library

    private static JsonNode? Node<T>(T value) => JsonSerializer.SerializeToNode(value, ControlPipe.Json);

    private ControlReply Status()
    {
        var (songs, albums, artists, roots, counts) = model.Database.Read(db =>
            (db.Scalar<int>("SELECT COUNT(*) FROM track"), db.Albums().Count, db.Artists().Count, db.Roots(), db.TrackCountsByRoot()));
        var importRoot = ImportRoot(roots);
        var folders = roots.Select(root => new FolderResult(root.Path, root.Id is { } id ? counts.GetValueOrDefault(id) : 0,
            !model.UnavailableFolders.Contains(root.Path), root.Id == importRoot?.Id)).ToList();
        var status = new StatusResult(model.Updates.CurrentVersion, songs, albums, artists, folders, CurrentSong());
        var lines = new List<string> { $"Groovelight {status.Version}: {Count(songs, "song")}, {Count(albums, "album")}, {Count(artists, "artist")}" };
        lines.AddRange(folders.Select(folder => $"  {folder.Path} ({Count(folder.Songs, "song")}{(folder.Available ? "" : ", not available")}{(folder.ImportsHere ? ", imports go here" : "")})"));
        if (status.NowPlaying is { } playing) lines.Add($"{Capitalized(playing.State)}: {playing.Title} by {playing.Artist}");
        return new ControlReply { Summary = string.Join('\n', lines), Data = Node(status) };
    }

    private ControlReply Search(string query, int limit)
    {
        limit = Math.Clamp(limit, 1, 200);
        var results = model.Database.Read(db => db.Search(query, limit));
        var found = new SearchResult(results.Artists.Take(limit).Select(artist => artist.DisplayName).ToList(),
            results.Albums.Take(limit).Select(AlbumResult.Of).ToList(), results.Songs.Take(limit).Select(SongResult.Of).ToList());
        var lines = new List<string>();
        if (found.Artists.Count > 0) lines.Add("Artists: " + string.Join(", ", found.Artists));
        if (found.Albums.Count > 0)
        {
            lines.Add("Albums:");
            lines.AddRange(found.Albums.Select(album => "  " + album.Description));
        }
        if (found.Songs.Count > 0)
        {
            lines.Add("Songs:");
            lines.AddRange(found.Songs.Select(song => "  " + song.Description));
        }
        return new ControlReply { Summary = lines.Count == 0 ? $"Nothing found for “{query}”." : string.Join('\n', lines), Data = Node(found) };
    }

    // MARK: Import

    private async Task<ControlReply> ImportAsync(ImportOptions options, Job job)
    {
        ImportPaths.Check(options.Paths);
        var missing = options.Paths.FirstOrDefault(path => !File.Exists(path) && !Directory.Exists(path));
        if (missing is not null) throw new ControlException($"No such file or folder: {missing}");
        var roots = await Task.Run(() => model.Database.Read(db => db.Roots()));
        if (roots.Count == 0) throw new ControlException("Add a library folder first (Settings, Library): imported songs go there.");
        var root = ImportRoot(roots);
        if (options.Folder is { } folder)
            root = Pick(roots, folder, "library folder", item => Path.GetFileName(item.Path.TrimEnd('\\', '/')), item => item.Path,
                item => string.Equals(Path.GetFullPath(item.Path), SafeFullPath(folder), StringComparison.OrdinalIgnoreCase));

        var session = new ImportSession(options.Paths, model, model.Files)
        {
            IsInteractive = false, DeleteArchives = options.TrashArchives, MoveFiles = !options.Copy, UseOnlineMetadata = options.UseOnlineMetadata,
            WriteTags = options.WriteTags,
        };
        void Watch(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
        {
            if (args.PropertyName == nameof(ImportSession.Phase) && Describe(session.Phase) is var (label, done, total)) job.Report(label, done, total);
        }
        session.PropertyChanged += Watch;
        try
        {
            await session.AnalyzeAsync();
            job.Messages.AddRange(session.Problems);
            session.RootId = root?.Id;
            var destinations = session.Destinations();
            var albums = session.Groups.Select(group => new ImportAlbumResult(group.Title, group.Artist, session.UseOnlineMetadata ? group.MatchedRelease : null,
                group.Items.Select(item => new ImportSongResult(session.SourceDescription(item.Source), destinations.GetValueOrDefault(item.Id), item.IsDuplicate)).ToList())).ToList();
            var folderPath = root?.Path ?? "";
            List<string> PlanLines() => albums.SelectMany(album =>
                new[] { $"{album.Album} by {album.Artist}{(album.MatchedRelease is { } release ? $" (matched {release})" : " (file tags)")}" }
                    .Concat(album.Songs.Select(song => "  " + (song.Destination is { } destination ? Relative(destination, folderPath) : $"already in your library: {song.Source}"))))
                .ToList();
            if (session.IncludedCount == 0)
            {
                var reason = session.Groups.Count == 0 ? $"No songs found in {string.Join(", ", options.Paths)}." : "Every song is already in your library.";
                session.CleanUp();
                return new ControlReply { Summary = string.Join('\n', PlanLines().Prepend(reason)), Data = Node(new ImportResult(options.DryRun, folderPath, albums)) };
            }
            if (options.DryRun)
            {
                session.CleanUp();
                return new ControlReply
                {
                    Summary = string.Join('\n', PlanLines().Prepend($"Would import {session.IncludedCount} songs into {folderPath}:")),
                    Data = Node(new ImportResult(true, folderPath, albums)),
                };
            }
            await session.RunAsync();
            if (session.Phase is not ImportSession.ImportPhase.Finished(var imported, var skipped, var failed)) throw new ControlException("The import stopped.");
            var result = new ImportResult(false, folderPath, albums) { Imported = imported, Skipped = skipped, Failed = failed, TrashedArchives = session.TrashedArchives };
            var lines = new List<string> { $"Imported {imported} songs into {folderPath}." };
            if (skipped > 0) lines.Add($"{skipped} left out (already in your library).");
            if (failed > 0) lines.Add($"{failed} could not be imported.");
            if (session.TrashedArchives > 0)
                lines.Add(session.TrashedArchives == 1 ? "The archive was moved to the Recycle Bin." : $"{session.TrashedArchives} archives were moved to the Recycle Bin.");
            lines.Add("Undo with: groovelight undo");
            return new ControlReply { Summary = string.Join('\n', lines.Concat(PlanLines())), Data = Node(result) };
        }
        finally
        {
            session.PropertyChanged -= Watch;
        }
    }

    private static (string, int, int)? Describe(ImportSession.ImportPhase phase) => phase switch
    {
        ImportSession.ImportPhase.Extracting(var name, var done, var total) => ($"Extracting {name}", done, total),
        ImportSession.ImportPhase.Reading(var done, var total) => ("Reading files", done, total),
        ImportSession.ImportPhase.Identifying(var done, var total) => ("Identifying albums on MusicBrainz", done, total),
        ImportSession.ImportPhase.Importing(var done, var total) => ("Importing songs", done, total),
        _ => null,
    };

    private LibraryRoot? ImportRoot(IReadOnlyList<LibraryRoot> roots)
    {
        var preferred = model.Preferences.String(FilesStore.ImportRootKey);
        return roots.FirstOrDefault(root => string.Equals(root.Path, preferred, StringComparison.OrdinalIgnoreCase)) ?? roots.FirstOrDefault();
    }

    private static string Relative(string path, string folder) =>
        folder.Length > 0 && path.StartsWith(folder, StringComparison.OrdinalIgnoreCase) ? path[folder.Length..].TrimStart('\\', '/') : path;

    private static string SafeFullPath(string path)
    {
        try { return Path.GetFullPath(path); }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException) { return path; }
    }

    // MARK: Fix metadata

    private async Task<ControlReply> FixMetadataAsync(FixMetadataOptions options, Job job)
    {
        var tracks = Songs(options.Album, options.Artist, options.SongIds);
        var service = model.Metadata.Service;
        var cancel = job.Cancellation.Token;
        job.Report("Searching MusicBrainz");
        var candidates = await service.CandidatesAsync(tracks, options.SearchAlbum, options.SearchArtist, cancel);
        var candidateResults = candidates.Take(10).Select(ReleaseResult.Of).ToList();
        var candidateLines = candidateResults.Select(release => $"  {release.Id}  {release.Description}").ToList();
        string releaseId;
        if (options.Release is { } chosen) releaseId = chosen;
        else if (candidates.Count > 0 && (options.Auto || options.DryRun)) releaseId = candidates[0].Id;
        else if (candidates.Count == 0) throw new ControlException("No release found on MusicBrainz for these songs. Search with other words: --search-album, --search-artist.");
        else
            return new ControlReply
            {
                Summary = string.Join('\n', candidateLines.Prepend("Releases found on MusicBrainz:")),
                Data = new JsonObject { ["candidates"] = Node(candidateResults) },
                Error = "Choose a release with --release ID, or pass --auto to take the best match (preview with --dry-run first).",
            };

        job.Report("Matching the songs to the release");
        var match = await service.MatchAsync(tracks, releaseId, cancel);
        var proposal = ReleaseMatcher.Proposal(match, includingUnmatched: true);
        var accepted = options.IncludeUnmatched ? proposal.Keys.ToHashSet() : match.Matches.Select(item => item.LocalId).ToHashSet();
        var changes = new Dictionary<long, TrackMetadata>();
        var songChanges = new List<SongChangeResult>();
        foreach (var track in tracks)
        {
            if (track.Id is not { } id || !accepted.Contains(id) || !proposal.TryGetValue(id, out var proposed)) continue;
            var diff = Dialogs.FixMetadataDialog.ChangesFrom(proposed, track.Metadata());
            if (diff.IsEmpty) continue;
            changes[id] = diff;
            songChanges.Add(new SongChangeResult(id, track.Title, track.Path, FieldChanges(track.Metadata(), diff)));
        }
        byte[]? cover = null;
        if (options.Cover)
        {
            job.Report("Looking for the cover");
            cover = (await service.CoverAsync(match.Release, match.Release.Title, match.Release.ArtistName, cancel))?.Data;
        }
        var result = new FixResult(options.DryRun, ReleaseResult.Of(match.Release), match.Matches.Count, tracks.Count, songChanges, cover is not null,
            options.Release is null ? candidateResults : []);
        var lines = new List<string>
        {
            $"{match.Release.Title} by {match.Release.ArtistName}{(match.Release.Year is { } year ? $" ({year})" : "")}, release {match.Release.Id}",
            $"{match.Matches.Count} of {tracks.Count} songs matched",
        };
        foreach (var song in songChanges)
        {
            lines.Add($"  {song.Title}");
            lines.AddRange(song.Changes.Select(change => $"    {change.Field}: {change.From ?? "empty"} -> {change.To}"));
        }
        if (cover is not null) lines.Add($"  New cover from {match.Release.Title}");
        if (changes.Count == 0 && cover is null) lines.Add("Nothing to change.");
        if (options.DryRun)
        {
            if (options.Release is null && candidateLines.Count > 1) lines.AddRange(candidateLines.Skip(1).Prepend("Other releases (choose one by its id):"));
            return new ControlReply { Summary = string.Join('\n', lines), Data = Node(result) };
        }
        if (changes.Count == 0 && cover is null) return new ControlReply { Summary = string.Join('\n', lines), Data = Node(result) };

        var writeToFiles = options.WriteTags ?? model.Metadata.WritesTags;
        var applied = await model.Metadata.ApplyAsync(changes, cover, tracks.Select(track => track.Id).OfType<long>().ToList(), writeToFiles,
            (done, total) => job.Report("Saving songs", done, total));
        result = result with { Updated = applied.Updated, FailedWrites = applied.FailedWrites };
        lines.Insert(0, $"Fixed {changes.Count} songs{(writeToFiles ? " (tags written into the files)" : " (in the library; files unchanged)")}.");
        if (applied.FailedWrites.Count > 0)
            lines.Add($"Could not write the tags of {applied.FailedWrites.Count} files (the fix is kept in the library): {string.Join(", ", applied.FailedWrites.Take(5))}");
        return new ControlReply { Summary = string.Join('\n', lines), Data = Node(result) };
    }

    /// <summary>Each changed field, as text: from (null when empty) and to.</summary>
    private static List<FieldChangeResult> FieldChanges(TrackMetadata current, TrackMetadata diff)
    {
        var options = new JsonSerializerOptions(ControlPipe.Json);
        var changed = (JsonSerializer.SerializeToNode(diff, options) as JsonObject) ?? [];
        var old = (JsonSerializer.SerializeToNode(current, options) as JsonObject) ?? [];
        return changed.OrderBy(pair => pair.Key, StringComparer.Ordinal)
            .Select(pair => new FieldChangeResult(pair.Key, TextOf(old[pair.Key]), TextOf(pair.Value) ?? "")).ToList();
    }

    private static string? TextOf(JsonNode? node) => node?.GetValueKind() switch
    {
        null or JsonValueKind.Null => null,
        JsonValueKind.True => "yes",
        JsonValueKind.False => "no",
        JsonValueKind.String => node.GetValue<string>(),
        _ => node.ToJsonString(),
    };

    // MARK: Files

    private async Task<ControlReply> OrganizeAsync(OrganizeOptions options, Job job)
    {
        var tracks = options.Album is not null || options.Artist is not null ? Songs(options.Album, options.Artist, null) : null;
        job.Report("Planning new names");
        var plan = await model.Files.PlanAsync(tracks);
        var moving = plan.Where(item => item.Status != RenameStatus.Unchanged).ToList();
        var renames = moving.Select(item => new RenameResult(item.Source, item.Destination, item.Status == RenameStatus.RenamedForConflict)).ToList();
        var lines = moving.Count == 0
            ? new List<string> { $"Every file already has its name ({plan.Count} checked)." }
            : [$"{(options.DryRun ? "Would rename" : "Renamed")} {moving.Count} of {plan.Count} files:"];
        lines.AddRange(renames.Take(200).Select(rename => $"  {rename.From} -> {rename.To}"));
        if (renames.Count > 200) lines.Add($"  and {renames.Count - 200} more");
        var data = new JsonObject { ["dryRun"] = options.DryRun, ["checked"] = plan.Count, ["renames"] = Node(renames) };
        if (options.DryRun || moving.Count == 0) return new ControlReply { Summary = string.Join('\n', lines), Data = data };
        var before = model.Files.Undoable?.Id;
        job.Report("Renaming files", 0, moving.Count);
        await model.Files.ApplyAsync(plan);
        if (model.Files.Undoable?.Id == before) throw new ControlException(model.ErrorMessage ?? "Could not rename the files (nothing was changed).");
        lines.Add("Undo with: groovelight undo");
        return new ControlReply { Summary = string.Join('\n', lines), Data = data };
    }

    private async Task<ControlReply> UndoAsync()
    {
        if (model.Files.Undoable is null) throw new ControlException("There is no import or organize to undo.");
        var title = model.Files.UndoTitle;
        await model.Files.UndoLastAsync();
        return new ControlReply { Summary = $"Done: {title}.", Data = new JsonObject { ["undone"] = title } };
    }

    private async Task<ControlReply> RescanAsync(Job job)
    {
        job.Report("Checking every file of the library");
        await model.RescanAndWaitAsync();
        if (model.LastScanSummary is not { } summary) return new ControlReply { Summary = "Checked the library." };
        return new ControlReply
        {
            Summary = $"Checked the library: {summary.Added} added, {summary.Updated} updated, {summary.Removed} removed, {summary.Failed.Count} unreadable.",
            Data = new JsonObject { ["added"] = summary.Added, ["updated"] = summary.Updated, ["removed"] = summary.Removed, ["unreadable"] = Node(summary.Failed) },
        };
    }

    // MARK: Playback

    private ControlReply Play(PlayOptions options)
    {
        var database = model.Database;
        string what;
        if (options.SongIds is { Count: > 0 } ids)
        {
            var chosen = Songs(ids);
            model.Play(chosen, shuffle: options.Shuffle);
            what = chosen.Count == 1 ? $"{chosen[0].Title} by {chosen[0].Artist ?? "Unknown Artist"}" : $"{chosen.Count} songs, from {chosen[0].Title}";
            return Playing(what, options.Shuffle);
        }
        // A song (or a search) comes first: an artist or album given with it only narrows it down ("Living Inside Myself"
        // by Gino Vannelli is that song, not every song of his).
        if ((options.Song ?? options.Query) is { } query)
        {
            var songs = database.Read(db => db.Search(query, 300)).Songs;
            if (options.Artist is { } artist) songs = songs.Where(song => Matches(song.Artist ?? "", artist, false) || Matches(song.AlbumArtist ?? "", artist, false)).ToList();
            if (options.Album is { } album) songs = songs.Where(song => Matches(song.Album ?? "", album, false)).ToList();
            if (options.Song is { } title)
            {
                // The song with that title before songs that only mention it ("Living Inside Myself (Live)" after).
                var exact = songs.Where(song => Matches(song.Title, title, true)).ToList();
                if (exact.Count > 0) songs = exact;
            }
            var narrowed = string.Join(" ", new[] { options.Artist is { } by ? $"by {by}" : null, options.Album is { } on ? $"on {on}" : null }.OfType<string>());
            if (songs.Count == 0) throw new ControlException($"No songs found for “{query}”{(narrowed.Length == 0 ? "" : " " + narrowed)}.");
            var chosen = options.Song is not null ? [songs[0]] : songs;
            model.Play(chosen, shuffle: options.Shuffle);
            what = chosen.Count == 1 ? $"{chosen[0].Title} by {chosen[0].Artist ?? "Unknown Artist"}{(chosen[0].Album is { } on2 ? ", " + on2 : "")}" : $"{chosen.Count} songs matching “{query}”";
        }
        else if (options.Album is { } albumName)
        {
            var album = PickAlbum(database.Read(db => db.Albums()), albumName, options.Artist);
            model.Play(database.Read(db => db.TracksOfAlbum(album.AlbumKey)), shuffle: options.Shuffle);
            what = $"{album.Title} by {album.Artist}";
        }
        else if (options.Artist is { } artistName)
        {
            var artist = Pick(database.Read(db => db.Artists()), artistName, "artist", item => item.DisplayName, item => item.DisplayName);
            model.Play(database.Read(db => db.TracksOfArtist(artist.Name)), shuffle: options.Shuffle);
            what = artist.DisplayName;
        }
        else if (options.Playlist is { } playlistName)
        {
            var playlist = Pick(database.Read(db => db.Playlists()), playlistName, "playlist", item => item.Name, item => item.Name);
            if (playlist.Id is not { } id) throw new ControlException("That playlist cannot be played.");
            var songs = database.Read(db => db.TracksOfPlaylist(id));
            if (songs.Count == 0) throw new ControlException($"The playlist {playlist.Name} is empty.");
            model.Play(songs, shuffle: options.Shuffle);
            what = $"the playlist {playlist.Name}";
        }
        else
        {
            model.Player.Resume();
            return NowPlaying();
        }
        return Playing(what, options.Shuffle);
    }

    /// <summary>The reply once playback was started: what plays, or why nothing does (the sound output could not open).</summary>
    private ControlReply Playing(string what, bool shuffle)
    {
        if (model.Player.State == PlaybackState.Stopped && model.Player.LastError is { } error) return ControlReply.Failure(error);
        return new() { Summary = $"Playing {what}{(shuffle ? ", shuffled" : "")}.", Data = new JsonObject { ["playing"] = what } };
    }

    private ControlReply Playback(PlaybackAction action)
    {
        var player = model.Player;
        switch (action)
        {
            case PlaybackAction.Pause: player.Pause(); break;
            case PlaybackAction.Resume: player.Resume(); break;
            case PlaybackAction.Toggle: player.TogglePlayPause(); break;
            case PlaybackAction.Next: player.Next(); break;
            case PlaybackAction.Previous: player.Previous(); break;
            case PlaybackAction.Stop: player.Stop(); break;
        }
        return NowPlaying();
    }

    private ControlReply NowPlaying()
    {
        if (CurrentSong() is not { } song) return new ControlReply { Summary = "Nothing is playing." };
        return new ControlReply
        {
            Summary = $"{Capitalized(song.State)}: {song.Title} by {song.Artist}, {song.Album} ({Time(song.Position)} of {Time(song.Duration)})",
            Data = Node(song),
        };
    }

    private NowPlayingResult? CurrentSong()
    {
        var player = model.Player;
        if (player.Current is not { } item) return null;
        var state = player.State switch
        {
            PlaybackState.Playing => "playing",
            PlaybackState.Paused => "paused",
            _ => "stopped",
        };
        return new NowPlayingResult(item.Id, item.Title, item.Artist, item.Album, state, player.CurrentTime, item.Duration);
    }

    // MARK: Playlists

    private ControlReply ListPlaylists()
    {
        var found = model.Database.Read(db => db.Playlists().Select(playlist =>
            new PlaylistResult(playlist.Id ?? 0, playlist.Name, playlist.IsSmart, playlist.Id is { } id ? db.TracksOfPlaylist(id).Count : 0)).ToList());
        var lines = found.Select(playlist => $"  {playlist.Name} ({Count(playlist.Songs, "song")}{(playlist.Smart ? ", smart" : "")})");
        return new ControlReply
        {
            Summary = found.Count == 0 ? "No playlists yet." : string.Join('\n', lines.Prepend("Playlists:")),
            Data = new JsonObject { ["playlists"] = Node(found) },
        };
    }

    private ControlReply CreatePlaylist(string name, IReadOnlyList<long> songIds)
    {
        name = name.Trim();
        if (name.Length == 0) throw new ControlException("Give the playlist a name.");
        if (model.Database.Read(db => db.Playlists()).FirstOrDefault(playlist => Matches(playlist.Name, name, true)) is { } same)
            throw new ControlException($"There is already a playlist called “{same.Name}”: add songs to it, or choose another name.");
        var songs = Songs(songIds);
        var playlist = model.Database.CreatePlaylist(name, songs.Select(song => song.Id).OfType<long>().ToList(), PlaylistCovers.RandomGenerated() with { ShowsTitle = true });
        var lines = songs.Select((song, index) => $"  {index + 1}. {song.Title} by {song.Artist ?? "Unknown Artist"}");
        return new ControlReply
        {
            Summary = string.Join('\n', lines.Prepend($"Created the playlist “{name}” with {Count(songs.Count, "song")}:")),
            Data = Node(new PlaylistResult(playlist.Id ?? 0, name, false, songs.Count)),
        };
    }

    private ControlReply AddToPlaylist(string name, IReadOnlyList<long> songIds)
    {
        var playlist = Pick(model.Database.Read(db => db.Playlists()), name, "playlist", item => item.Name, item => item.Name);
        if (playlist.Id is not { } id || playlist.IsSmart)
            throw new ControlException($"“{playlist.Name}” is a smart playlist: its songs come from its rules, so songs cannot be added to it.");
        var songs = Songs(songIds);
        model.Database.AddTracks(songs.Select(song => song.Id).OfType<long>().ToList(), id);
        var total = model.Database.Read(db => db.TracksOfPlaylist(id).Count);
        return new ControlReply
        {
            Summary = $"Added {Count(songs.Count, "song")} to “{playlist.Name}” (now {Count(total, "song")}).",
            Data = Node(new PlaylistResult(id, playlist.Name, false, total)),
        };
    }

    // MARK: Finding things by name

    /// <summary>Songs by id, in the order given; every id must be a song.</summary>
    private List<Track> Songs(IReadOnlyList<long> ids)
    {
        if (ids.Count == 0) throw new ControlException("Give the songs' ids (search finds them).");
        var byId = model.Database.Read(db => db.FetchTracks($"SELECT * FROM track WHERE id IN ({string.Join(",", ids.Distinct())})"))
            .Where(track => track.Id is not null).ToDictionary(track => track.Id!.Value);
        var missing = ids.Where(id => !byId.ContainsKey(id)).ToList();
        if (missing.Count > 0) throw new ControlException($"No songs with the ids {string.Join(", ", missing)} (search finds them).");
        return ids.Select(id => byId[id]).ToList();
    }

    /// <summary>Songs by id, or an album's songs by its title (and artist, to tell albums apart), or an artist's songs.</summary>
    private List<Track> Songs(string? album, string? artist, IReadOnlyList<long>? ids)
    {
        var database = model.Database;
        if (ids is { Count: > 0 })
        {
            var tracks = database.Read(db => db.FetchTracks($"SELECT * FROM track WHERE id IN ({string.Join(",", ids.Distinct())})"));
            return tracks.Count > 0 ? tracks : throw new ControlException($"No songs with the ids {string.Join(", ", ids)}.");
        }
        if (album is not null)
        {
            var found = PickAlbum(database.Read(db => db.Albums()), album, artist);
            return database.Read(db => db.TracksOfAlbum(found.AlbumKey));
        }
        if (artist is not null)
        {
            var found = Pick(database.Read(db => db.Artists()), artist, "artist", item => item.DisplayName, item => item.DisplayName);
            return database.Read(db => db.TracksOfArtist(found.Name));
        }
        throw new ControlException("Say which songs: --album (with --artist when several albums share the title), or --songs with their ids (from groovelight search).");
    }

    private static AlbumSummary PickAlbum(List<AlbumSummary> albums, string name, string? artist)
    {
        if (artist is not null)
        {
            var byArtist = albums.Where(album => Matches(album.Artist, artist, true)).ToList();
            albums = byArtist.Count > 0 ? byArtist : albums.Where(album => Matches(album.Artist, artist, false)).ToList();
        }
        return Pick(albums, name, "album", album => album.Title, album => $"{album.Title} by {album.Artist}{(album.Year is { } year ? $" ({year})" : "")}");
    }

    /// <summary>The one item called <paramref name="name"/> (ignoring case and accents), or the one whose name contains it.</summary>
    private static T Pick<T>(IReadOnlyList<T> items, string name, string what, Func<T, string> key, Func<T, string> describe, Func<T, bool>? alsoMatching = null)
    {
        foreach (var exact in new[] { true, false })
        {
            var found = items.Where(item => Matches(key(item), name, exact) || alsoMatching?.Invoke(item) == true).ToList();
            if (found.Count == 1) return found[0];
            if (found.Count > 1) throw new ControlException($"Several {what}s match “{name}”: {string.Join("; ", found.Take(10).Select(describe))}. Be more specific.");
        }
        throw new ControlException($"No {what} matches “{name}”.");
    }

    private static readonly CompareInfo Comparer = CultureInfo.InvariantCulture.CompareInfo;
    private const CompareOptions Loose = CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace;

    internal static bool Matches(string value, string name, bool exact) =>
        exact ? Comparer.Compare(value, name, Loose) == 0 : Comparer.IndexOf(value, name, Loose) >= 0;

    private static string Count(int number, string noun) => $"{number} {noun}{(number == 1 ? "" : "s")}";

    private static string Capitalized(string text) => text.Length == 0 ? text : char.ToUpperInvariant(text[0]) + text[1..];

    private static string Time(double seconds)
    {
        var total = (int)Math.Round(seconds);
        return $"{total / 60}:{total % 60:00}";
    }

    // MARK: Results (the data of replies)

    private sealed record StatusResult(string Version, int Songs, int Albums, int Artists, List<FolderResult> Folders, NowPlayingResult? NowPlaying);
    private sealed record FolderResult(string Path, int Songs, bool Available, bool ImportsHere);
    private sealed record NowPlayingResult(long Id, string Title, string Artist, string Album, string State, double Position, double Duration);
    private sealed record SearchResult(List<string> Artists, List<AlbumResult> Albums, List<SongResult> Songs);

    private sealed record AlbumResult(string Title, string Artist, int? Year, int Songs)
    {
        public static AlbumResult Of(AlbumSummary album) => new(album.Title, album.Artist, album.Year, album.TrackCount);
        [System.Text.Json.Serialization.JsonIgnore] public string Description => $"{Title} by {Artist}{(Year is { } year ? $" ({year})" : "")}, {Songs} songs";
    }

    private sealed record SongResult(long Id, string Title, string? Artist, string? Album, string? AlbumArtist, int? Year, int? TrackNumber, int? DiscNumber,
                                     string? Genre, double Duration, string Path, bool Loved, int Plays)
    {
        public static SongResult Of(Track track) => new(track.Id ?? 0, track.Title, track.Artist, track.Album, track.AlbumArtist, track.Year, track.TrackNumber,
            track.DiscNumber, track.Genre, track.Duration, track.Path, track.IsLoved, track.PlayCount);
        [System.Text.Json.Serialization.JsonIgnore] public string Description => $"[{Id}] {Title} by {Artist ?? "Unknown Artist"}{(Album is { } album ? ", " + album : "")}";
    }

    private sealed record ImportResult(bool DryRun, string Folder, List<ImportAlbumResult> Albums)
    {
        public int? Imported { get; init; }
        public int? Skipped { get; init; }
        public int? Failed { get; init; }
        public int? TrashedArchives { get; init; }
    }

    private sealed record ImportAlbumResult(string Album, string Artist, string? MatchedRelease, List<ImportSongResult> Songs);
    private sealed record ImportSongResult(string Source, string? Destination, bool AlreadyInLibrary);

    private sealed record ReleaseResult(string Id, string Title, string Artist, int? Year, string? Country, int Tracks, string? Format)
    {
        public static ReleaseResult Of(MBRelease release) => new(release.Id, release.Title, release.ArtistName, release.Year, release.Country, release.TotalTracks,
            release.Media?.FirstOrDefault()?.Format);
        [System.Text.Json.Serialization.JsonIgnore]
        public string Description => $"{Title} by {Artist}" + string.Concat(new[] { Year?.ToString(CultureInfo.InvariantCulture), Country, $"{Tracks} tracks", Format }.OfType<string>().Select(part => ", " + part));
    }

    private sealed record FixResult(bool DryRun, ReleaseResult Release, int Matched, int Songs, List<SongChangeResult> Changes, bool Cover, List<ReleaseResult> Candidates)
    {
        public int? Updated { get; init; }
        public List<string>? FailedWrites { get; init; }
    }

    private sealed record SongChangeResult(long Id, string Title, string Path, List<FieldChangeResult> Changes);
    private sealed record FieldChangeResult(string Field, string? From, string To);
    private sealed record PlaylistResult(long Id, string Name, bool Smart, int Songs);
    private sealed record RenameResult(string From, string To, bool Numbered);
}
