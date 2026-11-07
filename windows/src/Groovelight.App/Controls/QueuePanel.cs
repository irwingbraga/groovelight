using System.ComponentModel;
using Groovelight.Audio;
using Groovelight.Model;
using Groovelight.Support;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace Groovelight.Controls;

/// <summary>Up Next (the Mac's QueueView): the song playing, then what comes next, reorderable by dragging.</summary>
public sealed partial class QueuePanel : UserControl
{
    private static AppModel Model => AppModel.Current;
    private readonly StackPanel nowPlaying = new() { Spacing = 4 };
    private readonly ListView upNext = new() { SelectionMode = ListViewSelectionMode.None, CanReorderItems = true, AllowDrop = true, CanDragItems = true, IsItemClickEnabled = false };
    private readonly Button shuffle = new() { Style = Ui.Style("BarButton"), FontSize = 12 };
    private readonly FrameworkElement empty;
    private readonly Brush? foreground;
    private bool rebuilding;

    /// <param name="foreground">White text for Now Playing's dark backdrop; the theme's otherwise.</param>
    public QueuePanel(Brush? foreground = null)
    {
        this.foreground = foreground;
        shuffle.Click += (_, _) => Model.Player.SetShuffle(!Model.Player.IsShuffled);
        var heading = Ui.Grid("*,auto");
        heading.Children.Add(Label("Up Next"));
        heading.Children.Add(shuffle.At(1));
        heading.Margin = new Thickness(12, 8, 8, 0);
        empty = Ui.Unavailable(Glyphs.Queue, "Nothing Queued", "Play an album or use Play Next on a song.");
        var root = Ui.Grid("", "auto,auto,*");
        root.Children.Add(nowPlaying);
        root.Children.Add(heading.At(0, 1));
        root.Children.Add(upNext.At(0, 2));
        root.Children.Add(empty.At(0, 0, rowSpan: 3));
        Content = root;
        upNext.DragItemsCompleted += (_, args) =>
        {
            if (rebuilding || args.DropResult != DataPackageOperation.Move) return;
            // The list's new order, as offsets into the queue.
            var shift = (Model.Player.Queue.CurrentIndex ?? -1) + 1;
            var order = upNext.Items.OfType<ListViewItem>().Select(item => (int)item.Tag).ToList();
            var moved = args.Items.OfType<ListViewItem>().Select(item => (int)item.Tag).ToList();
            if (moved.Count == 0) return;
            var destination = order.IndexOf(moved[0]);
            var before = moved.Count(index => index - shift < destination);
            Model.Player.MoveInQueue(moved, destination + shift + before);
        };
        Loaded += (_, _) => { Model.Player.PropertyChanged += OnPlayerChanged; Rebuild(); };
        Unloaded += (_, _) => Model.Player.PropertyChanged -= OnPlayerChanged;
    }

    private TextBlock Label(string text)
    {
        var label = Ui.Text(text, "StrongText", 13, FontWeights.Bold);
        if (foreground is not null) label.Foreground = foreground;
        return label;
    }

    private void OnPlayerChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName is nameof(PlaybackController.Queue) or nameof(PlaybackController.Current) or nameof(PlaybackController.IsShuffled)) Rebuild();
        else if (args.PropertyName == nameof(PlaybackController.State)) RefreshRows();
    }

    private void Rebuild()
    {
        rebuilding = true;
        var queue = Model.Player.Queue;
        var currentIndex = queue.CurrentIndex ?? -1;
        shuffle.Content = Model.Player.IsShuffled ? "Unshuffle" : "Shuffle";
        nowPlaying.Children.Clear();
        if (queue.Current is { } current)
        {
            nowPlaying.Children.Add(Label("Now Playing").Margin(12, 8, 0, 0));
            nowPlaying.Children.Add(new QueueRow(current, -1, true, foreground));
        }
        upNext.Items.Clear();
        for (var index = currentIndex + 1; index < queue.Items.Count; index++)
        {
            var row = new QueueRow(queue.Items[index], index, false, foreground);
            upNext.Items.Add(new ListViewItem { Content = row, Tag = index, Padding = new Thickness(8, 2, 8, 2), MinHeight = 0 });
        }
        empty.Visibility = queue.Items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        rebuilding = false;
    }

    private void RefreshRows()
    {
        foreach (var row in nowPlaying.Children.OfType<QueueRow>()) row.Refresh();
        foreach (var item in upNext.Items.OfType<ListViewItem>()) (item.Content as QueueRow)?.Refresh();
    }
}

/// <summary>A song in Up Next: cover (click to jump there, or play / pause the current one), title, artist, time.</summary>
public sealed partial class QueueRow : Grid
{
    private readonly int index;
    private readonly bool isCurrent;
    private readonly Border scrim = new() { CornerRadius = new CornerRadius(4), Background = new SolidColorBrush(Windows.UI.Color.FromArgb(102, 0, 0, 0)) };
    private readonly FontIcon icon = new() { FontSize = 12, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White) };
    private bool hovering;

    public QueueRow(PlayableItem item, int index, bool isCurrent, Brush? foreground)
    {
        this.index = index;
        this.isCurrent = isCurrent;
        var model = AppModel.Current;
        ColumnSpacing = 10;
        Padding = new Thickness(isCurrent ? 12 : 4, 5, 8, 5);
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var cover = new Grid { Width = 36, Height = 36 };
        cover.Children.Add(new ArtworkImage { Hash = item.ArtworkHash, Radius = 4 });
        cover.Children.Add(scrim);
        cover.Children.Add(icon);
        var play = new Button { Content = cover, Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = Images.Transparent };
        play.Click += (_, _) => Play();
        Children.Add(play);
        var title = new TextBlock { Text = item.Title, FontSize = 12, FontWeight = isCurrent ? FontWeights.SemiBold : FontWeights.Normal, TextTrimming = TextTrimming.CharacterEllipsis };
        var artist = new TextBlock { Text = item.Artist, FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis, Opacity = 0.65 };
        var time = new TextBlock { Text = Format.Duration(item.Duration), FontSize = 11, Opacity = 0.65, VerticalAlignment = VerticalAlignment.Center };
        if (foreground is not null) title.Foreground = artist.Foreground = time.Foreground = foreground;
        Children.Add(Ui.Column(1, title, artist).With(c => c.VerticalAlignment = VerticalAlignment.Center).At(1));
        Children.Add(time.At(2));
        Background = Images.Transparent;
        PointerEntered += (_, _) => { hovering = true; Refresh(); };
        PointerExited += (_, _) => { hovering = false; Refresh(); };
        DoubleTapped += (_, _) => Play();
        if (!isCurrent)
        {
            ContextRequested += (_, args) =>
            {
                args.Handled = true;
                var menu = Menus.Flyout([
                    Menus.Item("Play", () => model.Player.JumpToQueueIndex(index), Glyphs.Play),
                    Menus.Item("Remove from Up Next", () => model.Player.RemoveFromQueue(index), Glyphs.Delete),
                ]);
                if (args.TryGetPosition(this, out var point)) menu.ShowAt(this, point); else menu.ShowAt(this);
            };
        }
        Refresh();
    }

    private void Play()
    {
        var player = AppModel.Current.Player;
        if (isCurrent) player.TogglePlayPause();
        else player.JumpToQueueIndex(index);
    }

    public void Refresh()
    {
        var playing = AppModel.Current.Player.State == PlaybackState.Playing;
        var shown = hovering || isCurrent;
        scrim.Visibility = icon.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
        icon.Glyph = hovering ? (isCurrent && playing ? Glyphs.Pause : Glyphs.Play) : (playing ? Glyphs.Volume3 : Glyphs.Volume);
    }
}

/// <summary>Lyrics in the right side pane (like Up Next): the song on top, then its lyrics following playback.</summary>
public sealed partial class LyricsSidePanel : UserControl
{
    private static AppModel Model => AppModel.Current;

    public LyricsSidePanel()
    {
        Loaded += (_, _) => { Model.Player.PropertyChanged += OnPlayerChanged; Build(); };
        Unloaded += (_, _) => Model.Player.PropertyChanged -= OnPlayerChanged;
    }

    private PlayableItem? shown;

    private void OnPlayerChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName == nameof(PlaybackController.Current) && Model.Player.Current != shown) Build();
    }

    private void Build()
    {
        shown = Model.Player.Current;
        if (shown is not { } item)
        {
            Content = Ui.Unavailable(Glyphs.Lyrics, "Nothing Playing", "Lyrics of the song that is playing show up here.");
            return;
        }
        var head = Ui.Row(10, new ArtworkImage { Hash = item.ArtworkHash, Width = 40, Height = 40, Radius = 4 },
            Ui.Column(1, Ui.Text(item.Title, "StrongText", 13), Ui.Text(item.Artist, "CaptionText", 11)).With(c => c.VerticalAlignment = VerticalAlignment.Center));
        head.Padding = new Thickness(16, 12, 16, 12);
        var grid = Ui.Grid("", "auto,auto,*");
        grid.Children.Add(head);
        grid.Children.Add(Ui.Separator().At(0, 1));
        grid.Children.Add(new LyricsView(19).With(view => view.Margin = new Thickness(16, 0, 16, 8)).At(0, 2));
        Content = grid;
    }
}
