using System.Globalization;
using Groovelight.Core;
using Groovelight.Core.Library;
using Groovelight.Support;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Groovelight.Model;

/// <summary>
/// Backups of the library data that is not in the music files, restores (relinking the music folders), and automatic
/// backups (the Mac's BackupManager). A backup is a folder in the Mac's format, so either computer restores it.
/// </summary>
public sealed class BackupManager : Observable
{
    public const string AutomaticKey = "backup.automatic", FrequencyKey = "backup.frequency", KeepKey = "backup.keep", FolderKey = "backup.folderPath",
        LastBackupKey = "backup.lastDate";

    /// <summary>Preferences that travel with a backup (machine specific ones, like the backup folder, stay behind).</summary>
    public static readonly IReadOnlyList<string> PreferencePrefixes =
        ["eq.", "metadata.", "visualizer.", "albums.", "shelf.", "devices.", "player.", "appearance.", "shortcuts.", "lastfm."];

    private readonly AppModel model;
    private bool isWorking;
    private DateTime? lastBackup;
    private List<LibraryRoot> foldersToLocate = [];

    public BackupManager(AppModel model)
    {
        this.model = model;
        model.Preferences.Register(new Dictionary<string, object?> { [AutomaticKey] = true, [FrequencyKey] = "weekly", [KeepKey] = 5L });
        lastBackup = model.Preferences.Date(LastBackupKey);
        // Check for a due automatic backup a minute after launch, then hourly.
        var timer = model.Queue.CreateTimer();
        timer.Interval = TimeSpan.FromMinutes(60);
        timer.Tick += (_, _) => BackUpIfDue();
        timer.Start();
        var first = model.Queue.CreateTimer();
        first.Interval = TimeSpan.FromSeconds(60);
        first.IsRepeating = false;
        first.Tick += (_, _) => BackUpIfDue();
        first.Start();
    }

    public bool IsWorking { get => isWorking; private set => Set(ref isWorking, value); }
    public DateTime? LastBackup { get => lastBackup; private set => Set(ref lastBackup, value); }
    /// <summary>Library folders that could not be opened after a restore: the user locates them again.</summary>
    public List<LibraryRoot> FoldersToLocate { get => foldersToLocate; set => Set(ref foldersToLocate, value); }

    public static string FileName(DateTime date) =>
        $"Groovelight Backup {date.ToLocalTime().ToString("yyyy-MM-dd HH.mm", CultureInfo.InvariantCulture)}.{LibraryBackup.FileExtension}";

    // MARK: Backing up

    /// <summary>Asks where to put a backup (a folder: the backup is a folder in it) and makes it.</summary>
    public async void ChooseAndBackUp()
    {
        if (await Pickers.FolderAsync("Back Up Here") is not { } folder) return;
        await BackUpAsync(Path.Combine(folder, FileName(DateTime.UtcNow)), isAutomatic: false);
    }

    public async Task<bool> BackUpAsync(string path, bool isAutomatic)
    {
        if (IsWorking) return false;
        IsWorking = true;
        try
        {
            var preferences = PropertyList.Write(model.Preferences.Export(PreferencePrefixes));
            var version = typeof(BackupManager).Assembly.GetName().Version?.ToString(3) ?? "0";
            await Task.Run(() => LibraryBackup.Write(model.Database, model.Artwork.Directory, preferences, version, path));
            LastBackup = DateTime.UtcNow;
            model.Preferences.Set(LastBackupKey, LastBackup);
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or Microsoft.Data.Sqlite.SqliteException)
        {
            if (!isAutomatic) model.ErrorMessage = $"The backup failed: {error.Message}";
            return false;
        }
        finally
        {
            IsWorking = false;
        }
    }

    // MARK: Automatic backups

    /// <summary>Where automatic backups go: the chosen folder, or the app's own Backups folder.</summary>
    public string AutomaticFolder => model.Preferences.String(FolderKey) is { Length: > 0 } chosen && Directory.Exists(chosen) ? chosen : DefaultFolder;

    public string DefaultFolder => Path.Combine(model.DataDirectory, "Backups");

    public async void ChooseAutomaticFolder()
    {
        if (await Pickers.FolderAsync("Choose") is { } folder) model.Preferences.Set(FolderKey, folder);
        OnPropertyChanged(nameof(AutomaticFolder));
    }

    public void BackUpIfDue()
    {
        if (!model.Preferences.Bool(AutomaticKey) || IsWorking) return;
        var interval = model.Preferences.String(FrequencyKey) == "daily" ? TimeSpan.FromDays(1) : TimeSpan.FromDays(7);
        if (LastBackup is { } last && DateTime.UtcNow - last < interval) return;
        _ = BackUpAutomaticallyAsync();
    }

    public async Task BackUpAutomaticallyAsync()
    {
        var folder = AutomaticFolder;
        Directory.CreateDirectory(folder);
        if (!await BackUpAsync(Path.Combine(folder, FileName(DateTime.UtcNow)), isAutomatic: true)) return;
        // Keep only the newest automatic backups.
        var keep = Math.Max(1, (int)model.Preferences.Integer(KeepKey, 5));
        var backups = Directory.EnumerateDirectories(folder, $"Groovelight Backup *.{LibraryBackup.FileExtension}")
            .OrderByDescending(path => Path.GetFileName(path), StringComparer.Ordinal).ToList();
        foreach (var old in backups.Skip(keep))
        {
            try { Directory.Delete(old, recursive: true); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }

    // MARK: Restoring

    public async void ChooseAndRestore()
    {
        if (await Pickers.FolderAsync("Restore") is not { } path) return;
        try
        {
            var manifest = LibraryBackup.ReadManifest(path);
            if (!await ConfirmRestoreAsync(manifest)) return;
            await RestoreAsync(path);
        }
        catch (LibraryBackup.BackupException error)
        {
            model.ErrorMessage = error.Message;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            model.ErrorMessage = error.Message;
        }
    }

    private static async Task<bool> ConfirmRestoreAsync(LibraryBackup.Manifest manifest)
    {
        var made = manifest.CreatedAt.ToLocalTime().ToString("f", CultureInfo.CurrentCulture);
        var message = $"Backup from {made}{(manifest.ComputerName is { } computer ? $" on {computer}" : "")}: {manifest.TrackCount} songs, " +
                      $"{manifest.PlaylistCount} playlists, {manifest.LovedCount} loved songs, {manifest.PlayCount} plays.\n\n" +
                      "Your current playlists, play counts, metadata fixes and settings are replaced. Your music files are not touched.";
        return await Ui.Confirm(MainWindow.Current.RootXamlRoot, "Restore the library from this backup?", message, "Restore");
    }

    public async Task RestoreAsync(string path)
    {
        if (IsWorking) return;
        IsWorking = true;
        try
        {
            model.Player.Stop();
            model.ReplacePath([]);
            model.Selection = SidebarItem.Albums;
            var plist = await Task.Run(() => LibraryBackup.Restore(path, model.Database, model.Artwork.Directory));
            if (plist is not null && PropertyList.Parse(plist) is Dictionary<string, object?> preferences)
                model.Preferences.Import(preferences, PreferencePrefixes);
            model.Equalizer.Reload();
            MainWindow.Current.UpdateTheme();
            model.Shortcuts.Load();
            PlaybackPrefs.Apply(model.Preferences, model.Player);
            FoldersToLocate = await model.ReopenLibraryAfterRestoreAsync();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or Microsoft.Data.Sqlite.SqliteException or LibraryBackup.BackupException)
        {
            model.ErrorMessage = $"The restore failed: {error.Message}";
        }
        finally
        {
            IsWorking = false;
        }
    }

    /// <summary>Asks for a library folder again (after restoring on another computer) and points its songs there.</summary>
    public async Task LocateAsync(LibraryRoot root)
    {
        if (root.Id is not { } id || await Pickers.FolderAsync("Use This Folder") is not { } folder) return;
        try
        {
            model.Database.RelocateRoot(id, Path.GetFullPath(folder));
            FoldersToLocate = FoldersToLocate.Where(item => item.Id != id).ToList();
            model.UnavailableFolders.Remove(root.Path);
            await model.Sync.FoldersChangedAsync();
            model.RescanAll();
        }
        catch (Exception error) when (error is IOException or Microsoft.Data.Sqlite.SqliteException)
        {
            model.ErrorMessage = $"Could not use that folder: {error.Message}";
        }
    }

    /// <summary>After restoring on another computer: the music folders to locate again.</summary>
    public async Task ShowLocateFoldersAsync(XamlRoot root)
    {
        if (FoldersToLocate.Count == 0) return;
        var list = Ui.Column(0);
        var dialog = new ContentDialog { XamlRoot = root, Title = "Locate Your Music Folders", CloseButtonText = "Later" };
        void Build()
        {
            list.Children.Clear();
            foreach (var folder in FoldersToLocate)
            {
                var row = Ui.Grid("auto,*,auto");
                row.ColumnSpacing = 10;
                row.Padding = new Thickness(0, 8, 0, 8);
                row.Children.Add(Ui.Icon(Glyphs.Folder, 16, "SecondaryIcon"));
                row.Children.Add(Ui.Column(1, Ui.Text(Path.GetFileName(folder.Path.TrimEnd('/', '\\')), "StrongText", 13), Ui.Text(folder.Path, "CaptionText")).At(1));
                var target = folder;
                row.Children.Add(Ui.Button("Locate…", async () => { await LocateAsync(target); Build(); if (FoldersToLocate.Count == 0) dialog.Hide(); }).At(2));
                list.Children.Add(row);
                list.Children.Add(Ui.Separator());
            }
        }
        Build();
        var content = Ui.Column(14,
            Ui.Text("The backup was restored. Point Groovelight at each of these folders on this computer (it can have a different name or location). Play counts, playlists and fixes reconnect to the songs.", "WrappingSecondaryText"),
            list,
            Ui.Text("Folders left out keep their songs' history until they are located (Settings, Library).", "SmallText").With(t => t.TextWrapping = TextWrapping.Wrap));
        content.Width = 520;
        dialog.Content = content;
        await ContentDialogs.ShowAsync(dialog);
    }
}
