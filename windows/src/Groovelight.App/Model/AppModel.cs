using System.Diagnostics;
using System.Text.Json;
using Groovelight.Audio;
using Groovelight.Audio.Windows;
using Groovelight.Core;
using Groovelight.Core.Library;
using Microsoft.UI.Dispatching;

namespace Groovelight.Model;

/// <summary>
/// App-wide state: the library database, the scanner, the player and the UI flags shared across windows (the Mac's
/// AppModel). Lives on the UI thread.
/// </summary>
public sealed partial class AppModel : Support.Observable
{
    public LibraryDatabase Database { get; }
    public ArtworkCache Artwork { get; }
    public Preferences Preferences { get; }
    public PlaybackController Player { get; }
    public WasapiOutput Output { get; }
    public SleepTimer SleepTimer { get; }
    public ShortcutStore Shortcuts { get; }
    public LibraryScanner Scanner { get; }
    public LibrarySync Sync { get; }
    public MetadataStore Metadata { get; }
    public LoudnessStore Loudness { get; }
    public EqualizerStore Equalizer { get; }
    public FilesStore Files { get; }
    public PlaylistTransfer PlaylistFiles { get; }
    public BackupManager Backup { get; }
    /// <summary>Songs converted for devices (FLAC for players that cannot decode them, or a lossy format), kept while syncs need them.</summary>
    public Core.Devices.ConversionCache Conversions { get; }
    /// <summary>Memory cards, players and paired phones.</summary>
    public DeviceStore Devices { get; }
    /// <summary>Updates from GitHub releases (the installed app only).</summary>
    public Support.Updates Updates { get; } = new();
    /// <summary>Wireless sync with the phone apps.</summary>
    public WirelessSyncService? Wireless { get; private set; }
    /// <summary>Scrobbles, "now playing" and loves on Last.fm.</summary>
    public LastFmStore LastFm { get; private set; } = null!;
    /// <summary>The command line tool's requests (`groovelight`, and AI tools through `groovelight mcp`).</summary>
    public ControlService Control { get; private set; } = null!;
    public string DataDirectory { get; }
    public DispatcherQueue Queue { get; }
    private readonly MediaControls? mediaControls;

    /// <summary>The model of the running app.</summary>
    public static AppModel Current { get; private set; } = null!;

    public const string VolumeKey = "player.volume";
    public const string QueueKey = "player.queue";
    public const string PositionKey = "player.position";

    /// <summary>Library folders that could not be opened at the last scan (an unplugged drive, a moved folder).</summary>
    public HashSet<string> UnavailableFolders { get; } = new(StringComparer.OrdinalIgnoreCase);

    public AppModel(string? dataDirectory = null)
    {
        Current = this;
        Queue = DispatcherQueue.GetForCurrentThread();
        DataDirectory = AppInfo.DataDirectory(dataDirectory ?? Environment.GetEnvironmentVariable("GROOVELIGHT_DATA"));
        Preferences = new Preferences(System.IO.Path.Combine(DataDirectory, "Preferences.plist"));
        Database = LibraryDatabase.Open(System.IO.Path.Combine(DataDirectory, "Library.sqlite"));
        Artwork = new ArtworkCache(System.IO.Path.Combine(DataDirectory, "Artwork"));
        Scanner = new LibraryScanner(Database, Artwork);
        Shortcuts = new ShortcutStore(Preferences);

        Output = new WasapiOutput();
        var dispatcher = new SynchronizationContextDispatcher(SynchronizationContext.Current);
        Player = new PlaybackController(Output, dispatcher);
        SleepTimer = new SleepTimer(Player, dispatcher);
        // The volume of the last session.
        if (Preferences[VolumeKey] is not null) Player.Volume = (float)Math.Clamp(Preferences.Double(VolumeKey), 0, 1);
        Player.VolumeChanged += volume => Preferences.Set(VolumeKey, (double)volume);
        PlaybackPrefs.Register(Preferences);
        PlaybackPrefs.Apply(Preferences, Player);

        Player.ItemStarted += OnItemStarted;
        Player.ItemFinished += (item, listened) =>
        {
            RecordListen(item, listened);
            ItemFinished?.Invoke(item, listened);
        };
        // The sound output could not be opened: said like other errors (an unplayable song is skipped quietly instead).
        Player.OutputFailed += message => ErrorMessage = message;
        // A song whose file is gone: its folder is checked, so the library catches up with what moved or was deleted.
        Player.ItemFailed += item => Sync?.CheckFolder(item.Path);
        Player.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(PlaybackController.Current)) OnPropertyChanged(nameof(CurrentItem));
        };
        try
        {
            mediaControls = new MediaControls(Player, action => Queue.TryEnqueue(() => action()), item => item.ArtworkPath);
        }
        catch (Exception error)
        {
            Debug.WriteLine($"Media controls unavailable: {error.Message}");
        }

        Sync = new LibrarySync(this);
        Metadata = new MetadataStore(this);
        Loudness = new LoudnessStore(this);
        Equalizer = new EqualizerStore(this);
        Core.Library.FileOrganizer.RecycleBin = new Support.WindowsRecycleBin();
        Files = new FilesStore(this);
        PlaylistFiles = new PlaylistTransfer(this);
        Backup = new BackupManager(this);
        Conversions = new Core.Devices.ConversionCache(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "Groovelight", "Conversions"));
        Devices = new DeviceStore(this);
        Wireless = new WirelessSyncService(this);
        LastFm = new LastFmStore(this);
        Control = new ControlService(this);
        Control.Start();
        Devices.Refresh();
        Updates.StartChecking(Preferences, Queue);
        // The installed app keeps its file types pointing at itself (its folder can change with an update).
        if (Updates.IsInstalled && Environment.ProcessPath is { } exe) _ = Task.Run(() => Support.FileTypes.Register(exe));
        Loudness.SetEnabled(Player.Normalization != VolumeNormalization.Off);
        playlistsObservation = new Support.Observation<List<Playlist>>(Database, db => db.Playlists(), value => Playlists = value);
        RestoreQueue();
        StartSavingQueue();
        _ = OpenLibraryRootsAsync();
        if (Environment.GetEnvironmentVariable("GROOVELIGHT_LIBRARY_PATH") is { Length: > 0 } debugPath)
        {
            Directory.CreateDirectory(debugPath);
            AddLibraryFolder(debugPath);
        }
    }

    private readonly Support.Observation<List<Playlist>> playlistsObservation;

    /// <summary>A song started (for Last.fm and the lyrics prefetch, set up by the parts that need it).</summary>
    public event Action<PlayableItem>? ItemStarted;
    public event Action<PlayableItem, double>? ItemFinished;

    public PlayableItem? CurrentItem => Player.Current;

    private void OnItemStarted(PlayableItem item)
    {
        PrefetchLyrics(item.Id);
        // Unmeasured songs about to play are measured first, so their level is right next time.
        if (Player.Normalization != VolumeNormalization.Off && item.TrackGain is null)
            Loudness.Prioritize(Player.Queue.NextForAutoAdvance is { } next ? [item.Id, next.Id] : [item.Id]);
        ItemStarted?.Invoke(item);
    }

    /// <summary>Looks up lyrics online as soon as a song starts, so they are ready when the lyrics panel opens.</summary>
    private async void PrefetchLyrics(long trackId)
    {
        if (await Task.Run(() => Database.Read(db => db.FetchTrack(trackId))) is { } track) await Metadata.EnsureLyricsAsync(track);
    }

    // MARK: Navigation state

    private SidebarItem selection = SidebarItem.Home;

    public SidebarItem Selection
    {
        get => selection;
        set
        {
            var old = selection;
            if (!Set(ref selection, value)) return;
            Path.Clear();
            OnPropertyChanged(nameof(Path));
            // Leaving the results clears the search, so the field never shows text the page does not reflect.
            if (old.Kind == PageKind.Search) SearchText = "";
        }
    }

    /// <summary>Pages pushed on top of the selected one.</summary>
    public List<Route> Path { get; } = [];

    public void Push(Route route)
    {
        IsShowingNowPlaying = false;
        Path.Add(route);
        OnPropertyChanged(nameof(Path));
    }

    /// <summary>Back from a pushed page (album, artist, person).</summary>
    public void GoBack()
    {
        if (Path.Count == 0) return;
        Path.RemoveAt(Path.Count - 1);
        OnPropertyChanged(nameof(Path));
    }

    public void ReplacePath(IEnumerable<Route> routes)
    {
        Path.Clear();
        Path.AddRange(routes);
        OnPropertyChanged(nameof(Path));
    }

    /// <summary>Artist selected on the Artists page (kept here so other pages can open an artist).</summary>
    private string? selectedArtist;
    public string? SelectedArtist { get => selectedArtist; set => Set(ref selectedArtist, value); }
    /// <summary>Genre selected on the Genres page.</summary>
    private string? selectedGenre;
    public string? SelectedGenre { get => selectedGenre; set => Set(ref selectedGenre, value); }
    /// <summary>All playlists, kept current for menus.</summary>
    private List<Playlist> playlists = [];
    public List<Playlist> Playlists { get => playlists; set => Set(ref playlists, value); }

    private string searchText = "";

    public string SearchText
    {
        get => searchText;
        set
        {
            if (!Set(ref searchText, value)) return;
            // Typing anywhere shows the results.
            if (value.Trim().Length > 0 && Selection.Kind != PageKind.Search) Selection = SidebarItem.Search;
        }
    }

    /// <summary>Raised to move the keyboard focus to the title bar's search box.</summary>
    public event Action? SearchFocusRequested;

    private bool isShowingNowPlaying, isShowingLyrics, isShowingNowPlayingQueue;
    private SidePanel sidePanel;
    private ScanProgress? scanProgress;
    private ScanSummary? lastScanSummary;
    private string? errorMessage;

    public bool IsShowingNowPlaying { get => isShowingNowPlaying; set => Set(ref isShowingNowPlaying, value); }

    public SidePanel SidePanel
    {
        get => sidePanel;
        set
        {
            if (!Set(ref sidePanel, value)) return;
            OnPropertyChanged(nameof(IsShowingQueue));
            OnPropertyChanged(nameof(IsShowingLyricsPanel));
        }
    }

    /// <summary>Lyrics in Now Playing.</summary>
    public bool IsShowingLyrics { get => isShowingLyrics; set => Set(ref isShowingLyrics, value); }
    /// <summary>Up Next in Now Playing: beside the cover, or in a vintage player's place.</summary>
    public bool IsShowingNowPlayingQueue { get => isShowingNowPlayingQueue; set => Set(ref isShowingNowPlayingQueue, value); }
    public ScanProgress? ScanProgress { get => scanProgress; set => Set(ref scanProgress, value); }
    public ScanSummary? LastScanSummary { get => lastScanSummary; set => Set(ref lastScanSummary, value); }
    public string? ErrorMessage { get => errorMessage; set => Set(ref errorMessage, value); }

    public bool IsShowingQueue
    {
        get => SidePanel == SidePanel.Queue;
        set => SidePanel = value ? SidePanel.Queue : SidePanel == SidePanel.Queue ? SidePanel.None : SidePanel;
    }

    public bool IsShowingLyricsPanel
    {
        get => SidePanel == SidePanel.Lyrics;
        set => SidePanel = value ? SidePanel.Lyrics : SidePanel == SidePanel.Lyrics ? SidePanel.None : SidePanel;
    }

    // MARK: Library folders

    public void AddLibraryFolder(string path)
    {
        try
        {
            var full = System.IO.Path.GetFullPath(path).TrimEnd(System.IO.Path.DirectorySeparatorChar);
            if (full.EndsWith(':')) full += System.IO.Path.DirectorySeparatorChar;
            var root = Database.AddRoot(full);
            UnavailableFolders.Remove(root.Path);
            _ = Sync.FoldersChangedAsync(root.Id);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or Microsoft.Data.Sqlite.SqliteException or ArgumentException)
        {
            ErrorMessage = $"Could not add folder: {error.Message}";
        }
    }

    public void RemoveRoot(LibraryRoot root)
    {
        if (root.Id is not { } id) return;
        try
        {
            Database.RemoveRoot(id);
            UnavailableFolders.Remove(root.Path);
            _ = Sync.FoldersChangedAsync();
        }
        catch (Microsoft.Data.Sqlite.SqliteException error)
        {
            ErrorMessage = error.Message;
        }
    }

    /// <summary>Checks every file of every library folder, showing progress (Rescan Now).</summary>
    public void RescanAll() => Sync.CheckEverything(loud: true);

    /// <summary>Rescans every library folder and returns when done (after an import).</summary>
    public Task RescanAndWaitAsync() => Sync.CheckEverythingAndWaitAsync();

    private async Task OpenLibraryRootsAsync()
    {
        var roots = await Task.Run(() => Database.Read(db => db.Roots()));
        foreach (var root in roots)
        {
            // Restored from another computer, or the folder moved: Settings, Library offers to locate it.
            if (!Directory.Exists(root.Path)) UnavailableFolders.Add(root.Path);
        }
        OnPropertyChanged(nameof(UnavailableFolders));
        await Sync.StartAsync();
    }

    /// <summary>
    /// After a restore: folders that are not on this computer (another computer, moved music) are listed for the user to
    /// locate, then what is available is rescanned.
    /// </summary>
    public async Task<List<LibraryRoot>> ReopenLibraryAfterRestoreAsync()
    {
        var roots = await Task.Run(() => Database.Read(db => db.Roots()));
        var missing = roots.Where(root => !Directory.Exists(root.Path)).ToList();
        UnavailableFolders.Clear();
        foreach (var root in missing) UnavailableFolders.Add(root.Path);
        OnPropertyChanged(nameof(UnavailableFolders));
        await Sync.FoldersChangedAsync();
        Sync.CheckEverything(loud: false);
        return missing;
    }

    // MARK: Queue across launches

    private PlayQueue.Snapshot? savedQueue;
    private string? savedQueueJson;

    /// <summary>The queue and song of the last session, paused where it was (Play resumes there).</summary>
    private void RestoreQueue()
    {
        if (Preferences.Data(QueueKey) is not { } data) return;
        try
        {
            var snapshot = JsonSerializer.Deserialize<PlayQueue.Snapshot>(data, SwiftJson.Options);
            if (snapshot is null) return;
            var ids = snapshot.ItemIds.Distinct().ToList();
            var tracks = Database.Read(db => db.FetchTracks($"SELECT * FROM track WHERE id IN ({string.Join(",", ids)})"));
            var items = tracks.Where(track => track.Id is not null).ToDictionary(track => track.Id!.Value, PlayableItem);
            Player.Restore(snapshot, items, Preferences.Double(PositionKey));
            savedQueue = snapshot;
        }
        catch (JsonException)
        {
        }
    }

    /// <summary>Saves the queue when it changes and the position every few seconds.</summary>
    private void StartSavingQueue()
    {
        var timer = Queue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(3);
        timer.Tick += (_, _) => SaveQueue();
        timer.Start();
    }

    public void SaveQueue()
    {
        if (Player.Queue.Current is null)
        {
            if (savedQueue is not null || Preferences.Contains(QueueKey))
            {
                Preferences.Remove(QueueKey);
                Preferences.Remove(PositionKey);
                savedQueue = null;
                savedQueueJson = null;
            }
            return;
        }
        var snapshot = Player.Queue.TakeSnapshot();
        var json = JsonSerializer.Serialize(snapshot, SwiftJson.Options);
        if (json != savedQueueJson)
        {
            Preferences.Set(QueueKey, System.Text.Encoding.UTF8.GetBytes(json));
            savedQueue = snapshot;
            savedQueueJson = json;
        }
        Preferences.Set(PositionKey, Player.CurrentTime);
    }

    /// <summary>When the app quits: the queue, the preferences, and the output device back to the system.</summary>
    public void Shutdown()
    {
        SaveQueue();
        Preferences.Flush();
        Player.ReleaseOutputDevice();
        mediaControls?.Dispose();
        Sync.Dispose();
        Wireless?.Shutdown();
        Control?.Stop();
    }

    // MARK: Playback

    public PlayableItem PlayableItem(Track track) => new()
    {
        Id = track.Id ?? 0,
        Path = track.FilePath,
        Title = track.Title,
        Artist = track.DisplayArtist,
        Album = track.DisplayAlbum,
        Duration = track.Duration,
        ArtworkHash = track.ArtworkHash,
        ArtworkPath = track.ArtworkHash is { } hash ? Artwork.PathFor(hash, ArtworkCache.Size.Large) : null,
        // A cue track plays only its range of the shared audio file.
        StartTime = track.StartTime,
        EndTime = track.EndTime,
        SampleRate = track.SampleRate,
        AlbumKey = track.AlbumKey,
        // ReplayGain tags first, otherwise the measured loudness.
        TrackGain = track.ReplayGainTrackGain ?? (track.Loudness is { } loudness ? LoudnessMeter.Gain(loudness) : null),
        AlbumGain = track.ReplayGainAlbumGain,
        BitDepth = track.BitDepth,
    };

    public void Play(IReadOnlyList<Track> tracks, int startAt = 0, bool shuffle = false, double position = 0)
    {
        if (tracks.Count == 0) return;
        Player.Play(tracks.Select(PlayableItem).ToList(), startAt, shuffle, position);
    }

    public void PlayNext(IReadOnlyList<Track> tracks) => Player.PlayNext(tracks.Select(PlayableItem).ToList());

    /// <summary>Adds songs to the end of Up Next.</summary>
    public void AddToUpNext(IReadOnlyList<Track> tracks) => Player.PlayLater(tracks.Select(PlayableItem).ToList());

    public Task<List<Track>> TracksAsync(SongSource source) => Task.Run(() => Database.Read(db => source switch
    {
        SongSource.Album album => db.TracksOfAlbum(album.AlbumKey),
        SongSource.Playlist playlist => db.TracksOfPlaylist(playlist.Id),
        SongSource.LovedSongs => db.LovedTracks(),
        SongSource.Tracks tracks => tracks.Items.ToList(),
        _ => [],
    }));

    /// <summary>Queues an album or playlist right after the current song (<paramref name="next"/>) or at the end of Up Next.</summary>
    public async void Enqueue(SongSource source, bool next)
    {
        var tracks = await TracksAsync(source);
        if (next) PlayNext(tracks); else AddToUpNext(tracks);
    }

    public async void Play(SongSource source, bool shuffle = false)
    {
        var tracks = await TracksAsync(source);
        Play(tracks, shuffle: shuffle);
    }

    public void PlayAlbum(AlbumSummary album, bool shuffle = false) => Play(new SongSource.Album(album.AlbumKey), shuffle);

    public void PlayPlaylist(long id, bool shuffle = false) => Play(new SongSource.Playlist(id), shuffle);

    public async Task<Track?> CurrentTrackAsync()
    {
        if (Player.Current?.Id is not { } id) return null;
        return await Task.Run(() => Database.Read(db => db.FetchTrack(id)));
    }

    /// <summary>Shows the search page and focuses the title bar's search box (Ctrl+F).</summary>
    public void ShowSearch()
    {
        IsShowingNowPlaying = false;
        if (Selection.Kind != PageKind.Search) Selection = SidebarItem.Search;
        else ReplacePath([]);
        SearchFocusRequested?.Invoke();
    }

    /// <summary>Switches to the Artists page with <paramref name="name"/> selected.</summary>
    public void ShowArtist(string name)
    {
        IsShowingNowPlaying = false;
        SearchText = "";
        SelectedArtist = name;
        if (Selection.Kind == PageKind.Artists) ReplacePath([]);
        else Selection = SidebarItem.Artists;
    }

    /// <summary>Opens the page of a person from the credits, on top of the current page.</summary>
    public void ShowPerson(CreditPerson person) => Push(new Route.Person(person));

    /// <summary>Opens an album's page on top of the current section.</summary>
    public async void ShowAlbum(string albumKey)
    {
        var album = await Task.Run(() => Database.Read(db => db.Albums().FirstOrDefault(album => album.AlbumKey == albumKey)));
        if (album is null) return;
        IsShowingNowPlaying = false;
        ReplacePath([new Route.Album(album)]);
    }

    public void ShowAlbum(AlbumSummary album) => Push(new Route.Album(album));

    /// <summary>Reopens the album page of a track (after its album changed, the old page would be empty).</summary>
    public async Task ShowAlbumContainingAsync(long trackId)
    {
        if (!Path.Any(route => route is Route.Album)) return;
        var album = await Task.Run(() => Database.Read(db => db.FetchTrack(trackId) is { } track ? db.Albums().FirstOrDefault(album => album.AlbumKey == track.AlbumKey) : null));
        if (album is null) return;
        ReplacePath(Path.Select(route => route is Route.Album ? new Route.Album(album) : route).ToList());
    }

    /// <summary>Shows the album of the song that is playing.</summary>
    public async void GoToCurrentSong()
    {
        IsShowingNowPlaying = false;
        if (await CurrentTrackAsync() is not { } track) return;
        if (Selection.Kind is PageKind.Search or PageKind.Shelf) Selection = SidebarItem.Albums;
        ShowAlbum(track.AlbumKey);
    }

    /// <summary>Loves the song that is playing, or undoes it.</summary>
    public async void ToggleLovedCurrent()
    {
        if (await CurrentTrackAsync() is { } track) ToggleLoved(track);
    }

    /// <summary>Lyrics in Now Playing when it is open, otherwise in the side panel.</summary>
    public void ToggleLyrics()
    {
        if (IsShowingNowPlaying)
        {
            IsShowingLyrics = !IsShowingLyrics;
            if (IsShowingLyrics) IsShowingNowPlayingQueue = false;
        }
        else IsShowingLyricsPanel = !IsShowingLyricsPanel;
    }

    /// <summary>Up Next beside Now Playing's cover while it shows, in the side panel otherwise.</summary>
    public void ToggleUpNext()
    {
        if (IsShowingNowPlaying)
        {
            IsShowingNowPlayingQueue = !IsShowingNowPlayingQueue;
            if (IsShowingNowPlayingQueue) IsShowingLyrics = false;
        }
        else IsShowingQueue = !IsShowingQueue;
    }

    /// <summary>Playback speed from the menu (saved like the setting).</summary>
    public void SetRate(float rate)
    {
        Player.Rate = rate;
        Preferences.Set(PlaybackPrefs.Rate, (double)Player.Rate);
    }

    public void SetBitPerfect(bool on)
    {
        Player.BitPerfect = on;
        Preferences.Set(PlaybackPrefs.BitPerfect, on);
    }

    private float volumeBeforeMute = 0.8f;

    public void ToggleMute()
    {
        if (Player.Volume > 0)
        {
            volumeBeforeMute = Player.Volume;
            Player.Volume = 0;
        }
        else Player.Volume = Math.Max(volumeBeforeMute, 0.1f);
    }

    public void CycleRepeat() => Player.RepeatMode = Player.RepeatMode switch
    {
        RepeatMode.Off => RepeatMode.All,
        RepeatMode.All => RepeatMode.One,
        _ => RepeatMode.Off,
    };

    public void SkipBy(double seconds)
    {
        if (Player.Current is null) return;
        Player.Seek(Math.Clamp(Player.CurrentTime + seconds, 0, Player.Duration));
    }

    /// <summary>Logs the listen: plays count when at least half the track (or 4 minutes) was heard, early stops count as skips.</summary>
    private void RecordListen(PlayableItem item, double seconds)
    {
        if (seconds <= 0) return;
        try
        {
            Database.RecordListen(item.Id, DateTime.UtcNow.AddSeconds(-seconds), seconds);
        }
        catch (Microsoft.Data.Sqlite.SqliteException)
        {
        }
    }

    /// <summary>Loves changed (Last.fm sends them on).</summary>
    public event Action<IReadOnlyList<long>, bool>? LovedChanged;

    public void ToggleLoved(Track track)
    {
        if (track.Id is not { } id) return;
        Database.SetLoved(!track.IsLoved, id);
        LovedChanged?.Invoke([id], !track.IsLoved);
    }

    /// <summary>Loves songs (dropping them on Loved Songs).</summary>
    public void Love(IReadOnlyList<long> trackIds)
    {
        Database.SetLoved(true, trackIds);
        LovedChanged?.Invoke(trackIds, true);
    }

    public void SetRating(Track track, int rating)
    {
        if (track.Id is { } id) Database.SetRating(rating, id);
    }

    // MARK: Playlists

    public void NewPlaylist(IReadOnlyList<Track>? tracks = null)
    {
        var playlist = Database.CreatePlaylist("Untitled Playlist", tracks?.Select(track => track.Id).OfType<long>().ToList() ?? [],
                                               PlaylistCovers.RandomGenerated());
        if (playlist.Id is { } id) { IsShowingNowPlaying = false; Selection = SidebarItem.Playlist(id); }
    }

    /// <summary>A playlist of songs (everything a person is credited on) with a cover showing its name, opened.</summary>
    public void CreatePlaylist(string name, IReadOnlyList<Track> tracks)
    {
        var cover = PlaylistCovers.RandomGenerated() with { ShowsTitle = true };
        var playlist = Database.CreatePlaylist(name, tracks.Select(track => track.Id).OfType<long>().ToList(), cover);
        if (playlist.Id is { } id) { IsShowingNowPlaying = false; Selection = SidebarItem.Playlist(id); }
    }

    public void DeletePlaylist(long id)
    {
        Database.DeletePlaylist(id);
        if (Selection.Kind == PageKind.Playlist && Selection.PlaylistId == id) Selection = SidebarItem.AllPlaylists;
    }

    public void Add(IReadOnlyList<Track> tracks, Playlist playlist)
    {
        if (playlist.Id is { } id) Database.AddTracks(tracks.Select(track => track.Id).OfType<long>().ToList(), id);
    }

    // MARK: Requests for the window (dialogs)

    /// <summary>Raised for the window to show a dialog: Get Info, credits, playlist editors and the like.</summary>
    public event Action<DialogRequest>? DialogRequested;

    public void Request(DialogRequest request) => DialogRequested?.Invoke(request);

    public void GetInfo(IReadOnlyList<Track> tracks)
    {
        if (tracks.Count > 0) Request(new DialogRequest.GetInfo(tracks));
    }

    public async void GetInfo(string albumKey) => GetInfo(await TracksAsync(new SongSource.Album(albumKey)));

    public void ShowCredits(Track track) => Request(new DialogRequest.Credits(track));

    public void EditPlaylist(Playlist playlist) => Request(new DialogRequest.EditPlaylist(playlist));

    public void NewSmartPlaylist() => Request(new DialogRequest.SmartPlaylist(null));

    public void EditSmartPlaylist(Playlist playlist) => Request(new DialogRequest.SmartPlaylist(playlist));

    /// <summary>Show in File Explorer, with the files selected (one folder at a time).</summary>
    public static void ShowInExplorer(IReadOnlyList<Track> tracks)
    {
        if (tracks.FirstOrDefault() is not { } track) return;
        var path = track.FilePath;
        if (File.Exists(path)) Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
        else if (System.IO.Path.GetDirectoryName(path) is { } folder && Directory.Exists(folder))
            Process.Start(new ProcessStartInfo("explorer.exe", $"\"{folder}\"") { UseShellExecute = true });
    }

    public static void OpenUrl(string url) => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
}

/// <summary>A dialog the window shows for the model.</summary>
public abstract record DialogRequest
{
    public sealed record GetInfo(IReadOnlyList<Track> Tracks) : DialogRequest;
    public sealed record Credits(Track Track) : DialogRequest;
    public sealed record EditPlaylist(Playlist Playlist) : DialogRequest;
    public sealed record SmartPlaylist(Playlist? Playlist) : DialogRequest;
    public sealed record FixMetadata(IReadOnlyList<Track> Tracks) : DialogRequest;
    public sealed record Organize(IReadOnlyList<Track>? Tracks) : DialogRequest;
    public sealed record Message(string Title, string Text) : DialogRequest;
    /// <summary>Export a playlist to a file (null: Loved Songs).</summary>
    public sealed record ExportPlaylist(long? PlaylistId) : DialogRequest;
}
