using Groovelight.Audio;

namespace Groovelight.Tests;

public class AudioDecoderTests
{
    private static string Fixture(string name) => Path.Combine(AudioFixtures.Directory, name);

    private static float[] DecodeAll(AudioDecoder decoder)
    {
        var all = new List<float>();
        var buffer = new float[4096 * decoder.Channels];
        int frames;
        while ((frames = decoder.Read(buffer)) > 0) all.AddRange(buffer.AsSpan(0, frames * decoder.Channels).ToArray());
        return [.. all];
    }

    public static TheoryData<string> Formats => new(Directory.EnumerateFiles(AudioFixtures.Directory, "tone*").Select(Path.GetFileName).Order()!);

    [Theory]
    [MemberData(nameof(Formats))]
    public void DecodesEveryFixtureFormat(string name)
    {
        using var decoder = AudioDecoder.Open(Fixture(name));
        var samples = DecodeAll(decoder);
        var seconds = samples.Length / (double)decoder.Channels / decoder.SampleRate;
        Assert.True(seconds is > 0.95 and < 1.06, $"{name}: {seconds:0.000} s");
        // A 440 Hz tone, not silence.
        Assert.True(samples.Max() > 0.05f, $"{name} is silent");
        Assert.InRange(decoder.Duration, 0.95, 1.06);
    }

    [Theory]
    [InlineData("tone.flac", 16)]
    [InlineData("tone-hires.flac", 24)]
    [InlineData("tone.wav", 16)]
    [InlineData("tone-alac.m4a", 16)]
    [InlineData("tone.mp3", null)]
    public void ReportsTheFilesResolution(string name, int? bits)
    {
        using var decoder = AudioDecoder.Open(Fixture(name));
        Assert.Equal(bits, decoder.FileBitDepth);
        Assert.Equal(name == "tone-hires.flac" ? 96_000 : 44_100, decoder.FileSampleRate);
    }

    /// <summary>Seeking lands on the exact sample: what follows matches a decode from the start.</summary>
    [Theory]
    [InlineData("tone.flac")]
    [InlineData("tone.wav")]
    [InlineData("tone-alac.m4a")]
    [InlineData("tone.wv")]
    [InlineData("tone.mp3")]
    [InlineData("tone-aac.m4a")]
    [InlineData("tone.ogg")]
    public void SeeksSampleAccurately(string name)
    {
        float[] full;
        using (var decoder = AudioDecoder.Open(Fixture(name))) full = DecodeAll(decoder);
        using var seeking = AudioDecoder.Open(Fixture(name));
        seeking.Seek(0.5);
        Assert.Equal(22_050, seeking.Position);
        var after = new float[1000 * seeking.Channels];
        Assert.Equal(1000, seeking.Read(after));
        var expected = full.AsSpan(22_050 * seeking.Channels, after.Length).ToArray();
        // Lossless formats are bit exact; lossy ones too in practice (they warm up before the target), within rounding.
        var tolerance = name is "tone.mp3" or "tone-aac.m4a" or "tone.ogg" ? 0.001 : 0;
        for (var index = 0; index < after.Length; index++) Assert.True(Math.Abs(after[index] - expected[index]) <= tolerance, $"{name} sample {index}");
    }

    /// <summary>A CUE track is a region: its samples are exactly that slice of the file.</summary>
    [Fact]
    public void RegionsAreSlicesOfTheFile()
    {
        float[] full;
        using (var decoder = AudioDecoder.Open(Fixture("tone.flac"))) full = DecodeAll(decoder);
        using var region = AudioDecoder.Open(Fixture("tone.flac"), start: 0.4, end: 0.8);
        Assert.Equal(17_640, region.Length);
        var slice = DecodeAll(region);
        Assert.Equal(full.AsSpan(17_640, 17_640).ToArray(), slice);
        // The last region runs to the end of the file.
        using var last = AudioDecoder.Open(Fixture("tone.flac"), start: 0.8);
        Assert.Equal(full.AsSpan(35_280).ToArray(), DecodeAll(last));
    }

    [Fact]
    public void ResamplesToTheOutputRate()
    {
        using var decoder = AudioDecoder.Open(Fixture("tone.flac"), outputSampleRate: 48_000);
        var frames = DecodeAll(decoder).Length / decoder.Channels;
        Assert.InRange(frames, 47_900, 48_100);
        Assert.Equal(48_000, decoder.SampleRate);
        Assert.Equal(44_100, decoder.FileSampleRate);
    }

    [Fact]
    public void FailsOnFilesThatAreNotAudio()
    {
        using var scratch = new ScratchFolder();
        var path = scratch.Combine("not audio.flac");
        File.WriteAllText(path, "hello");
        Assert.Throws<AudioDecoderException>(() => AudioDecoder.Open(path));
    }
}
