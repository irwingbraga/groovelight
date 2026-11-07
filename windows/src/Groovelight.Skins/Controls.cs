using SkiaSharp;
using static Groovelight.Skins.Colors;

namespace Groovelight.Skins;

/// <summary>The players' keys, knobs, switches, meters, counters and displays (the Mac's DeckControls).</summary>
internal static class Controls
{
    /// <summary>The color of a vacuum fluorescent display's lit segments.</summary>
    public static readonly SKColor Vfd = Rgb(0.45, 1, 0.9);

    /// <summary>The height a caption takes under a control.</summary>
    public static float CaptionHeight(float scale) => 7.5f * scale * 1.25f;

    /// <summary>A caption engraved under a control whose box is <paramref name="control"/>.</summary>
    public static void Caption(SKCanvas canvas, string caption, SKRect control, float scale, bool onDark = false) =>
        Lettering.Engraved(canvas, caption, new SKPoint(control.MidX, control.Bottom + 5 * scale + CaptionHeight(scale) / 2), 7.5f * scale, onDark);

    // MARK: Keys

    /// <summary>The turntable's square aluminum key, its symbol engraved, a lamp at its corner when it has one.</summary>
    public static void MetalKey(DeckUi ui, string id, SKRect rect, string title, Glyph glyph, Action tap, Action? hold = null, bool? lamp = null)
    {
        var canvas = ui.Canvas;
        var pressed = ui.Press(id, rect, tap, hold, title);
        var corner = Math.Min(rect.Width, rect.Height) * 0.12f;
        var h = rect.Height;
        using (var hole = Shapes.Round(SKRect.Inflate(rect, h * 0.04f, h * 0.04f), corner)) canvas.Fill(hole, Black(0.75));
        var face = rect;
        face.Offset(0, pressed ? h * 0.03f : 0);
        using var shape = Shapes.Round(face, corner);
        canvas.Shadow(shape, Black(pressed ? 0.2 : 0.6), pressed ? 1 : h * 0.08f, 0, pressed ? 0.5f : h * 0.06f);
        Textures.Fill(canvas, shape, SkinTexture.Aluminum, pressed ? 0.02 : 0.12);
        canvas.Fill(shape, Gradients.Vertical(face, White(pressed ? 0.05 : 0.3), Clear, Black(0.25)));
        canvas.Border(face, corner, r => Gradients.Vertical(r, White(0.8), Black(0.4)), 1);
        var center = new SKPoint(face.MidX, face.MidY);
        Glyphs.Draw(canvas, glyph, center + new SKPoint(0, 0.8f), h * 0.36f, White(0.6));
        Glyphs.Draw(canvas, glyph, center, h * 0.36f, Black(0.6));
        if (lamp is { } on)
        {
            var side = h * 0.14f;
            Materials.PilotLamp(canvas, SKRect.Create(rect.Right - h * 0.1f - side, rect.Top + h * 0.1f, side, side), on);
        }
    }

    /// <summary>A cassette deck's piano key: long, its face catching the light, latched down while what it does goes on.</summary>
    public static void PianoKey(DeckUi ui, string id, SKRect rect, string title, Glyph glyph, Action tap, Action? hold = null, bool latched = false, SKColor? accent = null)
    {
        var canvas = ui.Canvas;
        var pressed = ui.Press(id, rect, tap, hold, title);
        var down = pressed || latched;
        var size = rect.Size;
        var travel = size.Height * (pressed ? 0.14f : latched ? 0.1f : 0);
        var corner = size.Width * 0.1f;
        using (var slot = Shapes.Round(rect, corner)) canvas.Fill(slot, Black(0.85));
        canvas.Save();
        using (var clip = Shapes.Round(rect, corner)) canvas.ClipPath(clip, antialias: true);
        var left = rect.Left + size.Width * 0.04f;
        var width = size.Width * 0.92f;
        var top = rect.Top + travel;
        var topHeight = size.Height * 0.32f - travel * 0.6f;
        var topRect = SKRect.Create(left, top, width, topHeight);
        var faceRect = SKRect.Create(left, top + topHeight, width, size.Height - topHeight);
        using (var all = Shapes.Round(SKRect.Create(left, top, width, size.Height), corner)) canvas.Shadow(all, Black(0.5), 2, 0, 2);
        using (var cap = Shapes.Build(b => b.AddRoundRect(new SKRoundRect(SKRect.Create(left, top, width, topHeight + corner), corner))))
        {
            canvas.Save();
            canvas.ClipRect(topRect);
            canvas.Fill(cap, Gradients.Vertical(topRect, Gray(down ? 0.35 : 0.55), Gray(down ? 0.22 : 0.4)));
            canvas.Restore();
        }
        using (var face = Shapes.Build(b => b.AddRoundRect(new SKRoundRect(SKRect.Create(left, faceRect.Top - corner, width, faceRect.Height + corner), corner))))
        {
            canvas.Save();
            canvas.ClipRect(faceRect);
            Textures.Fill(canvas, face, SkinTexture.Aluminum, down ? 0 : 0.16);
            canvas.Fill(face, Gradients.Vertical(faceRect, White(down ? 0.1 : 0.45), White(0.05), Black(0.3)));
            if (accent is { } color) canvas.Fill(SKRect.Create(left, rect.Top + travel + size.Height - size.Height * 0.06f, width, size.Height * 0.06f), color.Opacity(down ? 0.7 : 0.9));
            canvas.Restore();
        }
        var center = new SKPoint(faceRect.MidX, faceRect.MidY);
        Glyphs.Draw(canvas, glyph, center + new SKPoint(0, 0.8f), size.Width * 0.32f, White(0.5));
        Glyphs.Draw(canvas, glyph, center, size.Width * 0.32f, Black(0.62));
        canvas.Restore();
    }

    /// <summary>A CD player's round key: black rubber in a polished ring, its symbol printed white.</summary>
    public static void RoundKey(DeckUi ui, string id, SKPoint center, float diameter, string title, Glyph glyph, Action tap, Action? hold = null)
    {
        var canvas = ui.Canvas;
        var rect = Shapes.Square(center, diameter);
        var pressed = ui.Press(id, rect, tap, hold, title, round: true);
        using var ring = Shapes.Oval(rect);
        canvas.Shadow(ring, Black(0.7), pressed ? 1 : diameter * 0.06f, 0, pressed ? 0.5f : diameter * 0.04f);
        canvas.Fill(ring, Materials.Spun(center, 0.85, 0.3));
        var face = Shapes.Square(center, diameter * 0.86f * (pressed ? 0.96f : 1));
        using var rubber = Shapes.Oval(face);
        canvas.Fill(rubber, Gradients.Radial(face, new Unit(0.4f, 0.3f), 0, diameter * 0.5f, [Gray(pressed ? 0.1 : 0.26), Gray(0.06)]));
        Glyphs.Draw(canvas, glyph, center, diameter * 0.32f, White(0.85));
    }

    // MARK: Knob and switches

    /// <summary>How far a drag goes to turn the knob from 0 to 10.</summary>
    private const float KnobTravel = 180;

    /// <summary>A knurled aluminum knob, turned by dragging up or down on it (or the wheel), its line on the printed scale around it.</summary>
    public static void Knob(DeckUi ui, string id, SKPoint center, float diameter, string title, SkinBinding<double> value, bool onDark = false)
    {
        var canvas = ui.Canvas;
        var rect = Shapes.Square(center, diameter);
        ui.Drag(id, rect, drag =>
        {
            var start = ui.State(id + ".start", () => value.Value);
            value.Value = Math.Clamp(start - drag.Translation.Y / KnobTravel, 0, 1);
        }, _ => ui.ClearState(id + ".start"), delta => value.Value = Math.Clamp(value.Value + delta * 0.05, 0, 1), $"{title}: {Math.Round(value.Value * 100)}%", round: true);
        // The scale: 0 to 10.
        for (var step = 0; step <= 10; step++)
        {
            var radians = (-135 + step * 27 - 90) * Math.PI / 180;
            var outer = diameter * (step % 5 == 0 ? 0.5f : 0.47f);
            canvas.Line(Shapes.Polar(center, radians, diameter * 0.43), Shapes.Polar(center, radians, outer), onDark ? White(0.7) : Black(0.6), Math.Max(1, diameter * 0.012f));
        }
        var knob = diameter * 0.72f;
        var knobRect = Shapes.Square(center, knob);
        canvas.WithShadow(Black(0.6), diameter * 0.06f, 0, diameter * 0.05f, knobRect, () =>
        {
            using var skirt = Shapes.Oval(knobRect);
            canvas.Fill(skirt, Gray(0.2));
            for (var index = 0; index < 72; index++)
            {
                var radians = index / 72.0 * 2 * Math.PI;
                canvas.Line(Shapes.Polar(center, radians, knob * 0.4), Shapes.Polar(center, radians, knob * 0.5), White(index % 2 == 0 ? 0.55 : 0.15), 1);
            }
            var capRect = Shapes.Square(center, knob - diameter * 0.12f);
            using var cap = Shapes.Oval(capRect);
            canvas.Fill(cap, Materials.Spun(center, 0.95, 0.5));
            canvas.Fill(cap, Gradients.Radial(capRect, Unit.Center, 0, diameter * 0.3f, [White(0.25), Clear]));
            canvas.CircleBorder(capRect, Black(0.3), 1);
            canvas.Save();
            canvas.RotateDegrees((float)(-135 + value.Value * 270), center.X, center.Y);
            using var line = Shapes.Capsule(Shapes.CenteredRect(new SKPoint(center.X, center.Y - diameter * 0.2f), Math.Max(2, diameter * 0.03f), diameter * 0.2f));
            canvas.Fill(line, Black(0.75));
            canvas.Restore();
        });
    }

    /// <summary>A bat-handle toggle on its nut: up for on, down for off; with three positions, down, middle and up.</summary>
    public static void ToggleSwitch(DeckUi ui, string id, SKPoint center, float size, string title, int position, Action tap, int positions = 2)
    {
        var canvas = ui.Canvas;
        ui.Press(id, Shapes.Square(center, size), tap, title: title);
        // Eased toward its place, as the lever snaps over.
        var target = position == 0 ? 1f : positions == 3 && position == 1 ? 0 : -1f;
        var lever = Ease(ui, id + ".lever", target, 0.05);
        var nut = Shapes.Square(center, size * 0.42f);
        using (var shape = Shapes.Oval(nut))
        {
            canvas.Shadow(shape, Black(0.5), 2, 0, 1.5f);
            canvas.Fill(shape, Gradients.Radial(nut, new Unit(0.35f, 0.3f), 0, size * 0.3f, [Gray(0.9), Gray(0.45)]));
            canvas.CircleBorder(nut, Black(0.4), 1);
        }
        var bat = Shapes.CenteredRect(new SKPoint(center.X, center.Y - lever * size * 0.18f), size * 0.17f, size * (0.1f + Math.Abs(lever) * 0.34f));
        using (var shape = Shapes.Capsule(bat))
        {
            canvas.Shadow(shape, Black(0.55), 2, 0, lever > 0 ? 3 : 1);
            canvas.Fill(shape, Gradients.Horizontal(bat, Gray(0.98), Gray(0.55), Gray(0.8)));
        }
        var tip = Shapes.Square(new SKPoint(center.X, center.Y - lever * size * 0.36f), size * 0.2f);
        using (var shape = Shapes.Oval(tip)) canvas.Fill(shape, Gradients.Radial(tip, new Unit(0.4f, 0.35f), 0, size * 0.1f, [SKColors.White, Gray(0.6)]));
    }

    /// <summary>A value easing toward <paramref name="target"/> (a spring's settle in about <paramref name="time"/> seconds).</summary>
    public static float Ease(DeckUi ui, string id, float target, double time)
    {
        var state = ui.State(id, () => new Eased { Value = target, Last = ui.Now });
        var elapsed = Math.Clamp(ui.Now - state.Last, 0, 0.1);
        state.Last = ui.Now;
        state.Value += (float)((target - state.Value) * (1 - Math.Exp(-elapsed / time)));
        if (Math.Abs(target - state.Value) > 0.002f) ui.Animate();
        else state.Value = target;
        return state.Value;
    }

    private sealed class Eased
    {
        public float Value;
        public double Last;
    }

    // MARK: Meters and counters

    /// <summary>
    /// A VU meter: the needle over a backlit amber scale, red past 0 dB, following its channel's level as a real VU meter
    /// does (taking about 300 ms to settle), and falling back while paused.
    /// </summary>
    public static void VuMeter(DeckUi ui, string id, SKRect frame, int channel, SkinPlayback playback)
    {
        var canvas = ui.Canvas;
        var ink = Rgb(0.1, 0.08, 0.06);
        var red = Rgb(0.78, 0.1, 0.06);
        var h = frame.Height;
        using (var bezel = Shapes.Round(frame, h * 0.08f))
        {
            canvas.Shadow(bezel, Black(0.5), 3, 0, 2);
            canvas.Fill(bezel, Gradients.Vertical(frame, Gray(0.16), Gray(0.04)));
            canvas.Border(frame, h * 0.08f, r => Gradients.Vertical(r, White(0.45), White(0.05), Black(0.6)), Math.Max(1, h * 0.02f));
        }
        var face = SKRect.Inflate(frame, -h * 0.07f, -h * 0.07f);
        var size = face.Size;
        using var faceShape = Shapes.Round(face, h * 0.05f);
        canvas.Save();
        canvas.ClipPath(faceShape, antialias: true);
        // The face: printed paper lit from behind by a lamp low in the middle, darker at its corners.
        canvas.Fill(face, Rgb(0.98, 0.88, 0.62));
        Textures.Fill(canvas, face, SkinTexture.Paper, blend: SKBlendMode.Multiply);
        canvas.Fill(face, Gradients.Radial(face, new Unit(0.5f, 1.05f), 0, size.Width * 0.75f, [Rgb(1, 0.85, 0.45, 0.55), Clear]), 1, SKBlendMode.Screen);
        canvas.Fill(face, Gradients.Elliptical(face, new Unit(0.5f, 0.75f), 0, 0.85f, [Clear, Clear, Rgb(0.35, 0.2, 0.05, 0.45)]));
        // The printed scale: the black arc to 0, the red one above, the numbers and the words.
        var pivot = new SKPoint(face.MidX, face.Top + size.Height * 1.12f);
        var radius = size.Height * 0.86f;
        using (var arc = Shapes.Build(b =>
        {
            b.AddArc(Shapes.Square(pivot, radius * 2), (float)(VuAngle(0) * 180 / Math.PI), (float)((VuAngle(0.78) - VuAngle(0)) * 180 / Math.PI));
            foreach (var mark in new[] { 0, 0.25, 0.38, 0.47, 0.58, 0.65, 0.71, 0.78, 0.85, 0.92, 1 })
            {
                var angle = VuAngle(mark);
                var isLong = mark is 0.78 or 0 or 1;
                b.MoveTo(Shapes.Polar(pivot, angle, radius));
                b.LineTo(Shapes.Polar(pivot, angle, radius + size.Height * (isLong ? 0.12f : 0.07f)));
            }
        })) canvas.Stroke(arc, ink.Opacity(0.85), Math.Max(0.8f, size.Height * 0.011f));
        using (var arc = Shapes.Build(b => b.AddArc(Shapes.Square(pivot, radius * 2), (float)(VuAngle(0.78) * 180 / Math.PI), (float)((VuAngle(1) - VuAngle(0.78)) * 180 / Math.PI))))
            canvas.Stroke(arc, red, Math.Max(1.5f, size.Height * 0.045f));
        using (var numbers = Fonts.System(size.Height * 0.085f, SKFontStyleWeight.SemiBold, FontWidth.Condensed))
        {
            foreach (var (text, at) in new[] { ("20", 0.0), ("10", 0.25), ("7", 0.38), ("5", 0.47), ("3", 0.58), ("0", 0.78), ("1", 0.85), ("2", 0.92) })
                Lettering.Centered(canvas, text, Shapes.Polar(pivot, VuAngle(at), size.Height * (0.86 + 0.17)), numbers, at > 0.78 ? red : ink.Opacity(0.85));
        }
        using (var vu = Fonts.Serif(size.Height * 0.15f)) Lettering.Centered(canvas, "VU", new SKPoint(face.MidX, face.MidY + size.Height * 0.15f), vu, ink.Opacity(0.8));
        using (var letter = Fonts.System(size.Height * 0.09f, SKFontStyleWeight.Bold))
            Lettering.Centered(canvas, channel == 0 ? "L" : "R", new SKPoint(face.Left + size.Width * 0.1f, face.Top + size.Height * 0.72f), letter, ink.Opacity(0.6));
        using (var sign = Fonts.System(size.Height * 0.11f, SKFontStyleWeight.Bold))
        {
            Lettering.Centered(canvas, "−", Shapes.Polar(pivot, VuAngle(0.1), size.Height * (0.86 - 0.16)), sign, ink.Opacity(0.8));
            Lettering.Centered(canvas, "+", Shapes.Polar(pivot, VuAngle(0.92), size.Height * (0.86 - 0.16)), sign, red);
        }
        // The needle, and its shadow on the face (a little below and to the right, soft).
        var needle = ui.State(id, () => new VuNeedle());
        var level = needle.Position(playback.IsPlaying ? Target(playback, channel) : 0, ui.Now, playback.IsPlaying);
        if (playback.IsPlaying || level > 0.001) ui.Animate();
        var tip = Shapes.Polar(pivot, VuAngle(level), size.Height * 1.02);
        using (var line = Shapes.Build(b =>
        {
            b.MoveTo(pivot);
            b.LineTo(tip);
        }))
        {
            canvas.Save();
            canvas.Translate(size.Height * 0.025f, size.Height * 0.04f);
            using (var blur = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, size.Height * 0.012f))
            {
                var paint = Paint.Of(Black(0.28));
                paint.Style = SKPaintStyle.Stroke;
                paint.StrokeWidth = Math.Max(1, size.Height * 0.02f);
                paint.StrokeCap = SKStrokeCap.Round;
                paint.MaskFilter = blur;
                canvas.DrawPath(line, paint);
                paint.MaskFilter = null;
            }
            canvas.Restore();
            canvas.Stroke(line, Gray(0.06), Math.Max(0.8f, size.Height * 0.014f), SKStrokeCap.Round);
        }
        // The pivot's cover: a black molded hood across the bottom, its edge catching the light.
        var hood = Shapes.CenteredRect(new SKPoint(face.MidX, face.Top + size.Height * 0.99f), size.Width * 0.62f, size.Height * 0.34f);
        using (var shape = Shapes.Oval(hood))
        {
            canvas.Shadow(shape, Black(0.4), size.Height * 0.03f, 0, -size.Height * 0.01f);
            canvas.Fill(shape, Gradients.Vertical(hood, Gray(0.22), Gray(0.04)));
            canvas.Border(hood, hood.Height / 2, r => Gradients.Linear(r, Unit.Top, Unit.Center, [White(0.35), Clear]), Math.Max(0.6f, size.Height * 0.01f));
        }
        canvas.Restore();
        // The glass: the bezel's shadow inside its top edge, the room's reflection across it.
        canvas.InnerShadow(faceShape, Black(0.55), size.Height * 0.05f, size.Height * 0.03f);
        canvas.Fill(faceShape, Gradients.Linear(face, Unit.TopLeading, Unit.BottomTrailing, (0, White(0.3)), (0.38f, White(0.08)), (0.4f, Clear), (1, Clear)));
    }

    /// <summary>Radians of a level across the VU scale (from 45 degrees left of upright to 45 right).</summary>
    private static double VuAngle(double level) => (-135 + level * 90) * Math.PI / 180;

    private static double Target(SkinPlayback playback, int channel)
    {
        if (playback.Levels is not { } levels) return MadeUpLevel(channel, playback.Time(), playback.IsPlaying);
        var (left, right) = levels();
        return VuPosition(channel == 0 ? left : right);
    }

    /// <summary>The scale's place (0 at -20 VU, 0.78 at 0, 1 at +3) for an RMS level, 0 VU at -12 dBFS.</summary>
    public static double VuPosition(float rms)
    {
        var vu = 20 * Math.Log10(Math.Max(rms, 1e-6)) + 12;
        (double Vu, double At)[] marks = [(-20, 0), (-10, 0.25), (-7, 0.38), (-5, 0.47), (-3, 0.58), (-2, 0.65), (-1, 0.71), (0, 0.78), (1, 0.85), (2, 0.92), (3, 1)];
        if (vu <= marks[0].Vu) return 0;
        if (vu >= marks[^1].Vu) return Math.Min(1.04, 1 + (vu - 3) * 0.01);
        var upper = Array.FindIndex(marks, mark => mark.Vu >= vu);
        var (low, high) = (marks[upper - 1], marks[upper]);
        return low.At + (high.At - low.At) * (vu - low.Vu) / (high.Vu - low.Vu);
    }

    /// <summary>A made-up level of a few slow and quick swings, different for each channel: for music not heard here.</summary>
    public static double MadeUpLevel(int channel, double time, bool isPlaying)
    {
        if (!isPlaying) return 0;
        var shift = channel * 1.7;
        var beat = Math.Pow(Math.Max(Math.Sin(time * 2 * Math.PI * 2.05 + shift), 0), 6) * 0.14;
        var swing = Math.Sin(time * 1.3 + shift) * 0.08 + Math.Sin(time * 4.7 + shift * 2) * 0.06 + Math.Sin(time * 11.3 + shift) * 0.04;
        return Math.Clamp(0.62 + swing + beat, 0.05, 1);
    }

    /// <summary>The needle's movement: toward where the level puts it at a VU meter's pace (99% of the way in 300 ms).</summary>
    private sealed class VuNeedle
    {
        private double value;
        private double? last;

        public double Position(double target, double now, bool isPlaying)
        {
            var elapsed = last is { } previous ? now - previous : double.PositiveInfinity;
            last = now;
            if (elapsed > 0.25 && isPlaying) value = 0;
            var step = Math.Clamp(elapsed, 0, 0.25);
            // Paused, it falls back as the Mac's spring does.
            value += (target - value) * (1 - Math.Exp(-step / (isPlaying ? 0.065 : 0.12)));
            return value;
        }
    }

    /// <summary>
    /// A tape counter: minutes and seconds on drums that roll on as the tape goes, each turning over as the one after it
    /// passes 9 (or 59 seconds), as a mechanical counter does.
    /// </summary>
    public static void TapeCounter(DeckUi ui, SKRect rect, SkinPlayback playback)
    {
        var canvas = ui.Canvas;
        var seconds = Math.Max(playback.Time(), 0);
        if (playback.IsPlaying) ui.Animate();
        var drum = rect.Width / 4.6f;
        var gap = drum * 0.08f;
        using var colonFont = Fonts.System(rect.Height * 0.5f, SKFontStyleWeight.Bold);
        var colon = colonFont.MeasureText(":");
        var total = drum * 4 + colon + gap * 4;
        var x = rect.MidX - total / 2;
        void Drum(double value)
        {
            CounterDrum(canvas, SKRect.Create(x, rect.Top, drum, rect.Height), value);
            x += drum + gap;
        }
        Drum(Wheel(seconds, 600, 10));
        Drum(Wheel(seconds, 60, 10));
        Lettering.Draw(canvas, ":", x, Lettering.Baseline(colonFont, rect.MidY), colonFont, Black(0.6));
        x += colon + gap;
        Drum(Wheel(seconds, 10, 6));
        Drum(Wheel(seconds, 1, 10));
    }

    /// <summary>A drum's place: its digit, and in the last second before it turns over, how far it has turned.</summary>
    public static double Wheel(double seconds, double unit, double radix)
    {
        var whole = Math.Floor(seconds / unit) % radix;
        var carry = unit == 1 ? seconds - Math.Floor(seconds) : Math.Max(0, seconds % unit - (unit - 1));
        return whole + carry;
    }

    /// <summary>One drum: white digits on black, the one above and below curving away.</summary>
    private static void CounterDrum(SKCanvas canvas, SKRect rect, double value)
    {
        var digit = (int)Math.Floor(value) % 10;
        var turn = (float)(value - Math.Floor(value));
        var step = rect.Height * 0.72f;
        using var shape = Shapes.Round(rect, rect.Width * 0.12f);
        canvas.Save();
        canvas.ClipPath(shape, antialias: true);
        canvas.Fill(rect, Gray(0.06));
        using var font = Fonts.Mono(rect.Height * 0.6f);
        for (var offset = -1; offset <= 2; offset++)
            Lettering.Centered(canvas, ((digit + offset + 10) % 10).ToString(), new SKPoint(rect.MidX, rect.MidY + (offset - turn) * step), font, Gray(0.92));
        canvas.Fill(rect, Gradients.Linear(rect, Unit.Top, Unit.Bottom, (0, Black(0.85)), (0.3f, Clear), (0.7f, Clear), (1, Black(0.85))));
        canvas.Restore();
        canvas.Border(rect, rect.Width * 0.12f, SKColors.Black, 1);
    }

    // MARK: Fluorescent display

    /// <summary>Text lit on a vacuum fluorescent display, the unlit segments faintly behind it. Returns its width.</summary>
    public static float VfdText(SKCanvas canvas, string text, string ghost, float x, float baseline, SKFont font, SKColor? color = null)
    {
        var lit = color ?? Vfd;
        Lettering.Draw(canvas, ghost, x, baseline, font, lit.Opacity(0.07));
        Lettering.Glowing(canvas, text, x, baseline, font, lit, lit.Opacity(0.8), 8);
        return Math.Max(font.MeasureText(ghost), font.MeasureText(text));
    }

    /// <summary>A line of the display's 14-segment characters, <paramref name="count"/> wide; longer text steps through.</summary>
    public static void VfdMarquee(DeckUi ui, string text, int count, float x, float baseline, float size, bool isMoving)
    {
        var letters = Fonts.SegmentText(text);
        string shown;
        if (letters.Length > count && isMoving)
        {
            var loop = letters + "    ";
            var start = (int)(ui.Now / 0.35) % loop.Length;
            shown = new string(Enumerable.Range(0, count).Select(index => loop[(start + index) % loop.Length]).ToArray());
            ui.Animate();
        }
        else shown = letters.Length > count ? letters[..count] : letters;
        using var font = Fonts.Letters(size);
        // DSEG's space is narrow: its blank as wide as a character is "!".
        VfdText(ui.Canvas, shown.PadRight(count).Replace(' ', '!'), new string('~', count), x, baseline, font);
    }

    /// <summary>The display's position bar: segments lit up to where the song is; dragged or clicked, it seeks.</summary>
    public static void VfdBar(DeckUi ui, string id, SKRect rect, SkinPlayback playback, Action<double> seek, int segments = 40)
    {
        var canvas = ui.Canvas;
        ui.Drag(id, rect, drag => ui.SetState(id, (double)Math.Clamp((drag.Location.X - rect.Left) / rect.Width, 0, 1)), drag =>
        {
            seek(Math.Clamp((drag.Location.X - rect.Left) / rect.Width, 0, 1) * playback.Duration);
            ui.ClearState(id);
        }, title: "Position");
        var progress = ui.State(id, () => -1.0) is var dragging && dragging >= 0 ? dragging : playback.Progress;
        if (dragging < 0) ui.ClearState(id);
        var lit = (int)Math.Ceiling(progress * segments);
        var spacing = rect.Width * 0.006f;
        var width = (rect.Width - spacing * (segments - 1)) / segments;
        for (var index = 0; index < segments; index++)
        {
            var segment = SKRect.Create(rect.Left + index * (width + spacing), rect.Top, width, rect.Height);
            using var shape = Shapes.Rect(segment);
            if (index < lit) canvas.Shadow(shape, Vfd.Opacity(0.7), 3);
            canvas.Fill(shape, index < lit ? Vfd : Vfd.Opacity(0.07));
        }
    }

    /// <summary>Elapsed time in red LED digits behind a dark window; returns its box.</summary>
    public static SKRect LedClock(DeckUi ui, SKPoint bottomCenter, float size, SkinPlayback playback)
    {
        var canvas = ui.Canvas;
        using var font = Fonts.Digits(size);
        var width = LedClockWidth(size);
        var height = size * 1.2f + size * 0.8f;
        var rect = SKRect.Create(bottomCenter.X - width / 2, bottomCenter.Y - height, width, height);
        Materials.Recess(canvas, rect, size * 0.3f, Rgb(0.08, 0.02, 0.02), 3);
        VfdText(canvas, SkinInfo.ClockText(playback.Time()), "88:88", rect.Left + size * 0.5f, Lettering.Baseline(font, rect.MidY), font, Rgb(1, 0.25, 0.15));
        return rect;
    }

    public static float LedClockWidth(float size)
    {
        using var font = Fonts.Digits(size);
        return font.MeasureText("88:88") + size;
    }

    /// <summary>A round aluminum cap with its symbol engraved (the app's love button at the foot of a player's panel).</summary>
    public static void DeckCap(DeckUi ui, string id, SKPoint center, string title, Glyph glyph, SKColor? color, Action tap, bool enabled = true)
    {
        var canvas = ui.Canvas;
        var rect = Shapes.Square(center, 40);
        var pressed = ui.Press(id, rect, tap, title: title, enabled: enabled, round: true);
        using var shape = Shapes.Oval(rect);
        canvas.Shadow(shape, Black(pressed ? 0.3 : 0.5), pressed ? 1 : 3, 0, pressed ? 1 : 2);
        using (var ring = Shapes.Oval(SKRect.Inflate(rect, 2, 2))) canvas.Fill(ring, Black(0.6));
        Textures.Fill(canvas, shape, SkinTexture.Aluminum, pressed ? 0.04 : 0.16);
        canvas.Fill(shape, Gradients.Vertical(rect, White(pressed ? 0.1 : 0.35), Clear, Black(0.2)));
        canvas.CircleBorder(rect, r => Gradients.Vertical(r, White(0.8), Black(0.35)), 1);
        Glyphs.Draw(canvas, glyph, center + new SKPoint(0, 0.8f), 17, White(0.6));
        Glyphs.Draw(canvas, glyph, center, 17, (color ?? Black(0.65)).Opacity(enabled ? 1 : 0.4));
    }
}
