using System.ComponentModel;
using Groovelight.Controls;
using Groovelight.Core.Library;
using Groovelight.Model;
using Groovelight.Support;
using Groovelight.Views;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Groovelight.Dialogs;

/// <summary>The naming template and options, shared by Organize, Import and Settings.</summary>
public sealed partial class NamingOptionsEditor : UserControl
{
    private static readonly string[] Tokens = ["{albumartist}", "{artist}", "{album}", "{year}", "{genre}", "{disc}", "{track:02}", "{title}"];
    private readonly FilesStore files = AppModel.Current.Files;
    private readonly TextBox template = new() { FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12 };
    public event Action? Changed;

    public NamingOptionsEditor()
    {
        var options = files.Options;
        template.Text = options.Template;
        template.TextChanged += (_, _) => Update(files.Options with { Template = template.Text });
        var presets = new DropDownButton { Content = "Presets" };
        presets.Flyout = Menus.Flyout(OrganizeOptions.Presets.Select(preset => (MenuFlyoutItemBase)Menus.Item(preset.Name, () => template.Text = preset.Template)));
        var insert = new DropDownButton { Content = "Insert" };
        insert.Flyout = Menus.Flyout(Tokens.Select(token => (MenuFlyoutItemBase)Menus.Item(token, () => Append(token)))
            .Append(new MenuFlyoutSeparator()).Append(Menus.Item("Folder separator /", () => Append("/"))).Append(Menus.Item("Optional part [ ]", () => Append("[ ]"))));
        var row = Ui.Grid("*,auto,auto");
        row.ColumnSpacing = 8;
        row.Children.Add(template);
        row.Children.Add(presets.At(1));
        row.Children.Add(insert.At(2));
        CheckBox Toggle(string title, bool value, Func<OrganizeOptions, bool, OrganizeOptions> change, string? tooltip = null)
        {
            var box = new CheckBox { Content = title, IsChecked = value, MinWidth = 0 };
            box.Click += (_, _) => Update(change(files.Options, box.IsChecked == true));
            if (tooltip is not null) ToolTipService.SetToolTip(box, tooltip);
            return box;
        }
        var toggles = Ui.Row(18,
            Toggle("Organize into folders", options.OrganizeFolders, (o, v) => o with { OrganizeFolders = v }),
            Toggle("Portable names", options.PortableNames, (o, v) => o with { PortableNames = v }, "Also replace characters other systems reject"),
            Toggle("Consistent \"feat.\"", options.NormalizeFeaturing, (o, v) => o with { NormalizeFeaturing = v }),
            Toggle("Title Case", options.TitleCase, (o, v) => o with { TitleCase = v }));
        Content = Ui.Column(10, row,
            Ui.Text("Tokens in { } are replaced by tags; a part in [ ] only appears when its tags have values (\"[{disc}-]\" for multi-disc albums); \"/\" makes folders.", "CaptionText")
                .With(t => { t.TextWrapping = TextWrapping.Wrap; t.TextTrimming = TextTrimming.None; }),
            toggles);
    }

    private void Append(string text)
    {
        template.Text += text;
        template.SelectionStart = template.Text.Length;
    }

    private void Update(OrganizeOptions options)
    {
        files.Options = options;
        Changed?.Invoke();
    }
}

/// <summary>Organize Files: a preview of the new names (current, new, conflicts), then apply; undo from the File menu.</summary>
public sealed class OrganizeDialog(IReadOnlyList<Track>? tracks)
{
    private readonly AppModel model = AppModel.Current;
    private readonly TextBlock summary = new() { TextWrapping = TextWrapping.Wrap };
    private readonly ListView list = new() { SelectionMode = ListViewSelectionMode.None, Height = 300 };
    private List<RenamePlanItem> plan = [];
    private List<LibraryRoot> roots = [];
    private ContentDialog? dialog;
    private int ticket;

    public async Task ShowAsync(XamlRoot root)
    {
        roots = await Task.Run(() => model.Database.Read(db => db.Roots()));
        var editor = new NamingOptionsEditor();
        editor.Changed += () => _ = PlanAsync();
        dialog = new ContentDialog
        {
            XamlRoot = root, Title = tracks is null ? "Organize Library Files" : "Organize Files", PrimaryButtonText = "Rename Files", CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary, IsPrimaryButtonEnabled = false,
        };
        dialog.Resources["ContentDialogMaxWidth"] = 820.0;
        var content = Ui.Column(14, editor, Ui.Separator(), summary, list,
            Ui.Text($"Files are moved inside your library folder; File, Library, {model.Files.UndoTitle} puts them back.", "SmallText").With(t => t.TextWrapping = TextWrapping.Wrap));
        content.Width = 740;
        dialog.Content = content;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            if (plan.Any(item => item.Status != RenameStatus.Unchanged)) await model.Files.ApplyAsync(plan);
            deferral.Complete();
        };
        _ = PlanAsync();
        await ContentDialogs.ShowAsync(dialog);
    }

    private async Task PlanAsync()
    {
        var current = ++ticket;
        summary.Text = "Planning…";
        await Task.Delay(200);
        if (current != ticket) return;
        var result = await model.Files.PlanAsync(tracks);
        if (current != ticket) return;
        plan = result;
        var changes = plan.Where(item => item.Status != RenameStatus.Unchanged).ToList();
        summary.Text = changes.Count == 0 ? "Every file already matches the template."
            : $"{changes.Count} of {plan.Count} files will be renamed or moved{(plan.Any(item => item.Status == RenameStatus.RenamedForConflict) ? ", some numbered to avoid name conflicts" : "")}";
        list.Items.Clear();
        foreach (var item in changes.Take(500))
        {
            var destination = Ui.Text(Relative(item.Destination), "BodyText", 12, FontWeights.Medium);
            if (item.Status == RenameStatus.RenamedForConflict) destination.Foreground = new SolidColorBrush(Microsoft.UI.Colors.Orange);
            list.Items.Add(new ListViewItem { Content = Ui.Column(2, destination, Ui.Text("was " + Relative(item.Source), "CaptionText", 11)), Padding = new Thickness(4) });
        }
        if (dialog is not null)
        {
            dialog.IsPrimaryButtonEnabled = !model.Files.IsWorking;
            dialog.PrimaryButtonText = changes.Count == 0 ? "Done" : $"Rename {changes.Count} Files";
        }
    }

    /// <summary>A path relative to the library folder it is in.</summary>
    private string Relative(string path)
    {
        foreach (var root in roots)
        {
            var prefix = root.Path.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            if (path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return path[prefix.Length..];
        }
        return path;
    }
}

/// <summary>Import: what was found for the chosen songs and where they will go; then move (or copy), tag and name them.</summary>
public sealed class ImportDialog(ImportSession session)
{
    private readonly AppModel model = AppModel.Current;
    private readonly ContentControl body = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch, Height = 540 };
    private ContentDialog? dialog;
    private ImportSession.ImportPhase? shownPhase;

    public async Task ShowAsync(XamlRoot root)
    {
        dialog = new ContentDialog { XamlRoot = root, Title = "Import Music", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
        dialog.Resources["ContentDialogMaxWidth"] = 900.0;
        body.Width = 820;
        dialog.Content = body;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (session.Phase is ImportSession.ImportPhase.Review) await session.RunAsync();
            else if (session.Phase is ImportSession.ImportPhase.Finished) dialog.Hide();
        };
        dialog.Closing += (_, args) =>
        {
            if (session.Phase is ImportSession.ImportPhase.Importing) args.Cancel = true;
        };
        session.PropertyChanged += OnChanged;
        Update();
        await ContentDialogs.ShowAsync(dialog);
        session.PropertyChanged -= OnChanged;
        if (session.Phase is not ImportSession.ImportPhase.Finished) session.CleanUp();
        model.Files.ImportSession = null;
    }

    private void OnChanged(object? sender, PropertyChangedEventArgs args) => model.Queue.TryEnqueue(Update);

    private void Update()
    {
        if (dialog is null) return;
        var phase = session.Phase;
        if (phase == shownPhase && phase is ImportSession.ImportPhase.Review) return;
        shownPhase = phase;
        dialog.PrimaryButtonText = "";
        switch (phase)
        {
            case ImportSession.ImportPhase.Extracting extracting:
                body.Content = Progress(extracting.Total > 1 ? $"Extracting “{extracting.Name}” ({extracting.Done + 1} of {extracting.Total})…" : $"Extracting “{extracting.Name}”…", extracting.Done, extracting.Total);
                break;
            case ImportSession.ImportPhase.Reading reading:
                body.Content = Progress($"Reading {reading.Done} of {reading.Total} files…", reading.Done, reading.Total);
                break;
            case ImportSession.ImportPhase.Identifying identifying:
                body.Content = Progress($"Identifying albums on MusicBrainz ({identifying.Done + 1} of {identifying.Total})…", identifying.Done, identifying.Total);
                break;
            case ImportSession.ImportPhase.Importing importing:
                body.Content = Progress($"Importing {importing.Done} of {importing.Total} songs…", importing.Done, importing.Total);
                dialog.CloseButtonText = "";
                break;
            case ImportSession.ImportPhase.Review:
                body.Content = Review();
                UpdateImportButton();
                break;
            case ImportSession.ImportPhase.Finished finished:
                body.Content = Finished(finished);
                dialog.PrimaryButtonText = "Done";
                dialog.CloseButtonText = "";
                break;
        }
    }

    private static FrameworkElement Progress(string text, int done, int total)
    {
        var column = Ui.Column(12, new ProgressBar { Maximum = Math.Max(total, 1), Value = done, Width = 420 }, Ui.Text(text, "SecondaryText"));
        column.HorizontalAlignment = HorizontalAlignment.Center;
        column.VerticalAlignment = VerticalAlignment.Center;
        return column;
    }

    private void UpdateImportButton()
    {
        if (dialog is null) return;
        dialog.PrimaryButtonText = $"Import {session.IncludedCount} Songs";
        dialog.IsPrimaryButtonEnabled = session.IncludedCount > 0;
    }

    private readonly ListView groups = new() { SelectionMode = ListViewSelectionMode.None };

    private FrameworkElement Review()
    {
        var options = Ui.Row(16);
        // Songs from archives are always moved out of the temporary folder they were extracted to.
        if (!session.OnlyArchives)
        {
            var mode = new ComboBox();
            mode.Items.Add("Move into library");
            mode.Items.Add("Copy into library");
            mode.SelectedIndex = session.MoveFiles ? 0 : 1;
            mode.SelectionChanged += (_, _) => { session.MoveFiles = mode.SelectedIndex == 0; };
            options.Children.Add(mode);
        }
        if (session.Roots.Count > 1)
        {
            var folder = new ComboBox();
            foreach (var root in session.Roots) folder.Items.Add(Path.GetFileName(root.Path.TrimEnd('\\')));
            folder.SelectedIndex = Math.Max(0, session.Roots.FindIndex(root => root.Id == session.RootId));
            folder.SelectionChanged += (_, _) => { session.RootId = session.Roots[folder.SelectedIndex].Id; BuildGroups(); };
            options.Children.Add(Ui.Row(8, Ui.Text("Library folder", "BodyText").With(t => t.VerticalAlignment = VerticalAlignment.Center), folder));
        }
        CheckBox Check(string title, bool value, Action<bool> set, string? tooltip = null)
        {
            var box = new CheckBox { Content = title, IsChecked = value, MinWidth = 0 };
            box.Click += (_, _) => { set(box.IsChecked == true); BuildGroups(); };
            if (tooltip is not null) ToolTipService.SetToolTip(box, tooltip);
            return box;
        }
        var checks = Ui.Row(18, Check("Use metadata found online", session.UseOnlineMetadata, value => session.UseOnlineMetadata = value),
                                Check("Write tags and cover into the files", session.WriteTags, value => session.WriteTags = value));
        if (session.Archives.Count > 0)
        {
            checks.Children.Add(Check(session.Archives.Count == 1 ? "Move the archive to the Recycle Bin after importing" : "Move the archives to the Recycle Bin after importing",
                session.DeleteArchives, value => session.DeleteArchives = value, "Only when every selected song from it was imported. Undo Import puts it back."));
        }
        BuildGroups();
        var note = Ui.Text(session.DuplicateCount == 1 ? "1 song already in your library is left out."
                           : session.DuplicateCount > 1 ? $"{session.DuplicateCount} songs already in your library are left out." : "Undo with File, Library, Undo Import.", "CaptionText");
        var grid = Ui.Grid("", "auto,auto,*,auto");
        grid.RowSpacing = 10;
        grid.Children.Add(options);
        grid.Children.Add(checks.At(0, 1));
        grid.Children.Add(groups.At(0, 2));
        grid.Children.Add(note.At(0, 3));
        return grid;
    }

    private void BuildGroups()
    {
        var destinations = session.Destinations();
        var root = session.Roots.FirstOrDefault(item => item.Id == session.RootId)?.Path.TrimEnd('\\');
        string Relative(string path) => root is not null && path.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase) ? path[(root.Length + 1)..] : path;
        groups.Items.Clear();
        foreach (var group in session.Groups)
        {
            var header = Ui.Grid("auto,*,auto");
            header.ColumnSpacing = 10;
            var cover = new Grid { Width = 36, Height = 36, CornerRadius = new CornerRadius(4), Background = Ui.Brush("ControlFillColorSecondaryBrush") };
            if (group.Cover is { } data)
            {
                var image = new Image { Stretch = Stretch.UniformToFill };
                _ = SetAsync(image, data);
                cover.Children.Add(image);
            }
            else cover.Children.Add(Ui.Icon(Glyphs.Note, 14, "SecondaryIcon"));
            header.Children.Add(cover);
            header.Children.Add(Ui.Column(1, Ui.Text(group.Title, "StrongText", 13), Ui.Text(group.Artist, "CaptionText", 11)).At(1));
            var matched = group.MatchedRelease is { } release && session.UseOnlineMetadata;
            var label = Ui.Row(6, Ui.Icon(matched ? "" : "", 12), Ui.Text(matched ? $"Matched: {group.MatchedRelease}" : "File tags", "CaptionText"));
            if (matched) foreach (var child in label.Children) if (child is TextBlock text) text.Foreground = new SolidColorBrush(Microsoft.UI.Colors.MediumSeaGreen); else if (child is FontIcon icon) icon.Foreground = new SolidColorBrush(Microsoft.UI.Colors.MediumSeaGreen);
            header.Children.Add(label.With(row => row.VerticalAlignment = VerticalAlignment.Center).At(2));
            header.Padding = new Thickness(0, 8, 0, 4);
            groups.Items.Add(new ListViewItem { Content = header, IsHitTestVisible = false });
            foreach (var item in group.Items)
            {
                var box = new CheckBox { IsChecked = item.Include, MinWidth = 0 };
                var current = item;
                box.Click += (_, _) => { current.Include = box.IsChecked == true; BuildGroups(); UpdateImportButton(); };
                var title = Ui.Text(destinations.TryGetValue(item.Id, out var destination) ? Relative(destination) : item.IsDuplicate ? "Already in your library" : "Skipped",
                                    item.Include ? "BodyText" : "SecondaryText", 12, FontWeights.Medium);
                var source = item.Cue is { } cue
                    ? $"{Path.GetFileName(item.Source)} + {(cue.Sheet is null ? "embedded cue sheet" : Path.GetFileName(cue.Sheet))} · {cue.Songs} songs"
                    : session.SourceDescription(item.Source);
                var row = Ui.Grid("auto,*");
                row.ColumnSpacing = 10;
                row.Children.Add(box);
                row.Children.Add(Ui.Column(2, title, Ui.Text(source, "CaptionText", 11)).At(1));
                groups.Items.Add(new ListViewItem { Content = row, Padding = new Thickness(12, 2, 4, 2) });
            }
        }
    }

    private static async Task SetAsync(Image image, byte[] data) => image.Source = await Images.FromBytesAsync(data);

    private FrameworkElement Finished(ImportSession.ImportPhase.Finished result)
    {
        var icon = Ui.Icon(result.Failed == 0 ? "" : Glyphs.Warning, 40);
        icon.Foreground = new SolidColorBrush(result.Failed == 0 ? Microsoft.UI.Colors.MediumSeaGreen : Microsoft.UI.Colors.Orange);
        var column = Ui.Column(12, icon, Ui.Text($"{result.Imported} songs imported", "SectionTitleText"));
        if (result.Skipped > 0) column.Children.Add(Ui.Text($"{result.Skipped} left out", "SecondaryText"));
        if (result.Failed > 0) column.Children.Add(Ui.Text($"{result.Failed} could not be imported", "BodyText").With(t => t.Foreground = new SolidColorBrush(Microsoft.UI.Colors.Orange)));
        if (session.TrashedArchives > 0)
            column.Children.Add(Ui.Text(session.TrashedArchives == 1 ? "The archive was moved to the Recycle Bin" : $"{session.TrashedArchives} archives were moved to the Recycle Bin", "SecondaryText"));
        foreach (var child in column.Children.OfType<FrameworkElement>()) child.HorizontalAlignment = HorizontalAlignment.Center;
        column.VerticalAlignment = VerticalAlignment.Center;
        return column;
    }
}

/// <summary>The Settings sections and cards of the files features: Files (naming), Backup, and the import folder.</summary>
public static class FilesSettings
{
    public static void Register()
    {
        SettingsPage.Extra.Add((40, new SettingsSection("Files", "", Files)));
        SettingsPage.Extra.Add((50, new SettingsSection("Backup", "", Backup)));
        SettingsPage.LocateFolder = root => _ = AppModel.Current.Backup.LocateAsync(root);
        SettingsPage.LibraryExtras.Add((page, roots) =>
        {
            if (roots.Count == 0) return new Grid();
            var model = AppModel.Current;
            var chosen = model.Preferences.String(FilesStore.ImportRootKey);
            var index = Math.Max(0, roots.ToList().FindIndex(root => string.Equals(root.Path, chosen, StringComparison.OrdinalIgnoreCase)));
            var box = SettingsPage.Choice(roots.Select(root => Path.GetFileName(root.Path.TrimEnd('\\')) is { Length: > 0 } name ? name : root.Path).ToList(), index,
                selected => model.Preferences.Set(FilesStore.ImportRootKey, roots[selected].Path));
            box.IsEnabled = roots.Count > 1;
            return Ui.Column(4, SettingsPage.Header("Import"),
                new SettingsCard("Import into", "Songs, folders and archives (zip, 7z, rar) imported with File, Import or dropped on the window go to this folder, named as Organize Library Files names them. Each import can still choose another folder.", box, Glyphs.Import));
        });
    }

    private static FrameworkElement Files(SettingsPage page)
    {
        var model = AppModel.Current;
        var editor = new NamingOptionsEditor();
        var example = new TextBlock { FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap };
        void Update() => example.Text = FileNaming.RelativePath(new NamingFields("Karma Police", "Radiohead", "OK Computer", "Radiohead", "Alternative Rock", 1997, 6), "flac", model.Files.Options);
        editor.Changed += Update;
        Update();
        var undo = Ui.Button(model.Files.UndoTitle, async () => { await model.Files.UndoLastAsync(); page.Refresh(); });
        undo.IsEnabled = model.Files.Undoable is not null;
        return Ui.Column(4, SettingsPage.Header("File Names"),
            new Border { Style = Ui.Style("CardBorder"), Child = Ui.Column(12, editor, Ui.Row(10, Ui.Text("Example", "SecondaryText"), example)) },
            SettingsPage.Footer("Used by File, Library, Organize Library Files and by imports. Files are never renamed without a preview."),
            new SettingsCard("Organize Library Files", null, Ui.Row(8, Ui.Button("Organize Library Files…", () => model.Request(new DialogRequest.Organize(null))), undo), Glyphs.Folder).Margin(0, 12, 0, 0));
    }

    private static FrameworkElement Backup(SettingsPage page)
    {
        var model = AppModel.Current;
        var backup = model.Backup;
        var preferences = model.Preferences;
        var buttons = Ui.Row(8, Ui.Button("Back Up…", backup.ChooseAndBackUp), Ui.Button("Restore…", backup.ChooseAndRestore));
        buttons.IsHitTestVisible = !backup.IsWorking;
        if (backup.IsWorking) buttons.Children.Insert(0, new ProgressRing { IsActive = true, Width = 16, Height = 16 });
        var automatic = preferences.Bool(BackupManager.AutomaticKey, true);
        var keep = new NumberBox { Minimum = 1, Maximum = 30, Value = preferences.Integer(BackupManager.KeepKey, 5), SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Inline, Width = 130 };
        keep.ValueChanged += (_, args) => { if (!double.IsNaN(args.NewValue)) preferences.Set(BackupManager.KeepKey, (long)args.NewValue); };
        var chosen = preferences.String(BackupManager.FolderKey);
        var folderNote = string.IsNullOrEmpty(chosen) ? "Inside Groovelight's data (choose another disk or OneDrive to survive losing this computer)" : backup.AutomaticFolder;
        var adjustable = Ui.Column(4,
            new SettingsCard("Every", null, SettingsPage.Choice(["Day", "Week"], preferences.String(BackupManager.FrequencyKey) == "daily" ? 0 : 1,
                index => preferences.Set(BackupManager.FrequencyKey, index == 0 ? "daily" : "weekly"))),
            new SettingsCard("Keep the last backups", null, keep),
            new SettingsCard("Folder", folderNote, Ui.Button("Choose…", async () => { backup.ChooseAutomaticFolder(); await Task.Delay(500); page.Refresh(); })));
        adjustable.Opacity = automatic ? 1 : 0.5;
        adjustable.IsHitTestVisible = automatic;
        return Ui.Column(4,
            new SettingsCard("Library Backup", backup.LastBackup is { } last ? $"Last backup {Format.DateTime(last)}" : "Never backed up", buttons, ""),
            SettingsPage.Footer("Playlists and their covers, smart playlist rules, play counts, ratings, loved songs, metadata fixes, lyrics, artwork, credits, album and artist info, equalizer presets and settings. Your music files are not included. Backups are folders in the Mac's format: either computer restores them."),
            SettingsPage.Header("Automatic Backups"),
            new SettingsCard("Back up automatically", null, SettingsPage.Toggle(automatic, on => { preferences.Set(BackupManager.AutomaticKey, on); page.Refresh(); })),
            adjustable);
    }
}
