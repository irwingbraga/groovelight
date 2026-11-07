using SkiaSharp;

namespace Groovelight.Skins;

/// <summary>Where a drag is: where it began and where it is now, in the region's own coordinates.</summary>
public readonly record struct DragInfo(SKPoint Start, SKPoint Location)
{
    public SKPoint Translation => Location - Start;
}

/// <summary>
/// The players' keys, knobs and sliders, drawn each frame and touched like real ones: while drawing, each one says
/// where it is (in the canvas's coordinates of the moment, so a key drawn scaled or turned is touched where it shows)
/// and what it does; the host passes the pointer here, and the next frame draws the key pressed. A key held past a
/// moment repeats its hold (rewind and fast forward scanning), as the Mac's DeckPress does.
/// </summary>
public sealed class DeckUi
{
    private sealed record Region(string Id, SKPath? Path, SKRect Rect, SKMatrix Matrix, SKMatrix Inverse, Action? Tap, Action? Hold,
                                 Action<DragInfo>? Changed, Action<DragInfo>? Ended, Action<double>? Wheel, string? Title)
    {
        public bool Contains(SKPoint device)
        {
            var local = Inverse.MapPoint(device);
            return Path?.Contains(local.X, local.Y) ?? Rect.Contains(local);
        }
    }

    private List<Region> building = [], regions = [];
    private Region? active;
    private SKPoint start;
    private double pressedAt, lastHold;
    private bool didHold;
    private readonly Dictionary<string, object> state = [];

    /// <summary>The canvas being drawn on (set by <see cref="Begin"/>).</summary>
    public SKCanvas Canvas { get; private set; } = null!;
    /// <summary>Seconds on a steady clock, for motors and meters.</summary>
    public double Now { get; private set; }
    /// <summary>Something moves on its own: the host keeps drawing frames.</summary>
    public bool WantsFrames { get; private set; }
    /// <summary>The key held now (its id), for drawing it down.</summary>
    public string? Pressed => active?.Tap is not null || active?.Hold is not null ? active.Id : null;
    /// <summary>A region was touched or changed: draw again.</summary>
    public event Action? Invalidated;

    public void Begin(SKCanvas canvas, double now)
    {
        Canvas = canvas;
        Now = now;
        WantsFrames = active is not null;
        building = [];
    }

    public void End() => regions = building;

    /// <summary>Asks for frames while something moves (a motor, a needle, a scrolling title).</summary>
    public void Animate() => WantsFrames = true;

    /// <summary>A value kept between frames under <paramref name="id"/>.</summary>
    public T State<T>(string id, Func<T> make) where T : notnull
    {
        if (state.TryGetValue(id, out var value) && value is T typed) return typed;
        var made = make();
        state[id] = made;
        return made;
    }

    /// <summary>
    /// A drawing kept as an image at the canvas's scale (the record, the disc: drawn once, turned each frame), drawn again
    /// when its key or size changes.
    /// </summary>
    public SKImage Cached(string key, SKSize size, Action<SKCanvas> draw)
    {
        // The canvas's scale whatever it is turned by.
        var matrix = Canvas.TotalMatrix;
        var scale = Math.Max(MathF.Round(MathF.Sqrt(matrix.ScaleX * matrix.ScaleX + matrix.SkewY * matrix.SkewY) * 100) / 100, 0.1f);
        var width = Math.Max(1, (int)Math.Ceiling(size.Width * scale));
        var height = Math.Max(1, (int)Math.Ceiling(size.Height * scale));
        var id = $"{key}@{width}x{height}";
        // One image a slot ("record:" whatever the cover), so a new song's replaces the last.
        key = key.Split(':')[0];
        if (cache.TryGetValue(key, out var kept) && kept.Id == id) return kept.Image;
        using var surface = SKSurface.Create(new SKImageInfo(width, height, SKColorType.Rgba8888, SKAlphaType.Premul));
        surface.Canvas.Scale(width / size.Width, height / size.Height);
        draw(surface.Canvas);
        var image = surface.Snapshot();
        if (cache.TryGetValue(key, out var old)) old.Image.Dispose();
        cache[key] = (id, image);
        return image;
    }

    private readonly Dictionary<string, (string Id, SKImage Image)> cache = [];

    public void SetState<T>(string id, T value) where T : notnull => state[id] = value;

    public void ClearState(string id) => state.Remove(id);

    private void Add(string id, SKRect rect, SKPath? path, Action? tap, Action? hold, Action<DragInfo>? changed, Action<DragInfo>? ended, Action<double>? wheel, string? title)
    {
        var matrix = Canvas.TotalMatrix;
        if (!matrix.TryInvert(out var inverse)) return;
        building.Add(new Region(id, path, rect, matrix, inverse, tap, hold, changed, ended, wheel, title));
    }

    /// <summary>A key at <paramref name="rect"/>: tapped (released without holding), or held (repeating). True while held.</summary>
    public bool Press(string id, SKRect rect, Action tap, Action? hold = null, string? title = null, bool enabled = true, bool round = false)
    {
        if (!enabled) return false;
        var path = round ? Shapes.Oval(rect) : null;
        Add(id, rect, path, tap, hold, null, null, null, title);
        return active?.Id == id;
    }

    /// <summary>A surface dragged (a knob, a slider, a position bar): <paramref name="changed"/> from the touch on, then <paramref name="ended"/>.</summary>
    public bool Drag(string id, SKRect rect, Action<DragInfo> changed, Action<DragInfo>? ended = null, Action<double>? wheel = null, string? title = null, bool round = false)
    {
        var path = round ? Shapes.Oval(rect) : null;
        Add(id, rect, path, null, null, changed, ended, wheel, title);
        return active?.Id == id;
    }

    /// <summary>A surface scrolled with the wheel (a list).</summary>
    public void Wheel(string id, SKRect rect, Action<double> scroll) => Add(id, rect, null, null, null, null, null, scroll, null);

    private Region? Hit(SKPoint device)
    {
        for (var index = regions.Count - 1; index >= 0; index--)
        {
            if (regions[index].Contains(device) && (regions[index].Tap is not null || regions[index].Changed is not null)) return regions[index];
        }
        return null;
    }

    /// <summary>The tooltip of what is under the pointer, and whether it can be worked (for the hand cursor).</summary>
    public (bool Interactive, string? Title) Hover(SKPoint device) => Hit(device) is { } region ? (true, region.Title) : (false, null);

    public bool PointerDown(SKPoint device, double now)
    {
        active = Hit(device);
        if (active is null) return false;
        start = active.Inverse.MapPoint(device);
        pressedAt = now;
        lastHold = double.NegativeInfinity;
        didHold = false;
        active.Changed?.Invoke(new DragInfo(start, start));
        Invalidated?.Invoke();
        return true;
    }

    public void PointerMove(SKPoint device)
    {
        if (active?.Changed is not { } changed) return;
        changed(new DragInfo(start, active.Inverse.MapPoint(device)));
        Invalidated?.Invoke();
    }

    public void PointerUp(SKPoint device)
    {
        if (active is not { } region) return;
        active = null;
        if (region.Changed is not null) region.Ended?.Invoke(new DragInfo(start, region.Inverse.MapPoint(device)));
        else if (!didHold) region.Tap?.Invoke();
        Invalidated?.Invoke();
    }

    public void PointerCancel()
    {
        active = null;
        Invalidated?.Invoke();
    }

    public bool PointerWheel(SKPoint device, double delta)
    {
        for (var index = regions.Count - 1; index >= 0; index--)
        {
            if (regions[index].Wheel is { } wheel && regions[index].Contains(device))
            {
                wheel(delta);
                Invalidated?.Invoke();
                return true;
            }
        }
        return false;
    }

    /// <summary>Runs a held key's repeat: after 450 ms, every 150 ms.</summary>
    public void Tick(double now)
    {
        if (active?.Hold is not { } hold || now - pressedAt < 0.45 || now - lastHold < 0.15) return;
        lastHold = now;
        didHold = true;
        hold();
    }
}
