using System.ComponentModel;
using Groovelight.Controls;
using Groovelight.Dialogs;
using Groovelight.Model;
using Groovelight.Shell;
using Groovelight.Support;
using Groovelight.Views;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Windows.System;

namespace Groovelight;

/// <summary>
/// The library window (the Mac's ContentView): title bar with the menus and search, navigation pane, the page with the
/// lyrics or Up Next pane beside it, and the player bar along the bottom. Now Playing covers it all when shown.
/// </summary>
public sealed partial class MainWindow : Window
{
    public static new MainWindow Current { get; private set; } = null!;

    /// <summary>Where dialogs of the library window open.</summary>
    public XamlRoot RootXamlRoot => Root.XamlRoot;

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr window);
    private AppModel Model => AppModel.Current;

    private readonly TitleBar titleBar = new() { IsBackButtonVisible = true, IsPaneToggleButtonVisible = true };
    private readonly AutoSuggestBox search = new() { PlaceholderText = "Artists, Albums, Songs, Credits", QueryIcon = new SymbolIcon(Symbol.Find), MinWidth = 320, MaxWidth = 560, VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel toolbar = new() { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) };
    private readonly NavigationView navigation = new()
    {
        IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed, IsPaneToggleButtonVisible = false, PaneDisplayMode = NavigationViewPaneDisplayMode.Left,
        IsSettingsVisible = true, OpenPaneLength = 250, IsTitleBarAutoPaddingEnabled = false,
    };
    private readonly Grid pageHost = new();
    private readonly Grid sidePane = new() { Width = 320 };
    private readonly ContentControl sideContent = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly Grid overlay = new() { VerticalAlignment = VerticalAlignment.Bottom, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 16), IsHitTestVisible = false };
    private readonly Grid nowPlayingHost = new() { Visibility = Visibility.Collapsed };
    private readonly Grid dropOverlay = new() { Visibility = Visibility.Collapsed, IsHitTestVisible = false };
    private readonly StackPane paneFooter = new();
    private readonly PlayerBar playerBar = new();
    private NavigationPane pane = null!;
    private AppMenus menus = null!;
    private PageView? page;
    private TaskbarIntegration? taskbar;
    private SettingsPage? settings;
    private string? shownPageKey;

    public MainWindow()
    {
        Current = this;
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Groovelight.ico"));
        // Sizes in pixels: the Mac's points times the display's scale.
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        if (DebugOptions.WindowSize is { } size) AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(size.Width * scale), (int)(size.Height * scale)));
        else AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(1360 * scale), (int)(860 * scale)));
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = (int)(960 * scale);
            presenter.PreferredMinimumHeight = (int)(600 * scale);
        }
        Build();
        SetTitleBar(titleBar);
        Model.PropertyChanged += OnModelChanged;
        Model.Sync.PropertyChanged += (_, _) => UpdateOverlay();
        Model.DialogRequested += request => _ = ShowDialogAsync(request);
        Model.SearchFocusRequested += () => search.Focus(FocusState.Keyboard);
        Root.ActualThemeChanged += (_, _) => UpdateTheme();
        Closed += (_, _) =>
        {
            taskbar?.Dispose();
            Model.Shutdown();
        };
        Activated += (_, _) => taskbar ??= new TaskbarIntegration(WinRT.Interop.WindowNative.GetWindowHandle(this));
        Program.Relaunched += HandleArguments;
        ShowPage();
        UpdateSidePane();
        UpdateTheme();
    }

    private void Build()
    {
        Root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        // The title bar: the menus, the search box (Ctrl+F) and the page's own controls.
        menus = new AppMenus();
        titleBar.Title = "Groovelight";
        titleBar.IconSource = new ImageIconSource { ImageSource = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "Groovelight.png"))) };
        titleBar.LeftHeader = menus.Bar;
        titleBar.Content = search;
        titleBar.RightHeader = toolbar;
        titleBar.PaneToggleRequested += (_, _) => navigation.IsPaneOpen = !navigation.IsPaneOpen;
        titleBar.BackRequested += (_, _) => GoBack();
        search.TextChanged += (_, args) =>
        {
            if (args.Reason != AutoSuggestionBoxTextChangeReason.UserInput) return;
            HideSettings();
            Model.IsShowingNowPlaying = false;
            Model.SearchText = search.Text;
        };
        search.QuerySubmitted += (_, args) =>
        {
            HideSettings();
            Model.SearchText = args.QueryText;
            RecentSearches.Add(args.QueryText);
        };
        search.GotFocus += (_, _) =>
        {
            // Recent searches as suggestions while the box is empty.
            if (search.Text.Length == 0) search.ItemsSource = RecentSearches.List();
        };
        search.SuggestionChosen += (_, args) => Model.SearchText = args.SelectedItem as string ?? "";
        Root.Children.Add(titleBar);

        // The page, with the lyrics or Up Next pane on the right.
        var body = Ui.Grid("*,auto");
        body.Children.Add(pageHost);
        sidePane.BorderThickness = new Thickness(1, 0, 0, 0);
        sidePane.BorderBrush = Ui.Brush("DividerStrokeColorDefaultBrush");
        sidePane.Background = Ui.Brush("LayerFillColorDefaultBrush");
        sidePane.Children.Add(sideContent);
        body.Children.Add(sidePane.At(1));
        overlay.SetValue(Grid.ColumnSpanProperty, 1);
        body.Children.Add(overlay);
        navigation.Content = body;
        navigation.PaneFooter = paneFooter;
        pane = new NavigationPane(navigation);
        Root.Children.Add(navigation.At(0, 1));
        Root.Children.Add(playerBar.At(0, 2));
        // Now Playing covers the whole window; the drop target covers it while files are dragged in.
        Root.Children.Add(nowPlayingHost.At(0, 0, rowSpan: 3));
        Root.Children.Add(dropOverlay.At(0, 0, rowSpan: 3));

        Root.KeyDown += OnKeyDown;
        Root.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(OnPreviewKey), handledEventsToo: true);
        Root.AllowDrop = true;
        Root.DragOver += OnDragOver;
        Root.DragLeave += (_, _) => dropOverlay.Visibility = Visibility.Collapsed;
        Root.Drop += OnDrop;
        BuildDropOverlay();
    }

    // MARK: Pages

    private void OnModelChanged(object? sender, PropertyChangedEventArgs args)
    {
        switch (args.PropertyName)
        {
            case nameof(AppModel.Selection):
            case nameof(AppModel.Path):
                if (args.PropertyName == nameof(AppModel.Selection))
                {
                    HideSettings();
                    UpdateTheme();
                }
                ShowPage();
                pane.SelectCurrent();
                break;
            case nameof(AppModel.SearchText):
                if (search.Text != Model.SearchText) search.Text = Model.SearchText;
                break;
            case nameof(AppModel.SidePanel):
                UpdateSidePane();
                break;
            case nameof(AppModel.IsShowingNowPlaying):
                UpdateNowPlaying();
                break;
            case nameof(AppModel.ScanProgress):
                UpdateOverlay();
                break;
            case nameof(AppModel.ErrorMessage):
                if (Model.ErrorMessage is { } message)
                {
                    Model.ErrorMessage = null;
                    _ = Ui.Alert(Root.XamlRoot, "Groovelight", message);
                }
                break;
        }
    }

    /// <summary>The page for the selection, or the page pushed on top of it.</summary>
    private void ShowPage()
    {
        if (settings is not null) return;
        var route = Model.Path.LastOrDefault();
        var key = route is null ? Model.Selection.Tag : $"{Model.Selection.Tag}/{Model.Path.Count}/{route}";
        if (key == shownPageKey && page is not null) return;
        var forward = route is not null && (shownPageKey?.Split('/').Length ?? 0) < key.Split('/').Length;
        shownPageKey = key;
        page?.Dispose();
        page = route switch
        {
            Route.Album album => new AlbumPage(album.Summary),
            Route.Person person => new PersonPage(person.Who),
            Route.Artist artist => new ArtistDetailView(artist.Name),
            Route.SearchResults results => new SearchCategoryPage(results.Category, results.Query),
            _ => MakePage(Model.Selection),
        };
        pageHost.Children.Clear();
        pageHost.Children.Add(page);
        if (forward)
        {
            page.Transitions = [new EntranceThemeTransition { FromHorizontalOffset = 40, FromVerticalOffset = 0 }];
        }
        RefreshTitle();
    }

    private static PageView MakePage(SidebarItem item) => item.Kind switch
    {
        PageKind.Search => new SearchPage(),
        PageKind.RecentlyAdded => new AlbumsPage(recentlyAdded: true),
        PageKind.Artists => new ArtistsPage(),
        PageKind.Songs => new SongsPage(),
        PageKind.Genres => new GenresPage(),
        PageKind.Shelf => PageFactories.Shelf?.Invoke() ?? new AlbumsPage(recentlyAdded: false),
        PageKind.AllPlaylists => new AllPlaylistsPage(),
        PageKind.LovedSongs => new PlaylistPage(null),
        PageKind.Playlist => new PlaylistPage(item.PlaylistId),
        PageKind.Device => PageFactories.Device?.Invoke(item.DeviceId ?? "") ?? new AlbumsPage(recentlyAdded: false),
        _ => new AlbumsPage(recentlyAdded: false),
    };

    /// <summary>The window title, back button and the page's toolbar.</summary>
    public void RefreshTitle()
    {
        var name = settings is not null ? "Settings" : page?.Title ?? "";
        Title = name.Length == 0 ? "Groovelight" : $"{name} - Groovelight";
        titleBar.Subtitle = settings is not null ? "Settings" : page switch
        {
            SongsPage songs => $"{name} · {songs.Subtitle}",
            _ => name,
        };
        titleBar.IsBackButtonEnabled = settings is not null || Model.Path.Count > 0;
        toolbar.Children.Clear();
        if (settings is null && page is not null) foreach (var item in page.Toolbar()) toolbar.Children.Add(item);
    }

    private void GoBack()
    {
        if (settings is not null) HideSettings();
        else if (Model.IsShowingNowPlaying) Model.IsShowingNowPlaying = false;
        else Model.GoBack();
    }

    public void ShowSettings()
    {
        if (settings is not null) return;
        Model.IsShowingNowPlaying = false;
        page?.Dispose();
        page = null;
        settings = new SettingsPage();
        pageHost.Children.Clear();
        pageHost.Children.Add(settings);
        navigation.SelectedItem = navigation.SettingsItem;
        RefreshTitle();
    }

    public void HideSettings()
    {
        if (settings is null) return;
        settings.Dispose();
        settings = null;
        shownPageKey = null;
        ShowPage();
        pane.SelectCurrent();
    }

    // MARK: Side pane and overlays

    private void UpdateSidePane()
    {
        sidePane.Visibility = Model.SidePanel == SidePanel.None ? Visibility.Collapsed : Visibility.Visible;
        sideContent.Content = Model.SidePanel switch
        {
            SidePanel.Lyrics => new LyricsSidePanel(),
            SidePanel.Queue => new QueuePanel(),
            _ => null,
        };
    }

    private void UpdateOverlay()
    {
        overlay.Children.Clear();
        FrameworkElement? badge = null;
        if (Model.ScanProgress is { } progress)
        {
            badge = Ui.Row(10, new ProgressRing { IsActive = true, Width = 16, Height = 16 },
                new TextBlock { Text = progress.FilesFound > 0 ? $"Scanning library… {progress.FilesProcessed} of {progress.FilesFound}" : "Looking for music…" });
        }
        else if (Model.Sync.Note is { } note)
        {
            // What a quiet update picked up from the folders.
            badge = Ui.Row(8, Ui.Icon(Glyphs.Check, 14), new TextBlock { Text = note });
        }
        if (badge is null) return;
        overlay.Children.Add(new Border
        {
            Child = badge, Padding = new Thickness(16, 10, 16, 10), CornerRadius = new CornerRadius(20),
            Background = Ui.Brush("AcrylicInAppFillColorDefaultBrush"), BorderBrush = Ui.Brush("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1),
            Shadow = new ThemeShadow(), Translation = new System.Numerics.Vector3(0, 0, 16),
        });
    }

    private void UpdateNowPlaying()
    {
        if (Model.IsShowingNowPlaying && PageFactories.NowPlaying is { } make && Model.Player.Current is not null)
        {
            if (nowPlayingHost.Children.Count == 0) nowPlayingHost.Children.Add(make());
            nowPlayingHost.Visibility = Visibility.Visible;
        }
        else
        {
            if (Model.IsShowingNowPlaying && Model.Player.Current is null) Model.IsShowingNowPlaying = false;
            foreach (var child in nowPlayingHost.Children.OfType<IDisposable>()) child.Dispose();
            nowPlayingHost.Children.Clear();
            nowPlayingHost.Visibility = Visibility.Collapsed;
        }
    }

    /// <summary>The Shelf stays dark, like the Cover Flow screens it is modeled on; elsewhere the chosen appearance.</summary>
    public void UpdateTheme()
    {
        var chosen = AppTheme.Current;
        Root.RequestedTheme = Model.Selection.Kind == PageKind.Shelf && settings is null ? ElementTheme.Dark : chosen;
        var dark = Root.ActualTheme == ElementTheme.Dark;
        AppWindow.TitleBar.ButtonForegroundColor = dark ? Microsoft.UI.Colors.White : Microsoft.UI.Colors.Black;
        AppWindow.TitleBar.ButtonInactiveForegroundColor = dark ? Windows.UI.Color.FromArgb(255, 160, 160, 160) : Windows.UI.Color.FromArgb(255, 110, 110, 110);
    }

    // MARK: Keyboard

    private static bool IsDown(VirtualKey key) => InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    /// <summary>The user's shortcuts, even when a control already handled the key (a list moving its selection).</summary>
    private void OnPreviewKey(object sender, KeyRoutedEventArgs args)
    {
        var ctrl = IsDown(VirtualKey.Control);
        var alt = IsDown(VirtualKey.Menu);
        var shift = IsDown(VirtualKey.Shift);
        if (StoredShortcut.KeyCharacter(args.Key) is not { } character) return;
        if (ctrl && args.Key == (VirtualKey)188 && !alt && !shift)
        {
            ShowSettings();
            args.Handled = true;
            return;
        }
        var typing = FocusManager.GetFocusedElement(Root.XamlRoot) is TextBox or AutoSuggestBox or PasswordBox or NumberBox or RichEditBox;
        // A plain key would stop typing in text fields: shortcuts need Ctrl or Alt, or a function key.
        if (!ctrl && !alt && !StoredShortcut.IsFunctionKey(character)) return;
        // Ctrl with arrows, Home and End edit text in a text field.
        if (typing && ctrl && !alt && character is StoredShortcut.Left or StoredShortcut.Right or StoredShortcut.Up or StoredShortcut.Down or StoredShortcut.Home or StoredShortcut.End) return;
        var pressed = new StoredShortcut(character.ToString(), (ctrl ? StoredShortcut.Command : 0) | (alt ? StoredShortcut.Option : 0) | (shift ? StoredShortcut.Shift : 0));
        if (Model.Shortcuts.Action(pressed) is not { } action) return;
        if (ShortcutRecorder.IsRecording) return;
        Commands.Run(action);
        args.Handled = true;
    }

    /// <summary>Space plays or pauses, unless something that takes it (a text field, a button) has the focus.</summary>
    private void OnKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key == VirtualKey.Space && !IsDown(VirtualKey.Control) && !IsDown(VirtualKey.Menu))
        {
            Model.Player.TogglePlayPause();
            args.Handled = true;
        }
        else if (args.Key == VirtualKey.Escape)
        {
            if (Model.IsShowingNowPlaying) { Model.IsShowingNowPlaying = false; args.Handled = true; }
        }
        else if (args.Key == VirtualKey.Back && !IsDown(VirtualKey.Control) || args.Key == VirtualKey.GoBack || (args.Key == VirtualKey.Left && IsDown(VirtualKey.Menu)))
        {
            GoBack();
            args.Handled = true;
        }
    }

    // MARK: Dialogs

    private async Task ShowDialogAsync(DialogRequest request)
    {
        var root = Root.XamlRoot;
        switch (request)
        {
            case DialogRequest.GetInfo info:
                await new GetInfoDialog(info.Tracks).ShowAsync(root);
                break;
            case DialogRequest.Credits credits:
                await TrackCredits.ShowAsync(root, credits.Track);
                break;
            case DialogRequest.EditPlaylist edit:
                await new EditPlaylistDialog(edit.Playlist).ShowAsync(root);
                break;
            case DialogRequest.SmartPlaylist smart:
                await new SmartPlaylistDialog(smart.Playlist).ShowAsync(root);
                break;
            case DialogRequest.Message message:
                await Ui.Alert(root, message.Title, message.Text);
                break;
            default:
                if (DialogHandlers.TryGetValue(request.GetType(), out var handler)) await handler(root, request);
                break;
        }
    }

    /// <summary>Dialogs of later features (Fix Metadata, Organize, playlist export), by request type.</summary>
    public static Dictionary<Type, Func<XamlRoot, DialogRequest, Task>> DialogHandlers { get; } = [];

    // MARK: Library folders and window

    public async void ChooseLibraryFolder()
    {
        if (await Pickers.FolderAsync("Add Folder") is { } path) Model.AddLibraryFolder(path);
    }

    public void BringToFront()
    {
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } presenter) presenter.Restore();
        AppWindow.Show();
        Activate();
    }

    // MARK: Dropping files

    private void BuildDropOverlay()
    {
        dropOverlay.Background = new SolidColorBrush(Windows.UI.Color.FromArgb(64, 0, 0, 0));
        var card = Ui.Column(12, Ui.Icon(Glyphs.Download, 44), Ui.Text("Drop to Import", "SectionTitleText"),
            Ui.Text("Songs and folders are moved into your library, tagged and named.", "SecondaryText"));
        foreach (var child in card.Children.OfType<FrameworkElement>()) child.HorizontalAlignment = HorizontalAlignment.Center;
        dropOverlay.Children.Add(new Border
        {
            Child = card, Padding = new Thickness(36), CornerRadius = new CornerRadius(24), HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center, Background = Ui.Brush("AcrylicBackgroundFillColorDefaultBrush"),
        });
    }

    private void OnDragOver(object sender, DragEventArgs args)
    {
        if (!args.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems) || args.Handled) return;
        args.AcceptedOperation = Windows.ApplicationModel.DataTransfer.DataPackageOperation.Copy;
        args.DragUIOverride.Caption = "Import";
        dropOverlay.Visibility = Visibility.Visible;
    }

    private async void OnDrop(object sender, DragEventArgs args)
    {
        dropOverlay.Visibility = Visibility.Collapsed;
        if (!args.DataView.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.StorageItems)) return;
        var items = await args.DataView.GetStorageItemsAsync();
        OpenFiles(items.Select(item => item.Path).ToList());
    }

    /// <summary>Files opened with the app or dropped on it: cassettes are added, playlist files imported, music imported.</summary>
    public static Action<IReadOnlyList<string>>? FileOpener { get; set; }

    /// <summary>Arguments of a launch: <c>--command</c> from the jump list, or files opened with the app.</summary>
    public void HandleArguments(IReadOnlyList<string> arguments)
    {
        var index = arguments.ToList().IndexOf("--command");
        if (index >= 0 && index + 1 < arguments.Count)
        {
            JumpList.Run(arguments[index + 1]);
            return;
        }
        var files = arguments.Where(argument => !argument.StartsWith("--", StringComparison.Ordinal) && (File.Exists(argument) || Directory.Exists(argument))).ToList();
        BringToFront();
        OpenFiles(files);
    }

    public void OpenFiles(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return;
        // Files opened with the app arrive before the window is on screen: dialogs need it.
        if (Root.XamlRoot is null) Root.Loaded += (_, _) => FileOpener?.Invoke(paths);
        else FileOpener?.Invoke(paths);
    }
}

/// <summary>Pages and windows of later features, plugged in by them.</summary>
public static class PageFactories
{
    public static Func<PageView>? Shelf { get; set; }
    public static Func<string, PageView>? Device { get; set; }
    public static Func<FrameworkElement>? NowPlaying { get; set; }
}

/// <summary>The navigation pane's footer: the background metadata job and New Playlist.</summary>
public sealed partial class StackPane : StackPanel
{
    private readonly StackPanel job = new() { Spacing = 5, Padding = new Thickness(12, 8, 12, 0) };

    public StackPane()
    {
        var model = AppModel.Current;
        Children.Add(job);
        var newPlaylist = AllPlaylistsPage.NewPlaylistButton();
        if (newPlaylist is FrameworkElement element) element.Margin = new Thickness(12);
        Children.Add(newPlaylist);
        model.Metadata.PropertyChanged += (_, args) => { if (args.PropertyName == nameof(MetadataStore.LibraryJob)) Update(); };
        Update();
    }

    /// <summary>Progress of the background "Fetch Missing Info" job.</summary>
    private void Update()
    {
        var model = AppModel.Current;
        job.Children.Clear();
        if (model.Metadata.LibraryJob is not { } progress)
        {
            job.Visibility = Visibility.Collapsed;
            return;
        }
        job.Visibility = Visibility.Visible;
        var head = Ui.Grid("*,auto,auto");
        head.ColumnSpacing = 6;
        head.Children.Add(Ui.Text(MetadataStore.StepTitle(progress.Step), "StrongText", 11));
        head.Children.Add(Ui.Text($"{progress.Done} of {progress.Total}", "CaptionText", 11).At(1));
        head.Children.Add(Ui.IconButton(Glyphs.Close, "Stop fetching missing info", model.Metadata.StopFetchingMissingInfo, 10).At(2));
        job.Children.Add(head);
        job.Children.Add(new ProgressBar { Maximum = Math.Max(progress.Total, 1), Value = progress.Done });
        if (progress.Remaining.Count > 0)
            job.Children.Add(Ui.Text("Then: " + string.Join(", ", progress.Remaining.Select(MetadataStore.StepTitle)), "SmallText", 10));
        ToolTipService.SetToolTip(job, "Fetching missing library info in the background, one request at a time");
    }
}
