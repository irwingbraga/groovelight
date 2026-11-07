using Groovelight.Audio;
using Groovelight.Visualizers;
using SkiaSharp;

namespace Groovelight.Tests;

public class VisualizerTests
{
    /// <summary>A loud frame with a beat and a sine scope.</summary>
    private static SpectrumFrame LoudFrame(int beat) => new()
    {
        Bands = Enumerable.Range(0, SpectrumFrame.BandCount).Select(index => 0.4f + 0.5f * MathF.Abs(MathF.Sin(index * 0.3f))).ToArray(),
        Waveform = Enumerable.Range(0, SpectrumFrame.WaveformCount).Select(index => MathF.Sin(index * 0.1f) * 0.6f).ToArray(),
        Bass = 0.8f, Mid = 0.6f, Treble = 0.4f, Level = 0.7f, IsBeat = true, BeatCount = beat,
    };

    [Theory]
    [InlineData(VisualizerStyle.BarsAndWaves)]
    [InlineData(VisualizerStyle.Lights)]
    [InlineData(VisualizerStyle.Ambience)]
    [InlineData(VisualizerStyle.Magnetosphere)]
    public void RendersEveryStyle(VisualizerStyle style)
    {
        var beat = 0;
        using var renderer = new VisualizerRenderer(() => LoudFrame(beat++ / 10)) { Style = style };
        SKImage? frame = null;
        for (var index = 0; index < 30; index++) frame = renderer.RenderFrame(320, 180);
        if (Environment.GetEnvironmentVariable("GL_VISUALIZER_DUMP") is { } folder)
        {
            using var data = frame!.Encode(SKEncodedImageFormat.Png, 100);
            File.WriteAllBytes(Path.Combine(folder, $"{style}.png"), data.ToArray());
        }
        using var bitmap = SKBitmap.FromImage(frame!);
        var lit = 0;
        for (var y = 0; y < bitmap.Height; y += 2)
            for (var x = 0; x < bitmap.Width; x += 2)
            {
                var pixel = bitmap.GetPixel(x, y);
                if (pixel.Red + pixel.Green + pixel.Blue > 90) lit++;
            }
        Assert.True(lit > 50, $"{style}: {lit} lit pixels");
    }

    [Fact]
    public void KeepsTheMacsStyleNames()
    {
        Assert.Equal("barsAndWaves", VisualizerStyle.BarsAndWaves.RawValue());
        Assert.Equal(VisualizerStyle.Magnetosphere, VisualizerStyles.Parse("magnetosphere"));
        Assert.Equal(VisualizerStyle.BarsAndWaves, VisualizerStyles.Parse(null));
    }
}
