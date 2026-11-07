using System.Globalization;
using Groovelight.Core;
using Groovelight.Core.Library;
using Groovelight.Metadata;

namespace Groovelight.Model;

/// <summary>Online metadata for the app: lyrics lookups, album and artist info, Fix Metadata and the missing info job (the Mac's MetadataStore).</summary>
public sealed class MetadataStore : Support.Observable
{
    public const string FetchLyricsKey = "metadata.fetchLyrics";
    public const string WriteTagsKey = "metadata.writeTags";
    public const string ContactKey = "metadata.contact";
    public const string FetchAlbumInfoKey = "metadata.fetchAlbumInfo";

    private readonly AppModel model;
    private LibraryDatabase Database => model.Database;
    private Preferences Preferences => model.Preferences;

    /// <summary>One limiter for the whole app: MusicBrainz allows one request per second per client.</summary>
    private static readonly RateLimiter MusicBrainzLimiter = new(TimeSpan.FromMilliseconds(1100));
    /// <summary>LRCLIB answers bursts with "busy": one shared pace for every lyrics lookup.</summary>
    private static readonly RateLimiter LrcLibLimiter = new(TimeSpan.FromMilliseconds(400));
    private static readonly HttpFetcher Fetcher = new();

    public MetadataStore(AppModel model)
    {
        this.model = model;
        Preferences.Register(new Dictionary<string, object?> { [FetchLyricsKey] = true, [WriteTagsKey] = false, [FetchAlbumInfoKey] = true });
        _ = IndexSavedCreditsAsync();
    }

    /// <summary>Built per use so the contact setting applies right away.</summary>
    public MetadataService Service
    {
        get
        {
            var identity = Identity;
            return new MetadataService(identity, Fetcher, new MusicBrainzClient(Fetcher, identity, MusicBrainzLimiter), new LrcLibClient(Fetcher, identity, LrcLibLimiter));
        }
    }

    private ClientIdentity Identity => new(typeof(MetadataStore).Assembly.GetName().Version?.ToString(3) ?? "0", Contact: Preferences.String(ContactKey)?.Trim());

    public bool WritesTags => Preferences.Bool(WriteTagsKey);

    /// <summary>Fills the credits index from album info saved before the index existed (a Mac library, say).</summary>
    private async Task IndexSavedCreditsAsync()
    {
        await Task.Run(() =>
        {
            if (Database.Read(db => db.CreditIndexCount()) != 0) return;
            foreach (var (albumKey, data) in Database.Read(db => db.AllAlbumInfo()))
            {
                if (AlbumInfo.Decode(data) is { } info) Database.SetCredits(info.CreditEntries(albumKey), albumKey);
            }
        });
    }

    // MARK: Lyrics

    /// <summary>Tracks whose online lyrics lookup is running, for a "Searching" state.</summary>
    public HashSet<long> LyricsInFlight { get; } = [];

    /// <summary>Looks up lyrics online for a track without any, at most once a week per track. True when lyrics were found.</summary>
    public async Task<bool> EnsureLyricsAsync(Track track)
    {
        if (!Preferences.Bool(FetchLyricsKey) || track.Id is not { } id || track.DisplayLyrics() is not null || LyricsInFlight.Contains(id)) return false;
        if (track.LyricsCheckedAt is { } checkedAt && checkedAt > DateTime.UtcNow.AddDays(-7)) return false;
        LyricsInFlight.Add(id);
        OnPropertyChanged(nameof(LyricsInFlight));
        try
        {
            var lyrics = await Service.LyricsAsync(track);
            await Task.Run(() => Database.SetFetchedLyrics(lyrics?.BestText, id));
            return lyrics?.BestText is not null;
        }
        catch (Exception error) when (IsOffline(error))
        {
            // Offline or service error: try again next time.
            return false;
        }
        finally
        {
            LyricsInFlight.Remove(id);
            OnPropertyChanged(nameof(LyricsInFlight));
        }
    }

    internal static bool IsOffline(Exception error) =>
        error is MetadataException or HttpRequestException or TaskCanceledException or System.Text.Json.JsonException or IOException;

    // MARK: Album credits and background

    /// <summary>Albums whose credits are being looked up.</summary>
    public HashSet<string> AlbumInfoInFlight { get; } = [];

    /// <summary>
    /// Fetches an album's credits and Wikipedia summary unless cached. Albums without a match are retried after 30 days;
    /// errors (offline) are not cached.
    /// </summary>
    public async Task LoadAlbumInfoAsync(string albumKey, bool force = false)
    {
        if ((!Preferences.Bool(FetchAlbumInfoKey) && !force) || AlbumInfoInFlight.Contains(albumKey)) return;
        if (!force && await Task.Run(() => Database.Read(db => db.AlbumInfo(albumKey))) is { } cached)
        {
            var isMiss = AlbumInfo.Decode(cached.Data)?.IsEmpty ?? true;
            if (!isMiss || cached.FetchedAt > DateTime.UtcNow.AddDays(-30)) return;
        }
        var tracks = await Task.Run(() => Database.Read(db => db.TracksOfAlbum(albumKey)));
        if (tracks.Count == 0) return;
        AlbumInfoInFlight.Add(albumKey);
        OnPropertyChanged(nameof(AlbumInfoInFlight));
        try
        {
            var info = await Service.AlbumInfoAsync(tracks, WikipediaLanguages);
            await Task.Run(() =>
            {
                Database.SetAlbumInfo(info.Encode(), albumKey);
                Database.SetCredits(info.CreditEntries(albumKey), albumKey);
            });
        }
        catch (Exception error) when (IsOffline(error))
        {
        }
        finally
        {
            AlbumInfoInFlight.Remove(albumKey);
            OnPropertyChanged(nameof(AlbumInfoInFlight));
        }
    }

    /// <summary>Artists whose background is being looked up.</summary>
    public HashSet<string> ArtistInfoInFlight { get; } = [];

    /// <summary>Fetches an artist's Wikipedia summary and photo unless cached (misses retried after 30 days).</summary>
    public async Task LoadArtistInfoAsync(string name, bool force = false)
    {
        if ((!Preferences.Bool(FetchAlbumInfoKey) && !force) || ArtistInfoInFlight.Contains(name)
            || name.Equals("various artists", StringComparison.OrdinalIgnoreCase) || name.Equals("unknown artist", StringComparison.OrdinalIgnoreCase)
            || name == ArtistSummary.Compilations) return;
        if (!force && await Task.Run(() => Database.Read(db => db.ArtistInfo(name))) is { } cached)
        {
            var info = ArtistInfo.Decode(cached.Data);
            var isMiss = info?.IsEmpty ?? true;
            // Info found before photos were fetched gets one more lookup for the photo.
            var needsPhoto = info is { IsEmpty: false, ImageChecked: null };
            if (!needsPhoto && (!isMiss || cached.FetchedAt > DateTime.UtcNow.AddDays(-30))) return;
        }
        // Their albums in the library identify the artist exactly (names are ambiguous).
        var albums = await Task.Run(() => Database.Read(db => db.Albums(AlbumSort.Year, name)));
        ArtistInfoInFlight.Add(name);
        OnPropertyChanged(nameof(ArtistInfoInFlight));
        try
        {
            var service = Service;
            var info = await service.ArtistInfoAsync(name, albums.Select(album => album.Title).Where(title => title != "Unknown Album").ToList(), WikipediaLanguages);
            // The photo from the Wikipedia article, kept with the other artwork (offline, and in backups).
            if (info.About?.ImageUrl is { } imageUrl && Uri.TryCreate(imageUrl, UriKind.Absolute, out var url))
            {
                try
                {
                    if (await service.Artwork.DownloadAsync(new ArtworkCandidate(ArtworkSource.Wikimedia, url)) is { } data)
                        info = info with { ImageHash = await Task.Run(() => model.Artwork.Store(data)) };
                }
                catch (Exception error) when (IsOffline(error)) { }
            }
            info = info with { ImageChecked = true };
            await Task.Run(() => Database.SetArtistInfo(info.Encode(), name));
        }
        catch (Exception error) when (IsOffline(error))
        {
        }
        finally
        {
            ArtistInfoInFlight.Remove(name);
            OnPropertyChanged(nameof(ArtistInfoInFlight));
        }
    }

    /// <summary>The user's languages as Wikipedia codes ("pt-BR" to "pt"), then English.</summary>
    public static IReadOnlyList<string> WikipediaLanguages
    {
        get
        {
            var codes = new List<string>();
            foreach (var language in Windows.System.UserProfile.GlobalizationPreferences.Languages)
            {
                try { codes.Add(new CultureInfo(language).TwoLetterISOLanguageName); }
                catch (CultureNotFoundException) { }
            }
            codes.Add(CultureInfo.CurrentUICulture.TwoLetterISOLanguageName);
            codes.Add("en");
            return codes.Distinct().ToList();
        }
    }

    // MARK: Fixing metadata

    public void Review(IReadOnlyList<Track> tracks)
    {
        if (tracks.Count > 0) model.Request(new DialogRequest.FixMetadata(tracks));
    }

    public sealed class ApplyResult
    {
        public int Updated { get; set; }
        public int Written { get; set; }
        public List<string> FailedWrites { get; } = [];
    }

    /// <summary>
    /// Applies accepted changes. When writing to files is on, tags (and the cover) go into the files and the database
    /// follows; files that cannot be written keep the fix as a database override.
    /// </summary>
    public async Task<ApplyResult> ApplyAsync(IReadOnlyDictionary<long, TrackMetadata> changes, byte[]? cover, IReadOnlyList<long> coverTrackIds,
                                              bool writeToFiles, Action<int, int>? progress = null)
    {
        var result = new ApplyResult();
        var keys = changes.Keys.Concat(coverTrackIds).Distinct().ToList();
        var tracks = await Task.Run(() => Database.Read(db => db.FetchTracks($"SELECT * FROM track WHERE id IN ({string.Join(",", keys.DefaultIfEmpty(-1))})")));
        var byId = tracks.Where(track => track.Id is not null).ToDictionary(track => track.Id!.Value);
        string? coverHash = cover is null ? null : await Task.Run(() => model.Artwork.Store(cover));
        var overrides = new Dictionary<long, TrackMetadata>();
        var inFiles = new Dictionary<long, TrackMetadata>();
        var ids = changes.Keys.Union(coverHash is null ? [] : coverTrackIds).ToList();
        var done = 0;
        progress?.Invoke(0, ids.Count);
        foreach (var id in ids)
        {
            var metadata = changes.GetValueOrDefault(id) ?? new TrackMetadata();
            // A cue track shares its audio file with the rest of the album: its fixes stay in the library.
            if (!writeToFiles || !byId.TryGetValue(id, out var track) || track.IsCueTrack)
            {
                overrides[id] = metadata;
            }
            else
            {
                var embedCover = coverHash is not null && coverTrackIds.Contains(id) ? cover : null;
                // Earlier fixes kept only in the database go into the file too, since its overrides are cleared after.
                var toWrite = (track.GetOverrides() ?? new TrackMetadata()).Merging(metadata);
                try
                {
                    var written = await Task.Run(() => TagWriter.Write(toWrite, track.Path, frontCover: embedCover));
                    Database.UpdateFileInfo(id, written.FileSize, written.ModifiedAt);
                    inFiles[id] = toWrite;
                    result.Written++;
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or TagLib.CorruptFileException or TagLib.UnsupportedFormatException or NotSupportedException)
                {
                    result.FailedWrites.Add(Path.GetFileName(track.Path));
                    overrides[id] = metadata;
                }
            }
            progress?.Invoke(++done, ids.Count);
        }
        try
        {
            await Task.Run(() =>
            {
                Database.ApplyMetadata(overrides.Where(pair => !pair.Value.IsEmpty).ToDictionary(), asOverrides: true);
                Database.ApplyMetadata(inFiles, asOverrides: false);
                if (coverHash is not null) Database.SetFetchedArtwork(coverHash, coverTrackIds);
            });
        }
        catch (Microsoft.Data.Sqlite.SqliteException error)
        {
            result.FailedWrites.Add(error.Message);
        }
        result.Updated = ids.Count;
        return result;
    }

    // MARK: Fetching missing info for the whole library

    /// <summary>One step of the library job, in the order it runs.</summary>
    public enum LibraryStep { Albums, Artists, Artwork, Lyrics }

    public static string StepTitle(LibraryStep step) => step switch
    {
        LibraryStep.Albums => "Album credits and info",
        LibraryStep.Artists => "Artist info",
        LibraryStep.Artwork => "Missing artwork",
        _ => "Lyrics",
    };

    public sealed record LibraryJobProgress(LibraryStep Step, int Done, int Total, IReadOnlyList<LibraryStep> Remaining);

    /// <summary>Progress of the background job, null when idle.</summary>
    private LibraryJobProgress? libraryJob;
    public LibraryJobProgress? LibraryJob { get => libraryJob; private set => Set(ref libraryJob, value); }

    private CancellationTokenSource? libraryCancellation;
    private readonly Queue<(List<LibraryStep> Steps, IReadOnlySet<long>? Ids)> queuedJobs = new();

    public bool IsFetchingLibraryInfo => libraryCancellation is not null;

    /// <summary>
    /// Fetches what is missing in the library (or for some songs: those just imported), one request at a time: album
    /// credits and backgrounds, artist backgrounds, covers, then lyrics. A job asked for while another runs is queued.
    /// </summary>
    public async void FetchMissingInfo(IReadOnlyList<LibraryStep>? steps = null, IReadOnlySet<long>? trackIds = null)
    {
        var enabled = (steps ?? Enum.GetValues<LibraryStep>()).Where(step => step switch
        {
            LibraryStep.Albums or LibraryStep.Artists => Preferences.Bool(FetchAlbumInfoKey),
            LibraryStep.Lyrics => Preferences.Bool(FetchLyricsKey),
            _ => true,
        }).ToList();
        if (enabled.Count == 0) return;
        queuedJobs.Enqueue((enabled, trackIds));
        if (libraryCancellation is not null) return;
        libraryCancellation = new CancellationTokenSource();
        OnPropertyChanged(nameof(IsFetchingLibraryInfo));
        var token = libraryCancellation.Token;
        try
        {
            while (queuedJobs.Count > 0 && !token.IsCancellationRequested)
            {
                var job = queuedJobs.Dequeue();
                await RunJobAsync(job.Steps, job.Ids, token);
            }
        }
        finally
        {
            LibraryJob = null;
            libraryCancellation = null;
            queuedJobs.Clear();
            OnPropertyChanged(nameof(IsFetchingLibraryInfo));
        }
    }

    public void StopFetchingMissingInfo() => libraryCancellation?.Cancel();

    private async Task RunJobAsync(List<LibraryStep> steps, IReadOnlySet<long>? ids, CancellationToken token)
    {
        HashSet<string>? albumKeys = null, artists = null;
        if (ids is not null)
        {
            var tracks = await Task.Run(() => Database.Read(db => db.FetchTracks($"SELECT * FROM track WHERE id IN ({string.Join(",", ids.DefaultIfEmpty(-1))})")));
            albumKeys = tracks.Select(track => track.AlbumKey).ToHashSet();
            artists = tracks.SelectMany(track => new[] { track.DisplayAlbumArtist, track.DisplayArtist }).Select(name => name.ToLowerInvariant()).ToHashSet();
        }
        for (var index = 0; index < steps.Count && !token.IsCancellationRequested; index++)
        {
            var step = steps[index];
            var remaining = steps.Skip(index + 1).ToList();
            switch (step)
            {
                case LibraryStep.Albums:
                {
                    var keys = await Task.Run(() => Database.Read(db => db.AlbumKeysWithoutInfo()));
                    if (albumKeys is not null) keys = keys.Where(albumKeys.Contains).ToList();
                    await RunAsync(step, keys, remaining, key => LoadAlbumInfoAsync(key, force: true), token);
                    break;
                }
                case LibraryStep.Artists:
                {
                    var names = await Task.Run(() => Database.Read(db =>
                    {
                        // Never looked up, or looked up before photos were fetched.
                        var all = db.Artists();
                        var withoutPhoto = db.AllArtistInfo().Where(row => ArtistInfo.Decode(row.Data) is { IsEmpty: false, ImageChecked: null })
                            .Select(row => all.FirstOrDefault(artist => artist.Name.ToLowerInvariant() == row.ArtistKey)?.Name).OfType<string>();
                        return db.ArtistNamesWithoutInfo().Concat(withoutPhoto).ToList();
                    }));
                    if (artists is not null) names = names.Where(name => artists.Contains(name.ToLowerInvariant())).ToList();
                    await RunAsync(step, names, remaining, name => LoadArtistInfoAsync(name, force: true), token);
                    break;
                }
                case LibraryStep.Artwork:
                {
                    var albums = await Task.Run(() => Database.Read(db => db.Albums().Where(album => album.ArtworkHash is null && album.Title != "Unknown Album").ToList()));
                    if (albumKeys is not null) albums = albums.Where(album => albumKeys.Contains(album.AlbumKey)).ToList();
                    await RunAsync(step, albums, remaining, FetchCoverAsync, token);
                    break;
                }
                case LibraryStep.Lyrics:
                {
                    var trackIds = await Task.Run(() => Database.Read(db => db.TrackIdsNeedingLyrics()));
                    if (ids is not null) trackIds = trackIds.Where(ids.Contains).ToList();
                    await RunAsync(step, trackIds, remaining, async id =>
                    {
                        if (await Task.Run(() => Database.Read(db => db.FetchTrack(id))) is { } track) await EnsureLyricsAsync(track);
                    }, token);
                    break;
                }
            }
        }
    }

    private async Task RunAsync<T>(LibraryStep step, IReadOnlyList<T> items, IReadOnlyList<LibraryStep> remaining, Func<T, Task> work, CancellationToken token)
    {
        LibraryJob = new LibraryJobProgress(step, 0, items.Count, remaining);
        for (var index = 0; index < items.Count; index++)
        {
            if (token.IsCancellationRequested) return;
            await work(items[index]);
            LibraryJob = LibraryJob! with { Done = index + 1 };
        }
    }

    /// <summary>Looks for an album's cover: Cover Art Archive for its MusicBrainz release, otherwise the iTunes Search API.</summary>
    private async Task FetchCoverAsync(AlbumSummary album)
    {
        var tracks = await Task.Run(() => Database.Read(db => db.TracksOfAlbum(album.AlbumKey)));
        var releaseId = tracks.Select(track => track.MusicBrainzReleaseId).OfType<string>().FirstOrDefault();
        if (releaseId is null && await Task.Run(() => Database.Read(db => db.AlbumInfo(album.AlbumKey))) is { } cached)
            releaseId = AlbumInfo.Decode(cached.Data)?.ReleaseId;
        var release = releaseId is null ? null : new MBRelease { Id = releaseId, Title = album.Title };
        var artist = album.Artist == "Various Artists" ? null : album.Artist;
        if (await Service.CoverAsync(release, album.Title, artist) is { } found && await Task.Run(() => model.Artwork.Store(found.Data)) is { } hash)
            await Task.Run(() => Database.SetFetchedArtwork(hash, tracks.Select(track => track.Id).OfType<long>().ToList()));
    }
}
