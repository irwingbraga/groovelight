using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using Groovelight.Core.Devices;
using Groovelight.Core.Library;
using Groovelight.Wireless;

namespace Groovelight.Tests;

public class WirelessTests
{
    private static readonly byte[] DevicePrivate = Enumerable.Range(1, 32).Select(value => (byte)value).ToArray();
    private static readonly byte[] HostPrivate = Enumerable.Range(33, 32).Select(value => (byte)value).ToArray();

    [Fact]
    public void DerivesTheSameCodeAndKeyAsTheMacAndThePhones()
    {
        var devicePublic = X25519.PublicKey(DevicePrivate);
        Assert.Equal("B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw=", Convert.ToBase64String(devicePublic));
        var pairing = new WirelessProtocol.Pairing(devicePublic, HostPrivate);
        Assert.Equal("WGmv9FBUlzLLqu1eXfmzCm2jHLDldCutWtShp2jxpns=", Convert.ToBase64String(pairing.HostPublicKey));
        // The device's side, from the computer's public key.
        var secret = X25519.SharedSecret(DevicePrivate, pairing.HostPublicKey);
        var (key, code) = WirelessProtocol.Derive(secret, pairing.HostPublicKey, devicePublic);
        Assert.Equal(pairing.Code, code);
        Assert.Equal(pairing.Key, key);
        Assert.Equal("328727", code);
        Assert.Equal("lpDhU3RKuAhlJ1Osb2X4F88i0R6pUe5J//UAaIQxHFs=", WirelessProtocol.Signature("post", "/sync", 1_700_000_000, "n1", "{}"u8, key));
    }

    [Fact]
    public void X25519MatchesRfc7748()
    {
        // RFC 7748, section 6.1.
        var alice = Convert.FromHexString("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
        Assert.Equal("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a", Convert.ToHexStringLower(X25519.PublicKey(alice)));
        var bob = Convert.FromHexString("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb");
        Assert.Equal("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742",
            Convert.ToHexStringLower(X25519.SharedSecret(alice, X25519.PublicKey(bob))));
    }

    [Fact]
    public void SignaturesCoverTheWholeRequestAndExpire()
    {
        var key = RandomNumberGenerator.GetBytes(32);
        var now = DateTime.UnixEpoch.AddSeconds(1_700_000_000);
        var body = """{"a":1}"""u8.ToArray();
        var signature = WirelessProtocol.Signature("POST", "/sync", 1_700_000_000, "n", body, key);
        Assert.True(WirelessProtocol.IsValid(signature, "POST", "/sync", 1_700_000_000, "n", body, key, now));
        Assert.False(WirelessProtocol.IsValid(signature, "POST", "/sync", 1_700_000_000, "n", """{"a":2}"""u8, key, now));
        Assert.False(WirelessProtocol.IsValid(signature, "GET", "/sync", 1_700_000_000, "n", body, key, now));
        Assert.False(WirelessProtocol.IsValid(signature, "POST", "/sync", 1_700_000_000, "n", body, RandomNumberGenerator.GetBytes(32), now));
        Assert.False(WirelessProtocol.IsValid(signature, "POST", "/sync", 1_700_000_000, "n", body, key, now.AddSeconds(600)));
    }

    [Fact]
    public void ParsesRanges()
    {
        Assert.Equal((100L, 999L), LocalHttpServer.ParseRange("bytes=100-", 1000));
        Assert.Equal((100L, 199L), LocalHttpServer.ParseRange("bytes=100-199", 1000));
        Assert.Equal((990L, 999L), LocalHttpServer.ParseRange("bytes=-10", 1000));
        Assert.Null(LocalHttpServer.ParseRange("bytes=2000-", 1000));
    }

    [Fact]
    public void ReadsAndWritesTheMacsMessages()
    {
        var command = WireJson.Decode<RemoteCommand>("""{"command": "play", "songIds": [3, 4], "startAt": 1, "position": 12.5, "shuffle": true}"""u8);
        Assert.Equal(new RemoteCommand.Play([3, 4], 1, 12.5, true) with { SongIds = ((RemoteCommand.Play)command!).SongIds }, command);
        Assert.Equal("""{"command":"seek","position":42}""", Encoding.UTF8.GetString(WireJson.Encode<RemoteCommand>(new RemoteCommand.Seek(42))));
        var manifest = new DeviceManifest { LastSync = new DateTime(2026, 10, 31, 12, 0, 0, DateTimeKind.Utc) };
        manifest.Entries["Music/a.flac"] = new ManifestEntry { Kind = ManifestKind.CueSheet, Fingerprint = "f", Size = 3, Synced = true };
        var json = Encoding.UTF8.GetString(WireJson.Encode(manifest));
        Assert.Contains("\"lastSync\":\"2026-10-31T12:00:00Z\"", json);
        Assert.Contains("\"kind\":\"cueSheet\"", json);
        var profile = WireJson.Decode<DeviceProfile>("""{"musicFolder":"M","template":"t","playlistFolder":"P","writesPlaylists":true,"writesCovers":false,"coverSize":300,"writesLyrics":true,"encoding":"mp3_320"}"""u8);
        Assert.Equal(LossyEncoding.Mp3320, profile!.Encoding);
        var request = WireJson.Decode<TransferRequest>("""{"id":"1","action":"remove","kind":"album","key":"k"}"""u8);
        Assert.Equal(TransferAction.Remove, request!.Action);
        Assert.Equal("album:k", request.EncodingKey);
    }

    /// <summary>A backend over one song, paired with one device.</summary>
    private sealed class Backend(string file, byte[] key) : IWirelessBackend
    {
        public string Pairing = "pending";
        public List<string> Log { get; } = [];
        public WirelessProtocol.Info Info() => new("host-id", "IRWING-PC");
        public Task PairRequested(WirelessProtocol.PairRequest request, WirelessProtocol.Pairing pairing)
        {
            Log.Add($"pair {request.DeviceId} {pairing.Code}");
            return Task.CompletedTask;
        }
        public Task<string> PairStatus(string deviceId) => Task.FromResult(Pairing);
        public Task<byte[]?> Key(string deviceId) => Task.FromResult<byte[]?>(deviceId == "phone" ? key : null);
        public Task<(DeviceSyncPlan Plan, DeviceProfile Profile)> Plan(string deviceId, WirelessProtocol.SyncRequest request)
        {
            var plan = new DeviceSyncPlan { SongCount = 1 };
            plan.Writes.Add(new DeviceWrite("Music/A/01 Song.flac", new DeviceContent.File(file), new ManifestEntry { Kind = ManifestKind.Song, TrackId = 7, Fingerprint = "x", Size = 4096, Synced = true }));
            return Task.FromResult((plan, new DeviceProfile()));
        }
        public byte[]? Cover(string hash, int size) => null;
        public Task Finished(string deviceId, WirelessProtocol.SyncResult result)
        {
            Log.Add($"done {result.Written}");
            return Task.CompletedTask;
        }
        public Task<WirelessProtocol.Status> Status(string deviceId) => Task.FromResult(new WirelessProtocol.Status(false, 0));
        public string Converted(ConversionSource source, string fingerprint) => source.Path;
        public Task<byte[]> Snapshot(string deviceId, Dictionary<long, string> paths, Dictionary<long, string> codecs) => Task.FromResult("{}"u8.ToArray());
        public Task<byte[]> Catalog(string deviceId) => Task.FromResult("""{"version":1}"""u8.ToArray());
        public Task<DeviceCatalog.ChosenSet> Requests(string deviceId, List<TransferRequest> requests) => Task.FromResult(new DeviceCatalog.ChosenSet());
        public Task History(string deviceId, List<DeviceHistoryEvent> events) => Task.CompletedTask;
        public Task<WirelessProtocol.RemoteState?> RemoteState(string deviceId) => Task.FromResult<WirelessProtocol.RemoteState?>(new WirelessProtocol.RemoteState { Volume = 0.5 });
        public Task<WirelessProtocol.RemoteState?> Remote(string deviceId, RemoteCommand command)
        {
            Log.Add(command.GetType().Name);
            return RemoteState(deviceId);
        }
        public Task<bool> MayControl(string deviceId) => Task.FromResult(true);
        public Task<string?> DeviceName(string deviceId) => Task.FromResult<string?>(deviceId);
        public Task<bool> MayConnectAway(string deviceId) => Task.FromResult(false);
        public Task<string?> Lyrics(long trackId) => Task.FromResult<string?>(null);
    }

    private static HttpRequestMessage Signed(HttpMethod method, string url, string path, byte[] body, byte[] key, string? nonce = null)
    {
        var message = new HttpRequestMessage(method, url) { Content = method == HttpMethod.Get ? null : new ByteArrayContent(body) };
        var time = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        nonce ??= Guid.NewGuid().ToString();
        message.Headers.Add(WirelessProtocol.Header.Device, "phone");
        message.Headers.Add(WirelessProtocol.Header.Time, time.ToString());
        message.Headers.Add(WirelessProtocol.Header.Nonce, nonce);
        message.Headers.Add(WirelessProtocol.Header.Signature, WirelessProtocol.Signature(method.Method, path, time, nonce, body, key));
        return message;
    }

    [Fact(Timeout = 60_000)]
    public async Task PairsSyncsAndServesFiles()
    {
        var cancel = TestContext.Current.CancellationToken;
        var folder = Path.Combine(Path.GetTempPath(), "gl-wireless-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            var song = Path.Combine(folder, "song.flac");
            var bytes = RandomNumberGenerator.GetBytes(4096);
            await File.WriteAllBytesAsync(song, bytes, cancel);
            var key = RandomNumberGenerator.GetBytes(32);
            var backend = new Backend(song, key);
            var server = new WirelessSyncServer(backend);
            var identity = TlsIdentity.Load(Path.Combine(folder, "identity.pfx"));
            var port = server.Start(0, identity) ?? throw new InvalidOperationException("no port");
            Assert.NotNull(server.TlsPort);
            using var http = new HttpClient();
            var info = WireJson.Decode<WirelessProtocol.Info>(await http.GetByteArrayAsync($"http://127.0.0.1:{port}/info", cancel));
            Assert.Equal("IRWING-PC", info!.Name);
            Assert.Equal("windows", info.Platform);
            Assert.Equal(server.TlsPort, info.TlsPort);

            // Pairing: the computer's public key comes back, and both sides' codes match.
            var devicePrivate = X25519.NewPrivateKey();
            var pairBody = WireJson.Encode(new WirelessProtocol.PairRequest("phone", "Pixel", "Pixel 9", Convert.ToBase64String(X25519.PublicKey(devicePrivate))));
            var pairAnswer = await http.PostAsync($"http://127.0.0.1:{port}/pair", new ByteArrayContent(pairBody), cancel);
            var pair = WireJson.Decode<WirelessProtocol.PairResponse>(await pairAnswer.Content.ReadAsByteArrayAsync(cancel));
            var (_, code) = WirelessProtocol.Derive(X25519.SharedSecret(devicePrivate, Convert.FromBase64String(pair!.PublicKey)), Convert.FromBase64String(pair.PublicKey),
                X25519.PublicKey(devicePrivate));
            Assert.Equal($"pair phone {code}", backend.Log[0]);
            Assert.Equal("pending", WireJson.Decode<WirelessProtocol.PairStatus>(await http.GetByteArrayAsync($"http://127.0.0.1:{port}/pair/phone", cancel))!.Status);

            // Unsigned requests are refused; a signed sync gets a plan.
            Assert.Equal(HttpStatusCode.Unauthorized, (await http.GetAsync($"http://127.0.0.1:{port}/status", cancel)).StatusCode);
            var syncBody = WireJson.Encode(new WirelessProtocol.SyncRequest { Capacity = 1, Available = 1 });
            var syncAnswer = await http.SendAsync(Signed(HttpMethod.Post, $"http://127.0.0.1:{port}/sync", "/sync", syncBody, key, "replayed"), cancel);
            var plan = WireJson.Decode<WirelessProtocol.SyncPlan>(await syncAnswer.Content.ReadAsByteArrayAsync(cancel));
            Assert.Equal("Music/A/01 Song.flac", plan!.Writes.Single().Path);
            Assert.Null(plan.Token);
            // The same request again (a replay) is refused.
            Assert.Equal(HttpStatusCode.Unauthorized, (await http.SendAsync(Signed(HttpMethod.Post, $"http://127.0.0.1:{port}/sync", "/sync", syncBody, key, "replayed"), cancel)).StatusCode);

            // The file, whole and resumed from an offset, with its SHA-256.
            var filePath = $"/sync/{plan.Session}/file/0";
            var whole = await http.SendAsync(Signed(HttpMethod.Get, $"http://127.0.0.1:{port}{filePath}", filePath, [], key), cancel);
            Assert.Equal(bytes, await whole.Content.ReadAsByteArrayAsync(cancel));
            Assert.Equal(WirelessProtocol.Sha256(bytes), whole.Headers.GetValues(WirelessProtocol.Header.Sha256).Single());
            var partial = Signed(HttpMethod.Get, $"http://127.0.0.1:{port}{filePath}", filePath, [], key);
            partial.Headers.Range = new RangeHeaderValue(4000, null);
            var resumed = await http.SendAsync(partial, cancel);
            Assert.Equal(HttpStatusCode.PartialContent, resumed.StatusCode);
            Assert.Equal(bytes[4000..], await resumed.Content.ReadAsByteArrayAsync(cancel));

            var doneBody = WireJson.Encode(new WirelessProtocol.SyncResult(1, 0, [], null));
            var donePath = $"/sync/{plan.Session}/done";
            Assert.Equal(HttpStatusCode.OK, (await http.SendAsync(Signed(HttpMethod.Post, $"http://127.0.0.1:{port}{donePath}", donePath, doneBody, key), cancel)).StatusCode);
            Assert.Contains("done 1", backend.Log);

            // The certificate, proved with the pairing key; then HTTPS pinned to it, where the catalog and remote control are.
            var nonce = Convert.ToHexString(RandomNumberGenerator.GetBytes(16));
            var certificatePath = "/certificate";
            var certificateAnswer = await http.SendAsync(Signed(HttpMethod.Get, $"http://127.0.0.1:{port}{certificatePath}?nonce={nonce}", certificatePath, [], key), cancel);
            var certificate = WireJson.Decode<WirelessProtocol.Certificate>(await certificateAnswer.Content.ReadAsByteArrayAsync(cancel));
            Assert.Equal(identity.Fingerprint, certificate!.Fingerprint);
            Assert.Equal(WirelessProtocol.CertificateProof(certificate.Fingerprint, nonce, key), certificate.Proof);
            using var pinned = new HttpClient(new HttpClientHandler
            {
                ServerCertificateCustomValidationCallback = (_, served, _, _) => served is not null && Convert.ToHexStringLower(SHA256.HashData(served.RawData)) == certificate.Fingerprint,
            });
            var catalog = await pinned.SendAsync(Signed(HttpMethod.Get, $"https://127.0.0.1:{server.TlsPort}/catalog", "/catalog", [], key), cancel);
            Assert.Equal("deflate", catalog.Headers.GetValues(WirelessProtocol.Header.Encoding).Single());
            var commandBody = WireJson.Encode<RemoteCommand>(new RemoteCommand.Next());
            var remote = await pinned.SendAsync(Signed(HttpMethod.Post, $"https://127.0.0.1:{server.TlsPort}/remote", "/remote", commandBody, key), cancel);
            Assert.Equal(0.5, WireJson.Decode<WirelessProtocol.RemoteState>(await remote.Content.ReadAsByteArrayAsync(cancel))!.Volume);
            Assert.Contains("Next", backend.Log);
            // The catalog is HTTPS only.
            Assert.Equal(HttpStatusCode.Forbidden, (await http.SendAsync(Signed(HttpMethod.Get, $"http://127.0.0.1:{port}/catalog", "/catalog", [], key), cancel)).StatusCode);
            server.Stop();
        }
        finally
        {
            Directory.Delete(folder, true);
        }
    }
}
