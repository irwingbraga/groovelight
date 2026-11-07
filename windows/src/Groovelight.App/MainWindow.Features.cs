using Groovelight.Core.Library;
using Groovelight.Metadata;
using Groovelight.Model;
using Groovelight.Support;
using Groovelight.Views;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Groovelight;

/// <summary>The window's commands that open other windows or run library jobs: each feature plugs its own in.</summary>
public sealed partial class MainWindow
{
    public static Action? VisualizerOpener { get; set; }
    public static Action? EqualizerOpener { get; set; }
    public static Action? MiniPlayerOpener { get; set; }
    public static Action? CassettesOpener { get; set; }
    public static Action? Importer { get; set; }
    public static Action? PlaylistImporter { get; set; }
    public static Action? BackUpper { get; set; }
    public static Action? Restorer { get; set; }
    /// <summary>The last file change that can be undone (organize, import): its title, or null.</summary>
    public static Func<string?>? UndoableTitle { get; set; }
    public static Action? Undoer { get; set; }

    public void ShowVisualizer() => VisualizerOpener?.Invoke();
    public void ShowEqualizer() => EqualizerOpener?.Invoke();
    public void ShowMiniPlayer() => MiniPlayerOpener?.Invoke();
    public void ShowCassettes() => CassettesOpener?.Invoke();
    public void ChooseAndImport() => Importer?.Invoke();
    public void ChooseAndImportPlaylist() => PlaylistImporter?.Invoke();
    public void ChooseAndBackUp() => BackUpper?.Invoke();
    public void ChooseAndRestore() => Restorer?.Invoke();
    public string UndoTitle => UndoableTitle?.Invoke() ?? "Undo";
    public bool CanUndoFileChange => UndoableTitle?.Invoke() is not null;
    public void UndoLastFileChange() => Undoer?.Invoke();

    /// <summary>The licenses of the software Groovelight includes.</summary>
    public void ShowAcknowledgements()
    {
        var notices = Path.Combine(AppContext.BaseDirectory, "THIRD_PARTY_NOTICES.md");
        if (File.Exists(notices)) System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(notices) { UseShellExecute = true });
        else AppModel.OpenUrl(Shell.AppLinks.Repository + "/blob/main/THIRD_PARTY_NOTICES.md");
    }

    public async void ShowAbout()
    {
        var version = typeof(MainWindow).Assembly.GetName().Version?.ToString(3) ?? "";
        var content = Ui.Column(8,
            new Image { Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "Groovelight.png"))), Width = 96, Height = 96 },
            Ui.Text("Groovelight", "SectionTitleText"),
            Ui.Text($"Version {version}", "SecondaryText"),
            Ui.Text("A music library and player for your own files.", "SecondaryText"),
            new HyperlinkButton { Content = "github.com/irwingbraga/groovelight", NavigateUri = new Uri(Shell.AppLinks.Repository) });
        foreach (var child in content.Children.OfType<FrameworkElement>()) child.HorizontalAlignment = HorizontalAlignment.Center;
        await ContentDialogs.ShowAsync(new ContentDialog { XamlRoot = Root.XamlRoot, Content = content, CloseButtonText = "OK" });
    }
}

/// <summary>Credits of one song (from its album's MusicBrainz release), loading them if needed.</summary>
public static class TrackCredits
{
    public static async Task ShowAsync(XamlRoot root, Track track)
    {
        var model = AppModel.Current;
        var load = model.Metadata.LoadAlbumInfoAsync(track.AlbumKey);
        var cached = await Task.Run(() => model.Database.Read(db => db.AlbumInfo(track.AlbumKey)));
        if (cached is null)
        {
            await load;
            cached = await Task.Run(() => model.Database.Read(db => db.AlbumInfo(track.AlbumKey)));
        }
        var info = cached is { } row ? AlbumInfo.Decode(row.Data) : null;
        await CreditsView.ShowAsync(root, track.Title, $"{track.DisplayArtist} · {track.DisplayAlbum}", track.ArtworkHash,
            info?.SectionsForTrack(track) ?? [], info?.ReleaseId, model.Metadata.AlbumInfoInFlight.Contains(track.AlbumKey));
    }
}
