using Groovelight.Core.Library;
using Groovelight.Support;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Groovelight.Model;

/// <summary>
/// Importing playlist files of other players (M3U, M3U8, PLS, XSPF, WPL, Music XML) as playlists of library songs, and
/// exporting playlists to those formats (the Mac's PlaylistTransfer).
/// </summary>
public sealed class PlaylistTransfer(AppModel model) : Observable
{
    public sealed record ReportedPlaylist(string Name, int Found, int Total, IReadOnlyList<string> Missing);

    private const string FormatKey = "playlists.exportFormat";
    private const string RelativeKey = "playlists.exportRelative";
    private bool isImporting;

    public bool IsImporting { get => isImporting; private set => Set(ref isImporting, value); }

    /// <summary>What an import found, for the window to show when some songs were not in the library.</summary>
    public event Action<IReadOnlyList<ReportedPlaylist>>? Reported;

    public static bool IsPlaylistFile(string path) => PlaylistFormats.ReadableExtensions.Contains(Path.GetExtension(path).TrimStart('.'))
        // A plain .xml is a playlist only when it is a Music / iTunes export.
        && (!Path.GetExtension(path).Equals(".xml", StringComparison.OrdinalIgnoreCase) || LooksLikeMusicXml(path));

    private static bool LooksLikeMusicXml(string path)
    {
        try
        {
            using var reader = new StreamReader(path);
            var head = new char[2048];
            var count = reader.Read(head, 0, head.Length);
            return new string(head, 0, count).Contains("<plist", StringComparison.Ordinal);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    public async void ChooseAndImport()
    {
        var files = await Pickers.FilesAsync(PlaylistFormats.ReadableExtensions.Select(extension => "." + extension), "Import");
        if (files.Count > 0) ImportFiles(files);
    }

    /// <summary>Reads the files, finds their songs in the library and creates one playlist per list.</summary>
    public async void ImportFiles(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0 || IsImporting) return;
        IsImporting = true;
        var reports = new List<ReportedPlaylist>();
        var created = new List<long>();
        var problems = new List<string>();
        try
        {
            foreach (var path in paths)
            {
                List<PlaylistDocument> documents;
                try
                {
                    documents = await Task.Run(() => PlaylistFile.Read(path));
                }
                catch (Exception error) when (error is PlaylistFileException or IOException or UnauthorizedAccessException)
                {
                    problems.Add(error.Message);
                    continue;
                }
                foreach (var document in documents)
                {
                    try
                    {
                        var entries = document.Entries;
                        var ids = await Task.Run(() => model.Database.Read(db => db.MatchPlaylistEntries(entries)));
                        var playlist = model.Database.CreatePlaylist(document.Name, ids.OfType<long>().ToList());
                        if (playlist.Id is { } id) created.Add(id);
                        var missing = entries.Zip(ids).Where(pair => pair.Second is null).Select(pair => pair.First.Label).ToList();
                        reports.Add(new ReportedPlaylist(document.Name, ids.Count - missing.Count, ids.Count, missing));
                    }
                    catch (Microsoft.Data.Sqlite.SqliteException error)
                    {
                        problems.Add($"{document.Name}: {error.Message}");
                    }
                }
            }
        }
        finally
        {
            IsImporting = false;
        }
        if (created.Count == 1) model.Selection = SidebarItem.Playlist(created[0]);
        else if (created.Count > 1) model.Selection = SidebarItem.AllPlaylists;
        if (problems.Count > 0) model.ErrorMessage = string.Join("\n", problems);
        // Shown when something was left out, or several playlists came in at once (a Music XML export).
        if (reports.Any(report => report.Missing.Count > 0) || reports.Count > 1) Reported?.Invoke(reports);
    }

    /// <summary>The Mac's raw values of the formats, for the remembered choice.</summary>
    private static string Raw(PlaylistFormat format) => format switch
    {
        PlaylistFormat.M3u8 => "m3u8", PlaylistFormat.M3u => "m3u", PlaylistFormat.Pls => "pls", PlaylistFormat.Xspf => "xspf",
        PlaylistFormat.Wpl => "wpl", _ => "musicXML",
    };

    /// <summary>Saves a playlist (null: Loved Songs) to a file, in the format and path style chosen.</summary>
    public async Task ExportAsync(XamlRoot root, long? playlistId)
    {
        var (name, tracks) = await ContentsAsync(playlistId);
        if (tracks.Count == 0)
        {
            model.ErrorMessage = $"{name} has no songs to export.";
            return;
        }
        var formats = PlaylistFormats.Exportable;
        var saved = model.Preferences.String(FormatKey);
        var format = new ComboBox { MinWidth = 260 };
        foreach (var item in formats) format.Items.Add($"{item.Name()} (.{item.FileExtension()})");
        format.SelectedIndex = Math.Max(0, formats.ToList().FindIndex(item => Raw(item) == saved));
        var relative = new CheckBox { Content = "Paths relative to the playlist file", IsChecked = model.Preferences.Bool(RelativeKey) };
        // Music XML always holds full file addresses.
        void Update() => relative.IsEnabled = formats[Math.Max(0, format.SelectedIndex)] != PlaylistFormat.MusicXml;
        format.SelectionChanged += (_, _) => Update();
        Update();
        var dialog = new ContentDialog
        {
            XamlRoot = root, Title = "Export Playlist", PrimaryButtonText = "Export…", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary,
            Content = Ui.Column(12, Ui.Text(name, "StrongText"), Ui.Row(8, Ui.Text("Format", "BodyText").With(t => t.VerticalAlignment = VerticalAlignment.Center), format), relative),
        };
        if (await ContentDialogs.ShowAsync(dialog) != ContentDialogResult.Primary) return;
        var chosen = formats[Math.Max(0, format.SelectedIndex)];
        var isRelative = relative.IsEnabled && relative.IsChecked == true;
        model.Preferences.Set(FormatKey, Raw(chosen));
        if (relative.IsEnabled) model.Preferences.Set(RelativeKey, relative.IsChecked == true);
        var path = await Pickers.SaveAsync(FileName(name), [($"{chosen.Name()}", ["." + chosen.FileExtension()])]);
        if (path is null) return;
        try
        {
            await Task.Run(() => Write(name, tracks, path, chosen, isRelative));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            model.ErrorMessage = $"Could not export {name}: {error.Message}";
        }
    }

    public static void Write(string name, IReadOnlyList<Track> tracks, string path, PlaylistFormat format, bool relative)
    {
        PlaylistPathStyle style = relative ? new PlaylistPathStyle.Relative(Path.GetDirectoryName(Path.GetFullPath(path))!) : new PlaylistPathStyle.Absolute();
        var temporary = path + ".tmp";
        File.WriteAllBytes(temporary, PlaylistFile.Write(name, tracks, format, style));
        File.Move(temporary, path, overwrite: true);
    }

    public Task<(string Name, List<Track> Tracks)> ContentsAsync(long? playlistId) => Task.Run(() => model.Database.Read(db =>
        playlistId is { } id ? (db.FetchPlaylist(id)?.Name ?? "Playlist", db.TracksOfPlaylist(id)) : ("Loved Songs", db.LovedTracks())));

    /// <summary>A file name without the characters Windows refuses.</summary>
    private static string FileName(string name)
    {
        var cleaned = string.Concat(name.Select(character => Path.GetInvalidFileNameChars().Contains(character) || character is ':' or '/' or '\\' ? '-' : character)).Trim();
        return cleaned.Length == 0 ? "Playlist" : cleaned;
    }

    /// <summary>After importing playlist files: how many songs each playlist found, and which were not in the library.</summary>
    public static async Task ShowReportAsync(XamlRoot root, IReadOnlyList<ReportedPlaylist> playlists)
    {
        var list = Ui.Column(12);
        foreach (var playlist in playlists)
        {
            var head = Ui.Grid("*,auto");
            head.Children.Add(Ui.Text(playlist.Name, "StrongText"));
            var count = Ui.Text(playlist.Found == playlist.Total ? $"All {playlist.Total} songs" : $"{playlist.Found} of {playlist.Total} songs found", "SecondaryText");
            if (playlist.Found != playlist.Total) count.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Orange);
            head.Children.Add(count.At(1));
            var section = Ui.Column(4, head);
            foreach (var label in playlist.Missing) section.Children.Add(Ui.Row(6, Ui.Icon("", 12, "SecondaryIcon"), Ui.Text(label, "SecondaryText")));
            list.Children.Add(section);
        }
        var content = Ui.Column(12, new ScrollViewer { Content = list, MaxHeight = 320 },
            Ui.Text("Songs are matched by their file, then by title and artist. Songs that are not in your library are left out: import them first (File, Import) and import the playlist again.", "WrappingSecondaryText"));
        content.Width = 480;
        await ContentDialogs.ShowAsync(new ContentDialog
        {
            XamlRoot = root, Title = playlists.Count == 1 ? "Playlist Imported" : $"{playlists.Count} Playlists Imported", Content = content, CloseButtonText = "OK",
        });
    }
}
