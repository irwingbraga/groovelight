using System.Globalization;
using Groovelight.Controls;
using Groovelight.Core.Library;
using Groovelight.Model;
using Groovelight.Support;
using Groovelight.Views;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace Groovelight.Dialogs;

/// <summary>
/// Edits a playlist's name and cover (the Mac's Edit Playlist sheet): generated colors and patterns, the songs' covers or
/// a custom image (chosen or dropped on the preview), and whether the name is drawn on the cover.
/// </summary>
public sealed class EditPlaylistDialog(Playlist playlist)
{
    private readonly AppModel model = AppModel.Current;
    private PlaylistCoverKind kind = playlist.CoverStyle?.Kind ?? new PlaylistCoverKind.SongCovers();
    private bool showsTitle = playlist.CoverStyle?.ShowsTitle ?? false;
    private List<string> songHashes = [];
    private readonly TextBox name = new() { Text = playlist.Name, FontSize = 18, PlaceholderText = "Name" };
    private readonly PlaylistCoverImage preview = new() { Width = 230, Height = 230, Radius = 12 };
    private readonly CheckBox titleToggle = new() { Content = "Show name on cover" };
    private readonly StackPanel controls = new() { Spacing = 14 };

    private PlaylistCover Cover => new(kind, showsTitle);

    /// <summary>Palette and pattern of the current generated cover (or the defaults when another kind is selected).</summary>
    private (string Palette, string Pattern) Generated => kind is PlaylistCoverKind.Generated generated
        ? (generated.Palette, generated.Pattern)
        : (CoverPalette.ForSeed(playlist.Id ?? 0).Id, "none");

    public async Task ShowAsync(XamlRoot root)
    {
        var id = playlist.Id ?? -1;
        var tracks = await Task.Run(() => model.Database.Read(db => db.TracksOfPlaylist(id)));
        songHashes = tracks.Select(track => track.ArtworkHash).OfType<string>().Distinct().Take(4).ToList();
        var dialog = new ContentDialog
        {
            XamlRoot = root, Title = "Edit Playlist", PrimaryButtonText = "Save", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary,
        };
        dialog.Resources["ContentDialogMaxWidth"] = 720.0;
        name.TextChanged += (_, _) =>
        {
            dialog.IsPrimaryButtonEnabled = name.Text.Trim().Length > 0;
            Update();
        };
        titleToggle.Checked += (_, _) => { showsTitle = true; Update(); };
        titleToggle.Unchecked += (_, _) => { showsTitle = false; Update(); };
        var dropHint = Ui.Text("Drop an image on the cover to use it", "CaptionText").With(t => t.HorizontalAlignment = HorizontalAlignment.Center);
        preview.Translation = new System.Numerics.Vector3(0, 0, 24);
        preview.Shadow = new ThemeShadow();
        var previewHost = new Grid { AllowDrop = true, Background = Images.Transparent };
        previewHost.Children.Add(preview);
        previewHost.DragOver += (_, args) => { if (args.DataView.Contains(StandardDataFormats.StorageItems)) args.AcceptedOperation = DataPackageOperation.Copy; };
        previewHost.Drop += async (_, args) =>
        {
            var items = await args.DataView.GetStorageItemsAsync();
            if (items.FirstOrDefault()?.Path is { } path) await UseImageAsync(path);
        };
        var layout = Ui.Grid("auto,*");
        layout.ColumnSpacing = 24;
        layout.Children.Add(Ui.Column(10, previewHost, dropHint));
        layout.Children.Add(controls.At(1));
        layout.Width = 640;
        dialog.Content = layout;
        dialog.PrimaryButtonClick += (_, _) => Save();
        Update();
        await ContentDialogs.ShowAsync(dialog);
    }

    private void Update()
    {
        preview.Set(name.Text, Cover, songHashes, playlist.Id ?? 0);
        controls.Children.Clear();
        controls.Children.Add(name);
        // Only a custom image can go without the name: every other cover shows it.
        if (kind is PlaylistCoverKind.Image)
        {
            titleToggle.IsChecked = showsTitle;
            controls.Children.Add(titleToggle);
        }
        var palettes = new VariableSizedWrapGrid { Orientation = Orientation.Horizontal, ItemWidth = 40, ItemHeight = 40, MaximumRowsOrColumns = 6 };
        foreach (var palette in CoverPalette.All)
        {
            var selected = kind is PlaylistCoverKind.Generated && Generated.Palette == palette.Id;
            var swatch = new Microsoft.UI.Xaml.Shapes.Ellipse
            {
                Width = 28, Height = 28,
                Fill = new LinearGradientBrush
                {
                    StartPoint = new Windows.Foundation.Point(0, 0), EndPoint = new Windows.Foundation.Point(1, 1),
                    GradientStops =
                    {
                        new GradientStop { Color = Color(palette.Top), Offset = 0 },
                        new GradientStop { Color = Color(palette.Bottom), Offset = 1 },
                    },
                },
            };
            var ring = new Border { Width = 36, Height = 36, CornerRadius = new CornerRadius(18), BorderThickness = new Thickness(2.5), Child = swatch, BorderBrush = selected ? Ui.Brush("BrandBrush") : Images.Transparent };
            var button = new Button { Content = ring, Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = Images.Transparent };
            ToolTipService.SetToolTip(button, palette.Name);
            var id = palette.Id;
            button.Click += (_, _) => { kind = new PlaylistCoverKind.Generated(id, Generated.Pattern); Update(); };
            palettes.Children.Add(button);
        }
        controls.Children.Add(Ui.Column(8, Ui.Text("Colors", "StrongText", 13), palettes));
        var styles = Ui.Row(10);
        foreach (var (pattern, title) in CoverPattern.All)
        {
            var selected = kind is PlaylistCoverKind.Generated && Generated.Pattern == pattern;
            var thumbnail = new PlaylistCoverImage { Width = 52, Height = 52, Radius = 6 };
            thumbnail.Set("", new PlaylistCover(new PlaylistCoverKind.Generated(Generated.Palette, pattern)), [], 0, hidesTitle: true);
            styles.Children.Add(Tile(thumbnail, title, selected, () => { kind = new PlaylistCoverKind.Generated(Generated.Palette, pattern); Update(); }));
        }
        controls.Children.Add(Ui.Column(8, Ui.Text("Style", "StrongText", 13), styles));
        var others = Ui.Row(10);
        FrameworkElement songs = songHashes.Count == 0 ? Ui.Icon(Glyphs.Grid, 18, "SecondaryIcon") : new PlaylistCoverImage { Radius = 0 }.With(c => c.Set("", new PlaylistCover(new PlaylistCoverKind.SongCovers()), songHashes, 0, hidesTitle: true));
        var songTile = Tile(songs, "Song Covers", kind is PlaylistCoverKind.SongCovers, () => { kind = new PlaylistCoverKind.SongCovers(); Update(); });
        songTile.IsEnabled = songHashes.Count > 0;
        ToolTipService.SetToolTip(songTile, songHashes.Count == 0 ? "The playlist's songs have no artwork yet" : "Use the covers of the playlist's songs");
        others.Children.Add(songTile);
        var imageHash = (kind as PlaylistCoverKind.Image)?.Hash;
        FrameworkElement image = imageHash is null ? Ui.Icon("", 18, "SecondaryIcon") : new ArtworkImage { Hash = imageHash, Radius = 0 };
        var imageTile = Tile(image, imageHash is null ? "Image…" : "Image", imageHash is not null, async () =>
        {
            if (await Pickers.FileAsync(Pickers.ImageExtensions, "Use Image", Windows.Storage.Pickers.PickerLocationId.PicturesLibrary) is { } path) await UseImageAsync(path);
        });
        ToolTipService.SetToolTip(imageTile, "Choose an image file (or drop one on the cover)");
        others.Children.Add(imageTile);
        controls.Children.Add(Ui.Column(8, Ui.Text("Other", "StrongText", 13), others));
    }

    private static Windows.UI.Color Color((double R, double G, double B) rgb) =>
        Windows.UI.Color.FromArgb(255, (byte)(rgb.R * 255), (byte)(rgb.G * 255), (byte)(rgb.B * 255));

    /// <summary>A 52 pixel selectable tile with a caption.</summary>
    private static Button Tile(FrameworkElement content, string title, bool selected, Action action)
    {
        var box = new Grid { Width = 52, Height = 52, CornerRadius = new CornerRadius(6), Background = Ui.Brush("ControlFillColorSecondaryBrush") };
        box.Children.Add(content);
        var ring = new Border { CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(2.5), Padding = new Thickness(1.5), Child = box, BorderBrush = selected ? Ui.Brush("BrandBrush") : Images.Transparent };
        var column = Ui.Column(4, ring, Ui.Text(title, "CaptionText", 11).With(t => t.HorizontalAlignment = HorizontalAlignment.Center));
        var button = new Button { Content = column, Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = Images.Transparent };
        button.Click += (_, _) => action();
        return button;
    }

    /// <summary>Copies the image into the artwork cache and selects it.</summary>
    private async Task UseImageAsync(string path)
    {
        var hash = await Task.Run(() =>
        {
            try { return model.Artwork.Store(File.ReadAllBytes(path)); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return null; }
        });
        if (hash is null)
        {
            model.ErrorMessage = $"{Path.GetFileName(path)} is not an image Groovelight can read.";
            return;
        }
        kind = new PlaylistCoverKind.Image(hash);
        Update();
    }

    private void Save()
    {
        if (playlist.Id is not { } id) return;
        try
        {
            model.Database.UpdatePlaylist(id, name.Text.Trim(), Cover);
        }
        catch (Microsoft.Data.Sqlite.SqliteException error)
        {
            model.ErrorMessage = $"Could not save the playlist: {error.Message}";
        }
    }
}

/// <summary>Creates or edits a smart playlist: name, rules (match all or any), optional limit, with a live count of matches.</summary>
public sealed class SmartPlaylistDialog(Playlist? playlist)
{
    private readonly AppModel model = AppModel.Current;
    private readonly TextBox name = new() { Text = "Untitled Smart Playlist", FontSize = 18, PlaceholderText = "Name" };
    private SmartPlaylistRules rules = new();
    private bool hasLimit;
    private SmartLimit limit = new();
    private readonly StackPanel rulesPanel = new() { Spacing = 8 };
    private readonly TextBlock preview = Ui.Text("Counting…", "SecondaryText");
    private readonly CheckBox limitToggle = new() { Content = "Limit to", MinWidth = 0 };
    private readonly NumberBox limitCount = new() { Width = 90, Minimum = 1, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
    private readonly ComboBox limitUnit = new();
    private readonly ComboBox limitSelection = new();
    private readonly ComboBox match = new();
    private int previewTicket;

    private SmartPlaylistRules Effective => rules with { Rules = rules.Rules.ToList(), Limit = hasLimit ? limit : null };

    /// <summary>Ready-made rules offered when creating a smart playlist.</summary>
    private static IReadOnlyList<(string Name, SmartPlaylistRules Rules)> Templates =>
    [
        ("Recently Added", new() { Rules = [new SmartRule { Field = SmartField.DateAdded, Op = SmartOperator.InTheLast, Period = 2, PeriodUnit = PeriodUnit.Weeks }] }),
        ("Recently Played", new() { Rules = [new SmartRule { Field = SmartField.LastPlayed, Op = SmartOperator.InTheLast, Period = 2, PeriodUnit = PeriodUnit.Weeks }],
                                    Limit = new SmartLimit { Count = 50, SelectedBy = SmartLimitSelection.MostRecentlyPlayed } }),
        ("Top 25 Most Played", new() { Rules = [new SmartRule { Field = SmartField.Plays, Op = SmartOperator.GreaterThan, Number = 0 }],
                                       Limit = new SmartLimit { Count = 25, SelectedBy = SmartLimitSelection.MostPlayed } }),
        ("Hi-Res Lossless", new() { Rules = [new SmartRule { Field = SmartField.Quality, Op = SmartOperator.IsAtLeast, Quality = QualityTier.HiResLossless }] }),
        ("Lossless", new() { Rules = [new SmartRule { Field = SmartField.Quality, Op = SmartOperator.IsAtLeast, Quality = QualityTier.Lossless }] }),
        ("Never Played", new() { Rules = [new SmartRule { Field = SmartField.Plays, Op = SmartOperator.Is, Number = 0 }] }),
        ("Missing Artwork", new() { Rules = [new SmartRule { Field = SmartField.HasArtwork, Op = SmartOperator.IsFalse }] }),
        ("Missing Lyrics", new() { Rules = [new SmartRule { Field = SmartField.HasLyrics, Op = SmartOperator.IsFalse }] }),
        ("90s Music", new() { Rules = [new SmartRule { Field = SmartField.Year, Op = SmartOperator.InRange, Number = 1990, Number2 = 1999 }] }),
    ];

    public async Task ShowAsync(XamlRoot root)
    {
        if (playlist?.Rules is { } saved)
        {
            name.Text = playlist.Name;
            rules = saved with { Rules = saved.Rules.Select(rule => rule with { }).ToList() };
            if (saved.Limit is { } savedLimit) { hasLimit = true; limit = savedLimit with { }; }
            if (rules.Rules.Count == 0) rules.Rules = [new SmartRule()];
        }
        var dialog = new ContentDialog
        {
            XamlRoot = root, PrimaryButtonText = playlist is null ? "Create" : "Save", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary,
        };
        dialog.Resources["ContentDialogMaxWidth"] = 860.0;
        var titleRow = Ui.Grid("*,auto");
        titleRow.Children.Add(Ui.Text(playlist is null ? "New Smart Playlist" : "Edit Smart Playlist", "SectionTitleText"));
        if (playlist is null)
        {
            var templates = new DropDownButton { Content = "Templates" };
            templates.Flyout = Menus.Flyout(Templates.Select(template => (MenuFlyoutItemBase)Menus.Item(template.Name, () => Apply(template.Name, template.Rules))));
            titleRow.Children.Add(templates.At(1));
        }
        name.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = name.Text.Trim().Length > 0;
        match.Items.Add("all");
        match.Items.Add("any");
        match.SelectedIndex = rules.Match == SmartMatch.All ? 0 : 1;
        match.SelectionChanged += (_, _) => { rules.Match = match.SelectedIndex == 0 ? SmartMatch.All : SmartMatch.Any; Changed(); };
        var matchRow = Ui.Row(6, Label("Match"), match, Label("of the following rules:"));
        foreach (var unit in Enum.GetValues<SmartLimitUnit>()) limitUnit.Items.Add(unit.DisplayName());
        foreach (var selection in Enum.GetValues<SmartLimitSelection>()) limitSelection.Items.Add(selection.DisplayName());
        limitToggle.Checked += (_, _) => { hasLimit = true; SyncLimit(); Changed(); };
        limitToggle.Unchecked += (_, _) => { hasLimit = false; SyncLimit(); Changed(); };
        limitCount.ValueChanged += (_, args) => { if (!double.IsNaN(args.NewValue)) { limit.Count = (int)args.NewValue; Changed(); } };
        limitUnit.SelectionChanged += (_, _) => { if (limitUnit.SelectedIndex >= 0) { limit.Unit = (SmartLimitUnit)limitUnit.SelectedIndex; Changed(); } };
        limitSelection.SelectionChanged += (_, _) => { if (limitSelection.SelectedIndex >= 0) { limit.SelectedBy = (SmartLimitSelection)limitSelection.SelectedIndex; Changed(); } };
        SyncLimit();
        var limitRow = Ui.Row(6, limitToggle, limitCount, limitUnit, Label("selected by"), limitSelection);
        var content = Ui.Column(16, titleRow, name, matchRow,
            new ScrollViewer { Content = rulesPanel, MinHeight = 120, MaxHeight = 280 },
            Ui.Separator(), limitRow, Ui.Separator(), preview);
        content.Width = 780;
        dialog.Content = content;
        dialog.PrimaryButtonClick += (_, _) => Save();
        BuildRules();
        Changed();
        await ContentDialogs.ShowAsync(dialog);
    }

    private static TextBlock Label(string text) => Ui.Text(text, "BodyText").With(t => t.VerticalAlignment = VerticalAlignment.Center);

    private void SyncLimit()
    {
        limitToggle.IsChecked = hasLimit;
        limitCount.Value = limit.Count;
        limitUnit.SelectedIndex = (int)limit.Unit;
        limitSelection.SelectedIndex = (int)limit.SelectedBy;
        limitCount.IsEnabled = limitUnit.IsEnabled = limitSelection.IsEnabled = hasLimit;
    }

    private void Apply(string templateName, SmartPlaylistRules template)
    {
        name.Text = templateName;
        rules = template with { Rules = template.Rules.Select(rule => rule with { Id = Guid.NewGuid().ToString().ToUpperInvariant() }).ToList() };
        hasLimit = template.Limit is not null;
        limit = template.Limit is { } templateLimit ? templateLimit with { } : new SmartLimit();
        match.SelectedIndex = rules.Match == SmartMatch.All ? 0 : 1;
        SyncLimit();
        BuildRules();
        Changed();
    }

    private void BuildRules()
    {
        rulesPanel.Children.Clear();
        foreach (var rule in rules.Rules) rulesPanel.Children.Add(RuleRow(rule));
    }

    private static readonly (string Section, SmartField[] Fields)[] FieldSections =
    [
        ("Text", [SmartField.Title, SmartField.Artist, SmartField.Album, SmartField.AlbumArtist, SmartField.Composer, SmartField.Genre, SmartField.Comment, SmartField.Kind]),
        ("Numbers", [SmartField.Year, SmartField.Rating, SmartField.Plays, SmartField.Skips, SmartField.Time, SmartField.Bpm]),
        ("Audio", [SmartField.Quality, SmartField.SampleRate, SmartField.BitDepth, SmartField.Bitrate]),
        ("Dates", [SmartField.DateAdded, SmartField.LastPlayed]),
        ("Other", [SmartField.Loved, SmartField.Compilation, SmartField.HasArtwork, SmartField.HasLyrics]),
    ];

    /// <summary>One rule: field, operator, value editor, and remove / add buttons.</summary>
    private FrameworkElement RuleRow(SmartRule rule)
    {
        var row = Ui.Grid("150,160,*,auto");
        row.ColumnSpacing = 8;
        var field = new DropDownButton { Content = rule.Field.DisplayName(), HorizontalAlignment = HorizontalAlignment.Stretch };
        var fieldMenu = new MenuFlyout();
        foreach (var (section, fields) in FieldSections)
        {
            fieldMenu.Items.Add(new MenuFlyoutItem { Text = section, IsEnabled = false });
            foreach (var choice in fields)
            {
                fieldMenu.Items.Add(Menus.Item(choice.DisplayName(), () => { rule.SetField(choice); BuildRules(); Changed(); }));
            }
        }
        field.Flyout = fieldMenu;
        row.Children.Add(field);
        var op = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        var operators = SmartFields.Operators(rule.Field.KindOf());
        foreach (var item in operators) op.Items.Add(item.DisplayName());
        op.SelectedIndex = Math.Max(0, operators.ToList().IndexOf(rule.Op));
        op.SelectionChanged += (_, _) =>
        {
            if (op.SelectedIndex < 0) return;
            var changed = rule.Op != operators[op.SelectedIndex];
            rule.Op = operators[op.SelectedIndex];
            if (changed) { BuildRules(); Changed(); }
        };
        row.Children.Add(op.At(1));
        row.Children.Add(ValueEditor(rule).At(2));
        var remove = Ui.IconButton("", "Remove rule", () => { rules.Rules.Remove(rule); BuildRules(); Changed(); }, 12, "CircleButton");
        remove.IsEnabled = rules.Rules.Count > 1;
        var add = Ui.IconButton(Glyphs.Add, "Add rule", () =>
        {
            rules.Rules.Insert(rules.Rules.IndexOf(rule) + 1, new SmartRule());
            BuildRules();
            Changed();
        }, 12, "CircleButton");
        foreach (var button in new[] { remove, add }) { button.Width = button.Height = 28; }
        row.Children.Add(Ui.Row(6, remove, add).At(3));
        return row;
    }

    private FrameworkElement ValueEditor(SmartRule rule)
    {
        switch (rule.Field.KindOf())
        {
            case SmartFieldKind.Text:
            {
                var box = new TextBox { Text = rule.Text, PlaceholderText = "Value" };
                box.TextChanged += (_, _) => { rule.Text = box.Text; Changed(); };
                return box;
            }
            case SmartFieldKind.Number:
            {
                var row = Ui.Row(6);
                var first = new NumberBox { Value = rule.Number, Width = 100 };
                first.ValueChanged += (_, args) => { if (!double.IsNaN(args.NewValue)) { rule.Number = args.NewValue; Changed(); } };
                row.Children.Add(first);
                if (rule.Op == SmartOperator.InRange)
                {
                    row.Children.Add(Label("to"));
                    var second = new NumberBox { Value = rule.Number2, Width = 100 };
                    second.ValueChanged += (_, args) => { if (!double.IsNaN(args.NewValue)) { rule.Number2 = args.NewValue; Changed(); } };
                    row.Children.Add(second);
                }
                if (rule.Field.Unit() is { } unit) row.Children.Add(Ui.Text(unit, "SecondaryText").With(t => t.VerticalAlignment = VerticalAlignment.Center));
                return row;
            }
            case SmartFieldKind.Date when rule.Op is SmartOperator.InTheLast or SmartOperator.NotInTheLast:
            {
                var count = new NumberBox { Value = rule.Period, Width = 80, Minimum = 1 };
                count.ValueChanged += (_, args) => { if (!double.IsNaN(args.NewValue)) { rule.Period = (int)args.NewValue; Changed(); } };
                var unit = new ComboBox();
                foreach (var item in Enum.GetValues<PeriodUnit>()) unit.Items.Add(item.ToString().ToLowerInvariant());
                unit.SelectedIndex = (int)rule.PeriodUnit;
                unit.SelectionChanged += (_, _) => { rule.PeriodUnit = (PeriodUnit)unit.SelectedIndex; Changed(); };
                return Ui.Row(6, count, unit);
            }
            case SmartFieldKind.Date:
            {
                var picker = new CalendarDatePicker { Date = new DateTimeOffset(rule.Date.ToLocalTime()) };
                picker.DateChanged += (_, args) => { if (args.NewDate is { } date) { rule.Date = date.UtcDateTime; Changed(); } };
                return picker;
            }
            case SmartFieldKind.Bool:
                return new Grid();
            default:
            {
                var tiers = Enum.GetValues<QualityTier>().Reverse().ToList();
                var quality = new ComboBox();
                foreach (var tier in tiers) quality.Items.Add(tier.DisplayName());
                quality.SelectedIndex = tiers.IndexOf(rule.Quality);
                quality.SelectionChanged += (_, _) => { rule.Quality = tiers[quality.SelectedIndex]; Changed(); };
                return quality;
            }
        }
    }

    /// <summary>Debounced live preview of what the rules match.</summary>
    private async void Changed()
    {
        var ticket = ++previewTicket;
        await Task.Delay(250);
        if (ticket != previewTicket) return;
        var current = Effective;
        try
        {
            var tracks = await Task.Run(() => model.Database.Read(db => db.TracksMatching(current)));
            if (ticket != previewTicket) return;
            preview.Text = $"{Format.Count(tracks.Count, "song")} match, {Format.LongDuration(tracks.Sum(track => track.Duration))}";
        }
        catch (Microsoft.Data.Sqlite.SqliteException)
        {
            preview.Text = "";
        }
    }

    private void Save()
    {
        var trimmed = name.Text.Trim();
        try
        {
            if (playlist?.Id is { } id) model.Database.UpdateSmartPlaylist(id, trimmed, Effective);
            else
            {
                var created = model.Database.CreateSmartPlaylist(trimmed, Effective, PlaylistCovers.RandomGenerated());
                if (created.Id is { } createdId) model.Selection = SidebarItem.Playlist(createdId);
            }
        }
        catch (Microsoft.Data.Sqlite.SqliteException error)
        {
            model.ErrorMessage = $"Could not save the smart playlist: {error.Message}";
        }
    }
}
