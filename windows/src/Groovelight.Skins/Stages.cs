using SkiaSharp;
using static Groovelight.Skins.Colors;

namespace Groovelight.Skins;

/// <summary>
/// A motor's turning: its angle (degrees) at any moment, from the clock rather than the song's time. A change of speed
/// takes <c>spinUp</c> seconds from rest to full speed (or <c>spinDown</c> from full speed to rest), easing in and out
/// as a real platter or disc does.
/// </summary>
internal sealed class SpinMotion(double speed, double spinUp, double spinDown, bool isOn, double now)
{
    private double angle, velocity = isOn ? speed : 0, target = isOn ? speed : 0, duration, since = now;
    private bool on = isOn;

    public (double Angle, double Velocity) State(double now)
    {
        var elapsed = Math.Max(now - since, 0);
        if (duration <= 0) return (angle + velocity * elapsed, velocity);
        // The speed follows smoothstep (3u² - 2u³) from velocity to target; the angle is its integral.
        var u = Math.Min(elapsed / duration, 1);
        var change = target - velocity;
        var turned = velocity * duration * u + change * duration * (u * u * u - u * u * u * u / 2);
        var velocityNow = velocity + change * (3 * u * u - 2 * u * u * u);
        return (angle + turned + target * Math.Max(elapsed - duration, 0), velocityNow);
    }

    /// <summary>Starts or stops the motor at <paramref name="now"/> (nothing when it is already so).</summary>
    public void Turn(bool isOn, double now)
    {
        if (isOn == on) return;
        on = isOn;
        var state = State(now);
        angle = state.Angle % 360;
        velocity = state.Velocity;
        target = isOn ? speed : 0;
        since = now;
        duration = Math.Abs(target - velocity) / speed * (isOn ? spinUp : spinDown);
    }

    public bool IsTurning(double now) => State(now).Velocity > 0.001 || target > 0;
}

/// <summary>The players themselves: the turntable from above, the cassette well, the CD well (the Mac's Stages).</summary>
internal static class Stages
{
    /// <summary>The cover, or without one the placeholder's colors, filling the rectangle.</summary>
    public static void Artwork(SKCanvas canvas, SKImage? artwork, SKRect rect)
    {
        if (artwork is not null)
        {
            canvas.ImageFill(artwork, rect);
            return;
        }
        canvas.Fill(rect, Gradients.Linear(rect, Unit.TopLeading, Unit.BottomTrailing, [Rgb(0.16, 0.3, 0.63), Rgb(0.56, 0.35, 0.54)]));
    }

    private static double Spin(DeckUi ui, string id, bool isOn, double speed, double spinUp, double spinDown)
    {
        var motion = ui.State(id, () => new SpinMotion(speed, spinUp, spinDown, isOn, ui.Now));
        motion.Turn(isOn, ui.Now);
        if (motion.IsTurning(ui.Now)) ui.Animate();
        return motion.State(ui.Now).Angle;
    }

    // MARK: Turntable

    /// <summary>
    /// The turntable from above, in the largest square that fits: the platter in its felt mat, the record turning at 33⅓
    /// with the cover as its label, and the tonearm going in from the first groove to the last as the song plays (on its
    /// rest until it starts). The arm's headshell can be dragged across the record to go to another part of the song.
    /// </summary>
    public static void Turntable(DeckUi ui, SKRect bounds, SkinPlayback playback, Action<double> seek)
    {
        var canvas = ui.Canvas;
        var side = Math.Min(bounds.Width, bounds.Height);
        canvas.Save();
        canvas.Translate(bounds.MidX - side / 2, bounds.MidY - side / 2);
        var center = new SKPoint(side * 0.43f, side * 0.5f);
        var record = side * 0.38f;
        var platter = Shapes.Square(center, side * 0.9f);
        canvas.Image(ui.Cached("platter", platter.Size, layer =>
        {
            layer.Translate(-platter.Left, -platter.Top);
            Platter(layer, center, side);
        }), platter);
        // 33⅓ turns a minute; a direct-drive motor is up to speed in a second, the platter coasts to a stop.
        var angle = Spin(ui, "turntable.motor", playback.IsPlaying, 200, 1, 2.6);
        var recordRect = Shapes.Square(center, record * 2);
        using (var disc = Shapes.Oval(recordRect)) canvas.Shadow(disc, Black(0.5), 3, 0, 2);
        var image = ui.Cached($"record:{playback.Artwork?.UniqueId}", recordRect.Size, layer => VinylRecord(layer, SKRect.Create(recordRect.Size), playback.Artwork));
        canvas.Save();
        canvas.RotateDegrees((float)angle, center.X, center.Y);
        canvas.Image(image, recordRect);
        canvas.Restore();
        // The light on the record stays where it is while the record turns under it.
        canvas.Image(ui.Cached("record.sheen", recordRect.Size, layer => VinylSheen(layer, SKRect.Create(recordRect.Size))), recordRect);
        // The spindle.
        var spindle = Shapes.Square(center, side * 0.02f);
        using (var shape = Shapes.Oval(spindle))
        {
            canvas.Shadow(shape, Black(0.33), 1);
            canvas.Fill(shape, Gradients.Radial(spindle, new Unit(0.35f, 0.3f), 0, side * 0.012f, [SKColors.White, Gray(0.55)]));
        }
        // The arm crosses the record over the whole song.
        var range = Tonearm.Range(side, center, record);
        var time = playback.Time();
        var started = playback.IsPlaying || time > 0.5;
        var dragging = ui.State("tonearm.drag", () => double.NaN);
        double armAngle;
        if (!double.IsNaN(dragging))
        {
            armAngle = dragging;
        }
        else
        {
            var target = started ? range.Outer + (range.Inner - range.Outer) * playback.Progress : Tonearm.Rest;
            armAngle = Controls.Ease(ui, "tonearm.angle", (float)target, 0.22);
        }
        Tonearm.Draw(canvas, side, armAngle);
        // The headshell's handle.
        var stylus = Tonearm.Stylus(side, armAngle);
        ui.Drag("tonearm", Shapes.Square(stylus, side * 0.16f), drag =>
        {
            var pivot = Tonearm.Pivot(side);
            var degrees = Math.Atan2(pivot.X - drag.Location.X, drag.Location.Y - pivot.Y) * 180 / Math.PI;
            ui.SetState("tonearm.drag", Math.Clamp(degrees, Tonearm.Rest, range.Inner + 2));
        }, _ =>
        {
            var dragged = ui.State("tonearm.drag", () => double.NaN);
            if (!double.IsNaN(dragged) && playback.Duration > 0)
            {
                var progress = (dragged - range.Outer) / (range.Inner - range.Outer);
                seek(Math.Clamp(progress, 0, 0.995) * playback.Duration);
                // Stays where it was put while the player catches up.
                ui.ClearState("tonearm.angle");
            }
            ui.SetState("tonearm.drag", double.NaN);
        }, title: "Drag the arm to move through the song", round: true);
        if (playback.IsPlaying) ui.Animate();
        canvas.Restore();
    }

    /// <summary>The platter: a polished aluminum rim with its strobe dots, the felt mat on it.</summary>
    private static void Platter(SKCanvas canvas, SKPoint center, float side)
    {
        var diameter = side * 0.84f;
        var rect = Shapes.Square(center, diameter);
        using var rim = Shapes.Oval(rect);
        canvas.Shadow(rim, Black(0.6), side * 0.025f, 0, side * 0.015f);
        canvas.Fill(rim, Gradients.Sweep(center, [Gray(0.92), Gray(0.5), Gray(0.85), Gray(0.42), Gray(0.92)]));
        for (var index = 0; index < 90; index++)
        {
            var point = Shapes.Polar(center, index / 90.0 * 2 * Math.PI, diameter * 0.488);
            var dot = diameter * 0.006f;
            using var shape = Shapes.Round(Shapes.Square(point, dot * 2), dot * 0.3f);
            canvas.Fill(shape, Black(0.4));
        }
        var felt = SKRect.Inflate(rect, -diameter * 0.035f, -diameter * 0.035f);
        using var mat = Shapes.Oval(felt);
        Textures.Fill(canvas, mat, SkinTexture.Felt, tint: Gray(0.28));
        canvas.CircleBorder(felt, Black(0.5), 1);
    }

    /// <summary>The record: black vinyl, its grooves faintly seen in the room's light, and the label (the cover, round).</summary>
    private static void VinylRecord(SKCanvas canvas, SKRect rect, SKImage? artwork)
    {
        using var disc = Shapes.Oval(rect);
        canvas.Save();
        canvas.ClipPath(disc, antialias: true);
        canvas.Fill(rect, Gray(0.035));
        Textures.Stretch(canvas, SkinTexture.Vinyl, rect, 0.17);
        var label = Shapes.Square(new SKPoint(rect.MidX, rect.MidY), rect.Width * 0.34f);
        using (var labelShape = Shapes.Oval(label))
        {
            canvas.Save();
            canvas.ClipPath(labelShape, antialias: true);
            Artwork(canvas, artwork, label);
            canvas.Restore();
        }
        canvas.CircleBorder(label, Black(0.4), 1);
        canvas.Restore();
    }

    /// <summary>
    /// The lamp's light on a record: two bright wedges across from each other, where the grooves face the light, made of
    /// the grooves' fine lines (the record's own grooves are its mask).
    /// </summary>
    private static void VinylSheen(SKCanvas canvas, SKRect rect)
    {
        var center = new SKPoint(rect.MidX, rect.MidY);
        using var disc = Shapes.Oval(rect);
        canvas.ClipPath(disc, antialias: true);
        canvas.Masked(() => canvas.Fill(rect, Gradients.Sweep(center,
            [Clear, White(0.18), White(0.75), White(0.18), Clear, Clear, White(0.12), White(0.5), White(0.12), Clear, Clear],
            [0, 0.06f, 0.11f, 0.16f, 0.24f, 0.53f, 0.57f, 0.61f, 0.65f, 0.72f, 1], -20)), () =>
        {
            using var luma = SKColorFilter.CreateLumaColor();
            using var paint = new SKPaint { ColorFilter = luma };
            canvas.DrawImage(Textures.Image(SkinTexture.Vinyl), rect, new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear), paint);
        });
    }

    // MARK: Cassette

    /// <summary>The deck's cassette well: a door of black plastic, the cassette behind its smoked window, the reels turning.</summary>
    public static void Cassette(DeckUi ui, SKRect bounds, CassetteDesign design, CassettePictures pictures, SkinPlayback playback)
    {
        var canvas = ui.Canvas;
        var aspect = (float)design.ResolvedGeometry.AspectRatio;
        // The door is a little larger than the cassette, around it.
        var width = Math.Min(bounds.Width, bounds.Height * aspect * 0.9f / 0.82f);
        var door = Shapes.CenteredRect(new SKPoint(bounds.MidX, bounds.MidY), width, width / aspect * 0.82f / 0.9f * 1.04f);
        var cassette = new SKSize(door.Width * 0.86f, door.Width * 0.86f / aspect);
        var corner = door.Width * 0.03f;
        // The window, the cassette behind it.
        var window = Shapes.CenteredRect(new SKPoint(door.MidX, door.MidY - door.Height * 0.03f), cassette.Width + door.Width * 0.04f, cassette.Height + door.Width * 0.04f);
        var area = SKRect.Inflate(door, corner * 2, corner * 2);
        // The door and the glass never move: kept as images, the turning reels drawn between them.
        canvas.Image(ui.Cached("door", area.Size, layer =>
        {
            layer.Translate(-area.Left, -area.Top);
            using var shape = Shapes.Round(door, corner);
            layer.Shadow(shape, Black(0.6), corner, 0, corner * 0.5f);
            Textures.Fill(layer, shape, SkinTexture.BlackPlastic, -0.05);
            layer.Border(door, corner, r => Gradients.Vertical(r, White(0.35), Black(0.6)), 1.5f);
            using var glass = Shapes.Round(window, corner * 0.6f);
            layer.Fill(glass, SKColors.Black);
        }), area);
        using (var shape = Shapes.Round(window, corner * 0.6f))
        {
            canvas.Save();
            canvas.ClipPath(shape, antialias: true);
            var face = Shapes.CenteredRect(new SKPoint(window.MidX, window.MidY), cassette.Width, cassette.Height);
            CassetteFace.Draw(ui, face, design, pictures, playback);
            if (playback.IsPlaying) ui.Animate();
            canvas.Restore();
        }
        canvas.Image(ui.Cached("door.glass", area.Size, layer =>
        {
            layer.Translate(-area.Left, -area.Top);
            using var shape = Shapes.Round(window, corner * 0.6f);
            // Smoked plexiglass: darker, and the light across it.
            layer.Fill(shape, Black(0.24));
            layer.Fill(shape, Gradients.Linear(window, Unit.TopLeading, Unit.BottomTrailing, (0, White(0.16)), (0.38f, White(0.03)), (0.4f, Clear), (1, Clear)));
            layer.Border(window, corner * 0.6f, r => Gradients.Vertical(r, Gray(0.2), Gray(0.7)), 2);
            // "◀ TAPE ▶" under the window, the arrows drawn (fonts may not have them).
            var size = door.Width * 0.022f;
            var center = new SKPoint(door.MidX, door.Bottom - door.Height * 0.035f - size * 0.6f);
            layer.Layer(0.6, () =>
            {
                Lettering.Engraved(layer, "TAPE", center, size, onDark: true);
                var half = Lettering.EngravedWidth("TAPE", size) / 2 + size * 0.5f;
                foreach (var side in new[] { -1, 1 })
                {
                    var tip = center.X + side * (half + size * 0.75f);
                    using var arrow = Shapes.Build(b =>
                    {
                        b.MoveTo(tip, center.Y);
                        b.LineTo(tip - side * size * 0.6f, center.Y - size * 0.38f);
                        b.LineTo(tip - side * size * 0.6f, center.Y + size * 0.38f);
                        b.Close();
                    });
                    layer.Fill(arrow, White(0.78));
                }
            });
        }), area);
    }

    // MARK: CD

    /// <summary>A top-loading CD player's well: the disc, printed with the cover, turning under a smoked lid.</summary>
    public static void Disc(DeckUi ui, SKRect bounds, SkinPlayback playback)
    {
        var canvas = ui.Canvas;
        var side = Math.Min(bounds.Width, bounds.Height);
        var center = new SKPoint(bounds.MidX, bounds.MidY);
        var rect = Shapes.Square(center, side);
        using (var ring = Shapes.Oval(rect)) canvas.Shadow(ring, Black(0.7), side * 0.03f, 0, side * 0.015f);
        // The lid's polished ring and the well under it (never moving: kept as an image).
        canvas.Image(ui.Cached("disc.well", rect.Size, layer =>
        {
            layer.Translate(-rect.Left, -rect.Top);
            DiscWell(layer, rect, center, side);
        }), rect);
        // The spindle motor spins the disc up in a second and a half, and brakes it in two.
        var angle = Spin(ui, "disc.motor", playback.IsPlaying, 300, 1.5, 2);
        var discRect = Shapes.Square(center, side * 0.86f);
        var disc = ui.Cached($"disc:{playback.Artwork?.UniqueId}", discRect.Size, layer => CompactDisc(layer, SKRect.Create(discRect.Size), playback.Artwork));
        canvas.Save();
        canvas.RotateDegrees((float)angle, center.X, center.Y);
        canvas.Image(disc, discRect);
        canvas.Restore();
        // The rainbow the light makes on the disc, the clamp and the smoked lid: still, over the turning disc.
        canvas.Image(ui.Cached("disc.lid", rect.Size, layer =>
        {
            layer.Translate(-rect.Left, -rect.Top);
            DiscLid(layer, rect, center, side, discRect);
        }), rect);
    }

    private static void DiscWell(SKCanvas canvas, SKRect rect, SKPoint center, float side)
    {
        using (var ring = Shapes.Oval(rect)) canvas.Fill(ring, Gradients.Sweep(center, [Gray(0.85), Gray(0.3), Gray(0.75), Gray(0.25), Gray(0.85)]));
        var well = SKRect.Inflate(rect, -side * 0.025f, -side * 0.025f);
        using var wellShape = Shapes.Oval(well);
        Textures.Fill(canvas, wellShape, SkinTexture.BlackPlastic, -0.08);
        canvas.InnerShadow(wellShape, SKColors.Black, side * 0.03f, side * 0.015f);
    }

    private static void DiscLid(SKCanvas canvas, SKRect rect, SKPoint center, float side, SKRect discRect)
    {
        using (var printed = DiscShape(discRect, DiscRadii.Mirror))
            canvas.Fill(printed, Gradients.Sweep(center, [Clear, SKColors.Cyan.Opacity(0.2), SKColors.Purple.Opacity(0.15), Clear, SKColors.Yellow.Opacity(0.15),
                SKColors.Pink.Opacity(0.13), Clear]), 1, SKBlendMode.Screen);
        var clamp = Shapes.Square(center, side * 0.12f);
        using (var shape = Shapes.Oval(clamp))
        {
            canvas.Shadow(shape, Black(0.6), 3, 0, 2);
            canvas.Fill(shape, Gradients.Sweep(center, [Gray(0.95), Gray(0.45), Gray(0.9), Gray(0.4), Gray(0.95)]));
        }
        using (var hub = Shapes.Oval(SKRect.Inflate(clamp, -side * 0.03f, -side * 0.03f))) canvas.Fill(hub, Gray(0.15));
        var well = SKRect.Inflate(rect, -side * 0.025f, -side * 0.025f);
        using var wellShape = Shapes.Oval(well);
        canvas.Fill(wellShape, Gradients.Linear(well, Unit.TopLeading, Unit.BottomTrailing, (0, White(0.2)), (0.42f, White(0.04)), (0.45f, Clear), (1, Black(0.18))));
    }

    /// <summary>A compact disc's radii over its width: the hole, the hub's stacking ring, the mirror's start, the print's start.</summary>
    private static class DiscRadii
    {
        public const float Hole = 0.0625f, StackingRing = 0.115f, Mirror = 0.17f, Print = 0.183f;
    }

    /// <summary>A disc with a hole (even-odd): <paramref name="hole"/> is the hole's radius relative to the width.</summary>
    private static SKPath DiscShape(SKRect rect, float hole, float inset = 0) => Shapes.Build(b =>
    {
        b.AddOval(SKRect.Inflate(rect, -inset, -inset));
        b.AddOval(Shapes.Square(new SKPoint(rect.MidX, rect.MidY), rect.Width * hole * 2));
    }, SKPathFillType.EvenOdd);

    /// <summary>
    /// The disc as a real one is (120 mm across): the 15 mm hole, the clear hub out to 41 mm, the mirror's edge, and the
    /// cover printed from 44 mm to the rim.
    /// </summary>
    private static void CompactDisc(SKCanvas canvas, SKRect rect, SKImage? artwork)
    {
        var size = rect.Width;
        var center = new SKPoint(rect.MidX, rect.MidY);
        using var whole = DiscShape(rect, DiscRadii.Hole);
        canvas.Save();
        canvas.ClipPath(whole, antialias: true);
        // The clear polycarbonate hub: the well shows through it, a little lighter.
        var hub = Shapes.Square(center, size * DiscRadii.Mirror * 2);
        using (var shape = Shapes.Oval(hub))
        {
            canvas.Fill(shape, Gradients.Radial(hub, Unit.Center, 0, size * DiscRadii.Mirror, [White(0.22), White(0.38)]));
            canvas.Fill(shape, Gradients.Sweep(center, [Clear, White(0.3), Clear, Clear, White(0.22), Clear]));
        }
        canvas.CircleBorder(Shapes.Square(center, size * DiscRadii.StackingRing * 2), White(0.28), size * 0.004f);
        canvas.CircleBorder(Shapes.Square(center, size * DiscRadii.Hole * 2 + size * 0.004f), White(0.35), size * 0.002f);
        // The mirror, then the print.
        using (var mirror = DiscShape(rect, DiscRadii.Mirror))
            canvas.Fill(mirror, Gradients.Sweep(center, [Gray(0.85), Gray(0.6), Gray(0.92), Gray(0.55), Gray(0.85)]));
        using (var print = DiscShape(rect, DiscRadii.Print, size * 0.008f))
        {
            canvas.Save();
            canvas.ClipPath(print, antialias: true);
            Artwork(canvas, artwork, rect);
            canvas.Restore();
        }
        // The mirror's dark inner edge, the print's edge, and the rim.
        canvas.CircleBorder(Shapes.Square(center, size * DiscRadii.Mirror * 2), Gray(0.2).Opacity(0.7), size * 0.005f);
        canvas.CircleBorder(Shapes.Square(center, size * DiscRadii.Print * 2), Black(0.15), size * 0.002f);
        canvas.CircleBorder(rect, White(0.4), size * 0.004f);
        canvas.Restore();
    }
}

/// <summary>The arm: its base, the counterweight behind the pivot, the chrome tube and the headshell at the stylus.</summary>
internal static class Tonearm
{
    /// <summary>Degrees from resting straight down beside the record; toward the record is positive.</summary>
    public const double Rest = -3;

    public static SKPoint Pivot(float side) => new(side * 0.88f, side * 0.14f);
    public static float Length(float side) => side * 0.66f;

    public static SKPoint Stylus(float side, double angle)
    {
        var pivot = Pivot(side);
        var length = Length(side) * 0.97;
        var radians = angle * Math.PI / 180;
        return new SKPoint((float)(pivot.X - Math.Sin(radians) * length), (float)(pivot.Y + Math.Cos(radians) * length));
    }

    /// <summary>The angles putting the stylus in the first groove and the last.</summary>
    public static (double Outer, double Inner) Range(float side, SKPoint center, float record)
    {
        var pivot = Pivot(side);
        var length = Length(side);
        double At(double radius)
        {
            double low = 0, high = 60;
            for (var step = 0; step < 30; step++)
            {
                var middle = (low + high) / 2;
                var radians = middle * Math.PI / 180;
                var x = pivot.X - Math.Sin(radians) * length;
                var y = pivot.Y + Math.Cos(radians) * length;
                if (Math.Sqrt((x - center.X) * (x - center.X) + (y - center.Y) * (y - center.Y)) > radius) low = middle;
                else high = middle;
            }
            return (low + high) / 2;
        }
        return (At(record * 0.95), At(record * 0.4));
    }

    public static void Draw(SKCanvas canvas, float side, double angle)
    {
        var pivot = Pivot(side);
        var length = Length(side);
        // The rest the arm sits on: a black rubber cradle on a chrome post.
        var post = Shapes.Square(new SKPoint(pivot.X + side * 0.035f, pivot.Y + length * 0.72f + side * 0.012f), side * 0.024f);
        using (var shape = Shapes.Oval(post))
        {
            canvas.Shadow(shape, Black(0.5), side * 0.004f, 0, side * 0.003f);
            canvas.Fill(shape, Materials.ChromeDome(post, side * 0.012f));
        }
        var cradle = Shapes.CenteredRect(new SKPoint(pivot.X + side * 0.035f, pivot.Y + length * 0.72f - side * 0.01f), side * 0.03f, side * 0.04f);
        using (var shape = Shapes.Round(cradle, side * 0.006f)) canvas.Fill(shape, Gradients.Horizontal(cradle, Gray(0.2), Gray(0.06)));
        // The arm's base: a disc of turned aluminum, its lathe rings.
        var baseRect = Shapes.Square(pivot, side * 0.13f);
        using (var shape = Shapes.Oval(baseRect))
        {
            canvas.Shadow(shape, Black(0.55), side * 0.012f, 0, side * 0.008f);
            canvas.Fill(shape, Materials.Turned(pivot));
            var radius = baseRect.Width / 2 - 1;
            var ring = 0;
            while (radius > baseRect.Width * 0.1f)
            {
                using var circle = Shapes.Circle(pivot, radius);
                canvas.Stroke(circle, ring % 3 == 0 ? White(0.2) : Black(0.07), 0.5f);
                radius -= Math.Max(0.8f, baseRect.Width * 0.012f);
                ring++;
            }
            canvas.CircleBorder(baseRect, r => Gradients.Linear(r, Unit.TopLeading, Unit.BottomTrailing, [White(0.85), Black(0.5)]), 1.2f);
        }
        // The arm, turned about the pivot, with its shadow on the plinth.
        // The arm, turned about the pivot, its shadow on the plinth (its outline, blurred).
        canvas.Save();
        canvas.RotateDegrees((float)angle, pivot.X, pivot.Y);
        using (var silhouette = Shapes.Build(b =>
        {
            b.AddRoundRect(new SKRoundRect(SKRect.Create(pivot.X - side * 0.0275f, pivot.Y - side * 0.095f, side * 0.055f, side * 0.07f), side * 0.005f));
            b.AddRoundRect(new SKRoundRect(SKRect.Create(pivot.X - side * 0.0085f, pivot.Y, side * 0.017f, length), side * 0.0085f));
            b.AddRoundRect(new SKRoundRect(SKRect.Create(pivot.X - side * 0.0225f, pivot.Y + length - side * 0.06f, side * 0.045f, side * 0.08f), side * 0.006f));
        }))
        {
            canvas.Restore();
            canvas.Save();
            canvas.Translate(side * 0.01f, side * 0.016f);
            canvas.RotateDegrees((float)angle, pivot.X, pivot.Y);
            canvas.Shadow(silhouette, Black(0.5), side * 0.012f);
            canvas.Restore();
        }
        {
            canvas.Save();
            canvas.RotateDegrees((float)angle, pivot.X, pivot.Y);
            var x = pivot.X;
            // The counterweight behind the pivot: a chrome cylinder, knurled, a black ring at its end.
            var weight = SKRect.Create(x - side * 0.0275f, pivot.Y - side * 0.095f, side * 0.055f, side * 0.07f);
            using (var shape = Shapes.Round(weight, side * 0.005f))
            {
                canvas.Fill(shape, Materials.ChromeCylinder(weight));
                var rows = 7;
                var spacing = side * 0.0035f;
                var line = Math.Max(0.5f, side * 0.0018f);
                var inner = weight.Height - side * 0.024f;
                var gap = (inner - rows * line) / (rows - 1);
                for (var row = 0; row < rows; row++)
                    canvas.Fill(SKRect.Create(weight.Left, weight.Top + side * 0.012f + row * (line + Math.Max(gap, spacing)), weight.Width, line), Black(0.28));
                var cap = SKRect.Create(weight.Left, weight.Top, weight.Width, side * 0.012f);
                using (var capShape = Shapes.Round(cap, side * 0.004f)) canvas.Fill(capShape, Gradients.Horizontal(cap, Gray(0.05), Gray(0.3), Gray(0.04)));
                canvas.Border(weight, side * 0.005f, Black(0.35), 0.6f);
            }
            // The tube, polished chrome.
            var tube = SKRect.Create(x - side * 0.0085f, pivot.Y, side * 0.017f, length);
            using (var shape = Shapes.Capsule(tube))
            {
                canvas.Fill(shape, Materials.ChromeCylinder(tube));
                canvas.Border(tube, tube.Width / 2, Black(0.3), 0.5f);
            }
            // The headshell (brushed aluminum, a chrome edge), the cartridge under it, and the chrome finger lift.
            var shell = SKRect.Create(x - side * 0.0225f, pivot.Y + length - side * 0.06f, side * 0.045f, side * 0.08f);
            using (var shape = Shapes.Round(shell, side * 0.006f))
            {
                Textures.Fill(canvas, shape, SkinTexture.Aluminum, 0.05);
                canvas.Fill(shape, Materials.ChromeCylinder(shell), 0.45);
                canvas.Border(shell, side * 0.006f, r => Materials.ChromeCylinder(r, Unit.Top, Unit.Bottom), side * 0.003f);
            }
            for (var screw = 0; screw < 2; screw++)
            {
                var point = new SKPoint(shell.MidX + (screw == 0 ? -1 : 1) * (side * 0.008f + side * 0.004f), shell.MidY - side * 0.012f);
                var rect = Shapes.Square(point, side * 0.008f);
                using var shape = Shapes.Oval(rect);
                canvas.Fill(shape, Materials.ChromeDome(rect, side * 0.004f));
                canvas.CircleBorder(rect, Black(0.5), 0.5f);
            }
            var cartridge = Shapes.CenteredRect(new SKPoint(shell.MidX, shell.Top + side * 0.0125f + side * 0.045f), side * 0.03f, side * 0.025f);
            using (var shape = Shapes.Round(cartridge, side * 0.003f))
                canvas.Fill(shape, Gradients.Horizontal(cartridge, Rgb(0.55, 0.06, 0.05), Rgb(0.85, 0.15, 0.1), Rgb(0.5, 0.05, 0.04)));
            var lift = Shapes.CenteredRect(new SKPoint(shell.Right - side * 0.015f + side * 0.025f, shell.MidY - side * 0.02f), side * 0.03f, side * 0.007f);
            using (var shape = Shapes.Capsule(lift)) canvas.Fill(shape, Materials.ChromeCylinder(lift, Unit.Top, Unit.Bottom));
            canvas.Restore();
        }
        // The pivot's chrome cap.
        var capRect = Shapes.Square(pivot, side * 0.04f);
        using (var shape = Shapes.Oval(capRect))
        {
            canvas.Shadow(shape, Black(0.5), side * 0.004f, 0, side * 0.003f);
            canvas.Fill(shape, Materials.ChromeDome(capRect, side * 0.02f));
            canvas.CircleBorder(capRect, Black(0.45), 0.8f);
        }
    }
}
