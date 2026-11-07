using Groovelight.Core.Library;

namespace Groovelight.Tests;

/// <summary>The Swift tests' library helpers (LibraryDatabaseTests.makeTrack and seeded).</summary>
internal static class TestLibrary
{
    public static Track MakeTrack(long rootId, string title, string artist, string album, int number, bool compilation = false) => new()
    {
        RootId = rootId, Path = $"/music/{artist}/{album}/{number} {title}.flac", FileSize = 1, ModifiedAt = DateTime.UtcNow,
        Title = title, Artist = artist, Album = album, Genre = "Rock", Year = 1969, TrackNumber = number, DiscNumber = 1,
        IsCompilation = compilation, Duration = 180, Format = "FLAC", SampleRate = 44_100, BitDepth = 16, Channels = 2,
        AlbumKey = Track.MakeAlbumKey(album, null, artist, compilation), DateAdded = DateTime.UtcNow,
    };

    public static LibraryDatabase Seeded()
    {
        var database = LibraryDatabase.InMemory();
        var root = database.AddRoot("/music");
        var id = root.Id!.Value;
        database.Write(db =>
        {
            foreach (var track in new[]
            {
                MakeTrack(id, "Come Together", "The Beatles", "Abbey Road", 1),
                MakeTrack(id, "Something", "The Beatles", "Abbey Road", 2),
                MakeTrack(id, "Yellow Submarine", "The Beatles", "Revolver", 6),
                MakeTrack(id, "Paranoid Android", "Radiohead", "OK Computer", 2),
                MakeTrack(id, "Song A", "Someone", "Hits 1999", 1, compilation: true),
                MakeTrack(id, "Song B", "Other", "Hits 1999", 2, compilation: true),
            })
            {
                db.Insert(track);
            }
        });
        return database;
    }
}
