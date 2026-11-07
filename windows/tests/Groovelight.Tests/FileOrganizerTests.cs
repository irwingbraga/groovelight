using Groovelight.Core.Library;

namespace Groovelight.Tests;

public class FileNamingTests
{
    private readonly OrganizeOptions options = new();

    [Fact]
    public void RendersTheDefaultTemplate()
    {
        var fields = new NamingFields("Karma Police", "Radiohead", "OK Computer", "Radiohead", Year: 1997, TrackNumber: 6, DiscNumber: 1, DiscTotal: 1);
        Assert.Equal("Radiohead/OK Computer (1997)/06 Karma Police.flac", FileNaming.RelativePath(fields, "FLAC", options));
    }

    [Fact]
    public void OptionalPartsDisappearWithoutValues()
    {
        var fields = new NamingFields("Song", "Artist", "Album", TrackNumber: 3);
        Assert.Equal("Artist/Album/03 Song.mp3", FileNaming.RelativePath(fields, "mp3", options));
        // Multi-disc albums get the disc number; compilations go under Various Artists.
        Assert.Equal("Various Artists/Album/2-03 Song.mp3",
                     FileNaming.RelativePath(fields with { DiscNumber = 2, DiscTotal = 2, IsCompilation = true }, "mp3", options));
        // No track number: the file name is just the title.
        Assert.Equal("Unknown Artist/Unknown Album/Loose Song.m4a", FileNaming.RelativePath(new NamingFields("Loose Song"), "m4a", options));
    }

    [Fact]
    public void SanitizesNames()
    {
        var fields = new NamingFields("Song: Part 1/2 ft. Someone?", "AC/DC", "...Hidden.", "AC/DC", TrackNumber: 1);
        Assert.Equal("AC-DC/Hidden/01 Song - Part 1-2 feat. Someone_.flac", FileNaming.RelativePath(fields, "flac", options));
        // Without portable names the Mac keeps "?"; Windows never allows it.
        var loose = options with { PortableNames = false };
        Assert.EndsWith(OperatingSystem.IsWindows() ? "Someone_.flac" : "Someone?.flac", FileNaming.RelativePath(fields, "flac", loose));
        // Decomposed accents become composed.
        Assert.EndsWith("01 Café.mp3", FileNaming.RelativePath(new NamingFields("Café", TrackNumber: 1), "mp3", options));
    }

    [Fact]
    public void AvoidsWindowsDeviceNames()
    {
        // "01 NUL.mp3" is a legal name; "NUL.mp3" is the null device.
        Assert.Equal("CON_/Album/01 NUL.mp3", FileNaming.RelativePath(new NamingFields("NUL", "CON", "Album", TrackNumber: 1), "mp3", options));
        Assert.Equal("CON_/Album/NUL_.mp3", FileNaming.RelativePath(new NamingFields("NUL", "CON", "Album"), "mp3", options));
        Assert.Equal("Aux_/Unknown Album/Song.mp3", FileNaming.RelativePath(new NamingFields("Song", "Aux"), "mp3", options));
    }

    [Fact]
    public void TitleCasesWithExceptions()
    {
        Assert.Equal("The End of the World as We Know It", FileNaming.TitleCased("the end of the world as we know it"));
        Assert.Equal("Live in the USA", FileNaming.TitleCased("live in the USA"));
    }

    [Fact]
    public void LimitsLongNames()
    {
        var name = FileNaming.RelativePath(new NamingFields(new string('é', 300), TrackNumber: 1), "flac", options).Split('/')[^1];
        Assert.True(System.Text.Encoding.UTF8.GetByteCount(name) <= 255);
        Assert.EndsWith(".flac", name);
    }

    [Fact]
    public void KeepsFilesInPlaceWithoutFolderOrganizing() =>
        Assert.Equal("01 Song.mp3", FileNaming.RelativePath(new NamingFields("Song", "Artist", "Album", TrackNumber: 1), "mp3", options with { OrganizeFolders = false }));
}

public class OrganizerTests
{
    private static string Sep => Path.DirectorySeparatorChar.ToString();

    /// <summary>A library with real files in messy places, tagged in the library (as a fix would).</summary>
    private static async Task<(LibraryDatabase Database, List<string> Files)> Library(ScratchFolder scratch)
    {
        var files = AudioFixtures.CopyAll(scratch.Combine("Music", "Messy Downloads"));
        // A cover next to the songs.
        File.WriteAllBytes(Path.Combine(Path.GetDirectoryName(files[0])!, "cover.jpg"), AudioFixtures.PngData());
        var database = LibraryDatabase.InMemory();
        var root = database.AddRoot(scratch.Combine("Music"));
        await new LibraryScanner(database, new ArtworkCache(scratch.Combine("Artwork"))).ScanAsync(root, cancellation: TestContext.Current.CancellationToken);
        var tracks = database.Read(db => db.AllTracks());
        database.ApplyMetadata(tracks.Select((track, index) => (track.Id!.Value, new TrackMetadata
        {
            Title = $"Song {index + 1}", Artist = "Test Artist", Album = "Fixture Album", AlbumArtist = "Test Artist", Year = 2001, TrackNumber = index + 1,
        })).ToDictionary(pair => pair.Item1, pair => pair.Item2), asOverrides: true);
        return (database, files);
    }

    [Fact]
    public async Task RenamesThenUndoRestoresExactPaths()
    {
        using var scratch = new ScratchFolder();
        var (database, files) = await Library(scratch);
        using var _ = database;
        var root = scratch.Combine("Music");
        var before = database.Read(db => db.AllTracks());
        var originalPaths = before.ToDictionary(track => track.Id!.Value, track => track.Path);

        var plan = RenamePlanner.Plan(before, root, new OrganizeOptions());
        Assert.All(plan, item => Assert.Equal(RenameStatus.Move, item.Status));
        Assert.Contains(plan, item => item.Destination.EndsWith($"Test Artist{Sep}Fixture Album (2001){Sep}01 Song 1.m4a"));

        var journal = FileOrganizer.Apply(plan, database);
        foreach (var track in database.Read(db => db.AllTracks()))
        {
            Assert.True(File.Exists(track.Path), track.Path);
            Assert.Contains($"{Sep}Test Artist{Sep}Fixture Album (2001){Sep}", track.Path);
        }
        // The cover moved with the album and the old folder is gone.
        Assert.True(File.Exists(Path.Combine(root, "Test Artist", "Fixture Album (2001)", "cover.jpg")));
        Assert.False(Directory.Exists(Path.GetDirectoryName(files[0])));

        // A rescan sees nothing new.
        var summary = await new LibraryScanner(database, new ArtworkCache(scratch.Combine("Artwork")))
            .ScanAsync(database.Read(db => db.Roots())[0], cancellation: TestContext.Current.CancellationToken);
        Assert.Equal((0, 0), (summary.Added, summary.Removed));

        FileOrganizer.Undo(journal, database);
        foreach (var track in database.Read(db => db.AllTracks()))
        {
            Assert.Equal(originalPaths[track.Id!.Value], track.Path);
            Assert.True(File.Exists(track.Path));
        }
        Assert.True(File.Exists(Path.Combine(Path.GetDirectoryName(files[0])!, "cover.jpg")));
        Assert.False(Directory.Exists(Path.Combine(root, "Test Artist")));
    }

    [Fact]
    public async Task ResolvesConflictsAndSwaps()
    {
        using var scratch = new ScratchFolder();
        var (database, _) = await Library(scratch);
        using var _db = database;
        var root = scratch.Combine("Music");
        // The two .m4a songs (ALAC and AAC) get the same title and number: the second becomes " (2)".
        var m4a = database.Read(db => db.AllTracks()).Where(track => track.Path.EndsWith(".m4a")).ToList();
        Assert.Equal(2, m4a.Count);
        long a = m4a[0].Id!.Value, b = m4a[1].Id!.Value;
        database.ApplyMetadata(new Dictionary<long, TrackMetadata> { [a] = new() { Title = "Same", TrackNumber = 1 }, [b] = new() { Title = "Same", TrackNumber = 1 } }, true);
        var plan = RenamePlanner.Plan(database.Read(db => db.AllTracks()), root, new OrganizeOptions());
        var names = plan.Select(item => Path.GetFileName(item.Destination)).ToList();
        Assert.Contains("01 Same.m4a", names);
        Assert.Contains("01 Same (2).m4a", names);
        Assert.Contains(plan, item => item.Status == RenameStatus.RenamedForConflict);
        FileOrganizer.Apply(plan, database);

        // Swap them: "A" takes "B"'s name and the reverse, without clobbering either file.
        database.ApplyMetadata(new Dictionary<long, TrackMetadata> { [a] = new() { Title = "B", TrackNumber = 2 }, [b] = new() { Title = "A", TrackNumber = 1 } }, true);
        FileOrganizer.Apply(RenamePlanner.Plan(database.Read(db => db.AllTracks()), root, new OrganizeOptions()), database);
        database.ApplyMetadata(new Dictionary<long, TrackMetadata> { [a] = new() { Title = "A", TrackNumber = 1 }, [b] = new() { Title = "B", TrackNumber = 2 } }, true);
        var swap = RenamePlanner.Plan(database.Read(db => db.AllTracks()), root, new OrganizeOptions());
        Assert.Equal(2, swap.Count(item => item.Status != RenameStatus.Unchanged));
        FileOrganizer.Apply(swap, database);
        var final = database.Read(db => db.AllTracks());
        Assert.Equal(final.Count, final.Select(track => track.Path).Distinct().Count());
        Assert.All(final, track => Assert.True(File.Exists(track.Path), track.Path));
        Assert.EndsWith($"{Sep}01 A.m4a", final.Single(track => track.Id == a).Path);
    }

    [Fact]
    public async Task UndoingAnImportTakesSongsOut()
    {
        using var scratch = new ScratchFolder();
        var (database, _) = await Library(scratch);
        using var _db = database;
        // An "import": one file copied in, one moved in, then the library is scanned.
        var outside = scratch.Combine("Downloads");
        Directory.CreateDirectory(outside);
        var tracks = database.Read(db => db.AllTracks());
        var copySource = Path.Combine(outside, "copied.flac");
        var moveSource = Path.Combine(outside, "moved.wav");
        File.Copy(tracks.First(track => track.Path.EndsWith("Tone.flac")).Path, copySource);
        File.Copy(tracks.First(track => track.Path.EndsWith(".wav")).Path, moveSource);
        var copied = scratch.Combine("Music", "Imported", "copied.flac");
        var moved = scratch.Combine("Music", "Imported", "moved.wav");
        Directory.CreateDirectory(Path.GetDirectoryName(copied)!);
        File.Copy(copySource, copied);
        File.Move(moveSource, moved);
        await new LibraryScanner(database, new ArtworkCache(scratch.Combine("Artwork"))).ScanAsync(database.Read(db => db.Roots())[0], cancellation: TestContext.Current.CancellationToken);
        var ids = new[] { copied, moved }.Select(path => database.Read(db => db.Scalar<long>("SELECT id FROM track WHERE path = ?", path))).ToList();
        var journal = new FileOperationJournal
        {
            Kind = FileOperationJournal.JournalKind.Import,
            Entries = [new(ids[0], copySource, copied, true), new(ids[1], moveSource, moved, false)],
            CreatedFolders = [Path.GetDirectoryName(copied)!],
        };

        FileOrganizer.Undo(journal, database);
        Assert.True(File.Exists(copySource) && File.Exists(moveSource));
        Assert.False(Directory.Exists(Path.GetDirectoryName(copied)));
        Assert.Equal(0, database.Read(db => db.Scalar<int>("SELECT COUNT(*) FROM track WHERE id IN (?, ?)", ids[0], ids[1])));
    }

    [Fact]
    public void JournalsRoundTripOnDisk()
    {
        using var scratch = new ScratchFolder();
        var journal = new FileOperationJournal { Kind = FileOperationJournal.JournalKind.Import, Entries = [new(1, "/a", "/b", true)], CreatedFolders = ["/x"] };
        FileOrganizer.Save(journal, scratch.Path);
        var latest = FileOrganizer.LatestJournal(scratch.Path);
        Assert.NotNull(latest);
        Assert.Equal(journal.Entries, latest.Value.Journal.Entries);
        Assert.Equal(journal.Id, latest.Value.Journal.Id);
    }

    [Fact]
    public async Task OrganizeMovesACueAlbumAsAUnit()
    {
        using var scratch = new ScratchFolder();
        var album = scratch.Combine("Library", "Cue Band");
        Directory.CreateDirectory(album);
        var image = Path.Combine(album, "Single File Album.flac");
        File.Copy(Path.Combine(AudioFixtures.Directory, "tone.flac"), image);
        var cue = Path.Combine(album, "Single File Album.cue");
        File.WriteAllText(cue, """
            REM DATE 1997
            PERFORMER "Cue Band"
            TITLE "Single File Album"
            FILE "Single File Album.wav" WAVE
              TRACK 01 AUDIO
                TITLE "First"
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                TITLE "Second"
                INDEX 01 00:00:30
            """);
        using var database = LibraryDatabase.InMemory();
        var root = database.AddRoot(scratch.Combine("Library"));
        var scanner = new LibraryScanner(database, new ArtworkCache(scratch.Combine("Artwork")));
        await scanner.ScanAsync(root, cancellation: TestContext.Current.CancellationToken);
        database.Write(db => db.Execute("UPDATE track SET playCount = 2"));
        var before = database.Read(db => db.FetchTracks("SELECT * FROM track ORDER BY path"));

        var plan = RenamePlanner.Plan(before, root.Path, new OrganizeOptions());
        var folder = Path.Combine(root.Path, "Cue Band", "Single File Album (1997)");
        Assert.Equal(2, plan.Count);
        Assert.All(plan, item => Assert.True(item.Status == RenameStatus.Move && item.TrackId is null));
        Assert.Equal(new HashSet<string> { Path.Combine(folder, "Single File Album.flac"), Path.Combine(folder, "Single File Album.cue") },
                     plan.Select(item => item.Destination).ToHashSet());

        var journal = FileOrganizer.Apply(plan, database);
        var tracks = database.Read(db => db.FetchTracks("SELECT * FROM track ORDER BY path"));
        Assert.Equal(before.Select(track => track.Id), tracks.Select(track => track.Id));
        Assert.All(tracks, track => Assert.Equal(Path.Combine(folder, "Single File Album.flac"), track.AudioPath));
        Assert.Equal([Path.Combine(folder, "Single File Album.cue") + "#01", Path.Combine(folder, "Single File Album.cue") + "#02"], tracks.Select(track => track.Path));

        // The library already matches the disk: a rescan changes nothing, and history is kept.
        var rescan = await scanner.ScanAsync(root, cancellation: TestContext.Current.CancellationToken);
        Assert.Equal((2, 0, 0), (rescan.Unchanged, rescan.Added, rescan.Removed));

        FileOrganizer.Undo(journal, database);
        Assert.True(File.Exists(image) && File.Exists(cue));
        tracks = database.Read(db => db.FetchTracks("SELECT * FROM track ORDER BY path"));
        Assert.Equal([cue + "#01", cue + "#02"], tracks.Select(track => track.Path));
        Assert.All(tracks, track => Assert.Equal(2, track.PlayCount));
    }

    [Fact]
    public void TagWriterRoundTrips()
    {
        using var scratch = new ScratchFolder();
        foreach (var name in new[] { "tone.flac", "tone.mp3", "tone-aac.m4a", "tone.ogg", "tone.wv" })
        {
            var path = scratch.Combine(name);
            File.Copy(Path.Combine(AudioFixtures.Directory, name), path);
            var cover = AudioFixtures.PngData();
            TagWriter.Write(new TrackMetadata { Title = "Fixed", Artist = "Band", Year = 1999, TrackNumber = 4, IsCompilation = true }, path,
                            lyrics: "[00:01.00]Hello", frontCover: cover);
            var tags = TagReader.Read(path);
            Assert.True(tags is { Title: "Fixed", Artist: "Band", Year: 1999, TrackNumber: 4, IsCompilation: true, Lyrics: "[00:01.00]Hello" }, name);
            Assert.Equal(cover, tags.Artwork);
            // An empty value removes the tag; unset fields stay.
            TagWriter.Write(new TrackMetadata { Artist = "", IsCompilation = false }, path);
            var cleared = TagReader.Read(path);
            Assert.True(cleared is { Artist: null, IsCompilation: false, Title: "Fixed" }, name);
        }
    }
}
