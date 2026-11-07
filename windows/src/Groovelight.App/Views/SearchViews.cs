using System.Globalization;
using Groovelight.Controls;
using Groovelight.Core.Library;
using Groovelight.Metadata;
using Groovelight.Model;
using Groovelight.Support;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace Groovelight.Views;

/// <summary>Searches recently opened or submitted, newest first (one per line in the preferences).</summary>
public static class RecentSearches
{
    public const string Key = "search.recent";
    private const int Limit = 10;

    public static List<string> List() =>
        (AppModel.Current.Preferences.String(Key) ?? "").Split('\n', StringSplitOptions.RemoveEmptyEntries).ToList();

    public static void Add(string query)
    {
        query = query.Trim();
        if (query.Length == 0) return;
        var updated = new[] { query }.Concat(List().Where(item => !string.Equals(item, query, StringComparison.CurrentCultureIgnoreCase))).Take(Limit);
        AppModel.Current.Preferences.Set(Key, string.Join("\n", updated));
    }

    public static void Clear() => AppModel.Current.Preferences.Set(Key, "");
}

/// <summary>The results of a search with the artists' photos (by lowercased name).</summary>
public sealed record SearchResultsPage(LibrarySearchResults Results, Dictionary<string, string> Photos)
{
    public static SearchResultsPage Load(Microsoft.Data.Sqlite.SqliteConnection db, string query)
    {
        var results = db.Search(query);
        var photos = new Dictionary<string, string>();
        foreach (var artist in results.Artists.Take(100))
        {
            if (db.ArtistInfo(artist.Name) is { } row && ArtistInfo.Decode(row.Data)?.ImageHash is { } hash) photos[artist.Name.ToLowerInvariant()] = hash;
        }
        return new SearchResultsPage(results, photos);
    }
}

/// <summary>The Search page: recent searches until something is typed in the title bar, then the results by category.</summary>
public sealed partial class SearchPage : PageView
{
    private readonly ContentControl host = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private string shownQuery = "\u0001";
    private IDisposable? results;

    public SearchPage()
    {
        Content = host;
        Model.PropertyChanged += OnModelChanged;
        Update();
    }

    public override string Title => "Search";

    private void OnModelChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
    {
        if (args.PropertyName == nameof(AppModel.SearchText)) Update();
    }

    private void Update()
    {
        var query = Model.SearchText.Trim();
        if (query == shownQuery) return;
        shownQuery = query;
        results?.Dispose();
        results = null;
        if (query.Length == 0)
        {
            host.Content = Landing();
            return;
        }
        var view = new SearchResultsView(query);
        results = view;
        host.Content = view;
    }

    private FrameworkElement Landing()
    {
        var panel = Ui.Column(24, Ui.Column(6, Ui.Text("Search", "PageTitleText"),
            Ui.Text("Find artists, albums and songs, and the people credited on your albums: musicians, producers, engineers and studios.", "WrappingSecondaryText")));
        var searches = RecentSearches.List();
        if (searches.Count > 0)
        {
            var head = Ui.Grid("*,auto");
            head.Children.Add(Ui.Text("Recent Searches", "SectionTitleText"));
            var clear = new HyperlinkButton { Content = "Clear" };
            clear.Click += (_, _) => { RecentSearches.Clear(); host.Content = Landing(); };
            head.Children.Add(clear.At(1));
            var list = Ui.Column(0, head);
            list.MaxWidth = 520;
            list.HorizontalAlignment = HorizontalAlignment.Left;
            foreach (var search in searches)
            {
                var button = new Button
                {
                    Style = Ui.Style("BarButton"), HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left,
                    Content = Ui.Row(10, Ui.Icon(Glyphs.Search, 13, "SecondaryIcon"), new TextBlock { Text = search }), Padding = new Thickness(6, 8, 6, 8),
                };
                button.Click += (_, _) => Model.SearchText = search;
                list.Children.Add(button);
                list.Children.Add(Ui.Separator());
            }
            panel.Children.Add(list);
        }
        return Scroll(panel, 24);
    }

    public override void Dispose()
    {
        Model.PropertyChanged -= OnModelChanged;
        results?.Dispose();
        base.Dispose();
    }
}

/// <summary>
/// Search results like Music's: a section per category ("Artists ›" opens them all), artists as large round photos,
/// albums in one row of covers, songs in a grid of three rows that scrolls sideways, and people from the credits.
/// </summary>
public sealed partial class SearchResultsView : PageView
{
    private readonly string query;
    private readonly StackPanel panel = new() { Spacing = 30 };

    public SearchResultsView(string query)
    {
        this.query = query;
        Content = new ScrollViewer { Content = new Border { Padding = new Thickness(28, 20, 28, 28), Child = panel } };
        Observations.Add(Model.Database, db => SearchResultsPage.Load(db, query), Build);
        Model.PropertyChanged += OnModelChanged;
    }

    /// <summary>Opening a result remembers the search.</summary>
    private void OnModelChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
    {
        if (args.PropertyName == nameof(AppModel.Path) && Model.Path.Count > 0) RecentSearches.Add(query);
    }

    private void Build(SearchResultsPage page)
    {
        panel.Children.Clear();
        var results = page.Results;
        if (results.IsEmpty)
        {
            panel.Children.Add(Ui.Unavailable(Glyphs.Search, $"No Results for “{query}”", "Check the spelling or try a new search.").Margin(0, 60, 0, 0));
            return;
        }
        if (results.Artists.Count > 0)
            panel.Children.Add(Section(SearchCategory.Artists, Shelf(results.Artists.Take(20).Select(artist => ArtistCircle(artist, page.Photos.GetValueOrDefault(artist.Name.ToLowerInvariant()), 200)), 200, 24)));
        if (results.Albums.Count > 0)
        {
            panel.Children.Add(Section(SearchCategory.Albums, Shelf(results.Albums.Take(30).Select(album =>
            {
                var card = new AlbumCard();
                card.Bind(album, true);
                return (FrameworkElement)card;
            }), 220, 22)));
        }
        if (results.Songs.Count > 0) panel.Children.Add(Section(SearchCategory.Songs, SongGrid(results.Songs.Take(36).ToList())));
        if (results.People.Count > 0)
            panel.Children.Add(Section(SearchCategory.Credits, Shelf(results.People.Take(20).Select(person => PersonCircle(person, 160)), 160, 24)));
    }

    /// <summary>A category's header ("Albums ›", which opens all of them) above its row.</summary>
    private FrameworkElement Section(SearchCategory category, FrameworkElement content)
    {
        var header = new Button
        {
            Style = Ui.Style("BarButton"), Padding = new Thickness(2),
            Content = Ui.Row(4, Ui.Text(category.ToString(), "SectionTitleText", 19, FontWeights.Bold), Ui.Icon(Glyphs.Chevron, 12, "SecondaryIcon").With(icon => icon.VerticalAlignment = VerticalAlignment.Center)),
        };
        ToolTipService.SetToolTip(header, $"Show all {category.ToString().ToLowerInvariant()}");
        header.Click += (_, _) => Model.Push(new Route.SearchResults(category, query));
        return Ui.Column(12, header, content);
    }

    /// <summary>One row of items that scrolls sideways, with page buttons at the edges (like Music's shelves).</summary>
    internal static FrameworkElement Shelf(IEnumerable<FrameworkElement> items, double itemWidth, double spacing)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = spacing };
        foreach (var item in items)
        {
            item.Width = itemWidth;
            row.Children.Add(item);
        }
        var scroll = new ScrollViewer
        {
            Content = row, HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, HorizontalScrollMode = ScrollMode.Enabled,
            VerticalScrollMode = ScrollMode.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        var back = Ui.IconButton("", "Back", () => scroll.ChangeView(Math.Max(0, scroll.HorizontalOffset - Math.Max(scroll.ViewportWidth - itemWidth, itemWidth)), null, null), 14, "PillButton");
        var forward = Ui.IconButton(Glyphs.Chevron, "Forward", () => scroll.ChangeView(scroll.HorizontalOffset + Math.Max(scroll.ViewportWidth - itemWidth, itemWidth), null, null), 14, "PillButton");
        foreach (var (button, alignment) in new[] { (back, HorizontalAlignment.Left), (forward, HorizontalAlignment.Right) })
        {
            button.HorizontalAlignment = alignment;
            button.VerticalAlignment = VerticalAlignment.Center;
            button.Height = 44;
            button.Padding = new Thickness(4);
            button.Background = Ui.Brush("AcrylicInAppFillColorDefaultBrush");
            button.Visibility = Visibility.Collapsed;
        }
        var grid = new Grid();
        grid.Children.Add(scroll);
        grid.Children.Add(back);
        grid.Children.Add(forward);
        void Update(bool hovering)
        {
            back.Visibility = hovering && scroll.HorizontalOffset > 1 ? Visibility.Visible : Visibility.Collapsed;
            forward.Visibility = hovering && scroll.HorizontalOffset + scroll.ViewportWidth < scroll.ExtentWidth - 1 ? Visibility.Visible : Visibility.Collapsed;
        }
        var hovering = false;
        grid.PointerEntered += (_, _) => { hovering = true; Update(true); };
        grid.PointerExited += (_, _) => { hovering = false; Update(false); };
        scroll.ViewChanged += (_, _) => Update(hovering);
        return grid;
    }

    /// <summary>An artist as a large round photo (or one of their covers) with the name below; opens the artist's page.</summary>
    internal static FrameworkElement ArtistCircle(ArtistSummary artist, string? photo, double size)
    {
        var image = new ArtworkImage { Hash = photo ?? artist.ArtworkHash, Width = size, Height = size, Radius = size / 2, IsLarge = size > 150 };
        var column = Ui.Column(10, image, Ui.Text(artist.DisplayName, "BodyText", 13).With(t => t.HorizontalAlignment = HorizontalAlignment.Center));
        var button = new Button { Content = column, Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = Images.Transparent };
        button.Click += (_, _) => AppModel.Current.Push(new Route.Artist(artist.Name));
        return button;
    }

    /// <summary>Someone from the credits as a round monogram with their main roles; opens their page.</summary>
    internal static FrameworkElement PersonCircle(CreditedPerson person, double size)
    {
        var roles = string.Join(", ", person.Roles.Take(2).Select(role => role.Length == 0 ? role : char.ToUpper(role[0], CultureInfo.CurrentCulture) + role[1..]));
        var column = Ui.Column(6, PersonAvatar.Make(person.Person.Name, size),
            Ui.Text(person.Person.Name, "BodyText", 13).With(t => { t.HorizontalAlignment = HorizontalAlignment.Center; t.Margin = new Thickness(0, 4, 0, 0); }),
            Ui.Text(roles, "CaptionText", 11).With(t => t.HorizontalAlignment = HorizontalAlignment.Center));
        var button = new Button { Content = column, Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = Images.Transparent };
        button.Click += (_, _) => AppModel.Current.ShowPerson(person.Person);
        return button;
    }

    /// <summary>Songs in a grid of three rows that scrolls sideways: cover, title, artist and "⋯" in each cell.</summary>
    private static FrameworkElement SongGrid(List<Track> tracks)
    {
        var columns = new List<FrameworkElement>();
        for (var start = 0; start < tracks.Count; start += 3)
        {
            var column = Ui.Column(0);
            for (var index = start; index < Math.Min(start + 3, tracks.Count); index++) column.Children.Add(new SongCell(tracks, index));
            columns.Add(column);
        }
        return Shelf(columns, 400, 24);
    }

    public override void Dispose()
    {
        Model.PropertyChanged -= OnModelChanged;
        base.Dispose();
    }
}

/// <summary>A song in the search results' song grid.</summary>
public sealed partial class SongCell : Grid
{
    public SongCell(List<Track> tracks, int index)
    {
        var model = AppModel.Current;
        var track = tracks[index];
        ColumnSpacing = 12;
        Padding = new Thickness(0, 7, 0, 7);
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var cover = new ArtworkImage { Hash = track.ArtworkHash, Width = 46, Height = 46, Radius = 5 };
        var play = new Button { Content = cover, Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = Images.Transparent };
        play.Click += (_, _) =>
        {
            if (model.Player.Current?.Id == track.Id) model.Player.TogglePlayPause();
            else model.Play(tracks, index);
        };
        ToolTipService.SetToolTip(play, "Play");
        Children.Add(play);
        var title = Ui.Text(track.Title, model.Player.Current?.Id == track.Id ? "BrandText" : "BodyText", 13);
        Children.Add(Ui.Column(2, title, Ui.Text(track.Artist ?? track.AlbumArtist ?? "Unknown Artist", "CaptionText")).With(c => c.VerticalAlignment = VerticalAlignment.Center).At(1));
        var more = Ui.IconButton(Glyphs.More, "More", () => { }, 13);
        more.Click += (_, _) => Menus.Flyout(Menus.TrackItems([track])).ShowAt(more, new FlyoutShowOptions { Placement = FlyoutPlacementMode.BottomEdgeAlignedRight });
        more.Opacity = 0.6;
        Children.Add(more.At(2));
        Background = Images.Transparent;
        PointerEntered += (_, _) => more.Opacity = 1;
        PointerExited += (_, _) => more.Opacity = 0.6;
        DoubleTapped += (_, _) => model.Play(tracks, index);
        ContextRequested += (_, args) =>
        {
            args.Handled = true;
            var menu = Menus.Flyout(Menus.TrackItems([track]));
            if (args.TryGetPosition(this, out var point)) menu.ShowAt(this, point); else menu.ShowAt(this);
        };
        CanDrag = true;
        DragStarting += (_, args) => { if (track.Id is { } id) TrackList.SetDragData(args.Data, [id]); };
    }
}

/// <summary>Every result of one category ("Albums ›" in the results).</summary>
public sealed partial class SearchCategoryPage : PageView
{
    private readonly SearchCategory category;
    private readonly StackPanel panel = new() { Spacing = 20 };

    public SearchCategoryPage(SearchCategory category, string query)
    {
        this.category = category;
        Content = Scroll(panel, 28);
        panel.Children.Add(Ui.Column(2, Ui.Text(category.ToString(), "PageTitleText"), Ui.Text($"Results for “{query}”", "SecondaryText")));
        Observations.Add(Model.Database, db => SearchResultsPage.Load(db, query), page =>
        {
            while (panel.Children.Count > 1) panel.Children.RemoveAt(1);
            switch (category)
            {
                case SearchCategory.Artists:
                    panel.Children.Add(Wrap(page.Results.Artists.Select(artist => SearchResultsView.ArtistCircle(artist, page.Photos.GetValueOrDefault(artist.Name.ToLowerInvariant()), 170)), 194));
                    break;
                case SearchCategory.Albums:
                    panel.Children.Add(new AlbumGrid { Albums = page.Results.Albums });
                    break;
                case SearchCategory.Songs:
                    panel.Children.Add(new TrackList { ListStyle = TrackListStyle.Playlist, Tracks = page.Results.Songs });
                    break;
                default:
                    panel.Children.Add(Wrap(page.Results.People.Select(person => SearchResultsView.PersonCircle(person, 150)), 174));
                    break;
            }
        });
    }

    public override string Title => category.ToString();

    private static FrameworkElement Wrap(IEnumerable<FrameworkElement> items, double width)
    {
        var grid = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, ItemWidth = width };
        foreach (var item in items)
        {
            item.Margin = new Thickness(0, 0, 0, 26);
            grid.Children.Add(item);
        }
        return grid;
    }
}
