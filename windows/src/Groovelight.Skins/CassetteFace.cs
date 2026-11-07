using SkiaSharp;
using static Groovelight.Skins.Colors;

namespace Groovelight.Skins;

/// <summary>Where a cassette's own pictures are on disk, and a number that changes with them.</summary>
public sealed record CassettePictures(string? Shell = null, string? Label = null, int Revision = 0)
{
    private static readonly Dictionary<string, SKImage?> images = [];

    /// <summary>The user's picture, decoded once per file and revision.</summary>
    internal SKImage? Image(string? path)
    {
        if (path is null) return null;
        var key = $"{path}#{Revision}";
        lock (images)
        {
            if (images.TryGetValue(key, out var image)) return image;
            try { image = File.Exists(path) ? SKImage.FromEncodedData(path) : null; }
            catch (IOException) { image = null; }
            images[key] = image;
            return image;
        }
    }
}

public static class CassetteStorePictures
{
    public static CassettePictures Pictures(this CassetteStore store, CassetteDesign design) =>
        new(store.PathOf(CassetteStore.Picture.Shell, design), store.PathOf(CassetteStore.Picture.Label, design), store.Revision);
}

/// <summary>How much tape each reel holds and how far each has turned (radii in points, angles in degrees).</summary>
internal readonly record struct ReelState(float LeftRadius, float RightRadius, float LeftAngle, float RightAngle)
{
    /// <summary>
    /// The tape goes from the left reel to the right one over the song at one speed (a bare hub turning half a turn a
    /// second). A pack grows as r² = r0² + k·s, so a reel has turned 2 (r - r0) / k.
    /// </summary>
    public static ReelState Of(CassetteGeometry geometry, float width, SkinPlayback playback)
    {
        var full = (float)geometry.ReelRadius * width;
        var hub = (float)geometry.HubRadius * width * 1.05f;
        var wound = full * full - hub * hub;
        var progress = (float)playback.Progress;
        var left = MathF.Sqrt(full * full - wound * progress);
        var right = MathF.Sqrt(hub * hub + wound * progress);
        if (playback.Duration <= 0 || wound <= 0)
        {
            var angle = (float)(playback.Time() * 180);
            return new ReelState(left, right, angle, angle);
        }
        var k = wound / (playback.Duration * Math.PI * hub);
        return new ReelState(left, right, (float)(2 * (full - left) / k * 180 / Math.PI), (float)(2 * (right - hub) / k * 180 / Math.PI));
    }
}

/// <summary>
/// A cassette from the front at its own size (the Mac's CassetteFace): the reels turn as the tape goes from the left one
/// to the right one, behind the design's shell and label, or behind the user's picture of them.
/// </summary>
public static class CassetteFace
{
    /// <summary>Draws the cassette into <paramref name="rect"/> (a cassette's shape: the design's aspect ratio).</summary>
    public static void Draw(SKCanvas canvas, SKRect rect, CassetteDesign design, CassettePictures pictures, SkinPlayback playback) =>
        Draw(canvas, rect, design, pictures, playback, null);

    /// <summary>
    /// Draws the cassette; with <paramref name="cache"/>, what does not move (the shell, the label) is kept as images and
    /// only the reels are drawn each frame.
    /// </summary>
    internal static void Draw(SKCanvas canvas, SKRect rect, CassetteDesign design, CassettePictures pictures, SkinPlayback playback,
                              Func<string, SKSize, Action<SKCanvas>, SKImage>? cache)
    {
        canvas.Save();
        canvas.Translate(rect.Left, rect.Top);
        var size = rect.Size;
        var layout = design.ResolvedGeometry;
        var reels = ReelState.Of(layout, size.Width, playback);
        var shellPicture = pictures.Image(pictures.Shell);
        var key = $"{System.Runtime.CompilerServices.RuntimeHelpers.GetHashCode(design)}|{pictures}|{playback.Title}|{playback.Artist}|{playback.Artwork?.UniqueId}";
        void Layer(string slot, Action<SKCanvas> draw)
        {
            if (cache is null) draw(canvas);
            else canvas.Image(cache($"{slot}:{key}", size, draw), SKRect.Create(size));
        }
        if (shellPicture is not null)
        {
            // The user's shell: the reels show through its transparent parts.
            Reels(canvas, design, layout, size, reels, true);
            Layer("cassette.front", layer =>
            {
                layer.Image(shellPicture, SKRect.Create(size));
                Label(layer, design, layout, size, playback, pictures, pictures.Label is not null);
            });
        }
        else
        {
            Layer("cassette.back", layer => Back(layer, design, size));
            Reels(canvas, design, layout, size, reels, design.ShellClarity > 0);
            Layer("cassette.front", layer => Front(layer, design, layout, size, playback, pictures));
        }
        canvas.Restore();
    }

    internal static void Draw(DeckUi ui, SKRect rect, CassetteDesign design, CassettePictures pictures, SkinPlayback playback) =>
        Draw(ui.Canvas, rect, design, pictures, playback, ui.Cached);

    private static SKRect Rect(CassetteRect rect, SKSize size) =>
        SKRect.Create((float)rect.X * size.Width, (float)rect.Y * size.Height, (float)rect.Width * size.Width, (float)rect.Height * size.Height);

    private static SKPoint Point(CassettePoint point, SKSize size) => new((float)point.X * size.Width, (float)point.Y * size.Height);

    /// <summary>The two packs of tape and their hubs, and (through a clear shell) the tape running along the bottom.</summary>
    private static void Reels(SKCanvas canvas, CassetteDesign design, CassetteGeometry layout, SKSize size, ReelState reels, bool showsTape)
    {
        var tape = design.Reels.TapeColor.Color;
        var left = Point(layout.LeftReel, size);
        var right = Point(layout.RightReel, size);
        var hub = (float)layout.HubRadius * size.Width;
        if (showsTape)
        {
            using var path = Shapes.Build(b =>
            {
                var guide = size.Height * 0.86f;
                b.MoveTo(left.X - reels.LeftRadius, left.Y);
                b.LineTo(size.Width * 0.1f, guide);
                b.LineTo(size.Width * 0.9f, guide);
                b.LineTo(right.X + reels.RightRadius, right.Y);
            });
            canvas.Stroke(path, tape.Opacity(0.9), Math.Max(1, size.Width * 0.004f));
        }
        foreach (var (center, radius) in new[] { (left, reels.LeftRadius), (right, reels.RightRadius) })
        {
            var packRect = Shapes.Square(center, radius * 2);
            using var pack = Shapes.Oval(packRect);
            canvas.Fill(pack, Gradients.Radial(packRect, Unit.Center, 0, radius, [tape.Opacity(0.75), tape, tape.Opacity(0.85)]));
            canvas.CircleBorder(packRect, Black(0.25), 0.5f);
        }
        Hub(canvas, design.Reels.HubColor.Color, left, hub, reels.LeftAngle);
        Hub(canvas, design.Reels.HubColor.Color, right, hub, reels.RightAngle);
    }

    /// <summary>A reel's hub: a ring with six teeth inside, the spindle's hole in the middle.</summary>
    private static void Hub(SKCanvas canvas, SKColor color, SKPoint center, float radius, float angle)
    {
        using (var ring = Shapes.Circle(center, radius)) canvas.Fill(ring, color);
        var hole = radius * 0.62f;
        using (var shape = Shapes.Circle(center, hole)) canvas.Fill(shape, Black(0.85));
        canvas.Save();
        canvas.RotateDegrees(angle, center.X, center.Y);
        for (var tooth = 0; tooth < 6; tooth++)
        {
            canvas.Save();
            canvas.RotateDegrees(tooth * 60, center.X, center.Y);
            using var shape = Shapes.Round(SKRect.Create(center.X - radius * 0.09f, center.Y - hole - 0.5f, radius * 0.18f, radius * 0.26f), radius * 0.03f);
            canvas.Fill(shape, color);
            canvas.Restore();
        }
        canvas.Restore();
    }

    /// <summary>The front: rounded with the window and the hubs' holes cut out (even-odd).</summary>
    private static SKPath Cutout(SKRect rect, float corner, SKRect window, IEnumerable<SKPoint> holes, float holeRadius) => Shapes.Build(b =>
    {
        b.AddRoundRect(new SKRoundRect(rect, corner));
        b.AddRoundRect(new SKRoundRect(window, window.Height * 0.18f));
        foreach (var hole in holes) b.AddOval(Shapes.Square(hole, holeRadius * 2));
    }, SKPathFillType.EvenOdd);

    /// <summary>The back of the shell, seen through the windows (and all over a clear one).</summary>
    private static void Back(SKCanvas canvas, CassetteDesign design, SKSize size)
    {
        using var back = Shapes.Round(SKRect.Create(size), size.Width * 0.035f);
        canvas.Fill(back, design.ShellColor.Color.Opacity(design.ShellClarity > 0 ? 0.35 : 1));
        canvas.Fill(back, Black(0.35));
    }

    /// <summary>The shell's front drawn from the design: the plastic with the window and the hubs' holes, the label, the head opening, the screws.</summary>
    private static void Front(SKCanvas canvas, CassetteDesign design, CassetteGeometry layout, SKSize size, SkinPlayback playback, CassettePictures pictures)
    {
        var shell = design.ShellColor.Color;
        var detail = design.DetailColor.Color;
        var corner = size.Width * 0.035f;
        var clarity = design.ShellClarity;
        var all = SKRect.Create(size);
        var window = Rect(layout.Window, size);
        var hubHole = (float)layout.HubRadius * size.Width * 1.25f;
        SKPoint[] holes = [Point(layout.LeftReel, size), Point(layout.RightReel, size)];
        // The front, with the window and the hubs' holes cut out: the mould's matte grain, the light across the plastic.
        using (var front = Cutout(all, corner, window, holes, hubHole))
        {
            canvas.Fill(front, shell.Opacity(1 - clarity));
            Textures.Fill(canvas, front, SkinTexture.Grain, opacity: clarity > 0 ? 0.35 : 0.8, blend: SKBlendMode.Overlay);
            Textures.Fill(canvas, front, SkinTexture.Grain, opacity: 0.05, blend: SKBlendMode.Screen);
            canvas.Fill(front, Gradients.Linear(all, Unit.TopLeading, Unit.BottomTrailing, (0, White(0.2)), (0.35f, White(0.05)), (0.6f, Clear), (1, Black(0.16))));
        }
        Label(canvas, design, layout, size, playback, pictures, true);
        // Printed rings around the hubs' holes.
        if (design.Reels.RingColor is { } ring)
        {
            var width = size.Width * 0.011f;
            foreach (var hole in holes)
            {
                var rect = Shapes.Square(hole, (hubHole + width) * 2);
                Materials.Print(canvas, SKRect.Inflate(rect, 1, 1), design.Reels.RingFinish, ring.Color, color => canvas.CircleBorder(rect, color, width));
            }
        }
        // The window's frame, and its clear plastic.
        using (var glass = Shapes.Round(window, window.Height * 0.18f)) canvas.Fill(glass, Gradients.Vertical(window, White(0.16), White(0.03)));
        canvas.Border(window, window.Height * 0.18f, detail, size.Width * 0.005f);
        // The head opening along the bottom: a raised trapezoid with its holes.
        using (var head = Shapes.Build(b =>
        {
            b.MoveTo(size.Width * 0.17f, size.Height);
            b.LineTo(size.Width * 0.22f, size.Height * 0.79f);
            b.LineTo(size.Width * 0.78f, size.Height * 0.79f);
            b.LineTo(size.Width * 0.83f, size.Height);
            b.Close();
        }))
        {
            canvas.Fill(head, shell.Opacity(Math.Max(1 - clarity, 0.55)));
            canvas.Fill(head, Black(0.18));
            canvas.Stroke(head, detail.Opacity(0.8), size.Width * 0.003f);
        }
        // The grip's molded ribs along the head area.
        for (var rib = 0; rib < 5; rib++)
        {
            var y = size.Height * (0.815f + rib * 0.012f);
            var inset = size.Width * (0.225f - rib * 0.0029f);
            var line = Math.Max(0.6f, size.Width * 0.0025f);
            canvas.Line(new SKPoint(inset, y), new SKPoint(size.Width - inset, y), Black(0.35), line);
            canvas.Line(new SKPoint(inset, y + line), new SKPoint(size.Width - inset, y + line), White(0.09), Math.Max(0.5f, size.Width * 0.0015f));
        }
        foreach (var (x, w) in new[] { (0.25f, 0.04f), (0.38f, 0.05f), (0.5f, 0.04f), (0.62f, 0.05f), (0.75f, 0.04f) })
        {
            using var hole = Shapes.Round(Shapes.CenteredRect(new SKPoint(size.Width * x, size.Height * 0.9f), size.Width * w, size.Height * 0.05f), size.Width * 0.004f);
            canvas.Fill(hole, Black(0.75));
        }
        foreach (var (x, y) in new[] { (0.035f, 0.055f), (0.965f, 0.055f), (0.035f, 0.945f), (0.965f, 0.945f), (0.5f, 0.8f) })
            Screw(canvas, detail, new SKPoint(size.Width * x, size.Height * y), size.Width * 0.028f);
        canvas.Border(all, corner, detail.Opacity(0.7), size.Width * 0.004f);
    }

    private static void Screw(SKCanvas canvas, SKColor color, SKPoint center, float size)
    {
        var rect = Shapes.Square(center, size);
        using (var head = Shapes.Oval(rect)) canvas.Fill(head, Gradients.Radial(rect, Unit.TopLeading, 0, size, [color.Opacity(0.9), color.Opacity(0.5)]));
        var width = Math.Max(0.5f, size * 0.1f);
        canvas.Line(new SKPoint(rect.Left + size * 0.25f, center.Y), new SKPoint(rect.Left + size * 0.75f, center.Y), Black(0.5), width);
        canvas.Line(new SKPoint(center.X, rect.Top + size * 0.25f), new SKPoint(center.X, rect.Top + size * 0.75f), Black(0.5), width);
    }

    /// <summary>
    /// The label: its color and bands (or the user's picture), the brand and the tape's type, the side, the song written
    /// on it and the cover, around the window and the hubs' holes. Without its background over a shell picture that has
    /// its own label (only the song goes on it).
    /// </summary>
    private static void Label(SKCanvas canvas, CassetteDesign design, CassetteGeometry layout, SKSize size, SkinPlayback playback, CassettePictures pictures,
                              bool drawsBackground)
    {
        var label = Rect(layout.Label, size);
        var window = Rect(layout.Window, size);
        var hubHole = (float)layout.HubRadius * size.Width * 1.25f;
        SKPoint[] holes = [Point(layout.LeftReel, size), Point(layout.RightReel, size)];
        var text = design.Label.TextColor.Color;
        var ink = design.Label.Writing?.TextColor.Color ?? text;
        var labelPicture = pictures.Image(pictures.Label);
        var writing = SKRect.Create(label.Left, label.Top, label.Width, window.Top - label.Top);
        var strip = SKRect.Create(label.Left + label.Width * 0.035f, label.Top + size.Height * 0.07f, label.Width * 0.93f,
            Math.Max(window.Top - label.Top - size.Height * 0.095f, 0));
        if (drawsBackground)
        {
            using (var cutout = Cutout(label, label.Height * 0.04f, window, holes, hubHole))
            {
                canvas.Save();
                canvas.ClipPath(cutout, antialias: true);
                if (labelPicture is not null) canvas.ImageFill(labelPicture, label);
                else LabelBackground(canvas, design, label);
                canvas.Restore();
            }
            if (labelPicture is null && design.Label.Writing is { } paper)
            {
                using var shape = Shapes.Round(strip, size.Width * 0.006f);
                canvas.Fill(shape, paper.Background.Color);
                Textures.Fill(canvas, shape, SkinTexture.Paper, blend: SKBlendMode.Multiply);
                var y = strip.Bottom - strip.Height * 0.28f;
                canvas.Line(new SKPoint(strip.Left + strip.Width * 0.03f, y), new SKPoint(strip.Right - strip.Width * 0.03f, y), paper.TextColor.Color.Opacity(0.15), 0.7f);
            }
            if (labelPicture is null)
            {
                // Brand and type across the top, the side in the band left of the window.
                var finish = design.Label.TextFinish;
                using var brandFont = Fonts.System(size.Width * 0.026f, SKFontStyleWeight.Black);
                using var typeFont = Fonts.System(size.Width * 0.02f, SKFontStyleWeight.SemiBold);
                using var sideFont = Fonts.System(size.Width * 0.05f, SKFontStyleWeight.Black);
                var top = label.Top + size.Height * 0.035f;
                var left = label.Left + label.Width * 0.035f;
                var right = label.Right - label.Width * 0.035f;
                Materials.Print(canvas, SKRect.Create(label.Left, label.Top, label.Width, size.Height * 0.07f), finish, text.Opacity(0.85), color =>
                {
                    Lettering.Draw(canvas, design.Brand, left, Lettering.Baseline(brandFont, top), brandFont, color, SKTextAlign.Left, size.Width * 0.002f);
                    Lettering.Draw(canvas, design.TapeType, right, Lettering.Baseline(typeFont, top), typeFont, color, SKTextAlign.Right);
                }, lettering: true);
                var sideCenter = new SKPoint(label.Left + label.Width * 0.055f, window.Top + window.Height * 0.12f);
                Materials.Print(canvas, Shapes.Square(sideCenter, size.Width * 0.08f), finish, text.Opacity(0.85),
                    color => Lettering.Centered(canvas, design.Side, sideCenter, sideFont, color), lettering: true);
            }
        }
        // The song, written above the window (askew when by hand), and the cover beside it.
        var x = writing.Left + label.Width * 0.05f;
        var middle = writing.Top + size.Height * 0.05f + (writing.Height - size.Height * 0.05f) / 2;
        if (design.Label.ShowsArtwork)
        {
            var side = writing.Height * 0.58f;
            var cover = SKRect.Create(x, middle - side / 2, side, side);
            using var shape = Shapes.Round(cover, size.Width * 0.006f);
            canvas.Save();
            canvas.ClipPath(shape, antialias: true);
            Stages.Artwork(canvas, playback.Artwork, cover);
            canvas.Restore();
            x += side + size.Width * 0.02f;
        }
        if (!design.Label.ShowsText) return;
        var room = writing.Right - label.Width * 0.05f - x;
        using var titleFont = design.Label.Handwritten ? Fonts.Handwritten(size.Width * 0.042f) : Fonts.Rounded(size.Width * 0.042f);
        using var artistFont = design.Label.Handwritten ? Fonts.Handwritten(size.Width * 0.03f) : Fonts.Rounded(size.Width * 0.03f, SKFontStyleWeight.Normal);
        // Shrunk (to six tenths) before it is cut short, as the Mac's minimumScaleFactor.
        foreach (var font in new[] { titleFont, artistFont })
        {
            var widest = Math.Max(Lettering.Width(playback.Title, titleFont), Lettering.Width(playback.Artist, artistFont));
            if (widest > room) font.Size *= Math.Max(0.6f, room / widest);
        }
        var titleHeight = titleFont.Size * 1.2f;
        var artistHeight = artistFont.Size * 1.2f;
        var top0 = middle - (titleHeight + artistHeight) / 2;
        var printed = design.Label.Handwritten || design.Label.Writing is not null || labelPicture is not null ? null : design.Label.TextFinish;
        var color = labelPicture is null ? ink : text;
        canvas.Save();
        if (design.Label.Handwritten) canvas.RotateDegrees(-1.2f, x + room / 2, middle);
        var bounds = SKRect.Create(x, top0, room, titleHeight + artistHeight);
        Materials.Print(canvas, bounds, printed, color, paint =>
        {
            var title = Lettering.Fit(playback.Title, titleFont, room);
            Lettering.Draw(canvas, title, x, top0 - titleFont.Metrics.Ascent * 1.05f, titleFont, paint);
            var artist = Lettering.Fit(playback.Artist, artistFont, room);
            Lettering.Draw(canvas, artist, x, top0 + titleHeight - artistFont.Metrics.Ascent * 1.05f, artistFont, paint.Opacity(0.8));
        }, lettering: true);
        canvas.Restore();
    }

    /// <summary>The label's color (or foil) with its bands across the lower part, as on the classic tapes, and two lines to write on.</summary>
    private static void LabelBackground(SKCanvas canvas, CassetteDesign design, SKRect rect)
    {
        if (design.Label.BackgroundFinish is { } finish) canvas.Fill(rect, Materials.Foil(finish, rect));
        else
        {
            canvas.Fill(rect, design.Label.Background.Color);
            // Printed on paper: its fibres show where the label is not clear.
            if (design.Label.Background.Alpha > 0.5)
                Textures.Fill(canvas, rect, SkinTexture.Paper, opacity: design.Label.Background.Alpha, blend: SKBlendMode.Multiply);
        }
        var stripes = design.Label.Stripes;
        if (stripes.Count > 0)
        {
            var band = rect.Height * 0.3f / stripes.Count;
            for (var index = 0; index < stripes.Count; index++)
                canvas.Fill(SKRect.Create(rect.Left, rect.Top + rect.Height * 0.62f + band * index, rect.Width, band), stripes[index].Color);
        }
        foreach (var band in design.Label.Bands)
        {
            var bandRect = SKRect.Create(rect.Left, rect.Top + rect.Height * (float)band.Y, rect.Width, rect.Height * (float)band.Height);
            if (band.Finish is { } metal) canvas.Fill(bandRect, Materials.Foil(metal, bandRect));
            else canvas.Fill(bandRect, band.Color.Color);
        }
        for (var line = 0; line < 2; line++)
        {
            var y = rect.Top + rect.Height * (0.15f + 0.09f * line);
            canvas.Line(new SKPoint(rect.Left + rect.Width * 0.05f, y), new SKPoint(rect.Right - rect.Width * 0.05f, y), design.Label.TextColor.Color.Opacity(0.12), 0.7f);
        }
    }
}

/// <summary>
/// The template to draw a shell or a label on: the cassette's outline at 1000 x 635 pixels, the places of the reels, the
/// window and the label marked. A shell drawn on it needs no numbers in its design.
/// </summary>
public static class CassetteTemplate
{
    public const int PixelWidth = 1000;

    public static byte[] Png()
    {
        var layout = CassetteGeometry.Standard;
        var width = (float)PixelWidth;
        var height = (float)Math.Round(width / layout.AspectRatio);
        using var surface = SKSurface.Create(new SKImageInfo(PixelWidth, (int)height));
        var canvas = surface.Canvas;
        canvas.Clear(SKColors.Transparent);
        var size = new SKSize(width, height);
        var all = SKRect.Create(size);
        using (var shape = Shapes.Round(all, width * 0.035f))
        {
            canvas.Fill(shape, Gray(0.85));
            canvas.Stroke(shape, SKColors.Black, 2);
        }
        var guide = Rgb(0.1, 0.5, 0.95);
        using var dash = SKPathEffect.CreateDash([10, 6], 0);
        void Dashed(SKPath path, SKColor color)
        {
            var paint = Paint.Of(color);
            paint.Style = SKPaintStyle.Stroke;
            paint.StrokeWidth = 2;
            paint.PathEffect = dash;
            canvas.DrawPath(path, paint);
            paint.PathEffect = null;
        }
        var label = SKRect.Create((float)layout.Label.X * width, (float)layout.Label.Y * height, (float)layout.Label.Width * width, (float)layout.Label.Height * height);
        using (var shape = Shapes.Rect(label)) Dashed(shape, guide);
        using (var font = Fonts.System(22, SKFontStyleWeight.Bold)) Lettering.Draw(canvas, "LABEL", label.Left + 12, label.Top + 10 - font.Metrics.Ascent, font, guide);
        var window = SKRect.Create((float)layout.Window.X * width, (float)layout.Window.Y * height, (float)layout.Window.Width * width, (float)layout.Window.Height * height);
        using (var shape = Shapes.Round(window, window.Height * 0.18f)) canvas.Stroke(shape, SKColors.Red, 2);
        foreach (var reel in new[] { layout.LeftReel, layout.RightReel })
        {
            var center = new SKPoint((float)reel.X * width, (float)reel.Y * height);
            using (var full = Shapes.Circle(center, (float)layout.ReelRadius * width)) Dashed(full, SKColors.Red);
            using var hole = Shapes.Circle(center, (float)layout.HubRadius * width * 1.25f);
            canvas.Stroke(hole, SKColors.Red, 2);
        }
        using (var font = Fonts.System(16))
            Lettering.Draw(canvas, Lettering.Fit("Red: transparent in a shell picture (the window and the hubs' holes). Dashed red: the full reels. Blue: the label.", font, width * 0.9f),
                width / 2, height * 0.88f, font, Black(0.7), SKTextAlign.Center);
        using var image = surface.Snapshot();
        using var data = image.Encode(SKEncodedImageFormat.Png, 100);
        return data.ToArray();
    }
}
