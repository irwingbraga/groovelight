using SkiaSharp;

namespace Groovelight.Core.Library;

/// <summary>A diagonal two-color gradient for generated playlist covers (the Mac's CoverPalette).</summary>
public sealed record CoverPalette(string Id, string Name, (double R, double G, double B) Top, (double R, double G, double B) Bottom)
{
    public static readonly IReadOnlyList<CoverPalette> All =
    [
        new("sunset", "Sunset", (0.98, 0.58, 0.28), (0.52, 0.09, 0.24)),
        new("rose", "Rose", (1.00, 0.45, 0.60), (0.50, 0.07, 0.25)),
        new("grape", "Grape", (0.76, 0.46, 0.96), (0.18, 0.05, 0.34)),
        new("ocean", "Ocean", (0.26, 0.56, 0.98), (0.04, 0.09, 0.33)),
        new("teal", "Teal", (0.36, 0.90, 0.84), (0.04, 0.19, 0.29)),
        new("forest", "Forest", (0.46, 0.86, 0.55), (0.04, 0.24, 0.14)),
        new("gold", "Gold", (0.96, 0.80, 0.34), (0.38, 0.23, 0.04)),
        new("ember", "Ember", (0.95, 0.35, 0.20), (0.20, 0.03, 0.03)),
        new("slate", "Slate", (0.74, 0.79, 0.88), (0.19, 0.24, 0.34)),
        new("midnight", "Midnight", (0.32, 0.32, 0.48), (0.03, 0.03, 0.08)),
        new("mint", "Mint", (0.86, 0.98, 0.84), (0.48, 0.80, 0.62)),
        new("cream", "Cream", (0.99, 0.96, 0.88), (0.84, 0.77, 0.66)),
    ];

    public static CoverPalette Named(string id) => All.FirstOrDefault(palette => palette.Id == id) ?? All[0];

    /// <summary>A stable palette for a seed (playlists created before covers existed).</summary>
    public static CoverPalette ForSeed(long seed) => All[(int)(unchecked((ulong)(seed * 2_654_435_761L)) % (ulong)All.Count)];

    /// <summary>Brightness of the top-left color, where the title is drawn.</summary>
    public double TitleCornerLuminance => PlaylistCovers.Luma(Top.R, Top.G, Top.B);
}

/// <summary>Decorations drawn over a palette: records, the spectrum visualizer, light and sound waves.</summary>
public static class CoverPattern
{
    public static readonly IReadOnlyList<(string Id, string Name)> All =
        [("none", "Gradient"), ("vinyl", "Vinyl"), ("spectrum", "Spectrum"), ("glow", "Glow"), ("waves", "Waves")];
}

/// <summary>Draws playlist covers as the Mac does (generated, a custom image, or a mosaic of the songs' covers, with the name).</summary>
public static class PlaylistCovers
{
    /// <summary>A random generated cover for a new playlist.</summary>
    public static PlaylistCover RandomGenerated() =>
        new(new PlaylistCoverKind.Generated(CoverPalette.All[Random.Shared.Next(CoverPalette.All.Count)].Id, "none"));

    /// <summary>The name is on every cover, except a custom image whose owner turned it off.</summary>
    public static bool ShowsTitle(PlaylistCover? cover) => cover is not { Kind: PlaylistCoverKind.Image } || cover.ShowsTitle;

    /// <summary>Perceived brightness (Rec. 709 luma on the sRGB values, 0 to 1), used to choose black or white text.</summary>
    public static double Luma(double r, double g, double b) => 0.2126 * r + 0.7152 * g + 0.0722 * b;

    /// <summary>
    /// The cover as a PNG of <paramref name="side"/> pixels. <paramref name="songHashes"/>: covers of the playlist's
    /// songs (the mosaic, and the cover when none was chosen); <paramref name="seed"/> picks a palette otherwise.
    /// </summary>
    public static byte[] RenderPng(ArtworkCache artwork, string name, PlaylistCover? cover, IReadOnlyList<string> songHashes, long seed,
                                   int side, bool hidesTitle = false)
    {
        using var surface = SKSurface.Create(new SKImageInfo(side, side, SKColorType.Rgba8888, SKAlphaType.Premul));
        Draw(surface.Canvas, artwork, name, cover, songHashes, seed, side, hidesTitle);
        using var image = surface.Snapshot();
        using var data = image.Encode(SKEncodedImageFormat.Png, 100);
        return data.ToArray();
    }

    public static void Draw(SKCanvas canvas, ArtworkCache artwork, string name, PlaylistCover? cover, IReadOnlyList<string> songHashes,
                            long seed, int side, bool hidesTitle)
    {
        var kind = cover?.Kind ?? (songHashes.Count == 0
            ? new PlaylistCoverKind.Generated(CoverPalette.ForSeed(seed).Id, "none")
            : new PlaylistCoverKind.SongCovers());
        var showsTitle = !hidesTitle && ShowsTitle(cover);
        canvas.Clear(SKColors.Transparent);
        switch (kind)
        {
            case PlaylistCoverKind.Generated generated:
            {
                var palette = CoverPalette.Named(generated.Palette);
                using (var paint = new SKPaint())
                {
                    paint.Shader = SKShader.CreateLinearGradient(new SKPoint(0, 0), new SKPoint(side, side),
                        [Color(palette.Top), Color(palette.Bottom)], SKShaderTileMode.Clamp);
                    canvas.DrawRect(0, 0, side, side, paint);
                }
                DrawPattern(canvas, generated.Pattern, side);
                if (showsTitle) DrawTitle(canvas, name, side, palette.TitleCornerLuminance > 0.55);
                break;
            }
            case PlaylistCoverKind.Image image:
            {
                var luminance = DrawImage(canvas, artwork, image.Hash, new SKRect(0, 0, side, side), side > 300);
                if (showsTitle) DrawTitle(canvas, name, side, luminance > 0.55);
                break;
            }
            default:
            {
                double luminance;
                if (songHashes.Count >= 4)
                {
                    var half = side / 2f;
                    luminance = DrawImage(canvas, artwork, songHashes[0], new SKRect(0, 0, half, half), false);
                    DrawImage(canvas, artwork, songHashes[1], new SKRect(half, 0, side, half), false);
                    DrawImage(canvas, artwork, songHashes[2], new SKRect(0, half, half, side), false);
                    DrawImage(canvas, artwork, songHashes[3], new SKRect(half, half, side, side), false);
                }
                else luminance = DrawImage(canvas, artwork, songHashes.FirstOrDefault(), new SKRect(0, 0, side, side), side > 300);
                if (showsTitle) DrawTitle(canvas, name, side, luminance > 0.55);
                break;
            }
        }
    }

    private static SKColor Color((double R, double G, double B) rgb) =>
        new((byte)Math.Round(rgb.R * 255), (byte)Math.Round(rgb.G * 255), (byte)Math.Round(rgb.B * 255));

    /// <summary>Draws a cached artwork image filling <paramref name="rect"/>; returns the brightness of its title corner.</summary>
    private static double DrawImage(SKCanvas canvas, ArtworkCache artwork, string? hash, SKRect rect, bool large)
    {
        SKBitmap? bitmap = null;
        if (hash is not null)
        {
            var path = artwork.PathFor(hash, large ? ArtworkCache.Size.Large : ArtworkCache.Size.Small);
            if (!File.Exists(path)) path = artwork.PathFor(hash, ArtworkCache.Size.Small);
            if (File.Exists(path)) bitmap = SKBitmap.Decode(path);
        }
        if (bitmap is null)
        {
            // The placeholder: the app's gray gradient.
            using var paint = new SKPaint();
            paint.Shader = SKShader.CreateLinearGradient(new SKPoint(rect.Left, rect.Top), new SKPoint(rect.Right, rect.Bottom),
                [new SKColor(0x8E, 0x8E, 0x93), new SKColor(0x48, 0x48, 0x4A)], SKShaderTileMode.Clamp);
            canvas.DrawRect(rect, paint);
            return 0.4;
        }
        using (bitmap)
        {
            using var image = SKImage.FromBitmap(bitmap);
            // Fill (center crop) like the Mac's artwork views.
            var scale = Math.Max(rect.Width / bitmap.Width, rect.Height / bitmap.Height);
            var width = rect.Width / scale;
            var height = rect.Height / scale;
            var source = new SKRect((bitmap.Width - width) / 2, (bitmap.Height - height) / 2, (bitmap.Width + width) / 2, (bitmap.Height + height) / 2);
            canvas.DrawImage(image, source, rect, new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear));
            return CornerLuminance(bitmap);
        }
    }

    /// <summary>Average brightness of the top left region (60% wide, 35% tall), where the title sits.</summary>
    private static double CornerLuminance(SKBitmap bitmap)
    {
        var width = Math.Max(1, (int)(bitmap.Width * 0.6));
        var height = Math.Max(1, (int)(bitmap.Height * 0.35));
        double total = 0;
        var count = 0;
        for (var y = 0; y < height; y += Math.Max(1, height / 24))
        {
            for (var x = 0; x < width; x += Math.Max(1, width / 24))
            {
                var pixel = bitmap.GetPixel(x, y);
                total += Luma(pixel.Red / 255.0, pixel.Green / 255.0, pixel.Blue / 255.0);
                count++;
            }
        }
        return count == 0 ? 0 : total / count;
    }

    private static void DrawPattern(SKCanvas canvas, string pattern, float side)
    {
        using var paint = new SKPaint { IsAntialias = true };
        switch (pattern)
        {
            case "vinyl":
            {
                // A record peeking from the bottom right corner: grooves and a label.
                var center = new SKPoint(side * 0.82f, side * 0.82f);
                paint.Style = SKPaintStyle.Stroke;
                paint.StrokeWidth = side * 0.006f;
                for (var index = 0; index < 16; index++)
                {
                    paint.Color = SKColors.White.WithAlpha((byte)(255 * (index % 4 == 0 ? 0.16 : 0.08)));
                    canvas.DrawCircle(center, side * (0.16f + index * 0.045f), paint);
                }
                paint.Style = SKPaintStyle.Fill;
                paint.Color = SKColors.White.WithAlpha((byte)(255 * 0.22));
                canvas.DrawCircle(center, side * 0.12f, paint);
                break;
            }
            case "spectrum":
            {
                // Visualizer bars along the bottom.
                const int count = 14;
                var gap = side * 0.012f;
                var width = (side - gap * (count + 1)) / count;
                paint.Color = SKColors.White.WithAlpha((byte)(255 * 0.22));
                for (var index = 0; index < count; index++)
                {
                    var level = 0.25 + 0.55 * Math.Abs(Math.Sin(index * 1.7 + 0.6)) * (1 - (double)index / count * 0.4);
                    var height = (float)(side * 0.45 * level);
                    var rect = SKRect.Create(gap + index * (width + gap), side - height - gap, width, height);
                    canvas.DrawRoundRect(rect, width * 0.25f, width * 0.25f, paint);
                }
                break;
            }
            case "glow":
            {
                // Soft light from the bottom right, like the old visualizers.
                paint.Shader = SKShader.CreateRadialGradient(new SKPoint(side * 0.78f, side * 0.8f), side * 0.65f,
                    [SKColors.White.WithAlpha((byte)(255 * 0.45)), SKColors.White.WithAlpha(0)], SKShaderTileMode.Clamp);
                canvas.DrawRect(0, 0, side, side, paint);
                break;
            }
            case "waves":
            {
                paint.Style = SKPaintStyle.Stroke;
                paint.StrokeWidth = side * 0.008f;
                paint.Color = SKColors.White.WithAlpha((byte)(255 * 0.18));
                for (var index = 0; index < 6; index++)
                {
                    using var builder = new SKPathBuilder();
                    var baseline = side * (0.55f + index * 0.075f);
                    var amplitude = side * (0.05f + index * 0.006f);
                    builder.MoveTo(0, baseline);
                    for (float x = 0; x <= side; x += 2)
                        builder.LineTo(x, baseline + (float)Math.Sin(x / side * Math.PI * 3 + index * 0.5) * amplitude);
                    using var path = builder.Detach();
                    canvas.DrawPath(path, paint);
                }
                break;
            }
        }
    }

    /// <summary>
    /// The name in the top left corner, sized to the cover: dark text on light corners, light text on dark ones, with a
    /// faint shadow of the opposite tone. Up to three lines, shrinking (to 60%) before it is cut.
    /// </summary>
    private static void DrawTitle(SKCanvas canvas, string name, float side, bool isDark)
    {
        var padding = side * 0.075f;
        var maxWidth = side * 0.92f - padding * 2;
        var size = Math.Max(9, side * 0.105f);
        using var typeface = SKTypeface.FromFamilyName("Segoe UI", SKFontStyleWeight.Black, SKFontStyleWidth.Normal, SKFontStyleSlant.Upright)
                             ?? SKTypeface.Default;
        List<string> lines = [];
        SKFont? font = null;
        for (var scale = 1.0f; scale >= 0.6f; scale -= 0.05f)
        {
            font?.Dispose();
            font = new SKFont(typeface, size * scale) { Edging = SKFontEdging.SubpixelAntialias };
            lines = Wrap(name, font, maxWidth);
            if (lines.Count <= 3 && lines.All(line => font.MeasureText(line) <= maxWidth)) break;
        }
        using (font)
        {
            if (lines.Count > 3)
            {
                lines = lines.Take(3).ToList();
                lines[2] = lines[2].TrimEnd() + "…";
            }
            using var paint = new SKPaint { IsAntialias = true, Color = isDark ? new SKColor(0, 0, 0, (byte)(255 * 0.82)) : SKColors.White };
            var shadow = (isDark ? SKColors.White : SKColors.Black).WithAlpha((byte)(255 * 0.35));
            paint.ImageFilter = SKImageFilter.CreateDropShadow(0, 0, side * 0.01f, side * 0.01f, shadow);
            var metrics = font!.Metrics;
            var lineHeight = font.Spacing;
            var y = padding - metrics.Ascent;
            foreach (var line in lines)
            {
                canvas.DrawText(line, padding, y, SKTextAlign.Left, font, paint);
                y += lineHeight;
            }
        }
    }

    private static List<string> Wrap(string text, SKFont font, float width)
    {
        var lines = new List<string>();
        var current = "";
        foreach (var word in text.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = current.Length == 0 ? word : current + " " + word;
            if (font.MeasureText(candidate) <= width || current.Length == 0) current = candidate;
            else
            {
                lines.Add(current);
                current = word;
            }
        }
        if (current.Length > 0) lines.Add(current);
        return lines;
    }
}
