using Groovelight.Core.Devices;
using Groovelight.Core.Library;

namespace Groovelight.Tests;

/// <summary>The Mac's DeviceSyncTests, ported.</summary>
public sealed class DeviceSyncTests : IDisposable
{
    private readonly string baseFolder = Path.Combine(Path.GetTempPath(), "gl-device-" + Guid.NewGuid().ToString("N"));
    private readonly string device;

    public DeviceSyncTests()
    {
        device = Path.Combine(baseFolder, "SDCARD");
        Directory.CreateDirectory(device);
    }

    public void Dispose() => Directory.Delete(baseFolder, true);

    private Track AddTrack(long id, string title, string artist, string album, int number, int bytes = 1000, string? lyrics = null)
    {
        var source = Path.Combine(baseFolder, "library", artist.Replace('/', '_'), album, $"{number} {title.Replace(':', '_').Replace('?', '_')}.flac");
        Directory.CreateDirectory(Path.GetDirectoryName(source)!);
        File.WriteAllBytes(source, Enumerable.Repeat((byte)number, bytes).ToArray());
        return TestLibrary.MakeTrack(1, title, artist, album, number) with
        {
            Id = id, Path = source, FileSize = bytes, ModifiedAt = DateTime.UnixEpoch.AddSeconds(1_700_000_000), Lyrics = lyrics,
        };
    }

    private bool Exists(string path) => File.Exists(Path.Combine(device, path.Replace('/', Path.DirectorySeparatorChar)));

    private DeviceSyncPlan Sync(IReadOnlyList<Track> tracks, IReadOnlyList<DevicePlaylist>? playlists = null, DeviceSyncMode mode = DeviceSyncMode.Sync,
                                DeviceProfile? profile = null, bool fat32 = false)
    {
        profile ??= new DeviceProfile();
        var manifest = DeviceManifest.Read(device);
        var plan = DeviceSync.Plan(tracks, playlists ?? [], profile, manifest, mode, device, fat32, existing: Exists);
        DeviceSync.Run(plan, device, profile, manifest, (_, _) => [1, 2, 3]);
        return plan;
    }

    [Fact]
    public void CopiesSongsLyricsAndPlaylistsThenOnlyWhatChanged()
    {
        var a = AddTrack(1, "Come Together", "The Beatles", "Abbey Road", 1, lyrics: "[00:10.00]Here come old flat-top");
        var b = AddTrack(2, "Something", "The Beatles", "Abbey Road", 2);
        var c = AddTrack(3, "What: Why?", "AC/DC", "Back in Black", 3);
        var first = Sync([a, b, c], [new DevicePlaylist("Road Trip", [c, a])]);
        Assert.Equal(3, first.SongCount);
        Assert.True(Exists("Music/The Beatles/Abbey Road (1969)/01 Come Together.flac"));
        Assert.True(Exists("Music/The Beatles/Abbey Road (1969)/01 Come Together.lrc"));
        Assert.False(Exists("Music/The Beatles/Abbey Road (1969)/02 Something.lrc"));
        // Names safe on FAT and exFAT cards: no ":" "?" "/" in a name.
        Assert.True(Exists("Music/AC-DC/Back in Black (1969)/03 What - Why_.flac"));
        Assert.True(Exists(DeviceManifest.FileName));
        var playlist = File.ReadAllText(Path.Combine(device, "Playlists", "Road Trip.m3u8"));
        Assert.Contains("../Music/AC-DC/Back in Black (1969)/03 What - Why_.flac", playlist.Replace('\\', '/'));
        Assert.Contains("../Music/The Beatles/Abbey Road (1969)/01 Come Together.flac", playlist.Replace('\\', '/'));
        Assert.Empty(Directory.EnumerateFiles(device, "*.partial", SearchOption.AllDirectories));

        // Nothing changed: nothing to do.
        var second = DeviceSync.Plan([a, b, c], [new DevicePlaylist("Road Trip", [c, a])], new DeviceProfile(), DeviceManifest.Read(device), DeviceSyncMode.Sync, device,
            existing: Exists);
        Assert.True(second.IsEmpty);

        // A changed file is copied again, alone.
        var third = Sync([a, b with { ModifiedAt = DateTime.UtcNow }, c], [new DevicePlaylist("Road Trip", [c, a])]);
        Assert.Equal(["Music/The Beatles/Abbey Road (1969)/02 Something.flac"], third.Writes.Select(write => write.Path));
    }

    [Fact]
    public void RemovesOnlyItsOwnFilesWhenDeselected()
    {
        var a = AddTrack(1, "One", "Band", "First", 1);
        var b = AddTrack(2, "Two", "Other", "Second", 1);
        // The user's own files on the card, one where Groovelight would put a song.
        var mine = Path.Combine(device, "Music", "Mine", "keep.mp3");
        Directory.CreateDirectory(Path.GetDirectoryName(mine)!);
        File.WriteAllBytes(mine, [9]);
        var clash = Path.Combine(device, "Music", "Other", "Second (1969)", "01 Two.flac");
        Directory.CreateDirectory(Path.GetDirectoryName(clash)!);
        File.WriteAllBytes(clash, [7]);

        Sync([a, b]);
        Assert.True(Exists("Music/Other/Second (1969)/01 Two (2).flac"));
        Assert.Equal([7], File.ReadAllBytes(clash));

        // Band deselected: its song and emptied folders go; everything not Groovelight's stays.
        var plan = Sync([b]);
        Assert.Equal(["Music/Band/First (1969)/01 One.flac"], plan.Deletions);
        Assert.False(Directory.Exists(Path.Combine(device, "Music", "Band")));
        Assert.True(Exists("Music/Mine/keep.mp3"));
        Assert.True(Exists("Music/Other/Second (1969)/01 Two.flac"));
        // The numbered name is kept on later syncs.
        Assert.True(Sync([b]).IsEmpty);
    }

    [Fact]
    public void SendingAddsWithoutRemoving()
    {
        var a = AddTrack(1, "One", "Band", "First", 1);
        var b = AddTrack(2, "Two", "Band", "First", 2);
        Sync([a]);
        Sync([b], mode: DeviceSyncMode.Send);
        Assert.True(Exists("Music/Band/First (1969)/01 One.flac"));
        Assert.True(Exists("Music/Band/First (1969)/02 Two.flac"));
        // A sync without the sent song keeps it: it was not part of the sync.
        Assert.Empty(Sync([a]).Deletions);
        Assert.True(Exists("Music/Band/First (1969)/02 Two.flac"));
    }

    [Fact]
    public void RespectsTheProfileAndFat32()
    {
        var big = AddTrack(1, "Long", "Band", "Live", 1) with { FileSize = 5L * 1024 * 1024 * 1024 };
        var art = AddTrack(2, "Art", "Band", "Live", 2) with { ArtworkHash = "abc" };
        var profile = new DeviceProfile { MusicFolder = "/MUSIC/", Template = "{albumartist} - {album}/{track:02} {title}", PlaylistFolder = "" };
        var plan = Sync([big, art], [new DevicePlaylist("Mix", [art])], profile: profile, fat32: true);
        Assert.Equal(["Long"], plan.Skipped.Select(item => item.Title));
        Assert.True(Exists("MUSIC/Band - Live/02 Art.flac"));
        Assert.True(Exists("MUSIC/Band - Live/cover.jpg"));
        Assert.True(Exists("Mix.m3u8"));
        Assert.Equal(profile, DeviceManifest.Read(device).Profile);
    }

    [Fact]
    public void CleansFolderSettingsAndCounters()
    {
        Assert.Equal("Music/Songs", DeviceSync.Clean("/Music/../Songs/"));
        Assert.Equal("Music/A/01 x.flac", DeviceSync.StripCounter("Music/A/01 x (2).flac"));
        Assert.Equal("Music/A/01 x.flac", DeviceSync.StripCounter("Music/A/01 x.flac"));
    }

    [Fact]
    public void PlayerDevicesGetSongsTheyCanDecodeOrFlac()
    {
        var flac = AddTrack(1, "Airbag", "Radiohead", "OK Computer", 1) with { Format = "FLAC" };
        var alacTrack = AddTrack(2, "Paranoid Android", "Radiohead", "OK Computer", 2);
        var alac = alacTrack with { Format = "Apple Lossless", Path = alacTrack.Path.Replace(".flac", ".m4a") };
        var dsd = AddTrack(3, "Subterranean", "Radiohead", "OK Computer", 3) with { Format = "DSD Stream" };
        var cueTrack = AddTrack(4, "Exit Music", "Radiohead", "OK Computer", 4);
        var cue = cueTrack with { AudioPath = cueTrack.Path };

        var player = new DevicePlayer(new HashSet<string> { "flac", "mp3", "aac" });
        Assert.Equal(DevicePlayer.DeliveryKind.AsIs, player.Delivery(flac).Kind);
        Assert.Equal(DevicePlayer.DeliveryKind.Flac, player.Delivery(alac).Kind);
        var plan = DeviceSync.Plan([flac, alac, dsd, cue], [], new DeviceProfile(), new DeviceManifest(), DeviceSyncMode.Sync, device, player: player);
        var songs = plan.Writes.Where(write => write.Entry.Kind == ManifestKind.Song).ToDictionary(write => write.Entry.TrackId!.Value);
        Assert.Equal(new DeviceContent.File(flac.Path), songs[1].Content);
        // The ALAC song arrives as FLAC, under a .flac name, and its fingerprint changes with the conversion.
        Assert.Equal(new DeviceContent.Converted(new ConversionSource(alac.Path)), songs[2].Content);
        Assert.EndsWith("02 Paranoid Android.flac", songs[2].Path);
        Assert.EndsWith("|flac", songs[2].Entry.Fingerprint);
        Assert.False(songs.ContainsKey(3));
        Assert.Equal(["DSD does not play on this device yet"], plan.Skipped.Select(item => item.Reason));
        // A song of a CUE album arrives as a FLAC of its own.
        Assert.EndsWith("04 Exit Music.flac", songs[4].Path);
        Assert.EndsWith("|0.0--1.0|flac", songs[4].Entry.Fingerprint);
    }

    [Fact]
    public void DevicesSetToALossyFormatGetLosslessSongsEncoded()
    {
        var flac = AddTrack(1, "Airbag", "Radiohead", "OK Computer", 1) with { Format = "FLAC", Duration = 100 };
        var mp3Track = AddTrack(2, "Lucky", "Radiohead", "OK Computer", 2);
        var mp3 = mp3Track with { Format = "MP3", Path = mp3Track.Path.Replace(".flac", ".mp3") };
        var cueTrack = AddTrack(3, "Exit Music", "Radiohead", "OK Computer", 3);
        var cue = cueTrack with { AudioPath = cueTrack.Path, Format = "FLAC" };
        var profile = new DeviceProfile { Encoding = LossyEncoding.Opus160 };
        var plan = DeviceSync.Plan([flac, mp3, cue], [], profile, new DeviceManifest(), DeviceSyncMode.Sync, device);
        var songs = plan.Writes.Where(write => write.Entry.Kind == ManifestKind.Song).ToDictionary(write => write.Entry.TrackId!.Value);
        Assert.Equal(new DeviceContent.Converted(new ConversionSource(flac.Path, Encoding: LossyEncoding.Opus160)), songs[1].Content);
        Assert.EndsWith("01 Airbag.opus", songs[1].Path);
        Assert.Equal(2_000_000, songs[1].Entry.Size);
        Assert.Equal("opus", DeviceSync.ConvertedCodec(songs[1].Entry.Fingerprint));
        Assert.Equal(new DeviceContent.File(mp3.Path), songs[2].Content);
        Assert.Null(DeviceSync.ConvertedCodec(songs[2].Entry.Fingerprint));
        Assert.DoesNotContain(plan.Writes, write => write.Entry.Kind == ManifestKind.CueSheet);

        // A player that cannot decode the format gets the song as it is (FLAC).
        var playerPlan = DeviceSync.Plan([flac], [], profile, new DeviceManifest(), DeviceSyncMode.Sync, device, player: new DevicePlayer(new HashSet<string> { "flac", "mp3" }));
        Assert.Equal(new DeviceContent.File(flac.Path), playerPlan.Writes.First(write => write.Entry.TrackId == 1).Content);
    }

    [Fact]
    public void SongsRemovedFromTheDeviceLeaveItAndStayOff()
    {
        var one = AddTrack(1, "One", "Band", "LP", 1);
        var two = AddTrack(2, "Two", "Band", "LP", 2);
        var sent = AddTrack(3, "Sent", "Other", "Single", 1);
        var first = DeviceSync.Plan(([one, two], []), ([sent], []), new DeviceProfile(), new DeviceManifest(), device, _ => false);
        var manifest = new DeviceManifest();
        foreach (var write in first.Writes) manifest.Entries[write.Path] = write.Entry;
        var onePath = first.Writes.First(write => write.Entry.TrackId == 1).Path;
        var sentPath = first.Writes.First(write => write.Entry.TrackId == 3).Path;
        Assert.False(manifest.Entries[sentPath].Synced);
        // Removed on the device: still chosen (the album), they leave anyway.
        var next = DeviceSync.Plan(([one, two], []), ([], []), new DeviceProfile(), manifest, device, _ => true, excluded: new HashSet<long> { 1, 3 });
        Assert.Equal(new HashSet<string> { onePath, sentPath }, next.Deletions.ToHashSet());
        Assert.Empty(next.Writes);
        Assert.Contains(next.Unchanged.Keys, path => path.EndsWith("02 Two.flac", StringComparison.Ordinal));

        // Removing and adding change only the selection.
        var selection = new DeviceSelection { Everything = true };
        IReadOnlyList<long> Songs(TransferKind kind, string key) => kind == TransferKind.Album && key == "lp" ? [1, 2] : kind == TransferKind.Song ? [long.Parse(key)] : [];
        var removed = selection.Applying([new TransferRequest("1", TransferAction.Remove, TransferKind.Album, "lp")], Songs);
        Assert.Equal(new HashSet<long> { 1, 2 }, removed.ExcludedTrackIds);
        Assert.True(removed.Everything);
        var back = removed.Applying([new TransferRequest("2", TransferAction.Add, TransferKind.Song, "2")], Songs);
        Assert.Equal(new HashSet<long> { 1 }, back.ExcludedTrackIds);
        Assert.Equal(new HashSet<long> { 2 }, back.TrackIds);
    }

    [Fact]
    public void ConvertsWithFfmpegWhenItIsThere()
    {
        if (!File.Exists(FormatConverter.Tool) && FormatConverter.Tool == "ffmpeg") return;
        var fixture = Path.Combine(AppContext.BaseDirectory, "Fixtures");
        var source = Directory.Exists(fixture) ? Directory.EnumerateFiles(fixture, "*.wav", SearchOption.AllDirectories).FirstOrDefault() : null;
        if (source is null) return;
        foreach (var encoding in new LossyEncoding?[] { null, LossyEncoding.Opus160, LossyEncoding.Mp3320, LossyEncoding.Aac192 })
        {
            var target = Path.Combine(baseFolder, $"out.{encoding?.FileExtension() ?? "flac"}");
            FormatConverter.Convert(new ConversionSource(source, 0, 0.5, new TrackMetadata { Title = "Cut", TrackNumber = 3 }, encoding), target);
            Assert.True(new FileInfo(target).Length > 100, $"{encoding}: {new FileInfo(target).Length} bytes");
        }
    }
}
