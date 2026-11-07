namespace Groovelight.Core.Library;

/// <summary>Writes metadata fixes, lyrics and cover art into audio files (TagLib#; SFBAudioEngine on the Mac).</summary>
public static class TagWriter
{
    public sealed record Result(long FileSize, DateTime ModifiedAt);

    /// <summary>
    /// Writes the fields set in <paramref name="metadata"/> (others are left untouched; an empty string or 0 removes the
    /// tag), plus optional lyrics and front cover. Returns the file's new size and modification date.
    /// </summary>
    public static Result Write(TrackMetadata metadata, string path, string? lyrics = null, byte[]? frontCover = null)
    {
        using (var file = TagLib.File.Create(path))
        {
            var tag = file.Tag;
            static string? Text(string value) => value.Trim().Length == 0 ? null : value;
            static uint Number(int value) => value <= 0 ? 0 : (uint)value;
            static string[] List(string value) => Text(value) is { } text ? [text] : [];

            if (metadata.Title is { } title) tag.Title = Text(title);
            if (metadata.Artist is { } artist) tag.Performers = List(artist);
            if (metadata.Album is { } album) tag.Album = Text(album);
            if (metadata.AlbumArtist is { } albumArtist) tag.AlbumArtists = List(albumArtist);
            if (metadata.Genre is { } genre) tag.Genres = List(genre);
            if (metadata.Composer is { } composer) tag.Composers = List(composer);
            if (metadata.Comment is { } comment) tag.Comment = Text(comment);
            if (metadata.Year is { } year) tag.Year = Number(year);
            if (metadata.TrackNumber is { } track) tag.Track = Number(track);
            if (metadata.TrackTotal is { } trackTotal) tag.TrackCount = Number(trackTotal);
            if (metadata.DiscNumber is { } disc) tag.Disc = Number(disc);
            if (metadata.DiscTotal is { } discTotal) tag.DiscCount = Number(discTotal);
            if (metadata.Bpm is { } bpm) tag.BeatsPerMinute = Number(bpm);
            if (metadata.IsCompilation is { } compilation) SetCompilation(file, compilation);
            if (metadata.MusicBrainzRecordingId is { } recording) tag.MusicBrainzTrackId = Text(recording);
            if (metadata.MusicBrainzReleaseId is { } release) tag.MusicBrainzReleaseId = Text(release);
            if (metadata.Lyrics is { } metadataLyrics) tag.Lyrics = Text(metadataLyrics);
            if (lyrics is not null) tag.Lyrics = lyrics;
            if (frontCover is not null)
            {
                var others = (tag.Pictures ?? []).Where(picture => picture.Type != TagLib.PictureType.FrontCover);
                tag.Pictures = [.. others, new TagLib.Picture(new TagLib.ByteVector(frontCover)) { Type = TagLib.PictureType.FrontCover }];
            }
            file.Save();
        }
        var info = new FileInfo(path);
        return new Result(info.Length, info.LastWriteTimeUtc);
    }

    /// <summary>The compilation flag in each format's own field (what the tag reader reads back).</summary>
    private static void SetCompilation(TagLib.File file, bool compilation)
    {
        if (file.GetTag(TagLib.TagTypes.Xiph) is TagLib.Ogg.XiphComment xiph)
        {
            if (compilation) xiph.SetField("COMPILATION", "1"); else xiph.RemoveField("COMPILATION");
        }
        if (file.GetTag(TagLib.TagTypes.Apple) is TagLib.Mpeg4.AppleTag apple) apple.IsCompilation = compilation;
        if (file.GetTag(TagLib.TagTypes.Id3v2) is TagLib.Id3v2.Tag id3)
        {
            if (compilation) TagLib.Id3v2.TextInformationFrame.Get(id3, "TCMP", true).Text = ["1"];
            else id3.RemoveFrames("TCMP");
        }
        if (file.GetTag(TagLib.TagTypes.Ape) is TagLib.Ape.Tag ape)
        {
            if (compilation) ape.SetValue("Compilation", "1"); else ape.RemoveItem("Compilation");
        }
    }
}
