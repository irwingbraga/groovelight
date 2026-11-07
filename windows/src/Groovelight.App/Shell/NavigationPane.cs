using Groovelight.Controls;
using Groovelight.Core.Library;
using Groovelight.Model;
using Groovelight.Support;
using Groovelight.Views;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.ApplicationModel.DataTransfer;

namespace Groovelight.Shell;

/// <summary>
/// The navigation pane's items (the Mac's sidebar): Search, Library, Explore, Devices while connected, and Playlists with
/// their covers. Songs dropped on Loved Songs are loved; on a playlist, added; on a device, synced to it.
/// </summary>
public sealed class NavigationPane
{
    private static AppModel Model => AppModel.Current;
    private readonly NavigationView view;
    private readonly List<NavigationViewItemBase> fixedTop;
    private readonly NavigationViewItemHeader devicesHeader = new() { Content = "Devices" };
    private readonly NavigationViewItemHeader playlistsHeader = new() { Content = "Playlists" };
    private readonly NavigationViewItem allPlaylists;
    private readonly NavigationViewItem lovedSongs;
    private List<PlaylistSummary> playlists = [];
    private readonly Dictionary<string, BitmapImage> coverIcons = [];
    private bool updating;

    /// <summary>Devices to list (filled in by device sync): id, name, icon glyph, and the item's extra content.</summary>
    public static Func<IReadOnlyList<(string Id, string Name, string Glyph, Action<NavigationViewItem> Configure)>>? Devices { get; set; }

    /// <summary>The devices changed (plugged in, paired, gone): the pane lists them again.</summary>
    public static event Action? DevicesChanged;

    public static void InvalidateDevices() => DevicesChanged?.Invoke();

    public NavigationPane(NavigationView view)
    {
        this.view = view;
        fixedTop =
        [
            Item("Search", SidebarItem.Search, Glyphs.Search),
            new NavigationViewItemHeader { Content = "Library" },
            Item("Recently Added", SidebarItem.RecentlyAdded, Glyphs.Clock),
            Item("Artists", SidebarItem.Artists, Glyphs.Artist),
            Item("Albums", SidebarItem.Albums, Glyphs.Album),
            Item("Songs", SidebarItem.Songs, Glyphs.Songs),
            Item("Genres", SidebarItem.Genres, Glyphs.Genres),
            new NavigationViewItemHeader { Content = "Explore" },
            Item("Shelf", SidebarItem.Shelf, Glyphs.Shelf),
        ];
        allPlaylists = Item("All Playlists", SidebarItem.AllPlaylists, Glyphs.Grid);
        lovedSongs = Item("Loved Songs", SidebarItem.LovedSongs, Glyphs.HeartFilled);
        ((FontIcon)lovedSongs.Icon).Foreground = Ui.Brush("LoveBrush");
        lovedSongs.ContextFlyout = Menus.Flyout(Menus.QueueItems(new SongSource.LovedSongs()).Append(new MenuFlyoutSeparator())
            .Append(Menus.Item("Export Playlist…", () => Model.Request(new DialogRequest.ExportPlaylist(null)), Glyphs.Export)));
        AcceptSongs(lovedSongs, ids => Model.Love(ids), "Love");
        view.SelectionChanged += (_, args) =>
        {
            if (updating) return;
            if (args.IsSettingsSelected)
            {
                MainWindow.Current.ShowSettings();
                return;
            }
            if (SidebarItem.FromTag((args.SelectedItem as NavigationViewItem)?.Tag as string) is { } item)
            {
                Model.IsShowingNowPlaying = false;
                if (item == Model.Selection) Model.ReplacePath([]);
                else Model.Selection = item;
                MainWindow.Current.HideSettings();
            }
        };
        // Clicking the selected item again goes back to its root page.
        view.ItemInvoked += (_, args) =>
        {
            if (args.InvokedItemContainer?.Tag is string tag && SidebarItem.FromTag(tag) == Model.Selection)
            {
                Model.IsShowingNowPlaying = false;
                Model.ReplacePath([]);
                MainWindow.Current.HideSettings();
            }
        };
        new Observation<List<PlaylistSummary>>(Model.Database, db => db.PlaylistOverview().Playlists.ToList(), value =>
        {
            playlists = value;
            Rebuild();
        });
        DevicesChanged += Rebuild;
        Rebuild();
    }

    private static NavigationViewItem Item(string title, SidebarItem item, string glyph) =>
        new() { Content = title, Tag = item.Tag, Icon = new FontIcon { Glyph = glyph } };

    /// <summary>Rebuilds the items (playlists or devices changed), keeping the selection.</summary>
    public void Rebuild()
    {
        updating = true;
        view.MenuItems.Clear();
        foreach (var item in fixedTop) view.MenuItems.Add(item);
        var devices = Devices?.Invoke() ?? [];
        if (devices.Count > 0)
        {
            view.MenuItems.Add(devicesHeader);
            foreach (var (id, name, glyph, configure) in devices)
            {
                var item = Item(name, SidebarItem.Device(id), glyph);
                configure(item);
                view.MenuItems.Add(item);
            }
        }
        view.MenuItems.Add(playlistsHeader);
        view.MenuItems.Add(allPlaylists);
        view.MenuItems.Add(lovedSongs);
        foreach (var summary in playlists) view.MenuItems.Add(PlaylistItem(summary));
        SelectCurrent();
        updating = false;
    }

    private NavigationViewItem PlaylistItem(PlaylistSummary summary)
    {
        var playlist = summary.Playlist;
        var id = summary.Id;
        var icon = new ImageIcon();
        var item = new NavigationViewItem { Content = playlist.Name, Tag = SidebarItem.Playlist(id).Tag, Icon = icon };
        _ = LoadCoverAsync(icon, summary);
        var menu = Menus.Flyout(Menus.QueueItems(new SongSource.Playlist(id)).Concat(new MenuFlyoutItemBase[]
        {
            new MenuFlyoutSeparator(),
            Menus.Item("Edit Playlist…", () => Model.EditPlaylist(playlist), Glyphs.Edit),
        }).Concat(playlist.IsSmart ? [Menus.Item("Edit Rules…", () => Model.EditSmartPlaylist(playlist), Glyphs.Smart)] : Array.Empty<MenuFlyoutItemBase>())
          .Concat(new MenuFlyoutItemBase[]
        {
            Menus.Item("Rename", () => _ = RenameAsync(playlist), Glyphs.Rename),
            Menus.Item("Export Playlist…", () => Model.Request(new DialogRequest.ExportPlaylist(id)), Glyphs.Export),
            Menus.Item("Delete Playlist", async () =>
            {
                if (await Ui.Confirm(view.XamlRoot, $"Delete “{playlist.Name}”?", "The playlist is deleted. Its songs stay in your library.", "Delete", destructive: true))
                    Model.DeletePlaylist(id);
            }, Glyphs.Delete),
        }));
        item.ContextFlyout = menu;
        // Smart playlists are filled by their rules.
        if (!playlist.IsSmart) AcceptSongs(item, ids => Model.Database.AddTracks(ids, id), "Add to Playlist");
        return item;
    }

    /// <summary>The playlist's cover as its icon, name included, exactly as in All Playlists (drawn at card size, then shrunk).</summary>
    private async Task LoadCoverAsync(ImageIcon icon, PlaylistSummary summary)
    {
        var playlist = summary.Playlist;
        var key = $"{playlist.Name}\u0001{(playlist.Cover is null ? "" : Convert.ToBase64String(playlist.Cover))}\u0001{string.Join(",", summary.ArtworkHashes.Take(4))}";
        if (!coverIcons.TryGetValue(key, out var bitmap))
        {
            var artwork = Model.Artwork;
            var png = await Task.Run(() => PlaylistCovers.RenderPng(artwork, playlist.Name, playlist.CoverStyle, summary.ArtworkHashes, summary.Id, 200));
            bitmap = await Images.FromBytesAsync(png);
            bitmap.DecodePixelWidth = 48;
            coverIcons[key] = bitmap;
        }
        icon.Source = bitmap;
    }

    private async Task RenameAsync(Playlist playlist)
    {
        var box = new TextBox { Text = playlist.Name, SelectionStart = 0, SelectionLength = playlist.Name.Length };
        var dialog = new ContentDialog { XamlRoot = view.XamlRoot, Title = "Rename Playlist", Content = box, PrimaryButtonText = "Rename", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
        if (await ContentDialogs.ShowAsync(dialog) == ContentDialogResult.Primary && box.Text.Trim() is { Length: > 0 } name && playlist.Id is { } id)
            Model.Database.RenamePlaylist(id, name);
    }

    /// <summary>Lets songs dragged from the app be dropped on an item.</summary>
    public static void AcceptSongs(NavigationViewItem item, Action<List<long>> drop, string caption, Action<(List<long> Ids, string? AlbumKey)>? dropWithAlbum = null)
    {
        item.AllowDrop = true;
        item.DragOver += (_, args) =>
        {
            if (!args.DataView.Contains(TrackList.TracksFormat)) return;
            args.AcceptedOperation = DataPackageOperation.Copy;
            args.DragUIOverride.Caption = caption;
        };
        item.Drop += async (_, args) =>
        {
            if (await TrackList.ReadDragDataAsync(args.DataView) is not { } data) return;
            if (dropWithAlbum is not null) dropWithAlbum(data);
            else drop(data.Ids);
        };
    }

    /// <summary>Selects the item of the model's page (Search is reached from the title bar too).</summary>
    public void SelectCurrent()
    {
        var wasUpdating = updating;
        updating = true;
        var tag = Model.Selection.Tag;
        view.SelectedItem = view.MenuItems.OfType<NavigationViewItem>().FirstOrDefault(item => item.Tag as string == tag);
        updating = wasUpdating;
    }
}
