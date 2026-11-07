using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using Groovelight.Core.Devices;

namespace Groovelight.Wireless;

/// <summary>A request as the handler sees it.</summary>
public sealed record HttpRequest
{
    public string Method { get; init; } = "GET";
    /// <summary>Path without the query, percent-decoded.</summary>
    public string Path { get; init; } = "/";
    public Dictionary<string, string> Query { get; init; } = [];
    /// <summary>Lowercased names.</summary>
    public Dictionary<string, string> Headers { get; init; } = [];
    public byte[] Body { get; init; } = [];
    public IPAddress? Remote { get; init; }
    /// <summary>Came over TLS.</summary>
    public bool Secure { get; init; }
    /// <summary>Came from outside the computer's local networks (Tailscale, a VPN): see <see cref="AwayNetwork"/>.</summary>
    public bool IsAway { get; init; }
}

public sealed record HttpResponse
{
    public int Status { get; init; } = 200;
    public Dictionary<string, string> Headers { get; init; } = [];
    public byte[]? Data { get; init; }
    /// <summary>A file, or part of it (Range requests are answered from it).</summary>
    public string? FilePath { get; init; }

    public static HttpResponse Json<T>(T value, int status = 200) =>
        new() { Status = status, Headers = new() { ["Content-Type"] = "application/json" }, Data = WireJson.Encode(value) };

    public static HttpResponse Error(int status, string message) => Json(new Dictionary<string, string> { ["error"] = message }, status);
}

/// <summary>
/// A small HTTP/1.1 server for the local network (the Mac's LocalHTTPServer): one request per connection, JSON bodies up
/// to 64 MB, and file bodies streamed in 1 MB pieces with Range support (so a download cut off by Wi-Fi resumes). With
/// a certificate it serves HTTPS (TLS 1.2 or later) instead.
/// </summary>
public sealed class LocalHttpServer(Func<HttpRequest, CancellationToken, Task<HttpResponse>> handler, X509Certificate2? certificate = null)
{
    private const int MaximumBody = 64 * 1024 * 1024;
    private const int Chunk = 1024 * 1024;
    private TcpListener? listener;
    private CancellationTokenSource? stopping;

    public int Port { get; private set; }

    /// <summary>Starts listening on <paramref name="port"/> (any free one with 0), on every address; returns the port, or null when taken.</summary>
    public int? Start(int port = 0)
    {
        try
        {
            var socket = new TcpListener(IPAddress.IPv6Any, port);
            socket.Server.DualMode = true;
            socket.Start(64);
            listener = socket;
            Port = ((IPEndPoint)socket.LocalEndpoint).Port;
            stopping = new CancellationTokenSource();
            _ = AcceptAsync(socket, stopping.Token);
            return Port;
        }
        catch (SocketException)
        {
            return null;
        }
    }

    public void Stop()
    {
        stopping?.Cancel();
        listener?.Stop();
        listener = null;
    }

    private async Task AcceptAsync(TcpListener socket, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await socket.AcceptTcpClientAsync(token); }
            catch (Exception error) when (error is OperationCanceledException or ObjectDisposedException or SocketException) { return; }
            _ = ServeAsync(client, token);
        }
    }

    private async Task ServeAsync(TcpClient client, CancellationToken token)
    {
        using (client)
        {
            client.NoDelay = true;
            var remote = (client.Client.RemoteEndPoint as IPEndPoint)?.Address;
            Stream stream = client.GetStream();
            try
            {
                if (certificate is not null)
                {
                    var ssl = new SslStream(stream, false);
                    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
                    timeout.CancelAfter(TimeSpan.FromSeconds(30));
                    await ssl.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
                    {
                        ServerCertificate = certificate, EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13, ClientCertificateRequired = false,
                    }, timeout.Token);
                    stream = ssl;
                }
                var request = await ReadRequestAsync(stream, remote, token);
                if (request is null) return;
                HttpResponse response;
                try { response = await handler(request, token); }
                catch (Exception error) when (error is not OperationCanceledException) { response = HttpResponse.Error(500, error.Message); }
                await SendAsync(stream, response, request, token);
                // The device closes its side once it has read everything (Connection: close): wait for that, a minute at most,
                // so nothing still in the buffers is dropped.
                if (stream is SslStream secure) await secure.ShutdownAsync();
                client.Client.Shutdown(SocketShutdown.Send);
                using var drain = CancellationTokenSource.CreateLinkedTokenSource(token);
                drain.CancelAfter(TimeSpan.FromSeconds(60));
                var buffer = new byte[4096];
                while (await stream.ReadAsync(buffer, drain.Token) > 0) { }
            }
            catch (Exception error) when (error is IOException or SocketException or AuthenticationException or OperationCanceledException or ObjectDisposedException) { }
            finally
            {
                await stream.DisposeAsync();
            }
        }
    }

    private async Task<HttpRequest?> ReadRequestAsync(Stream stream, IPAddress? remote, CancellationToken token)
    {
        var buffer = new MemoryStream();
        var chunk = new byte[64 * 1024];
        int end;
        while ((end = HeadEnd(buffer)) < 0)
        {
            if (buffer.Length > 64 * 1024) return null;
            var read = await stream.ReadAsync(chunk, token);
            if (read == 0) return null;
            buffer.Write(chunk, 0, read);
        }
        var all = buffer.ToArray();
        var parsed = ParseHead(Encoding.UTF8.GetString(all, 0, end));
        if (parsed is null)
        {
            await SendAsync(stream, HttpResponse.Error(400, "bad request"), null, token);
            return null;
        }
        var length = parsed.Headers.TryGetValue("content-length", out var text) && int.TryParse(text, out var value) ? value : 0;
        if (length > MaximumBody)
        {
            await SendAsync(stream, HttpResponse.Error(413, "too large"), null, token);
            return null;
        }
        var body = new MemoryStream();
        body.Write(all, end + 4, all.Length - end - 4);
        while (body.Length < length)
        {
            var read = await stream.ReadAsync(chunk.AsMemory(0, (int)Math.Min(chunk.Length, length - body.Length)), token);
            if (read == 0) return null;
            body.Write(chunk, 0, read);
        }
        return parsed with
        {
            Body = body.ToArray()[..length], Remote = remote, Secure = certificate is not null, IsAway = remote is null || AwayNetwork.IsAway(remote),
        };
    }

    private static int HeadEnd(MemoryStream buffer)
    {
        var bytes = buffer.GetBuffer();
        for (var index = 0; index + 3 < buffer.Length; index++)
            if (bytes[index] == '\r' && bytes[index + 1] == '\n' && bytes[index + 2] == '\r' && bytes[index + 3] == '\n') return index;
        return -1;
    }

    internal static HttpRequest? ParseHead(string head)
    {
        var lines = head.Split("\r\n");
        var parts = lines[0].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2) return null;
        var headers = new Dictionary<string, string>();
        foreach (var line in lines.Skip(1))
        {
            var colon = line.IndexOf(':');
            if (colon <= 0) continue;
            headers[line[..colon].ToLowerInvariant()] = line[(colon + 1)..].Trim();
        }
        var target = parts[1];
        var question = target.IndexOf('?');
        var rawPath = question >= 0 ? target[..question] : target;
        var query = new Dictionary<string, string>();
        if (question >= 0)
        {
            foreach (var pair in target[(question + 1)..].Split('&', StringSplitOptions.RemoveEmptyEntries))
            {
                var equals = pair.IndexOf('=');
                var name = Uri.UnescapeDataString((equals >= 0 ? pair[..equals] : pair).Replace('+', ' '));
                query[name] = equals >= 0 ? Uri.UnescapeDataString(pair[(equals + 1)..].Replace('+', ' ')) : "";
            }
        }
        return new HttpRequest { Method = parts[0].ToUpperInvariant(), Path = Uri.UnescapeDataString(rawPath), Query = query, Headers = headers };
    }

    private static async Task SendAsync(Stream stream, HttpResponse response, HttpRequest? request, CancellationToken token)
    {
        if (response.FilePath is not { } path)
        {
            var data = response.Data ?? [];
            await stream.WriteAsync(Head(response.Status, response.Headers, data.Length), token);
            await stream.WriteAsync(data, token);
            await stream.FlushAsync(token);
            return;
        }
        FileStream file;
        try { file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, Chunk, true); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            await SendAsync(stream, HttpResponse.Error(404, "missing file"), request, token);
            return;
        }
        await using (file)
        {
            var size = file.Length;
            var status = response.Status;
            var headers = new Dictionary<string, string>(response.Headers) { ["Accept-Ranges"] = "bytes" };
            headers.TryAdd("Content-Type", "application/octet-stream");
            long start = 0, end = size - 1;
            // A resumed download names the version it has (If-Range): another version of the file starts over.
            var sameVersion = request?.Headers.TryGetValue("if-range", out var ifRange) != true || headers.TryGetValue("ETag", out var etag) && ifRange == etag;
            if (sameVersion && request?.Headers.TryGetValue("range", out var range) == true && ParseRange(range, size) is { } parsed)
            {
                (start, end) = parsed;
                status = 206;
                headers["Content-Range"] = $"bytes {start}-{end}/{size}";
            }
            var length = Math.Max(end - start + 1, 0);
            await stream.WriteAsync(Head(status, headers, length), token);
            file.Seek(start, SeekOrigin.Begin);
            var buffer = new byte[Chunk];
            var remaining = length;
            while (remaining > 0)
            {
                var read = await file.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, remaining)), token);
                if (read == 0) break;
                await stream.WriteAsync(buffer.AsMemory(0, read), token);
                remaining -= read;
            }
            await stream.FlushAsync(token);
        }
    }

    /// <summary>"bytes=100-" or "bytes=100-199" or "bytes=-10" (one range).</summary>
    internal static (long Start, long End)? ParseRange(string header, long size)
    {
        if (!header.StartsWith("bytes=", StringComparison.Ordinal) || size <= 0) return null;
        var spec = header[6..].Split(',')[0];
        var bounds = spec.Split('-').Select(part => part.Trim()).ToArray();
        if (bounds.Length != 2) return null;
        if (bounds[0].Length == 0 && long.TryParse(bounds[1], out var suffix)) return (Math.Max(size - suffix, 0), size - 1);
        if (!long.TryParse(bounds[0], out var start) || start >= size) return null;
        var end = long.TryParse(bounds[1], out var last) ? Math.Min(last, size - 1) : size - 1;
        return end >= start ? (start, end) : null;
    }

    internal static byte[] Head(int status, Dictionary<string, string> headers, long length)
    {
        var lines = new List<string> { $"HTTP/1.1 {status} {Reason(status)}", $"Content-Length: {length}", "Connection: close" };
        foreach (var (name, value) in headers.OrderBy(pair => pair.Key, StringComparer.Ordinal)) lines.Add($"{name}: {value}");
        return Encoding.UTF8.GetBytes(string.Join("\r\n", lines) + "\r\n\r\n");
    }

    private static string Reason(int status) => status switch
    {
        200 => "OK", 206 => "Partial Content", 304 => "Not Modified", 400 => "Bad Request", 401 => "Unauthorized", 403 => "Forbidden", 404 => "Not Found",
        409 => "Conflict", 413 => "Payload Too Large", 500 => "Internal Server Error", 504 => "Gateway Timeout", _ => "Status",
    };
}
