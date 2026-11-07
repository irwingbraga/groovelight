using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Groovelight.Core.Devices;

namespace Groovelight.Wireless;

/// <summary>
/// The protocol between Groovelight on a computer and Groovelight for Android and iOS, over the local network (the
/// Mac's WirelessProtocol, byte for byte). The computer serves (DNS-SD <c>_groovelight._tcp</c>); the phone finds it,
/// pairs once (X25519, a 6-digit code on both screens), and then signs every request with the derived key. Version 2
/// adds HTTPS on a second port, whose certificate the phone pins after a signed <c>GET /certificate</c>.
/// </summary>
public static class WirelessProtocol
{
    public const string ServiceType = "_groovelight._tcp";
    public const int Version = 2;

    /// <summary>A pairing in progress: the computer's side of the key exchange with one device.</summary>
    public sealed class Pairing
    {
        public byte[] HostPublicKey { get; }
        public byte[] Key { get; }
        /// <summary>Shown on both screens; the user checks they match before allowing the device.</summary>
        public string Code { get; }

        public Pairing(byte[] devicePublicKey, byte[]? privateKey = null)
        {
            var mine = privateKey ?? X25519.NewPrivateKey();
            HostPublicKey = X25519.PublicKey(mine);
            var secret = X25519.SharedSecret(mine, devicePublicKey);
            (Key, Code) = Derive(secret, HostPublicKey, devicePublicKey);
        }
    }

    /// <summary>The signing key and the confirmation code from the shared secret (HKDF-SHA256), bound to both public keys.</summary>
    public static (byte[] Key, string Code) Derive(byte[] secret, byte[] hostPublicKey, byte[] devicePublicKey)
    {
        var salt = "groovelight-pair-v1"u8.ToArray();
        var key = HKDF.DeriveKey(HashAlgorithmName.SHA256, secret, 32, salt, [.. "key"u8, .. hostPublicKey, .. devicePublicKey]);
        var codeBytes = HKDF.DeriveKey(HashAlgorithmName.SHA256, secret, 4, salt, [.. "code"u8, .. hostPublicKey, .. devicePublicKey]);
        var number = codeBytes.Aggregate(0u, (value, part) => value << 8 | part) % 1_000_000;
        return (key, number.ToString("000000", CultureInfo.InvariantCulture));
    }

    /// <summary>Header names of a signed request.</summary>
    public static class Header
    {
        public const string Device = "x-gl-device";
        public const string Time = "x-gl-time";
        public const string Signature = "x-gl-signature";
        public const string Nonce = "x-gl-nonce";
        /// <summary>The plan's download token (v2, over TLS).</summary>
        public const string Token = "x-gl-token";
        /// <summary>SHA-256 of a whole downloaded file (lowercase hex).</summary>
        public const string Sha256 = "x-gl-sha256";
        /// <summary>"deflate": the body is raw DEFLATE (the catalog).</summary>
        public const string Encoding = "x-gl-encoding";
    }

    /// <summary>HMAC-SHA256 of "groovelight-certificate\nfingerprint\nnonce" with the pairing key, base64.</summary>
    public static string CertificateProof(string fingerprint, string nonce, byte[] key) =>
        Convert.ToBase64String(HMACSHA256.HashData(key, Encoding.UTF8.GetBytes($"groovelight-certificate\n{fingerprint}\n{nonce}")));

    /// <summary>"METHOD\npath\ntime\nnonce\nsha256(body) in hex", signed with HMAC-SHA256, in base64.</summary>
    public static string Signature(string method, string path, long time, string nonce, ReadOnlySpan<byte> body, byte[] key) =>
        Convert.ToBase64String(HMACSHA256.HashData(key, SignedMessage(method, path, time, nonce, body)));

    public static bool IsValid(string signature, string method, string path, long time, string nonce, ReadOnlySpan<byte> body, byte[] key, DateTime? now = null)
    {
        var seconds = (long)((now ?? DateTime.UtcNow) - DateTime.UnixEpoch).TotalSeconds;
        // Five minutes either way covers clocks a little off.
        if (Math.Abs(seconds - time) > 300 || nonce.Length == 0) return false;
        byte[] given;
        try { given = Convert.FromBase64String(signature); }
        catch (FormatException) { return false; }
        return CryptographicOperations.FixedTimeEquals(given, HMACSHA256.HashData(key, SignedMessage(method, path, time, nonce, body)));
    }

    private static byte[] SignedMessage(string method, string path, long time, string nonce, ReadOnlySpan<byte> body) =>
        Encoding.UTF8.GetBytes($"{method.ToUpperInvariant()}\n{path}\n{time}\n{nonce}\n{Sha256(body)}");

    public static string Sha256(ReadOnlySpan<byte> data) => Convert.ToHexStringLower(SHA256.HashData(data));

    public static string? Sha256(string file)
    {
        try
        {
            using var stream = File.OpenRead(file);
            return Convert.ToHexStringLower(SHA256.HashData(stream));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
    }

    // MARK: Messages

    /// <summary>GET /info: who is serving (no signature needed). <c>platform</c> tells the phones it is a Windows PC.</summary>
    public sealed record Info(string Id, string Name, int Version = WirelessProtocol.Version, int? TlsPort = null, List<string>? AwayAddresses = null,
                              string? Platform = "windows");

    /// <summary>POST /pair: a device asks to pair (its X25519 public key, base64).</summary>
    public sealed record PairRequest(string DeviceId, string Name, string? Model, string PublicKey);

    public sealed record PairResponse(string MacId, string MacName, string PublicKey);

    /// <summary>"pending", "accepted" or "rejected" (and "ok" when a sync is done).</summary>
    public sealed record PairStatus(string Status);

    public sealed record Certificate(string Fingerprint, string Proof);

    /// <summary>A storage volume of the device: internal memory, an SD card.</summary>
    public sealed record Volume(string Name, bool Removable, long Total, long Free, bool Music);

    /// <summary>POST /sync (signed): what the device holds.</summary>
    public sealed record SyncRequest
    {
        public DeviceManifest? Manifest { get; init; }
        public List<string> Files { get; init; } = [];
        public long Capacity { get; init; }
        public long Available { get; init; }
        public string? Model { get; init; }
        public string? Name { get; init; }
        public List<Volume>? Volumes { get; init; }
        /// <summary>"player" (Groovelight plays the music) or "sync" (another app does).</summary>
        public string? Mode { get; init; }
        /// <summary>Codecs the device decodes (player mode): the rest is converted to FLAC.</summary>
        public List<string>? Decodes { get; init; }
        /// <summary>"original" or a lossy encoding chosen on the device; null: as set on the computer.</summary>
        public string? Encoding { get; init; }

        [JsonIgnore] public bool IsPlayer => Mode == "player";
    }

    public sealed record PlanWrite(int Index, string Path, long Size, ManifestEntry Entry);

    /// <summary>The plan for the device.</summary>
    public sealed record SyncPlan(string Session, List<PlanWrite> Writes, List<string> Deletions, Dictionary<string, ManifestEntry> Unchanged, DeviceProfile Profile,
                                  int Songs, List<string> Skipped, string? Token = null);

    /// <summary>POST /sync/session/done (signed).</summary>
    public sealed record SyncResult(int Written, int Deleted, List<string> Failed, long? Available);

    /// <summary>GET /status (signed): whether the computer asked for a sync, so an open app starts one.</summary>
    public sealed record Status(bool SyncRequested, int PendingSends);

    public sealed record History(List<DeviceHistoryEvent> Events);

    public sealed record Requests([property: JsonPropertyName("requests")] List<TransferRequest> Items);

    // MARK: Playing on the computer (remote control)

    public sealed record RemoteItem(long Id, string Title, string Artist, string Album, string? AlbumKey, string? ArtworkHash, double Duration, bool? Loved = null);

    /// <summary>
    /// The player as a paired device sees it (<c>GET /remote</c>, HTTPS): what plays, where, and the queue. Positions are
    /// as of the answer; <c>Version</c> changes when anything but the steady progress of the song changes.
    /// </summary>
    public sealed record RemoteState
    {
        public RemoteItem? Item { get; init; }
        public bool Playing { get; init; }
        public double Position { get; init; }
        public double Rate { get; init; } = 1;
        public double Volume { get; init; }
        public bool Shuffle { get; init; }
        /// <summary>"off", "all" or "one".</summary>
        public string RepeatMode { get; init; } = "off";
        public List<long> Queue { get; init; } = [];
        public int? QueueIndex { get; init; }
        public string Version { get; init; } = "";

        /// <summary>What <c>Version</c> is made from, as of now: while playing, the moment the song started (rounded), which a seek moves.</summary>
        public string Signature(DateTime now)
        {
            var seconds = (now - DateTime.UnixEpoch).TotalSeconds;
            var anchor = Playing ? Math.Round(seconds - Position / Math.Max(Rate, 0.01)) : Math.Round(Position);
            var queueHash = Queue.Aggregate(17L, (hash, id) => unchecked(hash * 31 + id));
            return string.Join("|", Item?.Id.ToString(CultureInfo.InvariantCulture) ?? "-", Playing ? "p" : "s", ((long)anchor).ToString(CultureInfo.InvariantCulture),
                Volume.ToString("0.00", CultureInfo.InvariantCulture), Shuffle ? "1" : "0", RepeatMode, queueHash.ToString(CultureInfo.InvariantCulture),
                QueueIndex?.ToString(CultureInfo.InvariantCulture) ?? "-");
        }

        public RemoteState Versioned(DateTime now) => this with { Version = Signature(now) };

        /// <summary>A device playing nothing.</summary>
        public static RemoteState Idle(DateTime now) => new RemoteState { Volume = 1 }.Versioned(now);
    }

    /// <summary>Another device music can play on (<c>GET /remote/devices</c>): a phone with Groovelight open, reached through the computer.</summary>
    public sealed record RemoteDevice(string Id, string Name);

    public sealed record RemoteDevices(List<RemoteDevice> Devices);

    /// <summary>A command for a device music plays on, passed on from the device that sent it.</summary>
    public sealed record RelayedCommand(int Seq, string From, string FromName, RemoteCommand Command);

    public sealed record RelayCommands(List<RelayedCommand> Commands, int Last);

    /// <summary>A device's own player, for the devices controlling it (<c>POST /relay/state</c>).</summary>
    public sealed record RelayState(RemoteState? State, int Applied);
}

/// <summary>
/// What a device asks the player to do (<c>POST /remote</c>): a flat object, <c>{"command": "seek", "position": 42}</c>,
/// <c>{"command": "play", "songIds": [...], "startAt": 0, "position": 0, "shuffle": false}</c>, and so on.
/// </summary>
[JsonConverter(typeof(RemoteCommandConverter))]
public abstract record RemoteCommand
{
    public sealed record Play(List<long> SongIds, int StartAt, double Position, bool Shuffle) : RemoteCommand;
    public sealed record Pause : RemoteCommand;
    public sealed record Resume : RemoteCommand;
    public sealed record Next : RemoteCommand;
    public sealed record Previous : RemoteCommand;
    public sealed record Seek(double Position) : RemoteCommand;
    public sealed record SetVolume(double Volume) : RemoteCommand;
    public sealed record SetShuffle(bool On) : RemoteCommand;
    public sealed record SetRepeat(string Mode) : RemoteCommand;
    public sealed record Stop : RemoteCommand;
}

public sealed class RemoteCommandConverter : JsonConverter<RemoteCommand>
{
    public override RemoteCommand Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var document = JsonDocument.ParseValue(ref reader);
        var root = document.RootElement;
        double Number(string name) => root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number ? value.GetDouble() : 0;
        return root.GetProperty("command").GetString() switch
        {
            "play" => new RemoteCommand.Play(root.GetProperty("songIds").EnumerateArray().Select(item => item.GetInt64()).ToList(), (int)Number("startAt"), Number("position"),
                root.TryGetProperty("shuffle", out var shuffle) && shuffle.ValueKind == JsonValueKind.True),
            "pause" => new RemoteCommand.Pause(),
            "resume" => new RemoteCommand.Resume(),
            "next" => new RemoteCommand.Next(),
            "previous" => new RemoteCommand.Previous(),
            "seek" => new RemoteCommand.Seek(root.GetProperty("position").GetDouble()),
            "volume" => new RemoteCommand.SetVolume(root.GetProperty("volume").GetDouble()),
            "shuffle" => new RemoteCommand.SetShuffle(root.GetProperty("on").GetBoolean()),
            "repeatMode" => new RemoteCommand.SetRepeat(root.GetProperty("mode").GetString() ?? "off"),
            "stop" => new RemoteCommand.Stop(),
            var other => throw new JsonException($"Unknown command {other}"),
        };
    }

    public override void Write(Utf8JsonWriter writer, RemoteCommand value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        switch (value)
        {
            case RemoteCommand.Play play:
                writer.WriteString("command", "play");
                writer.WriteStartArray("songIds");
                foreach (var id in play.SongIds) writer.WriteNumberValue(id);
                writer.WriteEndArray();
                writer.WriteNumber("startAt", play.StartAt);
                writer.WriteNumber("position", play.Position);
                writer.WriteBoolean("shuffle", play.Shuffle);
                break;
            case RemoteCommand.Seek seek:
                writer.WriteString("command", "seek");
                writer.WriteNumber("position", seek.Position);
                break;
            case RemoteCommand.SetVolume volume:
                writer.WriteString("command", "volume");
                writer.WriteNumber("volume", volume.Volume);
                break;
            case RemoteCommand.SetShuffle shuffle:
                writer.WriteString("command", "shuffle");
                writer.WriteBoolean("on", shuffle.On);
                break;
            case RemoteCommand.SetRepeat repeat:
                writer.WriteString("command", "repeatMode");
                writer.WriteString("mode", repeat.Mode);
                break;
            default:
                writer.WriteString("command", value switch
                {
                    RemoteCommand.Pause => "pause", RemoteCommand.Resume => "resume", RemoteCommand.Next => "next", RemoteCommand.Previous => "previous", _ => "stop",
                });
                break;
        }
        writer.WriteEndObject();
    }
}
