using System.Net;
using System.Text;

namespace Groovelight.Metadata;

public enum MetadataErrorKind { NotFound, Http, InvalidResponse }

public sealed class MetadataException(MetadataErrorKind kind, int status = 0)
    : Exception(kind == MetadataErrorKind.Http ? $"The server answered {status}." : kind == MetadataErrorKind.NotFound ? "Not found." : "Invalid response.")
{
    public MetadataErrorKind Kind { get; } = kind;
    public int Status { get; } = status;
}

/// <summary>Fetches a URL. Abstracted so tests can serve canned responses.</summary>
public interface IHttpFetcher
{
    Task<(byte[] Data, int Status)> GetAsync(Uri url, IReadOnlyDictionary<string, string> headers, CancellationToken cancellation = default);
}

public sealed class HttpFetcher : IHttpFetcher
{
    private static readonly HttpClient Shared = new(new SocketsHttpHandler { AutomaticDecompression = DecompressionMethods.All, PooledConnectionLifetime = TimeSpan.FromMinutes(5) })
    {
        Timeout = TimeSpan.FromSeconds(20),
    };

    public async Task<(byte[] Data, int Status)> GetAsync(Uri url, IReadOnlyDictionary<string, string> headers, CancellationToken cancellation = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        foreach (var (name, value) in headers) request.Headers.TryAddWithoutValidation(name, value);
        using var response = await Shared.SendAsync(request, cancellation);
        return (await response.Content.ReadAsByteArrayAsync(cancellation), (int)response.StatusCode);
    }
}

/// <summary>Spaces requests at least <c>interval</c> apart (MusicBrainz allows one request per second per client).</summary>
public sealed class RateLimiter(TimeSpan interval)
{
    private readonly Lock gate = new();
    private DateTime next = DateTime.MinValue;

    public async Task WaitAsync(CancellationToken cancellation = default)
    {
        DateTime slot;
        lock (gate)
        {
            var now = DateTime.UtcNow;
            slot = now > next ? now : next;
            next = slot + interval;
        }
        var delay = slot - DateTime.UtcNow;
        if (delay > TimeSpan.Zero) await Task.Delay(delay, cancellation);
    }
}

/// <summary>Identifies the app to web services, as MusicBrainz and LRCLIB ask.</summary>
public sealed record ClientIdentity(string Version, string Name = "Groovelight", string? Contact = null)
{
    public string UserAgent => string.IsNullOrEmpty(Contact) ? $"{Name}/{Version}" : $"{Name}/{Version} ( {Contact} )";
}

public static class HttpFetching
{
    /// <summary>GET returning the body, with NotFound for 404 and Http for other failures.</summary>
    public static async Task<byte[]> GetAsync(this IHttpFetcher fetcher, Uri url, ClientIdentity identity, string accept = "application/json",
                                               CancellationToken cancellation = default)
    {
        var (data, status) = await fetcher.GetAsync(url, new Dictionary<string, string> { ["User-Agent"] = identity.UserAgent, ["Accept"] = accept }, cancellation);
        return status switch
        {
            >= 200 and < 300 => data,
            404 => throw new MetadataException(MetadataErrorKind.NotFound),
            _ => throw new MetadataException(MetadataErrorKind.Http, status),
        };
    }

    /// <summary>GET through a rate limiter, retrying "busy" answers (503, 429) with a growing backoff.</summary>
    public static async Task<byte[]> GetAsync(this IHttpFetcher fetcher, Uri url, ClientIdentity identity, RateLimiter limiter,
                                               string accept = "application/json", CancellationToken cancellation = default)
    {
        for (var attempt = 0; attempt < 3; attempt++)
        {
            await limiter.WaitAsync(cancellation);
            try
            {
                return await fetcher.GetAsync(url, identity, accept, cancellation);
            }
            catch (MetadataException error) when (error.Kind == MetadataErrorKind.Http && error.Status is 503 or 429 && attempt < 2)
            {
                await Task.Delay(TimeSpan.FromSeconds(1.5 * (attempt + 1)), cancellation);
            }
        }
        throw new MetadataException(MetadataErrorKind.Http, 503);
    }

    /// <summary>A URL with its query items sorted by name (nil values left out).</summary>
    public static Uri Build(string baseUrl, IEnumerable<KeyValuePair<string, string?>> items)
    {
        var query = string.Join("&", items.Where(pair => pair.Value is not null).OrderBy(pair => pair.Key, StringComparer.Ordinal)
            .Select(pair => $"{Uri.EscapeDataString(pair.Key)}={Uri.EscapeDataString(pair.Value!)}"));
        return new Uri(query.Length == 0 ? baseUrl : $"{baseUrl}?{query}");
    }

    public static Uri Build(string baseUrl, params (string Key, string? Value)[] items) =>
        Build(baseUrl, items.Select(item => new KeyValuePair<string, string?>(item.Key, item.Value)));

    internal static string Utf8(byte[] data) => Encoding.UTF8.GetString(data);
}
