using SkiaSharp;

namespace Groovelight.Tests;

/// <summary>The audio fixtures (Fixtures/Audio, one second of a tone in each format) copied into a scratch folder.</summary>
internal sealed class ScratchFolder : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"groovelight-{Guid.NewGuid():N}");

    public ScratchFolder() => Directory.CreateDirectory(Path);

    public string Combine(params string[] parts) => System.IO.Path.Combine([Path, .. parts]);

    public void Dispose()
    {
        try { Directory.Delete(Path, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }
}

internal static class AudioFixtures
{
    public static string Directory => Path.Combine(AppContext.BaseDirectory, "Fixtures", "Audio");

    /// <summary>Every fixture, as the Swift tests' afconvert set: "Test Artist/Fixture Album/NN Name.ext".</summary>
    public static List<string> CopyAll(string root)
    {
        var album = Path.Combine(root, "Test Artist", "Fixture Album");
        System.IO.Directory.CreateDirectory(album);
        var copies = new List<string>();
        var index = 1;
        foreach (var source in System.IO.Directory.EnumerateFiles(Directory, "tone*").Order(StringComparer.Ordinal))
        {
            var name = Path.GetFileNameWithoutExtension(source).Replace("tone", "Tone");
            var destination = Path.Combine(album, $"{index++:00} {name}{Path.GetExtension(source)}");
            File.Copy(source, destination);
            copies.Add(destination);
        }
        return copies;
    }

    public static byte[] PngData()
    {
        using var bitmap = new SKBitmap(64, 64);
        using (var canvas = new SKCanvas(bitmap)) canvas.Clear(new SKColor(0x2A, 0x4C, 0xA0));
        using var data = bitmap.Encode(SKEncodedImageFormat.Png, 100);
        return data.ToArray();
    }

    /// <summary>Writes tags with TagLib# (SFBAudioEngine's metadata writer in the Swift tests).</summary>
    public static void Tag(string path, Action<TagLib.Tag> edit, Action<TagLib.File>? file = null)
    {
        using var tagged = TagLib.File.Create(path);
        edit(tagged.Tag);
        file?.Invoke(tagged);
        tagged.Save();
    }
}
