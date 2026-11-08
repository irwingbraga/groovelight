using System.IO.Compression;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Groovelight.Core.Devices;

namespace Groovelight.Wireless;

/// <summary>What the server knows about the library and the devices, given by the app.</summary>
public interface IWirelessBackend
{
    /// <summary>This computer's id and name.</summary>
    WirelessProtocol.Info Info();
    /// <summary>A device asks to pair: the app shows the code and asks the user.</summary>
    Task PairRequested(WirelessProtocol.PairRequest request, WirelessProtocol.Pairing pairing);
    /// <summary>"pending", "accepted" or "rejected".</summary>
    Task<string> PairStatus(string deviceId);
    /// <summary>The signing key of a paired device.</summary>
    Task<byte[]?> Key(string deviceId);
    /// <summary>The plan for a device, from what it holds.</summary>
    Task<(DeviceSyncPlan Plan, DeviceProfile Profile)> Plan(string deviceId, WirelessProtocol.SyncRequest request);
    /// <summary>cover.jpg data for an artwork hash at a size.</summary>
    byte[]? Cover(string hash, int size);
    Task Finished(string deviceId, WirelessProtocol.SyncResult result);
    Task<WirelessProtocol.Status> Status(string deviceId);
    /// <summary>A file of a plan was asked for (index, count), for progress.</summary>
    void FileServed(string deviceId, int index, int count) { }
    /// <summary>The conversion of a song (its source and the plan's fingerprint), for player devices and lossy formats.</summary>
    string Converted(ConversionSource source, string fingerprint);
    /// <summary>The library snapshot (JSON) for a device: song ids to their paths on it, and to the codec of converted ones.</summary>
    Task<byte[]> Snapshot(string deviceId, Dictionary<long, string> paths, Dictionary<long, string> codecs);
    /// <summary>The whole library for a device to browse (catalog JSON).</summary>
    Task<byte[]> Catalog(string deviceId);
    /// <summary>Applies a device's requests to its selection and asks it to sync; returns what the selection holds then.</summary>
    Task<DeviceCatalog.ChosenSet> Requests(string deviceId, List<TransferRequest> requests);
    /// <summary>Applies a device's loves, ratings, plays and playlist edits to the library.</summary>
    Task History(string deviceId, List<DeviceHistoryEvent> events);
    /// <summary>The player for a device allowed to control it, or null when it is not.</summary>
    Task<WirelessProtocol.RemoteState?> RemoteState(string deviceId);
    /// <summary>Does what a device allowed to control the player asks; returns the state after it, or null when not allowed.</summary>
    Task<WirelessProtocol.RemoteState?> Remote(string deviceId, RemoteCommand command);
    /// <summary>Whether a device may control playback (the computer's and, through it, other devices').</summary>
    Task<bool> MayControl(string deviceId);
    /// <summary>A paired device's name, as other devices list it.</summary>
    Task<string?> DeviceName(string deviceId);
    /// <summary>Whether a device may reach this computer away from home (over Tailscale).</summary>
    Task<bool> MayConnectAway(string deviceId);
    /// <summary>A song's lyrics, for a device showing a song it does not have (playing on the computer).</summary>
    Task<string?> Lyrics(long trackId);
    /// <summary>Home for a device: the day's picks and the dashboard (HomeSnapshot JSON).</summary>
    Task<byte[]> Home(string deviceId) => Task.FromResult("{}"u8.ToArray());
}

/// <summary>
/// The computer's side of wireless sync (the Mac's WirelessSyncServer): routes requests from the phone apps, checks their
/// signatures, serves the files of a plan, and passes commands between devices playing on each other.
/// </summary>
public sealed class WirelessSyncServer(IWirelessBackend backend)
{
    private sealed class Session
    {
        public required string DeviceId;
        public required DeviceSyncPlan Plan;
        public required DeviceProfile Profile;
        public DateTime Expires;
        /// <summary>Authorizes this session's downloads over TLS (v2).</summary>
        public string? Token;
        public bool IsPlayer;
        /// <summary>SHA-256 of files already served (a resumed download asks again).</summary>
        public Dictionary<int, string> Hashes = [];
    }

    /// <summary>A device music can play on through this computer: there while it waits for commands (or did lately).</summary>
    private sealed class RelayTarget
    {
        public string Name = "Device";
        public DateTime LastSeen = DateTime.UtcNow;
        public int Waiting;
        public List<WirelessProtocol.RelayedCommand> Commands = [];
        public int LastSeq;
        public int Applied;
        public WirelessProtocol.RemoteState? State;
        public DateTime StateAt = DateTime.UtcNow;

        public bool IsPresent => Waiting > 0 || DateTime.UtcNow - LastSeen < RelayPresence;

        /// <summary>Its state as of now: the position moved on while it plays, as the device would show it.</summary>
        public WirelessProtocol.RemoteState? Current(DateTime now)
        {
            if (State is not { } state) return null;
            if (state.Playing)
            {
                var moved = state.Position + (now - StateAt).TotalSeconds * state.Rate;
                state = state with { Position = Math.Min(moved, state.Item?.Duration ?? moved) };
            }
            return state.Versioned(now);
        }
    }

    public static readonly TimeSpan RemoteWait = TimeSpan.FromSeconds(25);
    /// <summary>How long a device counts as there after it last waited for commands.</summary>
    private static readonly TimeSpan RelayPresence = TimeSpan.FromSeconds(10);
    /// <summary>How long a command waits for the device to apply it.</summary>
    private static readonly TimeSpan RelayAnswerWait = TimeSpan.FromSeconds(5);
    public const string PairAtHome = "Pair at home, on the same network as the computer.";
    public const string NotAllowedAway = "This computer does not allow this device away from home. Turn it on in the device's page in Groovelight.";

    private readonly Lock gate = new();
    private readonly Dictionary<string, RelayTarget> relay = [];
    private readonly Dictionary<string, Session> sessions = [];
    /// <summary>Nonces seen lately (requests are valid for five minutes either way): a captured request cannot be sent again.</summary>
    private readonly Dictionary<string, DateTime> recentNonces = [];
    private LocalHttpServer? server, secureServer;
    private int? tlsPort;
    private string? fingerprint;

    public int? Port => server?.Port;
    public int? TlsPort => tlsPort;

    /// <summary>
    /// Serves HTTP on <paramref name="port"/> (v1 and pairing) and, with a certificate, HTTPS on the next port (any free
    /// one when taken), which <c>/info</c> reports. Returns the HTTP port, or null when it could not start.
    /// </summary>
    public int? Start(int port = 0, (X509Certificate2 Certificate, string Fingerprint)? tls = null)
    {
        if (tls is { } identity)
        {
            var secure = new LocalHttpServer(HandleAsync, identity.Certificate);
            var bound = secure.Start(port == 0 ? 0 : port + 1) ?? (port != 0 ? secure.Start(0) : null);
            if (bound is not null)
            {
                lock (gate)
                {
                    secureServer = secure;
                    tlsPort = bound;
                    fingerprint = identity.Fingerprint;
                }
            }
        }
        var plain = new LocalHttpServer(HandleAsync);
        var started = plain.Start(port) ?? (port != 0 ? plain.Start(0) : null);
        if (started is not null) server = plain;
        return started;
    }

    public void Stop()
    {
        server?.Stop();
        secureServer?.Stop();
        server = secureServer = null;
        tlsPort = null;
    }

    public WirelessProtocol.Info Info()
    {
        var away = AwayNetwork.Addresses();
        return backend.Info() with { TlsPort = tlsPort, AwayAddresses = away.Count == 0 ? null : away };
    }

    // MARK: Routing

    internal async Task<HttpResponse> HandleAsync(HttpRequest request, CancellationToken token)
    {
        var parts = request.Path.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var first = parts.FirstOrDefault();
        switch (request.Method, parts.Length, first)
        {
            case ("GET", 1, "info"):
                return HttpResponse.Json(Info());
            // Pairing only at home: away, a device can only reach a computer it is already paired with.
            case ("POST", 1, "pair") or ("GET", 2, "pair") when request.IsAway:
                return HttpResponse.Error(403, PairAtHome);
            case ("POST", 1, "pair"):
                return await PairAsync(request);
            case ("GET", 2, "pair"):
                return HttpResponse.Json(new WirelessProtocol.PairStatus(await backend.PairStatus(parts[1])));
        }
        // A session's downloads over TLS, with its token instead of a signature (v2).
        if (request.Method == "GET" && parts.Length >= 3 && parts[0] == "sync" && request.Headers.TryGetValue(WirelessProtocol.Header.Token, out var given))
        {
            Session? session;
            lock (gate) session = sessions.GetValueOrDefault(parts[1]);
            if (!request.Secure || session is null || session.Expires < DateTime.UtcNow || session.Token is not { } expected
                || !CryptographicOperations.FixedTimeEquals(System.Text.Encoding.UTF8.GetBytes(given), System.Text.Encoding.UTF8.GetBytes(expected)))
                return HttpResponse.Error(401, "bad token");
            if (request.IsAway && !await backend.MayConnectAway(session.DeviceId)) return HttpResponse.Error(403, NotAllowedAway);
            return await DownloadAsync(parts[1], parts, session.DeviceId);
        }
        if (await VerifyAsync(request) is not { } deviceId) return HttpResponse.Error(401, "not paired or bad signature");
        if (request.IsAway && !await backend.MayConnectAway(deviceId)) return HttpResponse.Error(403, NotAllowedAway);
        HttpResponse? HttpsOnly() => request.Secure ? null : HttpResponse.Error(403, "HTTPS only");
        switch (request.Method, parts.Length, first)
        {
            case ("GET", 1, "status"):
                return HttpResponse.Json(await backend.Status(deviceId));
            case ("GET", 1, "certificate"):
                return await CertificateAsync(deviceId, request);
            case ("POST", 1, "sync"):
                return await StartSyncAsync(deviceId, request);
            case ("GET", 4, "sync") when parts[2] == "file":
                return await DownloadAsync(parts[1], parts, deviceId);
            case ("POST", 3, "sync") when parts[2] == "done":
                return await FinishAsync(parts[1], deviceId, request);
            // The whole library and the device's requests (v2, over TLS only: they describe the library).
            case ("GET", 1, "catalog"):
                return HttpsOnly() ?? await CatalogAsync(deviceId, request);
            case ("GET", 1, "home"):
                return HttpsOnly() ?? Deflated(await backend.Home(deviceId), request);
            case ("GET", 3, "catalog") when parts[1] == "artwork":
                if (HttpsOnly() is { } refusal) return refusal;
                return backend.Cover(parts[2], 300) is { } cover ? Jpeg(cover) : HttpResponse.Error(404, "no cover");
            case ("GET", 3, "catalog") when parts[1] == "lyrics":
                if (HttpsOnly() is { } refused) return refused;
                return long.TryParse(parts[2], out var trackId) && await backend.Lyrics(trackId) is { } lyrics
                    ? new HttpResponse { Headers = new() { ["Content-Type"] = "text/plain; charset=utf-8" }, Data = System.Text.Encoding.UTF8.GetBytes(lyrics) }
                    : HttpResponse.Error(404, "no lyrics");
            case ("POST", 1, "requests"):
                if (HttpsOnly() is { } notSecure) return notSecure;
                return WireJson.Decode<WirelessProtocol.Requests>(request.Body) is { Items: { } requests }
                    ? HttpResponse.Json(await backend.Requests(deviceId, requests)) : HttpResponse.Error(400, "bad requests");
            // Playing on the computer from the device: the player's state, waited on, and commands; with ?device=, another device's.
            case ("GET", 1, "remote"):
                if (HttpsOnly() is { } plainRemote) return plainRemote;
                return request.Query.TryGetValue("device", out var target)
                    ? await RelayedStateAsync(deviceId, target, request.Query.GetValueOrDefault("after"), token)
                    : await RemoteStateAsync(deviceId, request.Query.GetValueOrDefault("after"), token);
            case ("GET", 2, "remote") when parts[1] == "devices":
                if (HttpsOnly() is { } plainDevices) return plainDevices;
                if (!await backend.MayControl(deviceId)) return HttpResponse.Error(403, "not allowed to control playback");
                return HttpResponse.Json(new WirelessProtocol.RemoteDevices(RelayDevices(deviceId)));
            case ("POST", 1, "remote"):
                if (HttpsOnly() is { } plainCommand) return plainCommand;
                if (WireJson.Decode<RemoteCommand>(request.Body) is not { } command) return HttpResponse.Error(400, "bad command");
                if (request.Query.TryGetValue("device", out var to)) return await RelayAsync(command, deviceId, to, token);
                return await backend.Remote(deviceId, command) is { } after ? HttpResponse.Json(after.Versioned(DateTime.UtcNow))
                    : HttpResponse.Error(403, "not allowed to control playback");
            // A device music can play on: its commands, waited on, and its player after them.
            case ("GET", 1, "relay"):
                if (HttpsOnly() is { } plainRelay) return plainRelay;
                return await RelayCommandsAsync(deviceId, int.TryParse(request.Query.GetValueOrDefault("after"), out var seq) ? seq : null, token);
            case ("POST", 2, "relay") when parts[1] == "state":
                if (HttpsOnly() is { } plainState) return plainState;
                if (WireJson.Decode<WirelessProtocol.RelayState>(request.Body) is not { } state) return HttpResponse.Error(400, "bad state");
                await RelayStateArrivedAsync(state, deviceId);
                return HttpResponse.Json(new Dictionary<string, bool> { ["ok"] = true });
            case ("POST", 1, "history"):
                if (HttpsOnly() is { } plainHistory) return plainHistory;
                if (WireJson.Decode<WirelessProtocol.History>(request.Body) is not { } history) return HttpResponse.Error(400, "bad history");
                try
                {
                    await backend.History(deviceId, history.Events);
                    return HttpResponse.Json(new Dictionary<string, int> { ["applied"] = history.Events.Count });
                }
                catch (Exception error) when (error is IOException or InvalidOperationException or Microsoft.Data.Sqlite.SqliteException)
                {
                    return HttpResponse.Error(500, error.Message);
                }
            default:
                return HttpResponse.Error(404, "unknown request");
        }
    }

    private static HttpResponse Jpeg(byte[] data) =>
        new() { Headers = new() { ["Content-Type"] = "image/jpeg", [WirelessProtocol.Header.Sha256] = WirelessProtocol.Sha256(data) }, Data = data };

    /// <summary>The player's state; with <paramref name="after"/>, held until it changes or for 25 seconds.</summary>
    private async Task<HttpResponse> RemoteStateAsync(string deviceId, string? after, CancellationToken token)
    {
        var deadline = DateTime.UtcNow + (after is null ? TimeSpan.Zero : RemoteWait);
        while (true)
        {
            if (await backend.RemoteState(deviceId) is not { } state) return HttpResponse.Error(403, "not allowed to control playback");
            var now = DateTime.UtcNow;
            state = state.Versioned(now);
            if (state.Version != after || now >= deadline || token.IsCancellationRequested) return HttpResponse.Json(state);
            try { await Task.Delay(200, token); }
            catch (OperationCanceledException) { return HttpResponse.Json(state); }
        }
    }

    // MARK: Relay (devices playing on each other through the computer)

    private List<WirelessProtocol.RemoteDevice> RelayDevices(string except)
    {
        lock (gate)
        {
            return relay.Where(pair => pair.Key != except && pair.Value.IsPresent).Select(pair => new WirelessProtocol.RemoteDevice(pair.Key, pair.Value.Name))
                .OrderBy(device => device.Name, StringComparer.Ordinal).ToList();
        }
    }

    /// <summary>A device waiting for commands: answered with those after <paramref name="after"/> as soon as there are some, or none after 25 seconds.</summary>
    private async Task<HttpResponse> RelayCommandsAsync(string deviceId, int? after, CancellationToken token)
    {
        var name = await backend.DeviceName(deviceId) ?? "Device";
        var deadline = DateTime.UtcNow + (after is null ? TimeSpan.Zero : RemoteWait);
        lock (gate)
        {
            var target = relay.GetValueOrDefault(deviceId) ?? new RelayTarget();
            target.Name = name;
            target.LastSeen = DateTime.UtcNow;
            target.Waiting++;
            relay[deviceId] = target;
        }
        try
        {
            while (true)
            {
                WirelessProtocol.RelayCommands answer;
                lock (gate)
                {
                    var target = relay.GetValueOrDefault(deviceId);
                    var last = target?.LastSeq ?? 0;
                    answer = new WirelessProtocol.RelayCommands((target?.Commands ?? []).Where(command => command.Seq > (after ?? last)).ToList(), last);
                }
                if (answer.Commands.Count > 0 || DateTime.UtcNow >= deadline || token.IsCancellationRequested) return HttpResponse.Json(answer);
                try { await Task.Delay(100, token); }
                catch (OperationCanceledException) { return HttpResponse.Json(answer); }
            }
        }
        finally
        {
            lock (gate)
            {
                if (relay.TryGetValue(deviceId, out var target))
                {
                    target.Waiting--;
                    target.LastSeen = DateTime.UtcNow;
                }
            }
        }
    }

    private async Task RelayStateArrivedAsync(WirelessProtocol.RelayState body, string deviceId)
    {
        var name = await backend.DeviceName(deviceId) ?? "Device";
        lock (gate)
        {
            var target = relay.GetValueOrDefault(deviceId) ?? new RelayTarget { Name = name };
            target.State = body.State;
            target.StateAt = DateTime.UtcNow;
            target.Applied = Math.Max(target.Applied, body.Applied);
            // Applied commands are no longer kept.
            target.Commands.RemoveAll(command => command.Seq <= target.Applied);
            relay[deviceId] = target;
        }
    }

    /// <summary>Passes a command on and waits (a few seconds) for the device to apply it; answers with its player then.</summary>
    private async Task<HttpResponse> RelayAsync(RemoteCommand command, string from, string to, CancellationToken token)
    {
        if (!await backend.MayControl(from)) return HttpResponse.Error(403, "not allowed to control playback");
        var fromName = await backend.DeviceName(from) ?? "Device";
        int seq;
        lock (gate)
        {
            if (!relay.TryGetValue(to, out var device) || !device.IsPresent) return HttpResponse.Error(404, "that device is not there");
            device.LastSeq++;
            device.Commands.Add(new WirelessProtocol.RelayedCommand(device.LastSeq, from, fromName, command));
            seq = device.LastSeq;
        }
        var deadline = DateTime.UtcNow + RelayAnswerWait;
        while (DateTime.UtcNow < deadline && !token.IsCancellationRequested)
        {
            lock (gate)
            {
                if (relay.TryGetValue(to, out var device) && device.Applied >= seq)
                    return HttpResponse.Json(device.Current(DateTime.UtcNow) ?? WirelessProtocol.RemoteState.Idle(DateTime.UtcNow));
            }
            try { await Task.Delay(50, token); }
            catch (OperationCanceledException) { break; }
        }
        return HttpResponse.Error(504, "that device did not answer");
    }

    /// <summary>Another device's player; with <paramref name="after"/>, held until it changes or for 25 seconds.</summary>
    private async Task<HttpResponse> RelayedStateAsync(string deviceId, string target, string? after, CancellationToken token)
    {
        if (!await backend.MayControl(deviceId)) return HttpResponse.Error(403, "not allowed to control playback");
        var deadline = DateTime.UtcNow + (after is null ? TimeSpan.Zero : RemoteWait);
        while (true)
        {
            var now = DateTime.UtcNow;
            WirelessProtocol.RemoteState answer;
            lock (gate)
            {
                if (!relay.TryGetValue(target, out var device) || !device.IsPresent) return HttpResponse.Error(404, "that device is not there");
                answer = device.Current(now) ?? WirelessProtocol.RemoteState.Idle(now);
            }
            if (answer.Version != after || now >= deadline || token.IsCancellationRequested) return HttpResponse.Json(answer);
            try { await Task.Delay(200, token); }
            catch (OperationCanceledException) { return HttpResponse.Json(answer); }
        }
    }

    /// <summary>The catalog, deflated (raw DEFLATE), with its SHA-256 as the ETag: a device that has this version gets 304.</summary>
    private async Task<HttpResponse> CatalogAsync(string deviceId, HttpRequest request) => Deflated(await backend.Catalog(deviceId), request);

    /// <summary>JSON deflated (raw DEFLATE), with its SHA-256 as the ETag: 304 when the device has it.</summary>
    private static HttpResponse Deflated(byte[] json, HttpRequest request)
    {
        var tag = WirelessProtocol.Sha256(json);
        if (request.Headers.GetValueOrDefault("if-none-match") == tag) return new HttpResponse { Status = 304, Headers = new() { ["ETag"] = tag } };
        using var output = new MemoryStream();
        using (var deflate = new DeflateStream(output, CompressionLevel.Optimal, true)) deflate.Write(json);
        var deflated = output.ToArray();
        return new HttpResponse
        {
            Headers = new()
            {
                ["Content-Type"] = "application/json", ["ETag"] = tag, [WirelessProtocol.Header.Encoding] = "deflate", [WirelessProtocol.Header.Sha256] = WirelessProtocol.Sha256(deflated),
            },
            Data = deflated,
        };
    }

    /// <summary>The certificate the HTTPS port serves, with proof that this computer (paired with the device) serves it.</summary>
    private async Task<HttpResponse> CertificateAsync(string deviceId, HttpRequest request)
    {
        string? served;
        lock (gate) served = fingerprint;
        if (served is null || !request.Query.TryGetValue("nonce", out var nonce) || nonce.Length < 16 || await backend.Key(deviceId) is not { } key)
            return HttpResponse.Error(400, "no certificate, or no nonce");
        return HttpResponse.Json(new WirelessProtocol.Certificate(served, WirelessProtocol.CertificateProof(served, nonce, key)));
    }

    private async Task<HttpResponse> PairAsync(HttpRequest request)
    {
        if (WireJson.Decode<WirelessProtocol.PairRequest>(request.Body) is not { } pairRequest) return HttpResponse.Error(400, "bad pairing request");
        WirelessProtocol.Pairing pairing;
        try { pairing = new WirelessProtocol.Pairing(Convert.FromBase64String(pairRequest.PublicKey)); }
        catch (Exception error) when (error is FormatException or CryptographicException) { return HttpResponse.Error(400, "bad pairing request"); }
        await backend.PairRequested(pairRequest, pairing);
        var info = backend.Info();
        return HttpResponse.Json(new WirelessProtocol.PairResponse(info.Id, info.Name, Convert.ToBase64String(pairing.HostPublicKey)));
    }

    /// <summary>The device of a correctly signed request from a paired device.</summary>
    internal async Task<string?> VerifyAsync(HttpRequest request, DateTime? now = null)
    {
        var at = now ?? DateTime.UtcNow;
        if (!request.Headers.TryGetValue(WirelessProtocol.Header.Device, out var deviceId) || !request.Headers.TryGetValue(WirelessProtocol.Header.Time, out var timeText)
            || !long.TryParse(timeText, out var time) || !request.Headers.TryGetValue(WirelessProtocol.Header.Signature, out var signature)
            || !request.Headers.TryGetValue(WirelessProtocol.Header.Nonce, out var nonce) || await backend.Key(deviceId) is not { } key
            || !WirelessProtocol.IsValid(signature, request.Method, request.Path, time, nonce, request.Body, key, at)) return null;
        lock (gate)
        {
            foreach (var old in recentNonces.Where(pair => at - pair.Value >= TimeSpan.FromMinutes(10)).Select(pair => pair.Key).ToList()) recentNonces.Remove(old);
            if (!recentNonces.TryAdd(nonce, at)) return null;
        }
        return deviceId;
    }

    private async Task<HttpResponse> StartSyncAsync(string deviceId, HttpRequest request)
    {
        if (WireJson.Decode<WirelessProtocol.SyncRequest>(request.Body) is not { } syncRequest) return HttpResponse.Error(400, "bad sync request");
        try
        {
            var (plan, profile) = await backend.Plan(deviceId, syncRequest);
            var id = Guid.NewGuid().ToString().ToUpperInvariant();
            // A token only over TLS: in plain HTTP it could be read by others on the network.
            var token = request.Secure ? Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)).Replace('+', '-').Replace('/', '_') : null;
            lock (gate)
            {
                foreach (var old in sessions.Where(pair => pair.Value.Expires < DateTime.UtcNow).Select(pair => pair.Key).ToList()) sessions.Remove(old);
                sessions[id] = new Session
                {
                    DeviceId = deviceId, Plan = plan, Profile = profile, Expires = DateTime.UtcNow.AddHours(6), Token = token, IsPlayer = syncRequest.IsPlayer,
                };
            }
            var writes = plan.Writes.Select((write, index) => new WirelessProtocol.PlanWrite(index, write.Path, write.Entry.Size, write.Entry)).ToList();
            return HttpResponse.Json(new WirelessProtocol.SyncPlan(id, writes, plan.Deletions, plan.Unchanged, profile, plan.SongCount,
                plan.Skipped.Select(item => $"{item.Title}: {item.Reason}").ToList(), token));
        }
        catch (Exception error) when (error is IOException or InvalidOperationException or Microsoft.Data.Sqlite.SqliteException)
        {
            return HttpResponse.Error(409, error.Message);
        }
    }

    /// <summary>GET /sync/session/file/index, and over TLS /sync/session/snapshot and /sync/session/artwork/hash.</summary>
    private async Task<HttpResponse> DownloadAsync(string id, string[] parts, string deviceId)
    {
        Session? session;
        lock (gate) session = sessions.GetValueOrDefault(id);
        if (session is null || session.DeviceId != deviceId) return HttpResponse.Error(404, "no such session");
        return (parts.Length, parts[2]) switch
        {
            (4, "file") => await FileAsync(id, session, int.TryParse(parts[3], out var index) ? index : -1),
            (3, "snapshot") when session.IsPlayer => await SnapshotAsync(session),
            (4, "artwork") => backend.Cover(parts[3], 600) is { } cover ? Jpeg(cover) : HttpResponse.Error(404, "no cover"),
            _ => HttpResponse.Error(404, "unknown request"),
        };
    }

    private async Task<HttpResponse> FileAsync(string id, Session session, int index)
    {
        if (index < 0 || index >= session.Plan.Writes.Count) return HttpResponse.Error(404, "no such file");
        backend.FileServed(session.DeviceId, index, session.Plan.Writes.Count);
        var write = session.Plan.Writes[index];
        switch (write.Content)
        {
            case DeviceContent.File file:
                return FileResponse(file.Path, session, index);
            case DeviceContent.Converted converted:
                // Converted on first request (and cached), off the server's threads.
                try { return FileResponse(await Task.Run(() => backend.Converted(converted.Source, write.Entry.Fingerprint)), session, index); }
                catch (Exception error) when (error is ConversionException or IOException) { return HttpResponse.Error(500, error.Message); }
            case DeviceContent.Data data:
                return new HttpResponse { Headers = new() { [WirelessProtocol.Header.Sha256] = WirelessProtocol.Sha256(data.Bytes) }, Data = data.Bytes };
            case DeviceContent.Cover image:
                return backend.Cover(image.Hash, session.Profile.CoverSize) is { } cover ? Jpeg(cover) : HttpResponse.Error(404, "no cover");
            default:
                return HttpResponse.Error(404, "no such file");
        }
    }

    /// <summary>A file with its SHA-256 (worked out once per session and file), also as the ETag so a cut download resumes.</summary>
    private HttpResponse FileResponse(string path, Session session, int index)
    {
        string? hash;
        lock (gate) hash = session.Hashes.GetValueOrDefault(index);
        if (hash is null)
        {
            hash = WirelessProtocol.Sha256(path);
            if (hash is null) return HttpResponse.Error(404, "missing file");
            lock (gate) session.Hashes[index] = hash;
        }
        return new HttpResponse { Headers = new() { [WirelessProtocol.Header.Sha256] = hash, ["ETag"] = $"\"{hash}\"" }, FilePath = path };
    }

    /// <summary>The library snapshot for the songs the device will hold after this sync.</summary>
    private async Task<HttpResponse> SnapshotAsync(Session session)
    {
        var paths = new Dictionary<long, string>();
        var codecs = new Dictionary<long, string>();
        foreach (var (path, entry) in session.Plan.Unchanged)
            if (entry.Kind == ManifestKind.Song && entry.TrackId is { } id) paths[id] = path;
        foreach (var write in session.Plan.Writes)
        {
            if (write.Entry.Kind != ManifestKind.Song || write.Entry.TrackId is not { } id) continue;
            paths[id] = write.Path;
            if (write.Content is DeviceContent.Converted && DeviceSync.ConvertedCodec(write.Entry.Fingerprint) is { } codec) codecs[id] = codec;
        }
        // Converted earlier and unchanged since: still in that format on the device.
        foreach (var (path, entry) in session.Plan.Unchanged)
        {
            if (entry.Kind == ManifestKind.Song && entry.TrackId is { } id && paths.GetValueOrDefault(id) == path && DeviceSync.ConvertedCodec(entry.Fingerprint) is { } codec)
                codecs[id] = codec;
        }
        var data = await backend.Snapshot(session.DeviceId, paths, codecs);
        return new HttpResponse { Headers = new() { ["Content-Type"] = "application/json", [WirelessProtocol.Header.Sha256] = WirelessProtocol.Sha256(data) }, Data = data };
    }

    private async Task<HttpResponse> FinishAsync(string id, string deviceId, HttpRequest request)
    {
        bool owned;
        lock (gate) owned = sessions.TryGetValue(id, out var session) && session.DeviceId == deviceId;
        if (!owned || WireJson.Decode<WirelessProtocol.SyncResult>(request.Body) is not { } result) return HttpResponse.Error(404, "no such session");
        lock (gate) sessions.Remove(id);
        await backend.Finished(deviceId, result);
        return HttpResponse.Json(new WirelessProtocol.PairStatus("ok"));
    }
}
