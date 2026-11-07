using System.ComponentModel;
using System.Diagnostics;
using Groovelight.Audio;
using Groovelight.Controls;
using Groovelight.Core.Library;
using Groovelight.Model;
using Groovelight.Skins;
using Groovelight.Support;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using SkiaSharp;
using SkiaSharp.Views.Windows;

namespace Groovelight.SkinViews;

/// <summary>
/// Now Playing as the vintage player chosen (the Mac's NowPlayingDeck): the whole view is the turntable, the cassette
/// deck, the CD player or the PC Player, drawn each frame, their keys, knobs and switches working the player; the lyrics
/// (and Up Next, but on the PC Player, whose playlist is the queue) behind smoked glass in the player's place.
/// </summary>
public sealed partial class DeckView : UserControl
{
    private static AppModel Model => AppModel.Current;
    private static PlaybackController Player => Model.Player;
    private readonly SkinDeck deck = new();
    private readonly SKXamlCanvas canvas = new();
    private readonly Canvas overlayHost = new();
    private readonly ContentControl overlay = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private readonly ToolTip tip = new();
    private Track? track;
    private SKImage? artwork;
    private string? artworkHash;
    private double lastPaint;
    private string? hoverTitle;
    private bool attached;

    public DeckView(NowPlayingSkin skin)
    {
        deck.Skin = skin;
        overlayHost.Children.Add(overlay);
        var root = new Grid();
        root.Children.Add(canvas);
        root.Children.Add(overlayHost);
        Content = root;
        ToolTipService.SetToolTip(canvas, tip);
        tip.IsEnabled = false;
        canvas.PaintSurface += OnPaint;
        canvas.PointerPressed += OnPointerPressed;
        canvas.PointerMoved += OnPointerMoved;
        canvas.PointerReleased += OnPointerReleased;
        canvas.PointerCanceled += (_, _) => deck.Ui.PointerCancel();
        canvas.PointerCaptureLost += (_, _) => deck.Ui.PointerCancel();
        canvas.PointerWheelChanged += OnWheel;
        deck.Ui.Invalidated += () => canvas.Invalidate();
        Loaded += (_, _) => Attach();
        Unloaded += (_, _) => Detach();
    }

    public NowPlayingSkin Skin
    {
        get => deck.Skin;
        set
        {
            deck.Skin = value;
            UpdateOverlay();
            canvas.Invalidate();
        }
    }

    private void Attach()
    {
        if (attached) return;
        attached = true;
        CompositionTarget.Rendering += OnRendering;
        Player.PropertyChanged += OnPlayerChanged;
        Model.PropertyChanged += OnModelChanged;
        Model.Preferences.Changed += OnPreferenceChanged;
        Model.Database.Changed += OnDatabaseChanged;
        SkinStore.Cassettes.Changed += OnCassettesChanged;
        LoadSettings();
        UpdateOverlay();
        _ = LoadTrackAsync();
    }

    private void Detach()
    {
        if (!attached) return;
        attached = false;
        CompositionTarget.Rendering -= OnRendering;
        Player.PropertyChanged -= OnPlayerChanged;
        Model.PropertyChanged -= OnModelChanged;
        Model.Preferences.Changed -= OnPreferenceChanged;
        Model.Database.Changed -= OnDatabaseChanged;
        SkinStore.Cassettes.Changed -= OnCassettesChanged;
    }

    private void OnCassettesChanged() => DispatcherQueue.TryEnqueue(() =>
    {
        LoadSettings();
        canvas.Invalidate();
    });

    private void LoadSettings()
    {
        deck.Theme = SkinInfo.ParseTheme(Model.Preferences.String(SkinInfo.PcThemeStorageKey));
        deck.Cassette = SkinStore.Cassettes.Design(Model.Preferences.String(SkinInfo.CassetteStorageKey));
        deck.Pictures = SkinStore.Cassettes.Pictures(deck.Cassette);
        deck.CoronaVisualization = new SkinBinding<int>(() => (int)Model.Preferences.Integer(SkinInfo.CoronaVisualizationKey),
            value => Model.Preferences.Set(SkinInfo.CoronaVisualizationKey, (long)value));
    }

    private void OnPreferenceChanged(string key)
    {
        if (key.StartsWith("nowPlaying.", StringComparison.Ordinal)) DispatcherQueue.TryEnqueue(() =>
        {
            LoadSettings();
            canvas.Invalidate();
        });
    }

    private void OnPlayerChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName == nameof(PlaybackController.Current)) _ = LoadTrackAsync();
        canvas.Invalidate();
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName is nameof(AppModel.IsShowingLyrics) or nameof(AppModel.IsShowingNowPlayingQueue)) UpdateOverlay();
    }

    private void OnDatabaseChanged() => DispatcherQueue.TryEnqueue(() => _ = LoadTrackAsync());

    /// <summary>The song's file (its format and whether it is loved) and its cover, decoded for drawing.</summary>
    private async Task LoadTrackAsync()
    {
        var current = Player.Current;
        var id = current?.Id;
        var hash = current?.ArtworkHash;
        var loaded = id is { } trackId ? await Task.Run(() => Model.Database.Read(db => db.FetchTrack(trackId))) : null;
        if (hash != artworkHash)
        {
            var path = hash is null ? null : Model.Artwork.PathFor(hash, ArtworkCache.Size.Large);
            var image = path is null ? null : await Task.Run(() => File.Exists(path) ? SKImage.FromEncodedData(path) : null);
            if (Player.Current?.ArtworkHash != hash) return;
            artwork = image;
            artworkHash = hash;
        }
        if (Player.Current?.Id != id) return;
        track = loaded;
        canvas.Invalidate();
    }

    /// <summary>The lyrics, or Up Next (but on the PC Player), in the player's place.</summary>
    private void UpdateOverlay()
    {
        var lyrics = Model.IsShowingLyrics;
        var queue = Model.IsShowingNowPlayingQueue && deck.Skin != NowPlayingSkin.PcPlayer;
        deck.ShowsOverlay = lyrics || queue;
        var white = new SolidColorBrush(Microsoft.UI.Colors.White);
        overlay.Content = lyrics ? overlay.Content as LyricsView ?? new LyricsView(22, white) : queue ? overlay.Content as QueuePanel ?? new QueuePanel(white) : null;
        overlay.RequestedTheme = ElementTheme.Dark;
        overlay.Visibility = Visibility.Collapsed;
        canvas.Invalidate();
    }

    private void OnRendering(object? sender, object args)
    {
        var now = clock.Elapsed.TotalSeconds;
        deck.Ui.Tick(now);
        // Every display refresh while something moves, a few times a second otherwise (the clocks, a blinking time).
        if (deck.Ui.WantsFrames || now - lastPaint > 0.25) canvas.Invalidate();
    }

    private SkinPlayback Playback()
    {
        var current = Player.Current;
        var spec = track?.Id == current?.Id ? track?.AudioSpec : null;
        return new SkinPlayback
        {
            Title = current?.Title ?? "Not Playing", Artist = current?.Artist ?? "", Album = current?.Album ?? "",
            IsPlaying = Player.State == PlaybackState.Playing, Duration = Player.Duration,
            Time = () => Player.EstimatedTime(DateTime.UtcNow),
            Levels = () =>
            {
                var frame = Player.Analyzer.LatestFrame;
                return (frame.LeftLevel, frame.RightLevel);
            },
            Spectrum = () => Player.Analyzer.LatestFrame.Bands,
            Format = spec is null ? null : SkinFormat.From(spec.SampleRate, spec.BitDepth, spec.Bitrate is { } rate ? (int)Math.Round(rate) : null, spec.Channels),
            Artwork = artwork,
        };
    }

    private DeckControls Controls()
    {
        var current = track?.Id == Player.Current?.Id ? track : null;
        return new DeckControls
        {
            PlayPause = Player.TogglePlayPause, Previous = Player.Previous, Next = Player.Next, Seek = Player.Seek,
            Volume = new SkinBinding<double>(() => Player.Volume, value =>
            {
                Player.Volume = (float)value;
                canvas.Invalidate();
            }),
            Equalizer = new SkinBinding<bool>(() => Model.Equalizer.IsEnabled, value => Model.Equalizer.IsEnabled = value),
            Eject = () => Model.IsShowingNowPlaying = false,
            Love = current is null ? null : new SkinBinding<bool>(() => current.IsLoved, loved =>
            {
                Model.ToggleLoved(current);
                _ = LoadTrackAsync();
            }),
            LoveHint = Model.Shortcuts.Hint(ShortcutAction.Love),
            IsShuffled = Player.IsShuffled, ToggleShuffle = () => Player.SetShuffle(!Player.IsShuffled),
            RepeatMode = Player.RepeatMode switch { RepeatMode.All => DeckRepeat.All, RepeatMode.One => DeckRepeat.One, _ => DeckRepeat.Off },
            CycleRepeat = Model.CycleRepeat,
            TapeCue = TapeCue.Cue,
        };
    }

    private SkinPlaylist Playlist()
    {
        var queue = Player.Queue;
        return new SkinPlaylist(queue.Items.Select(item => new SkinPlaylistEntry(item.Title, item.Artist, item.Duration)).ToList(), queue.CurrentIndex,
            Player.JumpToQueueIndex);
    }

    private void OnPaint(object? sender, SKPaintSurfaceEventArgs args)
    {
        var now = clock.Elapsed.TotalSeconds;
        lastPaint = now;
        var surface = args.Surface.Canvas;
        var width = (float)Math.Max(ActualWidth, 1);
        var scale = args.Info.Width / width;
        surface.Clear(SKColors.Black);
        surface.Save();
        surface.Scale(scale);
        deck.Playlist = deck.Skin == NowPlayingSkin.PcPlayer ? Playlist() : null;
        deck.Draw(surface, new SKSize(width, args.Info.Height / scale), now, Playback(), Controls());
        surface.Restore();
        PlaceOverlay();
    }

    private void PlaceOverlay()
    {
        if (deck.OverlayRect is not { } rect || overlay.Content is null)
        {
            overlay.Visibility = Visibility.Collapsed;
            return;
        }
        Canvas.SetLeft(overlay, rect.Left);
        Canvas.SetTop(overlay, rect.Top);
        overlay.Width = Math.Max(rect.Width, 1);
        overlay.Height = Math.Max(rect.Height, 1);
        overlay.Visibility = Visibility.Visible;
    }

    private SKPoint Point(PointerRoutedEventArgs args)
    {
        var position = args.GetCurrentPoint(canvas).Position;
        // The canvas's pixels, as the deck's regions are kept.
        var scale = (float)(canvas.CanvasSize.Width / Math.Max(ActualWidth, 1));
        if (scale <= 0) scale = (float)(XamlRoot?.RasterizationScale ?? 1);
        return new SKPoint((float)position.X * scale, (float)position.Y * scale);
    }

    private void OnPointerPressed(object sender, PointerRoutedEventArgs args)
    {
        if (deck.Ui.PointerDown(Point(args), clock.Elapsed.TotalSeconds))
        {
            canvas.CapturePointer(args.Pointer);
            args.Handled = true;
        }
    }

    private void OnPointerMoved(object sender, PointerRoutedEventArgs args)
    {
        var point = Point(args);
        deck.Ui.PointerMove(point);
        var (interactive, title) = deck.Ui.Hover(point);
        ProtectedCursor = InputSystemCursor.Create(interactive ? InputSystemCursorShape.Hand : InputSystemCursorShape.Arrow);
        if (title != hoverTitle)
        {
            hoverTitle = title;
            tip.Content = title;
            tip.IsEnabled = title is not null;
            tip.IsOpen = false;
        }
    }

    private void OnPointerReleased(object sender, PointerRoutedEventArgs args)
    {
        deck.Ui.PointerUp(Point(args));
        canvas.ReleasePointerCapture(args.Pointer);
    }

    private void OnWheel(object sender, PointerRoutedEventArgs args)
    {
        var delta = args.GetCurrentPoint(canvas).Properties.MouseWheelDelta / 120.0;
        if (deck.Ui.PointerWheel(Point(args), delta)) args.Handled = true;
    }
}
