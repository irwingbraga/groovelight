using Groovelight.Dialogs;
using Groovelight.Model;

namespace Groovelight;

/// <summary>Plugs each feature into the window's menus, pages and settings (called once at launch).</summary>
internal static partial class Features
{
    private static AppModel Model => AppModel.Current;

    /// <summary>Fix Metadata, Organize, Import, playlist files and backups.</summary>
    private static void RegisterFiles()
    {
        MainWindow.DialogHandlers[typeof(DialogRequest.FixMetadata)] = (root, request) => new FixMetadataDialog(((DialogRequest.FixMetadata)request).Tracks).ShowAsync(root);
        MainWindow.DialogHandlers[typeof(DialogRequest.Organize)] = (root, request) => new OrganizeDialog(((DialogRequest.Organize)request).Tracks).ShowAsync(root);
        MainWindow.DialogHandlers[typeof(DialogRequest.ExportPlaylist)] = (root, request) => Model.PlaylistFiles.ExportAsync(root, ((DialogRequest.ExportPlaylist)request).PlaylistId);
        MainWindow.Importer = async () =>
        {
            var files = await Support.Pickers.FilesAsync([], "Import");
            if (files.Count > 0) Model.Files.ImportItems(files);
        };
        MainWindow.PlaylistImporter = Model.PlaylistFiles.ChooseAndImport;
        MainWindow.BackUpper = Model.Backup.ChooseAndBackUp;
        MainWindow.Restorer = Model.Backup.ChooseAndRestore;
        MainWindow.UndoableTitle = () => Model.Files.Undoable is null || Model.Files.IsWorking ? null : Model.Files.UndoTitle;
        MainWindow.Undoer = () => _ = Model.Files.UndoLastAsync();
        MainWindow.FileOpener = paths => Model.Files.ImportItems(paths);
        Model.PlaylistFiles.Reported += playlists => _ = PlaylistTransfer.ShowReportAsync(MainWindow.Current.RootXamlRoot, playlists);
        Model.Files.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(FilesStore.ImportSession) && Model.Files.ImportSession is { } session)
                _ = new ImportDialog(session).ShowAsync(MainWindow.Current.RootXamlRoot);
        };
        Model.Backup.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(BackupManager.FoldersToLocate) && Model.Backup.FoldersToLocate.Count > 0 && !locating)
            {
                locating = true;
                _ = Model.Backup.ShowLocateFoldersAsync(MainWindow.Current.RootXamlRoot).ContinueWith(_ => locating = false);
            }
        };
        FilesSettings.Register();
    }

    private static bool locating;

    public static void Register()
    {
        PageFactories.NowPlaying = () => new Views.NowPlayingView();
        PageFactories.Shelf = () => new Views.ShelfPage();
        MainWindow.VisualizerOpener = Shell.VisualizerWindow.Show;
        Views.NowPlayingView.VisualizerFactory = () => new Shell.VisualizerView { CornerRadius = new Microsoft.UI.Xaml.CornerRadius(14) };
        Views.NowPlayingView.VisualizerStylePicker = () =>
        {
            var button = new Microsoft.UI.Xaml.Controls.DropDownButton { Content = "Style" };
            var menu = new Microsoft.UI.Xaml.Controls.MenuFlyout();
            menu.Opening += (_, _) =>
            {
                menu.Items.Clear();
                foreach (var item in Shell.VisualizerView.StyleItems()) menu.Items.Add(item);
            };
            button.Flyout = menu;
            return button;
        };
        MainWindow.MiniPlayerOpener = () => Shell.MiniPlayerWindow.Show();
        MainWindow.EqualizerOpener = Shell.EqualizerWindow.Show;
        RegisterFiles();
        // After the files' opener, so cassettes opened with the app go to the Cassettes.
        SkinViews.SkinFeatures.Register();
        Views.LastFmSettings.Register();
        Views.DeviceFeatures.Register();
        Shell.UpdateFeatures.Register();
        Shell.CommandLineFeatures.Register();
    }
}
