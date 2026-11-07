using Groovelight.Core;
using Groovelight.Core.Library;
using Microsoft.Data.Sqlite;

namespace Groovelight.Tests;

/// <summary>
/// A library database written by the Mac app (GroovelightKit, `Fixtures/MacLibrary.sqlite`) opens here as is: same
/// migrations, schema, dates and JSON. Backups carry this file, so this is what restoring a Mac backup relies on.
/// </summary>
public class MacCompatibilityTests
{
    private static string CopyOfFixture()
    {
        var path = Path.Combine(Path.GetTempPath(), $"gl-mac-{Guid.NewGuid():N}.sqlite");
        File.Copy(Path.Combine(AppContext.BaseDirectory, "Fixtures", "MacLibrary.sqlite"), path);
        return path;
    }

    private static string Schema(SqliteConnection db) => string.Join("\n", db.Column<string>(
        "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' ORDER BY type, name"));

    [Fact]
    public void OpensTheMacsLibraryAndReadsItsValues()
    {
        var path = CopyOfFixture();
        using (var database = LibraryDatabase.Open(path))
        {
            var track = database.Read(db => db.AllTracks()).Single();
            Assert.Equal("Song", track.Title);
            Assert.Equal(DateTime.UnixEpoch.AddSeconds(1_700_000_000.123), track.DateAdded, TimeSpan.FromMilliseconds(1));
            Assert.Equal(DateTime.UnixEpoch.AddSeconds(1_600_000_000), track.ModifiedAt);
            Assert.True(track.IsLoved);
            Assert.Equal(QualityTier.HiResLossless, track.AudioSpec.Tier);
            Assert.Equal(new TrackMetadata { Title = "Fixed", Year = 2001, IsCompilation = true }, track.GetOverrides());

            var playlists = database.Read(db => db.Playlists()).ToDictionary(playlist => playlist.Name);
            Assert.Equal(new PlaylistCover(new PlaylistCoverKind.Generated("p", "q"), ShowsTitle: true), playlists["Gen"].CoverStyle);
            Assert.Equal(new PlaylistCover(new PlaylistCoverKind.Image("abc")), playlists["Img"].CoverStyle);
            Assert.Equal(new PlaylistCover(new PlaylistCoverKind.SongCovers()), playlists["Songs"].CoverStyle);

            var rules = playlists["Smart"].Rules!;
            Assert.Equal(SmartMatch.Any, rules.Match);
            var rule = Assert.Single(rules.Rules);
            Assert.Equal("E621E1F8-C36C-495A-93FC-0C247A3E6E5F", rule.Id);
            Assert.Equal((SmartField.Quality, SmartOperator.IsAtLeast, QualityTier.HiResLossless), (rule.Field, rule.Op, rule.Quality));
            Assert.Equal(DateTime.UnixEpoch.AddSeconds(1_750_000_000), rule.Date);
            Assert.Equal(new SmartLimit { Count = 2, Unit = SmartLimitUnit.Hours, SelectedBy = SmartLimitSelection.HighestRated, Seed = 42 }, rules.Limit);
            // The smart playlist runs here: the song is Hi-Res.
            Assert.Equal(["Song"], database.Read(db => db.TracksOfPlaylist(playlists["Smart"].Id!.Value)).Select(t => t.Title));

            // Its full-text index works with ours.
            Assert.Equal(["Song"], database.Read(db => db.Search("son")).Songs.Select(t => t.Title));
        }
        SqliteConnection.ClearAllPools();
        File.Delete(path);
    }

    [Fact]
    public void ANewLibraryHasTheMacsSchema()
    {
        var path = CopyOfFixture();
        string mac;
        using (var database = LibraryDatabase.Open(path)) mac = database.Read(Schema);
        using var fresh = LibraryDatabase.InMemory();
        Assert.Equal(mac, fresh.Read(Schema));
        Assert.Equal(["v1", "v2-metadata", "v3-lovedAt", "v4-playlistCover", "v5-albumInfo", "v6-artistInfo", "v7-creditIndex",
                      "v8-cueTracks", "v9-watchState", "v10-lastfmQueue", "v11-loudness", "v12-deviceHistory"],
                     fresh.Read(db => db.Column<string>("SELECT identifier FROM grdb_migrations ORDER BY rowid")));
        SqliteConnection.ClearAllPools();
        File.Delete(path);
    }

    [Fact]
    public void JsonMatchesTheMacs()
    {
        // The Mac writes {"showsTitle":true,"kind":{"generated":{"palette":"p","pattern":"q"}}}: same keys and nesting.
        var json = System.Text.Encoding.UTF8.GetString(SwiftJson.Encode(new PlaylistCover(new PlaylistCoverKind.Generated("p", "q"), true)));
        Assert.Equal("""{"kind":{"generated":{"palette":"p","pattern":"q"}},"showsTitle":true}""", json);
        Assert.Equal("""{"title":"Fixed","year":2001,"isCompilation":true}""",
                     System.Text.Encoding.UTF8.GetString(SwiftJson.Encode(new TrackMetadata { Title = "Fixed", Year = 2001, IsCompilation = true })));
    }
}
