using System.ComponentModel;
using Groovelight.Core.Devices;
using Groovelight.Core.Library;
using Groovelight.Model;
using Groovelight.Support;
using Groovelight.Wireless;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Groovelight.Views;

/// <summary>
/// A portable player, memory card or paired phone (the Mac's DeviceView): how full it is, what a sync would change, what
/// to sync to it, its format, and for phones whether they may play on this PC and connect away from home.
/// </summary>
public sealed partial class DevicePage : PageView
{
    private readonly string deviceId;
    private readonly StackPanel panel = new() { Spacing = 8, MaxWidth = 900 };
    private readonly StackPanel header = new() { Spacing = 10 };
    private readonly StackPanel selectionPanel = new() { Spacing = 6 };
    private readonly ListView choices = new() { SelectionMode = ListViewSelectionMode.None, Height = 280 };
    private readonly TextBox filter = new() { PlaceholderText = "Filter" };
    private readonly TextBlock summary = Ui.Text("", "WrappingSecondaryText");
    private DeviceSelection selection = new();
    private string kind = "Playlists";
    private List<string> artists = [], genres = [];
    private List<AlbumSummary> albums = [];
    private bool loading;

    private DeviceStore Store => Model.Devices;

    public DevicePage(string deviceId)
    {
        this.deviceId = deviceId;
        selection = Store.Selection(deviceId);
        Content = Scroll(panel);
        filter.TextChanged += (_, _) => FillChoices();
        Store.PropertyChanged += OnStoreChanged;
        Store.PreviewChanged += OnPreviewChanged;
        Observations.Add(new Observation<(List<string>, List<AlbumSummary>, List<string>)>(Model.Database,
            db => (db.Artists().Select(artist => artist.Name).ToList(), db.Albums(AlbumSort.Artist), db.Genres()), value =>
            {
                (artists, albums, genres) = value;
                FillChoices();
            }));
        Build();
    }

    public override string Title => Store.Find(deviceId)?.Name ?? "Device";

    public override void Dispose()
    {
        Store.PropertyChanged -= OnStoreChanged;
        Store.PreviewChanged -= OnPreviewChanged;
        base.Dispose();
    }

    public override IEnumerable<UIElement> Toolbar()
    {
        if (Store.Find(deviceId) is not { } device) yield break;
        if (device.IsWireless)
            yield return Ui.IconButton(Glyphs.Delete, $"Remove Device: {device.Name} can no longer sync until it pairs again", () => Model.Wireless?.Unpair(DeviceStore.PairedId(device)));
        else yield return Ui.IconButton(Glyphs.Eject, $"Eject {device.Name}", () => Store.Eject(device));
        yield return Ui.IconButton(Glyphs.Sync, $"Sync: make {device.Name} hold the chosen music", () => Store.Sync(device));
    }

    private void OnStoreChanged(object? sender, PropertyChangedEventArgs args)
    {
        switch (args.PropertyName)
        {
            case nameof(DeviceStore.CurrentJob) or nameof(DeviceStore.Devices):
                DispatcherQueue.TryEnqueue(BuildHeader);
                break;
            case nameof(DeviceStore.SelectionRevision):
                // Changed elsewhere (a phone asked for an album): shown here at once.
                DispatcherQueue.TryEnqueue(() =>
                {
                    var saved = Store.Selection(deviceId);
                    if (WireJson.Encode(saved).AsSpan().SequenceEqual(WireJson.Encode(selection))) return;
                    selection = saved;
                    Build();
                });
                break;
        }
    }

    private void OnPreviewChanged(string id)
    {
        if (id == deviceId) DispatcherQueue.TryEnqueue(BuildHeader);
    }

    private void Changed()
    {
        if (loading) return;
        Store.SetSelection(selection, deviceId);
        UpdateSummary();
    }

    private void Build()
    {
        loading = true;
        panel.Children.Clear();
        if (Store.Find(deviceId) is not { } device)
        {
            panel.Children.Add(Ui.Unavailable(Glyphs.Device, "Device Not Connected"));
            loading = false;
            return;
        }
        panel.Children.Add(new Border { Style = Ui.Style("CardBorder"), Padding = new Thickness(20), Child = header });
        BuildHeader();
        BuildSelection();
        panel.Children.Add(SettingsPage.Header("Format"));
        var formats = new List<string> { device.IsPlayer ? "As they are (FLAC when needed)" : "As they are" };
        formats.AddRange(LossyEncodings.All.Select(encoding => encoding.DisplayName()));
        var encoding = Store.Encoding(deviceId);
        panel.Children.Add(new SettingsCard("Lossless songs",
            "FLAC, ALAC, WAV, AIFF and other lossless songs can go to this device in a lossy format, about a fifth of their size or less: Opus at 160 kbps, AAC at 192 kbps and MP3 at 320 kbps are each close to transparent. Songs that are already lossy are copied as they are. Hi-res songs are brought down to 44.1 or 48 kHz. Encoded songs are made at the next sync, once each, and kept until they change.",
            SettingsPage.Choice(formats, encoding is { } chosen ? LossyEncodings.All.ToList().IndexOf(chosen) + 1 : 0,
                index => Store.SetEncoding(index == 0 ? null : LossyEncodings.All[index - 1], deviceId))));
        if (device.IsWireless && Model.Wireless is { } wireless)
        {
            var paired = DeviceStore.PairedId(device);
            if (device.IsPlayer)
            {
                panel.Children.Add(SettingsPage.Header("Play On"));
                panel.Children.Add(new SettingsCard($"Let {device.Name} play music on this PC and your other devices",
                    "The device can then choose this PC, or another phone with Groovelight open, under Play On: start and pause songs there, skip, seek and set the volume, and take what plays there over to itself. Only while they are on the same Wi-Fi as this PC, or allowed away from home below, with Groovelight open here.",
                    SettingsPage.Toggle(wireless.ControlsPlaybackOf(paired), on => wireless.SetControlsPlayback(paired, on))));
            }
            panel.Children.Add(SettingsPage.Header("Away From Home"));
            panel.Children.Add(new SettingsCard($"Let {device.Name} connect away from home", WirelessSyncService.AwayAddress is { } address
                    ? $"Through Tailscale, with this PC at {address}: the device syncs and plays as it does at home, once Tailscale is on there too. It learns the address at its next connection at home. Pairing is still only at home."
                    : "Through Tailscale, a private network between your devices: install it on this PC and on the device, sign in to the same account, and the device syncs and plays as it does at home. Pairing is still only at home.",
                SettingsPage.Toggle(wireless.ConnectsAway(paired), on => wireless.SetConnectsAway(paired, on))));
        }
        panel.Children.Add(new SettingsCard("Layout on devices", "Folders, covers, lyrics and playlists on devices are set in Settings, Devices.",
            Ui.Button("Layout Settings", () =>
            {
                Model.Preferences.Set(SettingsPage.LastSectionKey, "Devices");
                MainWindow.Current.ShowSettings();
            })));
        loading = false;
        UpdateSummary();
    }

    /// <summary>Name, format, a capacity bar (Groovelight's music, other files, free space), what a sync would change, and the progress of a sync.</summary>
    private void BuildHeader()
    {
        header.Children.Clear();
        if (Store.Find(deviceId) is not { } device) return;
        var preview = Store.Previews.GetValueOrDefault(deviceId);
        var used = Math.Max(device.Capacity - device.Available, 0);
        var music = Math.Min(preview?.MusicBytes ?? 0, used);
        var details = string.Join(" · ", new[] { device.Format, device.Capacity > 0 ? Format.Bytes(device.Capacity) : "", device.IsWireless ? device.IsOnline ? "Online" : "Offline" : "" }
            .Where(part => part.Length > 0));
        header.Children.Add(Ui.Row(14, Ui.Icon(device.IsWireless ? Glyphs.Phone : Glyphs.Device, 34, "SecondaryIcon"),
            Ui.Column(2, Ui.Text(device.Name, "SectionTitleText"), Ui.Text(details, "SecondaryText"))));
        if (device.IsPlayer)
            header.Children.Add(Ui.Text("Groovelight plays the music on this device. Covers, lyrics and playlists come with the library, and songs in formats it cannot play are converted to FLAC as they sync.", "WrappingSecondaryText"));
        header.Children.Add(CapacityBar(device.Capacity, music, used - music, preview is null ? null : Math.Clamp(used + preview.NetBytes, 0, device.Capacity)));
        if (device.Volumes.Count > 1 || device.Volumes.Any(volume => volume.Removable))
        {
            // Where the music is on a device with an SD card: the bar above is that storage.
            foreach (var volume in device.Volumes)
            {
                var row = Ui.Row(6, Ui.Icon(volume.Removable ? Glyphs.Device : Glyphs.Phone, 14), Ui.Text(volume.Name),
                    Ui.Text($"{Format.Bytes(volume.Free)} free of {Format.Bytes(volume.Total)}", "SecondaryText"));
                if (volume.Music) row.Children.Add(new Border { CornerRadius = new CornerRadius(8), Padding = new Thickness(6, 1, 6, 1), Background = Ui.Brush("AccentFillColorDefaultBrush"),
                    Child = Ui.Text("Music folder", "CaptionText").With(text => text.Foreground = Ui.Brush("TextOnAccentFillColorPrimaryBrush")) });
                header.Children.Add(row);
            }
        }
        header.Children.Add(Ui.Row(16, Legend("AccentFillColorDefaultBrush", "Music", music), Legend("ControlStrongFillColorDisabledBrush", "Other", used - music),
            Legend("ControlFillColorTertiaryBrush", "Free", device.Available)));
        if (Store.CurrentJob is { } job && job.DeviceId == device.Id) header.Children.Add(JobRow(job));
        else if (device.IsWireless && preview is null)
        {
            var row = Ui.Grid("*,auto");
            row.Children.Add(Ui.Text("What a sync will change shows here after the device's first sync.", "WrappingSecondaryText"));
            var sync = Ui.Button("Sync", () => Store.Sync(device), style: "AccentPillButton");
            sync.IsEnabled = Store.CurrentJob?.IsRunning != true && !Store.Selection(deviceId).IsEmpty;
            row.Children.Add(sync.At(1));
            header.Children.Add(row);
        }
        else if (preview is not null)
        {
            var row = Ui.Grid("*,auto");
            var text = Ui.Text(Describe(preview, device.Available), "WrappingSecondaryText");
            if (preview.NetBytes > device.Available) text.Foreground = Ui.Brush("SystemFillColorCriticalBrush");
            row.Children.Add(text);
            var sync = Ui.Button("Sync", () => Store.Sync(device), style: "AccentPillButton");
            sync.IsEnabled = (preview.FilesToWrite > 0 || preview.FilesToRemove > 0) && Store.CurrentJob?.IsRunning != true;
            row.Children.Add(sync.At(1));
            header.Children.Add(row);
            foreach (var line in preview.Skipped.Take(3))
                header.Children.Add(Ui.Row(6, Ui.Icon(Glyphs.Warning, 12), Ui.Text(line, "CaptionText")).With(item => item.Opacity = 0.9));
        }
    }

    private static FrameworkElement Legend(string brush, string label, long value) =>
        Ui.Row(6, new Border { Width = 9, Height = 9, CornerRadius = new CornerRadius(4.5), Background = Ui.Brush(brush), VerticalAlignment = VerticalAlignment.Center },
            Ui.Text(label), Ui.Text(Format.Bytes(Math.Max(value, 0)), "SecondaryText"));

    private static FrameworkElement CapacityBar(long capacity, long music, long other, long? afterSync)
    {
        var total = Math.Max(capacity, 1);
        var grid = new Grid { Height = 12, CornerRadius = new CornerRadius(6), Background = Ui.Brush("ControlFillColorTertiaryBrush") };
        var bars = Ui.Grid($"{Math.Max(music, 0)}*,{Math.Max(other, 0)}*,{Math.Max(total - music - other, 0)}*");
        bars.Children.Add(new Border { Background = Ui.Brush("AccentFillColorDefaultBrush") });
        bars.Children.Add(new Border { Background = Ui.Brush("ControlStrongFillColorDisabledBrush") }.At(1));
        grid.Children.Add(bars);
        var holder = new Grid();
        holder.Children.Add(grid);
        if (afterSync is { } after)
        {
            // Used space once the sync is done.
            var marker = Ui.Grid($"{after}*,auto,{Math.Max(total - after, 0)}*");
            marker.Children.Add(new Border { Width = 2, Height = 18, Background = Ui.Brush("TextFillColorPrimaryBrush"), Margin = new Thickness(0, -3, 0, -3) }.At(1));
            ToolTipService.SetToolTip(marker, "Used after the sync");
            holder.Children.Add(marker);
        }
        return holder;
    }

    /// <summary>A sync, send or export: progress with Cancel, then how it went.</summary>
    public static FrameworkElement JobRow(DeviceStore.Job job)
    {
        var store = AppModel.Current.Devices;
        var row = Ui.Grid("auto,*,auto");
        row.ColumnSpacing = 10;
        switch (job.Phase)
        {
            case DeviceStore.JobPhase.Waiting:
                row.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
                row.Children.Add(Ui.Text("Waiting for the device: open Groovelight on it, or wait for its next automatic sync.", "WrappingSecondaryText").At(1));
                row.Children.Add(Ui.Button("Cancel", store.Cancel).At(2));
                break;
            case DeviceStore.JobPhase.Planning:
                row.Children.Add(new ProgressRing { IsActive = true, Width = 16, Height = 16 });
                row.Children.Add(Ui.Text($"{job.Title}: getting ready…").At(1));
                break;
            case DeviceStore.JobPhase.Copying:
                row.Children.Add(Ui.Text($"{job.Done} of {job.Total}", "SecondaryText"));
                row.Children.Add(new ProgressBar { Maximum = Math.Max(job.Total, 1), Value = job.Done, VerticalAlignment = VerticalAlignment.Center }.At(1));
                row.Children.Add(Ui.Button("Cancel", store.Cancel).At(2));
                break;
            default:
                var ok = job.Phase == DeviceStore.JobPhase.Finished;
                row.Children.Add(Ui.Icon(ok ? Glyphs.Check : Glyphs.Warning, 14));
                row.Children.Add(Ui.Text(job.Message, "WrappingSecondaryText").At(1));
                row.Children.Add(Ui.Button("OK", store.DismissJob).At(2));
                break;
        }
        return row;
    }

    private static string Describe(DeviceStore.Preview preview, long available)
    {
        if (preview.FilesToWrite == 0 && preview.FilesToRemove == 0) return preview.Songs == 0 ? "Choose music below to sync." : $"{preview.Songs} songs, up to date.";
        var parts = new List<string> { $"{preview.Songs} songs" };
        if (preview.FilesToWrite > 0) parts.Add($"Sync copies {preview.FilesToWrite} files ({Format.Bytes(preview.BytesToWrite)})");
        if (preview.FilesToRemove > 0) parts.Add($"removes {preview.FilesToRemove}");
        var after = available - preview.NetBytes;
        parts.Add(after >= 0 ? $"{Format.Bytes(after)} free after" : $"{Format.Bytes(-after)} more than fits");
        return string.Join(", ", parts) + ".";
    }

    /// <summary>What the device holds: everything, or chosen playlists, artists, albums and genres.</summary>
    private void BuildSelection()
    {
        panel.Children.Add(SettingsPage.Header("Music to Sync"));
        selectionPanel.Children.Clear();
        var everything = SettingsPage.Toggle(selection.Everything, on =>
        {
            selection.Everything = on;
            Changed();
            BuildSelectionBody();
        });
        selectionPanel.Children.Add(new SettingsCard("All music", null, everything));
        panel.Children.Add(selectionPanel);
        BuildSelectionBody();
        panel.Children.Add(summary);
    }

    private readonly StackPanel selectionBody = new() { Spacing = 6 };

    private void BuildSelectionBody()
    {
        if (!selectionPanel.Children.Contains(selectionBody)) selectionPanel.Children.Add(selectionBody);
        selectionBody.Children.Clear();
        if (selection.Everything) return;
        selectionBody.Children.Add(new SettingsCard("Loved Songs", null, SettingsPage.Toggle(selection.LovedSongs, on =>
        {
            selection.LovedSongs = on;
            Changed();
        })));
        var kinds = new SelectorBar();
        foreach (var name in new[] { "Playlists", "Artists", "Albums", "Genres" })
        {
            var item = new SelectorBarItem { Text = name, IsSelected = name == kind };
            kinds.Items.Add(item);
        }
        kinds.SelectionChanged += (_, _) =>
        {
            kind = kinds.SelectedItem?.Text ?? "Playlists";
            filter.PlaceholderText = $"Filter {kind.ToLowerInvariant()}";
            FillChoices();
        };
        filter.PlaceholderText = $"Filter {kind.ToLowerInvariant()}";
        selectionBody.Children.Add(new Border
        {
            Style = Ui.Style("CardBorder"), Padding = new Thickness(16, 10, 16, 10), Child = Ui.Column(8, kinds, filter, choices),
        });
        FillChoices();
    }

    private bool Matches(string text) => filter.Text.Length == 0 || text.Contains(filter.Text, StringComparison.CurrentCultureIgnoreCase);

    private CheckBox Choice<T>(string text, string? detail, T value, HashSet<T> set)
    {
        var box = new CheckBox { IsChecked = set.Contains(value), Content = detail is null ? text : Ui.Row(8, Ui.Text(text), Ui.Text(detail, "SecondaryText")) };
        box.Checked += (_, _) =>
        {
            set.Add(value);
            Changed();
        };
        box.Unchecked += (_, _) =>
        {
            set.Remove(value);
            Changed();
        };
        return box;
    }

    private void FillChoices()
    {
        if (selection.Everything) return;
        var items = new List<CheckBox>();
        switch (kind)
        {
            case "Playlists":
                foreach (var playlist in Model.Playlists.Where(playlist => Matches(playlist.Name)))
                    if (playlist.Id is { } id) items.Add(Choice(playlist.Name, null, id, selection.PlaylistIds));
                break;
            case "Artists":
                items.AddRange(artists.Where(Matches).Select(name => Choice(name, null, name, selection.Artists)));
                break;
            case "Albums":
                items.AddRange(albums.Where(album => Matches(album.Title) || Matches(album.Artist)).Select(album => Choice(album.Title, album.Artist, album.AlbumKey, selection.AlbumKeys)));
                break;
            default:
                items.AddRange(genres.Where(Matches).Select(genre => Choice(genre, null, genre, selection.Genres)));
                break;
        }
        choices.ItemsSource = items;
    }

    private void UpdateSummary()
    {
        var removed = selection.ExcludedTrackIds.Count;
        var removedNote = removed == 0 ? "" : $" {removed} song{(removed == 1 ? " was" : "s were")} removed from the device there, and stay off it.";
        string text;
        if (selection.Everything) text = "Every song in the library. Songs removed from the library are removed from the device at the next sync.";
        else
        {
            var parts = new List<string>();
            if (selection.LovedSongs) parts.Add("Loved Songs");
            void Count(int number, string noun) { if (number > 0) parts.Add($"{number} {noun}{(number == 1 ? "" : "s")}"); }
            Count(selection.PlaylistIds.Count, "playlist");
            Count(selection.Artists.Count, "artist");
            Count(selection.AlbumKeys.Count, "album");
            Count(selection.Genres.Count, "genre");
            Count(selection.TrackIds.Count, "song");
            text = parts.Count == 0 ? "Nothing chosen yet. Songs added with Send To stay on the device; a sync only removes songs it put there."
                : $"Syncing {Format.List(parts)}. A sync only removes songs it put there; other files on the drive are left alone.";
        }
        summary.Text = text + removedNote;
        if (removed > 0 && panel.Children.OfType<Button>().All(button => button.Tag as string != "bring-back"))
        {
            var bring = Ui.Button("Bring Back Removed Songs", () =>
            {
                selection.ExcludedTrackIds.Clear();
                Changed();
                Build();
            });
            bring.Tag = "bring-back";
            ToolTipService.SetToolTip(bring, "Songs removed on the device come back at its next sync");
            panel.Children.Insert(panel.Children.IndexOf(summary) + 1, bring);
        }
    }
}

/// <summary>A device asks to pair: its name and the code, which must match the one on its screen.</summary>
public static class PairingDialog
{
    public static async Task ShowAsync(XamlRoot root, WirelessSyncService.PairingPrompt prompt)
    {
        var code = new TextBlock
        {
            Text = prompt.Code[..3] + " " + prompt.Code[3..], FontSize = 44, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 6, 0, 6),
        };
        code.FontFeatures();
        var content = Ui.Column(10, Ui.Icon(Glyphs.Phone, 40, "SecondaryIcon"), code,
            Ui.Text("Allow it only if the device shows the same code. It will be able to download the music you choose for it.", "WrappingSecondaryText")
                .With(text => text.TextAlignment = TextAlignment.Center));
        if (prompt.Request.Model is { } model) content.Children.Insert(1, Ui.Text(model, "SecondaryText").With(text => text.HorizontalAlignment = HorizontalAlignment.Center));
        var dialog = new ContentDialog
        {
            Title = $"Pair with “{prompt.Request.Name}”?", Content = content, PrimaryButtonText = "Allow", CloseButtonText = "Don't Allow", DefaultButton = ContentDialogButton.Primary,
            XamlRoot = root,
        };
        var allow = await ContentDialogs.ShowAsync(dialog) == ContentDialogResult.Primary;
        AppModel.Current.Wireless?.AnswerPairing(prompt, allow);
    }
}

/// <summary>Settings, Devices (the Mac's DevicesSettings): the layout on every device, wireless sync, and the paired devices.</summary>
public static class DevicesSettings
{
    public static FrameworkElement Build(SettingsPage page)
    {
        var model = AppModel.Current;
        var panel = new StackPanel { Spacing = 4 };
        var layout = model.Devices.Layout;
        void Save() => model.Devices.Layout = layout;
        panel.Children.Add(SettingsPage.Header("Layout on Devices"));
        var example = Ui.Text("", "SecondaryText");
        void UpdateExample()
        {
            var fields = new NamingFields("Paranoid Android", "Radiohead", "OK Computer", "Radiohead", "Alternative", 1997, 2, 1, 1, false);
            var path = FileNaming.RelativePath(fields, "flac", new OrganizeOptions { Template = layout.Template, PortableNames = true });
            var folder = string.Join("/", layout.MusicFolder.Split('/', StringSplitOptions.RemoveEmptyEntries));
            example.Text = "\\" + (folder.Length == 0 ? path : $"{folder}/{path}").Replace('/', '\\');
        }
        TextBox Field(string value, string placeholder, Action<string> changed)
        {
            var box = new TextBox { Text = value, PlaceholderText = placeholder, Width = 280 };
            box.TextChanged += (_, _) =>
            {
                changed(box.Text);
                Save();
                UpdateExample();
            };
            return box;
        }
        panel.Children.Add(new SettingsCard("Music folder", "For memory cards and players. On Android, songs go in the folder chosen in the Groovelight app; on iPhone and iPad, in the app's own storage.",
            Field(layout.MusicFolder, "Root of the drive", value => layout.MusicFolder = value)));
        var presets = OrganizeOptions.Presets.ToList();
        var isCustom = presets.All(preset => preset.Template != layout.Template);
        var template = Field(layout.Template, "", value => layout.Template = value);
        template.FontFamily = new FontFamily("Cascadia Mono, Consolas");
        template.Visibility = isCustom ? Visibility.Visible : Visibility.Collapsed;
        var names = SettingsPage.Choice(presets.Select(preset => preset.Name).Append("Custom").ToList(), isCustom ? presets.Count : presets.FindIndex(preset => preset.Template == layout.Template),
            index =>
            {
                if (index < presets.Count)
                {
                    layout.Template = presets[index].Template;
                    template.Text = layout.Template;
                    Save();
                }
                template.Visibility = index == presets.Count ? Visibility.Visible : Visibility.Collapsed;
                UpdateExample();
            });
        panel.Children.Add(new SettingsCard("Folders and names", null, Ui.Column(6, names, template)));
        UpdateExample();
        panel.Children.Add(new SettingsCard("Example", null, example));
        var playlistFolder = Field(layout.PlaylistFolder, "Root of the drive", value => layout.PlaylistFolder = value);
        panel.Children.Add(new SettingsCard("Playlists (M3U8)", null, Ui.Row(12, playlistFolder, SettingsPage.Toggle(layout.WritesPlaylists, on =>
        {
            layout.WritesPlaylists = on;
            playlistFolder.IsEnabled = on;
            Save();
        }))));
        playlistFolder.IsEnabled = layout.WritesPlaylists;
        var sizes = DeviceProfile.CoverSizes.ToList();
        var coverSize = SettingsPage.Choice(sizes.Select(size => size == 0 ? "Original" : $"{size} × {size}").ToList(), Math.Max(0, sizes.IndexOf(layout.CoverSize)), index =>
        {
            layout.CoverSize = sizes[index];
            Save();
        });
        coverSize.IsEnabled = layout.WritesCovers;
        panel.Children.Add(new SettingsCard("Cover image in each album folder (cover.jpg)", "Many players read cover.jpg; smaller covers load faster on players with little memory.",
            Ui.Row(12, coverSize, SettingsPage.Toggle(layout.WritesCovers, on =>
            {
                layout.WritesCovers = on;
                coverSize.IsEnabled = on;
                Save();
            }))));
        panel.Children.Add(new SettingsCard("Synced lyrics (.lrc files)", null, SettingsPage.Toggle(layout.WritesLyrics, on =>
        {
            layout.WritesLyrics = on;
            Save();
        })));
        panel.Children.Add(Ui.Text("Names are made safe for any file system, and FAT32 cards leave out files over 4 GB. Changes apply at the next sync.", "WrappingSecondaryText").Margin(4, 4, 0, 0));

        panel.Children.Add(SettingsPage.Header("Wireless Sync"));
        if (model.Wireless is not { } wireless) return panel;
        var details = new StackPanel { Spacing = 4 };
        void UpdateDetails()
        {
            details.Children.Clear();
            if (!wireless.IsEnabled) return;
            details.Children.Add(new SettingsCard("This PC", null, Ui.Text(wireless.Port is null ? "Starting…" : WirelessSyncService.HostName, "SecondaryText")));
            if (wireless.Port is { } port)
            {
                var addresses = WirelessSyncService.Addresses();
                details.Children.Add(new SettingsCard("Address", "Type it into the app when this PC is not listed.",
                    new TextBlock { Text = addresses.Count == 0 ? "Not on a network" : string.Join(", ", addresses.Select(address => $"{address} port {port}")), IsTextSelectionEnabled = true,
                        Style = Ui.Style("SecondaryText") }));
            }
            if (!WindowsFirewall.HasRule())
            {
                var allow = new Button { Content = "Allow in Windows Firewall" };
                var bar = new InfoBar
                {
                    IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning, Title = "Windows Firewall blocks phones",
                    Message = "Phones find this PC but cannot connect until Groovelight is allowed through Windows Firewall on private networks (ports 52300 and 52301). Windows asks for an administrator's permission.",
                    ActionButton = allow,
                };
                allow.Click += async (_, _) =>
                {
                    if (await WindowsFirewall.AllowAsync()) UpdateDetails();
                };
                details.Children.Add(bar);
            }
            if (WirelessSyncService.IsOnPublicNetwork())
            {
                details.Children.Add(new InfoBar
                {
                    IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning, Title = "This network is set to Public",
                    Message = "Windows hides this PC from other devices on Public networks. In Settings, Network & internet, set this network to Private so phones can find and reach it.",
                });
            }
            if (wireless.Paired.Count > 0)
            {
                details.Children.Add(SettingsPage.Header("Paired Devices"));
                foreach (var device in wireless.Paired)
                {
                    var parts = new List<string?> { device.Model, wireless.IsOnline(device) ? "Online" : device.LastSeen is { } seen ? "Last seen " + Format.Relative(seen) : null };
                    if (device.LastSyncAt is { } synced) parts.Add("Synced " + Format.Relative(synced));
                    details.Children.Add(new SettingsCard(device.Name, string.Join(" · ", parts.OfType<string>()), Ui.Button("Remove", () =>
                    {
                        wireless.Unpair(device.Id);
                        UpdateDetails();
                    }), Glyphs.Phone));
                }
            }
        }
        panel.Children.Add(new SettingsCard("Sync with phones and players over Wi-Fi",
            "Open Groovelight on an iPhone or iPad, or Groovelight for Android on an Android 12 or later player or phone, on the same Wi-Fi, and choose this PC (or type the address when it is not listed). Both screens show the same code: check it and allow the device here. Paired devices appear under Devices, with the same choices as memory cards, and sync whenever their app checks in.",
            SettingsPage.Toggle(wireless.IsEnabled, on =>
            {
                wireless.IsEnabled = on;
                UpdateDetails();
            })));
        panel.Children.Add(details);
        UpdateDetails();
        return panel;
    }
}

/// <summary>Plugs devices into the window: the sidebar items, their pages, Send To, the pairing prompt, Settings, Devices.</summary>
internal static class DeviceFeatures
{
    public static void Register()
    {
        var model = AppModel.Current;
        PageFactories.Device = id => new DevicePage(id);
        Shell.NavigationPane.Devices = () => model.Devices.Devices.Select(device => (device.Id, device.Name, device.IsWireless ? Glyphs.Phone : Glyphs.Device,
            (Action<NavigationViewItem>)(item => Configure(item, device)))).ToList();
        model.Devices.DevicesChanged += () => model.Queue.TryEnqueue(Shell.NavigationPane.InvalidateDevices);
        Menus.SendTo = source =>
        {
            var menu = new MenuFlyoutSubItem { Text = "Send to", Icon = new FontIcon { Glyph = Glyphs.Device } };
            foreach (var device in model.Devices.Devices)
            {
                var target = device;
                menu.Items.Add(Menus.Item(device.Name, () => model.Devices.Send(source, target), device.IsWireless ? Glyphs.Phone : Glyphs.Device));
            }
            if (menu.Items.Count > 0) menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(Menus.Item("Folder…", () => model.Devices.Export(source), Glyphs.Folder));
            menu.IsEnabled = model.Devices.CurrentJob?.IsRunning != true;
            return menu;
        };
        if (model.Wireless is { } wireless)
            wireless.PairingRequested += prompt => _ = PairingDialog.ShowAsync(MainWindow.Current.RootXamlRoot!, prompt);
        SettingsPage.Extra.Add((80, new SettingsSection("Devices", Glyphs.Device, DevicesSettings.Build)));
    }

    /// <summary>A device's sidebar item: songs and albums dropped on it join what it holds; its menu syncs, ejects or removes it.</summary>
    private static void Configure(NavigationViewItem item, DeviceStore.Device device)
    {
        var model = AppModel.Current;
        Shell.NavigationPane.AcceptSongs(item, _ => { }, $"Add to {device.Name}", data =>
        {
            var requests = data.AlbumKey is { } album
                ? [new TransferRequest(Guid.NewGuid().ToString(), TransferAction.Add, TransferKind.Album, album)]
                : data.Ids.Select(id => new TransferRequest(Guid.NewGuid().ToString(), TransferAction.Add, TransferKind.Song, id.ToString())).ToList();
            model.Devices.Add(requests, device);
        });
        if (!device.IsOnline) item.Opacity = 0.6;
        var items = new List<MenuFlyoutItemBase> { Menus.Item("Sync", () => model.Devices.Sync(device), Glyphs.Sync) };
        items.Add(device.IsWireless ? Menus.Item("Remove Device", () => model.Wireless?.Unpair(DeviceStore.PairedId(device)), Glyphs.Delete)
            : Menus.Item("Eject", () => model.Devices.Eject(device), Glyphs.Eject));
        item.ContextFlyout = Menus.Flyout(items);
    }
}
