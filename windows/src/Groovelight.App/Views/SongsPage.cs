using System.ComponentModel;
using Groovelight.Audio;
using Groovelight.Controls;
using Groovelight.Core.Library;
using Groovelight.Model;
using Groovelight.Support;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Windows.System;

namespace Groovelight.Views;

/// <summary>
/// Songs: every song in a table sortable by its column headers (title, artist, album, time, plays, quality), like the
/// Mac's Table. Sorting runs off the UI thread: comparing tens of thousands of titles would freeze the window.
/// </summary>
public sealed partial class SongsPage : PageView
{
    public enum Column { Title, Artist, Album, Genre, Time, Plays, Quality }

    internal static readonly (Column Column, string Name, GridLength Width, bool Sortable)[] Columns =
    [
        (Column.Title, "Title", new GridLength(2, GridUnitType.Star), true),
        (Column.Artist, "Artist", new GridLength(1.3, GridUnitType.Star), true),
        (Column.Album, "Album", new GridLength(1.3, GridUnitType.Star), true),
        (Column.Genre, "Genre", new GridLength(110), false),
        (Column.Time, "Time", new GridLength(64), true),
        (Column.Plays, "Plays", new GridLength(54), true),
        (Column.Quality, "Quality", new GridLength(190), true),
    ];

    private readonly ItemsRepeater repeater = new() { Layout = new StackLayout() };
    private readonly Grid headerRow;
    private readonly HashSet<int> selection = [];
    private int? anchor;
    private List<Track> tracks = [];
    private Column sortColumn = Column.Title;
    private bool descending;

    public SongsPage()
    {
        repeater.ItemTemplate = new Factory(this);
        repeater.ElementPrepared += (_, args) => ((SongRow)args.Element).Bind(tracks[args.Index], args.Index);
        headerRow = MakeHeader();
        var scroll = new ScrollViewer { Content = new Border { Padding = new Thickness(12, 0, 12, 24), Child = repeater } };
        var grid = Ui.Grid("", "auto,*");
        grid.Children.Add(headerRow);
        grid.Children.Add(scroll.At(0, 1));
        Content = grid;
        IsTabStop = true;
        KeyDown += OnKeyDown;
        Loaded += (_, _) => Model.Player.PropertyChanged += OnPlayerChanged;
        Unloaded += (_, _) => Model.Player.PropertyChanged -= OnPlayerChanged;
        Reload();
    }

    public override string Title => $"Songs";

    private void Reload()
    {
        Observations.Dispose();
        var (column, reverse) = (sortColumn, descending);
        Observations.Add(Model.Database, db => Sorted(db.AllTracks(), column, reverse), value =>
        {
            var selectedIds = selection.Where(index => index < tracks.Count).Select(index => tracks[index].Id).ToHashSet();
            tracks = value;
            selection.Clear();
            for (var index = 0; index < tracks.Count; index++) if (selectedIds.Contains(tracks[index].Id)) selection.Add(index);
            repeater.ItemsSource = tracks;
            MainWindow.Current?.RefreshTitle();
        });
    }

    public string Subtitle => Format.Songs(tracks.Count);

    internal static List<Track> Sorted(List<Track> tracks, Column column, bool descending)
    {
        var comparer = StringComparer.Create(System.Globalization.CultureInfo.CurrentCulture, System.Globalization.CompareOptions.IgnoreCase | System.Globalization.CompareOptions.NumericOrdering);
        IOrderedEnumerable<Track> sorted = column switch
        {
            Column.Artist => tracks.OrderBy(track => track.DisplayArtist, comparer),
            Column.Album => tracks.OrderBy(track => track.DisplayAlbum, comparer),
            Column.Time => tracks.OrderBy(track => track.Duration),
            Column.Plays => tracks.OrderByDescending(track => track.PlayCount),
            Column.Quality => tracks.OrderBy(track => QualityRank(track)),
            _ => tracks.OrderBy(track => track.Title, comparer),
        };
        var list = sorted.ThenBy(track => track.Title, comparer).ToList();
        if (descending) list.Reverse();
        return list;
    }

    /// <summary>Sort key for quality: the tier, then the sample rate (the Mac's qualityRank).</summary>
    internal static double QualityRank(Track track)
    {
        var spec = track.AudioSpec;
        return (int)spec.Tier * 10_000_000.0 + (spec.SampleRate ?? 0);
    }

    private Grid MakeHeader()
    {
        var grid = SongRow.MakeColumns();
        grid.Padding = new Thickness(22, 8, 22, 6);
        grid.BorderThickness = new Thickness(0, 0, 0, 1);
        grid.BorderBrush = Ui.Brush("DividerStrokeColorDefaultBrush");
        for (var index = 0; index < Columns.Length; index++)
        {
            var (column, name, _, sortable) = Columns[index];
            var label = Ui.Text(name, "CaptionText", 12, FontWeights.SemiBold);
            FrameworkElement cell = label;
            if (sortable)
            {
                var arrow = Ui.Icon(descending ? Glyphs.ChevronDown : "", 8, "SecondaryIcon");
                arrow.Visibility = column == sortColumn ? Visibility.Visible : Visibility.Collapsed;
                var button = new Button { Style = Ui.Style("BarButton"), Content = Ui.Row(4, label, arrow), Padding = new Thickness(4, 2, 4, 2), MinHeight = 0, HorizontalAlignment = HorizontalAlignment.Left };
                button.Click += (_, _) =>
                {
                    if (sortColumn == column) descending = !descending;
                    else { sortColumn = column; descending = false; }
                    var fresh = MakeHeader();
                    var parent = (Grid)headerRow.Parent;
                    parent.Children.Remove(parent.Children[0]);
                    parent.Children.Insert(0, fresh);
                    Reload();
                };
                cell = button;
            }
            Grid.SetColumn(cell, index + 1);
            grid.Children.Add(cell);
        }
        return grid;
    }

    internal bool IsSelected(int index) => selection.Contains(index);

    internal IReadOnlyList<Track> MenuTracks(int index) =>
        selection.Contains(index) && selection.Count > 1 ? selection.Order().Select(i => tracks[i]).ToList() : [tracks[index]];

    internal void Play(int index) => Model.Play(tracks, index);

    internal void Select(int index, bool toggle, bool range)
    {
        if (range && anchor is { } start)
        {
            selection.Clear();
            for (var i = Math.Min(start, index); i <= Math.Max(start, index); i++) selection.Add(i);
        }
        else if (toggle)
        {
            if (!selection.Remove(index)) selection.Add(index);
            anchor = index;
        }
        else
        {
            selection.Clear();
            selection.Add(index);
            anchor = index;
        }
        Refresh();
        Focus(FocusState.Programmatic);
    }

    internal MenuFlyout Menu(int index)
    {
        if (!selection.Contains(index)) Select(index, false, false);
        return Menus.Flyout(Menus.TrackItems(MenuTracks(index)));
    }

    private void Refresh()
    {
        for (var index = 0; index < tracks.Count; index++) if (repeater.TryGetElement(index) is SongRow row) row.Refresh();
    }

    private void OnPlayerChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName is nameof(PlaybackController.Current) or nameof(PlaybackController.State)) Refresh();
    }

    private void OnKeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs args)
    {
        if (tracks.Count == 0) return;
        var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        var ctrl = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        var current = anchor ?? -1;
        int? target = args.Key switch
        {
            VirtualKey.Down when !ctrl => Math.Min(current + 1, tracks.Count - 1),
            VirtualKey.Up when !ctrl => Math.Max(current - 1, 0),
            VirtualKey.PageDown => Math.Min(current + 15, tracks.Count - 1),
            VirtualKey.PageUp => Math.Max(current - 15, 0),
            _ => null,
        };
        if (target is { } index)
        {
            Select(index, false, shift);
            repeater.GetOrCreateElement(index).StartBringIntoView();
            args.Handled = true;
        }
        else if (args.Key == VirtualKey.Enter && selection.Count > 0)
        {
            Play(selection.Min());
            args.Handled = true;
        }
        else if (args.Key == VirtualKey.A && ctrl)
        {
            for (var i = 0; i < tracks.Count; i++) selection.Add(i);
            Refresh();
            args.Handled = true;
        }
    }

    private sealed partial class Factory(SongsPage owner) : IElementFactory
    {
        private readonly Stack<SongRow> recycled = new();
        public UIElement GetElement(ElementFactoryGetArgs args) => recycled.Count > 0 ? recycled.Pop() : new SongRow(owner);
        public void RecycleElement(ElementFactoryRecycleArgs args) { if (args.Element is SongRow row) recycled.Push(row); }
    }
}

/// <summary>A row of the Songs table.</summary>
public sealed partial class SongRow : Grid
{
    private readonly SongsPage owner;
    private readonly Border background = new() { CornerRadius = new CornerRadius(4) };
    private readonly FontIcon status = new() { FontSize = 11, HorizontalAlignment = HorizontalAlignment.Center };
    private readonly TextBlock title = new() { Style = Ui.Style("BodyText"), FontSize = 13 };
    private readonly Button more;
    private readonly TextBlock artist = Cell(), album = Cell(), genre = Cell(), time = Cell(), plays = Cell();
    private readonly StackPanel quality = new() { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
    private Track? track;
    private int index;
    private bool hovering;

    private static TextBlock Cell() => new() { Style = Ui.Style("BodyText"), FontSize = 13, VerticalAlignment = VerticalAlignment.Center };

    internal static Grid MakeColumns()
    {
        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
        foreach (var column in SongsPage.Columns) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = column.Width });
        return grid;
    }

    public SongRow(SongsPage owner)
    {
        this.owner = owner;
        ColumnSpacing = 10;
        Padding = new Thickness(10, 4, 10, 4);
        MinHeight = 32;
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
        foreach (var column in SongsPage.Columns) ColumnDefinitions.Add(new ColumnDefinition { Width = column.Width });
        Children.Add(background);
        SetColumnSpan(background, ColumnDefinitions.Count);
        background.Margin = new Thickness(-10, -4, -10, -4);
        Children.Add(status);
        more = new Button { Style = Ui.Style("BarButton"), Content = Ui.Icon(Glyphs.More, 12), MinWidth = 24, MinHeight = 22, Padding = new Thickness(2) };
        ToolTipService.SetToolTip(more, "More");
        more.Click += (_, _) => owner.Menu(index).ShowAt(more, new FlyoutShowOptions { Placement = FlyoutPlacementMode.BottomEdgeAlignedRight });
        var titleCell = Ui.Grid("*,auto");
        titleCell.Children.Add(title.With(t => t.VerticalAlignment = VerticalAlignment.Center));
        titleCell.Children.Add(more.At(1));
        Children.Add(titleCell.At(1));
        Children.Add(artist.At(2));
        Children.Add(album.At(3));
        Children.Add(genre.At(4));
        Children.Add(time.At(5));
        Children.Add(plays.At(6));
        Children.Add(quality.At(7));
        time.FontFeatures();
        Background = Images.Transparent;
        PointerEntered += (_, _) => { hovering = true; Refresh(); };
        PointerExited += (_, _) => { hovering = false; Refresh(); };
        Tapped += (_, _) =>
        {
            var ctrl = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            owner.Select(index, ctrl, shift);
        };
        DoubleTapped += (_, _) => owner.Play(index);
        ContextRequested += (_, args) =>
        {
            args.Handled = true;
            var menu = owner.Menu(index);
            if (args.TryGetPosition(this, out var point)) menu.ShowAt(this, point); else menu.ShowAt(this);
        };
        CanDrag = true;
        DragStarting += (_, args) =>
        {
            var chosen = owner.MenuTracks(index);
            TrackList.SetDragData(args.Data, chosen.Select(song => song.Id).OfType<long>());
            args.Data.Properties.Title = chosen.Count == 1 ? chosen[0].Title : $"{chosen.Count} songs";
        };
    }

    public void Bind(Track song, int position)
    {
        track = song;
        index = position;
        title.Text = song.Title;
        artist.Text = song.DisplayArtist;
        album.Text = song.DisplayAlbum;
        genre.Text = song.Genre ?? "";
        time.Text = Format.Duration(song.Duration);
        plays.Text = Format.Plays(song.PlayCount);
        quality.Children.Clear();
        var spec = song.AudioSpec;
        if (QualityBadge.HasBadge(spec.Tier)) quality.Children.Add(new QualityBadge(spec.Tier, isMini: true));
        quality.Children.Add(new TextBlock { Text = spec.CompactText, Style = Ui.Style("CaptionText") });
        ToolTipService.SetToolTip(quality, spec.Tier == QualityTier.Standard ? spec.Summary : $"{spec.Tier.DisplayName()} · {spec.Summary}");
        Refresh();
    }

    public void Refresh()
    {
        if (track is null) return;
        var player = AppModel.Current.Player;
        var isCurrent = player.Current?.Id == track.Id;
        var selected = owner.IsSelected(index);
        background.Style = selected ? Ui.Style("RowSelectedBorder") : hovering ? Ui.Style("RowHoverBorder") : null;
        if (!selected && !hovering) background.Background = null;
        more.Visibility = hovering || selected ? Visibility.Visible : Visibility.Collapsed;
        if (isCurrent)
        {
            status.Glyph = Glyphs.Volume3;
            status.Style = Ui.Style("BrandIcon");
            status.Visibility = Visibility.Visible;
        }
        else if (track.IsLoved)
        {
            status.Glyph = Glyphs.HeartFilled;
            status.Style = null;
            status.Foreground = Ui.Brush("LoveBrush");
            status.FontSize = 10;
            status.Visibility = Visibility.Visible;
        }
        else status.Visibility = Visibility.Collapsed;
    }
}
