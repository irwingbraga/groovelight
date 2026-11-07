using Groovelight.Controls;
using Groovelight.Core.Library;
using Groovelight.Metadata;
using Groovelight.Model;
using Groovelight.Support;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;

namespace Groovelight.Views;

/// <summary>A page's cover size: the Albums grid and the Shelf each keep their own (the Mac's CoverSize).</summary>
public sealed record CoverSize(string Key, double Standard, double Min, double Max, double Step)
{
    public static readonly CoverSize Albums = new("albums.coverSize", 180, 110, 380, 30);
    public static readonly CoverSize Shelf = new("shelf.coverSize", 300, 180, 460, 40);

    public double Clamped(double value) => Math.Clamp(value, Min, Max);

    public double Current => Clamped(AppModel.Current.Preferences.Double(Key, Standard));

    /// <summary>Changes the saved size by <paramref name="steps"/> (View > Bigger / Smaller Covers).</summary>
    public void Change(double steps) => AppModel.Current.Preferences.Set(Key, Clamped(Current + steps * Step));

    public void Reset() => AppModel.Current.Preferences.Remove(Key);
}

/// <summary>An album in a grid: cover with Play and Shuffle on hover, title and artist; click opens it.</summary>
public sealed partial class AlbumCard : StackPanel
{
    private readonly ArtworkImage artwork = new() { Radius = 10 };
    private readonly TextBlock title = new() { Style = Ui.Style("BodyText"), FontSize = 13, FontWeight = FontWeights.Medium };
    private readonly TextBlock artist = new() { Style = Ui.Style("CaptionText") };
    private readonly Grid hoverButtons = new() { Padding = new Thickness(8), VerticalAlignment = VerticalAlignment.Bottom, Opacity = 0 };
    private readonly Microsoft.UI.Xaml.Shapes.Rectangle shadowTarget = new();
    private AlbumSummary? album;

    public AlbumCard()
    {
        Spacing = 6;
        var cover = new Grid();
        cover.SizeChanged += (_, args) => cover.Height = args.NewSize.Width;
        cover.Children.Add(artwork);
        var play = Ui.IconButton(Glyphs.Play, "Play", () => { if (album is not null) AppModel.Current.PlayAlbum(album); }, 14, "CircleButton");
        var shuffle = Ui.IconButton(Glyphs.Shuffle, "Shuffle", () => { if (album is not null) AppModel.Current.PlayAlbum(album, shuffle: true); }, 14, "CircleButton");
        shuffle.HorizontalAlignment = HorizontalAlignment.Right;
        foreach (var button in new[] { play, shuffle }) button.Background = Ui.Brush("AcrylicInAppFillColorDefaultBrush");
        hoverButtons.Children.Add(play);
        hoverButtons.Children.Add(shuffle);
        cover.Children.Add(hoverButtons);
        Children.Add(cover);
        Children.Add(title);
        Children.Add(artist);
        Background = Images.Transparent;
        artwork.Translation = new System.Numerics.Vector3(0, 0, 8);
        artwork.Shadow = new ThemeShadow();
        PointerEntered += (_, _) => { hoverButtons.Opacity = 1; artwork.Translation = new System.Numerics.Vector3(0, 0, 24); };
        PointerExited += (_, _) => { hoverButtons.Opacity = 0; artwork.Translation = new System.Numerics.Vector3(0, 0, 8); };
        hoverButtons.OpacityTransition = new ScalarTransition { Duration = TimeSpan.FromMilliseconds(150) };
        Tapped += (_, args) =>
        {
            if (args.OriginalSource is DependencyObject source && IsInside(source, hoverButtons)) return;
            if (album is not null) AppModel.Current.ShowAlbum(album);
        };
        ContextRequested += (_, args) =>
        {
            if (album is null) return;
            args.Handled = true;
            var menu = Menus.Flyout(Menus.AlbumItems(album));
            if (args.TryGetPosition(this, out var point)) menu.ShowAt(this, point); else menu.ShowAt(this);
        };
        CanDrag = true;
        DragStarting += async (_, args) =>
        {
            if (album is null) return;
            var deferral = args.GetDeferral();
            var key = album.AlbumKey;
            var ids = await Task.Run(() => AppModel.Current.Database.Read(db => db.TracksOfAlbum(key)).Select(track => track.Id).OfType<long>().ToList());
            TrackList.SetDragData(args.Data, ids, key);
            args.Data.Properties.Title = album.Title;
            deferral.Complete();
        };
        PointerCanceled += (_, _) => hoverButtons.Opacity = 0;
    }

    private static bool IsInside(DependencyObject element, DependencyObject container)
    {
        for (var current = element; current is not null; current = VisualTreeHelper.GetParent(current))
        {
            if (current == container) return current is not Grid || element != container;
        }
        return false;
    }

    public void Bind(AlbumSummary summary, bool large)
    {
        album = summary;
        artwork.IsLarge = large;
        artwork.Hash = summary.ArtworkHash;
        title.Text = summary.Title;
        artist.Text = summary.Artist;
        ToolTipService.SetToolTip(this, null);
    }
}

/// <summary>A grid of album cards (ItemsRepeater, virtualized inside a ScrollViewer).</summary>
public sealed partial class AlbumGrid : UserControl
{
    private readonly ItemsRepeater repeater = new();
    private readonly UniformGridLayout layout = new() { ItemsStretch = UniformGridLayoutItemsStretch.Uniform };
    private IReadOnlyList<AlbumSummary> albums = [];
    private double? tileSize;

    public AlbumGrid(double? tileSize = null)
    {
        repeater.Layout = layout;
        repeater.ItemTemplate = new Factory();
        repeater.ElementPrepared += (_, args) => ((AlbumCard)args.Element).Bind(albums[args.Index], Large);
        Content = repeater;
        TileSize = tileSize;
    }

    /// <summary>Smallest cover width (the Albums page's chosen size); null for the standard grid.</summary>
    public double? TileSize
    {
        get => tileSize;
        set
        {
            tileSize = value;
            var minimum = value ?? 170;
            var spacing = value is { } size ? 14 + size * 0.05 : 22;
            layout.MinItemWidth = minimum;
            layout.MinItemHeight = minimum + 54;
            layout.MinColumnSpacing = spacing;
            layout.MinRowSpacing = spacing + 4;
            for (var index = 0; index < albums.Count; index++)
            {
                if (repeater.TryGetElement(index) is AlbumCard card) card.Bind(albums[index], Large);
            }
        }
    }

    /// <summary>Big covers use the large image so they stay sharp.</summary>
    private bool Large => (tileSize ?? 170) * 1.25 > 220;

    public IReadOnlyList<AlbumSummary> Albums
    {
        get => albums;
        set
        {
            albums = value;
            repeater.ItemsSource = albums.ToList();
        }
    }

    private sealed partial class Factory : IElementFactory
    {
        private readonly Stack<AlbumCard> recycled = new();
        public UIElement GetElement(ElementFactoryGetArgs args) => recycled.Count > 0 ? recycled.Pop() : new AlbumCard();
        public void RecycleElement(ElementFactoryRecycleArgs args) { if (args.Element is AlbumCard card) recycled.Push(card); }
    }
}

/// <summary>Albums (resizable covers, sorted as chosen) or Recently Added.</summary>
public sealed partial class AlbumsPage : PageView
{
    public const string SortKey = "albums.sort";
    private readonly bool recentlyAdded;
    private readonly AlbumGrid grid;
    private readonly Grid root = new();
    private readonly ScrollViewer scroll;
    private bool hasAlbums = true;

    public AlbumsPage(bool recentlyAdded)
    {
        this.recentlyAdded = recentlyAdded;
        grid = new AlbumGrid(recentlyAdded ? null : CoverSize.Albums.Current);
        scroll = Scroll(grid, 24);
        scroll.ZoomMode = ZoomMode.Disabled;
        root.Children.Add(scroll);
        Content = root;
        if (!recentlyAdded)
        {
            Model.Preferences.Changed += OnPreferenceChanged;
            // Ctrl+wheel and pinching change the cover size, like the Mac's pinch.
            scroll.PointerWheelChanged += (_, args) =>
            {
                var ctrl = InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
                if (!ctrl) return;
                args.Handled = true;
                var delta = args.GetCurrentPoint(scroll).Properties.MouseWheelDelta;
                Model.Preferences.Set(CoverSize.Albums.Key, CoverSize.Albums.Clamped(CoverSize.Albums.Current + delta / 120.0 * 15));
            };
            ManipulationMode = Microsoft.UI.Xaml.Input.ManipulationModes.Scale;
            double? pinchStart = null;
            ManipulationStarted += (_, _) => pinchStart = CoverSize.Albums.Current;
            ManipulationDelta += (_, args) =>
            {
                if (pinchStart is { } start) Model.Preferences.Set(CoverSize.Albums.Key, CoverSize.Albums.Clamped(start * args.Cumulative.Scale));
            };
            ManipulationCompleted += (_, _) => pinchStart = null;
        }
        Reload();
    }

    public override string Title => recentlyAdded ? "Recently Added" : "Albums";

    private AlbumSort Sort => Enum.TryParse<AlbumSort>(Model.Preferences.String(SortKey), ignoreCase: true, out var sort) ? sort : AlbumSort.Artist;

    private void Reload()
    {
        Observations.Dispose();
        var sort = Sort;
        Observations.Add(Model.Database, db => recentlyAdded ? db.RecentlyAddedAlbums() : db.Albums(sort), albums =>
        {
            grid.Albums = albums;
            var empty = albums.Count == 0 && !recentlyAdded;
            if (empty == !hasAlbums) return;
            hasAlbums = !empty;
            root.Children.Clear();
            root.Children.Add(empty
                ? Ui.Unavailable(Glyphs.Library, "Your Library Is Empty",
                    "Add the folder where you keep your music. Groovelight reads tags and artwork and keeps the library in sync as files change.",
                    ("Add Music Folder…", () => MainWindow.Current.ChooseLibraryFolder()))
                : scroll);
        });
    }

    private void OnPreferenceChanged(string key)
    {
        if (key == CoverSize.Albums.Key) DispatcherQueue.TryEnqueue(() => grid.TileSize = CoverSize.Albums.Current);
        else if (key == SortKey) DispatcherQueue.TryEnqueue(Reload);
    }

    public override IEnumerable<UIElement> Toolbar()
    {
        if (recentlyAdded) yield break;
        var slider = new Slider { Width = 110, Minimum = CoverSize.Albums.Min, Maximum = CoverSize.Albums.Max, Value = CoverSize.Albums.Current, VerticalAlignment = VerticalAlignment.Center };
        slider.ValueChanged += (_, args) => Model.Preferences.Set(CoverSize.Albums.Key, args.NewValue);
        ToolTipService.SetToolTip(slider, "Cover size");
        yield return Ui.Row(6, Ui.Icon("", 10, "SecondaryIcon"), slider, Ui.Icon("", 13, "SecondaryIcon")).With(row => row.VerticalAlignment = VerticalAlignment.Center);
        var sort = new ComboBox { MinWidth = 150, VerticalAlignment = VerticalAlignment.Center };
        foreach (var (value, name) in new[] { (AlbumSort.Artist, "Artist"), (AlbumSort.Title, "Title"), (AlbumSort.Year, "Year"), (AlbumSort.RecentlyAdded, "Recently Added") })
        {
            sort.Items.Add(new ComboBoxItem { Content = name, Tag = value });
        }
        sort.SelectedIndex = (int)Sort;
        sort.SelectionChanged += (_, _) =>
        {
            if (sort.SelectedItem is ComboBoxItem { Tag: AlbumSort value }) Model.Preferences.Set(SortKey, ToRaw(value));
        };
        ToolTipService.SetToolTip(sort, "Sort");
        yield return sort;
    }

    /// <summary>The Mac's raw values ("artist", "title", "year", "recentlyAdded").</summary>
    private static string ToRaw(AlbumSort sort) => sort switch
    {
        AlbumSort.Title => "title",
        AlbumSort.Year => "year",
        AlbumSort.RecentlyAdded => "recentlyAdded",
        _ => "artist",
    };

    public override void Dispose()
    {
        Model.Preferences.Changed -= OnPreferenceChanged;
        base.Dispose();
    }
}

/// <summary>An album's page: cover, title, artist, background, quality, Play and Shuffle, credits, then its songs.</summary>
public sealed partial class AlbumPage : PageView
{
    private readonly AlbumSummary album;
    private readonly TrackList list = new() { ListStyle = TrackListStyle.Album };
    private readonly StackPanel header = new() { Spacing = 6, VerticalAlignment = VerticalAlignment.Bottom };
    private readonly TextBlock footer = Ui.Text("", "SecondaryText");
    private readonly ArtworkImage cover = new() { IsLarge = true, Radius = 12, Width = 260, Height = 260 };
    private readonly Grid top = new() { ColumnSpacing = 28, RowSpacing = 20 };
    private List<Track> tracks = [];
    private AlbumInfo? info;

    public AlbumPage(AlbumSummary album)
    {
        this.album = album;
        list.AlbumKey = album.AlbumKey;
        cover.Hash = album.ArtworkHash;
        cover.Translation = new System.Numerics.Vector3(0, 0, 32);
        cover.Shadow = new ThemeShadow();
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        top.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        top.Children.Add(cover);
        top.Children.Add(header);
        SizeChanged += (_, args) => Layout(args.NewSize.Width - 64);
        Layout(1000);
        var body = Ui.Column(28, top, list, footer);
        var page = new Grid();
        page.Children.Add(CoverWash.Make(album.ArtworkHash));
        page.Children.Add(Scroll(body, 32));
        Content = page;
        Observations.Add(Model.Database, db => db.TracksOfAlbum(album.AlbumKey), value =>
        {
            tracks = value;
            list.ShowsQuality = AudioSpec.Uniform(value.Select(track => track.AudioSpec).ToList()) is null;
            list.Tracks = value;
            footer.Text = $"{Format.Songs(value.Count)}, {Format.LongDuration(value.Sum(track => track.Duration))}";
            BuildHeader();
        });
        Observations.Add(Model.Database, db => db.AlbumInfo(album.AlbumKey), value =>
        {
            info = value is { } row ? AlbumInfo.Decode(row.Data) : null;
            BuildHeader();
        });
        Model.Metadata.PropertyChanged += OnMetadataChanged;
        _ = Model.Metadata.LoadAlbumInfoAsync(album.AlbumKey);
    }

    public override string Title => album.Title;

    private void OnMetadataChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
    {
        if (args.PropertyName == nameof(MetadataStore.AlbumInfoInFlight)) BuildHeader();
    }

    /// <summary>Side by side when there is room, stacked in narrow windows.</summary>
    private void Layout(double width)
    {
        var sideBySide = width >= 800;
        Grid.SetColumn(header, sideBySide ? 1 : 0);
        Grid.SetRow(header, sideBySide ? 0 : 1);
        Grid.SetColumnSpan(header, sideBySide ? 1 : 2);
    }

    private bool IsLoadingInfo => Model.Metadata.AlbumInfoInFlight.Contains(album.AlbumKey) && (info?.IsEmpty ?? true);

    private void BuildHeader()
    {
        header.Children.Clear();
        header.Children.Add(Ui.Text(album.Title, "PageTitleText").With(text => { text.TextWrapping = TextWrapping.Wrap; text.MaxLines = 2; }));
        header.Children.Add(Ui.Link(album.Artist, album.Artist == "Various Artists" ? null : () => Model.ShowArtist(album.Artist), "BrandText", $"Go to {album.Artist}")
            .With(link => { if (link is HyperlinkButton button && button.Content is TextBlock text) text.FontSize = 22; else if (link is TextBlock plain) plain.FontSize = 22; }));
        header.Children.Add(Ui.Text(Format.Joined(album.Genre, album.Year).ToUpperInvariant(), "CaptionText", 11, FontWeights.SemiBold));
        if (info?.About is { } about) header.Children.Add(new AboutExcerpt(about).Margin(0, 4, 0, 4));
        else if (IsLoadingInfo) header.Children.Add(LoadingNote("Looking up album info…"));
        if (info?.Producers is { Count: > 0 } producers)
            header.Children.Add(Ui.Link($"Produced by {Format.List(producers)}", ShowCredits, "CaptionText", "Show all credits"));
        if (QualitySummary(tracks) is { } quality) header.Children.Add(quality.Margin(0, 2, 0, 0));
        var buttons = Ui.Row(12,
            Ui.Button("Play", () => Model.Play(tracks), Glyphs.Play, "AccentPillButton"),
            Ui.Button("Shuffle", () => Model.Play(tracks, shuffle: true), Glyphs.Shuffle));
        if (info?.Sections.Count > 0) buttons.Children.Add(Ui.Button("Credits", ShowCredits, Glyphs.People, tooltip: "Musicians, songwriters and production"));
        buttons.Children.Add(Ui.MenuButton(() => Menus.Flyout(MoreItems())));
        buttons.Margin = new Thickness(0, 10, 0, 0);
        header.Children.Add(buttons);
    }

    private IEnumerable<MenuFlyoutItemBase> MoreItems()
    {
        foreach (var item in Menus.QueueItems(new SongSource.Album(album.AlbumKey))) yield return item;
        yield return new MenuFlyoutSeparator();
        yield return Menus.Item("Get Info…", () => Model.GetInfo(tracks), Glyphs.Info);
        yield return Menus.Item("Reload Credits & Info", () => _ = Model.Metadata.LoadAlbumInfoAsync(album.AlbumKey, force: true), Glyphs.Refresh);
        yield return Menus.Item("Fix Metadata…", () => Model.Metadata.Review(tracks), Glyphs.Wand);
        yield return Menus.Item("Organize Files…", () => Model.Request(new DialogRequest.Organize(tracks)), Glyphs.Folder);
        yield return Menus.Item("Show in File Explorer", () => AppModel.ShowInExplorer(tracks.Take(1).ToList()), Glyphs.Folder);
    }

    private void ShowCredits() =>
        _ = CreditsView.ShowAsync(XamlRoot, album.Title, album.Artist, album.ArtworkHash, info?.Sections ?? [], info?.ReleaseId, IsLoadingInfo);

    internal static FrameworkElement LoadingNote(string text) =>
        Ui.Row(6, new ProgressRing { IsActive = true, Width = 12, Height = 12 }, Ui.Text(text, "SmallText"));

    /// <summary>The shared spec when every song matches, otherwise "Mixed formats" with the codecs.</summary>
    internal static FrameworkElement? QualitySummary(IReadOnlyList<Track> tracks)
    {
        var specs = tracks.Select(track => track.AudioSpec).ToList();
        if (specs.Count == 0) return null;
        if (AudioSpec.Uniform(specs) is { } spec)
        {
            var row = Ui.Row(6);
            if (QualityBadge.HasBadge(spec.Tier)) row.Children.Add(new QualityBadge(spec.Tier));
            row.Children.Add(Ui.Text(spec.Summary, "CaptionText", 11, FontWeights.Medium));
            ToolTipService.SetToolTip(row, spec.Tier == QualityTier.Standard ? spec.Summary : $"{spec.Tier.DisplayName()} · {spec.Summary}");
            return row;
        }
        var best = specs.Max(item => item.Tier);
        var codecs = specs.Select(item => item.Codec.ShortName()).Distinct().Order();
        var mixed = Ui.Row(6);
        if (QualityBadge.HasBadge(best)) mixed.Children.Add(new QualityBadge(best));
        mixed.Children.Add(Ui.Text($"Mixed formats · {string.Join(", ", codecs)}", "CaptionText", 11, FontWeights.Medium));
        ToolTipService.SetToolTip(mixed, "Tracks differ in format or resolution; each song shows its own details.");
        return mixed;
    }

    public override void Dispose()
    {
        Model.Metadata.PropertyChanged -= OnMetadataChanged;
        base.Dispose();
    }
}

/// <summary>
/// The soft color wash from a cover behind a page's header, like Apple Music: the cover decoded tiny and stretched over
/// the page width (which blurs it), faint, and fading out downwards.
/// </summary>
public static class CoverWash
{
    public static FrameworkElement Make(string? hash) => Make(hash is null ? null : new Uri(AppModel.Current.Artwork.PathFor(hash, ArtworkCache.Size.Small)));

    public static FrameworkElement Make(Uri? image, Windows.Storage.Streams.IRandomAccessStream? stream = null)
    {
        var host = new Grid { IsHitTestVisible = false };
        if (image is null && stream is null) return host;
        if (image is not null && image.IsFile && !File.Exists(image.LocalPath)) return host;
        var visual = Microsoft.UI.Xaml.Hosting.ElementCompositionPreview.GetElementVisual(host);
        var compositor = visual.Compositor;
        var surface = stream is not null
            ? LoadedImageSurface.StartLoadFromStream(stream, new Windows.Foundation.Size(14, 14))
            : LoadedImageSurface.StartLoadFromUri(image!, new Windows.Foundation.Size(14, 14));
        var imageBrush = compositor.CreateSurfaceBrush(surface);
        imageBrush.Stretch = Microsoft.UI.Composition.CompositionStretch.UniformToFill;
        imageBrush.VerticalAlignmentRatio = 0;
        imageBrush.BitmapInterpolationMode = Microsoft.UI.Composition.CompositionBitmapInterpolationMode.Linear;
        var fade = compositor.CreateLinearGradientBrush();
        fade.StartPoint = new System.Numerics.Vector2(0, 0);
        fade.EndPoint = new System.Numerics.Vector2(0, 1);
        fade.ColorStops.Add(compositor.CreateColorGradientStop(0, Microsoft.UI.Colors.White));
        fade.ColorStops.Add(compositor.CreateColorGradientStop(1, Microsoft.UI.Colors.Transparent));
        var mask = compositor.CreateMaskBrush();
        mask.Source = imageBrush;
        mask.Mask = fade;
        var sprite = compositor.CreateSpriteVisual();
        sprite.Brush = mask;
        sprite.Opacity = 0.35f;
        Microsoft.UI.Xaml.Hosting.ElementCompositionPreview.SetElementChildVisual(host, sprite);
        host.SizeChanged += (_, args) =>
        {
            var width = (float)args.NewSize.Width;
            sprite.Size = new System.Numerics.Vector2(width, Math.Min(width, (float)args.NewSize.Height));
        };
        host.Unloaded += (_, _) => surface.Dispose();
        return host;
    }
}

/// <summary>The Wikipedia background in a page's title block: a short excerpt, with MORE opening the full text.</summary>
public sealed partial class AboutExcerpt : StackPanel
{
    public AboutExcerpt(AlbumAbout about)
    {
        MaxWidth = 560;
        HorizontalAlignment = HorizontalAlignment.Left;
        var text = new TextBlock { Text = about.Summary, FontSize = 13, TextWrapping = TextWrapping.Wrap, MaxLines = 3, TextTrimming = TextTrimming.WordEllipsis, Opacity = 0.75, LineHeight = 19 };
        Children.Add(text);
        var more = new HyperlinkButton { Content = Ui.Text("MORE", "BrandText", 11, FontWeights.SemiBold), Style = Ui.Style("LinkTextButton") };
        ToolTipService.SetToolTip(more, "Read the full text");
        more.Click += (_, _) =>
        {
            var full = Ui.Column(10,
                Ui.Text(about.Title, "StrongText"),
                new ScrollViewer { MaxHeight = 360, Content = new TextBlock { Text = about.Summary, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, LineHeight = 20 } },
                Ui.Row(12, new HyperlinkButton { Content = "Read on Wikipedia", NavigateUri = Uri.TryCreate(about.Url, UriKind.Absolute, out var url) ? url : null, Padding = new Thickness(0) },
                       Ui.Text("Text from Wikipedia, CC BY-SA", "SmallText").With(t => t.VerticalAlignment = VerticalAlignment.Center)));
            full.Width = 460;
            new Flyout { Content = full, Placement = FlyoutPlacementMode.Bottom }.ShowAt(more);
        };
        Children.Add(more);
    }
}

/// <summary>Credits in a dialog (the Mac's CreditsSheet): the album's or one song's, each name opening their page.</summary>
public static class CreditsView
{
    public static async Task ShowAsync(XamlRoot root, string title, string subtitle, string? artworkHash, IReadOnlyList<CreditSection> sections,
                                       string? releaseId, bool isLoading)
    {
        var dialog = new ContentDialog { XamlRoot = root, CloseButtonText = "Done", DefaultButton = ContentDialogButton.Close };
        dialog.Resources["ContentDialogMaxWidth"] = 760.0;
        var head = Ui.Grid("auto,*,auto");
        head.ColumnSpacing = 12;
        head.Children.Add(new ArtworkImage { Hash = artworkHash, Width = 52, Height = 52, Radius = 6 });
        head.Children.Add(Ui.Column(2, Ui.Text(title, "StrongText"), Ui.Text(subtitle, "SecondaryText")).With(c => c.VerticalAlignment = VerticalAlignment.Center).At(1));
        head.Children.Add(Ui.Text("Credits", "SectionTitleText").With(text => { text.Opacity = 0.6; text.VerticalAlignment = VerticalAlignment.Center; }).At(2));
        FrameworkElement body;
        if (sections.Count > 0) body = Grid(sections, person => { dialog.Hide(); AppModel.Current.ShowPerson(person); });
        else if (isLoading) body = AlbumPage.LoadingNote("Looking up credits…");
        else body = Ui.Unavailable(Glyphs.People, "No Credits Found", "MusicBrainz has no credits for this, or the album could not be matched.");
        var content = Ui.Column(16, head, Ui.Separator(), new ScrollViewer { Content = body, MinHeight = 240, MaxHeight = 520 });
        if (releaseId is not null)
            content.Children.Add(new HyperlinkButton { Content = "Credits from MusicBrainz", NavigateUri = new Uri($"https://musicbrainz.org/release/{releaseId}"), Padding = new Thickness(0) });
        content.Width = 700;
        dialog.Content = content;
        await ContentDialogs.ShowAsync(dialog);
    }

    /// <summary>Credit sections side by side when there is room: title, then each name (opening their page) over its roles.</summary>
    public static FrameworkElement Grid(IReadOnlyList<CreditSection> sections, Action<CreditPerson> onSelect)
    {
        var panel = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, ItemWidth = 230, Margin = new Thickness(0, 0, 0, 8) };
        foreach (var section in sections)
        {
            var column = Ui.Column(10, Ui.Text(section.Kind.Title().ToUpperInvariant(), "CaptionText", 11, FontWeights.SemiBold).With(t => t.CharacterSpacing = 50));
            foreach (var credit in section.Credits)
            {
                var person = new CreditPerson(credit.Name, credit.ArtistId);
                column.Children.Add(Ui.Column(1,
                    Ui.Link(credit.Name, () => onSelect(person), "BodyText", $"Albums and songs with {credit.Name} in your library"),
                    Ui.Text(string.Join(", ", credit.Roles), "CaptionText").With(t => { t.TextWrapping = TextWrapping.Wrap; t.TextTrimming = TextTrimming.None; })));
            }
            column.Margin = new Thickness(0, 0, 24, 24);
            panel.Children.Add(column);
        }
        return panel;
    }
}
