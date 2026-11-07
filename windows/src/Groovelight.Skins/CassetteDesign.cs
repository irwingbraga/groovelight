using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using SkiaSharp;

namespace Groovelight.Skins;

/// <summary>
/// A cassette for Now Playing's cassette skin (the Mac's CassetteDesign): the shell, the label and the reels, as colors
/// and text, and optionally the user's own pictures of the shell and the label. Saved as <c>cassette.json</c> in a
/// folder with its pictures (<see cref="CassetteStore"/>), the same file on the Mac, the iPhone and Android, so a design
/// can be shared as that folder (zipped, as Android shares it).
///
/// Every size and place is relative to the cassette (0 to 1 across its width and its height), on the template's
/// geometry (<see cref="CassetteGeometry.Standard"/>).
/// </summary>
public sealed class CassetteDesign
{
    /// <summary>The file format; designs from a later version are still read, ignoring what is new.</summary>
    public const int FormatVersion = 1;

    public int Format { get; set; } = FormatVersion;
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "Cassette";
    /// <summary>Who made it, shown in the list (optional).</summary>
    public string? Author { get; set; }
    /// <summary>The plastic's color, and how clear it is (0 solid, up to 0.8 the smoked clear shells).</summary>
    public HexColor ShellColor { get; set; }
    public double ShellClarity { get; set; }
    /// <summary>The screws, the window's frame and the edges.</summary>
    public HexColor DetailColor { get; set; }
    public CassetteLabel Label { get; set; } = new();
    public CassetteReels Reels { get; set; } = new();
    /// <summary>The printed brand and the tape's type, at the top of the label.</summary>
    public string Brand { get; set; } = "";
    public string TapeType { get; set; } = "";
    /// <summary>The side shown on the label.</summary>
    public string Side { get; set; } = "A";
    /// <summary>The user's picture of the whole shell (a PNG with the windows transparent), relative to the folder.</summary>
    public string? ShellImage { get; set; }
    /// <summary>The user's picture for the label, relative to the design's folder.</summary>
    public string? LabelImage { get; set; }
    /// <summary>Where the reels, the window and the label are; the template's places when not set.</summary>
    public CassetteGeometry? Geometry { get; set; }

    public CassetteGeometry ResolvedGeometry => Geometry ?? CassetteGeometry.Standard;

    public bool IsBuiltIn => BuiltIn.Any(design => design.Id == Id);

    public CassetteDesign Copy() => Parse(ToJson());

    // MARK: JSON, as the Mac writes it (sorted keys), and read leniently: fields left out take the classic design's.

    public string ToJson()
    {
        var label = new JsonObject
        {
            ["background"] = Label.Background.Hex,
            ["handwritten"] = Label.Handwritten,
            ["showsArtwork"] = Label.ShowsArtwork,
            ["showsText"] = Label.ShowsText,
            ["stripes"] = new JsonArray(Label.Stripes.Select(stripe => (JsonNode)stripe.Hex).ToArray()),
            ["textColor"] = Label.TextColor.Hex,
        };
        // Only when used, so plain designs read as before.
        if (Label.Bands.Count > 0)
        {
            label["bands"] = new JsonArray(Label.Bands.Select(band =>
            {
                var node = new JsonObject { ["color"] = band.Color.Hex, ["height"] = band.Height, ["y"] = band.Y };
                if (band.Finish is { } finish) node["finish"] = finish.RawValue();
                return (JsonNode)node;
            }).ToArray());
        }
        if (Label.Writing is { } writing) label["writing"] = new JsonObject { ["background"] = writing.Background.Hex, ["textColor"] = writing.TextColor.Hex };
        if (Label.TextFinish is { } textFinish) label["textFinish"] = textFinish.RawValue();
        if (Label.BackgroundFinish is { } backgroundFinish) label["backgroundFinish"] = backgroundFinish.RawValue();
        var reels = new JsonObject { ["hubColor"] = Reels.HubColor.Hex, ["tapeColor"] = Reels.TapeColor.Hex };
        if (Reels.RingColor is { } ring) reels["ringColor"] = ring.Hex;
        if (Reels.RingFinish is { } ringFinish) reels["ringFinish"] = ringFinish.RawValue();
        var root = new JsonObject
        {
            ["brand"] = Brand,
            ["detailColor"] = DetailColor.Hex,
            ["format"] = Format,
            ["id"] = Id.ToString().ToUpperInvariant(),
            ["label"] = Sorted(label),
            ["name"] = Name,
            ["reels"] = Sorted(reels),
            ["shellClarity"] = ShellClarity,
            ["shellColor"] = ShellColor.Hex,
            ["side"] = Side,
            ["tapeType"] = TapeType,
        };
        if (Author is not null) root["author"] = Author;
        if (ShellImage is not null) root["shellImage"] = ShellImage;
        if (LabelImage is not null) root["labelImage"] = LabelImage;
        if (Geometry is { } geometry) root["geometry"] = geometry.ToJson();
        return Sorted(root).ToJsonString(new JsonSerializerOptions { WriteIndented = true });
    }

    private static JsonObject Sorted(JsonObject node)
    {
        var sorted = new JsonObject();
        foreach (var (key, value) in node.OrderBy(pair => pair.Key, StringComparer.Ordinal).ToList())
        {
            node.Remove(key);
            sorted[key] = value is JsonObject child ? Sorted(child) : value;
        }
        return sorted;
    }

    /// <summary>A design from its file; throws <see cref="FormatException"/> when the text is not one.</summary>
    public static CassetteDesign Parse(string json)
    {
        JsonObject root;
        try
        {
            root = JsonNode.Parse(json) as JsonObject ?? throw new FormatException("Not a cassette.");
        }
        catch (JsonException error)
        {
            throw new FormatException("Not a cassette: " + error.Message, error);
        }
        var fallback = Classic;
        var design = new CassetteDesign
        {
            Format = Int(root["format"]) ?? FormatVersion,
            Id = Guid.TryParse(Text(root["id"]), out var id) ? id : Guid.NewGuid(),
            Name = Text(root["name"]) ?? "Cassette",
            Author = Text(root["author"]),
            ShellColor = Color(root["shellColor"]) ?? fallback.ShellColor,
            ShellClarity = Math.Clamp(Number(root["shellClarity"]) ?? 0, 0, 0.8),
            DetailColor = Color(root["detailColor"]) ?? fallback.DetailColor,
            Label = root["label"] is JsonObject label ? ParseLabel(label) : fallback.Label,
            Reels = root["reels"] is JsonObject reels ? ParseReels(reels, fallback.Reels) : fallback.Reels,
            Brand = Text(root["brand"]) ?? "",
            TapeType = Text(root["tapeType"]) ?? "",
            Side = Text(root["side"]) ?? "A",
            ShellImage = Text(root["shellImage"]),
            LabelImage = Text(root["labelImage"]),
            Geometry = root["geometry"] is JsonObject geometry ? CassetteGeometry.FromJson(geometry) : null,
        };
        return design;
    }

    private static CassetteLabel ParseLabel(JsonObject node) => new()
    {
        Background = Color(node["background"]) ?? HexColor.Parse("#F2EBDD")!.Value,
        Stripes = node["stripes"] is JsonArray stripes ? stripes.Select(Color).OfType<HexColor>().ToList() : [],
        TextColor = Color(node["textColor"]) ?? HexColor.Parse("#1C2A6B")!.Value,
        ShowsText = Bool(node["showsText"]) ?? true,
        ShowsArtwork = Bool(node["showsArtwork"]) ?? false,
        Handwritten = Bool(node["handwritten"]) ?? true,
        Bands = node["bands"] is JsonArray bands
            ? bands.OfType<JsonObject>().Select(band => Color(band["color"]) is { } color && Number(band["y"]) is { } y && Number(band["height"]) is { } height
                ? new CassetteBand(color, y, height, FinishOf(band["finish"])) : null).OfType<CassetteBand>().ToList()
            : [],
        Writing = node["writing"] is JsonObject writing && Color(writing["background"]) is { } paper && Color(writing["textColor"]) is { } ink
            ? new CassetteWriting(paper, ink) : null,
        TextFinish = FinishOf(node["textFinish"]),
        BackgroundFinish = FinishOf(node["backgroundFinish"]),
    };

    private static CassetteReels ParseReels(JsonObject node, CassetteReels fallback)
    {
        // Hubs and tape are required on the Mac: a reels object without them is not read at all.
        if (Color(node["hubColor"]) is not { } hub || Color(node["tapeColor"]) is not { } tape) return fallback;
        return new CassetteReels { HubColor = hub, TapeColor = tape, RingColor = Color(node["ringColor"]), RingFinish = FinishOf(node["ringFinish"]) };
    }

    internal static string? Text(JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;
    internal static double? Number(JsonNode? node) => node is JsonValue value && value.TryGetValue<double>(out var number) ? number : null;
    private static int? Int(JsonNode? node) => Number(node) is { } number ? (int)number : null;
    private static bool? Bool(JsonNode? node) => node is JsonValue value && value.TryGetValue<bool>(out var flag) ? flag : null;
    private static HexColor? Color(JsonNode? node) => HexColor.Parse(Text(node));
    private static Finish? FinishOf(JsonNode? node) => Text(node) switch { "gold" => Finish.Gold, "silver" => Finish.Silver, _ => null };

    // MARK: Built-in designs

    private static CassetteDesign Make(string id, string name, string shell, string detail, CassetteLabel label, CassetteReels reels, string brand, string tapeType,
                                       double clarity = 0, string side = "A", CassetteGeometry? geometry = null) => new()
    {
        Id = Guid.Parse("6B1C1C8E-0001-4C55-9C11-" + id), Name = name, ShellColor = HexColor.Of(shell), ShellClarity = clarity, DetailColor = HexColor.Of(detail),
        Label = label, Reels = reels, Brand = brand, TapeType = tapeType, Side = side, Geometry = geometry,
    };

    private static CassetteLabel L(string background, string text, string[]? stripes = null, bool showsText = true, bool showsArtwork = false, bool handwritten = true,
                                   CassetteBand[]? bands = null, CassetteWriting? writing = null, Finish? textFinish = null, Finish? backgroundFinish = null) => new()
    {
        Background = HexColor.Of(background), TextColor = HexColor.Of(text), Stripes = (stripes ?? []).Select(HexColor.Of).ToList(), ShowsText = showsText,
        ShowsArtwork = showsArtwork, Handwritten = handwritten, Bands = (bands ?? []).ToList(), Writing = writing, TextFinish = textFinish, BackgroundFinish = backgroundFinish,
    };

    private static CassetteReels R(string hub, string tape, string? ring = null, Finish? ringFinish = null) => new()
    {
        HubColor = HexColor.Of(hub), TapeColor = HexColor.Of(tape), RingColor = ring is null ? null : HexColor.Of(ring), RingFinish = ringFinish,
    };

    private static CassetteBand B(string color, double y, double height, Finish? finish = null) => new(HexColor.Of(color), y, height, finish);
    private static CassetteWriting W(string background, string text) => new(HexColor.Of(background), HexColor.Of(text));

    /// <summary>Black shell, cream label with the red and orange bands of the 1980s.</summary>
    public static CassetteDesign Classic => Make("000000000001", "Classic", "#1E1E21", "#4A4A50",
        L("#F2EBDD", "#1C2A6B", ["#D8432E", "#EE8A2C", "#F3C340"]), R("#F4F4F2", "#3A2618"), "GROOVELIGHT", "TYPE I · NORMAL");

    /// <summary>The designs that come with the app (they cannot be changed, only copied).</summary>
    public static IReadOnlyList<CassetteDesign> BuiltIn { get; } =
    [
        Classic,
        Make("000000000002", "Chrome", "#ECECEA", "#A9AAB0", L("#1F4E9C", "#FFFFFF", ["#E9EEF7"], handwritten: false), R("#FFFFFF", "#2B2018"), "GROOVELIGHT", "TYPE II · CrO2"),
        Make("000000000003", "Clear", "#9FB4C2", "#D0D8DE", L("#FFFFFF", "#202020", showsArtwork: true, handwritten: false), R("#F7F7F7", "#4B3423"), "GROOVELIGHT",
            "TYPE II · HIGH BIAS", clarity: 0.65),
        Make("000000000004", "Metal", "#2B2D31", "#8D8F94", L("#C9A750", "#1A1A1A", ["#1A1A1A"], handwritten: false, backgroundFinish: Finish.Gold),
            R("#C9C9C9", "#1F1A16"), "GROOVELIGHT", "TYPE IV · METAL"),
        Make("000000000005", "Mixtape", "#E4497A", "#F7A6C0", L("#FFF6D8", "#2A2A2A", ["#47B5C9"], showsArtwork: true), R("#FFFFFF", "#3A2618"), "MIX", "90 MIN"),
        Make("000000000006", "Black Gold", "#161618", "#3C3C40",
            L("#00000000", "#D6AE5C", handwritten: false, bands: [B("#D6AE5C", 0.43, 0.012, Finish.Gold), B("#232120", 0.46, 0.34), B("#D6AE5C", 0.8, 0.012, Finish.Gold)],
                textFinish: Finish.Gold),
            R("#E8E6E0", "#2A1D14", "#C9A04A", Finish.Gold), "GROOVELIGHT GX 60", "HIGH POSITION · TYPE II", side: "B"),
        Make("000000000007", "Ice Chrome", "#B9CCDD", "#E3EBF2", L("#FFFFFF14", "#23356E", handwritten: false, bands: [B("#3D5FA8", 0.88, 0.06)]),
            R("#F5F7FA", "#3A2A20"), "GROOVELIGHT CR 90", "CHROME · TYPE II", clarity: 0.7),
        Make("000000000008", "Midnight Pro", "#1A1F30", "#59607A",
            L("#00000000", "#D5D9E2", handwritten: false, bands: [B("#262C42", 0.46, 0.34), B("#AEB3BF", 0.82, 0.01, Finish.Silver)], textFinish: Finish.Silver),
            R("#E9EBEF", "#241A14", "#BFC4CE", Finish.Silver), "GROOVELIGHT PRO 90", "SUPER ENERGY · TYPE II"),
        Make("000000000009", "Red Band", "#121214", "#3A3A3E",
            L("#00000000", "#F1EEE6", handwritten: true, bands: [B("#B5302A", 0.44, 0.38), B("#F1EEE6", 0.86, 0.1)], writing: W("#F1EEE6", "#1E2A5A")),
            R("#EDEDED", "#2B1E16"), "GROOVELIGHT S 60", "TYPE II · HIGH BIAS"),
        Make("00000000000A", "Smoked Lavender", "#33353B", "#6E7078", L("#00000000", "#B7A2E8", handwritten: true, writing: W("#CFCFCB", "#26262A")),
            R("#F0F0F0", "#2A1E16"), "GROOVELIGHT LX", "100 MINUTES", clarity: 0.5),
        Make("00000000000B", "Graphite Window", "#3B3C40", "#6A6B70", L("#00000000", "#E0E0DE", handwritten: true, writing: W("#ECEBE6", "#222222")),
            R("#F2F2F2", "#2B1E16", "#C23B32"), "GROOVELIGHT F 90", "IEC II · HIGH POSITION", clarity: 0.3,
            geometry: CassetteGeometry.Standard.WithWindow(new CassetteRect(0.2, 0.35, 0.6, 0.24))),
        Make("00000000000C", "Green Pinstripe", "#1C2520", "#4A564F",
            L("#00000000", "#E9E4D0", handwritten: true, bands: [B("#C8A55A", 0.8, 0.018, Finish.Gold), B("#EDE8D8", 0.835, 0.012), B("#C8A55A", 0.86, 0.018, Finish.Gold)],
                writing: W("#F2F0E6", "#1D2A22")),
            R("#F0F0EC", "#2A1D14"), "GROOVELIGHT X 90", "HIGH BIAS · 70µs EQ"),
        Make("00000000000D", "Bronze Clear", "#5E5A57", "#B9B2AA", L("#00000000", "#F4F2EE", handwritten: false, bands: [B("#B06A33", 0.84, 0.1)], writing: W("#F4F2EE", "#333333")),
            R("#F2F2F2", "#3A2A20"), "GROOVELIGHT", "CHROME II · 100", clarity: 0.55),
        Make("00000000000E", "Charcoal", "#2D2E30", "#4D4E52",
            L("#00000000", "#E6E6E6", handwritten: false, bands: [B("#111111", 0.78, 0.1), B("#E6E6E6", 0.8, 0.006, Finish.Silver)], textFinish: Finish.Silver),
            R("#E8E8E8", "#2A1D14"), "GROOVELIGHT TX 90", "HIGH BIAS · 70µs EQ", side: "B"),
    ];
}

public sealed class CassetteLabel
{
    public HexColor Background { get; set; } = HexColor.Of("#F2EBDD");
    /// <summary>Bands across the label's lower part, top to bottom, as on the classic tapes (none for a plain label).</summary>
    public List<HexColor> Stripes { get; set; } = [];
    public HexColor TextColor { get; set; } = HexColor.Of("#1C2A6B");
    /// <summary>The song's title and artist written on the label.</summary>
    public bool ShowsText { get; set; } = true;
    /// <summary>The album's cover on the label's left side.</summary>
    public bool ShowsArtwork { get; set; }
    public bool Handwritten { get; set; } = true;
    /// <summary>Bands placed anywhere on the label (over its color, under its text).</summary>
    public List<CassetteBand> Bands { get; set; } = [];
    /// <summary>A strip to write on above the window, in its own color (the song in its own ink).</summary>
    public CassetteWriting? Writing { get; set; }
    /// <summary>The printed lettering in foil instead of the text color.</summary>
    public Finish? TextFinish { get; set; }
    /// <summary>The whole label in foil instead of its background.</summary>
    public Finish? BackgroundFinish { get; set; }
}

/// <summary>A band across the label: <c>Y</c> and <c>Height</c> relative to the label's height.</summary>
public sealed record CassetteBand(HexColor Color, double Y, double Height, Finish? Finish = null);

public sealed record CassetteWriting(HexColor Background, HexColor TextColor);

public sealed class CassetteReels
{
    /// <summary>The hubs' plastic and the tape wound on them.</summary>
    public HexColor HubColor { get; set; } = HexColor.Of("#F4F4F2");
    public HexColor TapeColor { get; set; } = HexColor.Of("#3A2618");
    /// <summary>A printed ring around each hub's hole (optional).</summary>
    public HexColor? RingColor { get; set; }
    /// <summary>The rings in foil instead of their color (with the color set, for readers without finishes).</summary>
    public Finish? RingFinish { get; set; }
}

public readonly record struct CassettePoint(double X, double Y);

public readonly record struct CassetteRect(double X, double Y, double Width, double Height);

/// <summary>Where the parts of a cassette are, relative to the whole (x across the width, y down the height).</summary>
public sealed record CassetteGeometry(double AspectRatio, CassettePoint LeftReel, CassettePoint RightReel, double ReelRadius, double HubRadius,
                                      CassetteRect Window, CassetteRect Label)
{
    /// <summary>A compact cassette (100.4 x 63.8 mm): the template's places, at 1000 x 635 pixels.</summary>
    public static CassetteGeometry Standard { get; } = new(100.4 / 63.8, new(0.288, 0.47), new(0.712, 0.47), 0.165, 0.06,
        new(0.33, 0.38, 0.34, 0.18), new(0.075, 0.09, 0.85, 0.6));

    public CassetteGeometry WithWindow(CassetteRect window) => this with { Window = window };

    internal JsonObject ToJson()
    {
        static JsonObject Point(CassettePoint point) => new() { ["x"] = point.X, ["y"] = point.Y };
        static JsonObject Rect(CassetteRect rect) => new() { ["height"] = rect.Height, ["width"] = rect.Width, ["x"] = rect.X, ["y"] = rect.Y };
        return new JsonObject
        {
            ["aspectRatio"] = AspectRatio, ["hubRadius"] = HubRadius, ["label"] = Rect(Label), ["leftReel"] = Point(LeftReel), ["reelRadius"] = ReelRadius,
            ["rightReel"] = Point(RightReel), ["window"] = Rect(Window),
        };
    }

    internal static CassetteGeometry? FromJson(JsonObject node)
    {
        static CassettePoint? Point(JsonNode? node) => node is JsonObject point && CassetteDesign.Number(point["x"]) is { } x && CassetteDesign.Number(point["y"]) is { } y
            ? new CassettePoint(x, y) : null;
        static CassetteRect? Rect(JsonNode? node) => node is JsonObject rect && CassetteDesign.Number(rect["x"]) is { } x && CassetteDesign.Number(rect["y"]) is { } y
            && CassetteDesign.Number(rect["width"]) is { } width && CassetteDesign.Number(rect["height"]) is { } height ? new CassetteRect(x, y, width, height) : null;
        if (CassetteDesign.Number(node["aspectRatio"]) is not { } aspect || Point(node["leftReel"]) is not { } left || Point(node["rightReel"]) is not { } right
            || CassetteDesign.Number(node["reelRadius"]) is not { } reel || CassetteDesign.Number(node["hubRadius"]) is not { } hub || Rect(node["window"]) is not { } window
            || Rect(node["label"]) is not { } label) return null;
        return new CassetteGeometry(aspect, left, right, reel, hub, window, label);
    }
}

/// <summary>Print in metal foil, as the premium tapes' lettering, bands and rings.</summary>
public enum Finish { Gold, Silver }

public static class Finishes
{
    public static string RawValue(this Finish finish) => finish == Finish.Gold ? "gold" : "silver";
}

/// <summary>A color as "#RRGGBB" or "#RRGGBBAA", as in the design file.</summary>
public readonly record struct HexColor(double Red, double Green, double Blue, double Alpha = 1)
{
    public static HexColor Of(string text) => Parse(text) ?? new HexColor(0, 0, 0);

    public static HexColor? Parse(string? text)
    {
        var hex = text?.Trim() ?? "";
        if (hex.StartsWith('#')) hex = hex[1..];
        if (hex.Length is not (6 or 8) || !ulong.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var value)) return null;
        var full = hex.Length == 6 ? value << 8 | 0xFF : value;
        return new HexColor((full >> 24 & 0xFF) / 255.0, (full >> 16 & 0xFF) / 255.0, (full >> 8 & 0xFF) / 255.0, (full & 0xFF) / 255.0);
    }

    public string Hex
    {
        get
        {
            var parts = Alpha < 1 ? new[] { Red, Green, Blue, Alpha } : [Red, Green, Blue];
            return "#" + string.Concat(parts.Select(part => Math.Clamp((int)Math.Round(part * 255), 0, 255).ToString("X2", CultureInfo.InvariantCulture)));
        }
    }

    public SKColor Color => new((byte)Math.Round(Red * 255), (byte)Math.Round(Green * 255), (byte)Math.Round(Blue * 255), (byte)Math.Round(Alpha * 255));

    public static HexColor From(SKColor color) => new(color.Red / 255.0, color.Green / 255.0, color.Blue / 255.0, color.Alpha / 255.0);
}
