using System.Text.Json;
using Groovelight.Core;
using Groovelight.Core.Library;

namespace Groovelight.Tests;

/// <summary>Watching library folders: events to scan work, scans of only some folders, and the watcher.</summary>
public class LibrarySyncTests
{
    private static string P(string posix) => OperatingSystem.IsWindows() ? Path.GetFullPath(posix.Replace('/', '\\')) : posix;

    private static LibraryChanges Changes() => new([(1, P("/Music")), (2, P("/Volumes/NAS/Music"))]);

    private static void AssertFolders(ScanScope scope, IEnumerable<string> folders, IEnumerable<string> artwork)
    {
        var scoped = Assert.IsType<ScanScope.Folders>(scope);
        Assert.Equal(folders.ToHashSet(), scoped.Paths.ToHashSet());
        Assert.Equal(artwork.ToHashSet(), (scoped.ArtworkFolders ?? new HashSet<string>()).ToHashSet());
    }

    [Fact]
    public void EventsBecomeFolderScopes()
    {
        var changes = Changes();
        changes.Add([
            new(P("/Music/A/Album/01.flac"), FolderEventKind.File),
            new(P("/Music/A/Album/02.flac"), FolderEventKind.File),
            new(P("/Music/A/Album/notes.txt"), FolderEventKind.File),
            new(P("/Music/A/Album/.DS_Store"), FolderEventKind.File),
            new(P("/Music/B/Other/cover.jpg"), FolderEventKind.File),
            new(P("/Music/B"), FolderEventKind.Directory),
            new(P("/Elsewhere/song.flac"), FolderEventKind.File),
        ]);
        var work = Assert.Single(changes.Take());
        // "/Music/B" covers "/Music/B/Other"; the cover image still marks its folder for new artwork.
        Assert.Equal(1, work.RootId);
        AssertFolders(work.Scope, [P("/Music/A/Album"), P("/Music/B")], [P("/Music/B/Other")]);
        Assert.True(changes.IsEmpty);
        Assert.Empty(changes.Take());
    }

    [Fact]
    public void LostEventsAndRootChangesNeedFullScans()
    {
        var changes = Changes();
        changes.Add([new(P("/Music/A/x.flac"), FolderEventKind.File), new(P("/Volumes/NAS/Music"), FolderEventKind.RootChanged)]);
        var work = changes.Take();
        Assert.Equal([1L, 2L], work.Select(item => item.RootId));
        Assert.IsType<ScanScope.Full>(work[^1].Scope);

        changes.Add([new(P("/Music"), FolderEventKind.Overflow), new(P("/Volumes/NAS/Music"), FolderEventKind.Overflow)]);
        Assert.All(changes.Take(), item => Assert.IsType<ScanScope.Full>(item.Scope));

        // A deleted entry of unknown kind checks its folder; a missing song's folder too.
        changes.Add([new(P("/Music/C/gone"), FolderEventKind.Unknown)]);
        changes.AddFolder(P("/Volumes/NAS/Music/X"));
        var mixed = changes.Take();
        AssertFolders(mixed[0].Scope, [P("/Music/C")], []);
        AssertFolders(mixed[1].Scope, [P("/Volumes/NAS/Music/X")], []);
    }

    [Fact]
    public async Task ScopedScansOnlyTouchTheirFolders()
    {
        using var scratch = new ScratchFolder();
        var files = AudioFixtures.CopyAll(scratch.Path);
        var albumOne = Path.GetDirectoryName(files[0])!;
        // A second album folder with copies of two files.
        var albumTwo = scratch.Combine("Other Artist", "Second Album");
        Directory.CreateDirectory(albumTwo);
        foreach (var file in files.Take(2)) File.Copy(file, Path.Combine(albumTwo, Path.GetFileName(file)));

        using var database = LibraryDatabase.InMemory();
        var root = database.AddRoot(scratch.Path);
        var scanner = new LibraryScanner(database, new ArtworkCache(scratch.Combine(".artwork")));
        var cancel = TestContext.Current.CancellationToken;
        Assert.Equal(files.Count + 2, (await scanner.ScanAsync(root, cancellation: cancel)).Added);
        Assert.NotNull(database.Read(db => db.Roots())[0].LastFullScanAt);

        // Remove a file from each album, but scan only the second album's folder: the first keeps its song.
        File.Delete(Path.Combine(albumOne, Path.GetFileName(files[2])));
        File.Delete(Path.Combine(albumTwo, Path.GetFileName(files[1])));
        var scoped = await scanner.ScanAsync(root, new ScanScope.Folders(new HashSet<string> { albumTwo }), cancellation: cancel);
        Assert.Equal((1, 1), (scoped.Removed, scoped.Unchanged));
        Assert.Equal(files.Count + 1, database.Read(db => db.Scalar<int>("SELECT COUNT(*) FROM track")));

        // A cover image beside the songs: they are read again and pick it up.
        List<Track> InAlbum(string folder) => database.Read(db => db.FetchTracks("SELECT * FROM track WHERE path LIKE ? ORDER BY id", folder + Path.DirectorySeparatorChar + "%"));
        var before = InAlbum(albumTwo);
        Assert.All(before, track => Assert.Null(track.ArtworkHash));
        File.WriteAllBytes(Path.Combine(albumTwo, "cover.png"), AudioFixtures.PngData());
        var cover = await scanner.ScanAsync(root, new ScanScope.Folders(new HashSet<string> { albumTwo }, new HashSet<string> { albumTwo }), cancellation: cancel);
        Assert.Equal(1, cover.Updated);
        var after = InAlbum(albumTwo);
        Assert.All(after, track => Assert.NotNull(track.ArtworkHash));
        Assert.Equal(before.Select(track => track.Id), after.Select(track => track.Id));

        // Renaming a folder: both its old and new paths are in the scope, and its songs keep their ids.
        var renamed = scratch.Combine("Other Artist", "Renamed Album");
        Directory.Move(albumTwo, renamed);
        var move = await scanner.ScanAsync(root, new ScanScope.Folders(new HashSet<string> { albumTwo, renamed }), cancellation: cancel);
        Assert.Equal(0, move.Removed);
        Assert.Equal(after.Select(track => track.Id), InAlbum(renamed).Select(track => track.Id));

        // A deleted folder: its songs go.
        Directory.Delete(renamed, recursive: true);
        Assert.Equal(1, (await scanner.ScanAsync(root, new ScanScope.Folders(new HashSet<string> { renamed }), cancellation: cancel)).Removed);
        Assert.Equal(files.Count, database.Read(db => db.Scalar<int>("SELECT COUNT(*) FROM track")));
    }

    [Fact]
    public async Task WatcherReportsChanges()
    {
        using var scratch = new ScratchFolder();
        Directory.CreateDirectory(scratch.Combine("Album"));
        var received = new List<FolderEvent>();
        var gate = new Lock();
        using var watcher = new FolderWatcher(events => { lock (gate) received.AddRange(events); });
        watcher.Watch([scratch.Path], TimeSpan.FromSeconds(0.2));
        await Task.Delay(500, TestContext.Current.CancellationToken);
        File.WriteAllBytes(scratch.Combine("Album", "live.flac"), [1]);

        var changes = new LibraryChanges([(1, scratch.Path)]);
        for (var attempt = 0; attempt < 100; attempt++)
        {
            lock (gate)
            {
                if (received.Any(change => change.Path.EndsWith("live.flac"))) break;
            }
            await Task.Delay(100, TestContext.Current.CancellationToken);
        }
        lock (gate)
        {
            Assert.Contains(received, change => change.Path.EndsWith("live.flac") && change.Kind == FolderEventKind.File);
            changes.Add(received);
        }
        // The real folder may be spelled through a link (/var for /private/var on the Mac): its album folder is in scope.
        var scope = Assert.IsType<ScanScope.Folders>(Assert.Single(changes.Take()).Scope);
        Assert.Contains(scope.Paths, path => path.EndsWith("Album"));
        Assert.True(FolderWatcher.IsLocalVolume(scratch.Path));
    }
}

public class BackupTests
{
    [Fact]
    public async Task BacksUpAndRestoresEverythingOutsideTheFiles()
    {
        using var scratch = new ScratchFolder();
        var files = AudioFixtures.CopyAll(scratch.Combine("Music"));
        var artworkDirectory = scratch.Combine("Artwork");
        var cancel = TestContext.Current.CancellationToken;
        LibraryBackup.Manifest manifest;
        long first;
        string coverHash, albumKey;
        var backup = scratch.Combine($"Test.{LibraryBackup.FileExtension}");
        using (var database = LibraryDatabase.Open(scratch.Combine("Library.sqlite")))
        {
            var artwork = new ArtworkCache(artworkDirectory);
            var root = database.AddRoot(scratch.Combine("Music"), [1, 2, 3]);
            await new LibraryScanner(database, artwork).ScanAsync(root, cancellation: cancel);

            // Library-only data: history, loves, a fix, fetched lyrics, a playlist with a custom cover, album info.
            var tracks = database.Read(db => db.AllTracks());
            first = tracks[0].Id!.Value;
            albumKey = tracks[0].AlbumKey;
            database.RecordPlay(first);
            database.SetLoved(true, first);
            database.ApplyMetadata(new Dictionary<long, TrackMetadata> { [first] = new() { Title = "Fixed" } }, true);
            database.SetFetchedLyrics("[00:01.00]Hi", first);
            coverHash = artwork.Store(AudioFixtures.PngData())!;
            database.CreatePlaylist("Mix", tracks.Select(track => track.Id!.Value).ToList(), new PlaylistCover(new PlaylistCoverKind.Image(coverHash), true));
            database.SetAlbumInfo("{}"u8.ToArray(), albumKey);

            var preferences = PropertyList.Write(new Dictionary<string, object?> { ["eq.enabled"] = true });
            manifest = LibraryBackup.Write(database, artworkDirectory, preferences, "1.0", backup);
        }
        Assert.Equal((files.Count, 1, 1, 1), (manifest.TrackCount, manifest.PlaylistCount, manifest.LovedCount, manifest.PlayCount));
        var read = LibraryBackup.ReadManifest(backup);
        Assert.Equal(manifest.Folders, read.Folders);
        Assert.True(Math.Abs((read.CreatedAt - manifest.CreatedAt).TotalSeconds) < 1);
        // The manifest's dates are whole seconds, which the Mac's decoder needs.
        Assert.Matches("\"createdAt\": \"\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d:\\d\\dZ\"", File.ReadAllText(Path.Combine(backup, "Manifest.json")));

        // A different, empty library on a "new computer" with the music in another folder.
        var newComputer = scratch.Combine("NewPC");
        CopyDirectory(scratch.Combine("Music"), Path.Combine(newComputer, "Música"));
        using var restored = LibraryDatabase.Open(Path.Combine(newComputer, "Library.sqlite"));
        var restoredArtwork = Path.Combine(newComputer, "Artwork");
        var restoredPreferences = LibraryBackup.Restore(backup, restored, restoredArtwork);
        Assert.Equal(true, (PropertyList.Parse(restoredPreferences!) as Dictionary<string, object?>)?["eq.enabled"]);
        Assert.True(File.Exists(Path.Combine(restoredArtwork, $"{coverHash}.img")));

        // Locate the folder: paths move, history stays, and a rescan keeps everything.
        var restoredRoot = restored.Read(db => db.Roots())[0];
        Assert.Equal(files.Count, restored.RelocateRoot(restoredRoot.Id!.Value, Path.Combine(newComputer, "Música")));
        var summary = await new LibraryScanner(restored, new ArtworkCache(restoredArtwork)).ScanAsync(restored.Read(db => db.Roots())[0], cancellation: cancel);
        Assert.Equal((0, 0), (summary.Removed, summary.Added));
        var after = restored.Read(db => db.FetchTrack(first))!;
        Assert.True(after is { Title: "Fixed", PlayCount: 1, IsLoved: true });
        Assert.Equal("[00:01.00]Hi", after.DisplayLyrics());
        Assert.Contains(Path.Combine("NewPC", "Música") + Path.DirectorySeparatorChar, after.Path);
        Assert.True(restored.Read(db => db.Playlists())[0].CoverStyle?.ShowsTitle);
        Assert.NotNull(restored.Read(db => db.AlbumInfo(albumKey)));
    }

    /// <summary>A backup made on the Mac ("/music" paths) restores here and relocates onto this computer's folder.</summary>
    [Fact]
    public void RestoresAMacBackup()
    {
        using var scratch = new ScratchFolder();
        var backup = scratch.Combine($"Mac.{LibraryBackup.FileExtension}");
        Directory.CreateDirectory(Path.Combine(backup, "Artwork"));
        File.Copy(Path.Combine(AppContext.BaseDirectory, "Fixtures", "MacLibrary.sqlite"), Path.Combine(backup, "Library.sqlite"));
        // The Mac's manifest, as its JSONEncoder writes it (sorted keys, ISO 8601 dates in whole seconds).
        File.WriteAllText(Path.Combine(backup, "Manifest.json"), """
            {
              "appVersion" : "0.8.1",
              "artworkCount" : 0,
              "computerName" : "Irwing's MacBook Pro",
              "createdAt" : "2026-10-30T21:18:26Z",
              "folders" : [
                "/music"
              ],
              "formatVersion" : 1,
              "lovedCount" : 1,
              "playCount" : 0,
              "playlistCount" : 4,
              "trackCount" : 1
            }
            """);
        Assert.Equal("Irwing's MacBook Pro", LibraryBackup.ReadManifest(backup).ComputerName);

        using var database = LibraryDatabase.InMemory();
        Assert.Null(LibraryBackup.Restore(backup, database, scratch.Combine("Artwork")));
        var root = database.Read(db => db.Roots()).Single();
        Assert.Equal("/music", root.Path);
        var folder = scratch.Combine("Música");
        Assert.Equal(1, database.RelocateRoot(root.Id!.Value, folder));
        var track = database.Read(db => db.AllTracks()).Single();
        Assert.Equal(Path.Combine(folder, "Artist", "Album", "1 Song.flac"), track.Path);
        Assert.True(track is { IsLoved: true, Title: "Song" });
    }

    [Fact]
    public void RejectsFoldersThatAreNotBackups() =>
        Assert.Throws<LibraryBackup.BackupException>(() => LibraryBackup.ReadManifest(Path.GetTempPath()));

    private static void CopyDirectory(string from, string to)
    {
        foreach (var file in Directory.EnumerateFiles(from, "*", SearchOption.AllDirectories))
        {
            var destination = Path.Combine(to, Path.GetRelativePath(from, file));
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            File.Copy(file, destination);
        }
    }
}
