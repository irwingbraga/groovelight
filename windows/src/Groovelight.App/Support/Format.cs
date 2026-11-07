using System.Globalization;
using Groovelight.Core.Library;

namespace Groovelight.Support;

/// <summary>Text formats shared by the views.</summary>
public static class Format
{
    /// <summary>"3:07", "1:02:03", or "--:--".</summary>
    public static string Duration(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds < 0) return "--:--";
        var total = (int)Math.Round(seconds);
        int hours = total / 3600, minutes = total % 3600 / 60, rest = total % 60;
        return hours > 0 ? $"{hours}:{minutes:00}:{rest:00}" : $"{minutes}:{rest:00}";
    }

    /// <summary>"-2:10": the time left.</summary>
    public static string Remaining(double seconds) => "-" + Duration(Math.Max(0, seconds));

    /// <summary>"1 hr 5 min", "42 min".</summary>
    public static string LongDuration(double seconds)
    {
        var minutes = (int)(seconds / 60);
        return minutes >= 60 ? $"{minutes / 60} hr {minutes % 60} min" : $"{minutes} min";
    }

    public static string Count(int count, string singular, string? plural = null) =>
        $"{count.ToString("N0", CultureInfo.CurrentCulture)} {(count == 1 ? singular : plural ?? singular + "s")}";

    public static string Songs(int count) => Count(count, "song");

    /// <summary>"Rock · 1997" from the parts that are known.</summary>
    public static string Joined(params object?[] parts) =>
        string.Join(" · ", parts.Select(part => part?.ToString()).Where(part => !string.IsNullOrWhiteSpace(part)));

    /// <summary>"A, B and C".</summary>
    public static string List(IReadOnlyList<string> items) => items.Count switch
    {
        0 => "",
        1 => items[0],
        _ => string.Join(", ", items.Take(items.Count - 1)) + " and " + items[^1],
    };

    /// <summary>"2 minutes ago", "yesterday", "3 days ago", as the Mac's relative dates.</summary>
    public static string Relative(DateTime date)
    {
        var elapsed = System.DateTime.UtcNow - date.ToUniversalTime();
        if (elapsed < TimeSpan.FromMinutes(1)) return "now";
        if (elapsed < TimeSpan.FromHours(1)) return Count((int)elapsed.TotalMinutes, "minute") + " ago";
        if (elapsed < TimeSpan.FromDays(1)) return Count((int)elapsed.TotalHours, "hour") + " ago";
        if (elapsed < TimeSpan.FromDays(2)) return "yesterday";
        if (elapsed < TimeSpan.FromDays(30)) return Count((int)elapsed.TotalDays, "day") + " ago";
        return Date(date);
    }

    public static string Plays(int count) => count == 0 ? "" : count.ToString(CultureInfo.CurrentCulture);

    /// <summary>The artist's line of a song in a playlist row: "Artist — Album".</summary>
    public static string ArtistAndAlbum(Track track) => $"{track.DisplayArtist} — {track.DisplayAlbum}";

    public static string Date(DateTime? date) => date is { } value ? value.ToLocalTime().ToString("d", CultureInfo.CurrentCulture) : "";

    public static string DateTime(DateTime? date) => date is { } value ? value.ToLocalTime().ToString("g", CultureInfo.CurrentCulture) : "";

    public static string Bytes(long bytes)
    {
        string[] units = ["bytes", "KB", "MB", "GB", "TB"];
        double value = bytes;
        var unit = 0;
        while (value >= 1000 && unit < units.Length - 1) { value /= 1000; unit++; }
        return unit == 0 ? $"{bytes} bytes" : $"{value.ToString(value < 10 ? "0.#" : "0", CultureInfo.CurrentCulture)} {units[unit]}";
    }
}
