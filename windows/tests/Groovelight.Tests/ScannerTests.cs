using Groovelight.Core.Library;

namespace Groovelight.Tests;

public class ScannerTests
{
    private static (LibraryDatabase Database, LibraryScanner Scanner, LibraryRoot Root, ArtworkCache Artwork) Library(string rootPath, string artworkPath)
    {
        var database = LibraryDatabase.InMemory();
        var artwork = new ArtworkCache(artworkPath);
        var root = database.AddRoot(rootPath);
        return (database, new LibraryScanner(database, artwork), root, artwork);
    }

    [Fact]
    public async Task ScansTaggedFilesInEveryFormat()
    {
        using var scratch = new ScratchFolder();
        var files = AudioFixtures.CopyAll(scratch.Path);
        Assert.True(files.Count >= 12);

        // Tag every file except the WAV (left untagged to test the file name fallback), and the formats TagLib# cannot
        // write (TTA, MP2 with no tag support beyond ID3v1 is fine).
        for (var index = 0; index < files.Count; index++)
        {
            var path = files[index];
            if (path.EndsWith(".wav") || path.EndsWith(".tta")) continue;
            AudioFixtures.Tag(path, tag =>
            {
                tag.Title = $"Song {index + 1}";
                tag.Performers = ["Test Artist"];
                tag.Album = "Fixture Album";
                tag.Year = 2001;
                tag.Track = (uint)(index + 1);
                tag.Genres = ["Electronic"];
                if (index == 2) tag.Pictures = [new TagLib.Picture(new TagLib.ByteVector(AudioFixtures.PngData())) { Type = TagLib.PictureType.FrontCover }];
            });
        }

        var (database, scanner, root, artwork) = Library(scratch.Combine("Test Artist"), scratch.Combine("Artwork"));
        using var _ = database;
        var first = await scanner.ScanAsync(root, cancellation: TestContext.Current.CancellationToken);
        Assert.Empty(first.Failed);
        Assert.Equal(files.Count, first.Added);

        var tracks = database.Read(db => db.FetchTracks("SELECT * FROM track ORDER BY path"));
        Assert.Equal(files.Count, tracks.Count);
        foreach (var track in tracks.Where(track => !track.Path.EndsWith(".tta")))
        {
            Assert.True(track.Duration is > 0.9 and < 1.2, $"{track.Path} duration {track.Duration}");
        }
        var wav = tracks.Single(track => track.Path.EndsWith(".wav"));
        Assert.Equal("11 Tone", wav.Title);
        Assert.Equal("WAVE", wav.Format);
        foreach (var track in tracks.Where(track => !track.Path.EndsWith(".wav") && !track.Path.EndsWith(".tta")))
        {
            Assert.True(track is { Artist: "Test Artist", Year: 2001, Album: "Fixture Album" },
                        $"{Path.GetFileName(track.Path)}: {track.Artist} {track.Year} {track.Album}");
        }

        // The Mac's format names, so badges and smart playlists agree.
        string FormatOf(string suffix) => tracks.Single(track => track.Path.EndsWith(suffix)).Format!;
        Assert.Equal("FLAC", FormatOf("Tone.flac"));
        Assert.Equal("Apple Lossless", FormatOf("alac.m4a"));
        Assert.Equal("AAC", FormatOf("aac.m4a"));
        Assert.Equal("MP3", FormatOf(".mp3"));
        Assert.Equal("MPEG-1 Layer II", FormatOf(".mp2"));
        Assert.Equal("Ogg Vorbis", FormatOf(".ogg"));
        Assert.Equal("Ogg Opus", FormatOf(".opus"));
        Assert.Equal("AIFF", FormatOf(".aiff"));
        Assert.Equal("WavPack", FormatOf(".wv"));
        Assert.Equal("True Audio", FormatOf(".tta"));
        var hiRes = tracks.Single(track => track.Path.EndsWith("hires.flac"));
        Assert.Equal((96_000.0, 24), (hiRes.SampleRate, hiRes.BitDepth));
        Assert.Equal(QualityTier.HiResLossless, hiRes.AudioSpec.Tier);
        Assert.Equal(QualityTier.HighQuality, tracks.Single(track => track.Path.EndsWith(".mp3")).AudioSpec.Tier);

        var covered = tracks.Where(track => track.ArtworkHash is not null).ToList();
        Assert.Single(covered);
        Assert.True(File.Exists(artwork.PathFor(covered[0].ArtworkHash!, ArtworkCache.Size.Small)));

        // Second scan: nothing changed.
        var second = await scanner.ScanAsync(root, cancellation: TestContext.Current.CancellationToken);
        Assert.Equal((files.Count, 0, 0), (second.Unchanged, second.Added, second.Updated));

        // Delete one file: it disappears from the library.
        File.Delete(files[0]);
        Assert.Equal(1, (await scanner.ScanAsync(root, cancellation: TestContext.Current.CancellationToken)).Removed);
    }

    [Fact]
    public async Task KeepsHistoryWhenAFolderIsMoved()
    {
        using var scratch = new ScratchFolder();
        var files = AudioFixtures.CopyAll(scratch.Combine("Library"));
        var (database, scanner, root, _) = Library(scratch.Combine("Library"), scratch.Combine("Artwork"));
        using var _db = database;
        await scanner.ScanAsync(root, cancellation: TestContext.Current.CancellationToken);
        database.Write(db => db.Execute("UPDATE track SET playCount = 3, isLoved = 1"));
        var ids = database.Read(db => db.Column<long>("SELECT id FROM track ORDER BY id"));

        Directory.Move(scratch.Combine("Library", "Test Artist", "Fixture Album"), scratch.Combine("Library", "Test Artist", "Renamed Album"));
        var summary = await scanner.ScanAsync(root, cancellation: TestContext.Current.CancellationToken);
        Assert.Equal((0, 0, files.Count), (summary.Added, summary.Removed, summary.Updated));
        var tracks = database.Read(db => db.FetchTracks("SELECT * FROM track ORDER BY id"));
        Assert.Equal(ids, tracks.Select(track => track.Id!.Value));
        Assert.All(tracks, track => Assert.True(track.PlayCount == 3 && track.IsLoved && track.Path.Contains("Renamed Album")));
    }

    [Fact]
    public async Task AMissingFolderRemovesNothing()
    {
        using var scratch = new ScratchFolder();
        AudioFixtures.CopyAll(scratch.Combine("Library"));
        var (database, scanner, root, _) = Library(scratch.Combine("Library"), scratch.Combine("Artwork"));
        using var _db = database;
        await scanner.ScanAsync(root, cancellation: TestContext.Current.CancellationToken);
        var count = database.Read(db => db.Scalar<int>("SELECT COUNT(*) FROM track"));

        // An unplugged drive: the folder is gone, its songs stay.
        Directory.Move(scratch.Combine("Library"), scratch.Combine("Elsewhere"));
        await Assert.ThrowsAsync<FolderUnavailableException>(() => scanner.ScanAsync(root, cancellation: TestContext.Current.CancellationToken));
        Assert.Equal(count, database.Read(db => db.Scalar<int>("SELECT COUNT(*) FROM track")));
    }

    private const string Sheet = """
        REM GENRE "Alternative Rock"
        REM DATE 1997
        PERFORMER "Cue Band"
        TITLE "Single File Album"
        FILE "Single File Album.wav" WAVE
          TRACK 01 AUDIO
            TITLE "First"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Second"
            PERFORMER "Guest Singer"
            INDEX 00 00:00:20
            INDEX 01 00:00:30
          TRACK 03 AUDIO
            TITLE "Third"
            INDEX 01 00:00:60
        """;

    /// <summary>A 1 s FLAC in its own album folder.</summary>
    private static string MakeImage(ScratchFolder scratch)
    {
        var album = scratch.Combine("Library", "Cue Band");
        Directory.CreateDirectory(album);
        var image = Path.Combine(album, "Single File Album.flac");
        File.Copy(Path.Combine(AudioFixtures.Directory, "tone.flac"), image);
        return image;
    }

    private static void CheckTracks(List<Track> tracks, string image, string cueBase)
    {
        Assert.Equal(["First", "Second", "Third"], tracks.Select(track => track.Title));
        Assert.Equal(new[] { "01", "02", "03" }.Select(number => cueBase + "#" + number), tracks.Select(track => track.Path));
        Assert.All(tracks, track => Assert.True(track.AudioPath == image && track.FilePath == image && track.IsCueTrack));
        Assert.Equal([0, 0.4, 0.8], tracks.Select(track => Math.Round(track.StartTime!.Value, 6)));
        Assert.Equal(0.4, tracks[0].EndTime!.Value, 6);
        Assert.Equal(0.8, tracks[1].EndTime!.Value, 6);
        Assert.Null(tracks[2].EndTime);
        Assert.True(Math.Abs(tracks[1].Duration - 0.4) < 0.01 && Math.Abs(tracks[2].Duration - 0.2) < 0.05);
        Assert.All(tracks, track => Assert.True(track is { Album: "Single File Album", AlbumArtist: "Cue Band", Year: 1997 }));
        Assert.Equal(("Cue Band", "Guest Singer"), (tracks[0].Artist, tracks[1].Artist));
        Assert.Single(tracks.Select(track => track.AlbumKey).Distinct());
    }

    [Fact]
    public async Task ExternalSheetSplitsTheImage()
    {
        using var scratch = new ScratchFolder();
        var image = MakeImage(scratch);
        // The sheet names the ".wav" the rip started as: resolved to the FLAC beside it.
        var cue = Path.Combine(Path.GetDirectoryName(image)!, "Single File Album.cue");
        File.WriteAllText(cue, Sheet);

        var (database, scanner, root, _) = Library(scratch.Combine("Library"), scratch.Combine("Artwork"));
        using var _db = database;
        var first = await scanner.ScanAsync(root, cancellation: TestContext.Current.CancellationToken);
        Assert.Equal(3, first.Added);
        Assert.Empty(first.Failed);
        CheckTracks(database.Read(db => db.FetchTracks("SELECT * FROM track ORDER BY path")), image, cue);

        // History survives a rescan after the sheet changes.
        database.Write(db => db.Execute("UPDATE track SET playCount = 5 WHERE path LIKE '%#02'"));
        var second = await scanner.ScanAsync(root, cancellation: TestContext.Current.CancellationToken);
        Assert.Equal((3, 0), (second.Unchanged, second.Added));
        File.WriteAllText(cue, Sheet.Replace("\"Second\"", "\"Second (Edit)\""));
        File.SetLastWriteTimeUtc(cue, DateTime.UtcNow.AddSeconds(10));
        var third = await scanner.ScanAsync(root, cancellation: TestContext.Current.CancellationToken);
        Assert.Equal((3, 0, 0), (third.Updated, third.Added, third.Removed));
        var tracks = database.Read(db => db.FetchTracks("SELECT * FROM track ORDER BY path"));
        Assert.Equal(("Second (Edit)", 5), (tracks[1].Title, tracks[1].PlayCount));

        // Without the sheet the file is one song again.
        File.Delete(cue);
        var fourth = await scanner.ScanAsync(root, cancellation: TestContext.Current.CancellationToken);
        Assert.Equal((1, 3), (fourth.Added, fourth.Removed));
        var single = Assert.Single(database.Read(db => db.AllTracks()));
        Assert.Equal(image, single.Path);
        Assert.False(single.IsCueTrack);
    }

    [Fact]
    public async Task EmbeddedSheetSplitsTheFile()
    {
        using var scratch = new ScratchFolder();
        var image = MakeImage(scratch);
        AudioFixtures.Tag(image, _ => { }, file =>
        {
            var xiph = (TagLib.Ogg.XiphComment)file.GetTag(TagLib.TagTypes.Xiph, create: true);
            xiph.SetField("CUESHEET", Sheet);
        });

        var (database, scanner, root, _) = Library(scratch.Combine("Library"), scratch.Combine("Artwork"));
        using var _db = database;
        var first = await scanner.ScanAsync(root, cancellation: TestContext.Current.CancellationToken);
        Assert.Equal(3, first.Added);
        Assert.Empty(first.Failed);
        CheckTracks(database.Read(db => db.FetchTracks("SELECT * FROM track ORDER BY path")), image, image);

        var second = await scanner.ScanAsync(root, cancellation: TestContext.Current.CancellationToken);
        Assert.Equal((3, 0, 0), (second.Unchanged, second.Added, second.Removed));
    }

    [Fact]
    public void ArtworkCacheMakesThumbnails()
    {
        using var scratch = new ScratchFolder();
        var cache = new ArtworkCache(scratch.Combine("Artwork"));
        var hash = cache.Store(AudioFixtures.PngData());
        Assert.NotNull(hash);
        Assert.Equal(32, hash.Length);
        Assert.True(cache.Has(hash));
        Assert.True(File.Exists(cache.PathFor(hash, null)) && File.Exists(cache.PathFor(hash, ArtworkCache.Size.Large)));
        Assert.Null(cache.Store([1, 2, 3]));
        cache.Prune(new HashSet<string>());
        Assert.False(cache.Has(hash));
    }

    [Fact]
    public void ParsesYears()
    {
        Assert.Equal(1999, TagReader.ParseYear("1999-03-02"));
        Assert.Equal(2004, TagReader.ParseYear("03/02/2004"));
        Assert.Null(TagReader.ParseYear("unknown"));
    }
}
