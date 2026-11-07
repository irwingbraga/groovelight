using SkiaSharp;
using static Groovelight.Skins.Colors;

namespace Groovelight.Skins;

/// <summary>
/// Now Playing as the vintage player chosen, filling the window (the Mac's SkinDeck): a turntable on a walnut plinth, a
/// cassette deck of brushed aluminum, a CD player in black, or the PC Player, with their own keys, knobs, switches,
/// meters and displays working the app's player. The player itself (the stage) and its controls (the panel) are side
/// by side in a wide window, one above the other in a tall one.
///
/// The host draws it each frame (<see cref="Draw"/>) and passes the pointer to <see cref="Ui"/>. While
/// <see cref="ShowsOverlay"/> (the lyrics, Up Next), the stage is smoked glass and <see cref="OverlayRect"/> says where
/// the host puts them.
/// </summary>
public sealed class SkinDeck
{
    public DeckUi Ui { get; } = new();
    public NowPlayingSkin Skin { get; set; } = NowPlayingSkin.Vinyl;
    public PcTheme Theme { get; set; }
    public CassetteDesign Cassette { get; set; } = CassetteDesign.BuiltIn[0];
    public CassettePictures Pictures { get; set; } = new();
    /// <summary>Room left at the top for the app's own buttons, laid over the deck.</summary>
    public float ChromeInset { get; set; } = 56;
    public bool ShowsOverlay { get; set; }
    /// <summary>The queue for the PC Player's playlist.</summary>
    public SkinPlaylist? Playlist { get; set; }
    /// <summary>Corona's screen: 0 the spectrum's bars, 1 the cover (kept by the host).</summary>
    public SkinBinding<int> CoronaVisualization { get; set; } = new(() => 0, _ => { });
    /// <summary>Where the lyrics or Up Next go while <see cref="ShowsOverlay"/> (null when not shown).</summary>
    public SKRect? OverlayRect { get; private set; }

    /// <summary>Draws the deck filling <paramref name="size"/> (points), at <paramref name="now"/> seconds of a steady clock.</summary>
    public void Draw(SKCanvas canvas, SKSize size, double now, SkinPlayback playback, DeckControls controls)
    {
        Ui.Begin(canvas, now);
        OverlayRect = null;
        // What the player is made of never moves: drawn once for the size.
        canvas.Image(Ui.Cached($"surface:{Skin}", size, layer => Surface(layer, size)), SKRect.Create(size));
        if (Skin == NowPlayingSkin.PcPlayer)
        {
            OverlayRect = Theme == PcTheme.Corona
                ? Corona.Draw(Ui, size, ChromeInset, playback, controls, Playlist, ShowsOverlay, CoronaVisualization)
                : PcPlayer.Draw(Ui, size, ChromeInset, playback, controls, Playlist, ShowsOverlay);
        }
        else
        {
            var aspect = Skin == NowPlayingSkin.Cassette && !ShowsOverlay ? (float)Cassette.ResolvedGeometry.AspectRatio * 0.92f : 1;
            var (stage, panel) = Regions(size, ChromeInset, aspect);
            if (ShowsOverlay) OverlayRect = SmokedGlass(canvas, stage);
            else
            {
                switch (Skin)
                {
                    case NowPlayingSkin.Cassette: Stages.Cassette(Ui, stage, Cassette, Pictures, playback); break;
                    case NowPlayingSkin.CompactDisc: Stages.Disc(Ui, stage, playback); break;
                    default: Stages.Turntable(Ui, stage, playback, controls.Seek); break;
                }
            }
            switch (Skin)
            {
                case NowPlayingSkin.Cassette: Panels.Cassette(Ui, panel, playback, controls); break;
                case NowPlayingSkin.CompactDisc: Panels.Disc(Ui, panel, playback, controls); break;
                default: Panels.Turntable(Ui, panel, playback, controls); break;
            }
        }
        Ui.End();
    }

    /// <summary>The lyrics' or Up Next's place: smoked glass set into the player. Returns where they go.</summary>
    private static SKRect SmokedGlass(SKCanvas canvas, SKRect stage)
    {
        using var shape = Shapes.Round(stage, 18);
        canvas.Fill(shape, Black(0.78));
        canvas.InnerShadow(shape, SKColors.Black, 10, 6);
        canvas.Border(stage, 18, r => Gradients.Vertical(r, Black(0.6), White(0.35)), 1.5f);
        return SKRect.Inflate(stage, -16, -16);
    }

    /// <summary>What the player is made of, to the window's edges.</summary>
    private void Surface(SKCanvas canvas, SKSize size)
    {
        var all = SKRect.Create(size);
        switch (Skin)
        {
            case NowPlayingSkin.Cassette:
                Textures.Fill(canvas, all, SkinTexture.Aluminum, 0.14);
                canvas.Fill(all, Gradients.Vertical(all, White(0.18), Clear, Black(0.15)));
                // Walnut cheeks at the sides.
                foreach (var cheek in new[] { SKRect.Create(0, 0, 10, size.Height), SKRect.Create(size.Width - 10, 0, 10, size.Height) })
                {
                    Textures.Fill(canvas, cheek, SkinTexture.Walnut);
                    canvas.Fill(cheek, Gradients.Horizontal(cheek, Black(0.4), White(0.1), Black(0.4)));
                }
                break;
            case NowPlayingSkin.PcPlayer:
                // The desktop of the time: a green hill under a blue sky.
                canvas.ImageFill(Textures.Image(SkinTexture.Hill), all);
                break;
            case NowPlayingSkin.CompactDisc:
                Textures.Fill(canvas, all, SkinTexture.Aluminum, -0.12, Gray(0.32));
                canvas.Fill(all, Gradients.Vertical(all, White(0.08), Clear, Black(0.3)));
                break;
            default:
                Textures.Fill(canvas, all, SkinTexture.Walnut, -0.04);
                canvas.Fill(all, Gradients.Radial(all, new Unit(0.4f, 0.25f), 50, 900, [White(0.08), Black(0.45)]));
                break;
        }
    }

    /// <summary>
    /// Where the stage and the panel go: side by side in a clearly wide window, one above the other otherwise.
    /// <paramref name="stageAspect"/> is the stage's width over its height (the cassette's door is wide, the others square).
    /// </summary>
    internal static (SKRect Stage, SKRect Panel) Regions(SKSize size, float top, float stageAspect = 1)
    {
        var margin = Math.Max(12, Math.Min(size.Width, size.Height) * 0.025f);
        var area = SKRect.Create(margin, top, Math.Max(size.Width - margin * 2, 1), Math.Max(size.Height - top - margin, 1));
        if (area.Width >= area.Height * 1.25f)
        {
            var width = Math.Min(area.Height * stageAspect, area.Width * 0.58f);
            return (SKRect.Create(area.Left, area.Top, width, area.Height), SKRect.Create(area.Left + width + margin, area.Top, area.Width - width - margin, area.Height));
        }
        var height = Math.Min(area.Width / stageAspect, area.Height * 0.56f);
        return (SKRect.Create(area.Left, area.Top, area.Width, height), SKRect.Create(area.Left, area.Top + height + margin, area.Width, area.Height - height - margin));
    }

    /// <summary>How much a panel drawn for <paramref name="reference"/> grows (or shrinks) to fill <paramref name="size"/>.</summary>
    internal static float Scale(SKSize size, SKSize reference) =>
        Math.Clamp(Math.Min(size.Width / reference.Width, size.Height / reference.Height), 0.62f, 1.9f);
}

/// <summary>The players' panels: the turntable's plate, the cassette deck's front, the CD player's front.</summary>
internal static class Panels
{
    /// <summary>
    /// Rows one under the other, the room left over shared between them (up to <paramref name="maxHeight"/>), so a panel
    /// fills a tall window instead of sitting in its middle. Returns each row's top and the whole height.
    /// </summary>
    private static (float[] Tops, float Height) Spread(float[] heights, float spacing, float available, float maxHeight)
    {
        var natural = heights.Sum() + spacing * Math.Max(heights.Length - 1, 0);
        var height = Math.Max(natural, Math.Min(available, maxHeight));
        var gap = spacing + (heights.Length > 1 ? Math.Max(height - natural, 0) / (heights.Length - 1) : 0);
        var tops = new float[heights.Length];
        var y = 0f;
        for (var index = 0; index < heights.Length; index++)
        {
            tops[index] = y;
            y += heights[index] + gap;
        }
        return (tops, height);
    }

    private static string RepeatCaption(DeckRepeat mode) => mode switch { DeckRepeat.All => "REPEAT ALL", DeckRepeat.One => "REPEAT ONE", _ => "REPEAT OFF" };

    /// <summary>Repeat's toggle: down for off, the middle for all, up for one.</summary>
    private static int RepeatPosition(DeckRepeat mode) => mode switch { DeckRepeat.All => 1, DeckRepeat.One => 0, _ => 2 };

    private static Action Scan(SkinPlayback playback, DeckControls controls, double direction, bool cue = false) => () =>
    {
        if (cue) controls.TapeCue?.Invoke();
        controls.Seek(Math.Clamp(playback.Time() + direction * DeckControls.ScanStep, 0, Math.Max(playback.Duration - 1, 0)));
    };

    /// <summary>A captioned control's width: its own or its caption's.</summary>
    private static float Captioned(float width, string caption, float scale) => Math.Max(width, Lettering.EngravedWidth(caption, 7.5f * scale));

    /// <summary>The love cap at the foot of a panel.</summary>
    private static void LoveCap(DeckUi ui, SKPoint center, DeckControls controls)
    {
        var loved = controls.Love?.Value == true;
        Controls.DeckCap(ui, "love", center, (loved ? "Unlove" : "Love") + controls.LoveHint, loved ? Glyph.HeartFilled : Glyph.Heart,
            loved ? Rgb(0.84, 0.15, 0.24) : null, () => { if (controls.Love is { } love) love.Value = !love.Value; }, controls.Love is not null);
    }

    // MARK: Turntable

    /// <summary>The turntable's aluminum plate: the song in a receiver's dial window, the keys, the time, shuffle and repeat, the volume.</summary>
    public static void Turntable(DeckUi ui, SKRect bounds, SkinPlayback playback, DeckControls controls)
    {
        var canvas = ui.Canvas;
        var s = SkinDeck.Scale(bounds.Size, new SKSize(360, 290));
        var caption = Controls.CaptionHeight(s);
        float[] heights = [DialHeight(s), 52 * s + 5 * s + caption, (controls.Volume is null ? 44 : 66) * s + 5 * s + caption, 40];
        var (tops, height) = Spread(heights, 14 * s, bounds.Height - 32 * s, 290 * s * 1.5f);
        var width = Math.Min(bounds.Width, 360 * s);
        var plate = Shapes.CenteredRect(new SKPoint(bounds.MidX, bounds.MidY), width, height + 32 * s);
        var plateArea = SKRect.Inflate(plate, 12 * s, 12 * s);
        canvas.Image(ui.Cached("plate", plateArea.Size, layer =>
        {
            layer.Translate(-plateArea.Left, -plateArea.Top);
            Materials.Plate(layer, plate, SkinTexture.Aluminum, 10 * s, 0.12, screws: 9 * s);
        }), plateArea);
        var left = plate.Left + 20 * s;
        var right = plate.Right - 20 * s;
        var y0 = plate.Top + 16 * s;
        DialWindow(ui, SKRect.Create(left, y0 + tops[0], right - left, heights[0]), playback, controls.Seek, s);
        // The keys and the time, along their foot.
        var foot = y0 + tops[1] + heights[1] - caption - 5 * s;
        var x = left;
        void Key(string id, string captionText, string title, Glyph glyph, float keyWidth, float keyHeight, Action tap, Action? hold, bool? lamp = null)
        {
            var slot = Captioned(keyWidth, captionText, s);
            var rect = SKRect.Create(x + (slot - keyWidth) / 2, foot - keyHeight, keyWidth, keyHeight);
            Controls.MetalKey(ui, id, rect, title, glyph, tap, hold, lamp);
            Controls.Caption(canvas, captionText, rect, s);
            x += slot + 12 * s;
        }
        Key("previous", "PREV", "Previous", Glyph.Previous, 54 * s, 44 * s, controls.Previous, Scan(playback, controls, -1));
        Key("startStop", "START · STOP", playback.IsPlaying ? "Stop" : "Start", playback.IsPlaying ? Glyph.Stop : Glyph.Play, 92 * s, 52 * s, controls.PlayPause, null,
            playback.IsPlaying);
        Key("next", "NEXT", "Next", Glyph.Next, 54 * s, 44 * s, controls.Next, Scan(playback, controls, 1));
        var clockSlot = Captioned(Controls.LedClockWidth(15 * s), "TIME", s);
        Controls.Caption(canvas, "TIME", Controls.LedClock(ui, new SKPoint(right - clockSlot / 2, foot), 15 * s, playback), s);
        if (playback.IsPlaying) ui.Animate();
        Switches(ui, y0 + tops[2] + heights[2] - caption - 5 * s, left, right, s, 44 * s, 66 * s, "VOLUME", controls);
        LoveCap(ui, new SKPoint(plate.MidX, y0 + tops[3] + 20), controls);
    }

    /// <summary>Shuffle and repeat toggles on the left, the volume knob on the right, along their foot.</summary>
    private static void Switches(DeckUi ui, float foot, float left, float right, float s, float toggle, float knob, string knobCaption, DeckControls controls,
                                 bool onDark = false)
    {
        var canvas = ui.Canvas;
        var x = left;
        var shuffleSlot = Captioned(toggle, "SHUFFLE", s);
        var shuffle = SKRect.Create(x + (shuffleSlot - toggle) / 2, foot - toggle, toggle, toggle);
        Controls.ToggleSwitch(ui, "shuffle", new SKPoint(shuffle.MidX, shuffle.MidY), toggle, controls.IsShuffled ? "Shuffle: On" : "Shuffle: Off",
            controls.IsShuffled ? 0 : 1, controls.ToggleShuffle);
        Controls.Caption(canvas, "SHUFFLE", shuffle, s, onDark);
        x += shuffleSlot + 18 * s;
        var repeatCaption = RepeatCaption(controls.RepeatMode);
        var repeatSlot = Captioned(toggle, "REPEAT ALL", s);
        var repeat = SKRect.Create(x + (repeatSlot - toggle) / 2, foot - toggle, toggle, toggle);
        Controls.ToggleSwitch(ui, "repeat", new SKPoint(repeat.MidX, repeat.MidY), toggle, "Repeat: " + repeatCaption[7..].ToLowerInvariant(),
            RepeatPosition(controls.RepeatMode), controls.CycleRepeat, 3);
        Controls.Caption(canvas, repeatCaption, repeat, s, onDark);
        if (controls.Volume is not { } volume) return;
        var knobSlot = Captioned(knob, knobCaption, s);
        var knobRect = SKRect.Create(right - knobSlot + (knobSlot - knob) / 2, foot - knob, knob, knob);
        Controls.Knob(ui, "volume", new SKPoint(knobRect.MidX, knobRect.MidY), knob, "Volume", volume, onDark);
        Controls.Caption(canvas, knobCaption, knobRect, s, onDark);
    }

    private static float DialHeight(float s) => 2 * s + 9 * s + 16 * s * 1.2f + 3 * s + 10.5f * s * 1.2f + 3 * s + 4 * s + 20 * s + 6 * s + 2 * s;

    private static readonly SKColor DialLettering = Rgb(1, 0.93, 0.78);
    private static readonly SKColor DialGlow = Rgb(1, 0.6, 0.18);

    /// <summary>
    /// A receiver's dial window, set into the plate: smoked glass lit warm from behind by its lamps, the song in cream
    /// lettering, the artist and the album under it, and the printed scale along the bottom, its red pointer where the
    /// song is (dragged along the scale, it goes there).
    /// </summary>
    private static void DialWindow(DeckUi ui, SKRect frame, SkinPlayback playback, Action<double> seek, float s)
    {
        var canvas = ui.Canvas;
        var corner = 5 * s;
        using (var well = Shapes.Round(frame, corner + 2 * s)) canvas.Fill(well, Black(0.12));
        var glass = SKRect.Inflate(frame, -2 * s, -2 * s);
        using var shape = Shapes.Round(glass, corner);
        canvas.Save();
        canvas.ClipPath(shape, antialias: true);
        // The glass, dark, warmed by the lamps behind it (brightest low in the middle), darker at its ends.
        canvas.Fill(glass, Rgb(0.07, 0.045, 0.025));
        canvas.Fill(glass, Gradients.Elliptical(glass, new Unit(0.5f, 0.85f), 0, 0.75f, [DialGlow.Opacity(0.42), DialGlow.Opacity(0.12), Clear]));
        canvas.Fill(glass, Gradients.Horizontal(glass, Black(0.55), Clear, Clear, Black(0.55)));
        var subtitle = string.Join("  ·  ", new[] { playback.Artist, playback.Album }.Where(part => part.Length > 0));
        var left = glass.Left + 12 * s;
        var room = glass.Width - 24 * s;
        using var titleFont = Fonts.System(16 * s, SKFontStyleWeight.Medium, FontWidth.Expanded);
        using var subtitleFont = Fonts.System(10.5f * s, SKFontStyleWeight.Normal, FontWidth.Expanded);
        var y = glass.Top + 9 * s;
        var titleBaseline = y - titleFont.Metrics.Ascent;
        Lettering.Glowing(canvas, Lettering.Fit(playback.Title, titleFont, room, 0.6f * s), left, titleBaseline, titleFont, DialLettering, DialGlow.Opacity(0.85), 3 * s,
            tracking: 0.6f * s);
        y += 16 * s * 1.2f + 3 * s;
        Lettering.Glowing(canvas, Lettering.Fit(subtitle, subtitleFont, room, 0.5f * s), left, y - subtitleFont.Metrics.Ascent, subtitleFont, DialLettering.Opacity(0.72),
            DialGlow.Opacity(0.6), 3 * s, tracking: 0.5f * s);
        y += 10.5f * s * 1.2f + 3 * s + 4 * s;
        // The printed scale: fine ticks, longer every fifth, and the red pointer where the song is.
        var scale = SKRect.Create(left, y, room, 20 * s);
        for (var tick = 0; tick <= 50; tick++)
        {
            var x = scale.Left + scale.Width * tick / 50;
            var isLong = tick % 5 == 0;
            canvas.Line(new SKPoint(x, scale.Top + scale.Height * 0.35f), new SKPoint(x, scale.Top + scale.Height * (isLong ? 0.95f : 0.7f)),
                DialLettering.Opacity(isLong ? 0.75 : 0.45), isLong ? 1 : 0.6f);
        }
        canvas.Line(new SKPoint(scale.Left, scale.Top + scale.Height * 0.35f), new SKPoint(scale.Right, scale.Top + scale.Height * 0.35f), DialLettering.Opacity(0.5), 0.6f);
        ui.Drag("dial", SKRect.Inflate(scale, 0, 4 * s), drag => ui.SetState("dial.drag", (double)Math.Clamp((drag.Location.X - scale.Left) / scale.Width, 0, 1)), _ =>
        {
            var dragged = ui.State("dial.drag", () => -1.0);
            if (dragged >= 0 && playback.Duration > 0) seek(Math.Min(dragged, 0.995) * playback.Duration);
            ui.ClearState("dial.drag");
        }, title: "Position");
        var dragging = ui.State("dial.drag", () => -1.0);
        if (dragging < 0) ui.ClearState("dial.drag");
        var progress = dragging >= 0 ? dragging : Controls.Ease(ui, "dial.pointer", (float)playback.Progress, 0.08);
        var pointerWidth = Math.Max(2, 2.2f * s);
        var pointer = SKRect.Create(scale.Left + scale.Width * (float)progress - pointerWidth / 2, scale.Top - scale.Height * 0.15f, pointerWidth, scale.Height * 1.2f);
        using (var needle = Shapes.Capsule(pointer))
        {
            canvas.Shadow(needle, Rgb(1, 0.2, 0.1), 3 * s);
            canvas.Fill(needle, Rgb(1, 0.22, 0.12));
        }
        canvas.Restore();
        // The glass's reflection across its top, and its edge.
        canvas.Fill(shape, Gradients.Linear(glass, Unit.Top, Unit.Bottom, (0, White(0.13)), (0.42f, White(0.04)), (0.46f, Clear)));
        canvas.Border(glass, corner, r => Gradients.Vertical(r, Black(0.7), White(0.6)), 1.5f * s);
    }

    // MARK: Cassette deck

    /// <summary>The cassette deck's controls: its name, the VU meters and the counter, the piano keys, the switches and the level.</summary>
    public static void Cassette(DeckUi ui, SKRect bounds, SkinPlayback playback, DeckControls controls)
    {
        var canvas = ui.Canvas;
        var s = SkinDeck.Scale(bounds.Size, new SKSize(360, 300));
        var caption = Controls.CaptionHeight(s);
        var isPaused = !playback.IsPlaying && playback.Time() > 0.5;
        float[] heights = [16 * s, 64 * s, 72 * s, (controls.Volume is null ? 42 : 64) * s + 5 * s + caption, 40];
        var (tops, height) = Spread(heights, 14 * s, bounds.Height, 300 * s * 1.5f);
        var width = Math.Min(bounds.Width, 376 * s) - 16 * s;
        var left = bounds.MidX - width / 2;
        var right = left + width;
        var y0 = bounds.MidY - height / 2;
        // The name, and what it is.
        using (var name = Fonts.System(13 * s, SKFontStyleWeight.Black, FontWidth.Expanded))
        {
            var baseline = y0 + tops[0] - name.Metrics.Ascent;
            Lettering.Draw(canvas, "GROOVELIGHT", left, baseline + 0.8f, name, White(0.6));
            Lettering.Draw(canvas, "GROOVELIGHT", left, baseline, name, Black(0.7));
            var kind = Lettering.EngravedWidth("STEREO CASSETTE DECK", 7.5f * s);
            Lettering.Engraved(canvas, "STEREO CASSETTE DECK", new SKPoint(right - kind / 2, baseline - 7.5f * s * 0.35f), 7.5f * s);
        }
        // The meters and the counter.
        var meters = y0 + tops[1];
        Controls.VuMeter(ui, "vu.left", SKRect.Create(left, meters, 104 * s, 64 * s), 0, playback);
        Controls.VuMeter(ui, "vu.right", SKRect.Create(left + 114 * s, meters, 104 * s, 64 * s), 1, playback);
        var counter = SKRect.Create(right - 92 * s, meters + 64 * s - caption - 5 * s - 36 * s, 92 * s, 36 * s);
        Materials.Recess(canvas, counter, 4 * s, Gray(0.12), 3);
        Controls.TapeCounter(ui, SKRect.Inflate(counter, -4 * s, -4 * s), playback);
        Controls.Caption(canvas, "COUNTER", counter, s);
        // The piano keys.
        var key = new SKSize(54 * s, 62 * s);
        var keysWidth = key.Width * 5 + 4 * s * 4 + 10 * s;
        var keys = SKRect.Create(bounds.MidX - keysWidth / 2, y0 + tops[2], keysWidth, 72 * s);
        using (var bed = Shapes.Round(keys, 6 * s)) canvas.Fill(bed, Black(0.75));
        var x = keys.Left + 5 * s;
        void Key(string id, string title, Glyph glyph, Action tap, Action? hold = null, bool latched = false, SKColor? accent = null)
        {
            Controls.PianoKey(ui, id, SKRect.Create(x, keys.Top + 5 * s, key.Width, key.Height), title, glyph, tap, hold, latched, accent);
            x += key.Width + 4 * s;
        }
        Key("rewind", "Rewind", Glyph.Rewind, controls.Previous, Scan(playback, controls, -1, cue: true));
        Key("play", "Play", Glyph.Play, () => { if (!playback.IsPlaying) controls.PlayPause(); }, latched: playback.IsPlaying, accent: SKColors.Green.Opacity(0.8));
        Key("fastForward", "Fast Forward", Glyph.FastForward, controls.Next, Scan(playback, controls, 1, cue: true));
        Key("stop", "Stop", Glyph.Stop, () =>
        {
            if (playback.IsPlaying) controls.PlayPause();
            controls.Seek(0);
        });
        Key("pause", "Pause", Glyph.Pause, controls.PlayPause, latched: isPaused, accent: SKColors.Orange.Opacity(0.8));
        Switches(ui, y0 + tops[3] + heights[3] - caption - 5 * s, left, right, s, 42 * s, 64 * s, "OUTPUT LEVEL", controls);
        LoveCap(ui, new SKPoint(bounds.MidX, y0 + tops[4] + 20), controls);
    }

    // MARK: CD player

    private static float DisplayHeight(float s) => 14 * s * 2 + Math.Max(3 * 8 * s * 1.25f + 8 * s, 34 * s * 1.2f) + 8 * s + (15 * s * 1.3f + 8 * s) * 2 + 8 * s;

    /// <summary>The CD player's front: the fluorescent display (time, the song stepping through, the position bar), the round keys and the volume dial.</summary>
    public static void Disc(DeckUi ui, SKRect bounds, SkinPlayback playback, DeckControls controls)
    {
        var canvas = ui.Canvas;
        var s = SkinDeck.Scale(bounds.Size, new SKSize(360, 300));
        var caption = Controls.CaptionHeight(s);
        float[] heights = [16 * s, DisplayHeight(s), (controls.Volume is null ? 58 : 70) * s + 5 * s + caption, Math.Max(30 * s + 5 * s + caption, 40)];
        var (tops, height) = Spread(heights, 16 * s, bounds.Height, 300 * s * 1.5f);
        var width = Math.Min(bounds.Width, 376 * s) - 16 * s;
        var left = bounds.MidX - width / 2;
        var right = left + width;
        var y0 = bounds.MidY - height / 2;
        using (var name = Fonts.System(13 * s, SKFontStyleWeight.Black, FontWidth.Expanded))
        {
            var baseline = y0 + tops[0] - name.Metrics.Ascent;
            Lettering.Draw(canvas, "GROOVELIGHT", left, baseline, name, White(0.85));
            var kind = Lettering.EngravedWidth("COMPACT DISC PLAYER", 7.5f * s);
            Lettering.Engraved(canvas, "COMPACT DISC PLAYER", new SKPoint(right - kind / 2, baseline - 7.5f * s * 0.35f), 7.5f * s, onDark: true);
        }
        Display(ui, SKRect.Create(left, y0 + tops[1], width, heights[1]), playback, controls, s);
        // The round keys, the volume dial.
        var row = y0 + tops[2];
        var middle = row + (heights[2] - caption - 5 * s) / 2;
        var x = left;
        void Key(string id, string title, Glyph glyph, float diameter, Action tap, Action? hold = null)
        {
            Controls.RoundKey(ui, id, new SKPoint(x + diameter / 2, middle), diameter, title, glyph, tap, hold);
            x += diameter + 12 * s;
        }
        Key("previous", "Previous", Glyph.Previous, 46 * s, controls.Previous, Scan(playback, controls, -1));
        Key("playPause", playback.IsPlaying ? "Pause" : "Play", Glyph.PlayPause, 58 * s, controls.PlayPause);
        Key("next", "Next", Glyph.Next, 46 * s, controls.Next, Scan(playback, controls, 1));
        Key("stop", "Stop", Glyph.Stop, 40 * s, () =>
        {
            if (playback.IsPlaying) controls.PlayPause();
            controls.Seek(0);
        });
        if (controls.Volume is { } volume)
        {
            var knob = 70 * s;
            var slot = Captioned(knob, "VOLUME", s);
            var rect = SKRect.Create(right - slot + (slot - knob) / 2, row, knob, knob);
            Controls.Knob(ui, "volume", new SKPoint(rect.MidX, rect.MidY), knob, "Volume", volume, onDark: true);
            Controls.Caption(canvas, "VOLUME", rect, s, onDark: true);
        }
        // Random and repeat, and the love cap.
        var modes = y0 + tops[3];
        x = left;
        foreach (var (id, captionText, title, glyph, tap) in new[]
        {
            ("random", "RANDOM", controls.IsShuffled ? "Shuffle On" : "Shuffle Off", Glyph.Shuffle, controls.ToggleShuffle),
            ("repeat", "REPEAT", RepeatCaption(controls.RepeatMode) switch { "REPEAT ALL" => "Repeat All", "REPEAT ONE" => "Repeat One", _ => "Repeat Off" },
                controls.RepeatMode == DeckRepeat.One ? Glyph.RepeatOne : Glyph.Repeat, controls.CycleRepeat),
        })
        {
            var diameter = 30 * s;
            var slot = Captioned(diameter, captionText, s);
            var rect = SKRect.Create(x + (slot - diameter) / 2, modes, diameter, diameter);
            Controls.RoundKey(ui, id, new SKPoint(rect.MidX, rect.MidY), diameter, title, glyph, tap);
            Controls.Caption(canvas, captionText, rect, s, onDark: true);
            x += slot + 12 * s;
        }
        LoveCap(ui, new SKPoint(right - 20, modes + Math.Max(30 * s + 5 * s + caption, 40) / 2), controls);
    }

    private static void Display(DeckUi ui, SKRect rect, SkinPlayback playback, DeckControls controls, float s)
    {
        var canvas = ui.Canvas;
        Materials.Recess(canvas, rect, 8 * s, Gradients.Vertical(rect, Rgb(0.02, 0.08, 0.08), Rgb(0.01, 0.04, 0.05)), 5);
        var inner = SKRect.Inflate(rect, -14 * s, -14 * s);
        using var indicatorFont = Fonts.System(8 * s, SKFontStyleWeight.Bold, FontWidth.Expanded);
        var topHeight = Math.Max(3 * 8 * s * 1.25f + 8 * s, 34 * s * 1.2f);
        var y = inner.Top + (topHeight - (3 * 8 * s * 1.25f + 8 * s)) / 2;
        foreach (var (text, lit) in new[]
        {
            (playback.IsPlaying ? "PLAY" : "PAUSE", true), ("RANDOM", controls.IsShuffled),
            (controls.RepeatMode == DeckRepeat.One ? "REPEAT 1" : "REPEAT", controls.RepeatMode != DeckRepeat.Off),
        })
        {
            var baseline = y - indicatorFont.Metrics.Ascent;
            if (lit) Lettering.Glowing(canvas, text, inner.Left, baseline, indicatorFont, Controls.Vfd, Controls.Vfd.Opacity(0.7), 3);
            else Lettering.Draw(canvas, text, inner.Left, baseline, indicatorFont, Controls.Vfd.Opacity(0.1));
            y += 8 * s * 1.25f + 4 * s;
        }
        using (var digits = Fonts.Digits(34 * s))
        {
            var width = digits.MeasureText("88:88");
            Controls.VfdText(canvas, SkinInfo.ClockText(playback.Time()), "88:88", inner.Right - width, Lettering.Baseline(digits, inner.Top + topHeight / 2), digits);
        }
        y = inner.Top + topHeight + 8 * s;
        using (var letters = Fonts.Letters(15 * s))
        {
            Controls.VfdMarquee(ui, playback.Title, 14, inner.Left, y - letters.Metrics.Ascent, 15 * s, playback.IsPlaying);
            y += 15 * s * 1.3f + 8 * s;
            Controls.VfdMarquee(ui, playback.Artist, 14, inner.Left, y - letters.Metrics.Ascent, 15 * s, playback.IsPlaying);
            y += 15 * s * 1.3f + 8 * s;
        }
        Controls.VfdBar(ui, "position", SKRect.Create(inner.Left, y, inner.Width, 8 * s), playback, controls.Seek);
        using var glare = Shapes.Round(rect, 8 * s);
        canvas.Fill(glare, Gradients.Linear(rect, Unit.TopLeading, Unit.Center, [White(0.1), Clear]));
    }
}
