using System.Security.Cryptography;
using SkiaSharp;

namespace Groovelight.Core.Library;

/// <summary>Content-addressed artwork store: <c>&lt;hash&gt;.img</c> (original) plus JPEG thumbnails <c>&lt;hash&gt;_&lt;size&gt;.jpg</c>, as on the Mac.</summary>
public sealed class ArtworkCache
{
    public enum Size { Small = 256, Large = 800 }

    public string Directory { get; }

    public ArtworkCache(string directory)
    {
        Directory = directory;
        System.IO.Directory.CreateDirectory(directory);
    }

    public string PathFor(string hash, Size? size) =>
        System.IO.Path.Combine(Directory, size is { } value ? $"{hash}_{(int)value}.jpg" : $"{hash}.img");

    public static string Hash(byte[] data) => Convert.ToHexStringLower(SHA256.HashData(data).AsSpan(0, 16));

    /// <summary>Stores <paramref name="data"/> (any image format the decoder reads) and returns its hash, or null if it is not a valid image.</summary>
    public string? Store(byte[] data)
    {
        var hash = Hash(data);
        if (File.Exists(PathFor(hash, null))) return hash;
        return Store(data, hash) ? hash : null;
    }

    /// <summary>Stores an image under a hash given elsewhere. False when it is not a valid image.</summary>
    public bool Store(byte[] data, string hash)
    {
        var original = PathFor(hash, null);
        using var image = Decode(data);
        if (image is null) return false;
        try
        {
            WriteAtomically(original, data);
            foreach (var size in Enum.GetValues<Size>()) WriteThumbnail(image, (int)size, PathFor(hash, size));
            return true;
        }
        catch (IOException)
        {
            File.Delete(original);
            return false;
        }
    }

    public bool Has(string hash) => File.Exists(PathFor(hash, Size.Small));

    /// <summary>
    /// The image as JPEG with its longest side at most <paramref name="maxPixels"/> (0: the original size), for cover.jpg
    /// files and devices: from the original, or its stored thumbnails when the original is missing or unreadable. Always
    /// 8-bit RGB over white (CMYK, 16-bit or transparent covers do not decode on some players).
    /// </summary>
    public byte[]? Jpeg(string hash, int maxPixels)
    {
        foreach (var candidate in new[] { PathFor(hash, null), PathFor(hash, Size.Large), PathFor(hash, Size.Small) })
        {
            if (!File.Exists(candidate)) continue;
            byte[] data;
            try { data = File.ReadAllBytes(candidate); }
            catch (IOException) { continue; }
            using var image = Decode(data);
            if (image is null || image.Width <= 0 || image.Height <= 0) continue;
            var scale = maxPixels > 0 ? Math.Min(1, maxPixels / (double)Math.Max(image.Width, image.Height)) : 1;
            var width = Math.Max(1, (int)Math.Round(image.Width * scale));
            var height = Math.Max(1, (int)Math.Round(image.Height * scale));
            using var surface = SKSurface.Create(new SKImageInfo(width, height, SKColorType.Rgba8888, SKAlphaType.Opaque, SKColorSpace.CreateSrgb()));
            surface.Canvas.Clear(SKColors.White);
            using var source = SKImage.FromBitmap(image);
            surface.Canvas.DrawImage(source, SKRect.Create(width, height), new SKSamplingOptions(SKCubicResampler.Mitchell));
            using var snapshot = surface.Snapshot();
            using var encoded = snapshot.Encode(SKEncodedImageFormat.Jpeg, 88);
            if (encoded is not null) return encoded.ToArray();
        }
        return null;
    }

    /// <summary>Removes every image but <paramref name="hashes"/>.</summary>
    public void Prune(IReadOnlySet<string> hashes)
    {
        foreach (var file in System.IO.Directory.EnumerateFiles(Directory))
        {
            var name = System.IO.Path.GetFileName(file);
            var end = name.IndexOfAny(['.', '_']);
            if (!hashes.Contains(end < 0 ? name : name[..end])) File.Delete(file);
        }
    }

    /// <summary>The image upright (EXIF orientation applied), or null when the data is not an image.</summary>
    private static SKBitmap? Decode(byte[] data)
    {
        using var codec = SKCodec.Create(new SKMemoryStream(data));
        if (codec is null) return null;
        var bitmap = SKBitmap.Decode(codec);
        if (bitmap is null) return null;
        if (codec.EncodedOrigin == SKEncodedOrigin.TopLeft) return bitmap;
        var upright = Orient(bitmap, codec.EncodedOrigin);
        bitmap.Dispose();
        return upright;
    }

    /// <summary>Draws the bitmap upright for its EXIF origin (x' = a x + b y + c, y' = d x + e y + f).</summary>
    private static SKBitmap Orient(SKBitmap bitmap, SKEncodedOrigin origin)
    {
        float w = bitmap.Width, h = bitmap.Height;
        var swaps = origin is SKEncodedOrigin.LeftTop or SKEncodedOrigin.RightTop or SKEncodedOrigin.RightBottom or SKEncodedOrigin.LeftBottom;
        var matrix = origin switch
        {
            SKEncodedOrigin.TopRight => new SKMatrix(-1, 0, w, 0, 1, 0, 0, 0, 1),
            SKEncodedOrigin.BottomRight => new SKMatrix(-1, 0, w, 0, -1, h, 0, 0, 1),
            SKEncodedOrigin.BottomLeft => new SKMatrix(1, 0, 0, 0, -1, h, 0, 0, 1),
            SKEncodedOrigin.LeftTop => new SKMatrix(0, 1, 0, 1, 0, 0, 0, 0, 1),
            SKEncodedOrigin.RightTop => new SKMatrix(0, -1, h, 1, 0, 0, 0, 0, 1),
            SKEncodedOrigin.RightBottom => new SKMatrix(0, -1, h, -1, 0, w, 0, 0, 1),
            SKEncodedOrigin.LeftBottom => new SKMatrix(0, 1, 0, -1, 0, w, 0, 0, 1),
            _ => SKMatrix.Identity,
        };
        var result = new SKBitmap(swaps ? bitmap.Height : bitmap.Width, swaps ? bitmap.Width : bitmap.Height);
        using var canvas = new SKCanvas(result);
        canvas.SetMatrix(matrix);
        using var image = SKImage.FromBitmap(bitmap);
        canvas.DrawImage(image, 0, 0, SKSamplingOptions.Default);
        return result;
    }

    private static void WriteThumbnail(SKBitmap image, int maxSide, string path)
    {
        var scale = Math.Min(1.0, (double)maxSide / Math.Max(image.Width, image.Height));
        var width = Math.Max(1, (int)Math.Round(image.Width * scale));
        var height = Math.Max(1, (int)Math.Round(image.Height * scale));
        using var resized = scale < 1 ? image.Resize(new SKImageInfo(width, height), new SKSamplingOptions(SKCubicResampler.Mitchell)) : null;
        using var encoded = (resized ?? image).Encode(SKEncodedImageFormat.Jpeg, 85);
        WriteAtomically(path, encoded.ToArray());
    }

    private static void WriteAtomically(string path, byte[] data)
    {
        var temporary = path + ".tmp";
        File.WriteAllBytes(temporary, data);
        File.Move(temporary, path, overwrite: true);
    }

    /// <summary>Looks for a cover image next to the audio files (cover.jpg, folder.png, front.jpeg...).</summary>
    public static string? FolderImage(string directory)
    {
        string[] names = ["cover", "folder", "front", "albumart", "album", "artwork"];
        string[] extensions = [".jpg", ".jpeg", ".png", ".webp", ".heic"];
        string[] candidates;
        try
        {
            candidates = System.IO.Directory.EnumerateFiles(directory)
                .Where(file => extensions.Contains(System.IO.Path.GetExtension(file).ToLowerInvariant())).ToArray();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }
        foreach (var name in names)
        {
            var match = candidates.FirstOrDefault(file => System.IO.Path.GetFileNameWithoutExtension(file).Equals(name, StringComparison.OrdinalIgnoreCase));
            if (match is not null) return match;
        }
        return null;
    }
}
