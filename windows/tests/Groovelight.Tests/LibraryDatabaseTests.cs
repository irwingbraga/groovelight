using Groovelight.Core.Library;

namespace Groovelight.Tests;

public class LibraryDatabaseTests
{
    [Fact]
    public void GroupsAlbumsAndArtists()
    {
        using var database = TestLibrary.Seeded();
        var albums = database.Read(db => db.Albums(AlbumSort.Title));
        Assert.Equal(["Abbey Road", "Hits 1999", "OK Computer", "Revolver"], albums.Select(album => album.Title));
        Assert.Equal("Various Artists", albums.First(album => album.Title == "Hits 1999").Artist);
        Assert.Equal(2, albums.First(album => album.Title == "Abbey Road").TrackCount);

        var artists = database.Read(db => db.Artists());
        Assert.Equal(["Radiohead", "The Beatles"], artists.Select(artist => artist.Name));
        Assert.Equal(2, artists[^1].AlbumCount);

        Assert.Equal(2, database.Read(db => db.Albums(artist: "the beatles")).Count);
    }

    [Fact]
    public void ListsCompilationsAsOneEntry()
    {
        using var database = TestLibrary.Seeded();
        var compilations = database.Read(db => db.Compilations());
        Assert.NotNull(compilations);
        Assert.True(compilations.IsCompilations);
        Assert.Equal("Compilations", compilations.DisplayName);
        Assert.Equal((1, 2), (compilations.AlbumCount, compilations.TrackCount));
        Assert.Equal(["Hits 1999"], database.Read(db => db.Albums(artist: ArtistSummary.Compilations)).Select(album => album.Title));

        // No compilation albums, no entry.
        database.Write(db => db.Execute("DELETE FROM track WHERE isCompilation = 1"));
        Assert.Null(database.Read(db => db.Compilations()));
    }

    [Fact]
    public void AlbumTracksAreOrdered()
    {
        using var database = TestLibrary.Seeded();
        var key = Track.MakeAlbumKey("Abbey Road", null, "The Beatles", false);
        Assert.Equal(["Come Together", "Something"], database.Read(db => db.TracksOfAlbum(key)).Select(track => track.Title));
    }

    [Fact]
    public void FullTextSearchWithPrefixes()
    {
        using var database = TestLibrary.Seeded();
        Assert.Equal(["Yellow Submarine"], database.Read(db => db.Search("beat yell")).Songs.Select(track => track.Title));
        Assert.True(database.Read(db => db.Search("  ")).IsEmpty);
    }

    [Fact]
    public void SearchFindsEveryCategory()
    {
        using var database = TestLibrary.Seeded();
        var abbey = Track.MakeAlbumKey("Abbey Road", null, "The Beatles", false);
        var ok = Track.MakeAlbumKey("OK Computer", null, "Radiohead", false);
        database.SetCredits([
            new CreditIndexEntry(new CreditPerson("George Martin", "gm"), abbey, null, ["producer"], WholeRelease: true),
            new CreditIndexEntry(new CreditPerson("The Beatles", "tb"), abbey, null, ["performer"]),
        ], abbey);
        database.SetCredits([
            new CreditIndexEntry(new CreditPerson("Nigel Godrich", "ng"), ok, null, ["producer"]),
            new CreditIndexEntry(new CreditPerson("Nigel Godrich", "ng"), ok, 4, ["engineer"]),
        ], ok);

        var beatles = database.Read(db => db.Search("beatles"));
        Assert.Equal(["The Beatles"], beatles.Artists.Select(artist => artist.Name));
        Assert.Equal(new HashSet<string> { "Abbey Road", "Revolver" }, beatles.Albums.Select(album => album.Title).ToHashSet());
        Assert.Equal(3, beatles.Songs.Count);
        // A credited name that is also a library artist shows only as the artist.
        Assert.Empty(beatles.People);

        var abbeyRoad = database.Read(db => db.Search("abbey"));
        Assert.Equal(["Abbey Road"], abbeyRoad.Albums.Select(album => album.Title));
        Assert.Empty(abbeyRoad.Artists);

        var nigel = database.Read(db => db.Search("godr"));
        Assert.Equal(["Nigel Godrich"], nigel.People.Select(person => person.Person.Name));
        Assert.Equal(1, nigel.People[0].AlbumCount);
        Assert.Equal(["engineer", "producer"], nigel.People[0].Roles);

        // Accents and case are ignored, and an exact title ranks first.
        var radiohead = database.Read(db => db.Search("RÁDIOHEAD"));
        Assert.Equal(["Radiohead"], radiohead.Artists.Select(artist => artist.Name));
        Assert.Equal(["OK Computer"], radiohead.Albums.Select(album => album.Title));
    }

    [Fact]
    public void SearchMatcherScores()
    {
        var matcher = new SearchMatcher("ok comp");
        Assert.Equal(1, matcher.Score("OK Computer"));
        Assert.Equal(2, matcher.Score("Computer, OK?"));
        Assert.Null(matcher.Score("Okay"));
        Assert.Equal(0, new SearchMatcher("ac dc").Score("AC/DC"));
        Assert.Equal(0, new SearchMatcher("bjork").Score("Björk"));
    }

    [Fact]
    public void PlaylistCoversPersist()
    {
        using var database = TestLibrary.Seeded();
        var cover = new PlaylistCover(new PlaylistCoverKind.Generated("sunset", "vinyl"), ShowsTitle: true);
        var id = database.CreatePlaylist("Mix", cover: cover).Id!.Value;
        Assert.Equal(cover, database.Read(db => db.FetchPlaylist(id))?.CoverStyle);

        var image = new PlaylistCover(new PlaylistCoverKind.Image("abc"));
        database.UpdatePlaylist(id, "Renamed", image);
        var updated = database.Read(db => db.FetchPlaylist(id));
        Assert.Equal("Renamed", updated?.Name);
        Assert.Equal(image, updated?.CoverStyle);

        database.UpdatePlaylist(id, "Renamed", null);
        Assert.Null(database.Read(db => db.FetchPlaylist(id))?.CoverStyle);
    }

    [Fact]
    public void PlaylistsKeepOrder()
    {
        using var database = TestLibrary.Seeded();
        var ids = database.Read(db => db.Column<long>("SELECT id FROM track ORDER BY id DESC LIMIT 3"));
        var playlist = database.CreatePlaylist("Mix", ids);
        database.AddTracks([ids[0]], playlist.Id!.Value);
        Assert.Equal([.. ids, ids[0]], database.Read(db => db.TracksOfPlaylist(playlist.Id!.Value)).Select(track => track.Id!.Value));
    }

    [Fact]
    public void AlbumKeyIgnoresCaseAndLeadingThe() =>
        Assert.Equal(Track.MakeAlbumKey("Abbey Road", null, "The Beatles", false), Track.MakeAlbumKey("abbey road ", "Beatles", null, false));

    [Fact]
    public void MetadataFixesAndOverrides()
    {
        using var database = TestLibrary.Seeded();
        var id = database.Read(db => db.Scalar<long>("SELECT id FROM track WHERE title = 'Something'"));
        database.ApplyMetadata(new Dictionary<long, TrackMetadata> { [id] = new() { Album = "Abbey Road (Remaster)", Year = 0 } }, asOverrides: true);
        var track = database.Read(db => db.FetchTrack(id))!;
        Assert.Equal("Abbey Road (Remaster)", track.Album);
        Assert.Null(track.Year);
        Assert.Equal(Track.MakeAlbumKey("Abbey Road (Remaster)", null, "The Beatles", false), track.AlbumKey);
        Assert.Equal("Abbey Road (Remaster)", track.GetOverrides()?.Album);
    }
}
