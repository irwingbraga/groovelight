using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Groovelight.Core;

/// <summary>Dates as the Mac stores them, so a library or a backup reads the same on both.</summary>
public static class Dates
{
    /// <summary>The database form: UTC, "yyyy-MM-dd HH:mm:ss.SSS" (GRDB's).</summary>
    public static string ToDatabase(DateTime date) =>
        date.ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture);

    private static readonly string[] DatabaseFormats =
    [
        "yyyy-MM-dd HH:mm:ss.fff", "yyyy-MM-dd HH:mm:ss.ff", "yyyy-MM-dd HH:mm:ss.f", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd'T'HH:mm:ss.fff", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd",
    ];

    public static DateTime FromDatabase(string text) =>
        DateTime.ParseExact(text.TrimEnd('Z'), DatabaseFormats, CultureInfo.InvariantCulture,
                            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);

    /// <summary>Swift's default JSON date: seconds since 2001-01-01 UTC.</summary>
    public static readonly DateTime ReferenceDate = new(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    public static double ToReferenceSeconds(DateTime date) => (date.ToUniversalTime() - ReferenceDate).TotalSeconds;

    public static DateTime FromReferenceSeconds(double seconds) => ReferenceDate.AddTicks((long)Math.Round(seconds * TimeSpan.TicksPerSecond));
}

/// <summary>Writes and reads dates as Swift's <c>JSONEncoder</c> does by default (seconds since 2001).</summary>
public sealed class ReferenceDateConverter : JsonConverter<DateTime>
{
    public override DateTime Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        Dates.FromReferenceSeconds(reader.GetDouble());

    public override void Write(Utf8JsonWriter writer, DateTime value, JsonSerializerOptions options) =>
        writer.WriteNumberValue(Dates.ToReferenceSeconds(value));
}

/// <summary>JSON settings matching the Mac's encoders: camelCase keys, nil values left out, Swift dates.</summary>
public static class SwiftJson
{
    public static readonly JsonSerializerOptions Options = Create();

    private static JsonSerializerOptions Create()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        };
        options.Converters.Add(new ReferenceDateConverter());
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
        return options;
    }

    public static byte[] Encode<T>(T value) => JsonSerializer.SerializeToUtf8Bytes(value, Options);

    public static T? Decode<T>(byte[]? data)
    {
        if (data is null) return default;
        try { return JsonSerializer.Deserialize<T>(data, Options); }
        catch (JsonException) { return default; }
    }
}
