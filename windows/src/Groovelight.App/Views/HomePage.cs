using System.Globalization;
using Groovelight.Controls;
using Groovelight.Core.Discovery;
using Groovelight.Core.Library;
using Groovelight.Support;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using SkiaSharp;
using SkiaSharp.Views.Windows;
using Windows.UI;
using static Groovelight.Core.Discovery.Discovery;

namespace Groovelight.Views;

/// <summary>
/// Home (the Mac's HomeView): a greeting, Song, Album and Artist of the Day with Play, Shuffle and Something Else, then
/// Your Listening for a week, a month, a year or all time: tiles, listening time by place (SkiaSharp), when you listen,
/// where, top songs, albums and artists, genres, decades and the library.
/// </summary>
public sealed partial class HomePage : PageView
{
    public const string RangeKey = "home.range";

    private sealed record PickCard(HomeSnapshot.Card Card, IReadOnlyList<Track> Tracks);

    private readonly Grid picks = new() { ColumnSpacing = 18, RowSpacing = 18 };
    private readonly StackPanel rangeButtons = new() { Orientation = Orientation.Horizontal, Spacing = 4 };
    private readonly ContentControl dashboard = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch };
    private Dictionary<Kind, List<PickCard>> choices = [];
    private readonly Dictionary<Kind, int> shown = [];
    private ListeningStats.StatsRange range;
    private Observation<ListeningStats>? stats;
    private long day;
    private int columns;

    public override string Title => "Home";

    public HomePage()
    {
        range = Enum.TryParse<ListeningStats.StatsRange>(Model.Preferences.String(RangeKey), true, out var saved) ? saved : ListeningStats.StatsRange.Month;
        var title = Ui.Text(Greeting(), "LargeTitleText");
        var date = Ui.Text(DateTime.Now.ToString("dddd, d MMMM", CultureInfo.CurrentCulture).ToUpper(CultureInfo.CurrentCulture), "CaptionText");
        date.FontWeight = FontWeights.SemiBold;
        var listening = Ui.Grid("*, auto");
        listening.Children.Add(Ui.Text("Your Listening", "SectionTitleText").With(text => text.VerticalAlignment = VerticalAlignment.Center).At(0));
        listening.Children.Add(rangeButtons.At(1));
        var content = Ui.Column(28, Ui.Column(2, date, title), picks, Ui.Column(18, listening, dashboard));
        content.MaxWidth = 1400;
        content.HorizontalAlignment = HorizontalAlignment.Stretch;
        Content = Scroll(content);
        // Only when the number of columns changes: laying the cards out again changes the grid's size.
        picks.SizeChanged += (_, args) => { if (Columns(args.NewSize.Width) != columns) LayOutPicks(); };
        BuildRangeButtons();
        ObserveStats();
        _ = LoadPicksAsync();
        // A new day while the page is open: new picks when it is shown again.
        Loaded += (_, _) => { if (day != DayOf(DateTime.UtcNow)) _ = LoadPicksAsync(); };
    }

    public override void Dispose()
    {
        stats?.Dispose();
        base.Dispose();
    }

    private static string Greeting() => DateTime.Now.Hour switch
    {
        >= 5 and < 12 => "Good Morning",
        >= 12 and < 18 => "Good Afternoon",
        _ => "Good Evening",
    };

    // MARK: Picks

    private async Task LoadPicksAsync()
    {
        var database = Model.Database;
        var loaded = await Task.Run(() =>
        {
            var home = database.HomeSnapshotFor(stats: false);
            return database.Read(db => Enum.GetValues<Kind>().ToDictionary(kind => kind,
                kind => home.Cards(kind).Select(card => new PickCard(card, db.TracksWithIds(card.TrackIds))).ToList()));
        });
        choices = loaded;
        shown.Clear();
        day = DayOf(DateTime.UtcNow);
        LayOutPicks();
    }

    private PickCard? Current(Kind kind) =>
        choices.TryGetValue(kind, out var cards) && cards.Count > 0 ? cards[shown.GetValueOrDefault(kind) % cards.Count] : null;

    /// <summary>The cards side by side, as many columns as fit (at least 250 pixels each).</summary>
    private void LayOutPicks()
    {
        var cards = Enum.GetValues<Kind>().Select(Current).OfType<PickCard>().ToList();
        columns = Columns(picks.ActualWidth);
        picks.Children.Clear();
        picks.ColumnDefinitions.Clear();
        picks.RowDefinitions.Clear();
        for (var column = 0; column < columns; column++) picks.ColumnDefinitions.Add(new ColumnDefinition { MaxWidth = 420 });
        for (var row = 0; row < (cards.Count + columns - 1) / columns; row++) picks.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        for (var index = 0; index < cards.Count; index++) picks.Children.Add(Card(cards[index]).At(index % columns, index / columns));
    }

    private static int Columns(double width) => width <= 0 ? 3 : Math.Clamp((int)((width + 18) / 268), 1, 3);

    private FrameworkElement Card(PickCard pick)
    {
        var card = pick.Card;
        var isArtist = card.Kind == Kind.Artist;
        var artwork = new ArtworkImage { Hash = card.ArtworkHash, IsLarge = true, Radius = 12 };
        artwork.SizeChanged += (_, args) =>
        {
            artwork.Height = args.NewSize.Width;
            if (isArtist) artwork.Radius = args.NewSize.Width / 2;
        };
        var cover = new Button { Content = artwork, Padding = new Thickness(0), Background = Images.Transparent, BorderThickness = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        cover.Click += (_, _) => Open(pick);
        ToolTipService.SetToolTip(cover, isArtist ? $"Show {card.Title}" : "Show Album");
        var kindTitle = Ui.Text(HomeStore.Title(card.Kind).ToUpper(CultureInfo.CurrentCulture), "CaptionText");
        kindTitle.FontWeight = FontWeights.SemiBold;
        var title = Ui.Text(card.Title, "StrongText", 17);
        title.TextTrimming = TextTrimming.CharacterEllipsis;
        var subtitle = Ui.Text(card.Subtitle, "SecondaryText");
        subtitle.TextTrimming = TextTrimming.CharacterEllipsis;
        var reason = Ui.Text(card.ReasonText, "CaptionText");
        reason.TextWrapping = TextWrapping.WrapWholeWords;
        reason.MaxLines = 2;
        var buttons = Ui.Grid("auto, auto, *, auto");
        buttons.ColumnSpacing = 8;
        buttons.Children.Add(Ui.Button("Play", () => Model.Play(pick.Tracks), Glyphs.Play, "AccentPillButton").At(0));
        if (pick.Tracks.Count > 1) buttons.Children.Add(Ui.IconButton(Glyphs.Shuffle, "Shuffle", () => Model.Play(pick.Tracks, shuffle: true), 14, "CircleButton").At(1));
        if (choices.GetValueOrDefault(card.Kind)?.Count > 1)
        {
            buttons.Children.Add(Ui.IconButton(Glyphs.Refresh, "Something Else (the day's pick comes back after the last)", () =>
            {
                shown[card.Kind] = shown.GetValueOrDefault(card.Kind) + 1;
                LayOutPicks();
            }, 14, "CircleButton").At(3));
        }
        var panel = Ui.Column(12, kindTitle, cover, Ui.Column(3, title, subtitle, reason), buttons);
        var border = new Border
        {
            Child = panel, Padding = new Thickness(16), CornerRadius = new CornerRadius(18), Background = Ui.Brush("CardBackgroundBrush"),
            VerticalAlignment = VerticalAlignment.Top,
        };
        border.ContextFlyout = Menus.Flyout([
            Menus.Item("Play", () => Model.Play(pick.Tracks), Glyphs.Play),
            Menus.Item("Shuffle", () => Model.Play(pick.Tracks, shuffle: true), Glyphs.Shuffle),
            Menus.Item(isArtist ? "Show Artist" : "Show Album", () => Open(pick), Glyphs.Album),
        ]);
        return border;
    }

    private void Open(PickCard pick)
    {
        if (pick.Card.Kind == Kind.Artist) Model.ShowArtist(pick.Card.Key);
        else if (pick.Tracks.FirstOrDefault()?.AlbumKey is { } albumKey) Model.ShowAlbum(albumKey);
    }

    // MARK: Dashboard

    private void BuildRangeButtons()
    {
        rangeButtons.Children.Clear();
        foreach (var (value, label) in new[]
                 {
                     (ListeningStats.StatsRange.Week, "Week"), (ListeningStats.StatsRange.Month, "Month"),
                     (ListeningStats.StatsRange.Year, "Year"), (ListeningStats.StatsRange.All, "All Time"),
                 })
        {
            rangeButtons.Children.Add(Ui.Button(label, () =>
            {
                if (range == value) return;
                range = value;
                Model.Preferences.Set(RangeKey, value.ToString().ToLowerInvariant());
                BuildRangeButtons();
                ObserveStats();
            }, style: value == range ? "AccentPillButton" : "PillButton"));
        }
    }

    /// <summary>The dashboard for the range, again after each change to the library (a song played, an import).</summary>
    private void ObserveStats()
    {
        stats?.Dispose();
        var chosen = range;
        stats = new Observation<ListeningStats>(Model.Database, db => db.ListeningStatsFor(chosen), value =>
        {
            if (value.Range != range) return;
            dashboard.Content = value.Plays == 0 && value.Minutes == 0
                ? Ui.Unavailable(Glyphs.Note, "Nothing played yet",
                    "Play some music, or import your Last.fm history in Settings, Last.fm, and your listening shows here.")
                : new StatsDashboard(value);
        });
    }
}

/// <summary>The charts and lists of the listening log (the Mac's StatsDashboard).</summary>
internal sealed partial class StatsDashboard : StackPanel
{
    private static readonly (string Place, string Name)[] Places =
        [(ListeningStats.Place.Here, "This PC"), (ListeningStats.Place.Devices, "Phones"), (ListeningStats.Place.LastFm, "Last.fm")];

    private readonly ListeningStats stats;

    public StatsDashboard(ListeningStats stats)
    {
        this.stats = stats;
        Spacing = 18;
        Children.Add(Row(
            Tile("Listening", Hours(stats.Minutes), Glyphs.Clock),
            Tile("Plays", stats.Plays.ToString("N0", CultureInfo.CurrentCulture), Glyphs.Play),
            Tile("Songs", stats.Songs.ToString("N0", CultureInfo.CurrentCulture), Glyphs.Note),
            Tile(stats.Range == ListeningStats.StatsRange.All ? "Songs Heard" : "New to You", stats.NewSongs.ToString("N0", CultureInfo.CurrentCulture), Glyphs.Star),
            Tile("Streak", stats.Streak == 1 ? "1 day" : $"{stats.Streak} days", Glyphs.Check)));
        Children.Add(Panel("Listening Time", OverTime()));
        Children.Add(Row([2, 1], Panel("When You Listen", HeatMap()), Panel("Where", Where())));
        Children.Add(Row(
            Panel("Top Songs", Ranked(stats.TopSongs, artwork: true, open: item => PlaySong(item.Key))),
            Panel("Top Albums", Ranked(stats.TopAlbums, artwork: true, open: item => App().ShowAlbum(item.Key))),
            Panel("Top Artists", Ranked(stats.TopArtists, artwork: false, open: item => App().ShowArtist(item.Key)))));
        Children.Add(Row(Panel("Genres", Bars(stats.Genres)), Panel("Decades", Decades())));
        Children.Add(Row(
            Tile("In Your Library", stats.LibrarySongs.ToString("N0", CultureInfo.CurrentCulture), Glyphs.Library),
            Tile("Never Played", stats.NeverPlayed.ToString("N0", CultureInfo.CurrentCulture), Glyphs.Moon),
            Tile("Loved", stats.Loved.ToString("N0", CultureInfo.CurrentCulture), Glyphs.Heart)));
    }

    private static Groovelight.Model.AppModel App() => Groovelight.Model.AppModel.Current;

    private static async void PlaySong(string key)
    {
        if (!long.TryParse(key, out var id)) return;
        var model = App();
        var tracks = await Task.Run(() => model.Database.Read(db => db.TracksWithIds([id])));
        if (tracks.Count > 0) model.Play(tracks);
    }

    public static string Hours(double minutes) =>
        minutes >= 120 ? $"{Math.Round(minutes / 60).ToString("N0", CultureInfo.CurrentCulture)} hr" : $"{Math.Round(minutes)} min";

    private static Grid Row(params FrameworkElement[] children) => Row(children.Select(_ => 1.0).ToArray(), children);

    private static Grid Row(double[] weights, params FrameworkElement[] children)
    {
        var grid = new Grid { ColumnSpacing = 18 };
        for (var index = 0; index < children.Length; index++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(weights[index], GridUnitType.Star) });
            grid.Children.Add(children[index].At(index));
        }
        return grid;
    }

    private static Border Panel(string title, UIElement content) => new()
    {
        Child = Ui.Column(12, Ui.Text(title, "StrongText", 15), content),
        Padding = new Thickness(16), CornerRadius = new CornerRadius(16), Background = Ui.Brush("CardBackgroundBrush"),
    };

    private static Border Tile(string title, string value, string glyph)
    {
        var label = Ui.Row(6, Ui.Icon(glyph, 12, "SecondaryIcon"), Ui.Text(title, "CaptionText"));
        var number = Ui.Text(value, "LargeTitleText", 24);
        number.FontFeatures();
        number.TextTrimming = TextTrimming.CharacterEllipsis;
        return new Border
        {
            Child = Ui.Column(6, label, number), Padding = new Thickness(16), CornerRadius = new CornerRadius(16), Background = Ui.Brush("CardBackgroundBrush"),
        };
    }

    private bool IsDark => ActualTheme == ElementTheme.Dark || (ActualTheme == ElementTheme.Default && Application.Current.RequestedTheme == ApplicationTheme.Dark);

    private static SKColor Sk(Color color) => new(color.R, color.G, color.B, color.A);

    private SKColor PlaceColor(string place) => place switch
    {
        ListeningStats.Place.Here => Sk(Images.Brand(IsDark)),
        ListeningStats.Place.Devices => new SKColor(0x14, 0xB8, 0xA6),
        _ => new SKColor(0xE5, 0x48, 0x4D),
    };

    private static Color ToColor(SKColor color) => Color.FromArgb(color.Alpha, color.Red, color.Green, color.Blue);

    /// <summary>"Mon" for a day of the week, "8" for a day of the month, "Nov" for a month, the year as is.</summary>
    private static string ShortLabel(string label, ListeningStats.StatsRange range)
    {
        var parts = label.Split('-');
        return range switch
        {
            ListeningStats.StatsRange.Week when DateTime.TryParseExact(label, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date) =>
                date.ToString("ddd", CultureInfo.CurrentCulture),
            ListeningStats.StatsRange.Month when parts.Length == 3 => int.Parse(parts[2], CultureInfo.InvariantCulture).ToString(CultureInfo.CurrentCulture),
            ListeningStats.StatsRange.Year when parts.Length == 2 && int.TryParse(parts[1], out var month) && month is >= 1 and <= 12 =>
                CultureInfo.CurrentCulture.DateTimeFormat.GetAbbreviatedMonthName(month),
            _ => label,
        };
    }

    /// <summary>Minutes per day, month or year, stacked by place, with the axis and a legend.</summary>
    private FrameworkElement OverTime()
    {
        var canvas = new SKXamlCanvas { Height = 210 };
        canvas.PaintSurface += (_, args) =>
        {
            var scale = (float)(canvas.XamlRoot?.RasterizationScale ?? 1);
            var surface = args.Surface.Canvas;
            surface.Clear(SKColors.Transparent);
            surface.Scale(scale);
            float width = args.Info.Width / scale, height = args.Info.Height / scale;
            var text = IsDark ? SKColors.White.WithAlpha(150) : SKColors.Black.WithAlpha(150);
            using var font = new SKFont(SKTypeface.FromFamilyName("Segoe UI"), 11);
            using var label = new SKPaint { Color = text, IsAntialias = true };
            using var gridLine = new SKPaint { Color = text.WithAlpha(40), StrokeWidth = 1 };
            const float axis = 48, bottom = 20;
            float plot = height - bottom - 6;
            var most = Math.Max(stats.Buckets.Select(bucket => bucket.Total()).DefaultIfEmpty(0).Max(), 1);
            // A round top: the next of 1, 2, 5 times a power of ten.
            var step = Math.Pow(10, Math.Floor(Math.Log10(most / 3)));
            foreach (var factor in new[] { 1.0, 2, 5, 10 }) if (most / (step * factor) <= 4) { step *= factor; break; }
            var top = Math.Ceiling(most / step) * step;
            for (var value = 0.0; value <= top + 0.001; value += step)
            {
                var y = 6 + plot - (float)(value / top) * plot;
                surface.DrawLine(0, y, width - axis, y, gridLine);
                surface.DrawText(Hours(value), width - axis + 6, y + 4, SKTextAlign.Left, font, label);
            }
            var count = Math.Max(stats.Buckets.Count, 1);
            var slot = (width - axis) / count;
            var bar = Math.Max(slot * 0.7f, 1);
            var every = Math.Max(1, (int)Math.Ceiling(count / ((width - axis) / 48)));
            for (var index = 0; index < stats.Buckets.Count; index++)
            {
                var bucket = stats.Buckets[index];
                var y = 6 + plot;
                foreach (var (place, _) in Places)
                {
                    var minutes = bucket.Minutes.GetValueOrDefault(place);
                    if (minutes <= 0) continue;
                    var length = (float)(minutes / top) * plot;
                    using var fill = new SKPaint { Color = PlaceColor(place), IsAntialias = true };
                    surface.DrawRoundRect(new SKRect(index * slot + (slot - bar) / 2, y - length, index * slot + (slot + bar) / 2, y), 2, 2, fill);
                    y -= length;
                }
                if (index % every == 0)
                    surface.DrawText(ShortLabel(bucket.Label, stats.Range), index * slot + slot / 2, height - 4, SKTextAlign.Center, font, label);
            }
        };
        ActualThemeChanged += (_, _) => canvas.Invalidate();
        return new StackPanel { Spacing = 8, Children = { canvas, Legend() } };
    }

    private StackPanel Legend()
    {
        var legend = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16 };
        foreach (var (place, name) in Places)
        {
            var dot = new Border { Width = 8, Height = 8, CornerRadius = new CornerRadius(4), Background = new SolidColorBrush(ToColor(PlaceColor(place))), VerticalAlignment = VerticalAlignment.Center };
            legend.Children.Add(Ui.Row(6, dot, Ui.Text(name, "CaptionText")));
        }
        return legend;
    }

    /// <summary>Plays by weekday and hour, the busiest hour darkest.</summary>
    private FrameworkElement HeatMap()
    {
        var grid = new Grid { ColumnSpacing = 3, RowSpacing = 3 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(34) });
        for (var hour = 0; hour < 24; hour++) grid.ColumnDefinitions.Add(new ColumnDefinition());
        for (var day = 0; day < 8; day++) grid.RowDefinitions.Add(new RowDefinition { Height = day < 7 ? new GridLength(20) : GridLength.Auto });
        var most = Math.Max(stats.Hours.SelectMany(row => row).DefaultIfEmpty(0).Max(), 1);
        var names = CultureInfo.CurrentCulture.DateTimeFormat.AbbreviatedDayNames;
        var brand = Images.Brand(IsDark);
        for (var day = 0; day < 7; day++)
        {
            grid.Children.Add(Ui.Text(names[day], "CaptionText").With(text => text.VerticalAlignment = VerticalAlignment.Center).At(0, day));
            for (var hour = 0; hour < 24; hour++)
            {
                var plays = stats.Hours[day][hour];
                var alpha = plays == 0 ? 0.08 : 0.2 + 0.8 * plays / most;
                var cell = new Border { CornerRadius = new CornerRadius(3), Background = new SolidColorBrush(Color.FromArgb((byte)(alpha * 255), brand.R, brand.G, brand.B)) };
                ToolTipService.SetToolTip(cell, $"{names[day]} {hour}:00, {(plays == 1 ? "1 play" : $"{plays} plays")}");
                grid.Children.Add(cell.At(hour + 1, day));
            }
        }
        for (var hour = 0; hour < 24; hour += 6)
            grid.Children.Add(Ui.Text($"{hour}:00", "CaptionText").At(hour + 1, 7, columnSpan: 6));
        return grid;
    }

    /// <summary>Plays by place, as a ring with its legend.</summary>
    private FrameworkElement Where()
    {
        var shares = Places.Where(place => stats.Places.GetValueOrDefault(place.Place) > 0).ToList();
        var total = Math.Max(shares.Sum(place => stats.Places[place.Place]), 1);
        var canvas = new SKXamlCanvas { Width = 150, Height = 150, HorizontalAlignment = HorizontalAlignment.Center };
        canvas.PaintSurface += (_, args) =>
        {
            var surface = args.Surface.Canvas;
            surface.Clear(SKColors.Transparent);
            var size = Math.Min(args.Info.Width, args.Info.Height);
            var stroke = size * 0.18f;
            var oval = new SKRect(stroke / 2, stroke / 2, size - stroke / 2, size - stroke / 2);
            var start = -90f;
            foreach (var (place, _) in shares)
            {
                var sweep = 360f * stats.Places[place] / total;
                using var paint = new SKPaint { Color = PlaceColor(place), Style = SKPaintStyle.Stroke, StrokeWidth = stroke, IsAntialias = true };
                surface.DrawArc(oval, start + 1, Math.Max(sweep - 2, 0.5f), false, paint);
                start += sweep;
            }
        };
        ActualThemeChanged += (_, _) => canvas.Invalidate();
        var legend = new StackPanel { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center };
        foreach (var (place, name) in shares)
        {
            var dot = new Border { Width = 8, Height = 8, CornerRadius = new CornerRadius(4), Background = new SolidColorBrush(ToColor(PlaceColor(place))), VerticalAlignment = VerticalAlignment.Center };
            legend.Children.Add(Ui.Row(6, dot, Ui.Text($"{name} {stats.Places[place] * 100 / total}%", "CaptionText")));
        }
        return new StackPanel { Spacing = 12, Children = { canvas, legend } };
    }

    /// <summary>A top list: rank, cover, name, a bar for the plays; a double click plays the song or opens the album or artist.</summary>
    private static FrameworkElement Ranked(List<ListeningStats.Ranked> items, bool artwork, Action<ListeningStats.Ranked> open)
    {
        if (items.Count == 0) return Ui.Text("Nothing yet", "SecondaryText");
        var most = Math.Max(items[0].Plays, 1);
        var list = new StackPanel { Spacing = 8 };
        foreach (var (item, index) in items.Take(8).Select((item, index) => (item, index)))
        {
            var row = Ui.Grid(artwork ? "22, 32, *, auto" : "22, *, auto");
            row.ColumnSpacing = 10;
            var rank = Ui.Text($"{index + 1}", "CaptionText").With(text => { text.HorizontalAlignment = HorizontalAlignment.Right; text.VerticalAlignment = VerticalAlignment.Center; });
            row.Children.Add(rank.At(0));
            var column = 1;
            if (artwork) row.Children.Add(new ArtworkImage { Hash = item.ArtworkHash, Width = 32, Height = 32, Radius = 4 }.At(column++));
            var bar = new Grid { Height = 4, Margin = new Thickness(0, 3, 0, 3) };
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(item.Plays, 1), GridUnitType.Star) });
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(most - item.Plays, 0.0001), GridUnitType.Star) });
            bar.Children.Add(new Border { CornerRadius = new CornerRadius(2), Background = Ui.Brush("BrandBrush"), Opacity = 0.6 });
            var name = Ui.Text(item.Name, "BodyText");
            name.FontWeight = FontWeights.Medium;
            name.TextTrimming = TextTrimming.CharacterEllipsis;
            var texts = Ui.Column(0, name, bar);
            if (item.Detail.Length > 0) texts.Children.Add(Ui.Text(item.Detail, "CaptionText").With(text => text.TextTrimming = TextTrimming.CharacterEllipsis));
            row.Children.Add(texts.At(column++));
            var plays = Ui.Text(item.Plays.ToString("N0", CultureInfo.CurrentCulture), "CaptionText").With(text => text.VerticalAlignment = VerticalAlignment.Center);
            plays.FontFeatures();
            row.Children.Add(plays.At(column));
            row.Background = Images.Transparent;
            row.DoubleTapped += (_, _) => open(item);
            list.Children.Add(row);
        }
        return list;
    }

    /// <summary>Horizontal bars (genres), with their plays.</summary>
    private static FrameworkElement Bars(List<ListeningStats.Ranked> items)
    {
        if (items.Count == 0) return Ui.Text("Nothing yet", "SecondaryText");
        var most = Math.Max(items.Max(item => item.Plays), 1);
        var list = new StackPanel { Spacing = 8 };
        foreach (var item in items)
        {
            var row = Ui.Grid("110, *");
            row.ColumnSpacing = 10;
            row.Children.Add(Ui.Text(item.Name, "BodyText").With(text => text.TextTrimming = TextTrimming.CharacterEllipsis).At(0));
            var bar = new Grid { Height = 16 };
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(item.Plays, 1), GridUnitType.Star) });
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(most - item.Plays, 0.0001) + most * 0.15, GridUnitType.Star) });
            bar.Children.Add(new Border { CornerRadius = new CornerRadius(4), Background = Ui.Brush("BrandBrush") });
            bar.Children.Add(Ui.Text(item.Plays.ToString("N0", CultureInfo.CurrentCulture), "CaptionText").Margin(6, 0, 0, 0).At(1));
            row.Children.Add(bar.At(1));
            list.Children.Add(row);
        }
        return list;
    }

    /// <summary>Plays per decade, as columns.</summary>
    private FrameworkElement Decades()
    {
        if (stats.Decades.Count == 0) return Ui.Text("Nothing yet", "SecondaryText");
        var most = Math.Max(stats.Decades.Max(item => item.Plays), 1);
        var grid = new Grid { ColumnSpacing = 10, Height = 180 };
        grid.RowDefinitions.Add(new RowDefinition());
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var purple = new SolidColorBrush(Color.FromArgb(255, 0x8B, 0x5C, 0xF6));
        for (var index = 0; index < stats.Decades.Count; index++)
        {
            var item = stats.Decades[index];
            grid.ColumnDefinitions.Add(new ColumnDefinition { MaxWidth = 64 });
            var column = new Grid();
            column.RowDefinitions.Add(new RowDefinition { Height = new GridLength(Math.Max(most - item.Plays, 0.0001), GridUnitType.Star) });
            column.RowDefinitions.Add(new RowDefinition { Height = new GridLength(Math.Max(item.Plays, 1), GridUnitType.Star) });
            column.Children.Add(new Border { CornerRadius = new CornerRadius(4, 4, 0, 0), Background = purple }.At(0, 1));
            ToolTipService.SetToolTip(column, $"{item.Name}: {(item.Plays == 1 ? "1 play" : $"{item.Plays:N0} plays")}");
            grid.Children.Add(column.At(index));
            grid.Children.Add(Ui.Text(item.Name, "CaptionText").With(text => text.HorizontalAlignment = HorizontalAlignment.Center).At(index, 1));
        }
        return grid;
    }
}
