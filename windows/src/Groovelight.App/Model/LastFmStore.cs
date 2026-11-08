using System.Security.Cryptography;
using System.Text.Json;
using Groovelight.Audio;
using Groovelight.Core.Devices;
using Groovelight.Core.Library;
using Groovelight.Metadata;

namespace Groovelight.Model;

/// <summary>
/// Last.fm for the app (the Mac's LastFMStore): connecting the account (desktop authorization in the browser), "now
/// playing" updates, scrobbles by Last.fm's rules and loves, all through a queue in the library database so nothing is
/// lost while offline. The API secret and the session key are kept encrypted for the Windows user (DPAPI).
/// </summary>
public sealed class LastFmStore : Support.Observable
{
    public const string ApiKeyKey = "lastfm.apiKey";
    public const string UsernameKey = "lastfm.username";
    public const string ScrobbleKey = "lastfm.scrobble";
    public const string NowPlayingKey = "lastfm.nowPlaying";
    public const string SyncLovesKey = "lastfm.syncLoves";
    public const string LastSentAtKey = "lastfm.lastSentAt";
    public const string HistoryImportedAtKey = "lastfm.historyImportedAt";

    private readonly AppModel model;
    private readonly LastFmSender sender;
    private readonly string secretsFile;
    private readonly Support.Observation<int> pendingObservation;
    private readonly Support.Observation<(int Plays, int Matched)> historyObservation;
    private CancellationTokenSource? importing;
    private LastFmHistoryImport.Progress? historyProgress;
    private string? historyProblem;
    private DateTime? historyImportedAt;
    private (int Plays, int Matched) historyCounts;
    private DateTime lastHistoryCheck = DateTime.MinValue;
    private Dictionary<string, string> secrets;
    private string apiKey;
    private string? username;
    private bool isConnecting;
    private bool isSending;
    private int pendingCount;
    private string? problem;
    private DateTime? lastSentAt;
    private CancellationTokenSource? connecting;
    private bool sendScheduled;
    /// <summary>The song playing now: when it started and its library record (album artist, track number).</summary>
    private (long Id, DateTime StartedAt, Track? Track)? current;

    public LastFmStore(AppModel model)
    {
        this.model = model;
        sender = new LastFmSender(model.Database);
        secretsFile = Path.Combine(model.DataDirectory, "Last.fm.bin");
        secrets = LoadSecrets();
        var preferences = model.Preferences;
        preferences.Register(new Dictionary<string, object?> { [ScrobbleKey] = true, [NowPlayingKey] = true, [SyncLovesKey] = true });
        apiKey = preferences.String(ApiKeyKey) ?? "";
        username = SessionKey is null ? null : preferences.String(UsernameKey);
        lastSentAt = preferences.Date(LastSentAtKey);
        pendingObservation = new Support.Observation<int>(model.Database, db => db.LastFmQueueCount(), count => PendingCount = count);
        historyImportedAt = preferences.Date(HistoryImportedAtKey);
        historyObservation = new Support.Observation<(int, int)>(model.Database, db => db.ListenCounts(Listen.Sources.LastFm), counts => HistoryCounts = counts);

        model.ItemStarted += Started;
        model.ItemFinished += Finished;
        model.LovedChanged += LovedChanged;
        if (model.Wireless is { } wireless) wireless.HistoryApplied += PlayedElsewhere;

        // Retries what is waiting every few minutes (offline, Last.fm down), and soon after launch. Once the history was
        // imported, what is new on Last.fm (from other players) follows every 6 hours.
        var timer = model.Queue.CreateTimer();
        timer.Interval = TimeSpan.FromMinutes(5);
        timer.Tick += (_, _) =>
        {
            SendSoon(0);
            if (HistoryImportedAt is not null && DateTime.UtcNow - lastHistoryCheck > TimeSpan.FromHours(6))
            {
                lastHistoryCheck = DateTime.UtcNow;
                ImportHistory();
            }
        };
        timer.Start();
        var first = model.Queue.CreateTimer();
        first.Interval = TimeSpan.FromSeconds(5);
        first.IsRepeating = false;
        first.Tick += (_, _) => SendSoon(0);
        first.Start();
    }

    /// <summary>The user's name on Last.fm while connected.</summary>
    public string? Username { get => username; private set => Set(ref username, value); }
    public bool IsConnecting { get => isConnecting; private set => Set(ref isConnecting, value); }
    public bool IsSending { get => isSending; private set => Set(ref isSending, value); }
    /// <summary>Waiting scrobbles, loves and unloves.</summary>
    public int PendingCount { get => pendingCount; private set => Set(ref pendingCount, value); }
    /// <summary>What went wrong last (null after a successful send).</summary>
    public string? Problem { get => problem; private set => Set(ref problem, value); }
    public DateTime? LastSentAt { get => lastSentAt; private set => Set(ref lastSentAt, value); }

    /// <summary>Bringing the user's Last.fm history into the listening log (for Home): progress while it runs.</summary>
    public LastFmHistoryImport.Progress? HistoryProgress { get => historyProgress; private set => Set(ref historyProgress, value); }
    public string? HistoryProblem { get => historyProblem; private set => Set(ref historyProblem, value); }
    public DateTime? HistoryImportedAt { get => historyImportedAt; private set => Set(ref historyImportedAt, value); }
    /// <summary>Last.fm plays in the log, and how many of them are songs in the library.</summary>
    public (int Plays, int Matched) HistoryCounts { get => historyCounts; private set => Set(ref historyCounts, value); }
    public bool IsImportingHistory => importing is not null;

    /// <summary>Imports the plays on Last.fm not in the log yet, in the background (1 page of 200 a second).</summary>
    public async void ImportHistory()
    {
        if (importing is not null || Client() is not { } client || Username is not { } user) return;
        importing = new CancellationTokenSource();
        OnPropertyChanged(nameof(IsImportingHistory));
        HistoryProblem = null;
        var importer = new LastFmHistoryImport(model.Database, client, user);
        var token = importing.Token;
        try
        {
            await Task.Run(() => importer.RunAsync(progress => model.Queue.TryEnqueue(() => HistoryProgress = progress), token), token);
            HistoryImportedAt = DateTime.UtcNow;
            model.Preferences.Set(HistoryImportedAtKey, HistoryImportedAt);
        }
        catch (OperationCanceledException)
        {
        }
        catch (LastFmException error)
        {
            HistoryProblem = error.Describe();
        }
        catch (Exception error) when (error is HttpRequestException or IOException or Microsoft.Data.Sqlite.SqliteException)
        {
            HistoryProblem = error.Message;
        }
        finally
        {
            importing.Dispose();
            importing = null;
            HistoryProgress = null;
            OnPropertyChanged(nameof(IsImportingHistory));
        }
    }

    public void CancelHistoryImport() => importing?.Cancel();

    /// <summary>The app's Last.fm API account: the key in the preferences, the secret encrypted.</summary>
    public string ApiKey
    {
        get => apiKey;
        set
        {
            if (!Set(ref apiKey, value)) return;
            model.Preferences.Set(ApiKeyKey, value.Trim());
            OnPropertyChanged(nameof(HasCredentials));
        }
    }

    public string Secret
    {
        get => secrets.GetValueOrDefault("secret", "");
        set
        {
            if (Secret == value) return;
            SetSecret("secret", value.Trim());
            OnPropertyChanged();
            OnPropertyChanged(nameof(HasCredentials));
        }
    }

    private string? SessionKey => secrets.GetValueOrDefault("session");
    public bool IsConnected => SessionKey is not null;
    public bool HasCredentials => ApiKey.Trim().Length > 0 && Secret.Trim().Length > 0;

    public string? ProfileUrl => Username is { } name ? "https://www.last.fm/user/" + Uri.EscapeDataString(name) : null;

    private LastFmClient? Client()
    {
        if (!HasCredentials) return null;
        var version = typeof(LastFmStore).Assembly.GetName().Version?.ToString(3) ?? "1.0";
        return new LastFmClient(new LastFmCredentials(ApiKey.Trim(), Secret.Trim()), SessionKey, identity: new ClientIdentity(version));
    }

    // MARK: Account

    /// <summary>Opens Last.fm in the browser to allow Groovelight, then waits (up to 5 minutes) for the user to do it.</summary>
    public async void Connect()
    {
        if (Client() is not { } client)
        {
            Problem = "Enter the API key and secret of your Last.fm API account first.";
            return;
        }
        connecting?.Cancel();
        var cancel = connecting = new CancellationTokenSource();
        IsConnecting = true;
        Problem = null;
        try
        {
            var token = await client.GetTokenAsync();
            AppModel.OpenUrl(client.AuthorizationUrl(token).ToString());
            for (var attempt = 0; attempt < 100; attempt++)
            {
                await Task.Delay(TimeSpan.FromSeconds(3), cancel.Token);
                try
                {
                    var (name, key) = await client.GetSessionAsync(token);
                    SetSecret("session", key);
                    model.Preferences.Set(UsernameKey, name);
                    Username = name;
                    OnPropertyChanged(nameof(IsConnected));
                    SendSoon(0);
                    return;
                }
                catch (LastFmException error) when (error.IsUnauthorizedToken)
                {
                }
            }
            Problem = "Last.fm was not allowed in time. Try connecting again.";
        }
        catch (OperationCanceledException) when (cancel.IsCancellationRequested)
        {
        }
        catch (LastFmException error)
        {
            Problem = error.Describe();
        }
        finally
        {
            if (connecting == cancel)
            {
                IsConnecting = false;
                connecting = null;
            }
        }
    }

    public void CancelConnecting()
    {
        connecting?.Cancel();
        connecting = null;
        IsConnecting = false;
    }

    public void Disconnect()
    {
        SetSecret("session", null);
        model.Preferences.Remove(UsernameKey);
        Username = null;
        OnPropertyChanged(nameof(IsConnected));
    }

    // MARK: Listening

    private bool Wants(string key) => IsConnected && model.Preferences.Bool(key, true);

    /// <summary>A song started: tells Last.fm it is playing now, and remembers when it started (the scrobble's time).</summary>
    private async void Started(PlayableItem item)
    {
        current = (item.Id, DateTime.UtcNow, null);
        var track = await Task.Run(() => model.Database.Read(db => db.TracksWithIds([item.Id]).FirstOrDefault()));
        if (current?.Id != item.Id) return;
        current = current.Value with { Track = track };
        if (!Wants(NowPlayingKey) || Client() is not { } client || Song(item, track) is not { } song) return;
        try
        {
            await client.UpdateNowPlayingAsync(song);
        }
        catch (LastFmException)
        {
            // "Now playing" is best effort; scrobbles go through the queue.
        }
    }

    /// <summary>A song ended (finished, skipped or stopped): queues a scrobble when it was played long enough.</summary>
    private void Finished(PlayableItem item, double listened)
    {
        var playing = current?.Id == item.Id ? current : null;
        if (playing is not null) current = null;
        if (!Wants(ScrobbleKey) || !ScrobbleRules.IsEligible(item.Duration, listened) || Song(item, playing?.Track) is not { } song) return;
        var startedAt = playing?.StartedAt ?? DateTime.UtcNow.AddSeconds(-listened);
        Enqueue(LastFmKind.Scrobble, song, startedAt);
        SendSoon();
    }

    /// <summary>
    /// Songs played on a phone, as they reach the PC: queued as scrobbles with the time each started. Last.fm refuses
    /// scrobbles older than two weeks, so those are only counted in the library. Loves made there go to Last.fm too.
    /// </summary>
    private async void PlayedElsewhere(DeviceHistoryChanges changes)
    {
        foreach (var group in changes.Loves.GroupBy(love => love.Loved))
            LovedChanged(group.Select(love => love.TrackId).ToList(), group.Key);
        if (changes.Plays.Count == 0 || !Wants(ScrobbleKey)) return;
        var plays = changes.Plays.ToList();
        var tracks = await Task.Run(() => model.Database.Read(db => db.TracksWithIds(plays.Select(play => play.TrackId).Distinct())));
        var byId = tracks.Where(track => track.Id is not null).GroupBy(track => track.Id!.Value).ToDictionary(group => group.Key, group => group.First());
        var oldest = DateTime.UtcNow.AddDays(-14);
        foreach (var play in plays)
        {
            if (play.StartedAt.ToUniversalTime() <= oldest || !byId.TryGetValue(play.TrackId, out var track)) continue;
            if (!ScrobbleRules.IsEligible(track.Duration, play.Listened) || Song(track) is not { } song) continue;
            Enqueue(LastFmKind.Scrobble, song, play.StartedAt.ToUniversalTime());
        }
        SendSoon();
    }

    /// <summary>Songs were loved or unloved in the library: the same on Last.fm.</summary>
    private async void LovedChanged(IReadOnlyList<long> trackIds, bool loved)
    {
        if (!Wants(SyncLovesKey) || trackIds.Count == 0) return;
        var tracks = await Task.Run(() => model.Database.Read(db => db.TracksWithIds(trackIds)));
        foreach (var track in tracks)
        {
            if ((Trimmed(track.Artist) ?? Trimmed(track.AlbumArtist)) is not { } artist) continue;
            model.Database.EnqueueLastFm(new LastFmQueueItem { Kind = loved ? LastFmKind.Love : LastFmKind.Unlove, Artist = artist, Track = track.Title, Timestamp = DateTime.UtcNow });
        }
        SendSoon();
    }

    private void Enqueue(LastFmKind kind, LastFmTrack song, DateTime timestamp) =>
        model.Database.EnqueueLastFm(new LastFmQueueItem
        {
            Kind = kind, Artist = song.Artist, Track = song.Track, Album = song.Album, AlbumArtist = song.AlbumArtist, Duration = song.Duration,
            TrackNumber = song.TrackNumber, Timestamp = timestamp,
        });

    /// <summary>Sends what is waiting now (Settings, Send Now).</summary>
    public void SendNow() => SendSoon(0);

    /// <summary>Sends the queue after a moment (so a burst of loves goes out together); one send at a time.</summary>
    private async void SendSoon(double delay = 2)
    {
        if (sendScheduled || IsSending || !IsConnected || Client() is null) return;
        sendScheduled = true;
        if (delay > 0) await Task.Delay(TimeSpan.FromSeconds(delay));
        sendScheduled = false;
        if (Client() is not { } client) return;
        IsSending = true;
        var outcome = await sender.SendAsync(client);
        IsSending = false;
        switch (outcome)
        {
            case LastFmSender.Outcome.Sent sent:
                Problem = null;
                if (sent.Scrobbles + sent.Loves > 0)
                {
                    LastSentAt = DateTime.UtcNow;
                    model.Preferences.Set(LastSentAtKey, LastSentAt);
                }
                break;
            case LastFmSender.Outcome.Postponed postponed:
                Problem = postponed.Reason + ". Waiting items are sent later.";
                break;
            case LastFmSender.Outcome.NeedsReconnect reconnect:
                Problem = reconnect.Reason + ". Connect to Last.fm again.";
                Disconnect();
                break;
        }
    }

    // MARK: Songs

    private static string? Trimmed(string? text) => string.IsNullOrWhiteSpace(text) ? null : text.Trim();

    /// <summary>The song as Last.fm names it (null without an artist: Last.fm would refuse it).</summary>
    private static LastFmTrack? Song(Track track)
    {
        var artist = Trimmed(track.Artist) ?? Trimmed(track.AlbumArtist);
        if (artist is null or "Unknown Artist" || Trimmed(track.Title) is not { } title) return null;
        var album = Trimmed(track.Album);
        return new LastFmTrack(artist, title, album == "Unknown Album" ? null : album, Trimmed(track.AlbumArtist), track.Duration > 0 ? track.Duration : null, track.TrackNumber);
    }

    private static LastFmTrack? Song(PlayableItem item, Track? track)
    {
        var artist = Trimmed(track?.Artist) ?? Trimmed(item.Artist) ?? Trimmed(track?.AlbumArtist);
        if (artist is null or "Unknown Artist" || Trimmed(track?.Title ?? item.Title) is not { } title) return null;
        var album = Trimmed(track?.Album) ?? Trimmed(item.Album);
        return new LastFmTrack(artist, title, album == "Unknown Album" ? null : album, Trimmed(track?.AlbumArtist), item.Duration > 0 ? item.Duration : null, track?.TrackNumber);
    }

    // MARK: Secrets

    private Dictionary<string, string> LoadSecrets()
    {
        try
        {
            if (!File.Exists(secretsFile)) return [];
            var data = File.ReadAllBytes(secretsFile);
            if (OperatingSystem.IsWindows()) data = ProtectedData.Unprotect(data, null, DataProtectionScope.CurrentUser);
            return JsonSerializer.Deserialize<Dictionary<string, string>>(data) ?? [];
        }
        catch (Exception error) when (error is IOException or CryptographicException or JsonException or UnauthorizedAccessException) { return []; }
    }

    private void SetSecret(string name, string? value)
    {
        if (string.IsNullOrEmpty(value)) secrets.Remove(name);
        else secrets[name] = value;
        try
        {
            var data = JsonSerializer.SerializeToUtf8Bytes(secrets);
            if (OperatingSystem.IsWindows()) data = ProtectedData.Protect(data, null, DataProtectionScope.CurrentUser);
            File.WriteAllBytes(secretsFile, data);
        }
        catch (Exception error) when (error is IOException or CryptographicException or UnauthorizedAccessException)
        {
            Problem = "Could not save the Last.fm details: " + error.Message;
        }
    }
}
