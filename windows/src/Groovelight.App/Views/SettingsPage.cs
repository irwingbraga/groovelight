using Groovelight.Audio;
using Groovelight.Controls;
using Groovelight.Core.Library;
using Groovelight.Model;
using Groovelight.Support;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace Groovelight.Views;

/// <summary>The app's appearance, chosen in Settings: follow Windows, or always light or dark (the Shelf stays dark).</summary>
public static class AppTheme
{
    public const string Key = "appearance.theme";

    public static ElementTheme Current => AppModel.Current.Preferences.String(Key) switch
    {
        "light" => ElementTheme.Light,
        "dark" => ElementTheme.Dark,
        _ => ElementTheme.Default,
    };
}

/// <summary>A Windows 11 settings card: an icon, a title and a description on the left, its control on the right.</summary>
public sealed partial class SettingsCard : UserControl
{
    public SettingsCard(string title, string? description, FrameworkElement? control, string? glyph = null, bool stacked = false)
    {
        var border = new Border { Style = Ui.Style("CardBorder"), Padding = new Thickness(16, 14, 16, 14) };
        Content = border;
        Card = border;
        var grid = Ui.Grid("auto,*,auto");
        grid.ColumnSpacing = 16;
        if (glyph is not null) grid.Children.Add(Ui.Icon(glyph, 18).With(icon => icon.VerticalAlignment = VerticalAlignment.Center));
        var text = Ui.Column(2, Ui.Text(title, "BodyText").With(t => { t.TextWrapping = TextWrapping.Wrap; t.TextTrimming = TextTrimming.None; }));
        if (description is not null) text.Children.Add(Ui.Text(description, "CaptionText").With(t => { t.TextWrapping = TextWrapping.Wrap; t.TextTrimming = TextTrimming.None; }));
        text.VerticalAlignment = VerticalAlignment.Center;
        if (stacked && control is not null)
        {
            text.Children.Add(control.Margin(0, 10, 0, 0));
            grid.Children.Add(text.At(1, 0, 2));
        }
        else
        {
            grid.Children.Add(text.At(1));
            if (control is not null)
            {
                control.VerticalAlignment = VerticalAlignment.Center;
                control.HorizontalAlignment = HorizontalAlignment.Right;
                grid.Children.Add(control.At(2));
            }
        }
        border.Child = grid;
    }

    public Border Card { get; }

    public Grid Body => (Grid)Card.Child;
}

/// <summary>A section of the Settings page (the Mac's Settings window tabs).</summary>
public sealed record SettingsSection(string Title, string Glyph, Func<SettingsPage, FrameworkElement> Build);

/// <summary>
/// Settings, a page in the Windows 11 style: sections on the left (General, Library, Playback, Metadata, Files, Backup,
/// Last.fm, Devices, Shortcuts), their cards on the right.
/// </summary>
public sealed partial class SettingsPage : PageView
{
    /// <summary>Sections of later features, inserted by them.</summary>
    public static List<(int Order, SettingsSection Section)> Extra { get; } = [];

    private readonly ListView sections = new() { SelectionMode = ListViewSelectionMode.Single, Width = 210, Padding = new Thickness(8, 16, 8, 16) };
    private readonly ContentControl content = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly List<SettingsSection> all;
    private readonly List<IDisposable> disposables = [];
    public const string LastSectionKey = "settings.section";

    public SettingsPage()
    {
        var builtIn = new List<(int, SettingsSection)>
        {
            (0, new SettingsSection("General", Glyphs.Settings, page => page.General())),
            (10, new SettingsSection("Library", Glyphs.Folder, page => page.Library())),
            (20, new SettingsSection("Playback", "", page => page.Playback())),
            (30, new SettingsSection("Metadata", Glyphs.Wand, page => page.MetadataSection())),
            (90, new SettingsSection("Shortcuts", "", page => page.Shortcuts())),
        };
        all = builtIn.Concat(Extra).OrderBy(pair => pair.Item1).Select(pair => pair.Item2).ToList();
        foreach (var section in all)
            sections.Items.Add(new ListViewItem { Content = Ui.Row(12, Ui.Icon(section.Glyph, 16), new TextBlock { Text = section.Title }) });
        sections.SelectionChanged += (_, _) =>
        {
            if (sections.SelectedIndex < 0) return;
            ShowSection(all[sections.SelectedIndex]);
            Model.Preferences.Set(LastSectionKey, all[sections.SelectedIndex].Title);
        };
        var grid = Ui.Grid("auto,*");
        grid.Children.Add(new Border { Child = sections, BorderThickness = new Thickness(0, 0, 1, 0), BorderBrush = Ui.Brush("DividerStrokeColorDefaultBrush") });
        grid.Children.Add(content.At(1));
        Content = grid;
        var last = Model.Preferences.String(LastSectionKey);
        sections.SelectedIndex = Math.Max(0, all.FindIndex(section => section.Title == last));
    }

    public override string Title => "Settings";

    public void Track(IDisposable disposable) => disposables.Add(disposable);

    private void ShowSection(SettingsSection section)
    {
        foreach (var item in disposables) item.Dispose();
        disposables.Clear();
        var body = Ui.Column(4, Ui.Text(section.Title, "PageTitleText").Margin(0, 0, 0, 16), section.Build(this));
        body.MaxWidth = 900;
        content.Content = new ScrollViewer { Content = new Border { Padding = new Thickness(36, 28, 36, 36), Child = body } };
    }

    /// <summary>Re-renders the shown section (after a change that reshapes it).</summary>
    public void Refresh()
    {
        if (sections.SelectedIndex >= 0) ShowSection(all[sections.SelectedIndex]);
    }

    public static TextBlock Header(string text) => Ui.Text(text, "StrongText", 14).Margin(0, 18, 0, 6);

    public static TextBlock Footer(string text) =>
        Ui.Text(text, "CaptionText").With(t => { t.TextWrapping = TextWrapping.Wrap; t.TextTrimming = TextTrimming.None; t.Margin = new Thickness(4, 6, 4, 0); });

    public static ToggleSwitch Toggle(bool isOn, Action<bool> changed)
    {
        var toggle = new ToggleSwitch { IsOn = isOn, OnContent = "On", OffContent = "Off", MinWidth = 0 };
        toggle.Toggled += (_, _) => changed(toggle.IsOn);
        return toggle;
    }

    public static ComboBox Choice(IReadOnlyList<string> items, int selected, Action<int> changed)
    {
        var box = new ComboBox { MinWidth = 160 };
        foreach (var item in items) box.Items.Add(item);
        box.SelectedIndex = selected;
        box.SelectionChanged += (_, _) => { if (box.SelectedIndex >= 0) changed(box.SelectedIndex); };
        return box;
    }

    // MARK: General

    private FrameworkElement General()
    {
        var themes = new[] { ("system", "System"), ("light", "Light"), ("dark", "Dark") };
        var current = Model.Preferences.String(AppTheme.Key) ?? "system";
        var panel = Ui.Column(4,
            new SettingsCard("Appearance", "System follows the Windows setting. The Shelf is always dark.",
                Choice(themes.Select(theme => theme.Item2).ToList(), Math.Max(0, Array.FindIndex(themes, theme => theme.Item1 == current)), index =>
                {
                    Model.Preferences.Set(AppTheme.Key, themes[index].Item1);
                    MainWindow.Current.UpdateTheme();
                }), ""));
        foreach (var extra in GeneralExtras) panel.Children.Add(extra(this));
        return panel;
    }

    /// <summary>More General cards (updates, the command line, Claude), from their features.</summary>
    public static List<Func<SettingsPage, FrameworkElement>> GeneralExtras { get; } = [];

    // MARK: Library

    private FrameworkElement Library()
    {
        var panel = Ui.Column(4);
        var folders = Ui.Column(4);
        var summary = Ui.Text("", "CaptionText").With(t => t.TextWrapping = TextWrapping.Wrap);
        panel.Children.Add(Header("Music Folders"));
        panel.Children.Add(folders);
        var rescan = Ui.Button("Rescan Now", Model.RescanAll);
        panel.Children.Add(new SettingsCard("Add a music folder", "Groovelight reads tags and artwork and keeps the library in sync as files change.",
            Ui.Row(8, Ui.Button("Add Folder…", MainWindow.Current.ChooseLibraryFolder, Glyphs.Add, "AccentPillButton"), rescan), Glyphs.Folder));
        panel.Children.Add(Footer("Changes are picked up as they happen, and folders are checked again at launch for what changed while Groovelight was closed. Drives are checked when they are plugged in, network folders every 10 minutes, and every file once a day."));
        panel.Children.Add(summary);
        var import = Ui.Column(4);
        panel.Children.Add(import);
        Track(Observations.Add(Model.Database, db => (db.Roots(), db.TrackCountsByRoot()), value =>
        {
            var (roots, counts) = value;
            folders.Children.Clear();
            if (roots.Count == 0) folders.Children.Add(new SettingsCard("No music folders yet.", null, null));
            foreach (var root in roots)
            {
                var songs = root.Id is { } id ? counts.GetValueOrDefault(id) : 0;
                folders.Children.Add(FolderCard(root, songs));
            }
            rescan.IsEnabled = Model.ScanProgress is null;
            summary.Text = Model.LastScanSummary is { } last
                ? $"Last full check: {last.Added} added, {last.Updated} updated, {last.Removed} removed, {last.Failed.Count} unreadable." : "";
            import.Children.Clear();
            foreach (var extra in LibraryExtras) import.Children.Add(extra(this, roots));
        }));
        return panel;
    }

    /// <summary>More Library cards (the import folder), from their features.</summary>
    public static List<Func<SettingsPage, IReadOnlyList<LibraryRoot>, FrameworkElement>> LibraryExtras { get; } = [];

    /// <summary>A library folder: its name, path, song count, how it is kept up to date, and Remove.</summary>
    private FrameworkElement FolderCard(LibraryRoot root, int songs)
    {
        var name = Path.GetFileName(root.Path.TrimEnd(Path.DirectorySeparatorChar)) is { Length: > 0 } leaf ? leaf : root.Path;
        string status;
        if (Model.UnavailableFolders.Contains(root.Path)) status = "Not available: unplugged or moved. Its songs keep their history.";
        else
        {
            status = FolderWatcherInfo(root);
            if (root.LastScanAt is { } date) status += $" · last updated {Format.DateTime(date)}";
        }
        var remove = Ui.IconButton("", "Remove from the library", async () =>
        {
            var message = $"{(songs == 1 ? "Its song leaves" : $"Its {songs} songs leave")} Groovelight, with their play counts and loves, and leave your playlists. The files stay where they are.";
            if (await Ui.Confirm(XamlRoot, $"Remove “{name}” from the library?", message, "Remove", destructive: true)) Model.RemoveRoot(root);
        }, 14);
        var actions = Ui.Row(6);
        if (Model.UnavailableFolders.Contains(root.Path) && LocateFolder is { } locate) actions.Children.Add(Ui.Button("Locate…", () => locate(root)));
        actions.Children.Add(Ui.IconButton(Glyphs.Folder, "Show in File Explorer", () => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("explorer.exe", $"\"{root.Path}\"") { UseShellExecute = true }), 14));
        actions.Children.Add(remove);
        return new SettingsCard(name, $"{root.Path} · {Format.Songs(songs)}\n{status}", actions, Glyphs.Folder);
    }

    /// <summary>Relinks a library folder that moved (from backups).</summary>
    public static Action<LibraryRoot>? LocateFolder { get; set; }

    private static string FolderWatcherInfo(LibraryRoot root) =>
        FolderWatcher.IsLocalVolume(root.Path) ? "Watching for changes" : $"Network folder: checked every {(int)LibrarySync.NetworkInterval.TotalMinutes} minutes";

    // MARK: Playback

    private FrameworkElement Playback()
    {
        var player = Model.Player;
        var preferences = Model.Preferences;
        var panel = Ui.Column(4);
        panel.Children.Add(Header("Bit-Perfect"));
        panel.Children.Add(new SettingsCard("Bit-perfect playback",
            player.BitPerfect
                ? "The output device switches to each song's sample rate and the samples reach it untouched: the equalizer, crossfade, Sound Check and speed are paused, and the volume slider sets the device's own volume. Groovelight takes the device for itself (exclusive mode), so other apps' sounds do not mix in or change the rate."
                : "Plays songs exactly as they are in the files: the output device follows each song's sample rate and nothing in Groovelight changes the sound. Best with a USB DAC.",
            Toggle(player.BitPerfect, on => { Model.SetBitPerfect(on); Refresh(); }), ""));
        if (player.BitPerfect) panel.Children.Add(new Border { Style = Ui.Style("CardBorder"), Child = AudioQualityFlyout.OutputStatus() });

        var adjustable = Ui.Column(4);
        adjustable.IsHitTestVisible = !player.BitPerfect;
        adjustable.Opacity = player.BitPerfect ? 0.5 : 1;
        adjustable.Children.Add(Header("Crossfade"));
        adjustable.Children.Add(new SettingsCard("Crossfade songs",
            player.CrossfadeDuration > 0
                ? "Each song fades into the next over the last seconds. With \"Keep albums gapless\", songs that follow each other on the same album play without a fade, as live albums and mixes are meant to be heard."
                : "Songs follow each other gaplessly.",
            Toggle(player.CrossfadeDuration > 0, on =>
            {
                player.CrossfadeDuration = on ? 6 : 0;
                preferences.Set(PlaybackPrefs.Crossfade, player.CrossfadeDuration);
                Refresh();
            }), ""));
        if (player.CrossfadeDuration > 0)
        {
            var length = new Slider { Minimum = 1, Maximum = 12, StepFrequency = 1, Value = player.CrossfadeDuration, Width = 220 };
            var label = Ui.Text($"{(int)player.CrossfadeDuration} s", "SecondaryText").With(t => { t.Width = 34; t.VerticalAlignment = VerticalAlignment.Center; });
            length.ValueChanged += (_, args) =>
            {
                player.CrossfadeDuration = args.NewValue;
                preferences.Set(PlaybackPrefs.Crossfade, args.NewValue);
                label.Text = $"{(int)args.NewValue} s";
            };
            adjustable.Children.Add(new SettingsCard("Fade length", null, Ui.Row(8, length, label)));
            adjustable.Children.Add(new SettingsCard("Keep albums gapless", null, Toggle(player.CrossfadeSkipsSameAlbum, on =>
            {
                player.CrossfadeSkipsSameAlbum = on;
                preferences.Set(PlaybackPrefs.CrossfadeSkipsAlbum, on);
            })));
        }
        adjustable.Children.Add(Header("Sound Check"));
        var modes = new[] { VolumeNormalization.Off, VolumeNormalization.Track, VolumeNormalization.Album };
        adjustable.Children.Add(new SettingsCard("Volume normalization",
            "Plays songs at the same perceived loudness, like Sound Check, from their ReplayGain tags. Songs without tags are measured in the background (EBU R128). \"Albums\" keeps the differences between the songs of an album.",
            Choice(["Off", "Songs", "Albums"], Array.IndexOf(modes, player.Normalization), index =>
            {
                player.Normalization = modes[index];
                preferences.Set(PlaybackPrefs.Normalization, PlaybackPrefs.RawValue(modes[index]));
                Model.Loudness.SetEnabled(modes[index] != VolumeNormalization.Off);
                Refresh();
            }), ""));
        if (player.Normalization != VolumeNormalization.Off)
        {
            var progress = Ui.Text("", "SecondaryText");
            var ring = new ProgressRing { IsActive = true, Width = 16, Height = 16 };
            void Update()
            {
                progress.Text = $"{Model.Loudness.Measured} of {Model.Loudness.Total} measured";
                ring.Visibility = Model.Loudness.IsRunning && Model.Loudness.Measured < Model.Loudness.Total ? Visibility.Visible : Visibility.Collapsed;
            }
            Update();
            System.ComponentModel.PropertyChangedEventHandler handler = (_, _) => DispatcherQueue.TryEnqueue(Update);
            Model.Loudness.PropertyChanged += handler;
            Track(new Disposer(() => Model.Loudness.PropertyChanged -= handler));
            adjustable.Children.Add(new SettingsCard("Songs without ReplayGain", null, Ui.Row(8, ring, progress)));
        }
        adjustable.Children.Add(Header("Speed"));
        adjustable.Children.Add(new SettingsCard("Playback speed", "Changes the speed without changing the pitch. Also in Controls, Playback Speed.",
            Choice(PlaybackPrefs.Speeds.Select(PlaybackPrefs.SpeedLabel).ToList(), PlaybackPrefs.Speeds.ToList().IndexOf(player.Rate), index => Model.SetRate(PlaybackPrefs.Speeds[index])), ""));
        panel.Children.Add(adjustable);
        foreach (var extra in PlaybackExtras) panel.Children.Add(extra(this));
        return panel;
    }

    /// <summary>More Playback cards (the cassette deck's tape sound), from their features.</summary>
    public static List<Func<SettingsPage, FrameworkElement>> PlaybackExtras { get; } = [];

    // MARK: Metadata

    private FrameworkElement MetadataSection()
    {
        var preferences = Model.Preferences;
        var metadata = Model.Metadata;
        var panel = Ui.Column(4);
        panel.Children.Add(new SettingsCard("Find lyrics online for songs without lyrics", null,
            Toggle(preferences.Bool(MetadataStore.FetchLyricsKey), on => preferences.Set(MetadataStore.FetchLyricsKey, on)), Glyphs.Lyrics));
        panel.Children.Add(new SettingsCard("Show album credits and album and artist backgrounds (MusicBrainz, Wikipedia)", null,
            Toggle(preferences.Bool(MetadataStore.FetchAlbumInfoKey), on => preferences.Set(MetadataStore.FetchAlbumInfoKey, on)), Glyphs.People));
        var writes = preferences.Bool(MetadataStore.WriteTagsKey);
        panel.Children.Add(new SettingsCard("Write fixes into the files",
            writes ? "Fix Metadata saves tags and covers into the audio files." : "Fixes are kept in Groovelight's library and survive rescans; your files are not modified.",
            Toggle(writes, on => { preferences.Set(MetadataStore.WriteTagsKey, on); Refresh(); }), Glyphs.Edit));
        panel.Children.Add(Header("Library"));
        var jobText = Ui.Text("", "CaptionText").With(t => t.TextWrapping = TextWrapping.Wrap);
        var buttons = Ui.Row(8);
        void Update()
        {
            jobText.Text = metadata.LibraryJob is { } job ? $"{MetadataStore.StepTitle(job.Step)}: {job.Done} of {job.Total}"
                : "Album credits and info, artist info, missing artwork and lyrics, one request at a time.";
            buttons.Children.Clear();
            if (metadata.IsFetchingLibraryInfo) buttons.Children.Add(Ui.Button("Stop", metadata.StopFetchingMissingInfo));
            else
            {
                buttons.Children.Add(Ui.Button("Missing Artwork Only", () => metadata.FetchMissingInfo([MetadataStore.LibraryStep.Artwork])));
                buttons.Children.Add(Ui.Button("Fetch All", () => metadata.FetchMissingInfo(), style: "AccentPillButton"));
            }
        }
        Update();
        System.ComponentModel.PropertyChangedEventHandler handler = (_, _) => DispatcherQueue.TryEnqueue(Update);
        metadata.PropertyChanged += handler;
        Track(new Disposer(() => metadata.PropertyChanged -= handler));
        var card = new SettingsCard("Fetch Missing Info", null, buttons, Glyphs.Download);
        card.Body.Children.OfType<StackPanel>().First().Children.Add(jobText);
        panel.Children.Add(card);
        panel.Children.Add(Footer("Also in the File menu, Library. MusicBrainz allows one request per second, so a large library takes a while; it runs in the background."));
        panel.Children.Add(Header("MusicBrainz"));
        var contact = new TextBox { Text = preferences.String(MetadataStore.ContactKey) ?? "", PlaceholderText = "Email or website", Width = 280 };
        contact.TextChanged += (_, _) => preferences.Set(MetadataStore.ContactKey, contact.Text);
        panel.Children.Add(new SettingsCard("Contact (optional)", null, contact, Glyphs.Globe));
        panel.Children.Add(Footer("Sent with MusicBrainz requests so its operators can reach you about heavy use. Metadata and credits come from MusicBrainz, covers from the Cover Art Archive and Apple Music, lyrics from LRCLIB, album backgrounds from Wikipedia."));
        return panel;
    }

    // MARK: Shortcuts

    private FrameworkElement Shortcuts()
    {
        var store = Model.Shortcuts;
        var panel = Ui.Column(4);
        foreach (var group in Enum.GetValues<ShortcutGroup>())
        {
            panel.Children.Add(Header(ShortcutStore.GroupTitle(group)));
            foreach (var action in Enum.GetValues<ShortcutAction>().Where(action => ShortcutStore.GroupOf(action) == group))
                panel.Children.Add(ShortcutRow(action));
        }
        var restore = Ui.Button("Restore Defaults", () => { store.ResetAll(); Refresh(); });
        restore.IsEnabled = Enum.GetValues<ShortcutAction>().Any(store.IsCustomized);
        panel.Children.Add(new SettingsCard("Click a shortcut, then press the new keys. Esc cancels, Delete removes the shortcut. Space plays and pauses outside text fields.", null, restore).Margin(0, 16, 0, 0));
        return panel;
    }

    private FrameworkElement ShortcutRow(ShortcutAction action)
    {
        var store = Model.Shortcuts;
        var message = Ui.Text("", "CaptionText").With(t => { t.Foreground = new SolidColorBrush(Microsoft.UI.Colors.IndianRed); t.Visibility = Visibility.Collapsed; });
        var recorder = new ShortcutRecorder(action, problem =>
        {
            message.Text = problem ?? "";
            message.Visibility = problem is null ? Visibility.Collapsed : Visibility.Visible;
            if (problem is null) Refresh();
        });
        var controls = Ui.Row(6);
        if (store.IsCustomized(action))
        {
            controls.Children.Add(Ui.IconButton("", $"Reset to {ShortcutStore.Default(action)?.Display() ?? "none"}", () => { store.Reset(action); Refresh(); }, 13));
        }
        controls.Children.Add(recorder);
        var card = new SettingsCard(ShortcutStore.Title(action), null, controls);
        card.Card.Padding = new Thickness(16, 8, 16, 8);
        card.Body.Children.OfType<StackPanel>().First().Children.Add(message);
        return card;
    }
}

/// <summary>Shows an action's shortcut; click it to record a new one from the next key press.</summary>
public sealed partial class ShortcutRecorder : Button
{
    /// <summary>A shortcut is being recorded: the window does not run shortcuts meanwhile.</summary>
    public static bool IsRecording { get; private set; }

    private readonly ShortcutAction action;
    private readonly Action<string?> onResult;
    private bool recording;

    public ShortcutRecorder(ShortcutAction action, Action<string?> onResult)
    {
        this.action = action;
        this.onResult = onResult;
        MinWidth = 130;
        Show();
        Click += (_, _) =>
        {
            recording = !recording;
            IsRecording = recording;
            Show();
        };
        LostFocus += (_, _) => { recording = false; IsRecording = false; Show(); };
        PreviewKeyDown += OnKey;
    }

    private void Show()
    {
        var shortcut = AppModel.Current.Shortcuts.Shortcut(action);
        Content = recording ? "Type Shortcut…" : shortcut?.Display() ?? "None";
        Opacity = !recording && shortcut is null ? 0.7 : 1;
    }

    private static bool IsDown(Windows.System.VirtualKey key) =>
        Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

    private void OnKey(object sender, KeyRoutedEventArgs args)
    {
        if (!recording) return;
        args.Handled = true;
        var store = AppModel.Current.Shortcuts;
        var ctrl = IsDown(Windows.System.VirtualKey.Control);
        var alt = IsDown(Windows.System.VirtualKey.Menu);
        var shift = IsDown(Windows.System.VirtualKey.Shift);
        var plain = !ctrl && !alt && !shift;
        if (args.Key is Windows.System.VirtualKey.Control or Windows.System.VirtualKey.Menu or Windows.System.VirtualKey.Shift
            or Windows.System.VirtualKey.LeftWindows or Windows.System.VirtualKey.RightWindows or Windows.System.VirtualKey.LeftControl
            or Windows.System.VirtualKey.RightControl or Windows.System.VirtualKey.LeftMenu or Windows.System.VirtualKey.RightMenu
            or Windows.System.VirtualKey.LeftShift or Windows.System.VirtualKey.RightShift) return;
        if (args.Key == Windows.System.VirtualKey.Escape && plain)
        {
            Stop();
            return;
        }
        if (args.Key is Windows.System.VirtualKey.Back or Windows.System.VirtualKey.Delete && plain)
        {
            onResult(store.Set(StoredShortcut.None, action));
            Stop();
            return;
        }
        if (StoredShortcut.KeyCharacter(args.Key) is not { } key || (!ctrl && !alt && !StoredShortcut.IsFunctionKey(key)))
        {
            onResult("Use Ctrl or Alt with a key (or a function key).");
            return;
        }
        var stored = new StoredShortcut(key.ToString(), (ctrl ? StoredShortcut.Command : 0) | (alt ? StoredShortcut.Option : 0) | (shift ? StoredShortcut.Shift : 0));
        var problem = store.Set(stored, action);
        onResult(problem);
        if (problem is null) Stop();
    }

    private void Stop()
    {
        recording = false;
        IsRecording = false;
        Show();
    }
}

/// <summary>Runs an action when disposed.</summary>
public sealed class Disposer(Action action) : IDisposable
{
    private Action? action = action;

    public void Dispose()
    {
        action?.Invoke();
        action = null;
    }
}
