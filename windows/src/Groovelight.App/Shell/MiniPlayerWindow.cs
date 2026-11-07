using System.ComponentModel;
using Groovelight.Audio;
using Groovelight.Controls;
using Groovelight.Core.Library;
using Groovelight.Model;
using Groovelight.Support;
using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Groovelight.Shell;

/// <summary>
/// The mini player: a small window that stays on top (Windows' compact overlay), with the player bar's controls, like the
/// Mac's menu bar player. Also what the notification area icon opens.
/// </summary>
public sealed class MiniPlayerWindow : Window
{
    private static MiniPlayerWindow? shown;
    private static AppModel Model => AppModel.Current;
    private PlaybackController Player => Model.Player;
    private readonly ArtworkImage artwork = new() { Width = 60, Height = 60, Radius = 8 };
    private readonly TextBlock title = new() { FontSize = 13, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 150 };
    private readonly TextBlock artist = new() { FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly TextBlock album = new() { FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly StackPanel titleRow = new() { Orientation = Orientation.Horizontal, Spacing = 6 };
    private readonly Slider scrubber = new() { Minimum = 0, IsThumbToolTipEnabled = false };
    private readonly TextBlock elapsed = new() { FontSize = 10 }, remaining = new() { FontSize = 10, HorizontalAlignment = HorizontalAlignment.Right };
    private readonly Slider volume = new() { Minimum = 0, Maximum = 100, Width = 110 };
    private readonly Button play, shuffle, repeat, love, lyrics, upNext;
    private Track? track;
    private bool updating;
    private double? scrubValue;

    /// <summary>Opens the mini player, or brings it forward; <paramref name="near"/>: a screen point to open by (the tray icon).</summary>
    public static void Show(Windows.Graphics.PointInt32? near = null)
    {
        shown ??= new MiniPlayerWindow();
        shown.Activate();
        if (near is { } point) shown.MoveNear(point);
    }

    public static void Toggle(Windows.Graphics.PointInt32? near = null)
    {
        if (shown is not null && shown.AppWindow.IsVisible) shown.Close();
        else Show(near);
    }

    private MiniPlayerWindow()
    {
        Title = "Groovelight Mini Player";
        SystemBackdrop = new DesktopAcrylicBackdrop();
        ExtendsContentIntoTitleBar = true;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Groovelight.ico"));
        AppWindow.SetPresenter(AppWindowPresenterKind.CompactOverlay);
        var scale = MainWindow.Current.RootXamlRoot?.RasterizationScale ?? 1;
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(340 * scale), (int)(250 * scale)));
        play = Ui.IconButton(Glyphs.Play, "Play", Player.TogglePlayPause, 20);
        shuffle = Ui.IconButton(Glyphs.Shuffle, "Shuffle", () => Player.SetShuffle(!Player.IsShuffled), 14);
        repeat = Ui.IconButton(Glyphs.Repeat, "Repeat", Model.CycleRepeat, 14);
        love = Ui.IconButton(Glyphs.Heart, "Love", () => { if (track is not null) Model.ToggleLoved(track); }, 14);
        // Lyrics open full size in Now Playing; a second click closes it. Up Next toggles the side pane.
        lyrics = Ui.IconButton(Glyphs.Lyrics, "Lyrics", () =>
        {
            if (Model.IsShowingNowPlaying && Model.IsShowingLyrics) Model.IsShowingNowPlaying = false;
            else
            {
                MainWindow.Current.BringToFront();
                Model.IsShowingLyrics = true;
                Model.IsShowingNowPlaying = true;
            }
        }, 14);
        upNext = Ui.IconButton(Glyphs.Queue, "Up Next", () =>
        {
            if (!Model.IsShowingQueue) MainWindow.Current.BringToFront();
            Model.IsShowingQueue = !Model.IsShowingQueue;
        }, 14);
        var visualizer = Ui.IconButton(Glyphs.Visualizer, "Visualizer", MainWindow.Current.ShowVisualizer, 14);

        var cover = new Button { Content = artwork, Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = Images.Transparent };
        ToolTipService.SetToolTip(cover, "Show Now Playing");
        cover.Click += (_, _) =>
        {
            MainWindow.Current.BringToFront();
            Model.IsShowingNowPlaying = true;
        };
        titleRow.Children.Add(title);
        foreach (var text in new[] { artist, album, elapsed, remaining }) text.Foreground = Ui.Brush("TextFillColorSecondaryBrush");
        album.Opacity = 0.8;
        var header = Ui.Grid("auto,*,auto");
        header.ColumnSpacing = 12;
        header.Children.Add(cover);
        header.Children.Add(Ui.Column(2, titleRow, artist, album).With(c => c.VerticalAlignment = VerticalAlignment.Center).At(1));
        header.Children.Add(love.With(b => b.VerticalAlignment = VerticalAlignment.Center).At(2));
        var times = Ui.Grid("*,*");
        times.Children.Add(elapsed);
        times.Children.Add(remaining.At(1));
        var transport = Ui.Row(18, shuffle, Ui.IconButton(Glyphs.Previous, "Previous", Player.Previous, 16), play, Ui.IconButton(Glyphs.Next, "Next", Player.Next, 16), repeat);
        transport.HorizontalAlignment = HorizontalAlignment.Center;
        var tools = Ui.Grid("auto,*,auto");
        tools.Children.Add(Ui.Row(4, Ui.Icon(Glyphs.Volume1, 12, "SecondaryIcon").With(i => i.VerticalAlignment = VerticalAlignment.Center), volume));
        tools.Children.Add(Ui.Row(6, lyrics, upNext, visualizer).At(2));
        var panel = Ui.Column(10, header, new StackPanel { Children = { scrubber, times } }, transport, tools);
        panel.Padding = new Thickness(16, 36, 16, 12);
        Content = new Grid { Children = { panel } };

        scrubber.ValueChanged += (_, args) =>
        {
            if (updating) return;
            scrubValue = args.NewValue;
        };
        scrubber.AddHandler(UIElement.PointerReleasedEvent, new Microsoft.UI.Xaml.Input.PointerEventHandler((_, _) =>
        {
            if (scrubValue is { } value) Player.Seek(value);
            scrubValue = null;
        }), true);
        volume.ValueChanged += (_, args) => { if (!updating) Player.Volume = (float)(args.NewValue / 100); };
        Player.PropertyChanged += OnPlayerChanged;
        Model.PropertyChanged += OnModelChanged;
        Model.Database.Changed += OnDatabaseChanged;
        Closed += (_, _) =>
        {
            Player.PropertyChanged -= OnPlayerChanged;
            Model.PropertyChanged -= OnModelChanged;
            Model.Database.Changed -= OnDatabaseChanged;
            shown = null;
        };
        Update();
        _ = LoadTrackAsync();
        if (Environment.GetCommandLineArgs().Contains("--debug-mini")) Support.DebugSnapshot.Target = this;
    }

    private void MoveNear(Windows.Graphics.PointInt32 point)
    {
        var area = DisplayArea.GetFromPoint(point, DisplayAreaFallback.Primary).WorkArea;
        var size = AppWindow.Size;
        var x = Math.Clamp(point.X - size.Width / 2, area.X, area.X + area.Width - size.Width);
        var y = Math.Clamp(point.Y - size.Height - 12, area.Y, area.Y + area.Height - size.Height);
        AppWindow.Move(new Windows.Graphics.PointInt32(x, y));
    }

    private void OnPlayerChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName == nameof(PlaybackController.Current)) _ = LoadTrackAsync();
        Update();
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs args) => Update();

    private void OnDatabaseChanged() => DispatcherQueue.TryEnqueue(() => _ = LoadTrackAsync());

    private async Task LoadTrackAsync()
    {
        var id = Player.Current?.Id;
        var loaded = id is { } trackId ? await Task.Run(() => Model.Database.Read(db => db.FetchTrack(trackId))) : null;
        if (Player.Current?.Id != id) return;
        track = loaded;
        Update();
    }

    private static void Tint(Button button, bool on, Brush? color = null)
    {
        var icon = (FontIcon)button.Content;
        if (on) icon.Foreground = color ?? Ui.Brush("BrandBrush");
        else icon.ClearValue(FontIcon.ForegroundProperty);
    }

    private void Update()
    {
        var item = Player.Current;
        updating = true;
        artwork.Hash = item?.ArtworkHash;
        title.Text = item?.Title ?? "Not Playing";
        artist.Text = item?.Artist ?? "";
        album.Text = item?.Album ?? "";
        while (titleRow.Children.Count > 1) titleRow.Children.RemoveAt(1);
        if (track is not null && track.Id == item?.Id && QualityBadge.HasBadge(track.AudioSpec.Tier))
            titleRow.Children.Add(AudioQualityFlyout.Button(track, showsText: false, isMini: true));
        var time = scrubValue ?? Player.CurrentTime;
        scrubber.Maximum = Math.Max(Player.Duration, 1);
        if (scrubValue is null) scrubber.Value = Math.Clamp(Player.CurrentTime, 0, scrubber.Maximum);
        scrubber.IsEnabled = item is not null;
        elapsed.Text = item is null ? "--:--" : Format.Duration(time);
        remaining.Text = item is null ? "--:--" : Format.Remaining(Player.Duration - time);
        volume.Value = Player.Volume * 100;
        updating = false;
        var playing = Player.State == PlaybackState.Playing;
        ((FontIcon)play.Content).Glyph = playing ? Glyphs.Pause : Glyphs.Play;
        Tint(shuffle, Player.IsShuffled);
        ((FontIcon)repeat.Content).Glyph = Player.RepeatMode == RepeatMode.One ? Glyphs.RepeatOne : Glyphs.Repeat;
        Tint(repeat, Player.RepeatMode != RepeatMode.Off);
        var loved = track?.IsLoved == true && track.Id == item?.Id;
        ((FontIcon)love.Content).Glyph = loved ? Glyphs.HeartFilled : Glyphs.Heart;
        Tint(love, loved, Ui.Brush("LoveBrush"));
        love.IsEnabled = track is not null && track.Id == item?.Id;
        Tint(lyrics, Model.IsShowingNowPlaying && Model.IsShowingLyrics);
        Tint(upNext, Model.IsShowingQueue);
    }
}
