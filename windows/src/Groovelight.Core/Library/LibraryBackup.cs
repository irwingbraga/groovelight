using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Data.Sqlite;

namespace Groovelight.Core.Library;

/// <summary>
/// Backups of everything Groovelight keeps outside the music files: the library database (play counts, ratings, loves,
/// playlists and covers, smart rules, metadata fixes, fetched lyrics, credits and backgrounds, library folders), the
/// artwork folder and the app's preferences. The Mac's format: a folder (a package there) with <c>Library.sqlite</c>,
/// <c>Artwork\</c>, <c>Preferences.plist</c> and <c>Manifest.json</c>, so a backup restores on either.
/// </summary>
public static class LibraryBackup
{
    public const string FileExtension = "groovelightbackup";
    internal const int FormatVersion = 1;

    public sealed record Manifest
    {
        public int FormatVersion { get; init; }
        public string AppVersion { get; init; } = "";
        public DateTime CreatedAt { get; init; }
        public string? ComputerName { get; init; }
        public int TrackCount { get; init; }
        public int PlaylistCount { get; init; }
        public int LovedCount { get; init; }
        public int PlayCount { get; init; }
        public int ArtworkCount { get; init; }
        /// <summary>Library folders at backup time; they must be located again after restoring on another computer.</summary>
        public List<string> Folders { get; init; } = [];
    }

    public sealed class BackupException(string message) : Exception(message)
    {
        public static BackupException NotABackup() => new("This is not a Groovelight backup.");
        public static BackupException NewerFormat(int version) => new($"This backup was made by a newer version of Groovelight (format {version}).");
    }

    /// <summary>Swift's ISO 8601 dates: whole seconds, "Z" (its decoder rejects fractions).</summary>
    private sealed class SwiftIso8601Converter : JsonConverter<DateTime>
    {
        public override DateTime Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            DateTime.Parse(reader.GetString()!, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal);

        public override void Write(Utf8JsonWriter writer, DateTime value, JsonSerializerOptions options) =>
            writer.WriteStringValue(value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture));
    }

    private static readonly JsonSerializerOptions ManifestJson = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new SwiftIso8601Converter() },
    };

    /// <summary>
    /// Writes a backup at <paramref name="path"/> (replacing it). The database copy is a consistent snapshot, taken with
    /// SQLite's backup API while the library stays open. <paramref name="preferences"/> is property list data.
    /// </summary>
    public static Manifest Write(LibraryDatabase database, string artworkDirectory, byte[] preferences, string appVersion, string path)
    {
        // Build in the temporary folder, then move into place, so a failed backup never leaves a half-written one.
        var staging = Path.Combine(Path.GetTempPath(), $"backup-{Guid.NewGuid()}");
        Directory.CreateDirectory(staging);
        try
        {
            database.BackUp(Path.Combine(staging, "Library.sqlite"));
            SqliteConnection.ClearAllPools();

            var artwork = Path.Combine(staging, "Artwork");
            Directory.CreateDirectory(artwork);
            var artworkCount = 0;
            if (Directory.Exists(artworkDirectory))
            {
                foreach (var file in Directory.GetFiles(artworkDirectory))
                {
                    File.Copy(file, Path.Combine(artwork, Path.GetFileName(file)));
                    artworkCount++;
                }
            }
            File.WriteAllBytes(Path.Combine(staging, "Preferences.plist"), preferences);

            var manifest = database.Read(db => new Manifest
            {
                FormatVersion = FormatVersion, AppVersion = appVersion, CreatedAt = DateTime.UtcNow, ComputerName = Environment.MachineName,
                TrackCount = db.Scalar<int>("SELECT COUNT(*) FROM track"), PlaylistCount = db.Scalar<int>("SELECT COUNT(*) FROM playlist"),
                LovedCount = db.Scalar<int>("SELECT COUNT(*) FROM track WHERE isLoved"),
                PlayCount = db.Scalar<int>("SELECT COALESCE(SUM(playCount), 0) FROM track"),
                ArtworkCount = artworkCount, Folders = db.Roots().Select(root => root.Path).ToList(),
            });
            File.WriteAllText(Path.Combine(staging, "Manifest.json"), JsonSerializer.Serialize(manifest, ManifestJson));

            if (Directory.Exists(path)) Directory.Delete(path, recursive: true);
            MoveDirectory(staging, path);
            return manifest;
        }
        catch
        {
            try { Directory.Delete(staging, recursive: true); } catch (IOException) { }
            throw;
        }
    }

    /// <summary>A rename when both are on one volume, else a copy (the temporary folder may be on another drive).</summary>
    private static void MoveDirectory(string from, string to)
    {
        try
        {
            Directory.Move(from, to);
        }
        catch (IOException)
        {
            Directory.CreateDirectory(to);
            foreach (var file in Directory.EnumerateFiles(from, "*", SearchOption.AllDirectories))
            {
                var destination = Path.Combine(to, Path.GetRelativePath(from, file));
                Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                File.Copy(file, destination);
            }
            Directory.Delete(from, recursive: true);
        }
    }

    public static Manifest ReadManifest(string path)
    {
        var manifestPath = Path.Combine(path, "Manifest.json");
        if (!File.Exists(manifestPath) || !File.Exists(Path.Combine(path, "Library.sqlite"))) throw BackupException.NotABackup();
        Manifest? manifest;
        try { manifest = JsonSerializer.Deserialize<Manifest>(File.ReadAllText(manifestPath), ManifestJson); }
        catch (JsonException) { throw BackupException.NotABackup(); }
        if (manifest is null) throw BackupException.NotABackup();
        if (manifest.FormatVersion > FormatVersion) throw BackupException.NewerFormat(manifest.FormatVersion);
        return manifest;
    }

    /// <summary>
    /// Replaces the library with the backup's (in place, while it stays open), brings the schema up to date, and adds the
    /// backup's artwork. Returns the backup's preferences (property list data) for the app to apply.
    /// </summary>
    public static byte[]? Restore(string path, LibraryDatabase database, string artworkDirectory)
    {
        ReadManifest(path);
        // Read from a temporary copy: the backup itself is never modified, and SQLite may need to write side files.
        var temporary = Path.Combine(Path.GetTempPath(), $"restore-{Guid.NewGuid()}.sqlite");
        File.Copy(Path.Combine(path, "Library.sqlite"), temporary);
        try
        {
            database.RestoreFrom(temporary);
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            File.Delete(temporary);
        }

        Directory.CreateDirectory(artworkDirectory);
        var artwork = Path.Combine(path, "Artwork");
        if (Directory.Exists(artwork))
        {
            foreach (var file in Directory.GetFiles(artwork))
            {
                var destination = Path.Combine(artworkDirectory, Path.GetFileName(file));
                // Content-addressed names: an existing file is the same image.
                if (!File.Exists(destination)) File.Copy(file, destination);
            }
        }
        var preferences = Path.Combine(path, "Preferences.plist");
        return File.Exists(preferences) ? File.ReadAllBytes(preferences) : null;
    }
}

public sealed partial class LibraryDatabase
{
    /// <summary>Replaces this database's contents with the database file at <paramref name="path"/>, then migrates it.</summary>
    internal void RestoreFrom(string path)
    {
        lock (writeLock)
        {
            using (var source = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Pooling = false }.ToString()))
            using (var destination = Open())
            {
                source.Open();
                source.BackupDatabase(destination);
            }
            // Backups from older versions get the newer tables and columns.
            using var connection = Open();
            Migrations.Migrate(connection);
        }
        Changed?.Invoke();
    }

    /// <summary>
    /// Points a library folder (and all its songs) at a new location, e.g. after restoring on another computer, keeping
    /// every song's history. Returns the number of songs moved.
    /// </summary>
    public int RelocateRoot(long rootId, string newPath, byte[]? bookmark = null) => Write(db =>
    {
        var root = db.QueryOne("SELECT * FROM libraryRoot WHERE id = ?", Records.ReadRoot, rootId);
        if (root is null) return 0;
        static string Trim(string path) => path.Length > 1 ? path.TrimEnd('/', '\\') : path;
        var old = Trim(root.Path);
        var @new = Trim(newPath);
        db.Execute("UPDATE libraryRoot SET path = ?, bookmark = ?, eventId = NULL, eventsVolumeId = NULL WHERE id = ?", @new, bookmark ?? root.Bookmark, rootId);
        if (old == @new) return 0;
        // The old folder's separator: a Mac backup has "/" paths, a Windows one "\".
        var oldSeparator = old.Contains('\\') && !old.Contains('/') ? '\\' : '/';
        var newSeparator = Path.DirectorySeparatorChar;
        // SQLite's substr counts code points (Mac file names are often decomposed: "é" is two), not UTF-16 units.
        var start = old.EnumerateRunes().Count() + 1;
        var prefix = LikePrefix(old + oldSeparator) + "%";
        var moved = db.Execute("""
            UPDATE track SET path = ? || REPLACE(substr(path, ?), ?, ?) WHERE rootId = ? AND (path = ? OR path LIKE ? ESCAPE '\')
            """, @new, start, oldSeparator.ToString(), newSeparator.ToString(), rootId, old, prefix);
        // CUE tracks also point at their audio file.
        db.Execute("""
            UPDATE track SET audioPath = ? || REPLACE(substr(audioPath, ?), ?, ?) WHERE rootId = ? AND audioPath LIKE ? ESCAPE '\'
            """, @new, start, oldSeparator.ToString(), newSeparator.ToString(), rootId, prefix);
        return moved;
    });

    internal static string LikePrefix(string text) => text.Replace("\\", "\\\\").Replace("%", "\\%").Replace("_", "\\_");
}
