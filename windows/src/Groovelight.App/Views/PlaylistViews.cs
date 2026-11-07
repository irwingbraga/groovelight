using Groovelight.Controls;
using Groovelight.Core.Library;
using Groovelight.Model;
using Groovelight.Support;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace Groovelight.Views;

/// <summary>The cover of the built-in Loved Songs playlist: a pink gradient with a heart.</summary>
public static class LovedSongsCover
{
    public static FrameworkElement Make(double radius = 10)
    {
        var grid = new Grid { CornerRadius = new CornerRadius(radius) };
        grid.Children.Add(new Border
        {
            Background = new LinearGradientBrush
            {
                StartPoint = new Windows.Foundation.Point(0, 0), EndPoint = new Windows.Foundation.Point(1, 1),
                GradientStops =
                {
                    new GradientStop { Color = Windows.UI.Color.FromArgb(255, 255, 107, 140), Offset = 0 },
                    new GradientStop { Color = Windows.UI.Color.FromArgb(255, 219, 31, 92), Offset = 1 },
                },
            },
        });
        var heart = new FontIcon { Glyph = Glyphs.HeartFilled, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White) };
        grid.SizeChanged += (_, args) => heart.FontSize = Math.Max(8, args.NewSize.Width * 0.38);
        grid.Children.Add(heart);
        return grid;
    }
}

/// <summary>A playlist in the All Playlists grid: cover with Play and Shuffle on hover, name and song count.</summary>
public sealed partial class PlaylistCard : StackPanel
{
    public PlaylistCard(string title, string subtitle, FrameworkElement cover, Action open, Action<bool> play, Func<IEnumerable<MenuFlyoutItemBase>> menu)
    {
        Spacing = 6;
        Width = 190;
        var holder = new Grid();
        holder.SizeChanged += (_, args) => holder.Height = args.NewSize.Width;
        holder.Children.Add(cover);
        cover.Translation = new System.Numerics.Vector3(0, 0, 8);
        cover.Shadow = new ThemeShadow();
        var buttons = new Grid { Padding = new Thickness(8), VerticalAlignment = VerticalAlignment.Bottom, Opacity = 0, OpacityTransition = new ScalarTransition() };
        var playButton = Ui.IconButton(Glyphs.Play, "Play", () => play(false), 14, "CircleButton");
        var shuffleButton = Ui.IconButton(Glyphs.Shuffle, "Shuffle", () => play(true), 14, "CircleButton");
        shuffleButton.HorizontalAlignment = HorizontalAlignment.Right;
        foreach (var button in new[] { playButton, shuffleButton }) button.Background = Ui.Brush("AcrylicInAppFillColorDefaultBrush");
        buttons.Children.Add(playButton);
        buttons.Children.Add(shuffleButton);
        holder.Children.Add(buttons);
        Children.Add(holder);
        Children.Add(Ui.Text(title, "BodyText", 13, FontWeights.Medium));
        Children.Add(Ui.Text(subtitle, "CaptionText"));
        Background = Images.Transparent;
        PointerEntered += (_, _) => buttons.Opacity = 1;
        PointerExited += (_, _) => buttons.Opacity = 0;
        Tapped += (_, args) =>
        {
            if (args.OriginalSource is FrameworkElement source && (IsWithin(source, playButton) || IsWithin(source, shuffleButton))) return;
            open();
        };
        ContextRequested += (_, args) =>
        {
            args.Handled = true;
            var flyout = Menus.Flyout(menu());
            if (args.TryGetPosition(this, out var point)) flyout.ShowAt(this, point); else flyout.ShowAt(this);
        };
    }

    private static bool IsWithin(DependencyObject element, DependencyObject container)
    {
        for (var current = element; current is not null; current = VisualTreeHelper.GetParent(current)) if (current == container) return true;
        return false;
    }
}

/// <summary>Every playlist as a grid of cards: Loved Songs first, then the playlists by name.</summary>
public sealed partial class AllPlaylistsPage : PageView
{
    private readonly VariableSizedWrapGrid grid = new() { Orientation = Orientation.Horizontal, ItemWidth = 212, ItemHeight = 262 };

    public AllPlaylistsPage()
    {
        Content = Scroll(grid, 24);
        Observations.Add(Model.Database, db => db.PlaylistOverview(), Build);
    }

    public override string Title => "All Playlists";

    private void Build(PlaylistOverview overview)
    {
        grid.Children.Clear();
        grid.Children.Add(new PlaylistCard("Loved Songs", Format.Songs(overview.LovedCount), LovedSongsCover.Make(),
            () => Model.Selection = SidebarItem.LovedSongs,
            shuffle => Model.Play(new SongSource.LovedSongs(), shuffle),
            () => new MenuFlyoutItemBase[]
            {
                Menus.Item("Play", () => Model.Play(new SongSource.LovedSongs()), Glyphs.Play),
                Menus.Item("Shuffle", () => Model.Play(new SongSource.LovedSongs(), true), Glyphs.Shuffle),
            }.Concat(Menus.QueueItems(new SongSource.LovedSongs()))));
        foreach (var summary in overview.Playlists)
        {
            var playlist = summary.Playlist;
            var cover = new PlaylistCoverImage { Radius = 10 };
            cover.Set(playlist.Name, playlist.CoverStyle, summary.ArtworkHashes, summary.Id, playlist.IsSmart);
            var subtitle = playlist.IsSmart ? $"Smart Playlist · {Format.Songs(summary.TrackCount)}" : Format.Songs(summary.TrackCount);
            grid.Children.Add(new PlaylistCard(playlist.Name, subtitle, cover,
                () => Model.Selection = SidebarItem.Playlist(summary.Id),
                shuffle => Model.PlayPlaylist(summary.Id, shuffle),
                () => PlaylistMenu(playlist, summary.Id, includePlay: true)));
        }
    }

    internal static IEnumerable<MenuFlyoutItemBase> PlaylistMenu(Playlist playlist, long id, bool includePlay)
    {
        var model = AppModel.Current;
        if (includePlay)
        {
            yield return Menus.Item("Play", () => model.PlayPlaylist(id), Glyphs.Play);
            yield return Menus.Item("Shuffle", () => model.PlayPlaylist(id, true), Glyphs.Shuffle);
        }
        foreach (var item in Menus.QueueItems(new SongSource.Playlist(id))) yield return item;
        yield return new MenuFlyoutSeparator();
        yield return Menus.Item("Edit Playlist…", () => model.EditPlaylist(playlist), Glyphs.Edit);
        if (playlist.IsSmart) yield return Menus.Item("Edit Rules…", () => model.EditSmartPlaylist(playlist), Glyphs.Smart);
        yield return Menus.Item("Export Playlist…", () => model.Request(new DialogRequest.ExportPlaylist(id)), Glyphs.Export);
        yield return Menus.Item("Delete Playlist", async () =>
        {
            if (MainWindow.Current is { } window && await Ui.Confirm(window.RootXamlRoot, $"Delete “{playlist.Name}”?",
                    "The playlist is deleted. Its songs stay in your library.", "Delete", destructive: true))
                model.DeletePlaylist(id);
        }, Glyphs.Delete);
    }

    public override IEnumerable<UIElement> Toolbar()
    {
        yield return NewPlaylistButton();
    }

    /// <summary>"New Playlist" with a menu for a smart playlist.</summary>
    internal static UIElement NewPlaylistButton()
    {
        var model = AppModel.Current;
        var button = new SplitButton { Content = Ui.Row(6, Ui.Icon(Glyphs.Add, 12), new TextBlock { Text = "New Playlist" }) };
        button.Click += (_, _) => model.NewPlaylist();
        button.Flyout = Menus.Flyout([
            Menus.Item("New Playlist", () => model.NewPlaylist(), Glyphs.AddToPlaylist),
            Menus.Item("New Smart Playlist…", model.NewSmartPlaylist, Glyphs.Smart),
        ]);
        return button;
    }
}

/// <summary>A playlist's page (or Loved Songs): its cover, name, length, rules, Play and Shuffle, then its songs.</summary>
public sealed partial class PlaylistPage : PageView
{
    private readonly long? playlistId;
    private readonly TrackList list = new() { ListStyle = TrackListStyle.Playlist };
    private readonly StackPanel body = new() { Spacing = 20 };
    private readonly Grid header = Ui.Grid("auto,*");
    private readonly Grid page = new();
    private readonly Border dropHighlight = new() { CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(2), Opacity = 0, IsHitTestVisible = false };
    private Playlist? playlist;
    private List<Track> tracks = [];

    /// <summary><paramref name="playlistId"/>: null for Loved Songs.</summary>
    public PlaylistPage(long? playlistId)
    {
        this.playlistId = playlistId;
        header.ColumnSpacing = 24;
        body.Children.Add(header);
        body.Children.Add(list);
        page.Children.Add(new Grid());
        page.Children.Add(Scroll(body, 28));
        dropHighlight.BorderBrush = Ui.Brush("BrandBrush");
        page.Children.Add(dropHighlight);
        Content = page;
        if (playlistId is { } id)
        {
            list.ExtraMenuItems = chosen => playlist?.IsSmart == true ? [] : [Menus.Item("Remove from Playlist", () => Remove(chosen), Glyphs.Delete)];
            list.Reorder = (moved, destination) =>
            {
                var order = tracks.Select(track => track.Id!.Value).ToList();
                var movedIds = moved.Select(index => order[index]).ToList();
                var before = moved.Count(index => index < destination);
                foreach (var index in moved.OrderDescending()) order.RemoveAt(index);
                order.InsertRange(Math.Clamp(destination - before, 0, order.Count), movedIds);
                Model.Database.SetPlaylistTracks(id, order);
            };
            Observations.Add(Model.Database, db => (db.FetchPlaylist(id), db.TracksOfPlaylist(id)), value =>
            {
                playlist = value.Item1;
                tracks = value.Item2;
                if (playlist?.IsSmart == true) list.Reorder = null;
                Show();
            });
        }
        else
        {
            Observations.Add(Model.Database, db => db.LovedTracks(), value =>
            {
                tracks = value;
                Show();
            });
        }
        // Songs dropped here join the playlist (Loved Songs: they are loved).
        AllowDrop = true;
        DragOver += (_, args) =>
        {
            if (!args.DataView.Contains(TrackList.TracksFormat) || playlist?.IsSmart == true || list.dragSource is not null) return;
            args.AcceptedOperation = DataPackageOperation.Copy;
            args.DragUIOverride.Caption = playlistId is null ? "Love" : "Add to Playlist";
            dropHighlight.Opacity = 1;
        };
        DragLeave += (_, _) => dropHighlight.Opacity = 0;
        Drop += async (_, args) =>
        {
            dropHighlight.Opacity = 0;
            if (list.dragSource is not null || await TrackList.ReadDragDataAsync(args.DataView) is not { } data) return;
            if (playlistId is { } target) Model.Database.AddTracks(data.Ids, target);
            else Model.Love(data.Ids);
        };
    }

    public override string Title => playlistId is null ? "Loved Songs" : playlist?.Name ?? "Playlist";

    private void Remove(IReadOnlyList<Track> chosen)
    {
        if (playlistId is not { } id) return;
        var removed = chosen.Select(track => track.Id).ToHashSet();
        // One occurrence of each chosen song (a playlist can hold a song twice).
        var remaining = new List<long>();
        var dropped = new HashSet<long?>();
        foreach (var track in tracks)
        {
            if (removed.Contains(track.Id) && dropped.Add(track.Id)) continue;
            remaining.Add(track.Id!.Value);
        }
        Model.Database.SetPlaylistTracks(id, remaining);
    }

    /// <summary>Distinct covers of the songs, in playlist order.</summary>
    private List<string> SongHashes => tracks.Select(track => track.ArtworkHash).OfType<string>().Distinct().Take(4).ToList();

    private void Show()
    {
        list.Tracks = tracks;
        _ = ShowWashAsync();
        header.Children.Clear();
        FrameworkElement cover;
        if (playlist is { } current)
        {
            var image = new PlaylistCoverImage { Radius = 12 };
            image.Set(current.Name, current.CoverStyle, SongHashes, current.Id ?? 0, current.IsSmart);
            var button = new Button { Content = image, Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = Images.Transparent };
            ToolTipService.SetToolTip(button, "Edit Playlist");
            button.Flyout = Menus.Flyout(EditItems(current));
            cover = button;
        }
        else cover = LovedSongsCover.Make(12);
        cover.Width = cover.Height = 200;
        cover.Translation = new System.Numerics.Vector3(0, 0, 24);
        cover.Shadow = new ThemeShadow();
        header.Children.Add(cover);
        var info = Ui.Column(8, Ui.Text(Title, "PageTitleText"), Ui.Text($"{Format.Songs(tracks.Count)}, {Format.LongDuration(tracks.Sum(track => track.Duration))}", "SecondaryText"));
        if (playlist?.Rules is { } rules)
        {
            var line = Ui.Row(6, Ui.Icon(Glyphs.Smart, 12, "SecondaryIcon"), Ui.Text(SmartRulesText.Summary(rules), "SecondaryText").With(t => { t.TextWrapping = TextWrapping.Wrap; t.MaxLines = 2; }));
            info.Children.Add(line);
        }
        var buttons = Ui.Row(10, Ui.Button("Play", () => Model.Play(tracks), Glyphs.Play, "AccentPillButton"),
                              Ui.Button("Shuffle", () => Model.Play(tracks, shuffle: true), Glyphs.Shuffle));
        foreach (var child in buttons.Children.OfType<Control>()) child.IsEnabled = tracks.Count > 0;
        if (playlist is { IsSmart: true } smart) buttons.Children.Add(Ui.Button("Edit Rules", () => Model.EditSmartPlaylist(smart), ""));
        buttons.Children.Add(Ui.MenuButton(() => Menus.Flyout(MoreItems())));
        info.Children.Add(buttons);
        info.VerticalAlignment = VerticalAlignment.Bottom;
        header.Children.Add(info.At(1));
        if (body.Children.Count > 2) body.Children.RemoveAt(2);
        if (tracks.Count == 0)
        {
            var (title, glyph, message) = playlistId is null
                ? ("No Loved Songs", Glyphs.Heart, "Songs you love (the heart in the player or Love in a song's menu) show up here.")
                : playlist?.IsSmart == true
                    ? ("No Matching Songs", Glyphs.Smart, "Songs that match the rules show up here as your library changes.")
                    : ("No Songs Yet", Glyphs.AddToPlaylist, "Drag songs here or use Add to Playlist from a song's menu.");
            body.Children.Add(EmptyNote(title, glyph, message));
        }
        MainWindow.Current?.RefreshTitle();
    }

    private string? washKey;

    /// <summary>The cover's colors behind the header (without the title: letters would only smear the color).</summary>
    private async Task ShowWashAsync()
    {
        var current = playlist;
        var hashes = SongHashes;
        var key = current is null ? "loved" : $"{current.Cover?.Length}:{string.Join(",", hashes)}:{(current.Cover is null ? "" : Convert.ToBase64String(current.Cover))}";
        if (key == washKey) return;
        washKey = key;
        byte[] png;
        if (current is null)
        {
            // Loved Songs: its pink gradient.
            png = await Task.Run(() => PlaylistCovers.RenderPng(Model.Artwork, "", new PlaylistCover(new PlaylistCoverKind.Generated("rose", "none")), [], 0, 32, hidesTitle: true));
        }
        else
        {
            var artwork = Model.Artwork;
            png = await Task.Run(() => PlaylistCovers.RenderPng(artwork, current.Name, current.CoverStyle, hashes, current.Id ?? 0, 32, hidesTitle: true));
        }
        var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
        using (var writer = new Windows.Storage.Streams.DataWriter(stream.GetOutputStreamAt(0)))
        {
            writer.WriteBytes(png);
            await writer.StoreAsync();
            writer.DetachStream();
        }
        stream.Seek(0);
        page.Children[0] = CoverWash.Make(null, stream);
    }

    private IEnumerable<MenuFlyoutItemBase> EditItems(Playlist current)
    {
        yield return Menus.Item("Edit Playlist…", () => Model.EditPlaylist(current), Glyphs.Edit);
        if (current.IsSmart) yield return Menus.Item("Edit Rules…", () => Model.EditSmartPlaylist(current), Glyphs.Smart);
    }

    private IEnumerable<MenuFlyoutItemBase> MoreItems()
    {
        SongSource source = playlistId is { } id ? new SongSource.Playlist(id) : new SongSource.LovedSongs();
        foreach (var item in Menus.QueueItems(source)) yield return item;
        if (playlist is { } current)
        {
            yield return new MenuFlyoutSeparator();
            yield return Menus.Item("Edit Playlist…", () => Model.EditPlaylist(current), Glyphs.Edit);
        }
        else yield return new MenuFlyoutSeparator();
        yield return Menus.Item("Export Playlist…", () => Model.Request(new DialogRequest.ExportPlaylist(playlistId)), Glyphs.Export);
    }

    /// <summary>Where the songs of an empty playlist would be: a dashed drop area under the header.</summary>
    private static FrameworkElement EmptyNote(string title, string glyph, string message)
    {
        var grid = new Grid { Margin = new Thickness(0, 8, 0, 0) };
        grid.Children.Add(new Microsoft.UI.Xaml.Shapes.Rectangle
        {
            RadiusX = 12, RadiusY = 12, StrokeThickness = 1.5, StrokeDashArray = [4, 3.3], Stroke = Ui.Brush("TextFillColorTertiaryBrush"),
        });
        var row = Ui.Row(14, Ui.Icon(glyph, 22, "SecondaryIcon"), Ui.Column(3, Ui.Text(title, "StrongText"), Ui.Text(message, "SecondaryText")));
        row.Padding = new Thickness(20, 22, 20, 22);
        grid.Children.Add(row);
        return grid;
    }
}

/// <summary>One line descriptions of smart playlist rules (the Mac's summary).</summary>
public static class SmartRulesText
{
    /// <summary>"Artist contains "Radio" and Plays is greater than 10 · limited to 25 songs by most played".</summary>
    public static string Summary(SmartPlaylistRules rules)
    {
        var text = string.Join(rules.Match == SmartMatch.All ? " and " : " or ", rules.Rules.Select(Summary));
        if (text.Length == 0) text = "All songs";
        if (rules.Limit is { } limit) text += $" · limited to {limit.Count} {limit.Unit.DisplayName()} by {limit.SelectedBy.DisplayName()}";
        return text;
    }

    public static string Summary(SmartRule rule)
    {
        var head = $"{rule.Field.DisplayName()} {rule.Op.DisplayName()}";
        return rule.Field.KindOf() switch
        {
            SmartFieldKind.Text => $"{head} \"{rule.Text}\"",
            SmartFieldKind.Number => rule.Op == SmartOperator.InRange
                ? $"{head} {rule.Number:0.##} to {rule.Number2:0.##}{Unit(rule)}"
                : $"{head} {rule.Number:0.##}{Unit(rule)}",
            SmartFieldKind.Date => rule.Op is SmartOperator.InTheLast or SmartOperator.NotInTheLast
                ? $"{head} {rule.Period} {rule.PeriodUnit.ToString().ToLowerInvariant()}"
                : $"{head} {rule.Date.ToLocalTime():d MMM yyyy}",
            SmartFieldKind.Bool => head,
            _ => $"{head} {rule.Quality.DisplayName()}",
        };
    }

    private static string Unit(SmartRule rule) => rule.Field.Unit() is { } unit ? $" {unit}" : "";
}
