using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace Groovelight.Core.Library;

/// <summary>
/// A person (or group, or studio) credited in the library. Identified by their MusicBrainz artist id when known,
/// otherwise by name (studios, or credits without an id).
/// </summary>
public sealed record CreditPerson(string Name, string? ArtistId);

/// <summary>One credit of a person on an album (<see cref="TrackId"/> null: anywhere on the album) or on one song.</summary>
public sealed record CreditIndexEntry(CreditPerson Person, string AlbumKey, long? TrackId, IReadOnlyList<string> Roles, bool WholeRelease = false);

/// <summary>What a person did in the library: albums and songs with their roles there.</summary>
public sealed record PersonCredits(CreditPerson Person, IReadOnlyList<(AlbumSummary Album, IReadOnlyList<string> Roles)> Albums,
                                   IReadOnlyList<(Track Track, IReadOnlyList<string> Roles)> Tracks, IReadOnlyList<string> Roles);

public sealed partial class LibraryDatabase
{
    /// <summary>Replaces the credits indexed for an album.</summary>
    public void SetCredits(IEnumerable<CreditIndexEntry> entries, string albumKey) => Write(db =>
    {
        db.Execute("DELETE FROM creditIndex WHERE albumKey = ?", albumKey);
        foreach (var entry in entries)
        {
            db.Execute("""
                INSERT INTO creditIndex (name, nameKey, artistId, albumKey, trackId, roles, wholeRelease) VALUES (?, ?, ?, ?, ?, ?, ?)
                """, entry.Person.Name, entry.Person.Name.ToLowerInvariant(), entry.Person.ArtistId, entry.AlbumKey, entry.TrackId,
                string.Join('\n', entry.Roles), entry.WholeRelease);
        }
    });
}

public static class CreditQueries
{
    /// <summary>Every cached album info (album key and JSON), to rebuild the index.</summary>
    public static List<(string AlbumKey, byte[] Data)> AllAlbumInfo(this SqliteConnection db) =>
        db.Query("SELECT albumKey, data FROM albumInfo", row => (row.Required<string>("albumKey"), row.Required<byte[]>("data")));

    /// <summary>Every cached artist info (lowercased name and JSON).</summary>
    public static List<(string ArtistKey, byte[] Data)> AllArtistInfo(this SqliteConnection db) =>
        db.Query("SELECT artistKey, data FROM artistInfo", row => (row.Required<string>("artistKey"), row.Required<byte[]>("data")));

    /// <summary>The photos known for these artists (in the artwork cache), by name as given, matched without case.</summary>
    public static Dictionary<string, string> ArtistPhotos(this SqliteConnection db, IEnumerable<string> names)
    {
        var wanted = new Dictionary<string, string>();
        foreach (var name in names) wanted.TryAdd(name.ToLowerInvariant(), name);
        var photos = new Dictionary<string, string>();
        if (wanted.Count == 0) return photos;
        foreach (var (key, data) in db.AllArtistInfo())
        {
            if (!wanted.TryGetValue(key, out var name)) continue;
            try
            {
                using var document = JsonDocument.Parse(data);
                if (document.RootElement.TryGetProperty("imageHash", out var hash) && hash.GetString() is { } value) photos[name] = value;
            }
            catch (JsonException) { }
        }
        return photos;
    }

    /// <summary>Albums (with a title) whose credits were never looked up.</summary>
    public static List<string> AlbumKeysWithoutInfo(this SqliteConnection db) => db.Column<string>("""
        SELECT DISTINCT albumKey FROM track WHERE albumKey NOT IN (SELECT albumKey FROM albumInfo) AND COALESCE(album, '') != ''
        """);

    /// <summary>Library artists (album artists of non-compilations) whose background was never looked up.</summary>
    public static List<string> ArtistNamesWithoutInfo(this SqliteConnection db)
    {
        var known = db.Column<string>("SELECT artistKey FROM artistInfo").ToHashSet();
        return db.Artists().Select(artist => artist.Name).Where(name =>
            name.ToLowerInvariant() is not ("unknown artist" or "various artists") && !known.Contains(name.ToLowerInvariant())).ToList();
    }

    /// <summary>Songs without lyrics (from the file or online) whose online lookup never ran.</summary>
    public static List<long> TrackIdsNeedingLyrics(this SqliteConnection db) => db.Column<long>("""
        SELECT id FROM track WHERE COALESCE(lyrics, '') = '' AND COALESCE(fetchedLyrics, '') = '' AND lyricsCheckedAt IS NULL
        ORDER BY dateAdded DESC
        """);

    public static int CreditIndexCount(this SqliteConnection db) => db.Scalar<int>("SELECT COUNT(*) FROM creditIndex");

    /// <summary>Albums whose credits are known (fetched), and all albums, for "credits known for N of M albums".</summary>
    public static (int Known, int Total) CreditCoverage(this SqliteConnection db) =>
        (db.Scalar<int>("SELECT COUNT(*) FROM albumInfo WHERE albumKey IN (SELECT DISTINCT albumKey FROM track)"),
         db.Scalar<int>("SELECT COUNT(DISTINCT albumKey) FROM track"));

    /// <summary>
    /// Everything a person is credited on. Songs: the ones credited to them, plus every song of albums where they are
    /// credited on the release itself (mastering, design...). Someone credited only on songs that are not in the library
    /// shows the album without songs.
    /// </summary>
    public static PersonCredits Credits(this SqliteConnection db, CreditPerson person)
    {
        var rows = person.ArtistId is { } artistId
            ? db.Query("SELECT * FROM creditIndex WHERE artistId = ?", ReadEntryRow, artistId)
            : db.Query("SELECT * FROM creditIndex WHERE artistId IS NULL AND nameKey = ?", ReadEntryRow, person.Name.ToLowerInvariant());

        var albumRoles = new Dictionary<string, List<string>>();
        var trackRoles = new Dictionary<long, List<string>>();
        var albumsWithTrackCredits = new HashSet<string>();
        var wholeReleaseAlbums = new HashSet<string>();
        var roleCounts = new Dictionary<string, int>();
        foreach (var (albumKey, trackId, roles, wholeRelease) in rows)
        {
            if (trackId is { } id)
            {
                var list = trackRoles.TryGetValue(id, out var existing) ? existing : trackRoles[id] = [];
                list.AddRange(roles.Where(role => !list.Contains(role)).ToList());
                albumsWithTrackCredits.Add(albumKey);
            }
            else
            {
                if (wholeRelease) wholeReleaseAlbums.Add(albumKey);
                var list = albumRoles.TryGetValue(albumKey, out var existing) ? existing : albumRoles[albumKey] = [];
                list.AddRange(roles.Where(role => !list.Contains(role)).ToList());
                foreach (var role in roles) roleCounts[role] = roleCounts.GetValueOrDefault(role) + 1;
            }
        }

        var albums = db.Albums(AlbumSort.Year).Where(album => albumRoles.ContainsKey(album.AlbumKey) || albumsWithTrackCredits.Contains(album.AlbumKey)).ToList();
        var tracks = new List<(Track, IReadOnlyList<string>)>();
        foreach (var album in albums)
        {
            var albumTracks = db.TracksOfAlbum(album.AlbumKey);
            if (wholeReleaseAlbums.Contains(album.AlbumKey))
            {
                // Release credits apply to every song, alongside any song-specific roles.
                foreach (var track in albumTracks)
                {
                    var own = track.Id is { } id && trackRoles.TryGetValue(id, out var list) ? list : [];
                    tracks.Add((track, own.Count == 0 ? albumRoles.GetValueOrDefault(album.AlbumKey) ?? [] : own));
                }
            }
            else
            {
                foreach (var track in albumTracks)
                    if (track.Id is { } id && trackRoles.TryGetValue(id, out var list)) tracks.Add((track, list));
            }
        }
        var sortedRoles = roleCounts.OrderByDescending(pair => pair.Value).ThenBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => pair.Key).ToList();
        return new PersonCredits(person, albums.Select(album => (album, (IReadOnlyList<string>)(albumRoles.GetValueOrDefault(album.AlbumKey) ?? []))).ToList(),
                                 tracks, sortedRoles);
    }

    private static (string AlbumKey, long? TrackId, string[] Roles, bool WholeRelease) ReadEntryRow(Row row) =>
        (row.Required<string>("albumKey"), row.Get<long?>("trackId"), (row.Get<string>("roles") ?? "").Split('\n', StringSplitOptions.RemoveEmptyEntries), row.Get<bool>("wholeRelease"));
}
