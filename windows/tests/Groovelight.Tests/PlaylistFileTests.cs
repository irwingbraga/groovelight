using System.Text;
using Groovelight.Core;
using Groovelight.Core.Library;

namespace Groovelight.Tests;

public class PlaylistFileTests
{
    /// <summary>A Mac-style path as a full path on this system ("/music/a" is "C:\music\a" on Windows).</summary>
    private static string P(string posix) => OperatingSystem.IsWindows() ? Path.GetFullPath(posix.Replace('/', '\\')) : posix;

    private static readonly string Folder = P("/music/Playlists");

    private static PlaylistDocument One(string text, PlaylistFormat format) =>
        Assert.Single(PlaylistFile.Parse(Encoding.UTF8.GetBytes(text), format, "file", Folder));

    [Fact]
    public void ReadsExtendedM3u()
    {
        var document = One("""
            ﻿#EXTM3U
            #PLAYLIST:Road Trip
            #EXTINF:259,The Beatles - Come Together
            #EXTALB:Abbey Road
            ../The Beatles/Abbey Road/1 Come Together.flac
            #EXTINF:-1,Radio
            http://radio.example/stream
            file:///music/Radiohead/OK%20Computer/2%20Paranoid%20Android.flac
            C:\Music\song.mp3
            """, PlaylistFormat.M3u8);
        Assert.Equal("Road Trip", document.Name);
        Assert.Equal(4, document.Entries.Count);
        Assert.Equal(new PlaylistEntry(P("/music/The Beatles/Abbey Road/1 Come Together.flac"), "Come Together", "The Beatles", "Abbey Road", 259),
                     document.Entries[0]);
        Assert.Null(document.Entries[1].Path);
        Assert.Equal(P("/music/Radiohead/OK Computer/2 Paranoid Android.flac"), document.Entries[2].Path);
        // A drive path is a song on Windows, and nothing on the Mac.
        Assert.Equal(OperatingSystem.IsWindows() ? @"C:\Music\song.mp3" : null, document.Entries[3].Path);
    }

    [Fact]
    public void ReadsLatin1M3u()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        var data = Encoding.GetEncoding(1252).GetBytes("#EXTINF:100,Café Tacvba - Eres\n/music/café.mp3\n");
        var entry = PlaylistFile.Parse(data, PlaylistFormat.M3u, "Old", Folder)[0].Entries[0];
        Assert.Equal("Café Tacvba", entry.Artist);
        Assert.Equal(P("/music/café.mp3"), entry.Path);
    }

    [Fact]
    public void ReadsPls()
    {
        var entries = One("""
            [playlist]
            File2=/music/b.mp3
            Title2=Other - B
            File1=a.mp3
            Title1=A
            Length1=61
            NumberOfEntries=2
            Version=2
            """, PlaylistFormat.Pls).Entries;
        Assert.Equal([new PlaylistEntry(P("/music/Playlists/a.mp3"), "A", Duration: 61), new PlaylistEntry(P("/music/b.mp3"), "B", "Other")], entries);
    }

    [Fact]
    public void ReadsXspfAndWpl()
    {
        var mix = One("""
            <?xml version="1.0" encoding="UTF-8"?>
            <playlist version="1" xmlns="http://xspf.org/ns/0/">
              <title>Mix</title>
              <trackList>
                <track><location>file:///music/a%20b.flac</location><title>A B</title><creator>X</creator>
                  <album>Y</album><duration>90500</duration></track>
                <track><location>sub/c%20d.mp3</location><title>C</title></track>
              </trackList>
            </playlist>
            """, PlaylistFormat.Xspf);
        Assert.Equal("Mix", mix.Name);
        Assert.Equal([new PlaylistEntry(P("/music/a b.flac"), "A B", "X", "Y", 90.5), new PlaylistEntry(P("/music/Playlists/sub/c d.mp3"), "C")], mix.Entries);

        var list = One("""
            <?wpl version="1.0"?>
            <smil><head><title>Windows List</title></head>
            <body><seq><media src="..\Rock\song.wma"/><media src="/music/x.mp3"/></seq></body></smil>
            """, PlaylistFormat.Wpl);
        Assert.Equal("Windows List", list.Name);
        Assert.Equal([P("/music/Rock/song.wma"), P("/music/x.mp3")], list.Entries.Select(entry => entry.Path));
    }

    [Fact]
    public void ReadsMusicXmlSkippingBuiltInPlaylists()
    {
        var data = PropertyList.Write(new Dictionary<string, object?>
        {
            ["Tracks"] = new Dictionary<string, object?>
            {
                ["7"] = new Dictionary<string, object?> { ["Name"] = "Song", ["Artist"] = "Band", ["Album"] = "LP", ["Total Time"] = 200_000L, ["Location"] = "file:///music/Band/LP/Song.m4a" },
            },
            ["Playlists"] = new List<object?>
            {
                new Dictionary<string, object?> { ["Name"] = "Library", ["Master"] = true, ["Playlist Items"] = new List<object?> { new Dictionary<string, object?> { ["Track ID"] = 7L } } },
                new Dictionary<string, object?> { ["Name"] = "Music", ["Distinguished Kind"] = 4L, ["Playlist Items"] = new List<object?> { new Dictionary<string, object?> { ["Track ID"] = 7L } } },
                new Dictionary<string, object?> { ["Name"] = "Favorites", ["Playlist Items"] = new List<object?> { new Dictionary<string, object?> { ["Track ID"] = 7L }, new Dictionary<string, object?> { ["Track ID"] = 99L } } },
            },
        });
        var documents = PlaylistFile.Parse(data, PlaylistFormat.MusicXml, "file", Folder);
        Assert.Equal([new PlaylistDocument("Favorites", [new PlaylistEntry(P("/music/Band/LP/Song.m4a"), "Song", "Band", "LP", 200)])], documents);
    }

    private static Track At(Track track, string posix) { track.Path = P(posix); return track; }

    [Fact]
    public void WrittenPlaylistsReadBackInEveryFormat()
    {
        var tracks = new[]
        {
            At(TestLibrary.MakeTrack(1, "Come Together", "The Beatles", "Abbey Road", 1), "/music/The Beatles/Abbey Road/1 Come Together.flac"),
            At(TestLibrary.MakeTrack(1, "Ação & Reação", "Ç <Band>", "Álbum", 2), "/music/Ç <Band>/Álbum/2 Ação & Reação.flac"),
        };
        foreach (var format in PlaylistFormats.Exportable)
        {
            foreach (PlaylistPathStyle style in new PlaylistPathStyle[] { new PlaylistPathStyle.Absolute(), new PlaylistPathStyle.Relative(Folder) })
            {
                var data = PlaylistFile.Write("Trip & Back", tracks, format, style);
                var document = Assert.Single(PlaylistFile.Parse(data, format, "file", Folder));
                Assert.True(tracks.Select(track => track.Path).SequenceEqual(document.Entries.Select(entry => entry.Path)), $"{format} {style}");
                Assert.Equal(tracks.Select(track => track.Title), document.Entries.Select(entry => entry.Title));
                if (format != PlaylistFormat.Pls) Assert.Equal("Trip & Back", document.Name);
            }
        }
        // Plain M3U falls back to UTF-8 only when Latin-1 cannot hold the text.
        var japanese = TestLibrary.MakeTrack(1, "夜に駆ける", "YOASOBI", "THE BOOK", 1);
        Assert.Contains("夜に駆ける", Encoding.UTF8.GetString(PlaylistFile.Write("J", [japanese], PlaylistFormat.M3u)));
    }

    [Fact]
    public void RelativePaths()
    {
        var separator = Path.DirectorySeparatorChar;
        Assert.Equal($"..{separator}A{separator}b.mp3", PlaylistFile.RelativePath(P("/music/A/b.mp3"), P("/music/Playlists")));
        Assert.Equal("b.mp3", PlaylistFile.RelativePath(P("/music/Playlists/b.mp3"), P("/music/Playlists")));
        // On another drive (or volume) the path stays absolute.
        var other = OperatingSystem.IsWindows() ? @"D:\X\b.mp3" : "/Volumes/X/b.mp3";
        Assert.Equal(other, PlaylistFile.RelativePath(other, P("/music")));
    }

    [Fact]
    public void MatchesEntriesByPathThenTags()
    {
        using var database = TestLibrary.Seeded();
        database.Write(db =>
        {
            db.Execute("UPDATE track SET path = REPLACE(path, '/', ?)", OperatingSystem.IsWindows() ? "\\" : "/");
            if (OperatingSystem.IsWindows()) db.Execute("UPDATE track SET path = ? || path", Path.GetPathRoot(Path.GetFullPath("/"))!.TrimEnd('\\'));
            // A CUE album: two songs in one file.
            foreach (var (number, title) in new[] { (1, "Intro"), (2, "Main Theme") })
            {
                var track = TestLibrary.MakeTrack(1, title, "Composer", "Score", number);
                track.Path = P($"/music/Score/score.cue#{number}");
                track.AudioPath = P("/music/Score/score.flac");
                track.StartTime = (number - 1) * 100;
                db.Insert(track);
            }
        });
        PlaylistEntry[] entries =
        [
            new(P("/music/The Beatles/Abbey Road/2 Something.flac")),
            new(P("/elsewhere/Paranoid Android.mp3"), "paranoid android", "RADIOHEAD"),
            new(P("/music/Score/score.flac"), "Main Theme"),
            new(Title: "Come Together", Artist: "Someone Else"),
            new(P("/nope/nope.mp3")),
        ];
        var ids = database.Read(db => db.MatchPlaylistEntries(entries));
        var titles = ids.Select(id => id is { } value ? database.Read(db => db.FetchTrack(value))?.Title : null);
        Assert.Equal(["Something", "Paranoid Android", "Main Theme", null, null], titles);
    }
}
