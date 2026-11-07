using System.Globalization;
using Groovelight.Controls;
using Groovelight.Core.Library;
using Groovelight.Metadata;
using Groovelight.Model;
using Groovelight.Support;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Groovelight.Views;

/// <summary>A list column beside the page (the Artists and Genres lists, like Music's).</summary>
public sealed partial class SelectableList<T> : UserControl where T : notnull
{
    private readonly ListView list = new() { SelectionMode = ListViewSelectionMode.Single, Padding = new Thickness(4, 8, 4, 8) };
    private readonly Func<T, string> key;
    private readonly Func<T, UIElement> row;
    private List<T> items = [];
    private bool updating;

    public event Action<T>? Selected;

    public SelectableList(Func<T, string> key, Func<T, UIElement> row)
    {
        this.key = key;
        this.row = row;
        Content = list;
        list.SelectionChanged += (_, _) =>
        {
            if (updating || list.SelectedIndex < 0 || list.SelectedIndex >= items.Count) return;
            Selected?.Invoke(items[list.SelectedIndex]);
        };
    }

    public void Set(List<T> values, string? selectedKey)
    {
        updating = true;
        var same = values.Count == items.Count && values.Select(key).SequenceEqual(items.Select(key));
        items = values;
        if (!same)
        {
            list.Items.Clear();
            foreach (var item in values) list.Items.Add(new ListViewItem { Content = row(item), Padding = new Thickness(10, 4, 10, 4) });
        }
        Select(selectedKey);
        updating = false;
    }

    public void Select(string? selectedKey)
    {
        var index = selectedKey is null ? -1 : items.FindIndex(item => key(item) == selectedKey);
        var wasUpdating = updating;
        updating = true;
        list.SelectedIndex = index;
        updating = wasUpdating;
        if (index >= 0 && list.Items[index] is UIElement element) DispatcherQueue.TryEnqueue(() => list.ScrollIntoView(list.Items[index], ScrollIntoViewAlignment.Default));
    }
}

/// <summary>The Artists page: the artist list column and the selected artist's page.</summary>
public sealed partial class ArtistsPage : PageView
{
    private readonly SelectableList<ArtistSummary> list;
    private readonly Border detail = new();
    private Dictionary<string, string> photos = [];
    private ArtistDetailView? shown;

    public ArtistsPage()
    {
        list = new SelectableList<ArtistSummary>(artist => artist.Name, ArtistRow);
        list.Selected += artist => Model.SelectedArtist = artist.Name;
        var grid = Ui.Grid("250,*");
        var column = new Border { Child = list, BorderThickness = new Thickness(0, 0, 1, 0), BorderBrush = Ui.Brush("DividerStrokeColorDefaultBrush") };
        grid.Children.Add(column);
        grid.Children.Add(detail.At(1));
        Content = grid;
        // Compilations first, like Music, when the library has any.
        Observations.Add(Model.Database, db => new[] { db.Compilations() }.OfType<ArtistSummary>().Concat(db.Artists()).ToList(), artists =>
        {
            // Names coming from other pages may differ in case, and a compilation's "Various Artists" means the compilations entry.
            if (Model.SelectedArtist is { } wanted && !artists.Any(artist => artist.Name == wanted))
            {
                Model.SelectedArtist = artists.FirstOrDefault(artist => string.Equals(artist.Name, wanted, StringComparison.OrdinalIgnoreCase))?.Name
                    ?? (string.Equals(wanted, "Various Artists", StringComparison.OrdinalIgnoreCase) ? artists.FirstOrDefault(artist => artist.IsCompilations)?.Name : null);
            }
            Model.SelectedArtist ??= artists.FirstOrDefault()?.Name;
            list.Set(artists, Model.SelectedArtist);
            ShowSelected();
        });
        Observations.Add(Model.Database, db => db.AllArtistInfo().Select(row => (row.ArtistKey, ArtistInfo.Decode(row.Data)?.ImageHash))
            .Where(pair => pair.ImageHash is not null).GroupBy(pair => pair.ArtistKey).ToDictionary(group => group.Key, group => group.First().ImageHash!), value =>
        {
            photos = value;
        });
        Model.PropertyChanged += OnModelChanged;
    }

    public override string Title => Model.SelectedArtist is { } name ? ArtistSummary.GetDisplayName(name) : "Artists";

    private UIElement ArtistRow(ArtistSummary artist)
    {
        var picture = artist.IsCompilations
            ? CompilationsArtwork(40)
            : new ArtworkImage { Hash = photos.GetValueOrDefault(artist.Name.ToLowerInvariant()) ?? artist.ArtworkHash, Width = 40, Height = 40, Radius = 20 };
        var text = Ui.Column(0, Ui.Text(artist.DisplayName), Ui.Text(Format.Count(artist.AlbumCount, "album"), "CaptionText"));
        text.VerticalAlignment = VerticalAlignment.Center;
        return Ui.Row(10, picture, text);
    }

    /// <summary>The picture of the Compilations entry: stacked albums on the app's color.</summary>
    public static FrameworkElement CompilationsArtwork(double size)
    {
        var grid = new Grid { Width = size, Height = size, CornerRadius = new CornerRadius(size / 2) };
        grid.Children.Add(new Border { Background = Ui.Brush("BrandBrush") });
        grid.Children.Add(new FontIcon { Glyph = "", FontSize = size * 0.42, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White) });
        return grid;
    }

    private void OnModelChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
    {
        if (args.PropertyName != nameof(AppModel.SelectedArtist)) return;
        list.Select(Model.SelectedArtist);
        ShowSelected();
    }

    private void ShowSelected()
    {
        if (Model.SelectedArtist is not { } name)
        {
            shown?.Dispose();
            shown = null;
            detail.Child = Ui.Unavailable(Glyphs.Artist, "Select an Artist");
            return;
        }
        if (shown?.Artist == name) return;
        shown?.Dispose();
        shown = new ArtistDetailView(name);
        detail.Child = shown;
        MainWindow.Current?.RefreshTitle();
    }

    public override void Dispose()
    {
        Model.PropertyChanged -= OnModelChanged;
        shown?.Dispose();
        base.Dispose();
    }
}

/// <summary>An artist's page: photo, name, background, Play and Shuffle, then each album with its songs.</summary>
public sealed partial class ArtistDetailView : PageView
{
    public string Artist { get; }
    private readonly StackPanel albumsPanel = new() { Spacing = 44 };
    private readonly StackPanel titleBlock = new() { Spacing = 10, VerticalAlignment = VerticalAlignment.Bottom, Padding = new Thickness(0, 0, 0, 24) };
    private readonly StackPanel photoBlock = new() { Spacing = 6 };
    private readonly Grid header = new() { ColumnSpacing = 28, RowSpacing = 20 };
    private List<(AlbumSummary Album, List<Track> Tracks)> albums = [];
    private ArtistInfo? info;
    private bool IsCompilations => Artist == ArtistSummary.Compilations;

    public ArtistDetailView(string artist)
    {
        Artist = artist;
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        header.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        header.Children.Add(photoBlock);
        header.Children.Add(titleBlock);
        header.SizeChanged += (_, args) =>
        {
            var wide = args.NewSize.Width >= 720;
            Grid.SetColumn(titleBlock, wide ? 1 : 0);
            Grid.SetRow(titleBlock, wide ? 0 : 1);
        };
        Content = Scroll(Ui.Column(28, header, albumsPanel), 28);
        Observations.Add(Model.Database, db => db.Albums(AlbumSort.Year, artist).Select(album => (album, db.TracksOfAlbum(album.AlbumKey))).ToList(), value =>
        {
            albums = value;
            BuildHeader();
            albumsPanel.Children.Clear();
            foreach (var (album, tracks) in value) albumsPanel.Children.Add(new ArtistAlbumSection(album, tracks));
        });
        Observations.Add(Model.Database, db => db.ArtistInfo(artist), value =>
        {
            info = value is { } row ? ArtistInfo.Decode(row.Data) : null;
            BuildHeader();
        });
        Model.Metadata.PropertyChanged += OnMetadataChanged;
        if (!IsCompilations) _ = Model.Metadata.LoadArtistInfoAsync(artist);
    }

    public override string Title => ArtistSummary.GetDisplayName(Artist);

    private void OnMetadataChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
    {
        if (args.PropertyName == nameof(MetadataStore.ArtistInfoInFlight)) BuildHeader();
    }

    private List<Track> AllTracks => albums.SelectMany(entry => entry.Tracks).ToList();

    private void BuildHeader()
    {
        photoBlock.Children.Clear();
        FrameworkElement photo = IsCompilations
            ? ArtistsPage.CompilationsArtwork(220)
            : new ArtworkImage { Hash = info?.ImageHash ?? albums.FirstOrDefault().Album?.ArtworkHash, IsLarge = true, Width = 220, Height = 220, Radius = 110 };
        photo.Translation = new System.Numerics.Vector3(0, 0, 32);
        photo.Shadow = new ThemeShadow();
        photoBlock.Children.Add(photo);
        if (info?.ImageHash is not null && info.About?.Url is { } url && Uri.TryCreate(url, UriKind.Absolute, out var link))
        {
            // Commons photos have various open licenses: credit and link to the source article.
            photoBlock.Children.Add(new HyperlinkButton { Content = Ui.Text("Photo: Wikimedia Commons", "SmallText", 10), NavigateUri = link, Padding = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Center });
        }
        titleBlock.Children.Clear();
        titleBlock.Children.Add(Ui.Text(ArtistSummary.GetDisplayName(Artist), "LargeTitleText"));
        titleBlock.Children.Add(Ui.Text($"{Format.Count(albums.Count, "album")}, {Format.Songs(AllTracks.Count)}", "SecondaryText"));
        if (info?.About is { } about) titleBlock.Children.Add(new AboutExcerpt(about));
        else if (Model.Metadata.ArtistInfoInFlight.Contains(Artist)) titleBlock.Children.Add(AlbumPage.LoadingNote("Looking up artist info…"));
        var buttons = Ui.Row(10, Ui.Button("Play", () => Model.Play(AllTracks), Glyphs.Play, "AccentPillButton"),
                              Ui.Button("Shuffle", () => Model.Play(AllTracks, shuffle: true), Glyphs.Shuffle));
        foreach (var child in buttons.Children.OfType<Control>()) child.IsEnabled = albums.Count > 0;
        buttons.Margin = new Thickness(0, 4, 0, 0);
        titleBlock.Children.Add(buttons);
    }

    public override void Dispose()
    {
        Model.Metadata.PropertyChanged -= OnMetadataChanged;
        base.Dispose();
    }
}

/// <summary>An album on its artist's page: the cover on the left; title, genre and year, actions and the songs on the right.</summary>
public sealed partial class ArtistAlbumSection : Grid
{
    public ArtistAlbumSection(AlbumSummary album, List<Track> tracks)
    {
        var model = AppModel.Current;
        ColumnSpacing = 32;
        RowSpacing = 18;
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var cover = new ArtworkImage { Hash = album.ArtworkHash, IsLarge = true, Radius = 8 };
        var coverButton = new Button { Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = Images.Transparent, Content = cover, VerticalAlignment = VerticalAlignment.Top };
        coverButton.Click += (_, _) => model.ShowAlbum(album);
        ToolTipService.SetToolTip(coverButton, $"Show {album.Title}");
        Children.Add(coverButton);
        var title = Ui.Link(album.Title, () => model.ShowAlbum(album), "BodyText");
        if (title is HyperlinkButton { Content: TextBlock text }) { text.FontSize = 22; text.FontWeight = FontWeights.Bold; text.Foreground = Ui.Brush("TextFillColorPrimaryBrush"); }
        var titleColumn = Ui.Column(4, title);
        if (Format.Joined(album.Genre, album.Year) is { Length: > 0 } subtitle) titleColumn.Children.Add(Ui.Text(subtitle, "SecondaryText", 13));
        var actions = Ui.Row(8,
            Ui.IconButton(Glyphs.Play, "Play", () => model.PlayAlbum(album), 14, "CircleButton"),
            Ui.IconButton(Glyphs.Shuffle, "Shuffle", () => model.PlayAlbum(album, shuffle: true), 14, "CircleButton"),
            Ui.MenuButton(() => Menus.Flyout(Menus.QueueItems(new SongSource.Album(album.AlbumKey)).Concat(new MenuFlyoutItemBase[]
            {
                new MenuFlyoutSeparator(),
                Menus.Item("Get Info…", () => model.GetInfo(album.AlbumKey), Glyphs.Info),
                Menus.Item("Fix Metadata…", () => model.Metadata.Review(tracks), Glyphs.Wand),
                Menus.Item("Show in File Explorer", () => AppModel.ShowInExplorer(tracks), Glyphs.Folder),
            }))));
        var top = Ui.Grid("*,auto");
        top.Children.Add(titleColumn);
        top.Children.Add(actions.At(1));
        var list = new TrackList { ListStyle = TrackListStyle.Album, AlbumKey = album.AlbumKey, Tracks = tracks };
        var details = Ui.Column(12, top, Ui.Separator(), list);
        Children.Add(details);
        SizeChanged += (_, args) =>
        {
            var sideBySide = args.NewSize.Width >= 720;
            var size = sideBySide ? Math.Min(320, args.NewSize.Width * 0.32) : Math.Min(260, args.NewSize.Width);
            cover.Width = cover.Height = size;
            SetColumn(details, sideBySide ? 1 : 0);
            SetRow(details, sideBySide ? 0 : 1);
        };
    }
}

/// <summary>The Genres page: the genre list column and the chosen genre's songs.</summary>
public sealed partial class GenresPage : PageView
{
    private readonly SelectableList<string> list;
    private readonly TrackList tracks = new() { ListStyle = TrackListStyle.Playlist };
    private readonly TextBlock title = Ui.Text("", "PageTitleText");
    private List<Track> songs = [];
    private IDisposable? songsObservation;

    public GenresPage()
    {
        list = new SelectableList<string>(genre => genre, genre => Ui.Text(genre));
        list.Selected += genre => Model.SelectedGenre = genre;
        var head = Ui.Grid("*,auto");
        head.Children.Add(title);
        head.Children.Add(Ui.Button("Shuffle", () => Model.Play(songs, shuffle: true), Glyphs.Shuffle, "AccentPillButton").At(1));
        var grid = Ui.Grid("250,*");
        grid.Children.Add(new Border { Child = list, BorderThickness = new Thickness(0, 0, 1, 0), BorderBrush = Ui.Brush("DividerStrokeColorDefaultBrush") });
        grid.Children.Add(Scroll(Ui.Column(16, head, tracks), 24).At(1));
        Content = grid;
        Observations.Add(Model.Database, db => db.Genres(), genres =>
        {
            if (Model.SelectedGenre is null || !genres.Contains(Model.SelectedGenre)) Model.SelectedGenre = genres.FirstOrDefault();
            list.Set(genres, Model.SelectedGenre);
            ShowSelected();
        });
        Model.PropertyChanged += OnModelChanged;
    }

    public override string Title => Model.SelectedGenre ?? "Genres";

    private void OnModelChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
    {
        if (args.PropertyName == nameof(AppModel.SelectedGenre)) ShowSelected();
    }

    private string? shownGenre;

    private void ShowSelected()
    {
        var genre = Model.SelectedGenre;
        if (genre == shownGenre) return;
        shownGenre = genre;
        title.Text = genre ?? "";
        songsObservation?.Dispose();
        songsObservation = genre is null ? null : new Observation<List<Track>>(Model.Database, db => db.TracksOfGenre(genre), value =>
        {
            songs = value;
            tracks.Tracks = value;
        });
        MainWindow.Current?.RefreshTitle();
    }

    public override void Dispose()
    {
        Model.PropertyChanged -= OnModelChanged;
        songsObservation?.Dispose();
        base.Dispose();
    }
}

/// <summary>A round picture with initials on a color from the name (credits have no photos).</summary>
public static class PersonAvatar
{
    public static FrameworkElement Make(string name, double size)
    {
        var value = 5;
        foreach (var character in name) value = (value * 31 + character) & 0xFFFF;
        var hue = value % 360 / 360.0;
        var initials = string.Concat(name.Split(' ', StringSplitOptions.RemoveEmptyEntries).Take(2).Select(word => word[0]));
        var grid = new Grid { Width = size, Height = size };
        grid.Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse
        {
            Fill = new LinearGradientBrush
            {
                StartPoint = new Windows.Foundation.Point(0, 0), EndPoint = new Windows.Foundation.Point(1, 1),
                GradientStops =
                {
                    new GradientStop { Color = ArtworkImage.Hsb(hue, 0.45, 0.75), Offset = 0 },
                    new GradientStop { Color = ArtworkImage.Hsb(hue, 0.6, 0.35), Offset = 1 },
                },
            },
        });
        grid.Children.Add(new TextBlock
        {
            Text = initials, FontSize = size * 0.36, FontWeight = FontWeights.SemiBold, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White),
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        });
        return grid;
    }
}

/// <summary>
/// A musician, producer, songwriter or studio from the credits: what they did in the library, with their albums and
/// songs, ready to play or turn into a playlist.
/// </summary>
public sealed partial class PersonPage : PageView
{
    private readonly CreditPerson person;
    private readonly StackPanel body = new() { Spacing = 28 };
    private PersonCredits? credits;
    private (int Known, int Total) coverage;
    private bool isLibraryArtist;
    private string? photo;

    public PersonPage(CreditPerson person)
    {
        this.person = person;
        Content = Scroll(body, 28);
        Observations.Add(Model.Database, db => (db.Credits(person), db.CreditCoverage(),
                                               db.Artists().Any(artist => string.Equals(artist.Name, person.Name, StringComparison.OrdinalIgnoreCase))), value =>
        {
            (credits, coverage, isLibraryArtist) = value;
            Build();
        });
        Observations.Add(Model.Database, db => db.ArtistInfo(person.Name), value =>
        {
            photo = value is { } row ? ArtistInfo.Decode(row.Data)?.ImageHash : null;
            Build();
        });
        Model.Metadata.PropertyChanged += OnMetadataChanged;
    }

    public override string Title => person.Name;

    private void OnMetadataChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
    {
        if (args.PropertyName == nameof(MetadataStore.IsFetchingLibraryInfo)) Build();
    }

    private void Build()
    {
        body.Children.Clear();
        var tracks = credits?.Tracks.Select(item => item.Track).ToList() ?? [];
        var header = Ui.Row(24, photo is not null
            ? new ArtworkImage { Hash = photo, IsLarge = true, Width = 140, Height = 140, Radius = 70 }
            : PersonAvatar.Make(person.Name, 140));
        var info = Ui.Column(6, Ui.Text(person.Name, "PageTitleText"));
        if (credits?.Roles is { Count: > 0 } roles) info.Children.Add(Ui.Text(Capitalized(string.Join(", ", roles.Take(6))), "SecondaryText", 15));
        var albumCount = credits?.Albums.Count ?? 0;
        info.Children.Add(Ui.Text($"{Format.Count(albumCount, "album")} · {Format.Songs(tracks.Count)} in your library", "SmallText", 12));
        var buttons = Ui.Row(12, Ui.Button("Play", () => Model.Play(tracks), Glyphs.Play, "AccentPillButton"),
                              Ui.Button("Shuffle", () => Model.Play(tracks, shuffle: true), Glyphs.Shuffle),
                              Ui.Button("Create Playlist", () => Model.CreatePlaylist($"With {person.Name}", tracks), Glyphs.AddToPlaylist,
                                        tooltip: $"A playlist of every song {person.Name} is credited on"));
        if (isLibraryArtist) buttons.Children.Add(Ui.Button("Artist Page", () => Model.ShowArtist(person.Name), Glyphs.Artist));
        foreach (var button in buttons.Children.OfType<Control>()) button.IsEnabled = tracks.Count > 0;
        buttons.Margin = new Thickness(0, 8, 0, 0);
        info.Children.Add(buttons);
        info.VerticalAlignment = VerticalAlignment.Center;
        header.Children.Add(info);
        body.Children.Add(header);
        if (credits?.Albums is { Count: > 0 } albums)
        {
            var grid = new AlbumGrid { Albums = albums.Select(item => item.Album).ToList() };
            body.Children.Add(Ui.Column(14, Ui.Text("Albums", "SectionTitleText"), grid));
        }
        if (tracks.Count > 0) body.Children.Add(Ui.Column(10, Ui.Text("Songs", "SectionTitleText"), new TrackList { ListStyle = TrackListStyle.Playlist, Tracks = tracks }));
        // Credits are only known for albums looked up so far: offer to look up the rest.
        if (coverage.Known < coverage.Total)
        {
            var note = Ui.Row(10, Ui.Icon(Glyphs.Info, 14, "SecondaryIcon"));
            if (Model.Metadata.IsFetchingLibraryInfo) note.Children.Add(Ui.Text("Fetching missing library info in the background (see the navigation pane).", "SecondaryText"));
            else
            {
                note.Children.Add(Ui.Text($"Credits are known for {coverage.Known} of {coverage.Total} albums, so {person.Name} may appear on more.", "SecondaryText"));
                note.Children.Add(new HyperlinkButton { Content = "Look Up the Rest" }.With(link => link.Click += (_, _) => Model.Metadata.FetchMissingInfo([MetadataStore.LibraryStep.Albums])));
            }
            body.Children.Add(note);
        }
    }

    private static string Capitalized(string text) => text.Length == 0 ? text : char.ToUpper(text[0], CultureInfo.CurrentCulture) + text[1..];

    public override void Dispose()
    {
        Model.Metadata.PropertyChanged -= OnMetadataChanged;
        base.Dispose();
    }
}
