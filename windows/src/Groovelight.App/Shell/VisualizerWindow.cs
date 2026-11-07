using System.ComponentModel;
using Groovelight.Audio;
using Groovelight.Controls;
using Groovelight.Model;
using Groovelight.Support;
using Groovelight.Visualizers;
using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using SkiaSharp;
using SkiaSharp.Views.Windows;
using Windows.System;

namespace Groovelight.Shell;

/// <summary>A visualizer drawn on a canvas, a frame each display refresh while music plays.</summary>
public sealed partial class VisualizerView : UserControl
{
    public const string StyleKey = "visualizer.style";
    private readonly SKXamlCanvas canvas = new();
    private readonly VisualizerRenderer renderer;
    private bool running;

    public VisualizerView()
    {
        renderer = new VisualizerRenderer(() => AppModel.Current.Player.Analyzer.LatestFrame) { Style = VisualizerStyles.Parse(AppModel.Current.Preferences.String(StyleKey)) };
        Content = canvas;
        canvas.PaintSurface += (_, args) =>
        {
            var info = args.Info;
            // Rendered at up to 720 pixels across and scaled up smoothly: the looks are soft glows and trails.
            var scale = Math.Min(1, 720.0 / Math.Max(info.Width, 1));
            var frame = renderer.RenderFrame(Math.Max(1, (int)(info.Width * scale)), Math.Max(1, (int)(info.Height * scale)));
            args.Surface.Canvas.DrawImage(frame, new SKRect(0, 0, info.Width, info.Height), new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.None));
        };
        Loaded += (_, _) =>
        {
            running = true;
            CompositionTarget.Rendering += OnRendering;
            AppModel.Current.Preferences.Changed += OnPreferenceChanged;
        };
        Unloaded += (_, _) =>
        {
            running = false;
            CompositionTarget.Rendering -= OnRendering;
            AppModel.Current.Preferences.Changed -= OnPreferenceChanged;
            renderer.Dispose();
        };
    }

    public VisualizerStyle VisualStyle
    {
        get => renderer.Style;
        set => AppModel.Current.Preferences.Set(StyleKey, value.RawValue());
    }

    private void OnPreferenceChanged(string key)
    {
        if (key == StyleKey) DispatcherQueue.TryEnqueue(() => renderer.Style = VisualizerStyles.Parse(AppModel.Current.Preferences.String(StyleKey)));
    }

    private int skip;

    private void OnRendering(object? sender, object args)
    {
        if (!running) return;
        // About 60 frames a second whatever the display's rate; still while nothing plays.
        if (++skip % 2 == 1 && AppModel.Current.Player.State != PlaybackState.Playing) return;
        canvas.Invalidate();
    }

    /// <summary>The style menu items.</summary>
    public static IEnumerable<MenuFlyoutItemBase> StyleItems() => Enum.GetValues<VisualizerStyle>().Select(style =>
    {
        var item = new RadioMenuFlyoutItem
        {
            Text = style.DisplayName(), GroupName = "visualizer",
            IsChecked = VisualizerStyles.Parse(AppModel.Current.Preferences.String(StyleKey)) == style,
        };
        item.Click += (_, _) => AppModel.Current.Preferences.Set(StyleKey, style.RawValue());
        return (MenuFlyoutItemBase)item;
    });
}

/// <summary>
/// The visualizer in its own window (the Mac's VisualizerScreen, Ctrl+T), meant to go full screen like the iTunes
/// visualizer. The controls fade out after a few seconds without the mouse moving; the song's title fades in on every
/// song change.
/// </summary>
public sealed class VisualizerWindow : Window
{
    private static VisualizerWindow? shown;
    private static AppModel Model => AppModel.Current;
    private readonly VisualizerView view = new();
    private readonly Border controls;
    private readonly StackPanel titleBlock = new() { Spacing = 4, Margin = new Thickness(40, 56, 40, 0), IsHitTestVisible = false, Opacity = 0, OpacityTransition = new ScalarTransition { Duration = TimeSpan.FromSeconds(0.8) } };
    private readonly DropDownButton styleButton = new();
    private readonly Button play, fullScreen;
    private readonly StackPanel nowPlaying = new() { Orientation = Orientation.Horizontal, Spacing = 10 };
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer hideTimer, titleTimer;
    private bool hoveringControls;

    public static void Show()
    {
        shown ??= new VisualizerWindow();
        shown.Activate();
    }

    private VisualizerWindow()
    {
        Title = "Visualizer";
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Groovelight.ico"));
        var scale = MainWindow.Current.RootXamlRoot?.RasterizationScale ?? 1;
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(1100 * scale), (int)(700 * scale)));
        styleButton.Flyout = Menus.Flyout(VisualizerView.StyleItems());
        styleButton.Flyout.Opening += (_, _) =>
        {
            var flyout = (MenuFlyout)styleButton.Flyout;
            flyout.Items.Clear();
            foreach (var item in VisualizerView.StyleItems()) flyout.Items.Add(item);
        };
        ToolTipService.SetToolTip(styleButton, "Visualizer style (Left, Right)");
        var player = Model.Player;
        play = Ui.IconButton(Glyphs.Play, "Play", player.TogglePlayPause, 20);
        fullScreen = Ui.IconButton(Glyphs.FullScreen, "Full Screen (F)", ToggleFullScreen, 15);
        var row = Ui.Row(16, styleButton, Divider(),
            Ui.Row(14, Ui.IconButton(Glyphs.Previous, "Previous", player.Previous, 15), play, Ui.IconButton(Glyphs.Next, "Next", player.Next, 15)),
            nowPlaying, Divider(), fullScreen);
        foreach (var child in row.Children.OfType<FrameworkElement>()) child.VerticalAlignment = VerticalAlignment.Center;
        controls = new Border
        {
            Child = row, Padding = new Thickness(18, 8, 18, 8), CornerRadius = new CornerRadius(28), HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, 0, 24), Background = Ui.Brush("AcrylicInAppFillColorDefaultBrush"),
            BorderBrush = Ui.Brush("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1), OpacityTransition = new ScalarTransition { Duration = TimeSpan.FromSeconds(0.4) },
        };
        controls.PointerEntered += (_, _) => hoveringControls = true;
        controls.PointerExited += (_, _) => { hoveringControls = false; ScheduleHide(); };
        var root = new Grid { Background = new SolidColorBrush(Microsoft.UI.Colors.Black), RequestedTheme = ElementTheme.Dark };
        root.Children.Add(view);
        root.Children.Add(titleBlock);
        root.Children.Add(controls);
        root.PointerMoved += (_, _) => Reveal();
        root.KeyDown += OnKey;
        root.IsTabStop = true;
        root.Loaded += (_, _) => root.Focus(FocusState.Programmatic);
        Content = root;
        hideTimer = root.DispatcherQueue.CreateTimer();
        hideTimer.Interval = TimeSpan.FromSeconds(3);
        hideTimer.IsRepeating = false;
        hideTimer.Tick += (_, _) => { if (!hoveringControls) controls.Opacity = 0; };
        titleTimer = root.DispatcherQueue.CreateTimer();
        titleTimer.Interval = TimeSpan.FromSeconds(5);
        titleTimer.IsRepeating = false;
        titleTimer.Tick += (_, _) => titleBlock.Opacity = 0;
        player.PropertyChanged += OnPlayerChanged;
        Model.Preferences.Changed += OnPreferenceChanged;
        Closed += (_, _) =>
        {
            player.PropertyChanged -= OnPlayerChanged;
            Model.Preferences.Changed -= OnPreferenceChanged;
            shown = null;
        };
        AppWindow.Changed += (_, args) => { if (args.DidPresenterChange) UpdateFullScreenButton(); };
        Update();
        FlashTitle();
        Reveal();
        if (Environment.GetCommandLineArgs().Contains("--debug-visualizer")) DebugSnapshot.Target = this;
    }

    private static Border Divider() => new() { Width = 1, Height = 26, Background = Ui.Brush("DividerStrokeColorDefaultBrush") };

    private void OnPlayerChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName == nameof(PlaybackController.Current)) FlashTitle();
        if (args.PropertyName is nameof(PlaybackController.Current) or nameof(PlaybackController.State)) Update();
    }

    private void OnPreferenceChanged(string key)
    {
        if (key == VisualizerView.StyleKey) DispatcherQueue.TryEnqueue(() => { Update(); Reveal(); });
    }

    private void Update()
    {
        styleButton.Content = view.VisualStyle.DisplayName();
        var player = Model.Player;
        ((FontIcon)play.Content).Glyph = player.State == PlaybackState.Playing ? Glyphs.Pause : Glyphs.Play;
        nowPlaying.Children.Clear();
        if (player.Current is { } item)
        {
            nowPlaying.Children.Add(new ArtworkImage { Hash = item.ArtworkHash, Width = 36, Height = 36, Radius = 5 });
            var text = Ui.Column(1, Ui.Text(item.Title, "StrongText", 12), Ui.Text(item.Artist, "CaptionText", 11));
            text.MaxWidth = 200;
            text.VerticalAlignment = VerticalAlignment.Center;
            nowPlaying.Children.Add(text);
        }
        titleBlock.Children.Clear();
        if (player.Current is { } current)
        {
            titleBlock.Children.Add(new TextBlock { Text = current.Title, FontSize = 28, FontWeight = FontWeights.Bold, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White) });
            titleBlock.Children.Add(new TextBlock { Text = $"{current.Artist} — {current.Album}", FontSize = 18, Foreground = new SolidColorBrush(Windows.UI.Color.FromArgb(191, 255, 255, 255)) });
        }
    }

    /// <summary>The song's title fades in on every song change.</summary>
    private void FlashTitle()
    {
        Update();
        titleBlock.Opacity = 1;
        titleTimer.Stop();
        titleTimer.Start();
    }

    private void Reveal()
    {
        controls.Opacity = 1;
        ScheduleHide();
    }

    private void ScheduleHide()
    {
        hideTimer.Stop();
        hideTimer.Start();
    }

    private void OnKey(object sender, KeyRoutedEventArgs args)
    {
        switch (args.Key)
        {
            case VirtualKey.Space: Model.Player.TogglePlayPause(); break;
            case VirtualKey.Right: Cycle(1); break;
            case VirtualKey.Left: Cycle(-1); break;
            case VirtualKey.F: ToggleFullScreen(); break;
            case VirtualKey.Escape when AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen: ToggleFullScreen(); break;
            default: return;
        }
        args.Handled = true;
    }

    private void Cycle(int offset)
    {
        var all = Enum.GetValues<VisualizerStyle>();
        view.VisualStyle = all[(Array.IndexOf(all, view.VisualStyle) + offset + all.Length) % all.Length];
    }

    private void ToggleFullScreen()
    {
        AppWindow.SetPresenter(AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen ? AppWindowPresenterKind.Overlapped : AppWindowPresenterKind.FullScreen);
        UpdateFullScreenButton();
    }

    private void UpdateFullScreenButton()
    {
        var full = AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen;
        ((FontIcon)fullScreen.Content).Glyph = full ? Glyphs.BackToWindow : Glyphs.FullScreen;
        ToolTipService.SetToolTip(fullScreen, full ? "Exit Full Screen (F)" : "Full Screen (F)");
    }
}
