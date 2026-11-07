using SkiaSharp;
using static Groovelight.Skins.Colors;

namespace Groovelight.Skins;

/// <summary>A flag kept between frames.</summary>
internal sealed class Flag(bool value)
{
    public bool Value = value;
}

/// <summary>A number kept between frames.</summary>
internal sealed class Number(double value)
{
    public double Value = value;
}

/// <summary>The classic base skin's colors, as its bitmaps have them.</summary>
internal static class PcColors
{
    public static readonly SKColor Digits = Hex(0x00F800), Text = Hex(0x00E200), ListText = Hex(0x00FF00), Dots = Hex(0x182129);
    public static readonly SKColor KeyFace = Hex(0xBDCED6), KeyLight = Hex(0xEFFFFF), KeyEdge = Hex(0xADB5C6), KeyShade = Hex(0x7B8494), KeyDark = Hex(0x4A5A6B);
    public static readonly SKColor Glyph = Hex(0x97A8B9), Ink = Hex(0x2F374D), FrameLight = Hex(0x73738A), FrameDark = Hex(0x0F0F17);
    public static readonly SKColor GoldLight = Hex(0xECCE7A), GoldDim = Hex(0xA3946A), GoldDark = Hex(0x45413C);
    /// <summary>The spectrum's colors, from the top of a bar to its foot, and its peaks.</summary>
    public static readonly SKColor[] Spectrum = new uint[]
    {
        0xEF3110, 0xCE2910, 0xD65A00, 0xD66600, 0xD67300, 0xC67B08, 0xDEA518, 0xD6B521, 0xBDDE29, 0x94DE21, 0x29CE10, 0x32BE10, 0x39B510, 0x319C08, 0x299400, 0x188408,
    }.Select(hex => Hex(hex)).ToArray();
    public static readonly SKColor Peak = Hex(0x969696);
}

/// <summary>The transport keys' glyphs, as on the base skin.</summary>
internal enum PcGlyph { Previous, Play, Pause, Stop, Next, Eject }

/// <summary>Drawing on the original's pixel grid (the canvas scaled to it).</summary>
internal static class Pixels
{
    public static void Px(this SKCanvas canvas, float x, float y, float w, float h, SKColor color)
    {
        if (w <= 0 || h <= 0) return;
        var paint = Paint.Of(color);
        paint.IsAntialias = false;
        canvas.DrawRect(SKRect.Create(x, y, w, h), paint);
    }

    /// <summary>An engraved line around a rectangle: shaded above and on the left, lit below and on the right.</summary>
    public static void Groove(this SKCanvas canvas, float x, float y, float w, float h, SKColor? dark = null, SKColor? light = null)
    {
        var shade = dark ?? Hex(0x101019);
        var lit = light ?? PcColors.FrameLight;
        canvas.Px(x, y, w, 1, shade);
        canvas.Px(x, y, 1, h, shade);
        canvas.Px(x, y + h - 1, w, 1, lit);
        canvas.Px(x + w - 1, y, 1, h, lit);
    }

    public static SKPath Glyph(PcGlyph kind, SKRect rect)
    {
        var w = rect.Width;
        var h = rect.Height;
        return Shapes.Build(b =>
        {
            void Triangle(float x, bool right, float width)
            {
                b.MoveTo(rect.Left + x + (right ? 0 : width), rect.Top);
                b.LineTo(rect.Left + x + (right ? width : 0), rect.MidY);
                b.LineTo(rect.Left + x + (right ? 0 : width), rect.Bottom);
                b.Close();
            }
            switch (kind)
            {
                case PcGlyph.Previous:
                    b.AddRect(SKRect.Create(rect.Left, rect.Top, w * 0.25f, h));
                    Triangle(w * 0.35f, false, w * 0.65f);
                    break;
                case PcGlyph.Play:
                    Triangle(w * 0.15f, true, w * 0.75f);
                    break;
                case PcGlyph.Pause:
                    b.AddRect(SKRect.Create(rect.Left + w * 0.1f, rect.Top, w * 0.3f, h));
                    b.AddRect(SKRect.Create(rect.Left + w * 0.6f, rect.Top, w * 0.3f, h));
                    break;
                case PcGlyph.Stop:
                    b.AddRect(SKRect.Create(rect.Left + w * 0.05f, rect.Top, w * 0.9f, h));
                    break;
                case PcGlyph.Next:
                    Triangle(0, true, w * 0.65f);
                    b.AddRect(SKRect.Create(rect.Left + w * 0.75f, rect.Top, w * 0.25f, h));
                    break;
                case PcGlyph.Eject:
                    b.MoveTo(rect.MidX, rect.Top);
                    b.LineTo(rect.Right, rect.Top + h * 0.58f);
                    b.LineTo(rect.Left, rect.Top + h * 0.58f);
                    b.Close();
                    b.AddRect(SKRect.Create(rect.Left, rect.Top + h * 0.75f, w, h * 0.25f));
                    break;
            }
        });
    }
}

/// <summary>The spectrum's bars falling at their pace and their peaks held a moment, then falling.</summary>
internal sealed class SpectrumState
{
    public const int Bars = 19;
    private readonly double[] levels = new double[Bars], peaks = new double[Bars], held = new double[Bars];
    private double? last;

    public bool IsQuiet => levels.All(level => level < 0.01) && peaks.All(peak => peak < 0.01);

    public (double[] Levels, double[] Peaks) Update(double[] target, double now)
    {
        var elapsed = Math.Clamp(now - (last ?? now), 0, 0.25);
        last = now;
        for (var index = 0; index < Bars; index++)
        {
            var goal = index < target.Length ? target[index] : 0;
            // Up at once, down at two heights a second.
            levels[index] = goal > levels[index] ? goal : Math.Max(goal, levels[index] - elapsed * 2);
            if (levels[index] >= peaks[index])
            {
                peaks[index] = levels[index];
                held[index] = 0.4;
            }
            else if (held[index] > 0) held[index] -= elapsed;
            else peaks[index] = Math.Max(levels[index], peaks[index] - elapsed * 0.8);
        }
        return (levels, peaks);
    }

    /// <summary>Each bar's level: the analyzer's bands gathered into nineteen, or (not heard here) a made-up dance.</summary>
    public static double[] Target(SkinPlayback playback)
    {
        if (!playback.IsPlaying) return new double[Bars];
        if (playback.Spectrum?.Invoke() is { Length: > 0 } bands)
        {
            return Enumerable.Range(0, Bars).Select(index =>
            {
                var from = index * bands.Length / Bars;
                var to = Math.Max((index + 1) * bands.Length / Bars, from + 1);
                var peak = 0f;
                for (var band = from; band < Math.Min(to, bands.Length); band++) peak = Math.Max(peak, bands[band]);
                return Math.Min(peak * 2.2, 1);
            }).ToArray();
        }
        var time = playback.Time();
        return Enumerable.Range(0, Bars).Select(index =>
        {
            var tilt = 1 - index / (double)Bars * 0.55;
            var swing = 0.5 + 0.25 * Math.Sin(time * (3.1 + index * 0.37) + index) + 0.2 * Math.Sin(time * (7.3 + index * 0.21) + index * 2.1);
            var beat = Math.Pow(Math.Max(Math.Sin(time * 2 * Math.PI * 2.05), 0), 8) * 0.3 * tilt;
            return Math.Clamp(swing * tilt + beat, 0.02, 1);
        }).ToArray();
    }
}

/// <summary>
/// Now Playing as a desktop music player of the late 1990s, after the classic two-window skin (the Mac's PCPlayer): the
/// main window (the title bar, the green display with the time and a spectrum, the scrolling title, the bit rate and
/// sample rate, mono and stereo, the volume and balance sliders, EQ and PL, the position bar and the transport keys)
/// docked over the playlist window. Each is drawn on the original's pixel grid (the main window 275 by 116) and scaled
/// up to the window, so every part sits where it does in the original.
/// </summary>
internal static class PcPlayer
{
    public static readonly SKSize MainSize = new(275, 116);
    private const float AccessoryHeight = 12;

    /// <summary>Draws the windows; returns where the lyrics or Up Next go (the playlist's list) when shown.</summary>
    public static SKRect? Draw(DeckUi ui, SKSize size, float top, SkinPlayback playback, DeckControls controls, SkinPlaylist? playlist, bool showsOverlay)
    {
        var canvas = ui.Canvas;
        var margin = Math.Max(8, Math.Min(size.Width, size.Height) * 0.02f);
        var area = SKRect.Create(margin, top, Math.Max(size.Width - margin * 2, 1), Math.Max(size.Height - top - margin, 1));
        var aspect = MainSize.Width / MainSize.Height;
        // Docked, the playlist under the main window: as wide as the window while the playlist keeps half the height.
        var width = Math.Min(Math.Min(area.Width, (area.Height - AccessoryHeight) * 0.45f * aspect), MainSize.Width * 3);
        var scale = width / MainSize.Width;
        var main = SKRect.Create(area.MidX - width / 2, area.Top, width, width / aspect);
        var list = SKRect.Create(main.Left, main.Bottom, width, Math.Max(area.Bottom - main.Bottom - AccessoryHeight, 60));
        var showsPlaylist = ui.State("pc.showsPlaylist", () => new Flag(true));
        {
            using (var shadow = Shapes.Rect(main)) canvas.Shadow(shadow, Black(0.45), 18, 0, 8);
            canvas.Save();
            canvas.Translate(main.Left, main.Top);
            canvas.Scale(scale);
            MainWindow(ui, playback, controls, showsPlaylist);
            canvas.Restore();
        }
        if (!showsPlaylist.Value) return null;
        SKRect? overlay = null;
        {
            using (var shadow = Shapes.Rect(list)) canvas.Shadow(shadow, Black(0.45), 18, 0, 8);
            canvas.Save();
            canvas.Translate(list.Left, list.Top);
            canvas.Scale(scale);
            var inner = PlaylistWindow(ui, (float)Math.Floor(list.Width / scale), (float)Math.Floor(list.Height / scale), playback, controls, playlist, showsOverlay);
            canvas.Restore();
            if (showsOverlay) overlay = SKRect.Create(list.Left + (inner.Left + 8) * scale, list.Top + (inner.Top + 8) * scale, (inner.Width - 16) * scale, (inner.Height - 16) * scale);
        }
        return overlay;
    }

    /// <summary>A window's face as the base skin paints it: nearly black at its left edge, a slate violet right of the middle, a darker band low across it.</summary>
    internal static void WindowFace(SKCanvas canvas, SKRect rect, (float From, float To)? band = null)
    {
        uint[] stops = [0x0D0D14, 0x1A1927, 0x202033, 0x27283E, 0x2E2D48, 0x343351, 0x383758, 0x39395A, 0x383757, 0x343351, 0x2E2D47, 0x26263B];
        canvas.Fill(rect, Gradients.Horizontal(rect, stops.Select(hex => Hex(hex)).ToArray()));
        if (band is var (from, to))
            canvas.Fill(rect, Gradients.Linear(rect, Unit.Top, Unit.Bottom, (Math.Max(from - 0.08f, 0), Clear), (from, Black(0.13)), (to, Black(0.13)), (Math.Min(to + 0.08f, 1), Clear)));
    }

    /// <summary>A window's title bar: the gold double rails on either side of the name, the menu's squiggle, the window buttons (for the look).</summary>
    internal static void TitleBar(SKCanvas canvas, string title, float width, bool isPlaylist)
    {
        var top = isPlaylist ? 5f : 4f;
        var textWidth = title.Length * (isPlaylist ? 6.4f : 7.2f) + 10;
        var left = isPlaylist ? 7f : 20f;
        var right = width - (isPlaylist ? 20 : 34);
        foreach (var (from, to) in new[] { (left, width / 2 - textWidth / 2), (width / 2 + textWidth / 2, right) })
        {
            if (to - from <= 4) continue;
            canvas.Px(from, top, to - from, 7, Hex(0x1E1F25));
            canvas.Px(from + 1, top + 1, to - from - 2, 1, PcColors.GoldLight);
            canvas.Px(from + 1, top + 2, to - from - 2, 1, SKColors.White);
            canvas.Px(from + 1, top + 3, to - from - 2, 1, PcColors.GoldDark);
            canvas.Px(from + 1, top + 4, to - from - 2, 1, PcColors.GoldDim);
            canvas.Px(from + 1, top + 5, to - from - 2, 1, PcColors.GoldLight);
            canvas.Px(from + 1, top + 6, to - from - 2, 1, Hex(0x25262C));
            foreach (var x in new[] { from + 1, to - 2 })
            {
                canvas.Px(x, top + 1, 1, 1, PcColors.GoldDim);
                canvas.Px(x, top + 5, 1, 1, Hex(0x736C52));
            }
        }
        if (!isPlaylist)
        {
            foreach (var (x, y) in new[] { (8, 7), (9, 6), (9, 5), (10, 4), (11, 5), (11, 6), (12, 7), (13, 8), (13, 9), (14, 10), (15, 9), (15, 8), (16, 7) })
                canvas.Px(x, y, 1, 1, Hex(0xEFBE66));
        }
        float[] buttons = isPlaylist ? [width - 20, width - 11] : [width - 31, width - 21, width - 11];
        var by = isPlaylist ? 4f : 3f;
        for (var index = 0; index < buttons.Length; index++)
        {
            var x = buttons[index];
            if (index < buttons.Length - 1)
            {
                canvas.Px(x + 2, by, 5, 1, Hex(0xB3B6B8));
                canvas.Px(x + 1, by + 1, 7, 1, Hex(0xCEE2D1));
                canvas.Px(x, by + 2, 9, 4, Hex(0x6B5D43));
                canvas.Px(x, by + 5, 9, 2, Hex(0x5A573A));
                canvas.Px(x + 1, by + 7, 7, 1, PcColors.GoldDark);
            }
            else
            {
                canvas.Px(x + 2, by, 5, 1, Hex(0x352D10));
                canvas.Px(x, by + 2, 1, 5, Hex(0x352D10));
                canvas.Px(x + 8, by + 2, 1, 5, Hex(0x352D10));
                canvas.Px(x + 2, by + 8, 5, 1, Hex(0x352D10));
                for (var step = 0; step < 7; step++)
                {
                    canvas.Px(x + 1 + step, by + 1 + step, 1, 1, Hex(0xB69C54));
                    canvas.Px(x + 7 - step, by + 1 + step, 1, 1, Hex(0xB69C54));
                }
                canvas.Px(x + 4, by + 4, 1, 1, SKColors.White);
            }
        }
        using var font = Fonts.System(isPlaylist ? 7 : 8.5f, SKFontStyleWeight.Black);
        var baseline = Lettering.Baseline(font, isPlaylist ? 8.5f : 7.5f);
        Lettering.Draw(canvas, title, width / 2 + 0.5f, baseline + 0.5f, font, Black(0.8), SKTextAlign.Center, 0.4f);
        Lettering.Draw(canvas, title, width / 2, baseline, font, SKColors.White, SKTextAlign.Center, 0.4f);
    }

    /// <summary>A key's face: pale blue-gray, a white highlight above and on the left, two shades below and on the right; held, it sinks.</summary>
    internal static void KeyFace(SKCanvas canvas, SKRect r, bool pressed)
    {
        float x = r.Left, y = r.Top, w = r.Width, h = r.Height;
        if (pressed)
        {
            canvas.Px(x, y, w, h, Hex(0x080810));
            canvas.Px(x + 1, y + 1, w - 2, h - 2, Hex(0x7B8C9C));
            canvas.Px(x + 2, y + 2, w - 4, 1, Hex(0xADBDC6));
            canvas.Px(x + 2, y + 2, 1, h - 4, Hex(0xADBDC6));
            return;
        }
        canvas.Px(x, y, w, h, PcColors.KeyFace);
        canvas.Px(x, y, w, 1, PcColors.KeyEdge);
        canvas.Px(x, y, 1, h, PcColors.KeyEdge);
        canvas.Px(x + 1, y + 1, w - 2, 1, PcColors.KeyLight);
        canvas.Px(x + 1, y + 1, 1, h - 2, PcColors.KeyLight);
        canvas.Px(x + 2, y + h - 3, w - 4, 1, PcColors.KeyEdge);
        canvas.Px(x + w - 3, y + 2, 1, h - 4, PcColors.KeyEdge);
        canvas.Px(x + 1, y + h - 2, w - 2, 1, PcColors.KeyShade);
        canvas.Px(x + w - 2, y + 1, 1, h - 2, PcColors.KeyShade);
        canvas.Px(x, y + h - 1, w, 1, PcColors.KeyDark);
        canvas.Px(x + w - 1, y, 1, h, PcColors.KeyDark);
    }

    /// <summary>A key of the player: its face, and its label drawn (shifted a pixel while held) by <paramref name="label"/>.</summary>
    private static void Key(DeckUi ui, string id, SKRect rect, string title, Action tap, Action<SKPoint, bool> label, Action? hold = null, bool enabled = true)
    {
        var canvas = ui.Canvas;
        var pressed = ui.Press(id, rect, tap, hold, title, enabled);
        KeyFace(canvas, rect, pressed);
        canvas.Save();
        if (!enabled)
        {
            canvas.SaveLayer(new SKPaint { Color = Black(0.45) });
        }
        label(new SKPoint(rect.MidX + (pressed ? 1 : 0), rect.MidY + (pressed ? 1 : 0)), pressed);
        if (!enabled) canvas.Restore();
        canvas.Restore();
    }

    /// <summary>A glyph engraved in a key: shaded on its upper and left edges, lit on its lower and right ones, gray within.</summary>
    private static void GlyphLabel(SKCanvas canvas, PcGlyph kind, SKPoint center, float width, float height)
    {
        var rect = SKRect.Create(center.X - (width + 1) / 2, center.Y - (height + 1) / 2, width, height);
        using var shape = Pixels.Glyph(kind, rect);
        canvas.Save();
        canvas.Translate(1, 1);
        canvas.Fill(shape, PcColors.KeyLight);
        canvas.Restore();
        canvas.Fill(shape, PcColors.KeyDark);
        canvas.Save();
        canvas.Translate(1, 1);
        canvas.ClipPath(shape);
        canvas.Translate(-1, -1);
        canvas.Fill(shape, PcColors.Glyph);
        canvas.Restore();
    }

    /// <summary>A key's small light: green when on.</summary>
    private static void Led(SKCanvas canvas, float x, float y, bool on)
    {
        if (on)
        {
            using var glow = Shapes.Rect(SKRect.Create(x, y, 5, 4));
            canvas.Shadow(glow, Hex(0x00D600, 0.6), 2);
        }
        canvas.Px(x, y, 5, 1, PcColors.KeyDark);
        canvas.Px(x, y, 1, 4, PcColors.KeyDark);
        canvas.Px(x + 1, y + 1, 3, 2, on ? Hex(0x00D600) : Hex(0x8C9AA8));
        canvas.Px(x + 1, y + 3, 4, 1, Hex(0xD5DEF2));
        canvas.Px(x + 4, y + 1, 1, 3, Hex(0xD5DEF2));
    }

    /// <summary>A LED and a word on a key, centered.</summary>
    private static void LedLabel(SKCanvas canvas, SKPoint center, bool on, string text, Glyph? glyph = null)
    {
        using var font = Fonts.Pixel(6, bold: true);
        var textWidth = glyph is null ? font.MeasureText(text) : 7;
        var spacing = glyph is null ? 2.5f : 2;
        var total = 5 + spacing + textWidth;
        var x = center.X - total / 2;
        Led(canvas, (float)Math.Round(x), (float)Math.Round(center.Y - 2), on);
        if (glyph is { } symbol) Glyphs.Draw(canvas, symbol, new SKPoint(x + 5 + spacing + 3.5f, center.Y), 8, PcColors.Ink);
        else Lettering.Draw(canvas, text, x + 5 + spacing, Lettering.Baseline(font, center.Y), font, PcColors.Ink);
    }

    private static void MainWindow(DeckUi ui, SkinPlayback playback, DeckControls controls, Flag showsPlaylist)
    {
        var canvas = ui.Canvas;
        canvas.Save();
        canvas.ClipRect(SKRect.Create(MainSize));
        WindowFace(canvas, SKRect.Create(MainSize), (0.57f, 0.73f));
        // Its edges and the groove within them; the display's panel, the title's, the bit rate's and sample rate's, the position bar's groove.
        canvas.Px(0, 0, 275, 1, Hex(0x26263B));
        canvas.Px(0, 0, 1, 116, PcColors.FrameDark);
        canvas.Px(1, 1, 273, 1, PcColors.FrameLight);
        canvas.Px(1, 1, 1, 114, Hex(0x5C5C63));
        canvas.Px(0, 115, 275, 1, Hex(0x28273E));
        canvas.Px(274, 0, 1, 116, Hex(0x1E1E2F));
        canvas.Px(4, 12, 267, 2, Hex(0x101019));
        canvas.Px(4, 12, 2, 100, Hex(0x101019));
        canvas.Px(6, 14, 263, 1, PcColors.FrameLight);
        canvas.Px(6, 14, 1, 98, Hex(0x5F5F68));
        canvas.Px(4, 110, 267, 2, Hex(0x101019));
        canvas.Px(4, 112, 267, 1, PcColors.FrameLight);
        canvas.Px(267, 12, 2, 100, Hex(0x101019));
        canvas.Px(269, 12, 1, 101, PcColors.FrameLight);
        canvas.Px(11, 22, 93, 43, SKColors.Black);
        for (var y = 24; y < 64; y += 2)
            for (var x = 24; x < 102; x += 2) canvas.Px(x, y, 1, 1, PcColors.Dots);
        for (var y = 43; y < 61; y += 2) canvas.Px(23, y, 1, 1, Hex(0x3E6AB2));
        for (var x = 24; x < 101; x += 2) canvas.Px(x, 61, 1, 1, Hex(0x3E6AB2));
        canvas.Groove(10, 21, 95, 45, light: Hex(0x5F5F68));
        foreach (var (x, y, w, h) in new[] { (111f, 24f, 154f, 12f), (111, 43, 15, 8), (156, 43, 10, 8) })
        {
            canvas.Px(x, y, w, h, SKColors.Black);
            canvas.Groove(x - 1, y - 1, w + 2, h + 2, light: Hex(0x5F5F68));
        }
        canvas.Px(16, 72, 248, 12, Hex(0x1C1B2B));
        canvas.Px(16, 72, 248, 2, Hex(0x11111B));
        canvas.Px(16, 72, 2, 12, Hex(0x11111B));
        canvas.Px(16, 83, 248, 1, Hex(0x656572));
        canvas.Px(263, 72, 1, 12, Hex(0x656572));
        TitleBar(canvas, "GROOVELIGHT", 275, false);
        using (var letters = Fonts.Pixel(6))
        {
            var y = 23f;
            foreach (var letter in new[] { "O", "A", "I", "D", "V" })
            {
                Lettering.Centered(canvas, letter, new SKPoint(15, y + 3.5f), letters, Hex(0x6A6A80));
                y += 7 + 1.4f;
            }
        }
        // Playing, paused or stopped: a green arrow, two bars or a square.
        var time = playback.Time();
        var paused = !playback.IsPlaying && time > 0.5;
        var state = SKRect.Create(25, 28, 9, 9);
        using (var glyph = playback.IsPlaying ? Pixels.Glyph(PcGlyph.Play, SKRect.Inflate(state, -1, 0)) : paused
                   ? Pixels.Glyph(PcGlyph.Pause, SKRect.Inflate(state, -1, -1)) : Pixels.Glyph(PcGlyph.Stop, SKRect.Inflate(state, -1.5f, -1.5f)))
            canvas.Fill(glyph, Hex(0x00E800));
        // The time (tapped, the time left), blinking while paused.
        var remaining = ui.State("pc.remaining", () => new Flag(false));
        var timeRect = SKRect.Create(34, 25, 68, 15);
        ui.Press("pc.time", timeRect, () => remaining.Value = !remaining.Value, title: remaining.Value ? "Time remaining" : "Time");
        var blink = paused && (int)(ui.Now * 2) % 2 == 0;
        if (paused) ui.Animate();
        using (var sign = Fonts.Pixel(10, bold: true))
        using (var digits = Fonts.Digits(13))
        {
            var shown = remaining.Value ? Math.Max(playback.Duration - time, 0) : time;
            var color = PcColors.Digits.Opacity(blink ? 0.1 : 1);
            var text = SkinInfo.ClockText(shown);
            var total = sign.MeasureText("-") + digits.MeasureText(text);
            var x = timeRect.MidX - total / 2;
            if (remaining.Value) Lettering.Draw(canvas, "-", x, Lettering.Baseline(sign, timeRect.MidY), sign, color);
            Lettering.Draw(canvas, text, x + sign.MeasureText("-"), Lettering.Baseline(digits, timeRect.MidY), digits, color);
        }
        Spectrum(ui, "pc.spectrum", SKRect.Create(24, 43, 76, 16), playback);
        Marquee(ui, SKRect.Create(111, 24, 154, 12), MarqueeText(playback));
        using (var info = Fonts.Pixel(6))
        using (var label = Fonts.Pixel(6, bold: true))
        {
            Lettering.Centered(canvas, playback.Format?.Kbps?.ToString() ?? "", new SKPoint(118.5f, 47), info, PcColors.Text);
            Lettering.Centered(canvas, "kbps", new SKPoint(139, 47), label, SKColors.White);
            Lettering.Centered(canvas, playback.Format?.KHz?.ToString() ?? "", new SKPoint(161, 47), info, PcColors.Text);
            Lettering.Centered(canvas, "kHz", new SKPoint(177, 47), label, SKColors.White);
            var channels = playback.Format?.Channels;
            Lettering.Centered(canvas, "mono", new SKPoint(225, 47), label, channels == 1 ? PcColors.Text : Hex(0x4C4C66));
            Lettering.Centered(canvas, "stereo", new SKPoint(254, 47), label, channels is null or >= 2 ? PcColors.Text : Hex(0x4C4C66));
        }
        // Volume, balance (for the look), EQ and PL.
        Slider(ui, "pc.volume", SKRect.Create(107, 57, 68, 13), controls.Volume, false);
        Slider(ui, "pc.balance", SKRect.Create(177, 57, 38, 13), null, true);
        var equalizer = controls.Equalizer;
        Key(ui, "pc.eq", SKRect.Create(219, 58, 23, 12), "Equalizer", () => { if (equalizer is not null) equalizer.Value = !equalizer.Value; },
            (center, _) => LedLabel(canvas, center, equalizer?.Value == true, "EQ"), enabled: equalizer is not null);
        Key(ui, "pc.pl", SKRect.Create(242, 58, 23, 12), showsPlaylist.Value ? "Hide Playlist" : "Show Playlist", () => showsPlaylist.Value = !showsPlaylist.Value,
            (center, _) => LedLabel(canvas, center, showsPlaylist.Value, "PL"));
        PositionBar(ui, SKRect.Create(16, 72, 248, 10), playback, controls.Seek);
        // The transport keys, eject, shuffle, repeat and love.
        Key(ui, "pc.previous", SKRect.Create(16, 88, 23, 18), "Previous", controls.Previous, (c, _) => GlyphLabel(canvas, PcGlyph.Previous, c, 9, 8),
            Scan(playback, controls, -1));
        Key(ui, "pc.play", SKRect.Create(39, 88, 23, 18), "Play", () => { if (playback.IsPlaying) controls.Seek(0); else controls.PlayPause(); },
            (c, _) => GlyphLabel(canvas, PcGlyph.Play, c, 8, 9));
        Key(ui, "pc.pause", SKRect.Create(62, 88, 23, 18), "Pause", () => { if (playback.IsPlaying || playback.Time() > 0.5) controls.PlayPause(); },
            (c, _) => GlyphLabel(canvas, PcGlyph.Pause, c, 8, 9));
        Key(ui, "pc.stop", SKRect.Create(85, 88, 23, 18), "Stop", () =>
        {
            if (playback.IsPlaying) controls.PlayPause();
            controls.Seek(0);
        }, (c, _) => GlyphLabel(canvas, PcGlyph.Stop, c, 9, 9));
        Key(ui, "pc.next", SKRect.Create(108, 88, 22, 18), "Next", controls.Next, (c, _) => GlyphLabel(canvas, PcGlyph.Next, c, 9, 8), Scan(playback, controls, 1));
        Key(ui, "pc.eject", SKRect.Create(136, 89, 22, 16), "Close Now Playing", () => controls.Eject?.Invoke(), (c, _) => GlyphLabel(canvas, PcGlyph.Eject, c, 10, 8),
            enabled: controls.Eject is not null);
        Key(ui, "pc.shuffle", SKRect.Create(164, 89, 46, 15), controls.IsShuffled ? "Shuffle: On" : "Shuffle: Off", controls.ToggleShuffle,
            (c, _) => LedLabel(canvas, c, controls.IsShuffled, "SHUFFLE"));
        Key(ui, "pc.repeat", SKRect.Create(210, 89, 28, 15), "Repeat: " + controls.RepeatMode.ToString().ToLowerInvariant(), controls.CycleRepeat,
            (c, _) => LedLabel(canvas, c, controls.RepeatMode != DeckRepeat.Off, "", controls.RepeatMode == DeckRepeat.One ? Glyph.RepeatOne : Glyph.Repeat));
        var loved = controls.Love?.Value == true;
        Key(ui, "pc.love", SKRect.Create(239, 89, 15, 15), (loved ? "Unlove" : "Love") + controls.LoveHint, () => { if (controls.Love is { } love) love.Value = !love.Value; },
            (c, _) => Glyphs.Draw(canvas, loved ? Glyph.HeartFilled : Glyph.Heart, c, 8.5f, loved ? Hex(0xD81830) : PcColors.Ink), enabled: controls.Love is not null);
        Logo(canvas, SKRect.Create(252, 89, 16, 17));
        canvas.Restore();
    }

    private static Action Scan(SkinPlayback playback, DeckControls controls, double direction) =>
        () => controls.Seek(Math.Clamp(playback.Time() + direction * DeckControls.ScanStep, 0, Math.Max(playback.Duration - 1, 0)));

    /// <summary>"ARTIST - TITLE (3:45)", as the classic player scrolls it.</summary>
    private static string MarqueeText(SkinPlayback playback)
    {
        var name = string.Join(" - ", new[] { playback.Artist, playback.Title }.Where(part => part.Length > 0));
        return $"{name} ({SkinInfo.ClockText(playback.Duration).TrimStart('0')})".ToUpperInvariant();
    }

    /// <summary>Text going by from right to left in a display, in the pixel lettering, a pixel at a time; still while it fits.</summary>
    private static void Marquee(DeckUi ui, SKRect rect, string text)
    {
        var canvas = ui.Canvas;
        using var font = Fonts.Pixel(7.5f);
        var width = font.MeasureText(text);
        var baseline = Lettering.Baseline(font, rect.MidY);
        canvas.Save();
        canvas.ClipRect(rect);
        if (width <= rect.Width - 4) Lettering.Draw(canvas, text, rect.Left + 2, baseline, font, PcColors.Text);
        else
        {
            const string gap = "  ***  ";
            var loop = width + font.MeasureText(gap);
            var offset = (float)(Math.Floor(ui.Now * 24) % loop);
            var line = text + gap + text;
            Lettering.Draw(canvas, line, rect.Left + 2 - offset, baseline, font, PcColors.Text);
            ui.Animate();
        }
        canvas.Restore();
    }

    /// <summary>The display's spectrum: nineteen bars (green at the foot to red at the top), each with a gray peak that falls slowly.</summary>
    private static void Spectrum(DeckUi ui, string id, SKRect rect, SkinPlayback playback)
    {
        var state = ui.State(id, () => new SpectrumState());
        var (bars, peaks) = state.Update(SpectrumState.Target(playback), ui.Now);
        if (playback.IsPlaying || !state.IsQuiet) ui.Animate();
        const int rows = 16;
        for (var index = 0; index < SpectrumState.Bars; index++)
        {
            var x = rect.Left + index * 4;
            var height = (int)Math.Round(rows * bars[index]);
            for (var row = 0; row < height; row++)
                ui.Canvas.Px(x, rect.Top + rows - 1 - row, 3, 1, PcColors.Spectrum[Math.Max(0, PcColors.Spectrum.Length - 1 - row)]);
            var peak = (int)Math.Round(rows * peaks[index]);
            if (peak > 0) ui.Canvas.Px(x, rect.Top + rows - peak, 3, 1, PcColors.Peak);
        }
    }

    /// <summary>The base skin's volume colors, from its quietest to its loudest.</summary>
    private static SKColor SliderColor(double level)
    {
        (double At, uint Hex)[] stops = [(0, 0x18920B), (0.15, 0x7ADA30), (0.33, 0xBDE238), (0.52, 0xE0DA30), (0.67, 0xE0B228), (0.85, 0xE0721E), (1, 0xE00E15)];
        var upper = Array.FindIndex(stops, stop => stop.At >= level);
        if (upper < 0) upper = stops.Length - 1;
        if (upper == 0) return Hex(stops[0].Hex);
        var (a, b) = (stops[upper - 1], stops[upper]);
        return Hex(a.Hex).Mix(Hex(b.Hex), (level - a.At) / (b.At - a.At));
    }

    /// <summary>The volume or balance slider: a groove colored by its level, the silver thumb with three grip lines.</summary>
    private static void Slider(DeckUi ui, string id, SKRect rect, SkinBinding<double>? value, bool balance)
    {
        var canvas = ui.Canvas;
        var w = rect.Width;
        var travel = w - 14;
        var level = Math.Clamp(balance ? 0.5 : value?.Value ?? 1, 0, 1);
        if (!balance && value is not null)
        {
            ui.Drag(id, rect, drag => value.Value = Math.Clamp((drag.Location.X - rect.Left - 7) / Math.Max(travel, 1), 0, 1), wheel: delta => value.Value = Math.Clamp(value.Value + delta * 0.05, 0, 1),
                title: $"Volume: {Math.Round(level * 100)}%");
        }
        float x0 = rect.Left, y0 = rect.Top;
        var color = SliderColor(balance ? Math.Abs(level - 0.5) * 2 : level);
        canvas.Px(x0, y0 + 3, w, 1, Hex(0x161623));
        canvas.Px(x0, y0 + 4, w, 1, color.Mix(SKColors.Black, 0.25));
        canvas.Px(x0, y0 + 5, w, 1, color.Mix(SKColors.Black, 0.12));
        canvas.Px(x0, y0 + 6, w, 1, color);
        canvas.Px(x0, y0 + 7, w, 1, color.Mix(SKColors.White, 0.08));
        canvas.Px(x0, y0 + 8, w, 1, Hex(0x7D7C90));
        canvas.Px(x0, y0 + 3, 1, 6, Hex(0x1F1F31));
        var x = x0 + (float)Math.Round(travel * level);
        canvas.Px(x, y0, 14, 11, Hex(0x0B0F16));
        canvas.Px(x + 1, y0 + 1, 12, 1, Hex(0xDAE7EA));
        canvas.Px(x + 1, y0 + 1, 1, 8, Hex(0xDAE7EA));
        canvas.Px(x + 2, y0 + 2, 9, 6, Hex(0xADBCC4));
        canvas.Px(x + 11, y0 + 2, 1, 7, PcColors.KeyShade);
        canvas.Px(x + 2, y0 + 8, 10, 1, PcColors.KeyShade);
        canvas.Px(x + 1, y0 + 9, 12, 1, PcColors.KeyDark);
        canvas.Px(x + 12, y0 + 2, 1, 8, PcColors.KeyDark);
        foreach (var grip in new[] { 4f, 6, 8 }) canvas.Px(x + grip, y0 + 3, 1, 4, Hex(0x0B0F16));
    }

    /// <summary>The position bar's gold thumb (or the playlist's upright scroll thumb).</summary>
    private static void GoldThumb(SKCanvas canvas, SKRect rect, bool upright = false)
    {
        canvas.Save();
        canvas.Translate(rect.Left, rect.Top);
        var w = upright ? rect.Height : rect.Width;
        var h = upright ? rect.Width : rect.Height;
        if (upright)
        {
            canvas.Translate(rect.Width, 0);
            canvas.RotateDegrees(90);
        }
        uint[] rows = [0xDBCB9E, 0x836930, 0xF4EAC7, 0xF5F5F5, 0x755B22, 0xAF9861, 0xF4EAC7, 0xAF9861, 0x8D753A, 0x090202];
        for (var index = 0; index < rows.Length; index++) canvas.Px(0, index * h / rows.Length, w, h / rows.Length + 0.05f, Hex(rows[index]));
        canvas.Px(0, 0, 1, h - 1, Hex(0xDBCB9E));
        canvas.Px(1, 1, 1, h - 2, Hex(0x836930));
        canvas.Px(w - 2, 1, 1, h - 1, Hex(0x8D753A));
        canvas.Px(w - 1, 0, 1, h, Hex(0x090202));
        canvas.Restore();
    }

    /// <summary>The position bar: the gold thumb at the song's place, dragged to go elsewhere in it.</summary>
    private static void PositionBar(DeckUi ui, SKRect rect, SkinPlayback playback, Action<double> seek)
    {
        const float thumb = 29;
        var travel = rect.Width - thumb;
        ui.Drag("pc.position", rect, drag => ui.SetState("pc.position", (double)Math.Clamp((drag.Location.X - rect.Left - thumb / 2) / Math.Max(travel, 1), 0, 1)), _ =>
        {
            var dragged = ui.State("pc.position", () => -1.0);
            if (dragged >= 0 && playback.Duration > 0) seek(Math.Min(dragged, 0.995) * playback.Duration);
            ui.ClearState("pc.position");
        }, title: "Position");
        var dragging = ui.State("pc.position", () => -1.0);
        if (dragging < 0) ui.ClearState("pc.position");
        if (playback.Duration <= 0) return;
        var progress = dragging >= 0 ? dragging : playback.Progress;
        GoldThumb(ui.Canvas, SKRect.Create(rect.Left + (float)Math.Round(travel * progress), rect.Top, thumb, rect.Height));
    }

    /// <summary>Groovelight's mark in the corner: a tilted tile with a silver edge in the icon's blue, the icon's two notes in gold before it.</summary>
    private static void Logo(SKCanvas canvas, SKRect rect)
    {
        var side = Math.Min(rect.Width, rect.Height);
        var center = new SKPoint(rect.MidX, rect.MidY);
        var tile = Shapes.Square(center, side * 0.7f);
        canvas.Save();
        canvas.RotateDegrees(45, center.X, center.Y);
        using (var shadow = Shapes.Round(SKRect.Create(tile.Left + 0.7f, tile.Top, tile.Width, tile.Height), side * 0.12f)) canvas.Fill(shadow, Black(0.5));
        using (var edge = Shapes.Round(tile, side * 0.12f)) canvas.Fill(edge, Hex(0x484848));
        var silver = SKRect.Inflate(tile, -0.8f, -0.8f);
        using (var shape = Shapes.Round(silver, side * 0.1f)) canvas.Fill(shape, Gradients.Linear(tile, Unit.TopLeading, Unit.BottomTrailing, [Hex(0xE4E6EA), Hex(0x8F9196)]));
        var face = SKRect.Inflate(tile, -1.8f, -1.8f);
        using (var shape = Shapes.Round(face, side * 0.07f)) canvas.Fill(shape, Gradients.Linear(face, Unit.TopLeading, Unit.BottomTrailing, [Hex(0x2A4CA0), Hex(0x09143B)]));
        canvas.Restore();
        var box = SKRect.Create(rect.Left + rect.Width * 0.3f, rect.Top + rect.Height * 0.29f, rect.Width * 0.42f, rect.Height * 0.42f);
        using var notes = LogoNotes(box);
        canvas.Save();
        canvas.Translate(0.5f, 0.5f);
        canvas.Fill(notes, Black(0.6));
        canvas.Restore();
        canvas.Fill(notes, Gradients.Linear(box, Unit.TopLeading, Unit.BottomTrailing, [Hex(0xFFE9A0), Hex(0xE0B44A), Hex(0xB07A22)]));
    }

    /// <summary>The app icon's notes (its 1024-point drawing) fitted in <paramref name="rect"/>.</summary>
    internal static SKPath LogoNotes(SKRect rect)
    {
        var box = SKRect.Create(250, 66, 570, 710);
        var fit = Math.Min(rect.Width / box.Width, rect.Height / box.Height);
        var matrix = SKMatrix.CreateTranslation(-box.Left, -box.Top)
            .PostConcat(SKMatrix.CreateScale(fit, fit))
            .PostConcat(SKMatrix.CreateTranslation(rect.MidX - box.Width * fit / 2, rect.MidY - box.Height * fit / 2));
        using var notes = Shapes.Build(b =>
        {
            using (var head = Shapes.Oval(SKRect.Create(258, 610, 224, 160)))
            {
                var turn = SKMatrix.CreateRotationDegrees(-20, 370, 690);
                b.AddPath(head, in turn);
            }
            using (var head = Shapes.Oval(SKRect.Create(578, 530, 224, 160)))
            {
                var turn = SKMatrix.CreateRotationDegrees(-20, 690, 610);
                b.AddPath(head, in turn);
            }
            b.AddRect(SKRect.Create(441, 161, 34, 509));
            b.AddRect(SKRect.Create(778, 81, 34, 509));
            foreach (var (a, c) in new[] { (151f, 223f), (261f, 333f) })
            {
                b.MoveTo(441, a);
                b.LineTo(812, a - 80);
                b.LineTo(812, c - 80);
                b.LineTo(441, c);
                b.Close();
            }
        });
        return Shapes.Build(b => b.AddPath(notes, in matrix));
    }

    // MARK: Playlist window

    /// <summary>The playlist window (its size in original pixels); returns the list's place in them.</summary>
    private static SKRect PlaylistWindow(DeckUi ui, float width, float height, SkinPlayback playback, DeckControls controls, SkinPlaylist? playlist, bool showsOverlay)
    {
        var canvas = ui.Canvas;
        var entries = playlist?.Entries ?? [new SkinPlaylistEntry(playback.Title, playback.Artist, playback.Duration)];
        var current = playlist is null ? 0 : playlist.Current;
        var listHeight = height - 58;
        canvas.Save();
        canvas.ClipRect(SKRect.Create(width, height));
        WindowFace(canvas, SKRect.Create(width, height));
        canvas.Px(0, 0, width, 1, Hex(0x1D1D2D));
        canvas.Px(0, 0, 1, height, Hex(0x1D1D2D));
        canvas.Px(1, 1, width - 2, 1, Hex(0x6A6A7A));
        canvas.Px(1, 1, 1, height - 2, Hex(0x6A6A7A));
        canvas.Px(0, height - 1, width, 1, Hex(0x0E0E16));
        canvas.Px(width - 1, 0, 1, height, Hex(0x0E0E16));
        canvas.Px(4, 12, width - 8, 2, Hex(0x1D1D2D));
        canvas.Px(6, 14, width - 12, 1, Hex(0x6B6B7C));
        canvas.Px(4, 12, 2, height - 16, Hex(0x1D1D2D));
        canvas.Px(6, 14, 1, height - 18, Hex(0x6A6A7A));
        canvas.Px(width - 6, 12, 2, height - 16, Hex(0x1D1D2D));
        canvas.Px(width - 7, 14, 1, height - 18, Hex(0x6A6A7A));
        canvas.Px(4, height - 4, width - 8, 1, Hex(0x6A6A7A));
        canvas.Px(11, 20, width - 31, listHeight, SKColors.Black);
        canvas.Groove(10, 19, width - 29, listHeight + 2, Hex(0x1D1D2D), Hex(0x6A6A7A));
        canvas.Px(width - 16, 20, 8, listHeight, Hex(0x14141F));
        canvas.Px(width - 145, height - 29, 94, 10, SKColors.Black);
        canvas.Groove(width - 146, height - 30, 96, 12, Hex(0x1D1D2D), Hex(0x6A6A7A));
        canvas.Px(width - 86, height - 16, 34, 8, SKColors.Black);
        canvas.Groove(width - 87, height - 17, 36, 10, Hex(0x1D1D2D), Hex(0x6A6A7A));
        for (var step = 0; step < 4; step++)
        {
            var offset = step * 3;
            for (var d = 0; d < 10 - offset; d++) canvas.Px(width - 6 - d, height - 15 + offset + d, 1, 1, Hex(0x6A6A7A));
        }
        TitleBar(canvas, "GROOVELIGHT PLAYLIST", width, true);
        var list = SKRect.Create(11, 20, width - 31, listHeight);
        var scrolled = 0f;
        if (!showsOverlay) scrolled = List(ui, "pc.list", list, entries, current, playlist?.Play, 12.5f, 9.5f, PcColors.ListText, SKColors.White, false, true);
        GoldThumb(canvas, SKRect.Create(width - 16, 20 + (float)Math.Round(scrolled * Math.Max(listHeight - 18, 0)), 8, 18), upright: true);
        // The bottom bar: the list's keys (for the look), the lengths, the small transport keys and the time, List Opts.
        using (var keyFont = Fonts.Pixel(5.5f, bold: true))
        {
            var titles = new[] { "ADD", "REM", "SEL", "MISC" };
            for (var index = 0; index < titles.Length; index++)
            {
                var rect = SKRect.Create(11 + index * 29, height - 30, 25, 18);
                KeyFace(canvas, rect, false);
                Lettering.Centered(canvas, titles[index], new SKPoint(rect.MidX, rect.MidY), keyFont, PcColors.Ink);
            }
            var opts = SKRect.Create(width - 47, height - 30, 25, 18);
            KeyFace(canvas, opts, false);
            Lettering.Centered(canvas, "LIST", new SKPoint(opts.MidX, opts.MidY - 3.2f), keyFont, PcColors.Ink);
            Lettering.Centered(canvas, "OPTS", new SKPoint(opts.MidX, opts.MidY + 3.2f), keyFont, PcColors.Ink);
        }
        using (var small = Fonts.Pixel(5.5f))
        {
            var total = entries.Sum(entry => entry.Duration);
            var selected = current is { } index && index >= 0 && index < entries.Count ? entries[index].Duration : playback.Duration;
            Lettering.Centered(canvas, $"{ShortClock(selected)}/{ShortClock(total)}", new SKPoint(width - 98, height - 24), small, PcColors.Text);
            Lettering.Centered(canvas, SkinInfo.ClockText(playback.Time()), new SKPoint(width - 69, height - 12), small, PcColors.Text);
        }
        var keys = new (PcGlyph Glyph, string Title, Action Tap)[]
        {
            (PcGlyph.Previous, "Previous", controls.Previous),
            (PcGlyph.Play, "Play", () => { if (!playback.IsPlaying) controls.PlayPause(); }),
            (PcGlyph.Pause, "Pause", () => { if (playback.IsPlaying) controls.PlayPause(); }),
            (PcGlyph.Stop, "Stop", () =>
            {
                if (playback.IsPlaying) controls.PlayPause();
                controls.Seek(0);
            }),
            (PcGlyph.Next, "Next", controls.Next),
            (PcGlyph.Eject, "Close Now Playing", () => controls.Eject?.Invoke()),
        };
        var keyWidth = 56f / keys.Length;
        for (var index = 0; index < keys.Length; index++)
        {
            var rect = SKRect.Create(width - 146 + index * keyWidth, height - 17, keyWidth, 10);
            var pressed = ui.Press("pc.mini." + index, rect, keys[index].Tap, title: keys[index].Title);
            using var glyph = Pixels.Glyph(keys[index].Glyph, Shapes.Square(new SKPoint(rect.MidX, rect.MidY), 5));
            canvas.Fill(glyph, Hex(0xE0C070).Opacity(pressed ? 0.6 : 1));
        }
        canvas.Restore();
        return list;
    }

    private static string ShortClock(double seconds)
    {
        var whole = (int)Math.Max(seconds, 0);
        return whole >= 3600 ? $"{whole / 3600}:{whole / 60 % 60:00}:{whole % 60:00}" : $"{whole / 60}:{whole % 60:00}";
    }

    /// <summary>
    /// A list of the queue: each song a row (tapped, it plays), the one playing in its own color, scrolled with the wheel
    /// and kept on the one playing as it changes. Returns how far it is scrolled (0 to 1).
    /// </summary>
    internal static float List(DeckUi ui, string id, SKRect rect, IReadOnlyList<SkinPlaylistEntry> entries, int? current, Action<int>? play, float rowHeight, float fontSize,
                               SKColor color, SKColor currentColor, bool titleFirst, bool numbered, bool boldCurrent = false)
    {
        var canvas = ui.Canvas;
        var content = entries.Count * rowHeight + 4;
        var range = Math.Max(content - rect.Height, 0);
        var offset = ui.State(id + ".offset", () => new Number(double.NaN));
        var followed = ui.State(id + ".current", () => new Number(-2));
        if ((current ?? -1) != (int)followed.Value || double.IsNaN(offset.Value))
        {
            followed.Value = current ?? -1;
            // On the song playing, in the middle.
            if (current is { } index) offset.Value = Math.Clamp(2 + index * rowHeight + rowHeight / 2 - rect.Height / 2, 0, range);
            else if (double.IsNaN(offset.Value)) offset.Value = 0;
        }
        offset.Value = Math.Clamp(offset.Value, 0, range);
        ui.Wheel(id, rect, delta => offset.Value = Math.Clamp(offset.Value - delta * rowHeight * 3, 0, range));
        canvas.Save();
        canvas.ClipRect(rect);
        using var regular = Fonts.System(fontSize);
        using var bold = Fonts.System(fontSize, SKFontStyleWeight.Bold);
        var first = Math.Max(0, (int)((offset.Value - 2) / rowHeight));
        for (var index = first; index < entries.Count; index++)
        {
            var top = rect.Top + 2 + index * rowHeight - (float)offset.Value;
            if (top > rect.Bottom) break;
            var row = SKRect.Create(rect.Left, top, rect.Width, rowHeight);
            var entry = entries[index];
            var isCurrent = index == current;
            if (play is not null)
            {
                var chosen = index;
                if (ui.Press($"{id}.{index}", SKRect.Intersect(row, rect), () => play(chosen), title: entry.Title)) canvas.Fill(row, White(0.12));
            }
            var font = isCurrent && boldCurrent ? bold : regular;
            var length = SkinInfo.ClockText(entry.Duration).TrimStart('0');
            if (length.StartsWith(':')) length = "0" + length;
            var lengthWidth = font.MeasureText(length);
            var name = titleFirst
                ? string.Join(" - ", new[] { entry.Title, entry.Artist }.Where(part => part.Length > 0))
                : string.Join(" - ", new[] { entry.Artist, entry.Title }.Where(part => part.Length > 0));
            if (numbered) name = $"{index + 1}. {name}";
            var baseline = Lettering.Baseline(font, row.MidY);
            var ink = isCurrent ? currentColor : color;
            Lettering.Draw(canvas, Lettering.Fit(name, font, row.Width - lengthWidth - fontSize * 0.9f), row.Left + 3 * fontSize / 9.5f, baseline, font, ink);
            Lettering.Draw(canvas, length, row.Right - 3 * fontSize / 9.5f, baseline, font, ink, SKTextAlign.Right);
        }
        canvas.Restore();
        return range > 0 ? (float)(offset.Value / range) : 0;
    }
}
