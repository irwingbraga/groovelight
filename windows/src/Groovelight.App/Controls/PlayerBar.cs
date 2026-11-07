using System.ComponentModel;
using Groovelight.Audio;
using Groovelight.Core.Library;
using Groovelight.Model;
using Groovelight.Support;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;

namespace Groovelight.Controls;

/// <summary>
/// The player bar docked along the bottom of the window (the Mac's floating player): transport on the left, the song
/// centered with its scrubber, tools on the right. Narrow windows drop controls in steps, as the Mac's bar does.
/// </summary>
public sealed partial class PlayerBar : UserControl
{
    public enum Density { Full, Medium, Compact }

    private static AppModel Model => AppModel.Current;
    private PlaybackController Player => Model.Player;

    private readonly Button shuffle, previous, play, next, repeat, love, lyrics, upNext, volumeButton, compactPlay, compactNext;
    private readonly StackPanel transport;
    private readonly ArtworkImage artwork = new() { Width = 44, Height = 44, Radius = 6 };
    private readonly Button artworkButton;
    private readonly TextBlock title = new() { FontSize = 13, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly StackPanel titleRow = new() { Orientation = Orientation.Horizontal, Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly StackPanel subtitle = new() { Orientation = Orientation.Horizontal, Spacing = 4, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock elapsed = new() { FontSize = 10, Width = 40, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock remaining = new() { FontSize = 10, Width = 40, VerticalAlignment = VerticalAlignment.Center };
    private readonly Slider scrubber = new() { Minimum = 0, Maximum = 1, VerticalAlignment = VerticalAlignment.Center, IsThumbToolTipEnabled = false, Margin = new Thickness(0, -6, 0, -6) };
    private readonly Slider volume = new() { Minimum = 0, Maximum = 100, Width = 90, VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel volumeInline;
    private readonly StackPanel extras = new() { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel tools;
    private readonly Grid row = new() { ColumnSpacing = 16 };
    private Track? track;
    private Density density = Density.Full;
    private bool updatingScrubber;
    private bool updatingVolume;
    private double? scrubValue;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? seekTimer;

    public PlayerBar()
    {
        Height = 72;
        shuffle = Ui.IconButton(Glyphs.Shuffle, "Shuffle", () => Player.SetShuffle(!Player.IsShuffled), 15);
        previous = Ui.IconButton(Glyphs.Previous, "Previous", Player.Previous, 16);
        play = Ui.IconButton(Glyphs.Play, "Play", Player.TogglePlayPause, 22);
        play.Width = 44;
        next = Ui.IconButton(Glyphs.Next, "Next", Player.Next, 16);
        repeat = Ui.IconButton(Glyphs.Repeat, "Repeat", Model.CycleRepeat, 15);
        transport = Ui.Row(10, shuffle, previous, play, next, repeat);
        transport.VerticalAlignment = VerticalAlignment.Center;

        artworkButton = new Button { Content = artwork, Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = Images.Transparent, VerticalAlignment = VerticalAlignment.Center };
        artworkButton.Click += (_, _) => Model.IsShowingNowPlaying = true;
        artwork.Translation = new System.Numerics.Vector3(0, 0, 4);
        artwork.Shadow = new ThemeShadow();
        titleRow.Children.Add(title);
        foreach (var text in new[] { elapsed, remaining }) text.Style = Ui.Style("CaptionText");
        elapsed.FontSize = remaining.FontSize = 10;
        elapsed.FontFeatures();
        remaining.FontFeatures();
        var timeRow = Ui.Grid("auto,*,auto");
        timeRow.ColumnSpacing = 8;
        timeRow.Children.Add(elapsed);
        timeRow.Children.Add(scrubber.At(1));
        timeRow.Children.Add(remaining.At(2));
        var center = Ui.Column(1, titleRow, subtitle, timeRow);
        center.VerticalAlignment = VerticalAlignment.Center;
        love = Ui.IconButton(Glyphs.Heart, "Love", () => { if (track is not null) Model.ToggleLoved(track); }, 15);
        love.VerticalAlignment = VerticalAlignment.Center;
        var summary = Ui.Grid("auto,*,auto");
        summary.ColumnSpacing = 12;
        summary.Children.Add(artworkButton);
        summary.Children.Add(center.At(1));
        summary.Children.Add(love.At(2));
        summary.MinWidth = 240;
        summary.MaxWidth = 560;

        var muteButton = Ui.IconButton(Glyphs.Volume1, "Mute", Model.ToggleMute, 14);
        volumeInline = Ui.Row(4, muteButton, volume);
        volumeInline.VerticalAlignment = VerticalAlignment.Center;
        volumeButton = Ui.IconButton(Glyphs.Volume3, "Volume", () => { }, 15);
        volumeButton.Flyout = new Flyout { Content = VolumePopover(), Placement = FlyoutPlacementMode.Top };
        lyrics = Ui.IconButton(Glyphs.Lyrics, "Lyrics", () => Model.IsShowingLyricsPanel = !Model.IsShowingLyricsPanel, 15);
        upNext = Ui.IconButton(Glyphs.Queue, "Up Next", () => Model.IsShowingQueue = !Model.IsShowingQueue, 15);
        compactPlay = Ui.IconButton(Glyphs.Play, "Play", Player.TogglePlayPause, 18);
        compactNext = Ui.IconButton(Glyphs.Next, "Next", Player.Next, 14);
        tools = Ui.Row(8, volumeInline, volumeButton, compactPlay, compactNext, extras, lyrics, upNext);
        tools.VerticalAlignment = VerticalAlignment.Center;
        tools.HorizontalAlignment = HorizontalAlignment.Right;

        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(2.2, GridUnitType.Star), MaxWidth = 560 });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(transport);
        row.Children.Add(summary.At(1));
        row.Children.Add(tools.At(2));
        row.Padding = new Thickness(18, 0, 14, 0);
        Content = new Border
        {
            Child = row,
            Background = Ui.Brush("AcrylicInAppFillColorDefaultBrush"),
            BorderBrush = Ui.Brush("CardStrokeColorDefaultBrush"),
            BorderThickness = new Thickness(0, 1, 0, 0),
        };

        scrubber.ValueChanged += (_, args) =>
        {
            if (updatingScrubber || Player.Current is null) return;
            scrubValue = args.NewValue;
            UpdateTimes();
            seekTimer ??= DispatcherQueue.CreateTimer();
            seekTimer.Interval = TimeSpan.FromMilliseconds(120);
            seekTimer.IsRepeating = false;
            seekTimer.Tick -= OnSeekTimer;
            seekTimer.Tick += OnSeekTimer;
            seekTimer.Start();
        };
        volume.ValueChanged += (_, args) => { if (!updatingVolume) Player.Volume = (float)(args.NewValue / 100); };
        SizeChanged += (_, args) => SetDensity(args.NewSize.Width >= 980 ? Density.Full : args.NewSize.Width >= 720 ? Density.Medium : Density.Compact);
        Loaded += (_, _) =>
        {
            Player.PropertyChanged += OnPlayerChanged;
            Model.PropertyChanged += OnModelChanged;
            Model.SleepTimer.PropertyChanged += OnSleepTimerChanged;
            Model.Database.Changed += OnDatabaseChanged;
            Model.Shortcuts.Changed += UpdateTooltips;
            UpdateAll();
        };
        Unloaded += (_, _) =>
        {
            Player.PropertyChanged -= OnPlayerChanged;
            Model.PropertyChanged -= OnModelChanged;
            Model.SleepTimer.PropertyChanged -= OnSleepTimerChanged;
            Model.Database.Changed -= OnDatabaseChanged;
            Model.Shortcuts.Changed -= UpdateTooltips;
        };
        SetDensity(Density.Full, force: true);
    }

    private void OnSeekTimer(Microsoft.UI.Dispatching.DispatcherQueueTimer sender, object args)
    {
        if (scrubValue is { } value) Player.Seek(value);
        scrubValue = null;
    }

    private FrameworkElement VolumePopover()
    {
        var slider = new Slider { Minimum = 0, Maximum = 100, Width = 160, VerticalAlignment = VerticalAlignment.Center };
        var percent = Ui.Text("", "CaptionText");
        percent.Width = 36;
        percent.TextAlignment = TextAlignment.Right;
        void Sync()
        {
            slider.Value = Player.Volume * 100;
            percent.Text = $"{(int)Math.Round(Player.Volume * 100)}%";
        }
        slider.ValueChanged += (_, args) => { Player.Volume = (float)(args.NewValue / 100); percent.Text = $"{(int)Math.Round(args.NewValue)}%"; };
        var mute = Ui.IconButton(Glyphs.Volume3, "Mute", () => { Model.ToggleMute(); Sync(); }, 14);
        var panel = Ui.Row(10, mute, slider, percent);
        panel.Loaded += (_, _) => Sync();
        return panel;
    }

    private void SetDensity(Density value, bool force = false)
    {
        if (value == density && !force) return;
        density = value;
        var full = value == Density.Full;
        var compact = value == Density.Compact;
        transport.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        shuffle.Visibility = repeat.Visibility = full ? Visibility.Visible : Visibility.Collapsed;
        transport.Spacing = full ? 14 : 8;
        row.ColumnDefinitions[0].Width = compact ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
        volumeInline.Visibility = full ? Visibility.Visible : Visibility.Collapsed;
        volumeButton.Visibility = full ? Visibility.Collapsed : Visibility.Visible;
        compactPlay.Visibility = compactNext.Visibility = compact ? Visibility.Visible : Visibility.Collapsed;
        elapsed.Visibility = remaining.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        love.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        UpdatePanels();
        UpdateTrack();
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
                UpdateAll();
                break;
            case nameof(PlaybackController.Volume):
                UpdateVolume();
                break;
            default:
                UpdateAll();
                break;
        }
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName is nameof(AppModel.SidePanel)) UpdatePanels();
    }

    private void OnSleepTimerChanged(object? sender, PropertyChangedEventArgs args) => UpdateExtras();

    private void OnDatabaseChanged() => DispatcherQueue.TryEnqueue(() => _ = LoadTrackAsync());

    private async Task LoadTrackAsync()
    {
        var id = Player.Current?.Id;
        var loaded = id is { } trackId ? await Task.Run(() => Model.Database.Read(db => db.FetchTrack(trackId))) : null;
        if (Player.Current?.Id != id) return;
        track = loaded;
        UpdateTrack();
    }

    private void UpdateAll()
    {
        var playing = Player.State == PlaybackState.Playing;
        foreach (var button in new[] { play, compactPlay })
        {
            ((FontIcon)button.Content).Glyph = playing ? Glyphs.Pause : Glyphs.Play;
            ToolTipService.SetToolTip(button, playing ? "Pause" : "Play");
        }
        Tint(shuffle, Player.IsShuffled);
        ((FontIcon)repeat.Content).Glyph = Player.RepeatMode == RepeatMode.One ? Glyphs.RepeatOne : Glyphs.Repeat;
        Tint(repeat, Player.RepeatMode != RepeatMode.Off);
        UpdateTrack();
        UpdateTimes();
        UpdateVolume();
        UpdateExtras();
        UpdateTooltips();
    }

    private void UpdateTooltips()
    {
        var shortcuts = Model.Shortcuts;
        ToolTipService.SetToolTip(shuffle, "Shuffle" + shortcuts.Hint(ShortcutAction.Shuffle));
        ToolTipService.SetToolTip(previous, "Previous" + shortcuts.Hint(ShortcutAction.Previous));
        ToolTipService.SetToolTip(next, "Next" + shortcuts.Hint(ShortcutAction.Next));
        ToolTipService.SetToolTip(compactNext, "Next" + shortcuts.Hint(ShortcutAction.Next));
        ToolTipService.SetToolTip(repeat, "Repeat" + shortcuts.Hint(ShortcutAction.CycleRepeat));
        ToolTipService.SetToolTip(love, "Love" + shortcuts.Hint(ShortcutAction.Love));
        ToolTipService.SetToolTip(lyrics, "Lyrics" + shortcuts.Hint(ShortcutAction.Lyrics));
        ToolTipService.SetToolTip(upNext, "Up Next" + shortcuts.Hint(ShortcutAction.UpNext));
        ToolTipService.SetToolTip(artworkButton, "Show Now Playing" + shortcuts.Hint(ShortcutAction.NowPlaying));
    }

    private static void Tint(Button button, bool on)
    {
        if (button.Content is not FontIcon icon) return;
        if (on) icon.Style = Ui.Style("BrandIcon");
        else
        {
            icon.ClearValue(StyleProperty);
            icon.ClearValue(FontIcon.ForegroundProperty);
        }
    }

    private void UpdateTrack()
    {
        var item = Player.Current;
        artwork.Hash = item?.ArtworkHash;
        artworkButton.IsEnabled = item is not null;
        title.Text = item?.Title ?? "Not Playing";
        title.Opacity = item is null ? 0.6 : 1;
        // The quality badge of the song, when it has one.
        while (titleRow.Children.Count > 1) titleRow.Children.RemoveAt(1);
        if (density != Density.Compact && track is not null && track.Id == item?.Id && QualityBadge.HasBadge(track.AudioSpec.Tier))
        {
            var badge = new QualityBadge(track.AudioSpec.Tier, isMini: true);
            var badgeButton = new Button { Content = badge, Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = Images.Transparent, VerticalAlignment = VerticalAlignment.Center };
            var current = track;
            badgeButton.Click += (_, _) => AudioQualityFlyout.Show(badgeButton, current);
            titleRow.Children.Add(badgeButton);
        }
        // Artist and album link to their pages, like in Now Playing (once the library track is loaded).
        subtitle.Children.Clear();
        if (item is not null)
        {
            var loaded = track?.Id == item.Id ? track : null;
            subtitle.Children.Add(Ui.Link(item.Artist, loaded is not null && Menus.ArtistPageName(loaded) is { } artist ? () => Model.ShowArtist(artist) : null, "CaptionText", $"Go to {item.Artist}"));
            subtitle.Children.Add(Ui.Text("—", "CaptionText"));
            subtitle.Children.Add(Ui.Link(item.Album, loaded is not null ? () => Model.ShowAlbum(loaded.AlbumKey) : null, "CaptionText", $"Go to {item.Album}"));
            foreach (var child in subtitle.Children.OfType<FrameworkElement>()) child.MaxWidth = 220;
        }
        else subtitle.Children.Add(Ui.Text(" ", "CaptionText"));
        var loved = track?.IsLoved == true && track.Id == item?.Id;
        ((FontIcon)love.Content).Glyph = loved ? Glyphs.HeartFilled : Glyphs.Heart;
        ((FontIcon)love.Content).Foreground = loved ? Ui.Brush("LoveBrush") : null;
        if (!loved) ((FontIcon)love.Content).ClearValue(FontIcon.ForegroundProperty);
        love.IsEnabled = track is not null && track.Id == item?.Id;
        scrubber.IsEnabled = item is not null;
    }

    private void UpdateTimes()
    {
        var item = Player.Current;
        var duration = Math.Max(Player.Duration, 1);
        var time = scrubValue ?? Player.CurrentTime;
        if (scrubValue is null)
        {
            updatingScrubber = true;
            scrubber.Maximum = duration;
            scrubber.Value = Math.Clamp(Player.CurrentTime, 0, duration);
            updatingScrubber = false;
        }
        elapsed.Text = item is null ? "" : Format.Duration(time);
        remaining.Text = item is null ? "" : Format.Remaining(Player.Duration - time);
    }

    private void UpdateVolume()
    {
        updatingVolume = true;
        volume.Value = Player.Volume * 100;
        updatingVolume = false;
        var glyph = Player.Volume switch { 0 => Glyphs.Mute, < 0.34f => Glyphs.Volume1, < 0.67f => Glyphs.Volume2, _ => Glyphs.Volume3 };
        ((FontIcon)volumeButton.Content).Glyph = glyph;
        if (volumeInline.Children[0] is Button mute)
        {
            ((FontIcon)mute.Content).Glyph = Player.Volume == 0 ? Glyphs.Mute : Glyphs.Volume1;
            ToolTipService.SetToolTip(mute, Player.Volume == 0 ? "Unmute" : "Mute");
        }
    }

    /// <summary>Shown only while active: the playback speed when it is not normal, and the sleep timer. Each opens a menu.</summary>
    private void UpdateExtras()
    {
        extras.Children.Clear();
        if (Player.Rate != 1 && !Player.BitPerfect)
        {
            var speed = new Button { Style = Ui.Style("BarButton"), Content = Ui.Text(PlaybackPrefs.SpeedLabel(Player.Rate), "BrandText", 12, FontWeights.SemiBold) };
            speed.Flyout = Menus.Flyout(PlaybackPrefs.Speeds.Select(rate => (MenuFlyoutItemBase)Menus.Item(PlaybackPrefs.SpeedLabel(rate), () => Model.SetRate(rate))));
            ToolTipService.SetToolTip(speed, "Playback speed");
            extras.Children.Add(speed);
        }
        if (Model.SleepTimer.IsActive)
        {
            var moon = new Button { Style = Ui.Style("BarButton"), Content = Ui.Icon(Glyphs.Moon, 14, "BrandIcon") };
            moon.Flyout = Menus.Flyout([
                new MenuFlyoutItem { Text = Model.SleepTimer.Summary ?? "", IsEnabled = false },
                Menus.Item("Turn Off Sleep Timer", Model.SleepTimer.Cancel),
            ]);
            ToolTipService.SetToolTip(moon, "Sleep timer: " + (Model.SleepTimer.Summary ?? ""));
            extras.Children.Add(moon);
        }
    }

    /// <summary>The compact bar has room for one of the two panel buttons: the one of the panel that is open.</summary>
    private void UpdatePanels()
    {
        Tint(lyrics, Model.IsShowingLyricsPanel);
        Tint(upNext, Model.IsShowingQueue);
        var compact = density == Density.Compact;
        lyrics.Visibility = !compact || Model.IsShowingLyricsPanel ? Visibility.Visible : Visibility.Collapsed;
        upNext.Visibility = !compact || !Model.IsShowingLyricsPanel ? Visibility.Visible : Visibility.Collapsed;
    }
}
