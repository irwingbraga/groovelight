using Groovelight.Skins;
using SkiaSharp;

namespace Groovelight.Tests;

public class SkinTests
{
    private static SkinPlayback Playback(bool playing = true) => new()
    {
        Title = "Paranoid Android", Artist = "Radiohead", Album = "OK Computer", IsPlaying = playing, Duration = 383, Time = () => 121.4,
        Format = SkinFormat.From(44100, 16, null, 2),
    };

    private static SKImage Render(SkinDeck deck, int width, int height, SkinPlayback playback, DeckControls controls, double now = 10)
    {
        using var surface = SKSurface.Create(new SKImageInfo(width, height));
        // Several frames, so motors, needles and eases settle.
        for (var frame = 0; frame < 6; frame++)
        {
            surface.Canvas.Clear(SKColors.Black);
            deck.Draw(surface.Canvas, new SKSize(width, height), now + frame * 0.05, playback, controls);
        }
        return surface.Snapshot();
    }

    private static void Dump(SKImage image, string name)
    {
        if (Environment.GetEnvironmentVariable("GL_SKIN_DUMP") is not { } folder) return;
        using var data = image.Encode(SKEncodedImageFormat.Png, 100);
        File.WriteAllBytes(Path.Combine(folder, name + ".png"), data.ToArray());
    }

    public static TheoryData<NowPlayingSkin, PcTheme, int, int> Looks => new()
    {
        { NowPlayingSkin.Vinyl, PcTheme.Classic, 1100, 700 },
        { NowPlayingSkin.Vinyl, PcTheme.Classic, 700, 1000 },
        { NowPlayingSkin.Cassette, PcTheme.Classic, 1100, 700 },
        { NowPlayingSkin.Cassette, PcTheme.Classic, 700, 1000 },
        { NowPlayingSkin.CompactDisc, PcTheme.Classic, 1100, 700 },
        { NowPlayingSkin.PcPlayer, PcTheme.Classic, 1100, 700 },
        { NowPlayingSkin.PcPlayer, PcTheme.Corona, 1100, 700 },
        { NowPlayingSkin.PcPlayer, PcTheme.Corona, 700, 1000 },
    };

    [Theory]
    [MemberData(nameof(Looks))]
    public void DrawsEveryPlayer(NowPlayingSkin skin, PcTheme theme, int width, int height)
    {
        var deck = new SkinDeck
        {
            Skin = skin, Theme = theme, Cassette = CassetteDesign.BuiltIn[skin == NowPlayingSkin.Cassette && width < height ? 5 : 0],
            Playlist = new SkinPlaylist([new("Airbag", "Radiohead", 284), new("Paranoid Android", "Radiohead", 383), new("Subterranean Homesick Alien", "Radiohead", 267)], 1, _ => { }),
        };
        var controls = new DeckControls
        {
            Volume = new SkinBinding<double>(() => 0.6, _ => { }), Love = new SkinBinding<bool>(() => true, _ => { }), Equalizer = new SkinBinding<bool>(() => true, _ => { }),
            Eject = () => { }, RepeatMode = DeckRepeat.All,
        };
        using var image = Render(deck, width, height, Playback(), controls);
        Dump(image, $"{skin}-{theme}-{width}x{height}");
        using var bitmap = SKBitmap.FromImage(image);
        var colors = new HashSet<SKColor>();
        for (var y = 0; y < bitmap.Height; y += 7)
            for (var x = 0; x < bitmap.Width; x += 7) colors.Add(bitmap.GetPixel(x, y));
        Assert.True(colors.Count > 200, $"{skin}: only {colors.Count} colors");
    }

    [Fact]
    public void DrawsEveryCassette()
    {
        foreach (var design in CassetteDesign.BuiltIn)
        {
            using var surface = SKSurface.Create(new SKImageInfo(502, 319));
            surface.Canvas.Clear(SKColors.Gray);
            CassetteFace.Draw(surface.Canvas, SKRect.Create(502, 319), design, new CassettePictures(), Playback());
            using var image = surface.Snapshot();
            Dump(image, "cassette-" + design.Name.Replace(' ', '-'));
        }
    }

    [Fact]
    public void KeysWorkThePlayer()
    {
        var deck = new SkinDeck { Skin = NowPlayingSkin.CompactDisc };
        var played = 0;
        var controls = new DeckControls { PlayPause = () => played++ };
        using var surface = SKSurface.Create(new SKImageInfo(1100, 700));
        deck.Draw(surface.Canvas, new SKSize(1100, 700), 0, Playback(false), controls);
        // Find the play key by scanning for a region that plays.
        var found = false;
        for (var y = 300; y < 700 && !found; y += 4)
            for (var x = 600; x < 1100 && !found; x += 4)
            {
                if (deck.Ui.Hover(new SKPoint(x, y)) is not (true, "Play")) continue;
                deck.Ui.PointerDown(new SKPoint(x, y), 1);
                deck.Ui.PointerUp(new SKPoint(x, y));
                found = true;
            }
        Assert.True(found);
        Assert.Equal(1, played);
    }

    [Fact]
    public void HeldKeysScan()
    {
        var ui = new DeckUi();
        var steps = 0;
        var tapped = 0;
        using var surface = SKSurface.Create(new SKImageInfo(100, 100));
        ui.Begin(surface.Canvas, 0);
        ui.Press("key", SKRect.Create(10, 10, 20, 20), () => tapped++, () => steps++);
        ui.End();
        ui.PointerDown(new SKPoint(15, 15), 0);
        for (var time = 0.0; time < 1; time += 0.05) ui.Tick(time);
        ui.PointerUp(new SKPoint(15, 15));
        Assert.Equal(0, tapped);
        Assert.InRange(steps, 3, 5);
    }

    [Fact]
    public void ReadsAndWritesTheMacsCassetteFile()
    {
        const string mac = """
        {
          "brand" : "GROOVELIGHT GX 60",
          "detailColor" : "#3C3C40",
          "format" : 1,
          "id" : "6B1C1C8E-0001-4C55-9C11-0000000000AA",
          "label" : {
            "background" : "#00000000",
            "bands" : [ { "color" : "#D6AE5C", "finish" : "gold", "height" : 0.012, "y" : 0.43 } ],
            "handwritten" : false, "showsArtwork" : false, "showsText" : true, "stripes" : [ ], "textColor" : "#D6AE5C", "textFinish" : "platinum"
          },
          "name" : "Mine",
          "reels" : { "hubColor" : "#E8E6E0", "ringColor" : "#C9A04A", "ringFinish" : "gold", "tapeColor" : "#2A1D14" },
          "shellClarity" : 2,
          "shellColor" : "#161618",
          "side" : "B",
          "tapeType" : "HIGH POSITION",
          "geometry" : { "aspectRatio" : 1.5, "hubRadius" : 0.06, "label" : { "height" : 0.6, "width" : 0.85, "x" : 0.075, "y" : 0.09 },
                         "leftReel" : { "x" : 0.3, "y" : 0.47 }, "reelRadius" : 0.165, "rightReel" : { "x" : 0.7, "y" : 0.47 },
                         "window" : { "height" : 0.18, "width" : 0.34, "x" : 0.33, "y" : 0.38 } },
          "later" : "ignored"
        }
        """;
        var design = CassetteDesign.Parse(mac);
        Assert.Equal("Mine", design.Name);
        Assert.Equal(0.8, design.ShellClarity);
        Assert.Equal(Finish.Gold, design.Label.Bands[0].Finish);
        // A finish from a later version reads as plain ink.
        Assert.Null(design.Label.TextFinish);
        Assert.Equal(0.3, design.Geometry!.LeftReel.X);
        var again = CassetteDesign.Parse(design.ToJson());
        Assert.Equal(design.ToJson(), again.ToJson());
        Assert.Contains("\"id\": \"6B1C1C8E-0001-4C55-9C11-0000000000AA\"", design.ToJson());
        Assert.Equal("#FFFFFF14", CassetteDesign.BuiltIn.First(d => d.Name == "Ice Chrome").Label.Background.Hex);
        // Fields left out take the classic design's.
        var sparse = CassetteDesign.Parse("""{ "name": "Sparse" }""");
        Assert.Equal(CassetteDesign.Classic.ShellColor, sparse.ShellColor);
        Assert.Throws<FormatException>(() => CassetteDesign.Parse("not json"));
    }

    [Fact]
    public void StoresSharesAndImportsCassettes()
    {
        var folder = Path.Combine(Path.GetTempPath(), "gl-cassettes-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new CassetteStore(Path.Combine(folder, "Store"));
            var mine = store.Duplicate(CassetteDesign.BuiltIn[1], "My Chrome");
            Assert.Single(store.Custom);
            var picture = Path.Combine(folder, "shell.png");
            using (var bitmap = new SKBitmap(10, 6))
            using (var data = bitmap.Encode(SKEncodedImageFormat.Png, 100)) File.WriteAllBytes(picture, data.ToArray());
            mine = store.SetPicture(CassetteStore.Picture.Shell, picture, mine);
            Assert.NotNull(store.PathOf(CassetteStore.Picture.Shell, mine));
            Assert.Throws<InvalidOperationException>(() => store.Save(CassetteDesign.BuiltIn[0]));
            var zip = Path.Combine(folder, "My Chrome.cassette.zip");
            store.Export(mine, zip);
            var other = new CassetteStore(Path.Combine(folder, "Other"));
            var imported = other.Import(zip);
            Assert.Equal(mine.Id, imported.Id);
            Assert.NotNull(other.PathOf(CassetteStore.Picture.Shell, imported));
            // Imported again where it already is: a copy with its own id.
            var copy = other.Import(zip);
            Assert.NotEqual(mine.Id, copy.Id);
            Assert.Equal(2, other.Custom.Count);
            // From its folder too.
            var third = new CassetteStore(Path.Combine(folder, "Third"));
            Assert.Equal(mine.Id, third.Import(store.FolderOf(mine)).Id);
            store.Delete(mine);
            Assert.Empty(store.Custom);
            Assert.Equal(CassetteDesign.BuiltIn[0].Id, store.Design(mine.Id).Id);
        }
        finally
        {
            Directory.Delete(folder, true);
        }
    }

    [Fact]
    public void KeepsTheMacsNamesAndFormats()
    {
        Assert.Equal("compactDisc", NowPlayingSkin.CompactDisc.RawValue());
        Assert.Equal(NowPlayingSkin.PcPlayer, SkinInfo.ParseSkin("pcPlayer"));
        Assert.Equal(PcTheme.Corona, SkinInfo.ParseTheme("corona"));
        Assert.Equal(1411, SkinFormat.From(44100, 16, null, 2).Kbps);
        Assert.Equal(320, SkinFormat.From(44100, null, 320_000, 2).Kbps);
        Assert.Equal("02:05", SkinInfo.ClockText(125.9));
    }
}

public class SkinTimingTests
{
    [Theory]
    [InlineData(NowPlayingSkin.Vinyl)]
    [InlineData(NowPlayingSkin.Cassette)]
    [InlineData(NowPlayingSkin.CompactDisc)]
    [InlineData(NowPlayingSkin.PcPlayer)]
    public void DrawsQuickly(NowPlayingSkin skin)
    {
        var deck = new SkinDeck { Skin = skin };
        var playback = new SkinPlayback { Title = "T", Artist = "A", IsPlaying = true, Duration = 200, Time = () => 50 };
        var controls = new DeckControls { Volume = new SkinBinding<double>(() => 0.5, _ => { }) };
        using var surface = SKSurface.Create(new SKImageInfo(1650, 1140));
        var watch = new System.Diagnostics.Stopwatch();
        var frames = 30;
        for (var frame = -5; frame < frames; frame++)
        {
            if (frame == 0) watch.Start();
            surface.Canvas.Save();
            surface.Canvas.Scale(1.5f);
            deck.Draw(surface.Canvas, new SKSize(1100, 760), frame / 60.0, playback, controls);
            surface.Canvas.Restore();
            surface.Canvas.Flush();
        }
        TestContext.Current.SendDiagnosticMessage($"{skin}: {watch.Elapsed.TotalMilliseconds / frames:0.0} ms a frame");
        File.AppendAllText(Path.Combine(Path.GetTempPath(), "gl-skin-timing.txt"), $"{skin}: {watch.Elapsed.TotalMilliseconds / frames:0.0} ms\n");
    }
}

public class SkinProfileTests
{
    [Fact]
    public void Profile()
    {
        using var surface = SKSurface.Create(new SKImageInfo(1650, 1140));
        var c = surface.Canvas;
        c.Scale(1.5f);
        var ui = new DeckUi();
        var lines = new List<string>();
        void Time(string name, Action draw)
        {
            ui.Begin(c, 0);
            draw();
            var watch = System.Diagnostics.Stopwatch.StartNew();
            for (var i = 0; i < 5; i++) { ui.Begin(c, i); draw(); ui.End(); }
            lines.Add($"{name}: {watch.Elapsed.TotalMilliseconds / 5:0.0} ms");
        }
        var all = SKRect.Create(1100, 760);
        var playback = new SkinPlayback { Title = "T", Artist = "A", IsPlaying = true, Duration = 200, Time = () => 50 };
        var controls = new DeckControls { Volume = new SkinBinding<double>(() => 0.5, _ => { }) };
        Time("walnut fill", () => Textures.Fill(c, all, SkinTexture.Walnut, -0.04));
        Time("walnut plain", () => Textures.Fill(c, all, SkinTexture.Walnut));
        Time("radial", () => c.Fill(all, Gradients.Radial(all, new Unit(0.4f, 0.25f), 50, 900, [Colors.White(0.08), Colors.Black(0.45)])));
        Time("turntable", () => Stages.Turntable(ui, SKRect.Create(20, 56, 600, 680), playback, _ => { }));
        Time("platter shadow", () => { using var p = Shapes.Circle(new SKPoint(300, 400), 250); c.Shadow(p, Colors.Black(0.6), 15, 0, 9); });
        Time("tonearm", () => Tonearm.Draw(c, 600, 10));
        Time("panel", () => Panels.Turntable(ui, SKRect.Create(640, 56, 440, 680), playback, controls));
        Time("plate", () => Materials.Plate(c, SKRect.Create(640, 100, 440, 500), SkinTexture.Aluminum, 10, 0.12, screws: 9));
        Time("knob", () => Controls.Knob(ui, "k", new SKPoint(900, 500), 66, "V", controls.Volume!));
        Time("switch", () => Controls.ToggleSwitch(ui, "s", new SKPoint(700, 500), 44, "S", 0, () => { }));
        Time("metal key", () => Controls.MetalKey(ui, "m", SKRect.Create(700, 300, 54, 44), "M", Glyph.Play, () => { }));
        Time("engraved", () => Lettering.Engraved(c, "START · STOP", new SKPoint(700, 400), 7.5f));
        Time("dial text", () => Lettering.Glowing(c, "Paranoid Android", 700, 200, Fonts.System(16), SKColors.White, SKColors.Orange, 3));
        Time("vu", () => Controls.VuMeter(ui, "vu", SKRect.Create(700, 200, 156, 96), 0, playback));
        Time("piano key", () => Controls.PianoKey(ui, "p", SKRect.Create(700, 300, 81, 93), "P", Glyph.Play, () => { }));
        Time("round key", () => Controls.RoundKey(ui, "r", new SKPoint(700, 300), 87, "R", Glyph.Play, () => { }));
        Time("counter", () => Controls.TapeCounter(ui, SKRect.Create(700, 300, 126, 42), playback));
        Time("cassette face", () => CassetteFace.Draw(c, SKRect.Create(20, 100, 600, 380), CassetteDesign.BuiltIn[0], new CassettePictures(), playback));
        Time("cassette stage", () => Stages.Cassette(ui, SKRect.Create(20, 56, 600, 680), CassetteDesign.BuiltIn[0], new CassettePictures(), playback));
        Time("disc stage", () => Stages.Disc(ui, SKRect.Create(20, 56, 600, 680), playback));
        Time("cassette panel", () => Panels.Cassette(ui, SKRect.Create(640, 56, 440, 680), playback, controls));
        Time("disc panel", () => Panels.Disc(ui, SKRect.Create(640, 56, 440, 680), playback, controls));
        var cached = ui.Cached("surface", new SKSize(1100, 760), layer => Textures.Fill(layer, all, SkinTexture.Walnut));
        Time("surface image", () => c.Image(cached, all));
        Time("vinyl stage", () => Stages.Turntable(ui, SKRect.Create(20, 56, 600, 680), playback, _ => { }));
        Time("led clock", () => Controls.LedClock(ui, new SKPoint(900, 300), 22, playback));
        Time("recess", () => Materials.Recess(c, SKRect.Create(700, 300, 100, 40), 6, SKColors.Black, 3));
        Time("lamp", () => Materials.PilotLamp(c, SKRect.Create(700, 300, 10, 10), true));
        Time("love cap", () => Controls.DeckCap(ui, "love", new SKPoint(800, 600), "L", Glyph.Heart, null, () => { }));
        Time("caption", () => Controls.Caption(c, "START · STOP", SKRect.Create(700, 300, 100, 40), 1.5f));
        Time("vfd text", () => Controls.VfdText(c, "02:01", "88:88", 700, 300, Fonts.Digits(50)));
        Time("fonts", () => { using var f = Fonts.Caption(10); });
        File.WriteAllLines(Path.Combine(Path.GetTempPath(), "gl-skin-profile.txt"), lines);
    }
}
