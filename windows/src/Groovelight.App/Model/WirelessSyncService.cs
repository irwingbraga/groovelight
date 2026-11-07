using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using Groovelight.Audio;
using Groovelight.Core;
using Groovelight.Core.Devices;
using Groovelight.Core.Library;
using Groovelight.Wireless;

namespace Groovelight.Model;

/// <summary>
/// Wireless sync with the Groovelight apps on Android and iOS (the Mac's WirelessSyncService): this PC serves on the
/// local network and advertises itself (DNS-SD <c>_groovelight._tcp</c>), devices pair once (a code shown on both
/// screens) and then pull their music, play on this PC, or on each other through it. Paired devices appear under
/// Devices with the same page as memory cards.
/// </summary>
public sealed class WirelessSyncService : Support.Observable, IWirelessBackend
{
    /// <summary>A paired device, saved under "devices.wireless.paired" (its key apart, encrypted for this Windows user).</summary>
    public sealed record PairedDevice
    {
        public string Id { get; set; } = "";
        public string Name { get; set; } = "";
        public string? Model { get; set; }
        public DateTime PairedAt { get; set; }
        public DateTime? LastSeen { get; set; }
        public long Capacity { get; set; }
        public long Available { get; set; }
        public DateTime? LastSyncAt { get; set; }
        public string? LastResult { get; set; }
        public List<WirelessProtocol.Volume>? Volumes { get; set; }
        /// <summary>"player" when Groovelight plays the music on the device, "sync" when another app does.</summary>
        public string? Mode { get; set; }
        public bool? ControlsPlayback { get; set; }
        public bool? ConnectsAway { get; set; }

        [System.Text.Json.Serialization.JsonIgnore] public bool IsPlayer => Mode == "player";
    }

    /// <summary>A device asking to pair, with its code.</summary>
    public sealed record PairingPrompt(WirelessProtocol.PairRequest Request, string Code);

    /// <summary>A "Send to" waiting for the device to connect.</summary>
    public sealed record PendingSend
    {
        public List<long> TrackIds { get; init; } = [];
        public string? AlbumKey { get; init; }
        public long? PlaylistId { get; init; }
        public bool LovedSongs { get; init; }
    }

    public const string EnabledKey = "devices.wireless.enabled";
    public const int DefaultPort = 52_300;
    private readonly AppModel model;
    private readonly string keysFile;
    private readonly Dictionary<string, (WirelessProtocol.PairRequest Request, WirelessProtocol.Pairing Pairing, string Status)> pairings = [];
    private readonly Dictionary<string, WirelessProtocol.SyncRequest> lastRequests = [];
    private readonly Dictionary<string, (int Done, int Total)> progress = [];
    private readonly HashSet<string> syncRequested = [];
    private Dictionary<string, string> keys;
    private List<PairedDevice> paired;
    private WirelessSyncServer? server;
    private DnsServiceAdvertiser? advertiser;
    private bool isEnabled;
    private int? port;

    public WirelessSyncService(AppModel model)
    {
        this.model = model;
        keysFile = Path.Combine(model.DataDirectory, "Wireless Keys.bin");
        HostId = model.Preferences.String("devices.wireless.macId") ?? Guid.NewGuid().ToString().ToUpperInvariant();
        model.Preferences.Set("devices.wireless.macId", HostId);
        paired = model.Preferences.Data("devices.wireless.paired") is { } data ? SwiftJson.Decode<List<PairedDevice>>(data) ?? [] : [];
        keys = LoadKeys();
        isEnabled = model.Preferences.Bool(EnabledKey);
        // Conversions left by a sync that did not finish.
        model.Conversions.Prune([]);
        if (isEnabled) Start();
    }

    /// <summary>This PC's id for devices (stable across launches).</summary>
    public string HostId { get; }
    public static string HostName => Environment.MachineName;

    public bool IsEnabled
    {
        get => isEnabled;
        set
        {
            if (!Set(ref isEnabled, value)) return;
            model.Preferences.Set(EnabledKey, value);
            if (value) Start();
            else Stop();
            model.Devices.Refresh();
        }
    }

    public int? Port { get => port; private set => Set(ref port, value); }
    public IReadOnlyList<PairedDevice> Paired => paired;
    public event Action<PairingPrompt>? PairingRequested;

    public WirelessProtocol.SyncRequest? LastRequest(string id) => lastRequests.GetValueOrDefault(id);

    /// <summary>Whether a device checked in lately (an open app checks every few seconds; a background sync every 15 minutes).</summary>
    public bool IsOnline(PairedDevice device) => device.LastSeen is { } seen && DateTime.UtcNow - seen < TimeSpan.FromMinutes(2);

    /// <summary>This PC's local network addresses (IPv4), for typing into the app when discovery is blocked.</summary>
    public static List<string> Addresses() => NetworkInterface.GetAllNetworkInterfaces()
        .Where(item => item.OperationalStatus == OperationalStatus.Up && item.NetworkInterfaceType is NetworkInterfaceType.Ethernet or NetworkInterfaceType.Wireless80211)
        .SelectMany(item => item.GetIPProperties().UnicastAddresses).Where(address => address.Address.AddressFamily == AddressFamily.InterNetwork)
        .Select(address => address.Address.ToString()).Where(address => !address.StartsWith("169.254.", StringComparison.Ordinal)).Distinct().ToList();

    /// <summary>Whether Windows calls the current network Public, where it blocks discovery and connections from other devices.</summary>
    public static bool IsOnPublicNetwork()
    {
        if (!OperatingSystem.IsWindows()) return false;
        try
        {
            var type = Type.GetTypeFromCLSID(new Guid("DCB00C01-570F-4A9B-8D69-199FDBA5723B"));
            dynamic? manager = type is null ? null : Activator.CreateInstance(type);
            if (manager is null) return false;
            foreach (dynamic network in manager.GetNetworks(1))
            {
                // NLM_NETWORK_CATEGORY: 0 public, 1 private, 2 domain.
                if ((int)network.GetCategory() == 0) return true;
            }
        }
        catch (Exception error) when (error is COMException or InvalidCastException or Microsoft.CSharp.RuntimeBinder.RuntimeBinderException) { }
        return false;
    }

    // MARK: Server

    private void Start()
    {
        if (server is not null) return;
        server = new WirelessSyncServer(this);
        (System.Security.Cryptography.X509Certificates.X509Certificate2, string)? identity = null;
        try { identity = TlsIdentity.Load(Path.Combine(model.DataDirectory, "Wireless Identity.pfx")); }
        catch (CryptographicException error) { CrashLog.Write(error, "wireless identity"); }
        // A fixed port is easier to allow through firewalls (HTTPS on the next one); others when it is taken.
        Port = server.Start(DefaultPort, identity);
        if (Port is not { } bound)
        {
            CrashLog.Write(null, $"wireless sync could not listen on port {DefaultPort} or any other");
            return;
        }
        advertiser = new DnsServiceAdvertiser();
        var txt = new Dictionary<string, string> { ["id"] = HostId, ["v"] = WirelessProtocol.Version.ToString(), ["platform"] = "windows" };
        if (server.TlsPort is { } tls) txt["tls"] = tls.ToString();
        advertiser.Register($"Groovelight on {HostName}", WirelessProtocol.ServiceType, bound, txt);
    }

    private void Stop()
    {
        advertiser?.Dispose();
        advertiser = null;
        server?.Stop();
        server = null;
        Port = null;
    }

    public void Shutdown() => Stop();

    // MARK: Keys

    private Dictionary<string, string> LoadKeys()
    {
        try
        {
            if (!File.Exists(keysFile)) return [];
            var data = File.ReadAllBytes(keysFile);
            if (OperatingSystem.IsWindows()) data = ProtectedData.Unprotect(data, null, DataProtectionScope.CurrentUser);
            return JsonSerializer.Deserialize<Dictionary<string, string>>(data) ?? [];
        }
        catch (Exception error) when (error is IOException or CryptographicException or JsonException) { return []; }
    }

    private void SaveKeys()
    {
        var data = JsonSerializer.SerializeToUtf8Bytes(keys);
        if (OperatingSystem.IsWindows()) data = ProtectedData.Protect(data, null, DataProtectionScope.CurrentUser);
        File.WriteAllBytes(keysFile, data);
    }

    private void Save() => model.Preferences.Set("devices.wireless.paired", SwiftJson.Encode(paired));

    /// <summary>Runs <paramref name="work"/> on the UI thread (the model lives there) and returns its result.</summary>
    private Task<T> OnMain<T>(Func<T> work)
    {
        var done = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!model.Queue.TryEnqueue(() =>
        {
            try { done.SetResult(work()); }
            catch (Exception error) { done.SetException(error); }
        })) done.SetException(new InvalidOperationException("The app is closing."));
        return done.Task;
    }

    // MARK: IWirelessBackend

    public WirelessProtocol.Info Info() => new(HostId, HostName);

    public Task PairRequested(WirelessProtocol.PairRequest request, WirelessProtocol.Pairing pairing) => OnMain(() =>
    {
        pairings[request.DeviceId] = (request, pairing, "pending");
        PairingRequested?.Invoke(new PairingPrompt(request, pairing.Code));
        return true;
    });

    public Task<string> PairStatus(string deviceId) => OnMain(() =>
        pairings.TryGetValue(deviceId, out var pending) ? pending.Status : keys.ContainsKey(deviceId) ? "accepted" : "rejected");

    public void AnswerPairing(PairingPrompt prompt, bool allow)
    {
        if (!pairings.TryGetValue(prompt.Request.DeviceId, out var pending)) return;
        pairings[prompt.Request.DeviceId] = pending with { Status = allow ? "accepted" : "rejected" };
        if (!allow) return;
        var id = prompt.Request.DeviceId;
        keys[id] = Convert.ToBase64String(pending.Pairing.Key);
        SaveKeys();
        paired.RemoveAll(device => device.Id == id);
        paired.Add(new PairedDevice { Id = id, Name = prompt.Request.Name, Model = prompt.Request.Model, PairedAt = DateTime.UtcNow, LastSeen = DateTime.UtcNow });
        Save();
        OnPropertyChanged(nameof(Paired));
        model.Devices.Refresh();
    }

    public void Unpair(string id)
    {
        paired.RemoveAll(device => device.Id == id);
        keys.Remove(id);
        SaveKeys();
        model.Preferences.Remove($"devices.wireless.{id}.sends");
        Save();
        OnPropertyChanged(nameof(Paired));
        model.Devices.Refresh();
    }

    public Task<byte[]?> Key(string deviceId) => OnMain(() =>
    {
        if (!keys.TryGetValue(deviceId, out var key) || paired.All(device => device.Id != deviceId)) return null;
        Touch(deviceId);
        return (byte[]?)Convert.FromBase64String(key);
    });

    private void Touch(string id)
    {
        if (paired.FirstOrDefault(device => device.Id == id) is not { } device) return;
        var wasOnline = IsOnline(device);
        device.LastSeen = DateTime.UtcNow;
        if (!wasOnline)
        {
            Save();
            model.Devices.Refresh();
        }
    }

    public byte[]? Cover(string hash, int size) => model.Artwork.Jpeg(hash, size);

    public string Converted(ConversionSource source, string fingerprint) => model.Conversions.Converted(source, fingerprint);

    public void FileServed(string deviceId, int index, int count) => model.Queue.TryEnqueue(() =>
    {
        progress[deviceId] = (index + 1, count);
        model.Devices.WirelessProgress(DeviceStore.WirelessId(deviceId), index + 1, count);
    });

    public Task<WirelessProtocol.Status> Status(string deviceId) => OnMain(() =>
        new WirelessProtocol.Status(syncRequested.Contains(deviceId), PendingSends(deviceId).Count));

    public void RequestSync(string id) => syncRequested.Add(id);
    public void CancelRequest(string id) => syncRequested.Remove(id);

    public void Send(SongSource source, string id)
    {
        var send = source switch
        {
            SongSource.Tracks tracks => new PendingSend { TrackIds = tracks.Items.Select(track => track.Id ?? -1).ToList() },
            SongSource.Album album => new PendingSend { AlbumKey = album.AlbumKey },
            SongSource.Playlist playlist => new PendingSend { PlaylistId = playlist.Id },
            _ => new PendingSend { LovedSongs = true },
        };
        var sends = PendingSends(id);
        sends.Add(send);
        model.Preferences.Set($"devices.wireless.{id}.sends", SwiftJson.Encode(sends));
    }

    public List<PendingSend> PendingSends(string id) =>
        model.Preferences.Data($"devices.wireless.{id}.sends") is { } data ? SwiftJson.Decode<List<PendingSend>>(data) ?? [] : [];

    public async Task<(DeviceSyncPlan Plan, DeviceProfile Profile)> Plan(string id, WirelessProtocol.SyncRequest request)
    {
        var deviceId = DeviceStore.WirelessId(id);
        var (selection, profile, sends) = await OnMain(() =>
        {
            lastRequests[id] = request;
            if (paired.FirstOrDefault(device => device.Id == id) is { } device)
            {
                device.Capacity = request.Capacity;
                device.Available = request.Available;
                if (request.Volumes is { } volumes) device.Volumes = volumes;
                device.Mode = request.Mode ?? "sync";
                Save();
            }
            syncRequested.Remove(id);
            progress[id] = (0, 0);
            // A format chosen on the device is this device's from now on.
            if (request.Encoding is { } chosen && (chosen == "original" || LossyEncodings.Parse(chosen) is not null))
            {
                var encoding = LossyEncodings.Parse(chosen);
                if (encoding != model.Devices.Encoding(deviceId)) model.Devices.SetEncoding(encoding, deviceId);
            }
            return (model.Devices.Selection(deviceId), model.Devices.Profile(deviceId), PendingSends(id));
        });
        // A player gets the songs only: covers, lyrics and playlists come with the library snapshot.
        var player = request.IsPlayer ? new DevicePlayer((request.Decodes ?? []).ToHashSet()) : null;
        if (player is not null) profile = profile with { WritesCovers = false, WritesLyrics = false, WritesPlaylists = false };
        var plan = await Task.Run(() =>
        {
            var (syncing, sending) = model.Database.Read(db => (db.DeviceContents(selection), Contents(db, sends)));
            var files = request.Files.Select(file => file.ToLowerInvariant()).ToHashSet();
            bool Existing(string path) => files.Contains(path.ToLowerInvariant());
            var manifest = request.Manifest ?? new DeviceManifest();
            var root = Path.Combine(Path.GetTempPath(), "device");
            LossyEncoding? Formats(Track track) => selection.Encoding(track, profile.Encoding);
            // Nothing chosen to sync: only what was sent, and nothing is removed.
            return selection.IsEmpty
                ? DeviceSync.Plan(sending.Tracks, sending.Playlists, profile, manifest, DeviceSyncMode.Send, root, false, player, selection.ExcludedTrackIds, Formats, Existing)
                : DeviceSync.Plan((syncing.Tracks, syncing.Playlists), (sending.Tracks, sending.Playlists), profile, manifest, root, Existing, false, player,
                    selection.ExcludedTrackIds, Formats);
        });
        await OnMain(() =>
        {
            // Sent songs are in this plan now.
            model.Preferences.Remove($"devices.wireless.{id}.sends");
            model.Devices.WirelessSyncStarted(deviceId, plan.Writes.Count);
            return true;
        });
        return (plan, profile);
    }

    private static (List<Track> Tracks, List<DevicePlaylist> Playlists) Contents(Microsoft.Data.Sqlite.SqliteConnection db, IReadOnlyList<PendingSend> sends)
    {
        var tracks = new List<Track>();
        var playlists = new List<DevicePlaylist>();
        foreach (var send in sends)
        {
            SongSource source = send.AlbumKey is { } key ? new SongSource.Album(key) : send.PlaylistId is { } playlist ? new SongSource.Playlist(playlist)
                : send.LovedSongs ? new SongSource.LovedSongs() : new SongSource.Tracks(db.TracksWithIds(send.TrackIds));
            var (more, lists) = source.Contents(db);
            tracks.AddRange(more);
            playlists.AddRange(lists);
        }
        return (tracks, playlists);
    }

    public Task Finished(string id, WirelessProtocol.SyncResult result) => OnMain(() =>
    {
        progress.Remove(id);
        // The device has its converted songs: free the space (unless another device is syncing now).
        if (progress.Count == 0) _ = Task.Run(() => model.Conversions.Prune([]));
        var summary = result.Written == 0 && result.Deleted == 0 ? "Already up to date." : $"Copied {result.Written}, removed {result.Deleted}.";
        if (result.Failed.Count > 0) summary += $" {result.Failed.Count} could not be written.";
        if (paired.FirstOrDefault(device => device.Id == id) is { } device)
        {
            device.LastSyncAt = DateTime.UtcNow;
            device.LastResult = summary;
            if (result.Available is { } available) device.Available = available;
            Save();
        }
        model.Devices.WirelessSyncFinished(DeviceStore.WirelessId(id), summary, result.Failed);
        return true;
    });

    public async Task<byte[]> Snapshot(string deviceId, Dictionary<long, string> paths, Dictionary<long, string> codecs)
    {
        var equalizer = await OnMain(SnapshotEqualizer);
        return await Task.Run(() => WireJson.Encode(model.Database.Read(db => DeviceSnapshot.Build(db, paths, codecs, equalizer))));
    }

    /// <summary>The equalizer's saved presets and current curve, for the device to offer.</summary>
    private DeviceSnapshot.Equalizer SnapshotEqualizer()
    {
        static DeviceSnapshot.EqPreset Preset(EQPreset preset) => new(preset.Name, preset.Preamp, preset.Bands.Select(band =>
            new DeviceSnapshot.EqBand(band.IsEnabled, JsonNamingPolicy.CamelCase.ConvertName(band.Type.ToString()), band.Frequency, band.Gain, band.Q)).ToList());
        var store = model.Equalizer;
        return new DeviceSnapshot.Equalizer(store.UserPresets.Select(Preset).ToList(), Preset(store.Preset), store.IsEnabled);
    }

    public async Task<byte[]> Catalog(string id)
    {
        var deviceId = DeviceStore.WirelessId(id);
        var (selection, encoding) = await OnMain(() => (model.Devices.Selection(deviceId), model.Devices.Encoding(deviceId)));
        return await Task.Run(() => WireJson.Encode(model.Database.Read(db => DeviceCatalog.Build(db, selection, encoding))));
    }

    /// <summary>Albums, artists and songs the phone asked for (or to remove): its selection changes, and it syncs next.</summary>
    public Task<DeviceCatalog.ChosenSet> Requests(string id, List<TransferRequest> requests) => OnMain(() =>
    {
        var deviceId = DeviceStore.WirelessId(id);
        var selection = model.Devices.Selection(deviceId).Applying(requests, (kind, key) => model.Database.Read(db => db.TrackIdsOf(kind, key)));
        model.Devices.SetSelection(selection, deviceId);
        return DeviceCatalog.ChosenSet.Of(selection);
    });

    /// <summary>Loves, ratings, plays, skips and playlist edits from the phone: into the library (and to Last.fm).</summary>
    public async Task History(string id, List<DeviceHistoryEvent> events)
    {
        var changes = await Task.Run(() => model.Database.ApplyDeviceHistory(events, DeviceStore.WirelessId(id)));
        await OnMain(() =>
        {
            HistoryApplied?.Invoke(changes);
            return true;
        });
    }

    /// <summary>A device's history changed loves and counted plays (Last.fm listens).</summary>
    public event Action<DeviceHistoryChanges>? HistoryApplied;

    public async Task<string?> Lyrics(long trackId)
    {
        var track = await Task.Run(() => model.Database.Read(db => db.FetchTrack(trackId)));
        if (track is null) return null;
        if (track.DisplayLyrics() is { } lyrics) return lyrics;
        if (!await OnMain(() => model.Metadata.EnsureLyricsAsync(track)).Unwrap()) return null;
        return (await Task.Run(() => model.Database.Read(db => db.FetchTrack(trackId))))?.DisplayLyrics();
    }

    // MARK: Away from home, and playing on this PC from a device

    public bool ConnectsAway(string id) => paired.FirstOrDefault(device => device.Id == id)?.ConnectsAway == true;

    public void SetConnectsAway(string id, bool allowed)
    {
        if (paired.FirstOrDefault(device => device.Id == id) is not { } device) return;
        device.ConnectsAway = allowed;
        Save();
    }

    /// <summary>This PC's Tailscale address, when Tailscale is on.</summary>
    public static string? AwayAddress => AwayNetwork.Addresses().FirstOrDefault();

    public bool ControlsPlaybackOf(string id) => paired.FirstOrDefault(device => device.Id == id)?.ControlsPlayback == true;

    public void SetControlsPlayback(string id, bool allowed)
    {
        if (paired.FirstOrDefault(device => device.Id == id) is not { } device) return;
        device.ControlsPlayback = allowed;
        Save();
    }

    public Task<bool> MayControl(string deviceId) => OnMain(() => ControlsPlaybackOf(deviceId));
    public Task<bool> MayConnectAway(string deviceId) => OnMain(() => ConnectsAway(deviceId));
    public Task<string?> DeviceName(string deviceId) => OnMain(() => paired.FirstOrDefault(device => device.Id == deviceId)?.Name);

    public Task<WirelessProtocol.RemoteState?> RemoteState(string deviceId) => OnMain(() => State(deviceId));

    /// <summary>The player as the device shows it, when the device may control it.</summary>
    private WirelessProtocol.RemoteState? State(string id)
    {
        if (!ControlsPlaybackOf(id)) return null;
        var player = model.Player;
        WirelessProtocol.RemoteItem? item = null;
        if (player.Current is { } current)
        {
            var track = model.Database.Read(db => db.FetchTrack(current.Id));
            item = new WirelessProtocol.RemoteItem(current.Id, current.Title, current.Artist, current.Album, current.AlbumKey, track?.ArtworkHash ?? current.ArtworkHash,
                current.Duration, track?.IsLoved);
        }
        return new WirelessProtocol.RemoteState
        {
            Item = item, Playing = player.State == PlaybackState.Playing, Position = player.EstimatedTime(DateTime.UtcNow), Rate = player.Rate, Volume = player.Volume,
            Shuffle = player.IsShuffled, RepeatMode = player.RepeatMode.ToString().ToLowerInvariant(), Queue = player.Queue.Items.Take(5000).Select(entry => entry.Id).ToList(),
            QueueIndex = player.Queue.CurrentIndex,
        };
    }

    public Task<WirelessProtocol.RemoteState?> Remote(string deviceId, RemoteCommand command) => OnMain(() =>
    {
        if (!ControlsPlaybackOf(deviceId)) return null;
        var player = model.Player;
        switch (command)
        {
            case RemoteCommand.Play play:
                // The device's queue, with the songs this PC has.
                var tracks = model.Database.Read(db => db.TracksWithIds(play.SongIds)).ToDictionary(track => track.Id ?? -1);
                var ordered = play.SongIds.Select(id => tracks.GetValueOrDefault(id)).OfType<Track>().ToList();
                var start = play.StartAt >= 0 && play.StartAt < play.SongIds.Count ? Math.Max(0, ordered.FindIndex(track => track.Id == play.SongIds[play.StartAt])) : 0;
                model.Play(ordered, start, play.Shuffle, play.Position > 1 ? play.Position : 0);
                break;
            case RemoteCommand.Pause: player.Pause(); break;
            case RemoteCommand.Resume:
                if (player.State == PlaybackState.Stopped) player.TogglePlayPause();
                else player.Resume();
                break;
            case RemoteCommand.Next: player.Next(); break;
            case RemoteCommand.Previous: player.Previous(); break;
            case RemoteCommand.Seek seek: player.Seek(seek.Position); break;
            case RemoteCommand.SetVolume volume: player.Volume = (float)Math.Clamp(volume.Volume, 0, 1); break;
            case RemoteCommand.SetShuffle shuffle: player.SetShuffle(shuffle.On); break;
            case RemoteCommand.SetRepeat repeat:
                if (Enum.TryParse<RepeatMode>(repeat.Mode, true, out var mode)) player.RepeatMode = mode;
                break;
            case RemoteCommand.Stop: player.Stop(); break;
        }
        return State(deviceId);
    });
}

/// <summary>Advertises the server with Windows' own DNS-SD (<c>DnsServiceRegister</c>, Windows 10 and later).</summary>
public sealed class DnsServiceAdvertiser : IDisposable
{
    [StructLayout(LayoutKind.Sequential)]
    private struct RegisterRequest
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr ServiceInstance;
        public IntPtr Callback;
        public IntPtr Context;
        public IntPtr Credentials;
        public int UnicastEnabled;
    }

    private delegate void Completion(uint status, IntPtr context, IntPtr instance);

    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr DnsServiceConstructInstance(string serviceName, string hostName, IntPtr ip4, IntPtr ip6, ushort port, ushort priority, ushort weight,
                                                             uint propertiesCount, string[] keys, string[] values);

    [DllImport("dnsapi.dll")]
    private static extern uint DnsServiceRegister(ref RegisterRequest request, IntPtr cancel);

    [DllImport("dnsapi.dll")]
    private static extern uint DnsServiceDeRegister(ref RegisterRequest request, IntPtr cancel);

    [DllImport("dnsapi.dll")]
    private static extern void DnsServiceFreeInstance(IntPtr instance);

    private const uint RequestPending = 9506;
    private RegisterRequest request;
    private readonly Completion completion = (_, _, instance) => { if (instance != IntPtr.Zero) DnsServiceFreeInstance(instance); };
    private bool registered;

    public void Register(string name, string type, int port, IReadOnlyDictionary<string, string> txt)
    {
        if (!OperatingSystem.IsWindows()) return;
        try
        {
            var host = Environment.MachineName + ".local";
            var instance = DnsServiceConstructInstance($"{name}.{type}.local", host, IntPtr.Zero, IntPtr.Zero, (ushort)port, 0, 0, (uint)txt.Count,
                txt.Keys.ToArray(), txt.Values.ToArray());
            if (instance == IntPtr.Zero) return;
            request = new RegisterRequest { Version = 1, ServiceInstance = instance, Callback = Marshal.GetFunctionPointerForDelegate(completion) };
            registered = DnsServiceRegister(ref request, IntPtr.Zero) == RequestPending;
        }
        catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException) { }
    }

    public void Dispose()
    {
        if (!registered) return;
        registered = false;
        try { DnsServiceDeRegister(ref request, IntPtr.Zero); }
        catch (Exception error) when (error is DllNotFoundException or EntryPointNotFoundException) { }
    }
}
