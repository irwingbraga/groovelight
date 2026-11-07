using System.Runtime.InteropServices;
using System.Text;
using Groovelight.Core;
using Groovelight.Core.Devices;
using Groovelight.Core.Library;
using Microsoft.Data.Sqlite;
using Microsoft.UI.Dispatching;

namespace Groovelight.Model;

/// <summary>What "Send to" copies: songs, an album, a playlist (written as a playlist too), or Loved Songs.</summary>
public static class SendSources
{
    public static (List<Track> Tracks, List<DevicePlaylist> Playlists) Contents(this SongSource source, SqliteConnection db) => source switch
    {
        SongSource.Tracks tracks => (tracks.Items.ToList(), []),
        SongSource.Album album => (db.TracksOfAlbum(album.AlbumKey), []),
        SongSource.Playlist playlist => db.TracksOfPlaylist(playlist.Id) is var songs
            ? (songs, [new DevicePlaylist(db.Playlists().FirstOrDefault(item => item.Id == playlist.Id)?.Name ?? "Playlist", songs)]) : default,
        _ => db.LovedTracks() is var loved ? (loved, [new DevicePlaylist("Loved Songs", loved)]) : default,
    };
}

/// <summary>
/// Portable players and memory cards (the Mac's DeviceStore): removable drives Windows mounts (players in USB disk mode,
/// SD cards, USB sticks), and the phones paired for wireless sync. Each has a selection to sync and a format, saved in
/// the preferences under "devices." as on the Mac; the layout is shared.
/// </summary>
public sealed class DeviceStore : Support.Observable
{
    public sealed record Device
    {
        /// <summary>The volume's serial number (its label without one), so the same card is known again; "wifi:" and the id for a paired phone.</summary>
        public required string Id { get; init; }
        public required string Name { get; init; }
        public required string Root { get; init; }
        public long Capacity { get; init; }
        public long Available { get; init; }
        /// <summary>"FAT32", "exFAT", "NTFS", or "Wi-Fi · model".</summary>
        public string Format { get; init; } = "";
        public bool IsFat32 { get; init; }
        public bool IsWireless { get; init; }
        /// <summary>Groovelight plays the music (the iOS app, or the Android app in Player mode).</summary>
        public bool IsPlayer { get; init; }
        public bool IsOnline { get; init; } = true;
        public List<Wireless.WirelessProtocol.Volume> Volumes { get; init; } = [];
    }

    public enum JobPhase { Waiting, Planning, Copying, Finished, Failed }

    /// <summary>A sync, send or export in progress or just finished.</summary>
    public sealed record Job(string DeviceId, string Title, JobPhase Phase, int Done = 0, int Total = 0, string Message = "")
    {
        public bool IsRunning => Phase is JobPhase.Waiting or JobPhase.Planning or JobPhase.Copying;
    }

    /// <summary>What a sync of the current selection would do, for the device page.</summary>
    public sealed record Preview(int Songs, long BytesToWrite, int FilesToWrite, int FilesToRemove, long NetBytes, long MusicBytes, List<string> Skipped);

    public const string LayoutKey = "devices.layout";
    private readonly AppModel model;
    private readonly DispatcherQueueTimer poll;
    private volatile bool cancelled;
    private readonly Dictionary<string, CancellationTokenSource> previewTasks = [];
    private List<Device> devices = [];
    private Job? job;
    private int selectionRevision;

    public DeviceStore(AppModel model)
    {
        this.model = model;
        // Drives come and go: checked every few seconds (cheap), the list changed only when they do.
        poll = model.Queue.CreateTimer();
        poll.Interval = TimeSpan.FromSeconds(3);
        poll.Tick += (_, _) => Refresh();
        poll.Start();
    }

    public IReadOnlyList<Device> Devices { get => devices; private set => Set(ref devices, value.ToList()); }
    public Job? CurrentJob { get => job; private set => Set(ref job, value); }
    public Dictionary<string, Preview> Previews { get; } = [];
    /// <summary>Changes whenever a selection or format is set (the device page reloads when a phone changed it).</summary>
    public int SelectionRevision { get => selectionRevision; private set => Set(ref selectionRevision, value); }
    public event Action? DevicesChanged;
    public event Action<string>? PreviewChanged;

    public Device? Find(string id) => devices.FirstOrDefault(device => device.Id == id);

    public static string WirelessId(string id) => "wifi:" + id;
    public static string PairedId(Device device) => device.Id["wifi:".Length..];

    // MARK: Finding devices

    public void Refresh()
    {
        var roots = model.Database.Read(db => db.Roots()).Select(root => root.Path.TrimEnd('\\') + "\\").ToList();
        var found = new List<Device>();
        foreach (var drive in SafeDrives())
        {
            if (drive.DriveType != DriveType.Removable || !drive.IsReady) continue;
            var root = drive.RootDirectory.FullName;
            // A drive holding a library folder is the library, not a player.
            if (roots.Any(path => path.StartsWith(root, StringComparison.OrdinalIgnoreCase))) continue;
            var label = drive.VolumeLabel is { Length: > 0 } name ? name : $"Removable Drive ({root.TrimEnd('\\')})";
            found.Add(new Device
            {
                Id = VolumeSerial(root) ?? label, Name = label, Root = root, Capacity = drive.TotalSize, Available = drive.AvailableFreeSpace,
                Format = drive.DriveFormat, IsFat32 = drive.DriveFormat.Equals("FAT32", StringComparison.OrdinalIgnoreCase),
            });
        }
        found.Sort((a, b) => string.Compare(a.Name, b.Name, StringComparison.CurrentCultureIgnoreCase));
        if (model.Wireless is { IsEnabled: true } wireless)
        {
            found.AddRange(wireless.Paired.Select(paired => new Device
            {
                Id = WirelessId(paired.Id), Name = paired.Name, Root = "", Capacity = paired.Capacity, Available = paired.Available,
                Format = string.Join(" · ", new[] { "Wi-Fi", paired.Model }.Where(part => !string.IsNullOrEmpty(part))), IsWireless = true,
                IsPlayer = paired.IsPlayer, IsOnline = wireless.IsOnline(paired), Volumes = paired.Volumes ?? [],
            }));
        }
        if (!found.SequenceEqual(devices, DeviceComparer.Instance))
        {
            Devices = found;
            DevicesChanged?.Invoke();
            // A device page whose device was unplugged goes back to the library.
            if (model.Selection.Kind == PageKind.Device && found.All(device => device.Id != model.Selection.DeviceId)) model.Selection = SidebarItem.Albums;
            foreach (var device in found) UpdatePreview(device);
        }
    }

    private sealed class DeviceComparer : IEqualityComparer<Device>
    {
        public static readonly DeviceComparer Instance = new();
        public bool Equals(Device? a, Device? b) => a is not null && b is not null && a.Id == b.Id && a.Name == b.Name && a.IsOnline == b.IsOnline
            && a.IsPlayer == b.IsPlayer && Math.Abs(a.Available - b.Available) < 1024 * 1024 && a.Capacity == b.Capacity;
        public int GetHashCode(Device device) => device.Id.GetHashCode();
    }

    private static DriveInfo[] SafeDrives()
    {
        try { return DriveInfo.GetDrives(); }
        catch (IOException) { return []; }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool GetVolumeInformationW(string root, StringBuilder? name, int nameSize, out uint serial, out uint maxComponent, out uint flags,
                                                     StringBuilder? fileSystem, int fileSystemSize);

    private static string? VolumeSerial(string root) =>
        OperatingSystem.IsWindows() && GetVolumeInformationW(root, null, 0, out var serial, out _, out _, null, 0) ? serial.ToString("X8") : null;

    // MARK: Settings

    private static string Key(string id, string name) => $"devices.{id}.{name}";

    /// <summary>The layout on every device (Settings, Devices).</summary>
    public DeviceProfile Layout
    {
        get => model.Preferences.Data(LayoutKey) is { } data ? WireJson.Decode<DeviceProfile>(data) ?? new DeviceProfile() : new DeviceProfile();
        set
        {
            model.Preferences.Set(LayoutKey, WireJson.Encode(value));
            foreach (var device in devices) UpdatePreview(device);
        }
    }

    /// <summary>The layout for one device: the shared one, except that the Android app writes into the folder picked there.</summary>
    public DeviceProfile Profile(string id)
    {
        var profile = Layout with { Encoding = Encoding(id) };
        if (id.StartsWith("wifi:", StringComparison.Ordinal)) profile.MusicFolder = "";
        return profile;
    }

    /// <summary>The lossy format this device gets lossless songs in (null: as they are).</summary>
    public LossyEncoding? Encoding(string id) => LossyEncodings.Parse(model.Preferences.String(Key(id, "encoding")));

    public void SetEncoding(LossyEncoding? encoding, string id)
    {
        model.Preferences.Set(Key(id, "encoding"), encoding?.RawValue());
        SelectionRevision++;
        if (Find(id) is { } device) UpdatePreview(device);
    }

    public DeviceSelection Selection(string id) =>
        model.Preferences.Data(Key(id, "selection")) is { } data ? WireJson.Decode<DeviceSelection>(data) ?? new DeviceSelection() : new DeviceSelection();

    public void SetSelection(DeviceSelection selection, string id)
    {
        var encoded = WireJson.Encode(selection);
        if (model.Preferences.Data(Key(id, "selection")) is { } old && old.AsSpan().SequenceEqual(encoded)) return;
        model.Preferences.Set(Key(id, "selection"), encoded);
        SelectionRevision++;
        if (Find(id) is { } device) UpdatePreview(device);
    }

    // MARK: Preview

    /// <summary>Plans a sync of the current selection in the background, for the capacity bar and the Sync button.</summary>
    public void UpdatePreview(Device device)
    {
        var selection = Selection(device.Id);
        var profile = Profile(device.Id);
        Func<string, bool> existing;
        DeviceManifest manifest;
        string root;
        if (device.IsWireless)
        {
            // From what the device reported at its last sync (nothing until it has synced once).
            if (model.Wireless?.LastRequest(PairedId(device)) is not { } request) return;
            var files = request.Files.Select(file => file.ToLowerInvariant()).ToHashSet();
            existing = path => files.Contains(path.ToLowerInvariant());
            manifest = request.Manifest ?? new DeviceManifest();
            root = Path.Combine(Path.GetTempPath(), "device");
        }
        else
        {
            root = device.Root;
            existing = path => File.Exists(Path.Combine(device.Root, path.Replace('/', '\\')));
            manifest = DeviceManifest.Read(device.Root);
        }
        if (previewTasks.TryGetValue(device.Id, out var previous)) previous.Cancel();
        var cancel = new CancellationTokenSource();
        previewTasks[device.Id] = cancel;
        _ = Task.Run(async () =>
        {
            await Task.Delay(250, cancel.Token);
            var contents = model.Database.Read(db => db.DeviceContents(selection));
            var plan = DeviceSync.Plan(contents.Tracks, contents.Playlists, profile, manifest, DeviceSyncMode.Sync, root, device.IsFat32, excluded: selection.ExcludedTrackIds,
                formats: track => selection.Encoding(track, profile.Encoding), existing: existing);
            return new Preview(plan.SongCount, plan.BytesToWrite, plan.Writes.Count, plan.Deletions.Count, plan.NetBytes, manifest.MusicBytes,
                plan.Skipped.Select(item => $"{item.Title}: {item.Reason}").ToList());
        }, cancel.Token).ContinueWith(task =>
        {
            if (task.IsCompletedSuccessfully && !cancel.IsCancellationRequested) model.Queue.TryEnqueue(() =>
            {
                Previews[device.Id] = task.Result;
                PreviewChanged?.Invoke(device.Id);
            });
        }, TaskScheduler.Default);
    }

    // MARK: Wireless progress

    public void WirelessSyncStarted(string id, int files)
    {
        if (Find(id) is not { } device) return;
        CurrentJob = files == 0 ? new Job(id, $"Syncing {device.Name}", JobPhase.Finished, Message: "Already up to date.")
            : new Job(id, $"Syncing {device.Name}", JobPhase.Copying, 0, files);
    }

    public void WirelessProgress(string id, int done, int total)
    {
        if (job?.DeviceId == id) CurrentJob = job with { Phase = JobPhase.Copying, Done = done, Total = total };
    }

    public void WirelessSyncFinished(string id, string summary, IReadOnlyList<string> failed)
    {
        if (Find(id) is not { } device) return;
        CurrentJob = new Job(id, $"Syncing {device.Name}", failed.Count == 0 ? JobPhase.Finished : JobPhase.Failed,
            Message: failed.Count == 0 ? summary : summary + " " + string.Join("; ", failed.Take(3)));
        Refresh();
    }

    // MARK: Sync, send, export

    /// <summary>Makes the device hold exactly its selection.</summary>
    public void Sync(Device device)
    {
        var selection = Selection(device.Id);
        if (selection.IsEmpty)
        {
            model.ErrorMessage = $"Choose what to sync to “{device.Name}” first.";
            return;
        }
        if (device.IsWireless)
        {
            model.Wireless?.RequestSync(PairedId(device));
            CurrentJob = new Job(device.Id, $"Syncing {device.Name}", JobPhase.Waiting);
            return;
        }
        Run(device, "Syncing", DeviceSyncMode.Sync, db => db.DeviceContents(selection));
    }

    /// <summary>Songs or albums dropped on a device: they join what it holds, and it syncs.</summary>
    public void Add(IReadOnlyList<TransferRequest> requests, Device device)
    {
        if (requests.Count == 0) return;
        var selection = Selection(device.Id).Applying(requests, (kind, key) => model.Database.Read(db => db.TrackIdsOf(kind, key)));
        SetSelection(selection, device.Id);
        if (job?.IsRunning == true && !device.IsWireless)
        {
            model.ErrorMessage = $"Added to what “{device.Name}” holds. Sync it when the current copy has finished.";
            return;
        }
        Sync(device);
    }

    /// <summary>Copies songs (and a playlist) to a device, without removing anything.</summary>
    public void Send(SongSource source, Device device)
    {
        if (device.IsWireless)
        {
            model.Wireless?.Send(source, PairedId(device));
            CurrentJob = new Job(device.Id, $"Sending to {device.Name}", JobPhase.Finished, Message: $"Queued: {device.Name} gets it at its next sync.");
            return;
        }
        Run(device, "Sending", DeviceSyncMode.Send, source.Contents);
    }

    /// <summary>Copies songs to a folder (another player's folder, a card the app does not list).</summary>
    public async void Export(SongSource source)
    {
        if (await Support.Pickers.FolderAsync("Export Here") is not { } folder) return;
        var drive = new DriveInfo(Path.GetPathRoot(folder)!);
        var target = new Device
        {
            Id = "folder:" + folder, Name = Path.GetFileName(folder.TrimEnd('\\')) is { Length: > 0 } name ? name : folder, Root = folder,
            Available = drive.IsReady ? drive.AvailableFreeSpace : 0, IsFat32 = drive.IsReady && drive.DriveFormat.Equals("FAT32", StringComparison.OrdinalIgnoreCase),
        };
        Run(target, "Exporting", DeviceSyncMode.Send, source.Contents);
    }

    public void Cancel()
    {
        cancelled = true;
        // A wireless sync not started yet is simply no longer asked for.
        if (job is { Phase: JobPhase.Waiting } waiting && Find(waiting.DeviceId) is { IsWireless: true } device)
        {
            model.Wireless?.CancelRequest(PairedId(device));
            CurrentJob = null;
        }
    }

    public void DismissJob()
    {
        if (job?.IsRunning == false) CurrentJob = null;
    }

    /// <summary>Ejects a drive the way Explorer does (its Eject verb).</summary>
    public void Eject(Device device)
    {
        if (device.IsWireless || (job?.IsRunning == true && job.DeviceId == device.Id)) return;
        try
        {
            var shell = Type.GetTypeFromProgID("Shell.Application") is { } type ? Activator.CreateInstance(type) : null;
            dynamic? computer = ((dynamic?)shell)?.NameSpace(17);
            dynamic? drive = computer?.ParseName(device.Root);
            drive?.InvokeVerb("Eject");
            model.Queue.TryEnqueue(Refresh);
        }
        catch (Exception error) when (error is COMException or InvalidOperationException or Microsoft.CSharp.RuntimeBinder.RuntimeBinderException)
        {
            model.ErrorMessage = $"Could not eject “{device.Name}”: {error.Message}";
        }
    }

    private void Run(Device device, string title, DeviceSyncMode mode, Func<SqliteConnection, (List<Track> Tracks, List<DevicePlaylist> Playlists)> contents)
    {
        if (job?.IsRunning == true)
        {
            model.ErrorMessage = "Wait for the current copy to finish first.";
            return;
        }
        var isFolder = device.Id.StartsWith("folder:", StringComparison.Ordinal);
        var profile = isFolder ? new DeviceProfile() : Profile(device.Id);
        // Songs removed from the device stay off it, and their files go.
        var chosen = isFolder ? new DeviceSelection() : Selection(device.Id);
        var root = device.Root;
        cancelled = false;
        CurrentJob = new Job(device.Id, $"{title} to {device.Name}", JobPhase.Planning);
        _ = Task.Run(() =>
        {
            try
            {
                var (tracks, playlists) = model.Database.Read(contents);
                var manifest = DeviceManifest.Read(root);
                var plan = DeviceSync.Plan(tracks, playlists, profile, manifest, mode, root, device.IsFat32, excluded: chosen.ExcludedTrackIds,
                    formats: track => chosen.Encoding(track, profile.Encoding), existing: path => File.Exists(Path.Combine(root, path.Replace('/', '\\'))));
                // Room for the songs, with a little to spare for the card's own bookkeeping.
                var available = new DriveInfo(Path.GetPathRoot(root)!) is { IsReady: true } drive ? drive.AvailableFreeSpace : 0;
                if (plan.NetBytes > 0 && available > 0 && plan.NetBytes > available - 32 * 1024 * 1024)
                {
                    Update(phase: JobPhase.Failed, message: $"Not enough space: {Support.Format.Bytes(plan.NetBytes)} needed, {Support.Format.Bytes(available)} free.");
                    return;
                }
                Update(phase: JobPhase.Copying, done: 0, total: plan.Writes.Count);
                DeviceSync.Run(plan, root, profile, manifest, (hash, size) => model.Artwork.Jpeg(hash, size),
                    (done, total) => Update(phase: JobPhase.Copying, done: done, total: total), () => cancelled, model.Conversions);
                Update(phase: JobPhase.Finished, message: Summary(plan, cancelled));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or ConversionException or SqliteException)
            {
                Update(phase: JobPhase.Failed, message: error.Message);
            }
            model.Queue.TryEnqueue(Refresh);
        });

        void Update(JobPhase phase, int done = 0, int total = 0, string message = "") =>
            model.Queue.TryEnqueue(() => CurrentJob = (job ?? new Job(device.Id, title, phase)) with { Phase = phase, Done = done, Total = total, Message = message });
    }

    private static string Summary(DeviceSyncPlan plan, bool cancelled)
    {
        var parts = new List<string>();
        if (cancelled) parts.Add("Stopped.");
        static string Files(int count) => $"{count} {(count == 1 ? "file" : "files")}";
        if (plan.IsEmpty) parts.Add("Already up to date.");
        else
        {
            var changes = new List<string>();
            if (plan.Writes.Count > 0) changes.Add($"copied {Files(plan.Writes.Count)} ({Support.Format.Bytes(plan.BytesToWrite)})");
            if (plan.Deletions.Count > 0) changes.Add($"removed {Files(plan.Deletions.Count)}");
            var joined = string.Join(", ", changes);
            parts.Add(char.ToUpperInvariant(joined[0]) + joined[1..]);
        }
        if (plan.Skipped.Count > 0) parts.Add($"{plan.Skipped.Count} left out (over 4 GB for FAT32)");
        var text = string.Join(". ", parts);
        return text.EndsWith('.') ? text : text + ".";
    }
}
