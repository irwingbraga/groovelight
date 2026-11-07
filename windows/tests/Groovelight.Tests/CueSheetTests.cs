using System.Text;
using Groovelight.Core.Library;

namespace Groovelight.Tests;

public class CueSheetTests
{
    internal const string Sample = """
        ﻿REM GENRE "Alternative Rock"
        REM DATE 1997
        REM DISCID 970ABC0C
        PERFORMER "Radiohead"
        TITLE "OK Computer"
        FILE "Radiohead - OK Computer.wav" WAVE
          TRACK 01 AUDIO
            TITLE "Airbag"
            PERFORMER "Radiohead"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Paranoid Android"
            ISRC GBAYE9700198
            INDEX 00 04:42:30
            INDEX 01 04:44:30
          TRACK 03 AUDIO
            TITLE "Subterranean Homesick Alien"
            SONGWRITER "Thom Yorke"
            INDEX 01 11:08:00
        """;

    [Fact]
    public void ParsesASheet()
    {
        var sheet = CueSheet.Parse(Sample.Replace("\n", "\r\n"));
        Assert.NotNull(sheet);
        Assert.Equal(("OK Computer", "Radiohead", "Alternative Rock", (int?)1997), (sheet.Title, sheet.Performer, sheet.Genre, sheet.Year));
        Assert.Equal("Radiohead - OK Computer.wav", Assert.Single(sheet.Files).Name);
        var tracks = sheet.Tracks.ToList();
        Assert.Equal([1, 2, 3], tracks.Select(track => track.Number));
        Assert.Equal(("Paranoid Android", "GBAYE9700198"), (tracks[1].Title, tracks[1].Isrc));
        Assert.Equal(284.4, tracks[1].Start, 9);
        Assert.Equal(282.4, tracks[1].Pregap!.Value, 9);
        Assert.Equal((668.0, "Thom Yorke"), (tracks[2].Start, tracks[2].Songwriter));
        Assert.Equal("Radiohead", tracks[0].Performer);
        Assert.Null(tracks[2].Performer);
    }

    [Fact]
    public void ReadsOtherEncodings()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        const string text = "PERFORMER \"Sigur Rós\"\nTITLE \"Ágætis byrjun\"\nFILE \"a.flac\" WAVE\n TRACK 01 AUDIO\n  TITLE \"Svefn-g-englar\"\n  INDEX 01 00:00:00\n";
        Assert.Equal("Sigur Rós", CueSheet.Parse(CueSheet.Decode(Encoding.GetEncoding(1252).GetBytes(text)))?.Performer);
        Assert.Equal("Ágætis byrjun", CueSheet.Parse(CueSheet.Decode([.. Encoding.Unicode.GetPreamble(), .. Encoding.Unicode.GetBytes(text)]))?.Title);
    }

    [Fact]
    public void HandlesSeveralFilesAndDataTracks()
    {
        var sheet = CueSheet.Parse("""
            FILE "CD1.flac" WAVE
              TRACK 01 AUDIO
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                INDEX 01 03:00:00
            FILE "CD2.flac" WAVE
              TRACK 03 AUDIO
                INDEX 01 00:00:00
              TRACK 04 MODE1/2352
                INDEX 01 05:00:00
            """);
        Assert.NotNull(sheet);
        Assert.Equal(["CD1.flac", "CD2.flac"], sheet.Files.Select(file => file.Name));
        Assert.Equal([3], sheet.Files[1].Tracks.Select(track => track.Number));
        Assert.Null(CueSheet.Parse("REM nothing here"));
    }

    [Fact]
    public void ResolvesFileReferences()
    {
        var folder = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "Music", "Album"));
        var files = new HashSet<string> { Path.Combine(folder, "Radiohead - OK Computer.flac"), Path.Combine(folder, "Other.mp3") };
        // The sheet still says .wav after the rip was compressed to FLAC.
        Assert.Equal("Radiohead - OK Computer.flac", Path.GetFileName(CueSheet.Resolve("Radiohead - OK Computer.wav", folder, files)));
        Assert.Equal("Other.mp3", Path.GetFileName(CueSheet.Resolve("other.MP3", folder, files)));
        Assert.Null(CueSheet.Resolve("Missing.flac", folder, files));
    }
}
