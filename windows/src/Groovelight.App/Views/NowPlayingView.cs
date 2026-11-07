using System.ComponentModel;
using System.Numerics;
using Groovelight.Audio;
using Groovelight.Controls;
using Groovelight.Core.Library;
using Groovelight.Model;
using Groovelight.Support;
using Microsoft.UI;
using Microsoft.UI.Composition;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;

namespace Groovelight.Views;

/// <summary>
/// The full-window player (the Mac's NowPlayingView): the cover's colors drifting behind, the big cover (or a
/// visualizer, or a vintage player taking the whole window), the song, the transport, and lyrics or Up Next beside.
/// </summary>
public sealed partial class NowPlayingView : UserControl, IDisposable
{
    private static AppModel Model => AppModel.Current;
    private PlaybackController Player => Model.Player;
    private static readonly SolidColorBrush White = new(Colors.White);
    private static readonly SolidColorBrush Dim = new(Windows.UI.Color.FromArgb(178, 255, 255, 255));
    private static readonly SolidColorBrush Faint = new(Windows.UI.Color.FromArgb(150, 255, 255, 255));

    public const string SkinKey = "nowPlaying.skin";
    /// <summary>A vintage player in the cover's place (filled in by the skins): the skin's id, or null for the cover.</summary>
    public static Func<string?, FrameworkElement?>? DeckFactory { get; set; }
    /// <summary>The skin menu's items (filled in by the skins).</summary>
    public static Func<IEnumerable<MenuFlyoutItemBase>>? SkinMenu { get; set; }
    /// <summary>A visualizer in the cover's place (filled in by the visualizers).</summary>
    public static Func<FrameworkElement>? VisualizerFactory { get; set; }
    public static Func<FrameworkElement>? VisualizerStylePicker { get; set; }

    private readonly ArtworkBackdrop backdrop = new();
    private readonly Grid root = new();
    private readonly Grid layout = new() { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel column = new() { HorizontalAlignment = HorizontalAlignment.Center };
    private readonly Grid coverHost = new();
    private readonly ArtworkImage cover = new() { IsLarge = true, Radius = 14 };
    private readonly TextBlock title = new() { Foreground = White, FontWeight = FontWeights.Bold, TextTrimming = TextTrimming.CharacterEllipsis, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly StackPanel subtitle = new() { Orientation = Orientation.Horizontal, Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly ContentControl quality = new() { HorizontalAlignment = HorizontalAlignment.Center };
    private readonly Slider scrubber = new() { Minimum = 0, IsThumbToolTipEnabled = false };
    private readonly TextBlock elapsed = new() { Foreground = Faint }, remaining = new() { Foreground = Faint, HorizontalAlignment = HorizontalAlignment.Right };
    private readonly Button shuffle, previous, playPause, next, repeat, love, upNext;
    private readonly Slider volume = new() { Minimum = 0, Maximum = 100 };
    private readonly ContentControl side = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly StackPanel topButtons = new() { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 12, 16, 0) };
    private readonly ContentControl deckHost = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private Track? track;
    private bool showVisualizer;
    private bool updatingScrubber, updatingVolume;
    private double? scrubValue;
    private double scale = 1;
    private string? shownSkin = "\u0001";

    public NowPlayingView()
    {
        RequestedTheme = ElementTheme.Dark;
        root.Children.Add(new Border { Background = new SolidColorBrush(Colors.Black) });
        root.Children.Add(backdrop);
        coverHost.Children.Add(cover);
        cover.Translation = new Vector3(0, 0, 48);
        cover.Shadow = new ThemeShadow();
        title.MaxLines = 1;
        shuffle = ModeButton(Glyphs.Shuffle, () => Player.SetShuffle(!Player.IsShuffled));
        previous = TransportButton(Glyphs.Previous, Player.Previous, "Previous");
        playPause = TransportButton(Glyphs.Play, Player.TogglePlayPause, "Play");
        next = TransportButton(Glyphs.Next, Player.Next, "Next");
        repeat = ModeButton(Glyphs.Repeat, Model.CycleRepeat);
        love = ModeButton(Glyphs.Heart, () => { if (track is not null) Model.ToggleLoved(track); });
        upNext = ModeButton(Glyphs.Queue, Model.ToggleUpNext);
        scrubber.ValueChanged += (_, args) =>
        {
            if (updatingScrubber) return;
            scrubValue = args.NewValue;
            UpdateTimes();
        };
        scrubber.AddHandler(PointerReleasedEvent, new Microsoft.UI.Xaml.Input.PointerEventHandler((_, _) => CommitScrub()), true);
        scrubber.AddHandler(PointerCaptureLostEvent, new Microsoft.UI.Xaml.Input.PointerEventHandler((_, _) => CommitScrub()), true);
        volume.ValueChanged += (_, args) => { if (!updatingVolume) Player.Volume = (float)(args.NewValue / 100); };
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        layout.Children.Add(column);
        layout.Children.Add(side.At(1));
        root.Children.Add(layout);
        root.Children.Add(deckHost);
        root.Children.Add(topButtons);
        Content = root;
        SizeChanged += (_, _) => Relayout();
        Loaded += (_, _) =>
        {
            Player.PropertyChanged += OnPlayerChanged;
            Model.PropertyChanged += OnModelChanged;
            Model.Database.Changed += OnDatabaseChanged;
            Model.Preferences.Changed += OnPreferenceChanged;
            Update();
            _ = LoadTrackAsync();
        };
        Unloaded += (_, _) => Dispose();
    }

    public void Dispose()
    {
        Player.PropertyChanged -= OnPlayerChanged;
        Model.PropertyChanged -= OnModelChanged;
        Model.Database.Changed -= OnDatabaseChanged;
        Model.Preferences.Changed -= OnPreferenceChanged;
        backdrop.Stop();
    }

    private void CommitScrub()
    {
        if (scrubValue is not { } value) return;
        Player.Seek(value);
        scrubValue = null;
    }

    private Button TransportButton(string glyph, Action action, string tooltip)
    {
        var button = new Button { Content = new FontIcon { Glyph = glyph, Foreground = White }, Background = Images.Transparent, BorderThickness = new Thickness(0), Padding = new Thickness(8) };
        ToolTipService.SetToolTip(button, tooltip);
        button.Click += (_, _) => action();
        return button;
    }

    /// <summary>Shuffle, Repeat, love and Up Next: bright on a light circle while on, dimmed while off.</summary>
    private Button ModeButton(string glyph, Action action)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, Foreground = White }, Background = Images.Transparent, BorderThickness = new Thickness(0),
            Padding = new Thickness(0), CornerRadius = new CornerRadius(20),
        };
        button.Click += (_, _) => action();
        return button;
    }

    private static void SetMode(Button button, bool on, string? glyph = null, Brush? color = null)
    {
        var icon = (FontIcon)button.Content;
        if (glyph is not null) icon.Glyph = glyph;
        icon.Foreground = color ?? (on ? White : Faint);
        button.Background = on && color is null ? new SolidColorBrush(Windows.UI.Color.FromArgb(51, 255, 255, 255)) : Images.Transparent;
    }

    private void OnPlayerChanged(object? sender, PropertyChangedEventArgs args)
    {
        switch (args.PropertyName)
        {
            case nameof(PlaybackController.CurrentTime):
            case nameof(PlaybackController.Duration):
                UpdateTimes();
                break;
            case nameof(PlaybackController.Current):
                _ = LoadTrackAsync();
                Update();
                break;
            default:
                Update();
                break;
        }
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName is nameof(AppModel.IsShowingLyrics) or nameof(AppModel.IsShowingNowPlayingQueue)) Update();
    }

    private void OnPreferenceChanged(string key)
    {
        if (key == SkinKey) DispatcherQueue.TryEnqueue(Update);
    }

    private void OnDatabaseChanged() => DispatcherQueue.TryEnqueue(() => _ = LoadTrackAsync());

    private async Task LoadTrackAsync()
    {
        var id = Player.Current?.Id;
        var loaded = id is { } trackId ? await Task.Run(() => Model.Database.Read(db => db.FetchTrack(trackId))) : null;
        if (Player.Current?.Id != id) return;
        track = loaded;
        UpdateSong();
    }

    private string? Skin => Model.Preferences.String(SkinKey) is { Length: > 0 } skin && skin != "cover" ? skin : null;

    private void Update()
    {
        var skin = Skin;
        var deck = skin is not null ? DeckFactory : null;
        if (skin != shownSkin)
        {
            shownSkin = skin;
            deckHost.Content = deck?.Invoke(skin);
        }
        var isDeck = deckHost.Content is not null;
        layout.Visibility = isDeck ? Visibility.Collapsed : Visibility.Visible;
        backdrop.Visibility = isDeck ? Visibility.Collapsed : Visibility.Visible;
        backdrop.Hash = Player.Current?.ArtworkHash;
        // Over a vintage player, the lyrics and Up Next take the player's place behind smoked glass (the deck shows them).
        deckHost.Visibility = isDeck ? Visibility.Visible : Visibility.Collapsed;
        var playing = Player.State == PlaybackState.Playing;
        ((FontIcon)playPause.Content).Glyph = playing ? Glyphs.Pause : Glyphs.Play;
        ToolTipService.SetToolTip(playPause, playing ? "Pause" : "Play");
        SetMode(shuffle, Player.IsShuffled);
        SetMode(repeat, Player.RepeatMode != RepeatMode.Off, Player.RepeatMode == RepeatMode.One ? Glyphs.RepeatOne : Glyphs.Repeat);
        SetMode(upNext, Model.IsShowingNowPlayingQueue);
        ToolTipService.SetToolTip(shuffle, "Shuffle" + Model.Shortcuts.Hint(ShortcutAction.Shuffle));
        ToolTipService.SetToolTip(repeat, "Repeat" + Model.Shortcuts.Hint(ShortcutAction.CycleRepeat));
        ToolTipService.SetToolTip(upNext, "Up Next" + Model.Shortcuts.Hint(ShortcutAction.UpNext));
        updatingVolume = true;
        volume.Value = Player.Volume * 100;
        updatingVolume = false;
        side.Content = isDeck ? null : Model.IsShowingLyrics ? side.Content as LyricsView ?? new LyricsView(24 * scale, White)
            : Model.IsShowingNowPlayingQueue ? side.Content as QueuePanel ?? new QueuePanel(White) : null;
        side.Visibility = side.Content is null ? Visibility.Collapsed : Visibility.Visible;
        BuildTopButtons(isDeck, skin);
        coverHost.Children.Clear();
        coverHost.Children.Add(showVisualizer && VisualizerFactory is { } visualizer ? visualizer() : cover);
        UpdateSong();
        UpdateTimes();
        Relayout();
    }

    private void UpdateSong()
    {
        var item = Player.Current;
        cover.Hash = item?.ArtworkHash;
        title.Text = item?.Title ?? "Not Playing";
        subtitle.Children.Clear();
        var current = track?.Id == item?.Id ? track : null;
        if (item is not null)
        {
            // Artist and album open their pages (closing Now Playing).
            subtitle.Children.Add(Link(item.Artist, current is not null && Menus.ArtistPageName(current) is { } artist ? () => Close(() => Model.ShowArtist(artist)) : null));
            subtitle.Children.Add(new TextBlock { Text = "—", Foreground = Dim, FontSize = 16 * scale });
            subtitle.Children.Add(Link(item.Album, current is not null ? () => Close(() => Model.ShowAlbum(current.AlbumKey)) : null));
        }
        quality.Content = current is not null ? AudioQualityFlyout.Button(current) : null;
        if (quality.Content is FrameworkElement button)
        {
            foreach (var text in FindText(button)) text.Foreground = Faint;
        }
        var loved = current?.IsLoved == true;
        SetMode(love, false, loved ? Glyphs.HeartFilled : Glyphs.Heart, loved ? Ui.Brush("LoveBrush") : Dim);
        love.IsEnabled = current is not null;
        ToolTipService.SetToolTip(love, (loved ? "Unlove" : "Love") + Model.Shortcuts.Hint(ShortcutAction.Love));
    }

    private static IEnumerable<TextBlock> FindText(DependencyObject element)
    {
        if (element is TextBlock text) yield return text;
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(element); index++)
            foreach (var child in FindText(VisualTreeHelper.GetChild(element, index))) yield return child;
        if (element is ContentControl { Content: DependencyObject content }) foreach (var child in FindText(content)) yield return child;
        if (element is Panel panel) foreach (var child in panel.Children) foreach (var item in FindText(child)) yield return item;
    }

    private FrameworkElement Link(string text, Action? action)
    {
        var block = new TextBlock { Text = text, Foreground = Dim, FontSize = 16 * scale, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 300 * scale };
        if (action is null) return block;
        var button = new HyperlinkButton { Content = block, Padding = new Thickness(0), Foreground = Dim };
        ToolTipService.SetToolTip(button, $"Go to {text}");
        button.Click += (_, _) => action();
        return button;
    }

    private static void Close(Action then)
    {
        Model.IsShowingNowPlaying = false;
        then();
    }

    private void UpdateTimes()
    {
        var duration = Math.Max(Player.Duration, 1);
        var time = scrubValue ?? Player.CurrentTime;
        if (scrubValue is null)
        {
            updatingScrubber = true;
            scrubber.Maximum = duration;
            scrubber.Value = Math.Clamp(Player.CurrentTime, 0, duration);
            updatingScrubber = false;
        }
        elapsed.Text = Format.Duration(time);
        remaining.Text = Format.Remaining(Player.Duration - time);
    }

    private void BuildTopButtons(bool isDeck, string? skin)
    {
        topButtons.Children.Clear();
        Button Round(string glyph, string tooltip, Action action)
        {
            var button = new Button
            {
                Content = new FontIcon { Glyph = glyph, FontSize = 14, Foreground = White }, Width = 40, Height = 40, CornerRadius = new CornerRadius(20), Padding = new Thickness(0),
                Background = new SolidColorBrush(Windows.UI.Color.FromArgb(isDeck ? (byte)140 : (byte)50, isDeck ? (byte)20 : (byte)255, isDeck ? (byte)20 : (byte)255, isDeck ? (byte)20 : (byte)255)),
                BorderThickness = new Thickness(0),
            };
            ToolTipService.SetToolTip(button, tooltip);
            button.Click += (_, _) => action();
            return button;
        }
        if (showVisualizer && !isDeck && VisualizerStylePicker is { } picker) topButtons.Children.Add(picker());
        if (SkinMenu is { } skins)
        {
            var menu = Round("", "Cover, Vinyl, Cassette, CD or PC Player", () => { });
            var flyout = new MenuFlyout();
            // Built as it opens: the cassettes may have changed since.
            flyout.Opening += (_, _) =>
            {
                flyout.Items.Clear();
                foreach (var item in skins()) flyout.Items.Add(item);
            };
            menu.Flyout = flyout;
            topButtons.Children.Add(menu);
        }
        if (!isDeck && VisualizerFactory is not null)
            topButtons.Children.Add(Round(Glyphs.Visualizer, "Visualizer" + Model.Shortcuts.Hint(ShortcutAction.Visualizer), () => { showVisualizer = !showVisualizer; Update(); }));
        topButtons.Children.Add(Round(Glyphs.Lyrics, "Lyrics" + Model.Shortcuts.Hint(ShortcutAction.Lyrics), () =>
        {
            Model.IsShowingLyrics = !Model.IsShowingLyrics;
            if (Model.IsShowingLyrics) Model.IsShowingNowPlayingQueue = false;
        }));
        // Over a player, Up Next in its place, like the lyrics (the PC Player's playlist shows the queue).
        if (isDeck && skin != "pcPlayer") topButtons.Children.Add(Round(Glyphs.Queue, "Up Next" + Model.Shortcuts.Hint(ShortcutAction.UpNext), Model.ToggleUpNext));
        topButtons.Children.Add(Round(Glyphs.ChevronDown, "Close (Esc)", () => Model.IsShowingNowPlaying = false));
    }

    /// <summary>Grows with big windows (1 at 1100 x 760, up to 1.9x), so nothing sits small on a large display.</summary>
    private void Relayout()
    {
        var width = ActualWidth;
        var height = ActualHeight;
        if (width <= 0 || height <= 0) return;
        var newScale = Math.Min(Math.Max(Math.Min(width / 1100, height / 760), 1), 1.9);
        var rebuild = Math.Abs(newScale - scale) > 0.01;
        scale = newScale;
        var showsSide = side.Content is not null;
        var coverSide = Math.Max(200, Math.Min(460 * scale, Math.Min(height - 420 * scale, width - (showsSide ? 480 * scale : 80))));
        coverHost.Width = coverHost.Height = coverSide;
        var columnWidth = Math.Max(coverSide, 360 * scale);
        title.FontSize = 22 * scale;
        foreach (var text in subtitle.Children.OfType<TextBlock>()) text.FontSize = 16 * scale;
        elapsed.FontSize = remaining.FontSize = 11 * scale;
        foreach (var button in new[] { previous, next }) ((FontIcon)button.Content).FontSize = 28 * scale;
        ((FontIcon)playPause.Content).FontSize = 40 * scale;
        foreach (var button in new[] { shuffle, repeat, love, upNext })
        {
            ((FontIcon)button.Content).FontSize = 17 * scale;
            button.Width = button.Height = 34 * scale;
        }
        column.Width = columnWidth;
        side.Width = 380 * scale;
        side.Height = coverSide + 190 * scale;
        side.Margin = new Thickness(48 * scale, 0, 0, 0);
        layout.Margin = new Thickness(40, 50, 40, 24);
        if (rebuild || column.Children.Count == 0) BuildColumn();
        if (side.Content is LyricsView lyrics && rebuild) side.Content = new LyricsView(24 * scale, White);
    }

    private void BuildColumn()
    {
        column.Children.Clear();
        column.Spacing = 24 * scale;
        column.Children.Add(coverHost);
        var text = new StackPanel { Spacing = 4 };
        text.Children.Add(title);
        text.Children.Add(subtitle);
        quality.Margin = new Thickness(0, 4, 0, 0);
        text.Children.Add(quality);
        column.Children.Add(text);
        // The transport: scrubber with times, the buttons, the volume.
        var times = Ui.Grid("*,*");
        times.Children.Add(elapsed);
        times.Children.Add(remaining.At(1));
        var transport = Ui.Row(36 * scale, shuffle, previous, playPause, next, repeat);
        transport.HorizontalAlignment = HorizontalAlignment.Center;
        foreach (var child in transport.Children.OfType<FrameworkElement>()) child.VerticalAlignment = VerticalAlignment.Center;
        var volumeRow = Ui.Grid("auto,*,auto");
        volumeRow.ColumnSpacing = 8;
        volumeRow.Children.Add(new FontIcon { Glyph = Glyphs.Volume1, FontSize = 11, Foreground = Dim });
        volumeRow.Children.Add(volume.At(1));
        volumeRow.Children.Add(new FontIcon { Glyph = Glyphs.Volume3, FontSize = 11, Foreground = Dim }.At(2));
        var controls = new StackPanel { Spacing = 16 * scale };
        controls.Children.Add(new StackPanel { Spacing = 0, Children = { scrubber, times } });
        controls.Children.Add(transport);
        controls.Children.Add(volumeRow);
        column.Children.Add(controls);
        // Love and Up Next under the controls, as on the iPhone.
        var buttons = Ui.Grid("auto,*,auto");
        buttons.Children.Add(love);
        buttons.Children.Add(upNext.At(2));
        column.Children.Add(buttons);
    }
}

/// <summary>
/// The cover's colors slowly drifting behind Now Playing, like Apple Music's animated backgrounds: two copies of the
/// cover, decoded tiny and stretched (which blurs them), turning and moving on the composition layer.
/// </summary>
public sealed partial class ArtworkBackdrop : Grid
{
    private readonly Compositor compositor;
    private readonly ContainerVisual container;
    private readonly CompositionPropertySet center;
    private SpriteVisual? first, second;
    private LoadedImageSurface? surface;
    private string? hash;

    public ArtworkBackdrop()
    {
        IsHitTestVisible = false;
        var visual = ElementCompositionPreview.GetElementVisual(this);
        compositor = visual.Compositor;
        container = compositor.CreateContainerVisual();
        center = compositor.CreatePropertySet();
        center.InsertVector3("Center", Vector3.Zero);
        ElementCompositionPreview.SetElementChildVisual(this, container);
        SizeChanged += (_, _) => Layout();
        Children.Add(new Border { Background = new SolidColorBrush(Windows.UI.Color.FromArgb(89, 0, 0, 0)) });
    }

    public string? Hash
    {
        get => hash;
        set
        {
            if (value == hash) return;
            hash = value;
            Load();
        }
    }

    private void Load()
    {
        container.Children.RemoveAll();
        surface?.Dispose();
        surface = null;
        if (hash is null) return;
        var path = AppModel.Current.Artwork.PathFor(hash, Core.Library.ArtworkCache.Size.Small);
        if (!File.Exists(path)) return;
        surface = LoadedImageSurface.StartLoadFromUri(new Uri(path), new Windows.Foundation.Size(10, 10));
        first = Sprite(0.9f);
        second = Sprite(0.6f);
        container.Children.InsertAtTop(first);
        container.Children.InsertAtTop(second);
        Layout();
        Animate(first, 3.2f, 4, 7, 9, 120, 80);
        Animate(second, 2.8f, -3, 6, 8, 160, 100);
    }

    private SpriteVisual Sprite(float opacity)
    {
        var brush = compositor.CreateSurfaceBrush(surface);
        brush.Stretch = CompositionStretch.UniformToFill;
        brush.BitmapInterpolationMode = CompositionBitmapInterpolationMode.Linear;
        var sprite = compositor.CreateSpriteVisual();
        sprite.Brush = brush;
        sprite.Opacity = opacity;
        return sprite;
    }

    private void Layout()
    {
        var size = new Vector2((float)ActualWidth, (float)ActualHeight);
        var side = Math.Max(size.X, size.Y);
        center.InsertVector3("Center", new Vector3(size.X / 2, size.Y / 2, 0));
        foreach (var sprite in new[] { first, second })
        {
            if (sprite is null) continue;
            sprite.Size = new Vector2(side, side);
            sprite.AnchorPoint = new Vector2(0.5f, 0.5f);
            sprite.CenterPoint = new Vector3(side / 2, side / 2, 0);
        }
    }

    /// <summary>Turns slowly and drifts on an ellipse, as the Mac's TimelineView does.</summary>
    private void Animate(SpriteVisual sprite, float scale, float degreesPerSecond, double xPeriod, double yPeriod, float xAmplitude, float yAmplitude)
    {
        sprite.Scale = new Vector3(scale, scale, 1);
        var rotation = compositor.CreateScalarKeyFrameAnimation();
        rotation.InsertKeyFrame(0, 0);
        rotation.InsertKeyFrame(1, 360 * Math.Sign(degreesPerSecond), compositor.CreateLinearEasingFunction());
        rotation.Duration = TimeSpan.FromSeconds(360 / Math.Abs(degreesPerSecond));
        rotation.IterationBehavior = AnimationIterationBehavior.Forever;
        sprite.StartAnimation("RotationAngleInDegrees", rotation);
        var drift = compositor.CreateVector3KeyFrameAnimation();
        const int steps = 16;
        var period = Math.Max(xPeriod, yPeriod) * 2 * Math.PI;
        for (var step = 0; step <= steps; step++)
        {
            var t = period * step / steps;
            drift.InsertKeyFrame((float)step / steps, new Vector3((float)(Math.Sin(t / xPeriod) * xAmplitude), (float)(Math.Cos(t / yPeriod) * yAmplitude), 0));
        }
        drift.Duration = TimeSpan.FromSeconds(period);
        drift.IterationBehavior = AnimationIterationBehavior.Forever;
        sprite.Properties.InsertVector3("Drift", Vector3.Zero);
        sprite.Properties.StartAnimation("Drift", drift);
        var offset = compositor.CreateExpressionAnimation("host.Center + sprite.Drift");
        offset.SetReferenceParameter("sprite", sprite.Properties);
        offset.SetReferenceParameter("host", center);
        sprite.StartAnimation("Offset", offset);
    }

    public void Stop()
    {
        container.Children.RemoveAll();
        surface?.Dispose();
        surface = null;
    }
}
