using Groovelight.Core.Library;

namespace Groovelight.Tests;

public class AudioSpecTests
{
    [Fact]
    public void ClassifiesTiers()
    {
        Assert.Equal(QualityTier.Lossless, new AudioSpec("FLAC", 44_100, 16, 900, 2).Tier);
        Assert.Equal(QualityTier.HiResLossless, new AudioSpec("FLAC", 96_000, 24, 3000, 2).Tier);
        Assert.Equal(QualityTier.HiResLossless, new AudioSpec("Apple Lossless", 48_000, 24, null, 2).Tier);
        Assert.Equal(QualityTier.Lossless, new AudioSpec("WAVE", 48_000, 16, null, 2).Tier);
        Assert.Equal(QualityTier.Dsd, new AudioSpec("DSD Stream", 2_822_400, 1, null, 2).Tier);
        Assert.Equal(QualityTier.HighQuality, new AudioSpec("MP3", 44_100, null, 320, 2).Tier);
        Assert.Equal(QualityTier.Standard, new AudioSpec("MPEG-1 Layer III", 44_100, null, 192, 2).Tier);
        Assert.Equal(QualityTier.HighQuality, new AudioSpec("Ogg Opus", 48_000, null, 160, 2).Tier);
        Assert.Equal(QualityTier.HighQuality, new AudioSpec("AAC", 44_100, null, 250, 2).Tier);
    }

    [Fact]
    public void FormatsSummaries()
    {
        var hiRes = new AudioSpec("FLAC", 96_000, 24, 3000, 2);
        Assert.Equal("FLAC · 24-bit / 96 kHz", hiRes.Summary);
        Assert.Equal("FLAC 24/96", hiRes.CompactText);
        var cd = new AudioSpec("Apple Lossless", 44_100, 16, null, 2);
        Assert.Equal("ALAC · 16-bit / 44.1 kHz", cd.Summary);
        Assert.Equal("ALAC 16/44.1", cd.CompactText);
        var mp3 = new AudioSpec("MP3", 44_100, null, 320, 2);
        Assert.Equal("MP3 · 320 kbps · 44.1 kHz", mp3.Summary);
        Assert.Equal("MP3 320", mp3.CompactText);
        var dsd = new AudioSpec("DSD Stream", 2_822_400, 1, null, 2);
        Assert.Equal("DSF · DSD64 (2.8 MHz)", dsd.Summary);
        Assert.Equal("DSD64", dsd.CompactText);
    }

    [Fact]
    public void DetectsUniformAlbums()
    {
        var a = new AudioSpec("FLAC", 44_100, 16, 870, 2);
        var b = new AudioSpec("FLAC", 44_100, 16, 1010, 2);
        Assert.Equal(a, AudioSpec.Uniform([a, b]));

        // VBR MP3 averages snap to the same encoder setting.
        var v1 = new AudioSpec("MP3", 44_100, null, 245, 2);
        var v2 = new AudioSpec("MP3", 44_100, null, 262, 2);
        Assert.Equal(256, AudioSpec.Uniform([v1, v2])?.Bitrate);

        Assert.Null(AudioSpec.Uniform([a, new AudioSpec("FLAC", 96_000, 24, 3000, 2)]));
        Assert.Null(AudioSpec.Uniform([]));
    }

    /// <summary>Every codec's format name reads back as the same codec, so tiers agree with the Mac's.</summary>
    [Fact]
    public void CodecsRoundTrip()
    {
        foreach (var codec in Enum.GetValues<Codec>().Where(codec => codec != Codec.Unknown))
            Assert.Equal(codec, Codecs.FromFormatName(codec.FormatName()));
    }
}
