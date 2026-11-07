using System.Globalization;
using System.Reflection;
using System.Text;
using SkiaSharp;

namespace Groovelight.Skins;

/// <summary>A point within a rectangle, as fractions of its width and height (SwiftUI's UnitPoint).</summary>
internal readonly record struct Unit(float X, float Y)
{
    public static readonly Unit Top = new(0.5f, 0), Bottom = new(0.5f, 1), Leading = new(0, 0.5f), Trailing = new(1, 0.5f), Center = new(0.5f, 0.5f);
    public static readonly Unit TopLeading = new(0, 0), BottomTrailing = new(1, 1), TopTrailing = new(1, 0), BottomLeading = new(0, 1);

    public SKPoint In(SKRect rect) => new(rect.Left + rect.Width * X, rect.Top + rect.Height * Y);
}

/// <summary>Colors as the Mac's drawing gives them (components 0 to 1).</summary>
internal static class Colors
{
    public static SKColor Rgb(double red, double green, double blue, double alpha = 1) =>
        new(B(red), B(green), B(blue), B(alpha));

    public static SKColor Gray(double white, double alpha = 1) => Rgb(white, white, white, alpha);
    public static SKColor White(double alpha = 1) => Rgb(1, 1, 1, alpha);
    public static SKColor Black(double alpha = 1) => Rgb(0, 0, 0, alpha);
    public static readonly SKColor Clear = SKColors.Transparent;

    public static SKColor Hex(uint hex, double alpha = 1) => new((byte)(hex >> 16 & 0xFF), (byte)(hex >> 8 & 0xFF), (byte)(hex & 0xFF), B(alpha));

    public static SKColor Opacity(this SKColor color, double opacity) => color.WithAlpha(B(color.Alpha / 255.0 * opacity));

    public static SKColor Mix(this SKColor a, SKColor b, double amount)
    {
        var t = Math.Clamp(amount, 0, 1);
        return new SKColor((byte)Math.Round(a.Red + (b.Red - a.Red) * t), (byte)Math.Round(a.Green + (b.Green - a.Green) * t),
            (byte)Math.Round(a.Blue + (b.Blue - a.Blue) * t), (byte)Math.Round(a.Alpha + (b.Alpha - a.Alpha) * t));
    }

    private static byte B(double value) => (byte)Math.Round(Math.Clamp(value, 0, 1) * 255);
}

/// <summary>Shapes as paths (the builder is the only way to make one that is not obsolete).</summary>
internal static class Shapes
{
    public static SKPath Build(Action<SKPathBuilder> build, SKPathFillType fill = SKPathFillType.Winding)
    {
        using var builder = new SKPathBuilder();
        builder.FillType = fill;
        build(builder);
        return builder.Detach();
    }

    public static SKPath Rect(SKRect rect) => Build(b => b.AddRect(rect));
    public static SKPath Oval(SKRect rect) => Build(b => b.AddOval(rect));
    public static SKPath Circle(SKPoint center, float radius) => Oval(SKRect.Create(center.X - radius, center.Y - radius, radius * 2, radius * 2));
    public static SKPath Round(SKRect rect, float radius) => Build(b => b.AddRoundRect(new SKRoundRect(rect, Math.Max(radius, 0))));
    public static SKPath Capsule(SKRect rect) => Round(rect, Math.Min(rect.Width, rect.Height) / 2);

    public static SKRect Square(SKPoint center, float side) => SKRect.Create(center.X - side / 2, center.Y - side / 2, side, side);
    public static SKRect CenteredRect(SKPoint center, float width, float height) => SKRect.Create(center.X - width / 2, center.Y - height / 2, width, height);

    public static SKPoint Polar(SKPoint center, double radians, double radius) =>
        new((float)(center.X + Math.Cos(radians) * radius), (float)(center.Y + Math.Sin(radians) * radius));
}

/// <summary>Gradients across a rectangle, as SwiftUI's.</summary>
internal static class Gradients
{
    public static (SKColor[] Colors, float[]? Stops) Even(params SKColor[] colors) => (colors, null);

    public static SKShader Linear(SKRect rect, Unit start, Unit end, SKColor[] colors, float[]? stops = null) =>
        SKShader.CreateLinearGradient(start.In(rect), end.In(rect), colors, stops, SKShaderTileMode.Clamp);

    public static SKShader Linear(SKRect rect, Unit start, Unit end, params (float At, SKColor Color)[] stops) =>
        Linear(rect, start, end, stops.Select(stop => stop.Color).ToArray(), stops.Select(stop => stop.At).ToArray());

    public static SKShader Vertical(SKRect rect, params SKColor[] colors) => Linear(rect, Unit.Top, Unit.Bottom, colors);
    public static SKShader Horizontal(SKRect rect, params SKColor[] colors) => Linear(rect, Unit.Leading, Unit.Trailing, colors);

    /// <summary>A radial gradient from <paramref name="startRadius"/> to <paramref name="endRadius"/> around a point of the rectangle.</summary>
    public static SKShader Radial(SKRect rect, Unit center, float startRadius, float endRadius, SKColor[] colors, float[]? stops = null)
    {
        var end = Math.Max(endRadius, 0.01f);
        var from = startRadius / end;
        var positions = (stops ?? Enumerable.Range(0, colors.Length).Select(index => colors.Length == 1 ? 0f : index / (float)(colors.Length - 1)).ToArray())
            .Select(stop => from + (1 - from) * stop).ToArray();
        return SKShader.CreateRadialGradient(center.In(rect), end, colors, positions, SKShaderTileMode.Clamp);
    }

    /// <summary>An ellipse's gradient (SwiftUI's EllipticalGradient): the radii fractions of the rectangle's half sides.</summary>
    public static SKShader Elliptical(SKRect rect, Unit center, float startFraction, float endFraction, SKColor[] colors)
    {
        var point = center.In(rect);
        var matrix = SKMatrix.CreateScale(rect.Width / 2, rect.Height / 2, point.X, point.Y);
        var positions = Enumerable.Range(0, colors.Length).Select(index => startFraction + (endFraction - startFraction) * index / (float)Math.Max(colors.Length - 1, 1)).ToArray();
        return SKShader.CreateRadialGradient(point, 1, colors, positions.Select(position => position).ToArray(), SKShaderTileMode.Clamp, matrix);
    }

    /// <summary>An angular gradient around a point (SwiftUI's AngularGradient: clockwise from the right, turned by <paramref name="degrees"/>).</summary>
    public static SKShader Sweep(SKPoint center, SKColor[] colors, float[]? stops = null, float degrees = 0) =>
        SKShader.CreateSweepGradient(center, colors, stops, SKMatrix.CreateRotationDegrees(degrees, center.X, center.Y));
}

/// <summary>Painting shapes with the Mac's looks: fills, borders inside the edge, soft shadows and inner shadows.</summary>
internal static class Paint
{
    [ThreadStatic] private static SKPaint? shared;

    /// <summary>A paint to use at once (shared: not kept between calls).</summary>
    public static SKPaint Of(SKColor color, SKShader? shader = null, SKBlendMode blend = SKBlendMode.SrcOver)
    {
        var paint = shared ??= new SKPaint { IsAntialias = true };
        paint.Reset();
        paint.IsAntialias = true;
        paint.Color = color;
        paint.Shader = shader;
        paint.BlendMode = blend;
        return paint;
    }

    public static void Fill(this SKCanvas canvas, SKPath path, SKColor color, SKBlendMode blend = SKBlendMode.SrcOver) =>
        canvas.DrawPath(path, Of(color, null, blend));

    public static void Fill(this SKCanvas canvas, SKPath path, SKShader shader, double opacity = 1, SKBlendMode blend = SKBlendMode.SrcOver)
    {
        using (shader) canvas.DrawPath(path, Of(SKColors.Black.Opacity(opacity), shader, blend));
    }

    public static void Fill(this SKCanvas canvas, SKRect rect, SKColor color) => canvas.DrawRect(rect, Of(color));

    public static void Fill(this SKCanvas canvas, SKRect rect, SKShader shader, double opacity = 1, SKBlendMode blend = SKBlendMode.SrcOver)
    {
        using (shader) canvas.DrawRect(rect, Of(SKColors.Black.Opacity(opacity), shader, blend));
    }

    public static void Stroke(this SKCanvas canvas, SKPath path, SKColor color, float width, SKStrokeCap cap = SKStrokeCap.Butt)
    {
        var paint = Of(color);
        paint.Style = SKPaintStyle.Stroke;
        paint.StrokeWidth = width;
        paint.StrokeCap = cap;
        canvas.DrawPath(path, paint);
    }

    public static void Stroke(this SKCanvas canvas, SKPath path, SKShader shader, float width)
    {
        using (shader)
        {
            var paint = Of(SKColors.Black, shader);
            paint.Style = SKPaintStyle.Stroke;
            paint.StrokeWidth = width;
            canvas.DrawPath(path, paint);
        }
    }

    public static void Line(this SKCanvas canvas, SKPoint from, SKPoint to, SKColor color, float width, SKStrokeCap cap = SKStrokeCap.Butt)
    {
        var paint = Of(color);
        paint.Style = SKPaintStyle.Stroke;
        paint.StrokeWidth = width;
        paint.StrokeCap = cap;
        canvas.DrawLine(from, to, paint);
    }

    /// <summary>A border inside a rounded rectangle's edge (SwiftUI's strokeBorder).</summary>
    public static void Border(this SKCanvas canvas, SKRect rect, float radius, SKColor color, float width)
    {
        var inset = SKRect.Inflate(rect, -width / 2, -width / 2);
        using var path = Shapes.Round(inset, Math.Max(radius - width / 2, 0));
        canvas.Stroke(path, color, width);
    }

    public static void Border(this SKCanvas canvas, SKRect rect, float radius, Func<SKRect, SKShader> shader, float width)
    {
        var inset = SKRect.Inflate(rect, -width / 2, -width / 2);
        using var path = Shapes.Round(inset, Math.Max(radius - width / 2, 0));
        canvas.Stroke(path, shader(rect), width);
    }

    public static void CircleBorder(this SKCanvas canvas, SKRect rect, SKColor color, float width) =>
        canvas.Border(rect, Math.Min(rect.Width, rect.Height) / 2, color, width);

    public static void CircleBorder(this SKCanvas canvas, SKRect rect, Func<SKRect, SKShader> shader, float width) =>
        canvas.Border(rect, Math.Min(rect.Width, rect.Height) / 2, shader, width);

    /// <summary>A soft shadow of the shape (SwiftUI's shadow: <paramref name="radius"/> is its blur).</summary>
    public static void Shadow(this SKCanvas canvas, SKPath path, SKColor color, float radius, float dx = 0, float dy = 0)
    {
        if (color.Alpha == 0) return;
        using var blur = radius > 0.1f ? SKMaskFilter.CreateBlur(SKBlurStyle.Normal, radius / 2) : null;
        var paint = Of(color);
        paint.MaskFilter = blur;
        canvas.Save();
        canvas.Translate(dx, dy);
        canvas.DrawPath(path, paint);
        canvas.Restore();
        paint.MaskFilter = null;
    }

    /// <summary>A shadow inside the shape's edge (a hollow, a well), falling from the top.</summary>
    public static void InnerShadow(this SKCanvas canvas, SKPath path, SKColor color, float radius, float dy = 0)
    {
        canvas.Save();
        canvas.ClipPath(path, antialias: true);
        var bounds = path.Bounds;
        bounds.Inflate(radius * 3 + Math.Abs(dy), radius * 3 + Math.Abs(dy));
        using var ring = Shapes.Build(b =>
        {
            b.AddRect(bounds);
            b.AddPath(path, dx: 0, dy: dy);
        }, SKPathFillType.EvenOdd);
        canvas.Shadow(ring, color, radius);
        canvas.Restore();
    }

    /// <summary>Draws <paramref name="draw"/> in a layer at <paramref name="opacity"/> (or with a blend mode).</summary>
    public static void Layer(this SKCanvas canvas, double opacity, Action draw, SKBlendMode blend = SKBlendMode.SrcOver)
    {
        using var paint = new SKPaint { Color = SKColors.Black.Opacity(opacity), BlendMode = blend };
        canvas.SaveLayer(paint);
        draw();
        canvas.Restore();
    }

    /// <summary>Draws <paramref name="draw"/> masked by <paramref name="mask"/> (drawn second, keeping only where it is).</summary>
    public static void Masked(this SKCanvas canvas, Action draw, Action mask)
    {
        canvas.SaveLayer();
        draw();
        using var paint = new SKPaint { BlendMode = SKBlendMode.DstIn };
        canvas.SaveLayer(paint);
        mask();
        canvas.Restore();
        canvas.Restore();
    }

    /// <summary>Draws what <paramref name="draw"/> draws with a soft shadow under it all (SwiftUI's shadow of a group).</summary>
    public static void WithShadow(this SKCanvas canvas, SKColor color, float radius, float dx, float dy, SKRect bounds, Action draw)
    {
        using var filter = SKImageFilter.CreateDropShadow(dx, dy, radius / 2, radius / 2, color);
        using var paint = new SKPaint { ImageFilter = filter };
        // Only the drawing's own box (and its shadow's), not the whole canvas: much faster.
        var room = radius * 1.5f + Math.Max(Math.Abs(dx), Math.Abs(dy));
        canvas.SaveLayer(SKRect.Inflate(bounds, room, room), paint);
        draw();
        canvas.Restore();
    }

    public static void Image(this SKCanvas canvas, SKImage image, SKRect rect, double opacity = 1)
    {
        var paint = Of(SKColors.Black.Opacity(opacity));
        canvas.DrawImage(image, rect, new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear), paint);
    }

    /// <summary>An image filling the rectangle (cropped to keep its shape), as SwiftUI's scaledToFill.</summary>
    public static void ImageFill(this SKCanvas canvas, SKImage image, SKRect rect, double opacity = 1)
    {
        var scale = Math.Max(rect.Width / image.Width, rect.Height / image.Height);
        var width = image.Width * scale;
        var height = image.Height * scale;
        canvas.Save();
        canvas.ClipRect(rect);
        canvas.Image(image, SKRect.Create(rect.MidX - width / 2, rect.MidY - height / 2, width, height), opacity);
        canvas.Restore();
    }
}

internal enum SkinTexture { Walnut, Aluminum, Felt, BlackPlastic, Vinyl, Grain, Foil, Paper, Hill }

/// <summary>
/// The photographed surfaces the players are made of (ambientCG, CC0; see Skins\CREDITS.md), tiled at half their pixel
/// size as on a Retina Mac.
/// </summary>
internal static class Textures
{
    private static readonly Dictionary<SkinTexture, SKImage> images = [];
    private static readonly Lock gate = new();

    public static SKImage Image(SkinTexture texture)
    {
        lock (gate)
        {
            if (images.TryGetValue(texture, out var image)) return image;
            using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream($"{texture}.jpg");
            image = (stream is null ? null : SKImage.FromEncodedData(stream)) ?? Blank();
            images[texture] = image;
            return image;
        }
    }

    private static SKImage Blank()
    {
        using var bitmap = new SKBitmap(1, 1);
        bitmap.Erase(Colors.Gray(0.5));
        return SKImage.FromBitmap(bitmap);
    }

    /// <summary>The texture tiled from <paramref name="origin"/>, made lighter or darker and colored (multiplied).</summary>
    public static SKShader Shader(SkinTexture texture, double brightness = 0, SKColor? tint = null, SKPoint origin = default, float scale = 0.5f)
    {
        var shader = Image(texture).ToShader(SKShaderTileMode.Repeat, SKShaderTileMode.Repeat, new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear),
            SKMatrix.CreateScale(scale, scale).PostConcat(SKMatrix.CreateTranslation(origin.X, origin.Y)));
        var color = tint ?? SKColors.White;
        if (brightness == 0 && color == SKColors.White) return shader;
        var b = (float)brightness;
        using var filter = SKColorFilter.CreateColorMatrix([
            color.Red / 255f, 0, 0, 0, b,
            0, color.Green / 255f, 0, 0, b,
            0, 0, color.Blue / 255f, 0, b,
            0, 0, 0, 1, 0,
        ]);
        return shader.WithColorFilter(filter);
    }

    /// <summary>A surface of the texture filling the path.</summary>
    public static void Fill(SKCanvas canvas, SKPath path, SkinTexture texture, double brightness = 0, SKColor? tint = null, double opacity = 1,
                            SKBlendMode blend = SKBlendMode.SrcOver) =>
        canvas.Fill(path, Shader(texture, brightness, tint, path.Bounds.Location), opacity, blend);

    public static void Fill(SKCanvas canvas, SKRect rect, SkinTexture texture, double brightness = 0, SKColor? tint = null, double opacity = 1,
                            SKBlendMode blend = SKBlendMode.SrcOver) =>
        canvas.Fill(rect, Shader(texture, brightness, tint, rect.Location), opacity, blend);

    /// <summary>The texture stretched over the rectangle (the record's grooves, the wallpaper).</summary>
    public static void Stretch(SKCanvas canvas, SkinTexture texture, SKRect rect, double opacity = 1) => canvas.Image(Image(texture), rect, opacity);
}

internal enum FontWidth { Standard, Condensed, Expanded }

/// <summary>The players' lettering: the segment displays' fonts (DSEG, OFL), the pixel font (Silkscreen, OFL), and the system's.</summary>
internal static class Fonts
{
    private static readonly Dictionary<string, SKTypeface> faces = [];
    private static readonly Lock gate = new();

    private static SKTypeface Embedded(string name)
    {
        lock (gate)
        {
            if (faces.TryGetValue(name, out var face)) return face;
            using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name + ".ttf");
            face = (stream is null ? null : SKTypeface.FromStream(stream)) ?? SKTypeface.Default;
            faces[name] = face;
            return face;
        }
    }

    private static SKTypeface System(string family, SKFontStyleWeight weight, SKFontStyleSlant slant = SKFontStyleSlant.Upright)
    {
        var key = $"{family}/{weight}/{slant}";
        lock (gate)
        {
            if (faces.TryGetValue(key, out var face)) return face;
            face = SKTypeface.FromFamilyName(family, new SKFontStyle(weight, SKFontStyleWidth.Normal, slant)) ?? SKTypeface.Default;
            faces[key] = face;
            return face;
        }
    }

    private static SKFont Make(SKTypeface face, float size, float scaleX = 1) =>
        new(face, Math.Max(size, 0.5f)) { Edging = SKFontEdging.Antialias, Subpixel = true, ScaleX = scaleX };

    /// <summary>Seven segments: digits and the colon.</summary>
    public static SKFont Digits(float size) => Make(Embedded("DSEG7Classic-Bold"), size);
    /// <summary>Fourteen segments: capitals, digits and some punctuation.</summary>
    public static SKFont Letters(float size) => Make(Embedded("DSEG14Classic-Bold"), size);
    /// <summary>A computer's pixel lettering: the PC Player's title, display and keys.</summary>
    public static SKFont Pixel(float size, bool bold = false) => Make(Embedded(bold ? "Silkscreen-Bold" : "Silkscreen-Regular"), size);

    /// <summary>The system's font (Segoe UI), wider for the hi-fi captions or narrower for the meters' numbers.</summary>
    public static SKFont System(float size, SKFontStyleWeight weight = SKFontStyleWeight.Normal, FontWidth width = FontWidth.Standard) =>
        Make(System("Segoe UI", weight), size, width switch { FontWidth.Expanded => 1.18f, FontWidth.Condensed => 0.86f, _ => 1 });

    public static SKFont Serif(float size, SKFontStyleWeight weight = SKFontStyleWeight.SemiBold) => Make(System("Georgia", weight), size);
    public static SKFont Mono(float size, SKFontStyleWeight weight = SKFontStyleWeight.SemiBold) => Make(System("Consolas", weight), size);
    public static SKFont Rounded(float size, SKFontStyleWeight weight = SKFontStyleWeight.SemiBold) => Make(System("Segoe UI", weight), size);
    /// <summary>Handwriting on a label (the Mac's Marker Felt): Ink Free, which comes with Windows.</summary>
    public static SKFont Handwritten(float size) => Make(System("Ink Free", SKFontStyleWeight.Bold), size);

    /// <summary>The captions on the panels, wide as on the hi-fi of the seventies.</summary>
    public static SKFont Caption(float size, SKFontStyleWeight weight = SKFontStyleWeight.Bold) => System(size, weight, FontWidth.Expanded);

    /// <summary>Text the 14-segment font can show: capitals without accents, the rest as spaces.</summary>
    public static string SegmentText(string text)
    {
        const string allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -.,'!?/()&+:";
        var folded = new string(text.Normalize(NormalizationForm.FormD).Where(c => CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark).ToArray());
        return new string(folded.ToUpperInvariant().Select(c => allowed.Contains(c) ? c : ' ').ToArray());
    }
}

/// <summary>Lettering: measured and drawn with letter spacing (tracking), aligned, cut short with an ellipsis.</summary>
internal static class Lettering
{
    public static float Width(string text, SKFont font, float tracking = 0) =>
        text.Length == 0 ? 0 : font.MeasureText(text) + tracking * Math.Max(text.Length - 1, 0);

    /// <summary>Cut to fit <paramref name="width"/>, ending in an ellipsis.</summary>
    public static string Fit(string text, SKFont font, float width, float tracking = 0)
    {
        if (Width(text, font, tracking) <= width) return text;
        var low = 0;
        var high = text.Length;
        while (low < high)
        {
            var middle = (low + high + 1) / 2;
            if (Width(text[..middle].TrimEnd() + "…", font, tracking) <= width) low = middle;
            else high = middle - 1;
        }
        return low == 0 ? "" : text[..low].TrimEnd() + "…";
    }

    /// <summary>Draws text with its baseline at <paramref name="y"/>, starting, centered or ending at <paramref name="x"/>.</summary>
    public static void Draw(SKCanvas canvas, string text, float x, float y, SKFont font, SKPaint paint, SKTextAlign align = SKTextAlign.Left, float tracking = 0)
    {
        if (text.Length == 0) return;
        if (tracking == 0)
        {
            canvas.DrawText(text, x, y, align, font, paint);
            return;
        }
        var width = Width(text, font, tracking);
        var left = align switch { SKTextAlign.Center => x - width / 2, SKTextAlign.Right => x - width, _ => x };
        var enumerator = StringInfo.GetTextElementEnumerator(text);
        while (enumerator.MoveNext())
        {
            var element = enumerator.GetTextElement();
            canvas.DrawText(element, left, y, SKTextAlign.Left, font, paint);
            left += font.MeasureText(element) + tracking;
        }
    }

    public static void Draw(SKCanvas canvas, string text, float x, float y, SKFont font, SKColor color, SKTextAlign align = SKTextAlign.Left, float tracking = 0) =>
        Draw(canvas, text, x, y, font, Paint.Of(color), align, tracking);

    /// <summary>The baseline putting the font's capitals in the middle of <paramref name="centerY"/>.</summary>
    public static float Baseline(SKFont font, float centerY)
    {
        var metrics = font.Metrics;
        var cap = metrics.CapHeight > 0 ? metrics.CapHeight : -metrics.Ascent * 0.7f;
        return centerY + cap / 2;
    }

    /// <summary>Text centered on a point (its capitals' middle there).</summary>
    public static void Centered(SKCanvas canvas, string text, SKPoint center, SKFont font, SKColor color, float tracking = 0) =>
        Draw(canvas, text, center.X, Baseline(font, center.Y), font, color, SKTextAlign.Center, tracking);

    /// <summary>Text glowing in its color (a display's lit segments, a dial's lettering).</summary>
    public static void Glowing(SKCanvas canvas, string text, float x, float y, SKFont font, SKColor color, SKColor glow, float radius, SKTextAlign align = SKTextAlign.Left,
                               float tracking = 0)
    {
        if (radius > 0.1f)
        {
            using var blur = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, radius / 2);
            var paint = Paint.Of(glow);
            paint.MaskFilter = blur;
            Draw(canvas, text, x, y, font, paint, align, tracking);
            paint.MaskFilter = null;
        }
        Draw(canvas, text, x, y, font, color, align, tracking);
    }

    /// <summary>A caption cut into metal (dark, lit from below) or printed on a dark panel (light).</summary>
    public static void Engraved(SKCanvas canvas, string text, SKPoint center, float size, bool onDark = false)
    {
        using var font = Fonts.Caption(size);
        var baseline = Baseline(font, center.Y);
        Draw(canvas, text, center.X, baseline + (onDark ? -0.6f : 0.8f), font, onDark ? Colors.Black(0.7) : Colors.White(0.55), SKTextAlign.Center, size * 0.14f);
        Draw(canvas, text, center.X, baseline, font, onDark ? Colors.White(0.78) : Colors.Black(0.62), SKTextAlign.Center, size * 0.14f);
    }

    public static float EngravedWidth(string text, float size)
    {
        using var font = Fonts.Caption(size);
        return Width(text, font, size * 0.14f);
    }
}
