using SkiaSharp;
using static Groovelight.Skins.Colors;

namespace Groovelight.Skins;

/// <summary>The players' materials: plates with screws, hollows, lamps, polished chrome and hot-stamped foil.</summary>
internal static class Materials
{
    /// <summary>A plate of the texture fixed to the player: a lit top edge, a shadowed bottom one, and screws in its corners.</summary>
    public static void Plate(SKCanvas canvas, SKRect rect, SkinTexture texture, float corner, double brightness = 0, SKColor? tint = null, float? screws = null)
    {
        using var shape = Shapes.Round(rect, corner);
        canvas.Shadow(shape, Black(0.55), corner * 0.6f, 0, corner * 0.3f);
        Textures.Fill(canvas, shape, texture, brightness, tint);
        canvas.Fill(shape, Gradients.Vertical(rect, White(0.16), Clear, Black(0.18)));
        canvas.Border(rect, corner, r => Gradients.Vertical(r, White(0.7), White(0.1), Black(0.35)), 1.2f);
        if (screws is not { } side) return;
        var inset = side * 1.4f;
        for (var index = 0; index < 4; index++)
        {
            var center = new SKPoint(index % 2 == 0 ? rect.Left + inset : rect.Right - inset, index < 2 ? rect.Top + inset : rect.Bottom - inset);
            Screw(canvas, center, side, index * 37 + 12);
        }
    }

    /// <summary>A hollow in the player (a well, a display's window): its edges in shadow at the top, lit at the bottom.</summary>
    public static void Recess(SKCanvas canvas, SKRect rect, float corner, SKShader fill, float depth = 6)
    {
        using var shape = Shapes.Round(rect, corner);
        canvas.Fill(shape, fill);
        canvas.InnerShadow(shape, Black(0.85), depth, depth * 0.6f);
        canvas.Border(rect, corner, r => Gradients.Vertical(r, Black(0.6), White(0.35)), 1);
    }

    public static void Recess(SKCanvas canvas, SKRect rect, float corner, SKColor fill, float depth = 6) =>
        Recess(canvas, rect, corner, SKShader.CreateColor(fill), depth);

    /// <summary>A slotted (cross) screw head, turned by <paramref name="angle"/> degrees.</summary>
    public static void Screw(SKCanvas canvas, SKPoint center, float side, float angle)
    {
        var rect = Shapes.Square(center, side);
        using var head = Shapes.Oval(rect);
        canvas.Shadow(head, Black(0.5), side * 0.1f, 0, side * 0.08f);
        canvas.Fill(head, Gradients.Radial(rect, new Unit(0.35f, 0.3f), 0, side * 0.7f, [Gray(0.92), Gray(0.55), Gray(0.3)]));
        canvas.Save();
        canvas.RotateDegrees(angle, center.X, center.Y);
        using (var slot = Shapes.Capsule(Shapes.CenteredRect(center, side * 0.75f, side * 0.16f))) canvas.Fill(slot, Black(0.6));
        using (var slot = Shapes.Capsule(Shapes.CenteredRect(center, side * 0.16f, side * 0.75f))) canvas.Fill(slot, Black(0.6));
        canvas.Restore();
        canvas.CircleBorder(rect, Black(0.4), 0.6f);
    }

    /// <summary>A small lamp: lit, it glows in its color.</summary>
    public static void PilotLamp(SKCanvas canvas, SKRect rect, bool isOn, SKColor? color = null)
    {
        var lamp = color ?? Rgb(1, 0.28, 0.16);
        var side = rect.Width;
        using var shape = Shapes.Oval(rect);
        if (isOn) canvas.Shadow(shape, lamp, side * 0.7f);
        canvas.Fill(shape, Gradients.Radial(rect, new Unit(0.4f, 0.35f), 0, side * 0.6f, isOn ? [SKColors.White, lamp, lamp.Opacity(0.7)] : [Gray(0.45), Gray(0.18), Gray(0.1)]));
        canvas.CircleBorder(rect, Black(0.6), side * 0.12f);
    }

    // MARK: Chrome: a mirror of the room, a bright window, a dark floor and the sky, sharply.

    private static readonly (float At, double R, double G, double B)[] chromeStops =
    [
        (0, 0.16, 0.17, 0.19), (0.1f, 0.42, 0.43, 0.45), (0.2f, 0.86, 0.87, 0.88), (0.25f, 1, 1, 1), (0.31f, 0.8, 0.8, 0.79), (0.44f, 0.4, 0.4, 0.39),
        (0.54f, 0.13, 0.13, 0.14), (0.66f, 0.3, 0.31, 0.33), (0.79f, 0.74, 0.77, 0.82), (0.9f, 0.55, 0.57, 0.6), (1, 0.14, 0.14, 0.16),
    ];

    /// <summary>A rod's or a cylinder's chrome, across it from <paramref name="start"/> to <paramref name="end"/>.</summary>
    public static SKShader ChromeCylinder(SKRect rect, Unit? start = null, Unit? end = null) =>
        Gradients.Linear(rect, start ?? Unit.Leading, end ?? Unit.Trailing, chromeStops.Select(stop => Rgb(stop.R, stop.G, stop.B)).ToArray(),
            chromeStops.Select(stop => stop.At).ToArray());

    /// <summary>A dome's chrome (a pivot's cap, a screw head): the window's reflection near the top left.</summary>
    public static SKShader ChromeDome(SKRect rect, float radius) =>
        Gradients.Radial(rect, new Unit(0.36f, 0.32f), 0, radius * 1.3f,
            [SKColors.White, Gray(0.92), Gray(0.45), Rgb(0.12, 0.12, 0.14), Rgb(0.55, 0.58, 0.63), Gray(0.2)], [0, 0.12f, 0.35f, 0.62f, 0.86f, 1]);

    /// <summary>Turned (lathe-cut) metal seen from above: light and dark sectors where the fine rings catch the light.</summary>
    public static SKShader Turned(SKPoint center) =>
        Gradients.Sweep(center, [Gray(0.97), Gray(0.62), Gray(0.35), Gray(0.7), Gray(0.98), Gray(0.6), Gray(0.3), Gray(0.68), Gray(0.97)]);

    /// <summary>Spun metal: two light sectors across from each other (a knob's cap, a platter's rim).</summary>
    public static SKShader Spun(SKPoint center, double light, double dark) =>
        Gradients.Sweep(center, [Gray(light), Gray(dark + 0.05), Gray(light - 0.05), Gray(dark), Gray(light)]);

    // MARK: Foil

    private static (float At, double R, double G, double B)[] FoilStops(Finish finish, bool lettering) => (finish, lettering) switch
    {
        (Finish.Gold, true) => [(0, 1, 0.94, 0.66), (0.3f, 0.95, 0.78, 0.36), (0.55f, 0.7, 0.5, 0.17), (0.78f, 0.88, 0.68, 0.28), (1, 0.98, 0.87, 0.52)],
        (Finish.Silver, true) => [(0, 1, 1, 1), (0.3f, 0.86, 0.88, 0.91), (0.55f, 0.55, 0.57, 0.61), (0.78f, 0.8, 0.82, 0.86), (1, 0.95, 0.96, 0.98)],
        (Finish.Gold, false) =>
        [
            (0, 0.42, 0.28, 0.08), (0.14f, 0.78, 0.58, 0.2), (0.24f, 1, 0.92, 0.6), (0.3f, 0.86, 0.66, 0.24), (0.46f, 0.5, 0.33, 0.09),
            (0.6f, 0.82, 0.62, 0.24), (0.7f, 1, 0.95, 0.7), (0.78f, 0.9, 0.72, 0.3), (0.92f, 0.56, 0.38, 0.12), (1, 0.74, 0.55, 0.2),
        ],
        _ =>
        [
            (0, 0.36, 0.37, 0.4), (0.14f, 0.72, 0.74, 0.78), (0.24f, 1, 1, 1), (0.3f, 0.8, 0.82, 0.85), (0.46f, 0.42, 0.43, 0.46),
            (0.6f, 0.76, 0.78, 0.82), (0.7f, 0.98, 0.99, 1), (0.78f, 0.82, 0.84, 0.88), (0.92f, 0.5, 0.51, 0.55), (1, 0.7, 0.72, 0.76),
        ],
    };

    /// <summary>
    /// Hot-stamped foil across <paramref name="rect"/>: a mirror of the room (bright and dark bands), its faint streaks
    /// and sparkle; down each letter for lettering (lit on its tops, darker below).
    /// </summary>
    public static SKShader Foil(Finish finish, SKRect rect, bool lettering = false)
    {
        var stops = FoilStops(finish, lettering);
        using var gradient = Gradients.Linear(rect, lettering ? new Unit(0.45f, 0) : new Unit(0, 0.15f), lettering ? new Unit(0.55f, 1) : new Unit(1, 0.85f),
            stops.Select(stop => Rgb(stop.R, stop.G, stop.B)).ToArray(), stops.Select(stop => stop.At).ToArray());
        using var texture = Textures.Shader(SkinTexture.Foil, origin: rect.Location);
        return SKShader.CreateCompose(texture, gradient, SKBlendMode.Multiply);
    }

    /// <summary>
    /// What <paramref name="draw"/> draws (in the color it is given) printed in foil, pressed into the surface (a hairline
    /// shadow under it); or as it is, in <paramref name="plain"/>, without a finish.
    /// </summary>
    public static void Print(SKCanvas canvas, SKRect bounds, Finish? finish, SKColor plain, Action<SKColor> draw, bool lettering = false)
    {
        if (finish is not { } metal)
        {
            draw(plain);
            return;
        }
        canvas.Save();
        canvas.Translate(0, 0.6f);
        draw(Black(0.45));
        canvas.Restore();
        canvas.SaveLayer();
        draw(SKColors.Black);
        canvas.Fill(bounds, Foil(metal, bounds, lettering), 1, SKBlendMode.SrcIn);
        canvas.Restore();
    }
}

/// <summary>The keys' symbols (the Mac's SF Symbols), drawn in a box.</summary>
internal enum Glyph
{
    Play, Pause, Stop, Previous, Next, Rewind, FastForward, PlayPause, Shuffle, Repeat, RepeatOne, Heart, HeartFilled, Speaker, SpeakerMuted,
    Folder, List, Asterisk, Bars, Close, ChevronDown, DashedRectangle, Shrink, Eject,
}

internal static class Glyphs
{
    private static SKPath Triangle(SKRect box, bool right) => Shapes.Build(b =>
    {
        b.MoveTo(right ? box.Left : box.Right, box.Top);
        b.LineTo(right ? box.Right : box.Left, box.MidY);
        b.LineTo(right ? box.Left : box.Right, box.Bottom);
        b.Close();
    });

    private static SKRect Part(SKRect box, float x, float y, float width, float height) =>
        SKRect.Create(box.Left + box.Width * x, box.Top + box.Height * y, box.Width * width, box.Height * height);

    /// <summary>The symbol fitted in a square of <paramref name="size"/> centered on <paramref name="center"/>.</summary>
    public static void Draw(SKCanvas canvas, Glyph glyph, SKPoint center, float size, SKColor color)
    {
        using var shader = SKShader.CreateColor(color);
        Draw(canvas, glyph, center, size, shader);
    }

    public static void Draw(SKCanvas canvas, Glyph glyph, SKPoint center, float size, SKShader shader)
    {
        var box = Shapes.Square(center, size);
        var paint = Paint.Of(SKColors.Black, shader);
        var stroke = Math.Max(size * 0.13f, 1);
        void Fill(SKPath path)
        {
            paint.Style = SKPaintStyle.Fill;
            canvas.DrawPath(path, paint);
            path.Dispose();
        }
        void Line(SKPath path, float width)
        {
            paint.Style = SKPaintStyle.Stroke;
            paint.StrokeWidth = width;
            paint.StrokeCap = SKStrokeCap.Round;
            paint.StrokeJoin = SKStrokeJoin.Round;
            canvas.DrawPath(path, paint);
            paint.Style = SKPaintStyle.Fill;
            path.Dispose();
        }
        switch (glyph)
        {
            case Glyph.Play:
                Fill(Triangle(Part(box, 0.18f, 0.08f, 0.72f, 0.84f), true));
                break;
            case Glyph.Pause:
                Fill(Shapes.Round(Part(box, 0.18f, 0.1f, 0.24f, 0.8f), size * 0.04f));
                Fill(Shapes.Round(Part(box, 0.58f, 0.1f, 0.24f, 0.8f), size * 0.04f));
                break;
            case Glyph.Stop:
                Fill(Shapes.Round(Part(box, 0.14f, 0.14f, 0.72f, 0.72f), size * 0.08f));
                break;
            case Glyph.Previous:
                Fill(Shapes.Round(Part(box, 0.06f, 0.14f, 0.13f, 0.72f), size * 0.03f));
                Fill(Triangle(Part(box, 0.2f, 0.14f, 0.38f, 0.72f), false));
                Fill(Triangle(Part(box, 0.56f, 0.14f, 0.38f, 0.72f), false));
                break;
            case Glyph.Next:
                Fill(Triangle(Part(box, 0.06f, 0.14f, 0.38f, 0.72f), true));
                Fill(Triangle(Part(box, 0.42f, 0.14f, 0.38f, 0.72f), true));
                Fill(Shapes.Round(Part(box, 0.81f, 0.14f, 0.13f, 0.72f), size * 0.03f));
                break;
            case Glyph.Rewind:
                Fill(Triangle(Part(box, 0.04f, 0.18f, 0.46f, 0.64f), false));
                Fill(Triangle(Part(box, 0.5f, 0.18f, 0.46f, 0.64f), false));
                break;
            case Glyph.FastForward:
                Fill(Triangle(Part(box, 0.04f, 0.18f, 0.46f, 0.64f), true));
                Fill(Triangle(Part(box, 0.5f, 0.18f, 0.46f, 0.64f), true));
                break;
            case Glyph.PlayPause:
                Fill(Triangle(Part(box, 0.02f, 0.2f, 0.46f, 0.6f), true));
                Fill(Shapes.Round(Part(box, 0.58f, 0.2f, 0.14f, 0.6f), size * 0.03f));
                Fill(Shapes.Round(Part(box, 0.8f, 0.2f, 0.14f, 0.6f), size * 0.03f));
                break;
            case Glyph.Shuffle:
            {
                var width = stroke * 0.9f;
                Line(Shapes.Build(b =>
                {
                    b.MoveTo(box.Left + size * 0.06f, box.Top + size * 0.3f);
                    b.LineTo(box.Left + size * 0.3f, box.Top + size * 0.3f);
                    b.CubicTo(box.Left + size * 0.55f, box.Top + size * 0.3f, box.Left + size * 0.5f, box.Top + size * 0.7f, box.Left + size * 0.78f, box.Top + size * 0.7f);
                    b.MoveTo(box.Left + size * 0.06f, box.Top + size * 0.7f);
                    b.LineTo(box.Left + size * 0.3f, box.Top + size * 0.7f);
                    b.CubicTo(box.Left + size * 0.55f, box.Top + size * 0.7f, box.Left + size * 0.5f, box.Top + size * 0.3f, box.Left + size * 0.78f, box.Top + size * 0.3f);
                }), width);
                Fill(Triangle(Part(box, 0.76f, 0.17f, 0.2f, 0.26f), true));
                Fill(Triangle(Part(box, 0.76f, 0.57f, 0.2f, 0.26f), true));
                break;
            }
            case Glyph.Repeat:
            case Glyph.RepeatOne:
            {
                var width = stroke * 0.9f;
                Line(Shapes.Build(b =>
                {
                    b.MoveTo(box.Left + size * 0.12f, box.Top + size * 0.55f);
                    b.LineTo(box.Left + size * 0.12f, box.Top + size * 0.42f);
                    b.QuadTo(box.Left + size * 0.12f, box.Top + size * 0.28f, box.Left + size * 0.26f, box.Top + size * 0.28f);
                    b.LineTo(box.Left + size * 0.76f, box.Top + size * 0.28f);
                    b.MoveTo(box.Left + size * 0.88f, box.Top + size * 0.45f);
                    b.LineTo(box.Left + size * 0.88f, box.Top + size * 0.58f);
                    b.QuadTo(box.Left + size * 0.88f, box.Top + size * 0.72f, box.Left + size * 0.74f, box.Top + size * 0.72f);
                    b.LineTo(box.Left + size * 0.24f, box.Top + size * 0.72f);
                }), width);
                Fill(Triangle(Part(box, 0.72f, 0.15f, 0.18f, 0.26f), true));
                Fill(Triangle(Part(box, 0.1f, 0.59f, 0.18f, 0.26f), false));
                if (glyph == Glyph.RepeatOne)
                {
                    using var font = Fonts.System(size * 0.36f, SKFontStyleWeight.Black);
                    canvas.DrawText("1", center.X, Lettering.Baseline(font, center.Y), SKTextAlign.Center, font, paint);
                }
                break;
            }
            case Glyph.Heart:
            case Glyph.HeartFilled:
            {
                var heart = Shapes.Build(b =>
                {
                    b.MoveTo(center.X, box.Top + size * 0.88f);
                    b.CubicTo(box.Left + size * 0.1f, box.Top + size * 0.58f, box.Left - size * 0.02f, box.Top + size * 0.28f, box.Left + size * 0.22f, box.Top + size * 0.16f);
                    b.CubicTo(box.Left + size * 0.36f, box.Top + size * 0.1f, box.Left + size * 0.46f, box.Top + size * 0.2f, center.X, box.Top + size * 0.3f);
                    b.CubicTo(box.Left + size * 0.54f, box.Top + size * 0.2f, box.Left + size * 0.64f, box.Top + size * 0.1f, box.Left + size * 0.78f, box.Top + size * 0.16f);
                    b.CubicTo(box.Left + size * 1.02f, box.Top + size * 0.28f, box.Left + size * 0.9f, box.Top + size * 0.58f, center.X, box.Top + size * 0.88f);
                    b.Close();
                });
                if (glyph == Glyph.HeartFilled) Fill(heart);
                else Line(heart, stroke * 0.85f);
                break;
            }
            case Glyph.Speaker:
            case Glyph.SpeakerMuted:
                Fill(Shapes.Build(b =>
                {
                    b.MoveTo(box.Left + size * 0.08f, box.Top + size * 0.36f);
                    b.LineTo(box.Left + size * 0.26f, box.Top + size * 0.36f);
                    b.LineTo(box.Left + size * 0.5f, box.Top + size * 0.14f);
                    b.LineTo(box.Left + size * 0.5f, box.Top + size * 0.86f);
                    b.LineTo(box.Left + size * 0.26f, box.Top + size * 0.64f);
                    b.LineTo(box.Left + size * 0.08f, box.Top + size * 0.64f);
                    b.Close();
                }));
                if (glyph == Glyph.Speaker)
                {
                    Line(Shapes.Build(b => b.AddArc(Shapes.Square(new SKPoint(box.Left + size * 0.5f, center.Y), size * 0.4f), -50, 100)), stroke * 0.8f);
                }
                else
                {
                    Line(Shapes.Build(b =>
                    {
                        b.MoveTo(box.Left + size * 0.62f, box.Top + size * 0.36f);
                        b.LineTo(box.Left + size * 0.9f, box.Top + size * 0.64f);
                        b.MoveTo(box.Left + size * 0.9f, box.Top + size * 0.36f);
                        b.LineTo(box.Left + size * 0.62f, box.Top + size * 0.64f);
                    }), stroke * 0.8f);
                }
                break;
            case Glyph.Folder:
                Fill(Shapes.Build(b =>
                {
                    b.MoveTo(box.Left + size * 0.06f, box.Top + size * 0.22f);
                    b.LineTo(box.Left + size * 0.38f, box.Top + size * 0.22f);
                    b.LineTo(box.Left + size * 0.46f, box.Top + size * 0.32f);
                    b.LineTo(box.Left + size * 0.94f, box.Top + size * 0.32f);
                    b.LineTo(box.Left + size * 0.94f, box.Top + size * 0.82f);
                    b.LineTo(box.Left + size * 0.06f, box.Top + size * 0.82f);
                    b.Close();
                }));
                break;
            case Glyph.List:
                for (var row = 0; row < 3; row++)
                {
                    var y = box.Top + size * (0.24f + row * 0.26f);
                    Fill(Shapes.Circle(new SKPoint(box.Left + size * 0.12f, y), size * 0.08f));
                    Fill(Shapes.Round(SKRect.Create(box.Left + size * 0.3f, y - size * 0.06f, size * 0.64f, size * 0.12f), size * 0.06f));
                }
                break;
            case Glyph.Asterisk:
                for (var arm = 0; arm < 3; arm++)
                {
                    var angle = Math.PI / 2 + arm * Math.PI / 3;
                    Line(Shapes.Build(b =>
                    {
                        b.MoveTo(Shapes.Polar(center, angle, size * 0.4));
                        b.LineTo(Shapes.Polar(center, angle + Math.PI, size * 0.4));
                    }), stroke);
                }
                break;
            case Glyph.Bars:
                Fill(Shapes.Round(Part(box, 0.08f, 0.5f, 0.22f, 0.4f), size * 0.03f));
                Fill(Shapes.Round(Part(box, 0.39f, 0.1f, 0.22f, 0.8f), size * 0.03f));
                Fill(Shapes.Round(Part(box, 0.7f, 0.32f, 0.22f, 0.58f), size * 0.03f));
                break;
            case Glyph.Close:
                Line(Shapes.Build(b =>
                {
                    b.MoveTo(box.Left + size * 0.2f, box.Top + size * 0.2f);
                    b.LineTo(box.Left + size * 0.8f, box.Top + size * 0.8f);
                    b.MoveTo(box.Left + size * 0.8f, box.Top + size * 0.2f);
                    b.LineTo(box.Left + size * 0.2f, box.Top + size * 0.8f);
                }), stroke * 1.1f);
                break;
            case Glyph.ChevronDown:
                Line(Shapes.Build(b =>
                {
                    b.MoveTo(box.Left + size * 0.15f, box.Top + size * 0.35f);
                    b.LineTo(center.X, box.Top + size * 0.68f);
                    b.LineTo(box.Left + size * 0.85f, box.Top + size * 0.35f);
                }), stroke * 1.1f);
                break;
            case Glyph.DashedRectangle:
            {
                using var dash = SKPathEffect.CreateDash([size * 0.12f, size * 0.08f], 0);
                paint.PathEffect = dash;
                Line(Shapes.Round(Part(box, 0.08f, 0.2f, 0.84f, 0.6f), size * 0.06f), stroke * 0.7f);
                paint.PathEffect = null;
                break;
            }
            case Glyph.Shrink:
                Line(Shapes.Build(b =>
                {
                    b.MoveTo(box.Left + size * 0.1f, box.Top + size * 0.1f);
                    b.LineTo(box.Left + size * 0.42f, box.Top + size * 0.42f);
                    b.MoveTo(box.Left + size * 0.9f, box.Top + size * 0.9f);
                    b.LineTo(box.Left + size * 0.58f, box.Top + size * 0.58f);
                    b.MoveTo(box.Left + size * 0.42f, box.Top + size * 0.18f);
                    b.LineTo(box.Left + size * 0.42f, box.Top + size * 0.42f);
                    b.LineTo(box.Left + size * 0.18f, box.Top + size * 0.42f);
                    b.MoveTo(box.Left + size * 0.58f, box.Top + size * 0.82f);
                    b.LineTo(box.Left + size * 0.58f, box.Top + size * 0.58f);
                    b.LineTo(box.Left + size * 0.82f, box.Top + size * 0.58f);
                }), stroke * 0.8f);
                break;
            case Glyph.Eject:
                Fill(Shapes.Build(b =>
                {
                    b.MoveTo(center.X, box.Top + size * 0.12f);
                    b.LineTo(box.Left + size * 0.9f, box.Top + size * 0.58f);
                    b.LineTo(box.Left + size * 0.1f, box.Top + size * 0.58f);
                    b.Close();
                }));
                Fill(Shapes.Rect(Part(box, 0.1f, 0.7f, 0.8f, 0.16f)));
                break;
        }
    }
}
