using Groovelight.Audio;
using SkiaSharp;

namespace Groovelight.Visualizers;

public enum VisualizerStyle { BarsAndWaves, Lights, Ambience, Magnetosphere }

public static class VisualizerStyles
{
    public static string DisplayName(this VisualizerStyle style) => style switch
    {
        VisualizerStyle.BarsAndWaves => "Bars & Waves",
        VisualizerStyle.Lights => "Lights",
        VisualizerStyle.Ambience => "Ambience",
        _ => "Magnetosphere",
    };

    /// <summary>The Mac's raw values ("barsAndWaves"...), kept in the preferences as <c>visualizer.style</c>.</summary>
    public static string RawValue(this VisualizerStyle style) => style switch
    {
        VisualizerStyle.BarsAndWaves => "barsAndWaves",
        VisualizerStyle.Lights => "lights",
        VisualizerStyle.Ambience => "ambience",
        _ => "magnetosphere",
    };

    public static VisualizerStyle Parse(string? raw) =>
        Enum.GetValues<VisualizerStyle>().FirstOrDefault(style => style.RawValue() == raw, VisualizerStyle.BarsAndWaves);

    /// <summary>Feedback parameters: zoom per frame, rotation per frame (radians), decay. Null: no trails.</summary>
    internal static (float Zoom, float Rotation, float Decay)? Feedback(this VisualizerStyle style) => style switch
    {
        VisualizerStyle.BarsAndWaves => null,
        VisualizerStyle.Lights => (1.006f, 0.002f, 0.90f),
        VisualizerStyle.Ambience => (1.03f, 0.012f, 0.92f),
        _ => (1.0f, 0.0f, 0.8f),
    };
}

/// <summary>
/// Draws the visualizers frame by frame from the player's spectrum (the Mac's VisualizerRenderer): the classic feedback
/// trail (the previous frame zoomed, turned, warped and faded) under each style, in a half-float buffer, tone mapped
/// when presented. Rendered at a modest size and scaled up by the view: the looks are soft glows and trails.
/// </summary>
public sealed class VisualizerRenderer : IDisposable
{
    public VisualizerStyle Style { get; set; } = VisualizerStyle.BarsAndWaves;

    private readonly Func<SpectrumFrame> frameSource;
    private readonly DateTime start = DateTime.UtcNow;
    private readonly float[] bands = new float[SpectrumFrame.BandCount];
    private readonly float[] peaks = new float[SpectrumFrame.BandCount];
    private readonly int[] peakHold = new int[SpectrumFrame.BandCount];
    private float[] waveform = new float[SpectrumFrame.WaveformCount];
    private float beat;
    private int lastBeatCount;
    private float hue = 0.55f;
    private (float Bass, float Mid, float Treble, float Level) smoothed;
    private SKSurface? previous, current;
    private int width, height;
    private VisualizerStyle? clearedFor;
    private readonly Particles particles = new(12_000);

    private static readonly Lazy<Shaders> Compiled = new(() => new Shaders());

    public VisualizerRenderer(Func<SpectrumFrame> frameSource) => this.frameSource = frameSource;

    /// <summary>Renders the next frame at <paramref name="frameWidth"/> by <paramref name="frameHeight"/> and returns it (owned by the renderer).</summary>
    public SKImage RenderFrame(int frameWidth, int frameHeight)
    {
        EnsureSurfaces(frameWidth, frameHeight);
        if (clearedFor != Style)
        {
            previous!.Canvas.Clear(SKColors.Black);
            clearedFor = Style;
        }
        var u = UpdateUniforms();
        var canvas = current!.Canvas;
        canvas.Clear(SKColors.Black);
        var shaders = Compiled.Value;
        using var previousImage = previous!.Snapshot();
        if (Style.Feedback() is not null)
        {
            using var previousShader = previousImage.ToShader(SKShaderTileMode.Decal, SKShaderTileMode.Decal, new SKSamplingOptions(SKFilterMode.Linear));
            using var feedback = shaders.Feedback.ToShader(Uniforms(shaders.Feedback, u), new SKRuntimeEffectChildren(shaders.Feedback) { ["previous"] = previousShader });
            using var paint = new SKPaint { Shader = feedback };
            canvas.DrawRect(0, 0, width, height, paint);
        }
        switch (Style)
        {
            case VisualizerStyle.BarsAndWaves:
                Draw(canvas, shaders.Bars, u, SKBlendMode.SrcOver);
                break;
            case VisualizerStyle.Lights:
                Draw(canvas, shaders.Lights, u, SKBlendMode.Plus);
                break;
            case VisualizerStyle.Ambience:
                Draw(canvas, shaders.Ambience, u, SKBlendMode.Plus);
                break;
            case VisualizerStyle.Magnetosphere:
                particles.Update(u, width, height);
                particles.Draw(canvas, u, width, height);
                break;
        }
        (previous, current) = (current, previous);
        // Soft tone map so additive glows do not clip harshly.
        using var output = SKSurface.Create(new SKImageInfo(width, height, SKColorType.Bgra8888, SKAlphaType.Premul))!;
        using var frame = previous!.Snapshot();
        using var frameShader = frame.ToShader();
        using var present = shaders.Present.ToShader(new SKRuntimeEffectUniforms(shaders.Present), new SKRuntimeEffectChildren(shaders.Present) { ["source"] = frameShader });
        using var presentPaint = new SKPaint { Shader = present };
        output.Canvas.DrawRect(0, 0, width, height, presentPaint);
        lastFrame?.Dispose();
        lastFrame = output.Snapshot();
        return lastFrame;
    }

    private SKImage? lastFrame;

    private void Draw(SKCanvas canvas, SKRuntimeEffect effect, FrameUniforms u, SKBlendMode blend)
    {
        using var shader = effect.ToShader(Uniforms(effect, u));
        using var paint = new SKPaint { Shader = shader, BlendMode = blend };
        canvas.DrawRect(0, 0, width, height, paint);
    }

    internal readonly record struct FrameUniforms(float Width, float Height, float Time, float Bass, float Mid, float Treble, float Level, float Beat,
                                                  float Zoom, float Rotation, float Decay, float Hue, float[] Bands, float[] Peaks, float[] Wave);

    private SKRuntimeEffectUniforms Uniforms(SKRuntimeEffect effect, FrameUniforms u)
    {
        var uniforms = new SKRuntimeEffectUniforms(effect);
        void Set(string name, object value)
        {
            if (!effect.Uniforms.Contains(name)) return;
            switch (value)
            {
                case float number: uniforms[name] = number; break;
                case float[] array: uniforms[name] = array; break;
                case SKPoint point: uniforms[name] = new[] { point.X, point.Y }; break;
            }
        }
        Set("resolution", new SKPoint(u.Width, u.Height));
        Set("time", u.Time);
        Set("bass", u.Bass);
        Set("mid", u.Mid);
        Set("treble", u.Treble);
        Set("level", u.Level);
        Set("beat", u.Beat);
        Set("zoom", u.Zoom);
        Set("rotation", u.Rotation);
        Set("decay", u.Decay);
        Set("hue", u.Hue);
        Set("bands", u.Bands);
        Set("peaks", u.Peaks);
        Set("wave", u.Wave);
        return uniforms;
    }

    private FrameUniforms UpdateUniforms()
    {
        var frame = frameSource();
        for (var i = 0; i < Math.Min(bands.Length, frame.Bands.Length); i++)
        {
            var target = frame.Bands[i];
            // Fast attack, slow release, like a VU meter.
            bands[i] = target > bands[i] ? bands[i] + (target - bands[i]) * 0.6f : Math.Max(target, bands[i] - 0.025f);
            if (bands[i] >= peaks[i])
            {
                peaks[i] = bands[i];
                peakHold[i] = 20;
            }
            else if (peakHold[i] > 0) peakHold[i]--;
            else peaks[i] = Math.Max(bands[i], peaks[i] - 0.008f);
        }
        if (frame.Waveform.Length == waveform.Length) waveform = frame.Waveform;
        if (frame.BeatCount != lastBeatCount)
        {
            lastBeatCount = frame.BeatCount;
            beat = 1;
            hue = (hue + 0.07f) % 1;
        }
        else beat *= 0.88f;
        hue = (hue + 0.0008f) % 1;
        static float Smooth(float old, float value) => old + (value - old) * 0.25f;
        smoothed = (Smooth(smoothed.Bass, frame.Bass), Smooth(smoothed.Mid, frame.Mid), Smooth(smoothed.Treble, frame.Treble), Smooth(smoothed.Level, frame.Level));
        var feedback = Style.Feedback() ?? (1, 0, 0);
        // The shaders sample 64 bands and a 128-point wave (Skia's shaders take fixed sizes).
        var wave = new float[128];
        for (var i = 0; i < wave.Length; i++) wave[i] = waveform[i * waveform.Length / wave.Length];
        return new FrameUniforms(width, height, (float)(DateTime.UtcNow - start).TotalSeconds, smoothed.Bass, smoothed.Mid, smoothed.Treble, smoothed.Level, beat,
                                 feedback.Zoom, feedback.Rotation * (1 + smoothed.Mid * 2), feedback.Decay, hue, (float[])bands.Clone(), (float[])peaks.Clone(), wave);
    }

    private void EnsureSurfaces(int frameWidth, int frameHeight)
    {
        if (previous is not null && frameWidth == width && frameHeight == height) return;
        previous?.Dispose();
        current?.Dispose();
        width = Math.Max(frameWidth, 1);
        height = Math.Max(frameHeight, 1);
        var info = new SKImageInfo(width, height, SKColorType.RgbaF16, SKAlphaType.Premul);
        previous = SKSurface.Create(info);
        current = SKSurface.Create(info);
        previous!.Canvas.Clear(SKColors.Black);
        clearedFor = Style;
    }

    public void Dispose()
    {
        previous?.Dispose();
        current?.Dispose();
        lastFrame?.Dispose();
    }

    /// <summary>
    /// The Magnetosphere's particles, pulled by three orbiting magnets whose strength follows bass, mid and treble
    /// (the Mac's compute shader, here on the CPU), drawn as additive glowing dots.
    /// </summary>
    private sealed class Particles(int count)
    {
        private readonly float[] x = new float[count], y = new float[count], vx = new float[count], vy = new float[count], life = new float[count], hue = new float[count];
        private bool seeded;

        private static float Hash(float n)
        {
            var value = MathF.Sin(n) * 43758.5453123f;
            return value - MathF.Floor(value);
        }

        public void Update(FrameUniforms u, int width, int height)
        {
            var aspect = u.Width / u.Height;
            if (!seeded)
            {
                var random = new Random(7);
                for (var i = 0; i < count; i++)
                {
                    x[i] = random.NextSingle() * 2 - 1;
                    y[i] = random.NextSingle() * 2 - 1;
                    life[i] = random.NextSingle();
                    hue[i] = random.NextSingle();
                }
                seeded = true;
            }
            Span<float> strengths = [u.Bass, u.Mid, u.Treble];
            Span<float> mx = stackalloc float[3], my = stackalloc float[3];
            for (var k = 0; k < 3; k++)
            {
                var t = u.Time * (0.35f + 0.15f * k) + k * 2.1f;
                mx[k] = MathF.Cos(t) * 0.55f * aspect;
                my[k] = MathF.Sin(t * 1.3f) * 0.45f;
            }
            for (var i = 0; i < count; i++)
            {
                float ax = 0, ay = 0;
                for (var k = 0; k < 3; k++)
                {
                    var dx = mx[k] - x[i];
                    var dy = my[k] - y[i];
                    var dist2 = dx * dx + dy * dy + 0.04f;
                    var length = MathF.Sqrt(dx * dx + dy * dy) + 1e-6f;
                    var force = (0.1f + strengths[k] * 0.8f) / (dist2 + 0.15f);
                    ax += dx / length * force;
                    ay += dy / length * force;
                }
                ax += -y[i] * (0.8f + u.Mid * 1.5f);
                ay += x[i] * (0.8f + u.Mid * 1.5f);
                var push = 0.00045f * (1 + u.Beat * 2);
                vx[i] = vx[i] * 0.965f + ax * push;
                vy[i] = vy[i] * 0.965f + ay * push;
                x[i] += vx[i];
                y[i] += vy[i];
                life[i] -= 0.0025f;
                if (life[i] <= 0 || x[i] * x[i] + y[i] * y[i] > 6.25f)
                {
                    var seed = i * 0.6180339f + u.Time;
                    var angle = Hash(seed) * 6.2831853f;
                    var radius = 0.05f + Hash(seed + 1.7f) * 0.25f;
                    x[i] = MathF.Cos(angle) * radius;
                    y[i] = MathF.Sin(angle) * radius;
                    vx[i] = -MathF.Sin(angle) * 0.004f;
                    vy[i] = MathF.Cos(angle) * 0.004f;
                    life[i] = 0.5f + Hash(seed + 3.1f) * 0.5f;
                    hue[i] = (u.Hue + Hash(seed + 5.3f) * 0.25f) % 1;
                }
            }
        }

        public void Draw(SKCanvas canvas, FrameUniforms u, int width, int height)
        {
            var aspect = u.Width / u.Height;
            var size = (2 + u.Level * 4) * width / 900f + 1;
            using var paint = new SKPaint { BlendMode = SKBlendMode.Plus, IsAntialias = true, StrokeCap = SKStrokeCap.Round, StrokeWidth = size };
            // Grouped by color (hue in 24 steps, brightness in 4) to draw thousands of dots in few calls.
            var groups = new Dictionary<int, List<SKPoint>>();
            for (var i = 0; i < x.Length; i++)
            {
                var px = (x[i] / aspect * 0.5f + 0.5f) * width;
                var py = (0.5f - y[i] * 0.5f) * height;
                if (px < -4 || py < -4 || px > width + 4 || py > height + 4) continue;
                var key = (int)(hue[i] * 24) * 4 + Math.Clamp((int)(life[i] * 4), 0, 3);
                if (!groups.TryGetValue(key, out var points)) groups[key] = points = [];
                points.Add(new SKPoint(px, py));
            }
            foreach (var (key, points) in groups)
            {
                var (r, g, b) = Hsv((key / 4 + 0.5f) / 24f, 0.85f, 1);
                var brightness = ((key % 4) + 0.5f) / 4 * 0.09f * 4;
                paint.Color = new SKColor((byte)Math.Min(255, r * brightness * 255), (byte)Math.Min(255, g * brightness * 255), (byte)Math.Min(255, b * brightness * 255));
                canvas.DrawPoints(SKPointMode.Points, points.ToArray(), paint);
            }
        }

        private static (float R, float G, float B) Hsv(float h, float s, float v)
        {
            float Channel(float offset)
            {
                var k = MathF.Abs((h + offset) % 1 * 6 - 3) - 1;
                return v * (1 - s + s * Math.Clamp(k, 0, 1));
            }
            return (Channel(0), Channel(2f / 3), Channel(1f / 3));
        }
    }
}

/// <summary>The Mac's Metal fragment shaders in Skia's shading language.</summary>
internal sealed class Shaders
{
    public SKRuntimeEffect Present { get; }
    public SKRuntimeEffect Feedback { get; }
    public SKRuntimeEffect Bars { get; }
    public SKRuntimeEffect Lights { get; }
    public SKRuntimeEffect Ambience { get; }

    private const string Common = """
        float3 hsv2rgb(float3 c) {
            float3 p = abs(fract(c.xxx + float3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
            return c.z * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
        }
        """;

    private const string WaveSampler = """
        float sampleWave(float x) {
            float fx = clamp(x, 0.0, 1.0) * 127.0;
            int i = int(fx);
            float a = 0.0;
            float b = 0.0;
            for (int k = 0; k < 128; k++) {
                if (k == i) { a = wave[k]; }
                if (k == (i + 1 > 127 ? 127 : i + 1)) { b = wave[k]; }
            }
            return mix(a, b, fract(fx));
        }
        """;

    public Shaders()
    {
        Present = Compile("""
            uniform shader source;
            half4 main(float2 coord) {
                float3 c = source.eval(coord).rgb;
                c = c / (1.0 + c * 0.35);
                return half4(half3(c), 1.0);
            }
            """);
        // The previous frame, zoomed, turned, warped and faded: the classic feedback trail.
        Feedback = Compile("""
            uniform shader previous;
            uniform float2 resolution;
            uniform float time;
            uniform float bass;
            uniform float mid;
            uniform float zoom;
            uniform float rotation;
            uniform float decay;
            half4 main(float2 coord) {
                float2 uv = coord / resolution;
                float aspect = resolution.x / resolution.y;
                float2 c = uv - 0.5;
                c.x *= aspect;
                float r = length(c);
                float angle = rotation + 0.02 * sin(time * 0.7 + r * 6.0) * mid;
                float2x2 m = float2x2(cos(angle), -sin(angle), sin(angle), cos(angle));
                c = (m * c) / (zoom + 0.015 * bass);
                c.x /= aspect;
                return previous.eval((c + 0.5) * resolution) * decay;
            }
            """);
        // Windows Media Player's "Bars and Waves": LED segmented spectrum bars with peak caps, reflection and a scope.
        Bars = Compile(Common + """
            uniform float2 resolution;
            uniform float beat;
            uniform float hue;
            uniform float bands[64];
            uniform float peaks[64];
            uniform float wave[128];
            """ + WaveSampler + """
            half4 main(float2 coord) {
                float2 uv = coord / resolution;
                float2 p = float2(uv.x, 1.0 - uv.y);
                float3 col = mix(float3(0.01, 0.01, 0.04), float3(0.0, 0.04, 0.10), p.y);
                const float floorY = 0.26;
                const float maxH = 0.62;
                float fx = p.x * 64.0;
                int i = int(min(fx, 63.0));
                float local = fract(fx);
                float gap = smoothstep(0.08, 0.14, local) * smoothstep(0.92, 0.86, local);
                float band = 0.0;
                float peak = 0.0;
                for (int k = 0; k < 64; k++) {
                    if (k == i) { band = bands[k]; peak = peaks[k]; }
                }
                float h = band * maxH;
                float y = p.y - floorY;
                float t = clamp(y / maxH, 0.0, 1.0);
                float3 barColor = mix(float3(0.10, 0.85, 0.45), float3(1.0, 0.88, 0.15), smoothstep(0.35, 0.7, t));
                barColor = mix(barColor, float3(1.0, 0.22, 0.12), smoothstep(0.78, 0.95, t));
                barColor = mix(barColor, hsv2rgb(float3(fract(hue + float(i) / 64.0 * 0.3), 0.7, 1.0)), 0.25);
                if (y >= 0.0) {
                    float segment = smoothstep(0.15, 0.3, fract(y * 70.0));
                    if (y < h) {
                        col += barColor * gap * segment * (0.85 + 0.3 * beat);
                    }
                    float pk = peak * maxH;
                    col += float3(0.85, 0.95, 1.0) * gap * smoothstep(0.006, 0.002, abs(y - pk));
                } else {
                    float ry = -y;
                    float reflectH = h * 0.45;
                    if (ry < reflectH) {
                        col += barColor * gap * 0.22 * (1.0 - ry / (reflectH + 0.001));
                    }
                }
                float w = sampleWave(p.x);
                float d = abs(p.y - (0.9 + w * 0.08));
                col += float3(0.35, 0.75, 1.0) * smoothstep(0.004, 0.0, d);
                col += float3(0.10, 0.30, 0.70) * smoothstep(0.025, 0.0, d) * 0.5;
                return half4(half3(col), 1.0);
            }
            """);
        // iTunes 4 "Lights": colored glowing orbs dancing on Lissajous paths, sized by their frequency band.
        Lights = Compile(Common + """
            uniform float2 resolution;
            uniform float time;
            uniform float beat;
            uniform float hue;
            uniform float bands[64];
            half4 main(float2 coord) {
                float2 uv = coord / resolution;
                float aspect = resolution.x / resolution.y;
                float2 p = uv - 0.5;
                p.x *= aspect;
                float3 col = float3(0.0);
                for (int k = 0; k < 7; k++) {
                    float fk = float(k);
                    float energy = 0.0;
                    for (int b = 0; b < 64; b++) {
                        if (b == k * 9 + 3) { energy = bands[b]; }
                    }
                    float t = time * (0.25 + 0.06 * fk);
                    float2 c = float2(sin(t * 1.3 + fk * 1.7) * 0.42 * aspect, cos(t * 0.9 + fk * 2.3) * 0.33);
                    float radius = 0.03 + energy * 0.14 + beat * 0.02;
                    float d = length(p - c);
                    float3 tint = hsv2rgb(float3(fract(hue + fk / 7.0), 0.75, 1.0));
                    col += tint * (radius * radius) / (d * d + 0.0015) * 0.05 * (0.25 + energy);
                }
                return half4(half3(col), 1.0);
            }
            """);
        // Windows Media Player's "Ambience": a waveform ring and pulsing core over a zooming, swirling tunnel.
        Ambience = Compile(Common + """
            uniform float2 resolution;
            uniform float bass;
            uniform float level;
            uniform float beat;
            uniform float hue;
            uniform float wave[128];
            """ + WaveSampler + """
            half4 main(float2 coord) {
                float2 uv = coord / resolution;
                float aspect = resolution.x / resolution.y;
                float2 p = uv - 0.5;
                p.x *= aspect;
                float r = length(p);
                float a = atan(p.y, p.x) / 6.2831853 + 0.5;
                float w = sampleWave(a < 0.5 ? a * 2.0 : (1.0 - a) * 2.0);
                float ringR = 0.10 + bass * 0.10 + w * 0.07;
                float d = abs(r - ringR);
                float3 ring = hsv2rgb(float3(fract(hue + a * 0.5), 0.85, 1.0));
                float3 col = ring * smoothstep(0.010, 0.0, d) * (0.25 + 0.4 * level);
                col += hsv2rgb(float3(fract(hue + 0.5), 0.6, 1.0)) * smoothstep(0.12, 0.0, r) * (0.01 + beat * 0.12);
                return half4(half3(col), 1.0);
            }
            """);
    }

    private static SKRuntimeEffect Compile(string source) =>
        SKRuntimeEffect.CreateShader(source, out var errors) ?? throw new InvalidOperationException($"Visualizer shader: {errors}");
}
