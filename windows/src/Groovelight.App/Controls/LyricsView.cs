using System.ComponentModel;
using Groovelight.Audio;
using Groovelight.Core.Library;
using Groovelight.Metadata;
using Groovelight.Model;
using Groovelight.Support;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Groovelight.Controls;

/// <summary>
/// Lyrics of the song that is playing, loaded from the library and looked up online when it has none (the Mac's
/// CurrentLyrics and LyricsPanel). Synced (LRC) lyrics follow the song: the current line is highlighted and kept in
/// view, and clicking a line seeks there. Plain lyrics scroll freely.
/// </summary>
public sealed partial class LyricsView : UserControl
{
    private static AppModel Model => AppModel.Current;
    private readonly double fontSize;
    private readonly Brush? foreground;
    private readonly ContentControl host = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private Track? track;
    private long? shownId;
    private SyncedLyrics? synced;
    private readonly List<TextBlock> lines = [];
    private ScrollViewer? scroll;
    private StackPanel? linesPanel;
    private int? active = -2;
    private DispatcherQueueTimer? timer;

    /// <param name="foreground">White on Now Playing's dark backdrop; the theme's text color otherwise.</param>
    public LyricsView(double fontSize, Brush? foreground = null)
    {
        this.fontSize = fontSize;
        this.foreground = foreground;
        Content = host;
        Loaded += (_, _) =>
        {
            Model.Player.PropertyChanged += OnPlayerChanged;
            Model.Metadata.PropertyChanged += OnMetadataChanged;
            Model.Database.Changed += OnDatabaseChanged;
            timer = DispatcherQueue.CreateTimer();
            timer.Interval = TimeSpan.FromMilliseconds(50);
            timer.Tick += (_, _) => UpdateActive();
            timer.Start();
            _ = LoadAsync(force: true);
        };
        Unloaded += (_, _) =>
        {
            Model.Player.PropertyChanged -= OnPlayerChanged;
            Model.Metadata.PropertyChanged -= OnMetadataChanged;
            Model.Database.Changed -= OnDatabaseChanged;
            timer?.Stop();
        };
        SizeChanged += (_, _) => { if (linesPanel is not null) Pad(); };
    }

    private void OnPlayerChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName == nameof(PlaybackController.Current)) _ = LoadAsync();
    }

    private void OnMetadataChanged(object? sender, PropertyChangedEventArgs args)
    {
        // The lookup started at playback finished: reload the track to pick up its lyrics.
        if (args.PropertyName == nameof(MetadataStore.LyricsInFlight)) _ = LoadAsync(force: true);
    }

    private void OnDatabaseChanged() => DispatcherQueue.TryEnqueue(() => _ = LoadAsync(force: true));

    private async Task LoadAsync(bool force = false)
    {
        var id = Model.Player.Current?.Id;
        if (!force && id == shownId) return;
        var loaded = id is { } trackId ? await Task.Run(() => Model.Database.Read(db => db.FetchTrack(trackId))) : null;
        if (Model.Player.Current?.Id != id) return;
        var lyrics = loaded?.DisplayLyrics();
        if (id == shownId && lyrics == track?.DisplayLyrics() && host.Content is not null) return;
        shownId = id;
        track = loaded;
        Build();
        // Online lookup when the song has no lyrics yet (also started when the song began playing).
        if (loaded is not null && lyrics is null) _ = Model.Metadata.EnsureLyricsAsync(loaded);
    }

    private TextBlock Styled(TextBlock text)
    {
        if (foreground is not null) text.Foreground = foreground;
        return text;
    }

    private void Build()
    {
        lines.Clear();
        synced = null;
        linesPanel = null;
        scroll = null;
        active = -2;
        var lyrics = track?.DisplayLyrics();
        if (string.IsNullOrEmpty(lyrics))
        {
            var searching = Model.Player.Current is { } item && Model.Metadata.LyricsInFlight.Contains(item.Id);
            var panel = new StackPanel { Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 360 };
            if (searching)
            {
                panel.Children.Add(new ProgressRing { IsActive = true, Width = 32, Height = 32 });
                panel.Children.Add(Styled(new TextBlock { Text = "Searching for lyrics…", FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center }));
            }
            else
            {
                panel.Children.Add(new FontIcon { Glyph = Glyphs.Lyrics, FontSize = 32, Foreground = foreground ?? Ui.Brush("TextFillColorSecondaryBrush") });
                panel.Children.Add(Styled(new TextBlock { Text = "No lyrics for this song", FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center }));
                var detail = new TextBlock
                {
                    Text = "Lyrics embedded in your files show up here, and Groovelight looks them up on LRCLIB (Settings, Metadata).",
                    TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Opacity = 0.7, FontSize = 13,
                };
                panel.Children.Add(Styled(detail));
            }
            host.Content = panel;
            return;
        }
        var parsed = SyncedLyrics.Parse(lyrics);
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Hidden };
        if (parsed.IsSynced)
        {
            synced = parsed;
            linesPanel = new StackPanel { Spacing = fontSize * 0.75 };
            foreach (var line in parsed.Lines)
            {
                var text = Styled(new TextBlock
                {
                    Text = line.Text.Length == 0 ? "♪" : line.Text, FontSize = fontSize, FontWeight = FontWeights.Bold, TextWrapping = TextWrapping.Wrap,
                    Opacity = 0.35, OpacityTransition = new ScalarTransition { Duration = TimeSpan.FromMilliseconds(300) },
                });
                var time = line.Time;
                text.Tapped += (_, _) => { if (time is { } seconds) Model.Player.Seek(seconds); };
                lines.Add(text);
                linesPanel.Children.Add(text);
            }
            scroll.Content = linesPanel;
            Pad();
        }
        else
        {
            scroll.Content = Styled(new TextBlock
            {
                Text = parsed.PlainText, FontSize = fontSize * 0.92, FontWeight = FontWeights.Bold, TextWrapping = TextWrapping.Wrap,
                LineHeight = fontSize * 1.42, Margin = new Thickness(0, 40, 0, 40), IsTextSelectionEnabled = true,
            });
        }
        root.Children.Add(scroll);
        if (track?.Lyrics is null && track?.FetchedLyrics is not null)
        {
            var credit = Styled(new TextBlock { Text = "Lyrics from LRCLIB", FontSize = 10, Opacity = 0.5, Margin = new Thickness(0, 8, 0, 0) });
            Grid.SetRow(credit, 1);
            root.Children.Add(credit);
        }
        host.Content = root;
        UpdateActive();
    }

    /// <summary>The first line starts near the top; room below lets the last line still reach the anchor.</summary>
    private void Pad()
    {
        if (linesPanel is null) return;
        var height = ActualHeight;
        linesPanel.Padding = new Thickness(0, Math.Max(fontSize * 1.5, height * 0.08), 0, Math.Max(fontSize * 6, height * (1 - Anchor)));
    }

    /// <summary>Where the current line is held, from the top of the panel.</summary>
    private const double Anchor = 0.35;

    private void UpdateActive()
    {
        if (synced is null || scroll is null) return;
        // Lines lead the audio slightly so a line lights up as it starts being sung.
        var index = synced.LineIndex(Model.Player.EstimatedTime(DateTime.UtcNow) + 0.15);
        if (index == active) return;
        active = index;
        for (var i = 0; i < lines.Count; i++) lines[i].Opacity = i == index ? 1 : 0.35;
        if (index is { } current && current < lines.Count)
        {
            var line = lines[current];
            var top = line.TransformToVisual(linesPanel).TransformPoint(new Windows.Foundation.Point(0, 0)).Y;
            scroll.ChangeView(null, Math.Max(0, top - scroll.ViewportHeight * Anchor), null, false);
        }
        else scroll.ChangeView(null, 0, null, false);
    }
}
