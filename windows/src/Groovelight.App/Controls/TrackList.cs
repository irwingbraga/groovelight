using System.ComponentModel;
using Groovelight.Audio;
using Groovelight.Core.Library;
using Groovelight.Model;
using Groovelight.Support;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace Groovelight.Controls;

public enum TrackListStyle { Album, Playlist }

/// <summary>
/// Vertical song list used by album, playlist, artist and genre pages (the Mac's TrackList): virtualized rows with the
/// number (albums) or the song's cover (playlists), play on the leading cell or a double click, selection with Ctrl and
/// Shift, the "⋯" menu, and dragging songs onto playlists and devices. Put it in a ScrollViewer (it virtualizes there).
/// </summary>
public sealed partial class TrackList : UserControl
{
    private readonly ItemsRepeater repeater = new();
    private readonly HashSet<int> selection = [];
    private int? anchor;
    private IReadOnlyList<Track> tracks = [];
    private readonly RowFactory factory;

    public TrackListStyle ListStyle { get; init; } = TrackListStyle.Album;
    /// <summary>Show each row's format and resolution (when an album mixes configurations).</summary>
    public bool ShowsQuality { get; set; }
    /// <summary>Tighter rows (the Shelf's flipped cover).</summary>
    public bool IsCompact { get; init; }
    /// <summary>Album the list belongs to: its songs' menus skip "Go to Album".</summary>
    public string? AlbumKey { get; set; }
    /// <summary>Extra menu items for the selected songs (a playlist's Remove from Playlist).</summary>
    public Func<IReadOnlyList<Track>, IEnumerable<MenuFlyoutItemBase>>? ExtraMenuItems { get; set; }
    /// <summary>Plays from a row; by default the list's songs from that row.</summary>
    public Action<int>? PlayAction { get; set; }
    /// <summary>Rows can be reordered by dragging (a playlist): the moved indexes and the destination.</summary>
    public Action<IReadOnlyList<int>, int>? Reorder { get; set; }

    public TrackList()
    {
        factory = new RowFactory(this);
        repeater.ItemTemplate = factory;
        repeater.Layout = new StackLayout();
        repeater.ElementPrepared += (_, args) => ((TrackRow)args.Element).Bind(this, (Track)tracks[args.Index], args.Index);
        Content = repeater;
        Loaded += (_, _) => AppModel.Current.Player.PropertyChanged += OnPlayerChanged;
        Unloaded += (_, _) => AppModel.Current.Player.PropertyChanged -= OnPlayerChanged;
        KeyDown += OnKeyDown;
        IsTabStop = true;
        AllowDrop = true;
        DragOver += OnDragOver;
        Drop += OnDrop;
    }

    public IReadOnlyList<Track> Tracks
    {
        get => tracks;
        set
        {
            // Keep the selection on the same songs when the list updates in place.
            var selectedIds = SelectedTracks.Select(track => track.Id).ToHashSet();
            tracks = value;
            selection.Clear();
            for (var index = 0; index < tracks.Count; index++) if (selectedIds.Contains(tracks[index].Id)) selection.Add(index);
            repeater.ItemsSource = tracks.ToList();
        }
    }

    public IReadOnlyList<Track> SelectedTracks => selection.Order().Where(index => index < tracks.Count).Select(index => tracks[index]).ToList();

    internal bool IsSelected(int index) => selection.Contains(index);

    /// <summary>The selected songs when <paramref name="index"/> is one of several selected, otherwise its song.</summary>
    internal IReadOnlyList<Track> MenuTracks(int index) =>
        selection.Contains(index) && selection.Count > 1 ? SelectedTracks : [tracks[index]];

    internal void Play(int index)
    {
        if (PlayAction is { } action) action(index);
        else AppModel.Current.Play(tracks, index);
    }

    internal void PlayOrToggle(int index)
    {
        var model = AppModel.Current;
        if (model.Player.Current?.Id == tracks[index].Id) model.Player.TogglePlayPause();
        else Play(index);
    }

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
        RefreshRows();
        Focus(FocusState.Programmatic);
    }

    internal MenuFlyout Menu(int index)
    {
        if (!selection.Contains(index)) Select(index, false, false);
        var chosen = MenuTracks(index);
        var items = Menus.TrackItems(chosen, AlbumKey).ToList();
        if (ExtraMenuItems?.Invoke(chosen) is { } extra)
        {
            var more = extra.ToList();
            if (more.Count > 0)
            {
                items.Add(new MenuFlyoutSeparator());
                items.AddRange(more);
            }
        }
        return Menus.Flyout(items);
    }

    private void OnPlayerChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName is nameof(PlaybackController.Current) or nameof(PlaybackController.State)) RefreshRows();
    }

    internal void RefreshRows()
    {
        for (var index = 0; index < tracks.Count; index++)
        {
            if (repeater.TryGetElement(index) is TrackRow row) row.Refresh();
        }
    }

    private void OnKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (tracks.Count == 0) return;
        var ctrl = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        var current = anchor ?? -1;
        switch (args.Key)
        {
            case VirtualKey.Down when !ctrl:
                Select(Math.Min(current + 1, tracks.Count - 1), false, shift);
                repeater.GetOrCreateElement(anchor ?? 0).StartBringIntoView();
                args.Handled = true;
                break;
            case VirtualKey.Up when !ctrl:
                Select(Math.Max(current - 1, 0), false, shift);
                repeater.GetOrCreateElement(anchor ?? 0).StartBringIntoView();
                args.Handled = true;
                break;
            case VirtualKey.Enter when selection.Count > 0:
                Play(selection.Min());
                args.Handled = true;
                break;
            case VirtualKey.A when ctrl:
                selection.Clear();
                for (var index = 0; index < tracks.Count; index++) selection.Add(index);
                RefreshRows();
                args.Handled = true;
                break;
        }
    }

    // MARK: Dragging

    public const string TracksFormat = "Groovelight.Tracks";

    /// <summary>Puts songs on a drag (ids, and the album key when a whole album is dragged).</summary>
    public static void SetDragData(DataPackage data, IEnumerable<long> ids, string? albumKey = null)
    {
        data.SetData(TracksFormat, string.Join(",", ids) + (albumKey is null ? "" : "|" + albumKey));
        data.RequestedOperation = DataPackageOperation.Copy | DataPackageOperation.Move;
    }

    /// <summary>The songs of a drag from inside the app, if any.</summary>
    public static async Task<(List<long> Ids, string? AlbumKey)?> ReadDragDataAsync(DataPackageView view)
    {
        if (!view.Contains(TracksFormat)) return null;
        var text = await view.GetDataAsync(TracksFormat) as string ?? "";
        var parts = text.Split('|', 2);
        var ids = parts[0].Split(',', StringSplitOptions.RemoveEmptyEntries).Select(long.Parse).ToList();
        return (ids, parts.Length > 1 ? parts[1] : null);
    }

    internal int? dragSource;

    private void OnDragOver(object sender, DragEventArgs args)
    {
        if (Reorder is null || dragSource is null) return;
        args.AcceptedOperation = DataPackageOperation.Move;
        args.DragUIOverride.Caption = "Move";
    }

    private void OnDrop(object sender, DragEventArgs args)
    {
        if (Reorder is not { } reorder || dragSource is null) return;
        // The row under the pointer: the moved songs go before it.
        var position = args.GetPosition(repeater);
        var destination = tracks.Count;
        for (var index = 0; index < tracks.Count; index++)
        {
            if (repeater.TryGetElement(index) is not FrameworkElement row) continue;
            var top = row.TransformToVisual(repeater).TransformPoint(new Windows.Foundation.Point(0, 0)).Y;
            if (position.Y < top + row.ActualHeight / 2) { destination = index; break; }
        }
        var moved = selection.Contains(dragSource.Value) ? selection.Order().ToList() : [dragSource.Value];
        dragSource = null;
        selection.Clear();
        reorder(moved, destination);
    }

    private sealed partial class RowFactory(TrackList owner) : IElementFactory
    {
        private readonly Stack<TrackRow> recycled = new();

        public UIElement GetElement(ElementFactoryGetArgs args) => recycled.Count > 0 ? recycled.Pop() : new TrackRow(owner.ListStyle, owner.IsCompact);

        public void RecycleElement(ElementFactoryRecycleArgs args)
        {
            if (args.Element is TrackRow row) recycled.Push(row);
        }
    }
}

/// <summary>One song in a <see cref="TrackList"/> (the Mac's TrackRow).</summary>
public sealed partial class TrackRow : Grid
{
    public const double PlayCellWidth = 34;
    public const double ArtworkSize = 34;

    private readonly TrackListStyle style;
    private readonly Border background = new() { CornerRadius = new CornerRadius(6) };
    private readonly TextBlock number = new() { Style = Ui.Style("CaptionText"), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly FontIcon playIcon = new() { FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly ArtworkImage? artwork;
    private readonly Border? coverScrim;
    private readonly FontIcon? coverIcon;
    private readonly TextBlock title;
    private readonly TextBlock subtitle;
    private readonly StackPanel quality = new() { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
    private readonly FontIcon heart = new() { Glyph = Glyphs.HeartFilled, FontSize = 10, Foreground = Ui.Brush("LoveBrush"), VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock duration = new() { Style = Ui.Style("CaptionText"), VerticalAlignment = VerticalAlignment.Center };
    private readonly Button more;
    private readonly Grid playTarget = new() { Background = Images.Transparent };
    private TrackList? owner;
    private Track? track;
    private int index;
    private bool isHovering;
    private bool isHoveringPlayTarget;

    public TrackRow(TrackListStyle style, bool isCompact)
    {
        this.style = style;
        title = new TextBlock { Style = Ui.Style("BodyText"), FontSize = isCompact ? 12 : 13 };
        subtitle = new TextBlock { Style = Ui.Style("CaptionText"), FontSize = 11 };
        Padding = new Thickness(10, isCompact ? 5 : style == TrackListStyle.Album ? 9 : 6, 10, isCompact ? 5 : style == TrackListStyle.Album ? 9 : 6);
        ColumnSpacing = 12;
        foreach (var width in new[] { GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto, GridLength.Auto, GridLength.Auto, GridLength.Auto })
            ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        Children.Add(background);
        SetColumnSpan(background, 6);
        background.Margin = new Thickness(-10, -Padding.Top, -10, -Padding.Bottom);

        if (style == TrackListStyle.Album)
        {
            var cell = new Grid { Width = PlayCellWidth, Height = 22 };
            cell.Children.Add(number);
            cell.Children.Add(playIcon);
            Children.Add(cell);
        }
        else
        {
            artwork = new ArtworkImage { Width = ArtworkSize, Height = ArtworkSize, Radius = 4 };
            coverScrim = new Border { CornerRadius = new CornerRadius(4), Background = new SolidColorBrush(Windows.UI.Color.FromArgb(102, 0, 0, 0)) };
            coverIcon = new FontIcon { FontSize = 13, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White) };
            var cell = new Grid { Width = ArtworkSize, Height = ArtworkSize };
            cell.Children.Add(artwork);
            cell.Children.Add(coverScrim);
            cell.Children.Add(coverIcon);
            Children.Add(cell);
        }

        var text = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(title);
        text.Children.Add(subtitle);
        Children.Add(text.At(1));
        Children.Add(quality.At(2));
        Children.Add(heart.At(3));
        Children.Add(duration.At(4));
        more = new Button { Style = Ui.Style("BarButton"), Content = Ui.Icon(Glyphs.More, 13), MinWidth = 26, MinHeight = 26, Padding = new Thickness(2) };
        ToolTipService.SetToolTip(more, "More");
        more.Click += (_, _) => owner?.Menu(index).ShowAt(more, new FlyoutShowOptions { Placement = FlyoutPlacementMode.BottomEdgeAlignedRight });
        Children.Add(more.At(5));

        // The play target: the whole leading strip (padding plus the number column or the cover, full row height).
        playTarget.Width = 10 + (style == TrackListStyle.Album ? PlayCellWidth : ArtworkSize);
        playTarget.HorizontalAlignment = HorizontalAlignment.Left;
        playTarget.Margin = new Thickness(-10, -Padding.Top, 0, -Padding.Bottom);
        SetColumnSpan(playTarget, 2);
        Children.Add(playTarget);
        playTarget.PointerEntered += (_, _) => { isHoveringPlayTarget = true; Refresh(); };
        playTarget.PointerExited += (_, _) => { isHoveringPlayTarget = false; Refresh(); };
        playTarget.Tapped += (_, args) =>
        {
            args.Handled = true;
            owner?.PlayOrToggle(index);
        };
        playTarget.DoubleTapped += (_, args) => args.Handled = true;

        Background = Images.Transparent;
        PointerEntered += (_, _) => { isHovering = true; Refresh(); };
        PointerExited += (_, _) => { isHovering = false; Refresh(); };
        Tapped += (_, _) =>
        {
            var ctrl = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
            owner?.Select(index, ctrl, shift);
        };
        DoubleTapped += (_, _) => owner?.Play(index);
        ContextRequested += (_, args) =>
        {
            if (owner is null) return;
            args.Handled = true;
            var menu = owner.Menu(index);
            if (args.TryGetPosition(this, out var point)) menu.ShowAt(this, point);
            else menu.ShowAt(this);
        };
        CanDrag = true;
        DragStarting += (_, args) =>
        {
            if (owner is null || track is null) return;
            owner.dragSource = index;
            var chosen = owner.MenuTracks(index);
            TrackList.SetDragData(args.Data, chosen.Select(song => song.Id).OfType<long>());
            args.DragUI.SetContentFromDataPackage();
            args.Data.Properties.Title = chosen.Count == 1 ? chosen[0].Title : $"{chosen.Count} songs";
        };
    }

    public void Bind(TrackList list, Track song, int position)
    {
        owner = list;
        track = song;
        index = position;
        title.Text = song.Title;
        number.Text = song.TrackNumber?.ToString() ?? "";
        if (artwork is not null) artwork.Hash = song.ArtworkHash;
        // A compilation's songs name their artists even without an album artist set.
        var showsArtist = style == TrackListStyle.Playlist
            || (song.Artist is not null && song.Artist != song.AlbumArtist && (song.AlbumArtist is not null || song.IsCompilation));
        subtitle.Text = style == TrackListStyle.Playlist ? Format.ArtistAndAlbum(song) : song.DisplayArtist;
        subtitle.Visibility = showsArtist ? Visibility.Visible : Visibility.Collapsed;
        heart.Visibility = song.IsLoved ? Visibility.Visible : Visibility.Collapsed;
        duration.Text = Format.Duration(song.Duration);
        quality.Children.Clear();
        if (list.ShowsQuality)
        {
            var spec = song.AudioSpec;
            if (QualityBadge.HasBadge(spec.Tier)) quality.Children.Add(new QualityBadge(spec.Tier, isMini: true));
            quality.Children.Add(new TextBlock { Text = spec.CompactText, Style = Ui.Style("CaptionText"), FontSize = 11 });
        }
        Refresh();
    }

    public void Refresh()
    {
        if (owner is null || track is null) return;
        var player = AppModel.Current.Player;
        var isCurrent = player.Current?.Id == track.Id;
        var isPlaying = player.State == PlaybackState.Playing;
        var isSelected = owner.IsSelected(index);
        var hovered = isHovering || isHoveringPlayTarget;
        title.FontWeight = isCurrent ? FontWeights.SemiBold : FontWeights.Normal;
        background.Style = isSelected ? Ui.Style("RowSelectedBorder") : hovered ? Ui.Style("RowHoverBorder") : null;
        if (!isSelected && !hovered) background.Background = null;
        more.Opacity = hovered || isSelected ? 1 : 0;
        if (style == TrackListStyle.Album)
        {
            number.Visibility = !hovered && !isCurrent ? Visibility.Visible : Visibility.Collapsed;
            playIcon.Visibility = hovered || isCurrent ? Visibility.Visible : Visibility.Collapsed;
            playIcon.Glyph = hovered ? (isCurrent && isPlaying ? Glyphs.Pause : Glyphs.Play) : (isPlaying ? Glyphs.Volume3 : Glyphs.Volume);
            playIcon.Style = isCurrent ? Ui.Style("BrandIcon") : null;
            if (!isCurrent) playIcon.ClearValue(FontIcon.ForegroundProperty);
        }
        else if (coverScrim is not null && coverIcon is not null)
        {
            var shown = hovered || isCurrent;
            coverScrim.Visibility = coverIcon.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
            coverScrim.Opacity = isHoveringPlayTarget ? 1.35 : 1;
            coverIcon.Glyph = hovered ? (isCurrent && isPlaying ? Glyphs.Pause : Glyphs.Play) : (isPlaying ? Glyphs.Volume3 : Glyphs.Volume);
        }
        ToolTipService.SetToolTip(playTarget, isCurrent && isPlaying ? "Pause" : "Play");
    }
}
