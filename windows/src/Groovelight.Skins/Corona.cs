using SkiaSharp;
using static Groovelight.Skins.Colors;

namespace Groovelight.Skins;

/// <summary>Corona's colors, as its bitmaps have them.</summary>
internal static class CoronaColors
{
    public static readonly SKColor Frame = Hex(0xC0D3EA), FrameEdge = Hex(0xA1B5D5), FrameDark = Hex(0x60647F), Navy = Hex(0x202852), Green = Hex(0x00FF00);
    public static readonly SKColor[] Tube = [Hex(0xB7CBEA), Hex(0x94AAD9), Hex(0x7D94CC), Hex(0x6577B9), Hex(0x505FA6), Hex(0x44549C)];
    public static readonly SKColor[] Glyph = [Hex(0x182B3C), Hex(0x33597C), Hex(0x4D7BA2)];
    public static readonly SKColor[] Seek = [Hex(0x779C8C), Hex(0x8EB599), Hex(0xA0C8A1), Hex(0xBBDEAE)];
    public static readonly SKColor[] ThumbGreen = [Hex(0x1CE249), Hex(0x53D324), Hex(0x28A949)];
    public static readonly SKColor[] Block = [Hex(0xA6B9DE), Hex(0x8AA3CC), Hex(0x8396BB)];
}

/// <summary>
/// The PC Player's Corona theme (the Mac's CoronaPlayer), the glassy blue media player of 2002: a screen in a periwinkle
/// frame (the spectrum's bars or the cover), the transport drawer under it, and the playlist drawer sliding out beside
/// it in a wide window (or under it in a tall one). Drawn in its own pixels (the main window 346 wide), scaled up.
/// </summary>
internal static class Corona
{
    private const float Width = 346, PlaylistWidth = 263;
    /// <summary>The main window and the drawer around the screen: 26 above it, 19 under it, then the drawer.</summary>
    private const float Chrome = 26 + 19 + 59;

    public static SKRect? Draw(DeckUi ui, SKSize size, float top, SkinPlayback playback, DeckControls controls, SkinPlaylist? playlist, bool showsOverlay,
                               SkinBinding<int> visualization)
    {
        var canvas = ui.Canvas;
        var margin = Math.Max(8, Math.Min(size.Width, size.Height) * 0.02f);
        var area = SKRect.Create(margin, top, Math.Max(size.Width - margin * 2, 1), Math.Max(size.Height - top - margin, 1));
        float scale, screen;
        SKRect main, list;
        if (area.Width >= area.Height * 1.25f)
        {
            // Wide: the playlist slid out on the player's left, as in the original.
            var total = Width + PlaylistWidth - 13;
            scale = Math.Min(Math.Min(area.Width / total, area.Height / (240 + Chrome)), 3);
            screen = Math.Clamp(area.Height / scale - Chrome, 120, 240);
            var left = area.MidX - total * scale / 2;
            main = SKRect.Create(left + (PlaylistWidth - 13) * scale, area.Top, Width * scale, (screen + Chrome) * scale);
            list = SKRect.Create(left, main.Top + 33 * scale, PlaylistWidth * scale, (screen - 3) * scale);
        }
        else
        {
            // Tall: the playlist under the player, the screen giving it room.
            scale = Math.Min(area.Width / Width, 3);
            screen = Math.Clamp(area.Height * 0.5f / scale - Chrome, 120, 240);
            main = SKRect.Create(area.MidX - Width * scale / 2, area.Top, Width * scale, (screen + Chrome) * scale);
            list = SKRect.Create(main.Left, main.Bottom + 4 * scale, main.Width, Math.Max(area.Bottom - main.Bottom - 4 * scale, 80));
        }
        var shows = ui.State("corona.showsPlaylist", () => new Flag(true));
        // Slides open and closed over a third of a second.
        var open = Controls.Ease(ui, "corona.open", shows.Value ? 1 : 0, 0.08);
        var beside = list.Right <= main.Left + 20 * scale;
        // On a wide screen the window sits centered while the playlist is closed; opening it, the two slide apart.
        var shift = beside ? (list.Width - 13 * scale) / 2 * (1 - open) : 0;
        SKRect? overlay = null;
        if (open > 0.001f)
        {
            canvas.Save();
            canvas.ClipRect(SKRect.Create(list.Left + (beside ? shift : 0), list.Top, list.Width, list.Height));
            var dx = beside ? (main.Left - shift - list.Left) * (1 - open) : 0;
            var dy = beside ? 0 : -list.Height * (1 - open);
            canvas.Translate(list.Left + dx, list.Top + dy);
            canvas.Scale(scale);
            var inner = Playlist(ui, list.Width / scale, list.Height / scale, playback, controls, playlist, showsOverlay, shows, open > 0.99f);
            canvas.Restore();
            if (showsOverlay && open > 0.99f)
                overlay = SKRect.Create(list.Left + (inner.Left + 8) * scale, list.Top + (inner.Top + 8) * scale, (inner.Width - 16) * scale, (inner.Height - 16) * scale);
        }
        canvas.Save();
        canvas.Translate(main.Left - shift, main.Top);
        canvas.Scale(scale);
        Main(ui, screen, playback, controls, playback.Artwork, shows, !(beside && open > 0.5f), visualization);
        canvas.Restore();
        return overlay;
    }

    /// <summary>A glossy round key: a silver rim, a pale face lit from above and bluer below, its glyph in navy; held, it sinks.</summary>
    private static void RoundKey(DeckUi ui, string id, SKPoint topLeft, float diameter, string title, Action tap, Action<SKPoint> glyph, Action? hold = null, bool enabled = true)
    {
        var canvas = ui.Canvas;
        var rect = SKRect.Create(topLeft.X, topLeft.Y, diameter, diameter);
        var pressed = ui.Press(id, rect, tap, hold, title, enabled, round: true);
        using (var rim = Shapes.Oval(rect))
        {
            canvas.Shadow(rim, Black(0.25), 1, 0, 0.6f);
            canvas.Fill(rim, Gradients.Vertical(rect, Hex(0xB0B3BA), Hex(0x607279)));
        }
        var ring = SKRect.Inflate(rect, -0.8f, -0.8f);
        using (var shape = Shapes.Oval(ring)) canvas.Fill(shape, Gradients.Vertical(ring, SKColors.White, Hex(0xF6F7FA), Hex(0xA9ABB0)));
        var pad = diameter > 26 ? 3 : 2.2f;
        var face = SKRect.Inflate(rect, -pad, -pad);
        using (var shape = Shapes.Oval(face))
        {
            canvas.Fill(shape, Gradients.Linear(face, Unit.Top, Unit.Bottom, (0, pressed ? Hex(0xB9CBE4) : SKColors.White), (0.45f, pressed ? Hex(0xA9C0DD) : Hex(0xD5DCEF)),
                (1, pressed ? Hex(0x9DB8D6) : Hex(0xC3E0F2))));
            canvas.CircleBorder(face, Hex(0x5D686F, 0.55), 0.6f);
        }
        var center = new SKPoint(rect.MidX, rect.MidY + (pressed ? 0.5f : 0));
        if (enabled) glyph(center);
        else canvas.Layer(0.4, () => glyph(center));
    }

    /// <summary>A transport glyph in Corona's navy, darker at the top.</summary>
    private static void TransportGlyph(SKCanvas canvas, PcGlyph kind, SKPoint center, float width, float height)
    {
        var rect = Shapes.CenteredRect(center, width, height);
        using var shape = Pixels.Glyph(kind, rect);
        canvas.Fill(shape, Gradients.Vertical(rect, CoronaColors.Glyph));
    }

    private static void Symbol(SKCanvas canvas, Glyph glyph, SKPoint center, float size, SKColor? color = null)
    {
        if (color is { } plain) Glyphs.Draw(canvas, glyph, center, size, plain);
        else Glyphs.Draw(canvas, glyph, center, size, Gradients.Vertical(Shapes.Square(center, size), CoronaColors.Glyph));
    }

    private static Action Scan(SkinPlayback playback, DeckControls controls, double direction) =>
        () => controls.Seek(Math.Clamp(playback.Time() + direction * DeckControls.ScanStep, 0, Math.Max(playback.Duration - 1, 0)));

    // MARK: Main window and transport drawer

    private static void Main(DeckUi ui, float screen, SkinPlayback playback, DeckControls controls, SKImage? artwork, Flag shows, bool showsHandle, SkinBinding<int> visualization)
    {
        var canvas = ui.Canvas;
        var screenBottom = 26 + screen;
        var drawerTop = screenBottom + 18;
        // The transport drawer, flowing on from the window, then the blue block at its lower right with the mark and the view keys.
        canvas.Save();
        canvas.Translate(13, drawerTop);
        canvas.Scale(333f / 334);
        var drawerRect = SKRect.Create(334, 60);
        using (var drawer = DrawerShape(false))
        {
            canvas.Fill(drawer, Gradients.Linear(drawerRect, Unit.Top, Unit.Bottom, (0, CoronaColors.Frame), (0.2f, Hex(0xD3E0F1)), (0.27f, SKColors.White), (0.42f, Hex(0xF1F3FA)),
                (0.55f, Hex(0xE5EAF5)), (0.66f, Hex(0xF4F6FB)), (0.86f, Hex(0xD5DCEF)), (1, Hex(0xB6C2D9))));
        }
        using (var outline = DrawerShape(true)) canvas.Stroke(outline, Hex(0x646871), 0.8f);
        using (var block = BlockShape(false)) canvas.Fill(block, Gradients.Linear(SKRect.Create(229, 17, 105, 23), Unit.Top, Unit.Bottom, CoronaColors.Block));
        using (var edge = BlockShape(true)) canvas.Stroke(edge, Hex(0x6D7285), 0.6f);
        canvas.Restore();
        using (var notes = PcPlayer.LogoNotes(SKRect.Create(272, drawerTop + 21, 13, 13)))
        {
            canvas.Save();
            canvas.Translate(0.6f, 0.6f);
            canvas.Fill(notes, Hex(0x45549D, 0.7));
            canvas.Restore();
            canvas.Fill(notes, Gradients.Vertical(SKRect.Create(272, drawerTop + 21, 13, 13), SKColors.White, Hex(0xDDE6F7)));
        }
        Glyphs.Draw(canvas, Glyph.DashedRectangle, new SKPoint(300, drawerTop + 27), 10, White(0.95));
        Glyphs.Draw(canvas, Glyph.Shrink, new SKPoint(318, drawerTop + 27), 8, White(0.95));
        for (var row = 0; row < 3; row++)
            for (var column = 0; column < 3 - row; column++)
            {
                using var dot = Shapes.Oval(SKRect.Create(338 - column * 3, drawerTop + 35.5f - row * 3, 1.6f, 1.6f));
                canvas.Fill(dot, White(0.7));
            }
        // The seek row: rewind, the track with its thumb, fast forward.
        SeekBar(ui, SKRect.Create(54, drawerTop + 1, 249, 13), playback, controls.Seek);
        SeekKey(ui, "corona.rewind", SKRect.Create(18, drawerTop + 1, 35, 13), "Rewind", false, Scan(playback, controls, -1));
        SeekKey(ui, "corona.fastForward", SKRect.Create(303, drawerTop + 1, 35, 13), "Fast Forward", true, Scan(playback, controls, 1));
        // The transport keys: play (pause while playing) large, stop, previous and next joined, mute.
        var joined = SKRect.Create(78, drawerTop + 24, 45, 22);
        using (var capsule = Shapes.Capsule(joined))
        {
            canvas.Fill(capsule, Gradients.Vertical(joined, Hex(0xEAF0F8), Hex(0xC4CCDD)));
            canvas.Stroke(capsule, Hex(0x9297A5, 0.7), 0.5f);
        }
        RoundKey(ui, "corona.play", new SKPoint(20, drawerTop + 20), 30, playback.IsPlaying ? "Pause" : "Play", controls.PlayPause, center =>
        {
            if (playback.IsPlaying) TransportGlyph(canvas, PcGlyph.Pause, center, 9, 10);
            else TransportGlyph(canvas, PcGlyph.Play, center + new SKPoint(1, 0), 10, 12);
        });
        RoundKey(ui, "corona.stop", new SKPoint(54, drawerTop + 24), 22, "Stop", () =>
        {
            if (playback.IsPlaying) controls.PlayPause();
            controls.Seek(0);
        }, center => TransportGlyph(canvas, PcGlyph.Stop, center, 6.5f, 6.5f));
        RoundKey(ui, "corona.previous", new SKPoint(78, drawerTop + 24), 22, "Previous", controls.Previous, center => TransportGlyph(canvas, PcGlyph.Previous, center, 7.5f, 7.5f),
            Scan(playback, controls, -1));
        RoundKey(ui, "corona.next", new SKPoint(101, drawerTop + 24), 22, "Next", controls.Next, center => TransportGlyph(canvas, PcGlyph.Next, center, 7.5f, 7.5f),
            Scan(playback, controls, 1));
        var muted = ui.State("corona.muted", () => new Number(double.NaN));
        RoundKey(ui, "corona.mute", new SKPoint(128, drawerTop + 24), 22, double.IsNaN(muted.Value) ? "Mute" : "Sound", () =>
        {
            if (controls.Volume is not { } volume) return;
            // Mute: the volume to nothing, and back to where it was.
            if (!double.IsNaN(muted.Value))
            {
                volume.Value = muted.Value;
                muted.Value = double.NaN;
            }
            else
            {
                muted.Value = Math.Max(volume.Value, 0.05);
                volume.Value = 0;
            }
        }, center => Symbol(canvas, double.IsNaN(muted.Value) ? Glyph.Speaker : Glyph.SpeakerMuted, center, 10), enabled: controls.Volume is not null);
        Volume(ui, SKRect.Create(158, drawerTop + 25, 70, 18), controls.Volume);
        // The window's edge as one bent blue tube, the playlist drawer's grip on it, the periwinkle frame.
        Edge(canvas, screenBottom + 12, showsHandle ? null : (33, screenBottom + 4));
        if (showsHandle)
        {
            Grip(canvas, new SKPoint(3.5f, 26 + screen / 2 - 14));
            ui.Press("corona.handle", SKRect.Create(0, 26, 13, screen), () => shows.Value = !shows.Value, title: shows.Value ? "Hide Playlist" : "Show Playlist");
        }
        using (var frame = FrameShape(screen, false))
        {
            canvas.Fill(frame, Gradients.Linear(SKRect.Create(0, 0, Width, screenBottom + 19), Unit.Top, Unit.Bottom, (0, SKColors.White), (0.01f, Hex(0xDFE8F4)),
                (0.06f, CoronaColors.Frame), (1, CoronaColors.Frame)));
        }
        using (var outline = FrameShape(screen, true)) canvas.Stroke(outline, CoronaColors.FrameDark, 0.8f);
        canvas.Px(13, 22, 1, screen + 6, Hex(0xFAFDFF));
        // The screen: the spectrum or the cover (tapped, the next).
        var screenRect = SKRect.Create(19, 26, 320, screen);
        canvas.Fill(screenRect, SKColors.Black);
        canvas.Save();
        canvas.ClipRect(screenRect);
        if (visualization.Value == 1)
        {
            var side = Math.Min(screen * 0.78f, screenRect.Width);
            Stages.Artwork(canvas, artwork, Shapes.Square(new SKPoint(screenRect.MidX, screenRect.MidY), side));
        }
        else Bars(ui, screenRect, playback);
        canvas.Restore();
        canvas.Stroke(Shapes.Rect(SKRect.Inflate(screenRect, 0.2f, 0.2f)), CoronaColors.FrameDark, 0.8f);
        void NextVisualization() => visualization.Value = (visualization.Value + 1) % 2;
        ui.Press("corona.screen", screenRect, NextVisualization, title: "Visualization");
        Metadata(ui, SKRect.Create(19, screenBottom + 1, 320, 15), playback);
        // The top bar's keys: open (leaves Now Playing), the playlist, the next visualization, the equalizer; minimize and close.
        void TopKey(string id, string title, Glyph glyph, float x, Action tap, bool on = false, bool enabled = true) =>
            RoundKey(ui, id, new SKPoint(x, 3), 18, title, tap, center => Glyphs.Draw(canvas, glyph, center, 8.5f, on ? Hex(0x2B6CD8) : CoronaColors.Navy), enabled: enabled);
        TopKey("corona.open", "Close Now Playing", Glyph.Folder, 117, () => controls.Eject?.Invoke(), enabled: controls.Eject is not null);
        canvas.Px(138, 5, 1, 15, Hex(0xA1B5D5));
        canvas.Px(139, 5, 1, 15, SKColors.White);
        TopKey("corona.playlist", shows.Value ? "Hide Playlist" : "Show Playlist", Glyph.List, 144, () => shows.Value = !shows.Value, shows.Value);
        TopKey("corona.visualization", "Next Visualization", Glyph.Asterisk, 167, NextVisualization);
        var equalizer = controls.Equalizer;
        TopKey("corona.equalizer", "Equalizer", Glyph.Bars, 190, () => { if (equalizer is not null) equalizer.Value = !equalizer.Value; }, equalizer?.Value == true,
            equalizer is not null);
        canvas.Px(302, 5, 1, 15, Hex(0xA1B5D5));
        canvas.Px(303, 5, 1, 15, SKColors.White);
        using (var font = Fonts.System(11, SKFontStyleWeight.Black)) Lettering.Draw(canvas, "_", 311, 1 - font.Metrics.Ascent, font, CoronaColors.Navy);
        var close = SKRect.Create(324, 4, 16, 16);
        var closing = ui.Press("corona.close", close, () => controls.Eject?.Invoke(), title: "Close Now Playing", enabled: controls.Eject is not null);
        Glyphs.Draw(canvas, Glyph.Close, new SKPoint(close.MidX, close.MidY), 9, CoronaColors.Navy.Opacity(closing ? 0.6 : 1));
    }

    /// <summary>The window's periwinkle frame: the top bar rising with an S curve from the tab to its rounded right corner, down both sides around the screen.</summary>
    private static SKPath FrameShape(float screen, bool open) => Shapes.Build(b =>
    {
        var bottom = 26 + screen + 19;
        if (open)
        {
            b.MoveTo(13, bottom);
            b.LineTo(13, 24);
            b.QuadTo(13, 20, 20, 20);
            b.LineTo(92, 20);
            b.CubicTo(106, 20, 104, 0, 118, 0);
            b.LineTo(336, 0);
            b.QuadTo(346, 0, 346, 10);
            b.LineTo(346, bottom);
            b.AddRect(SKRect.Create(19, 26, 320, screen));
            b.AddRect(SKRect.Create(19, 26 + screen + 1, 320, 15));
            return;
        }
        b.MoveTo(13, 24);
        b.LineTo(13, bottom);
        b.LineTo(346, bottom);
        b.LineTo(346, 10);
        b.QuadTo(346, 0, 336, 0);
        b.LineTo(118, 0);
        b.CubicTo(104, 0, 106, 20, 92, 20);
        b.LineTo(20, 20);
        b.QuadTo(13, 20, 13, 24);
        b.Close();
        // The screen and the metadata strip, cut out.
        b.AddRect(SKRect.Create(19, 26, 320, screen));
        b.AddRect(SKRect.Create(19, 26 + screen + 1, 320, 15));
    }, SKPathFillType.EvenOdd);

    /// <summary>The drawer: a glossy tray with a large rounded lower left corner, its right end lower (open: without its top).</summary>
    private static SKPath DrawerShape(bool open) => Shapes.Build(b =>
    {
        if (open) b.MoveTo(334, 0);
        else
        {
            b.MoveTo(0, 0);
            b.LineTo(334, 0);
        }
        b.LineTo(334, 32);
        b.QuadTo(334, 40, 326, 40);
        b.LineTo(229, 40);
        b.CubicTo(222, 48, 218, 58, 205, 58);
        b.LineTo(22, 58);
        b.QuadTo(0, 58, 0, 36);
        if (open) b.LineTo(0, 0);
        else b.Close();
    });

    /// <summary>The blue block at the drawer's lower right (just its top and curved edge for its outline).</summary>
    private static SKPath BlockShape(bool edgeOnly) => Shapes.Build(b =>
    {
        if (edgeOnly)
        {
            b.MoveTo(334, 17);
            b.LineTo(256, 17);
            b.MoveTo(229, 40);
            b.CubicTo(236, 32, 240, 17, 256, 17);
            return;
        }
        b.MoveTo(256, 17);
        b.LineTo(334, 17);
        b.LineTo(334, 32);
        b.QuadTo(334, 40, 326, 40);
        b.LineTo(229, 40);
        b.CubicTo(236, 32, 240, 17, 256, 17);
        b.Close();
    });

    /// <summary>
    /// The window's blue edge as one bent tube: from behind the frame along the top, around a rounded corner, and down the
    /// left side to a diagonal cut, lit on its outer side and darker on its inner side all along; without the drawer's
    /// piece (<paramref name="gap"/>) while the playlist is slid out beside it.
    /// </summary>
    private static void Edge(SKCanvas canvas, float length, (float From, float To)? gap)
    {
        const float thickness = 13, radius = 10, top = 7;
        var bottom = top + length;
        using var outline = Shapes.Build(b =>
        {
            b.MoveTo(radius, top);
            b.LineTo(130, top);
            b.LineTo(130, top + thickness);
            b.LineTo(thickness + 3, top + thickness);
            b.QuadTo(thickness, top + thickness, thickness, top + thickness + 3);
            b.LineTo(thickness, bottom - 2);
            b.QuadTo(thickness, bottom, thickness - 1.5f, bottom - 0.5f);
            b.LineTo(0, bottom - thickness);
            b.LineTo(0, top + radius);
            b.ArcTo(SKRect.Create(0, top, radius * 2, radius * 2), 180, 90, false);
            b.Close();
        });
        canvas.Save();
        if (gap is var (from, to))
        {
            using var kept = Shapes.Build(b =>
            {
                b.AddRect(SKRect.Create(-2, -2, 134, from + 2));
                b.AddRect(SKRect.Create(-2, to, 134, bottom + 20 - to));
            });
            canvas.ClipPath(kept);
        }
        canvas.Save();
        canvas.ClipPath(outline, antialias: true);
        canvas.Fill(outline, CoronaColors.Tube[^1]);
        // Bands from the outer edge in, each following the bend: the light stays outside around the corner.
        const int bands = 26;
        for (var band = 0; band < bands; band++)
        {
            var d = (band + 0.5f) * thickness / bands;
            var position = d / thickness * (CoronaColors.Tube.Length - 1);
            var lower = Math.Min((int)position, CoronaColors.Tube.Length - 2);
            var color = CoronaColors.Tube[lower].Mix(CoronaColors.Tube[lower + 1], position - lower);
            using var line = Shapes.Build(b =>
            {
                b.MoveTo(130, top + d);
                b.LineTo(radius, top + d);
                if (radius - d > 0) b.ArcTo(SKRect.Create(d, top + d, (radius - d) * 2, (radius - d) * 2), 270, -90, false);
                else b.LineTo(d, top + d);
                b.LineTo(d, bottom + 2);
            });
            canvas.Stroke(line, color, thickness / bands + 0.4f);
        }
        canvas.Restore();
        canvas.Stroke(outline, Hex(0x45549D), 0.6f);
        canvas.Restore();
    }

    /// <summary>The playlist drawer's grip on its blue tube: two columns of light dots.</summary>
    private static void Grip(SKCanvas canvas, SKPoint topLeft)
    {
        for (var row = 0; row < 8; row++)
            for (var column = 0; column < 2; column++)
            {
                using var dot = Shapes.Oval(SKRect.Create(topLeft.X + column * 3.6f, topLeft.Y + row * 3.6f, 1.6f, 1.6f));
                canvas.Fill(dot, White(0.7));
            }
    }

    /// <summary>A seek key at an end of the seek bar: a white capsule with two navy arrowheads; held, it keeps going.</summary>
    private static void SeekKey(DeckUi ui, string id, SKRect rect, string title, bool right, Action step)
    {
        var canvas = ui.Canvas;
        var pressed = ui.Press(id, rect, step, step, title);
        using (var outer = Shapes.Capsule(rect)) canvas.Fill(outer, Gradients.Vertical(rect, Hex(0xB2B4BE), Hex(0x98ADB7)));
        var inner = SKRect.Inflate(rect, -0.8f, -0.8f);
        using (var shape = Shapes.Capsule(inner))
            canvas.Fill(shape, Gradients.Linear(inner, Unit.Top, Unit.Bottom, (0, SKColors.White), (0.5f, Hex(0xECEDF3)), (1, pressed ? Hex(0xA8C8E4) : Hex(0xC0E0F0))));
        for (var arrow = 0; arrow < 2; arrow++)
        {
            var x = rect.MidX + (arrow == 0 ? -4.3f : 0.3f);
            var box = SKRect.Create(x, rect.MidY - 2, 4, 4);
            using var shape = Shapes.Build(b =>
            {
                b.MoveTo(right ? box.Left : box.Right, box.Top);
                b.LineTo(right ? box.Right : box.Left, box.MidY);
                b.LineTo(right ? box.Left : box.Right, box.Bottom);
                b.Close();
            });
            canvas.Fill(shape, CoronaColors.Navy);
        }
    }

    /// <summary>Corona's slider thumb: silver, with green caps at its ends.</summary>
    private static void Thumb(SKCanvas canvas, SKRect rect, bool horizontal)
    {
        using var shape = Shapes.Round(rect, 3);
        canvas.Fill(shape, Gradients.Linear(rect, horizontal ? Unit.Leading : Unit.Top, horizontal ? Unit.Trailing : Unit.Bottom, CoronaColors.ThumbGreen));
        var silver = horizontal ? SKRect.Inflate(rect, -4.5f, -1) : SKRect.Inflate(rect, -1, -4.5f);
        using (var inner = Shapes.Round(silver, 3)) canvas.Fill(inner, Gradients.Vertical(silver, SKColors.White, Hex(0xCCD8E7), Hex(0xA3B3CA)));
        canvas.Border(rect, 3, Hex(0x747475), 0.6f);
    }

    /// <summary>The seek bar: a green-tinted groove and the thumb at the song's place, dragged to seek.</summary>
    private static void SeekBar(DeckUi ui, SKRect rect, SkinPlayback playback, Action<double> seek)
    {
        var canvas = ui.Canvas;
        const float thumb = 23;
        var travel = rect.Width - thumb;
        var groove = SKRect.Create(rect.Left, rect.MidY - 4.5f, rect.Width, 9);
        canvas.Fill(groove, Gradients.Vertical(groove, CoronaColors.Seek));
        canvas.Fill(SKRect.Create(rect.Left, groove.Bottom, rect.Width, 2), SKColors.White);
        ui.Drag("corona.seek", rect, drag => ui.SetState("corona.seek", (double)Math.Clamp((drag.Location.X - rect.Left - thumb / 2) / Math.Max(travel, 1), 0, 1)), _ =>
        {
            var dragged = ui.State("corona.seek", () => -1.0);
            if (dragged >= 0 && playback.Duration > 0) seek(Math.Min(dragged, 0.995) * playback.Duration);
            ui.ClearState("corona.seek");
        }, title: "Position");
        var dragging = ui.State("corona.seek", () => -1.0);
        if (dragging < 0) ui.ClearState("corona.seek");
        if (playback.Duration > 0) Thumb(canvas, SKRect.Create(rect.Left + travel * (float)(dragging >= 0 ? dragging : playback.Progress), rect.Top, thumb, rect.Height), true);
    }

    /// <summary>The volume: a wedge widening to the right, green as far as the level, and the green-capped thumb.</summary>
    private static void Volume(DeckUi ui, SKRect rect, SkinBinding<double>? value)
    {
        var canvas = ui.Canvas;
        const float thumb = 10;
        var level = (float)Math.Clamp(value?.Value ?? 1, 0, 1);
        if (value is not null)
            ui.Drag("corona.volume", rect, drag => value.Value = Math.Clamp((drag.Location.X - rect.Left - thumb / 2) / Math.Max(rect.Width - thumb, 1), 0, 1),
                wheel: delta => value.Value = Math.Clamp(value.Value + delta * 0.05, 0, 1), title: $"Volume: {Math.Round(level * 100)}%");
        using var wedge = Shapes.Build(b =>
        {
            b.MoveTo(rect.Left, rect.Top + rect.Height * 0.72f);
            b.LineTo(rect.Right, rect.Top + rect.Height * 0.2f);
            b.LineTo(rect.Right, rect.Top + rect.Height * 0.72f);
            b.Close();
        });
        canvas.Fill(wedge, Gradients.Vertical(rect, Hex(0xDFE6F7), Hex(0xA3ADCB)));
        canvas.Save();
        canvas.ClipRect(SKRect.Create(rect.Left, rect.Top, thumb / 2 + (rect.Width - thumb) * level, rect.Height));
        canvas.Fill(wedge, Gradients.Vertical(rect, Hex(0x72A382), Hex(0x99D295)));
        canvas.Restore();
        canvas.Stroke(wedge, Hex(0x9FAACB), 0.5f);
        Thumb(canvas, SKRect.Create(rect.Left + (rect.Width - thumb) * level, rect.Top, thumb, rect.Height), false);
    }

    /// <summary>The metadata strip: the song's title, artist and album in turn, the time at the right.</summary>
    private static void Metadata(DeckUi ui, SKRect rect, SkinPlayback playback)
    {
        var canvas = ui.Canvas;
        canvas.Fill(rect, SKColors.Black);
        var fields = new[] { playback.Title, playback.Artist, playback.Album }.Where(field => field.Length > 0).ToArray();
        var field = fields.Length == 0 ? "" : fields[(int)(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 4000 % fields.Length)];
        using var font = Fonts.System(8.5f, SKFontStyleWeight.Bold);
        var time = SkinInfo.ClockText(playback.Time());
        var timeWidth = font.MeasureText(time);
        var baseline = Lettering.Baseline(font, rect.MidY);
        Lettering.Draw(canvas, Lettering.Fit(field, font, rect.Width - 8 - timeWidth - 6), rect.Left + 4, baseline, font, CoronaColors.Green);
        Lettering.Draw(canvas, time, rect.Right - 4, baseline, font, CoronaColors.Green, SKTextAlign.Right);
    }

    /// <summary>The screen's bars: the spectrum, deep blue at their foot to white at their top, with falling caps.</summary>
    private static void Bars(DeckUi ui, SKRect rect, SkinPlayback playback)
    {
        var canvas = ui.Canvas;
        var state = ui.State("corona.spectrum", () => new SpectrumState());
        var (bars, peaks) = state.Update(SpectrumState.Target(playback), ui.Now);
        if (playback.IsPlaying || !state.IsQuiet) ui.Animate();
        var count = SpectrumState.Bars;
        var gap = rect.Width * 0.012f;
        var width = (rect.Width - gap * (count + 1)) / count;
        using var gradient = SKShader.CreateLinearGradient(new SKPoint(0, rect.Top + rect.Height * 0.1f), new SKPoint(0, rect.Bottom),
            [Hex(0xE8F6FF), Hex(0x3FA9F5), Hex(0x1E4FB5), Hex(0x0B1F5C)], null, SKShaderTileMode.Clamp);
        using var paint = new SKPaint { Shader = gradient, IsAntialias = true };
        for (var index = 0; index < count; index++)
        {
            var x = rect.Left + gap + index * (width + gap);
            var height = rect.Height * 0.9f * (float)bars[index];
            if (height > 0) canvas.DrawRect(SKRect.Create(x, rect.Bottom - height, width, height), paint);
            var peak = rect.Height * 0.9f * (float)peaks[index];
            if (peak > 2) canvas.Fill(SKRect.Create(x, rect.Bottom - peak - 2, width, 1.5f), White(0.85));
        }
    }

    // MARK: Playlist drawer

    /// <summary>The playlist drawer (its size in the skin's pixels); returns the list's place in them.</summary>
    private static SKRect Playlist(DeckUi ui, float width, float height, SkinPlayback playback, DeckControls controls, SkinPlaylist? playlist, bool showsOverlay, Flag shows,
                                   bool interactive)
    {
        var canvas = ui.Canvas;
        var entries = playlist?.Entries ?? [new SkinPlaylistEntry(playback.Title, playback.Artist, playback.Duration)];
        var current = playlist is null ? 0 : playlist.Current;
        // The frame: the blue tube down the left with its grip, the periwinkle around the list.
        var frame = SKRect.Create(6, 0, width - 6, height);
        using (var shape = Shapes.Round(frame, 8))
        {
            canvas.Fill(shape, Gradients.Linear(frame, Unit.Top, Unit.Bottom, (0, SKColors.White), (0.02f, Hex(0xC9DAEF)), (0.05f, CoronaColors.Frame), (0.95f, CoronaColors.Frame),
                (1, CoronaColors.FrameEdge)));
            canvas.Stroke(shape, Hex(0x73767B), 0.8f);
        }
        var tube = SKRect.Create(0, 0, 13, height);
        canvas.Fill(tube, Gradients.Horizontal(tube, CoronaColors.Tube));
        canvas.Stroke(Shapes.Rect(tube), Hex(0x45549D), 0.6f);
        Grip(canvas, new SKPoint(3.5f, height / 2 - 14));
        if (interactive)
        {
            RoundKey(ui, "corona.shuffle", new SKPoint(26, 9), 19, controls.IsShuffled ? "Shuffle: On" : "Shuffle: Off", controls.ToggleShuffle,
                center => Glyphs.Draw(canvas, Glyph.Shuffle, center, 9, controls.IsShuffled ? Hex(0x2B6CD8) : CoronaColors.Navy));
        }
        var box = SKRect.Create(52, 11, width - 110, 15);
        using (var shape = Shapes.Round(box, 2))
        {
            canvas.Fill(shape, SKColors.White);
            canvas.Stroke(shape, Hex(0x7F9DB9), 0.6f);
        }
        using (var font = Fonts.System(8.5f)) Lettering.Draw(canvas, "Now Playing", box.Left + 4, Lettering.Baseline(font, box.MidY), font, SKColors.Black);
        Glyphs.Draw(canvas, Glyph.ChevronDown, new SKPoint(box.Right - 7, box.MidY), 7, CoronaColors.Navy);
        var close = SKRect.Create(width - 22, 11, 15, 15);
        if (interactive) ui.Press("corona.hidePlaylist", close, () => shows.Value = false, title: "Hide Playlist");
        Glyphs.Draw(canvas, Glyph.Close, new SKPoint(close.MidX, close.MidY), 9, CoronaColors.Navy);
        // The list: white on black, the song playing in bold green.
        var list = SKRect.Create(26, 34, width - 37, height - 46);
        canvas.Fill(list, SKColors.Black);
        if (!showsOverlay && interactive) PcPlayer.List(ui, "corona.list", list, entries, current, playlist?.Play, 13, 9, SKColors.White, CoronaColors.Green, true, false, true);
        canvas.Stroke(Shapes.Rect(SKRect.Inflate(list, 0.2f, 0.2f)), CoronaColors.FrameDark, 0.8f);
        return list;
    }
}
