using System.IO.Compression;
using Groovelight.Core.Library;

namespace Groovelight.Tests;

public class ArchiveExtractorTests
{
    private static string Scratch()
    {
        var folder = Path.Combine(Path.GetTempPath(), "groovelight-archive-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        return folder;
    }

    [Fact]
    public void ExtractsZipWithFolders()
    {
        var folder = Scratch();
        try
        {
            var zip = Path.Combine(folder, "Album.zip");
            using (var archive = ZipFile.Open(zip, ZipArchiveMode.Create))
            {
                using (var writer = new StreamWriter(archive.CreateEntry("Artist/Album/01 Song.mp3").Open())) writer.Write("audio");
                using (var writer = new StreamWriter(archive.CreateEntry("Artist/Album/cover.jpg").Open())) writer.Write("image");
                // A path escaping the folder is left out.
                using (var writer = new StreamWriter(archive.CreateEntry("../escape.mp3").Open())) writer.Write("bad");
            }
            var output = Path.Combine(folder, "out");
            ArchiveExtractor.Extract(zip, output);
            Assert.Equal("audio", File.ReadAllText(Path.Combine(output, "Artist", "Album", "01 Song.mp3")));
            Assert.True(File.Exists(Path.Combine(output, "Artist", "Album", "cover.jpg")));
            Assert.False(File.Exists(Path.Combine(folder, "escape.mp3")));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [Fact]
    public void ReportsDamagedArchives()
    {
        var folder = Scratch();
        try
        {
            var path = Path.Combine(folder, "Broken.zip");
            File.WriteAllText(path, "not an archive");
            var error = Assert.Throws<ArchiveExtractor.ExtractException>(() => ArchiveExtractor.Extract(path, Path.Combine(folder, "out")));
            Assert.Contains("Broken.zip", error.Message);
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [Fact]
    public void RecognizesArchives()
    {
        Assert.True(ArchiveExtractor.IsArchive("a.ZIP"));
        Assert.True(ArchiveExtractor.IsArchive("a.7z"));
        Assert.False(ArchiveExtractor.IsArchive("a.flac"));
    }
}
