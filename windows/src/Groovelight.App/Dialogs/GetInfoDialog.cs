using System.Globalization;
using Groovelight.Controls;
using Groovelight.Core.Library;
using Groovelight.Model;
using Groovelight.Support;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace Groovelight.Dialogs;

/// <summary>
/// The tag editor for one or several songs (the Mac's Get Info): details, artwork, lyrics and file info. With several
/// songs, fields that differ show "Mixed" and only the fields that were changed are applied; per-song fields (title,
/// track number, lyrics) are disabled. Clearing a field removes the tag.
/// </summary>
public sealed class GetInfoDialog
{
    private enum Field { Title, Artist, Album, AlbumArtist, Composer, Genre, Year, Bpm, TrackNumber, TrackTotal, DiscNumber, DiscTotal, Comment }

    private static bool IsNumber(Field field) => field is Field.Year or Field.Bpm or Field.TrackNumber or Field.TrackTotal or Field.DiscNumber or Field.DiscTotal;

    /// <summary>Fields that only make sense per song.</summary>
    private static bool IsPerSong(Field field) => field is Field.Title or Field.TrackNumber;

    private static string Value(Field field, Track track) => field switch
    {
        Field.Title => track.Title,
        Field.Artist => track.Artist ?? "",
        Field.Album => track.Album ?? "",
        Field.AlbumArtist => track.AlbumArtist ?? "",
        Field.Composer => track.Composer ?? "",
        Field.Genre => track.Genre ?? "",
        Field.Year => track.Year?.ToString(CultureInfo.InvariantCulture) ?? "",
        Field.Bpm => track.Bpm?.ToString(CultureInfo.InvariantCulture) ?? "",
        Field.TrackNumber => track.TrackNumber?.ToString(CultureInfo.InvariantCulture) ?? "",
        Field.TrackTotal => track.TrackTotal?.ToString(CultureInfo.InvariantCulture) ?? "",
        Field.DiscNumber => track.DiscNumber?.ToString(CultureInfo.InvariantCulture) ?? "",
        Field.DiscTotal => track.DiscTotal?.ToString(CultureInfo.InvariantCulture) ?? "",
        _ => track.Comment ?? "",
    };

    private readonly IReadOnlyList<Track> tracks;
    private readonly AppModel model = AppModel.Current;
    private readonly Dictionary<Field, TextBox> boxes = [];
    private readonly Dictionary<Field, string> initial = [];
    private readonly HashSet<Field> mixed = [];
    private bool? initialCompilation;
    private readonly ComboBox compilation = new() { MinWidth = 110 };
    private readonly TextBox lyrics = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 13, Height = 300 };
    private string initialLyrics = "";
    private byte[]? newCover;
    private readonly ArtworkImage headerArtwork = new() { Width = 64, Height = 64, Radius = 6 };
    private readonly Image headerImage = new() { Width = 64, Height = 64, Stretch = Stretch.UniformToFill };
    private readonly Grid artworkHost = new() { Width = 240, Height = 240, CornerRadius = new CornerRadius(10), HorizontalAlignment = HorizontalAlignment.Center };
    private readonly CheckBox writeToFiles = new() { Content = "Write changes into the files" };
    private ContentDialog? dialog;

    private bool IsSingle => tracks.Count == 1;

    public GetInfoDialog(IReadOnlyList<Track> tracks)
    {
        this.tracks = tracks;
    }

    public async Task ShowAsync(XamlRoot root)
    {
        Load();
        dialog = new ContentDialog
        {
            XamlRoot = root, PrimaryButtonText = "Save", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary,
            Content = Build(),
        };
        dialog.Resources["ContentDialogMaxWidth"] = 680.0;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            args.Cancel = !IsValid;
            if (IsValid) await SaveAsync();
            deferral.Complete();
        };
        await ContentDialogs.ShowAsync(dialog);
    }

    private void Load()
    {
        foreach (var field in Enum.GetValues<Field>())
        {
            var distinct = tracks.Select(track => Value(field, track)).Distinct().ToList();
            if (distinct.Count == 1) initial[field] = distinct[0];
            else
            {
                initial[field] = "";
                mixed.Add(field);
            }
        }
        var flags = tracks.Select(track => track.IsCompilation).Distinct().ToList();
        initialCompilation = flags.Count == 1 ? flags[0] : null;
        initialLyrics = IsSingle ? tracks[0].Lyrics ?? "" : "";
    }

    private FrameworkElement Build()
    {
        var header = Ui.Grid("auto,*");
        header.ColumnSpacing = 14;
        headerArtwork.Hash = tracks[0].ArtworkHash;
        var headerCover = new Grid { Width = 64, Height = 64, CornerRadius = new CornerRadius(6) };
        headerCover.Children.Add(headerArtwork);
        headerCover.Children.Add(headerImage);
        header.Children.Add(headerCover);
        var albums = tracks.Select(track => track.DisplayAlbum).Distinct().ToList();
        var artists = tracks.Select(track => track.DisplayArtist).Distinct().ToList();
        var artist = artists.Count == 1 ? artists[0] : "Various Artists";
        header.Children.Add(Ui.Column(2, Ui.Text(IsSingle ? tracks[0].Title : $"{tracks.Count} songs", "StrongText"),
            Ui.Text(albums.Count == 1 ? $"{artist} · {albums[0]}" : $"{artist} · {albums.Count} albums", "SecondaryText")).With(c => c.VerticalAlignment = VerticalAlignment.Center).At(1));

        var tabs = new SelectorBar();
        var pages = new Dictionary<string, FrameworkElement>
        {
            ["Details"] = Details(), ["Artwork"] = Artwork(), ["Lyrics"] = Lyrics(), ["File"] = FileInfo(),
        };
        var host = new ContentControl { MinHeight = 340, HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Top };
        foreach (var name in pages.Keys) tabs.Items.Add(new SelectorBarItem { Text = name });
        tabs.SelectionChanged += (_, _) => host.Content = pages[tabs.SelectedItem.Text];
        tabs.SelectedItem = tabs.Items[0];
        host.Content = pages["Details"];

        writeToFiles.IsChecked = model.Preferences.Bool(MetadataStore.WriteTagsKey);
        writeToFiles.Checked += (_, _) => model.Preferences.Set(MetadataStore.WriteTagsKey, true);
        writeToFiles.Unchecked += (_, _) => model.Preferences.Set(MetadataStore.WriteTagsKey, false);
        ToolTipService.SetToolTip(writeToFiles, "Off: changes live in Groovelight's library only and survive rescans. On: tags and artwork are saved into the audio files (except for songs from cue sheets, which share one file).");
        var panel = Ui.Column(14, header, tabs, host, writeToFiles);
        panel.Width = 600;
        return panel;
    }

    private FrameworkElement Details()
    {
        var grid = Ui.Grid("auto,*");
        grid.ColumnSpacing = 10;
        grid.RowSpacing = 9;
        var row = 0;
        void Add(string label, FrameworkElement content)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            grid.Children.Add(Ui.Text(label, "SecondaryText").With(t => { t.HorizontalAlignment = HorizontalAlignment.Right; t.VerticalAlignment = VerticalAlignment.Center; }).At(0, row));
            grid.Children.Add(content.At(1, row));
            row++;
        }
        Add("Title", Box(Field.Title));
        Add("Artist", Box(Field.Artist));
        Add("Album", Box(Field.Album));
        Add("Album Artist", Box(Field.AlbumArtist));
        Add("Composer", Box(Field.Composer));
        Add("Genre", Box(Field.Genre));
        Add("Year", Ui.Row(8, Box(Field.Year, 80), Label("BPM"), Box(Field.Bpm, 70)));
        Add("Track", Ui.Row(8, Box(Field.TrackNumber, 60), Label("of"), Box(Field.TrackTotal, 60), Label("Disc").Margin(12, 0, 0, 0), Box(Field.DiscNumber, 60), Label("of"), Box(Field.DiscTotal, 60)));
        compilation.Items.Add("No");
        compilation.Items.Add("Yes");
        if (initialCompilation is null) compilation.Items.Add("Mixed");
        compilation.SelectedIndex = initialCompilation switch { false => 0, true => 1, null => 2 };
        Add("Compilation", compilation);
        var comment = Box(Field.Comment);
        comment.AcceptsReturn = true;
        comment.TextWrapping = TextWrapping.Wrap;
        comment.MinHeight = 56;
        Add("Comments", comment);
        return grid;
    }

    private static TextBlock Label(string text) => Ui.Text(text, "SecondaryText").With(t => t.VerticalAlignment = VerticalAlignment.Center);

    private TextBox Box(Field field, double width = double.NaN)
    {
        var disabled = !IsSingle && IsPerSong(field);
        var box = new TextBox
        {
            Text = initial[field], Width = width, IsEnabled = !disabled,
            PlaceholderText = disabled ? (IsNumber(field) ? "–" : "Per song") : mixed.Contains(field) ? "Mixed" : "",
        };
        if (IsNumber(field))
        {
            box.TextChanged += (_, _) =>
            {
                var valid = IsValidNumber(box.Text);
                box.BorderBrush = valid ? null : new SolidColorBrush(Microsoft.UI.Colors.Red);
                if (valid) box.ClearValue(Control.BorderBrushProperty);
                ToolTipService.SetToolTip(box, valid ? null : "Enter a whole number, or leave empty to remove it");
                if (dialog is not null) dialog.IsPrimaryButtonEnabled = IsValid;
            };
        }
        boxes[field] = box;
        return box;
    }

    private FrameworkElement Artwork()
    {
        ShowArtwork();
        var choose = Ui.Button("Choose Image…", async () =>
        {
            if (await Pickers.FileAsync(Pickers.ImageExtensions, "Use Image", Windows.Storage.Pickers.PickerLocationId.PicturesLibrary) is { } path) await UseImageAsync(path);
        });
        var revert = Ui.Button("Revert", () => { newCover = null; ShowArtwork(); });
        var panel = Ui.Column(12, artworkHost, Ui.Row(8, choose, revert).With(r => r.HorizontalAlignment = HorizontalAlignment.Center),
            Ui.Text(IsSingle ? "Drop an image on the artwork to use it." : $"The image is used for all {tracks.Count} songs.", "CaptionText").With(t => t.HorizontalAlignment = HorizontalAlignment.Center));
        artworkHost.AllowDrop = true;
        artworkHost.DragOver += (_, args) =>
        {
            if (args.DataView.Contains(StandardDataFormats.StorageItems)) args.AcceptedOperation = DataPackageOperation.Copy;
        };
        artworkHost.Drop += async (_, args) =>
        {
            if (!args.DataView.Contains(StandardDataFormats.StorageItems)) return;
            var items = await args.DataView.GetStorageItemsAsync();
            if (items.FirstOrDefault()?.Path is { } path) await UseImageAsync(path);
        };
        return panel;
    }

    private void ShowArtwork()
    {
        artworkHost.Children.Clear();
        if (newCover is null)
        {
            headerImage.Source = null;
            if (tracks.Select(track => track.ArtworkHash).Distinct().Count() > 1)
            {
                artworkHost.Children.Add(new Border { Background = Ui.Brush("ControlFillColorSecondaryBrush") });
                artworkHost.Children.Add(Ui.Text("Mixed artwork", "SecondaryText").With(t => { t.HorizontalAlignment = HorizontalAlignment.Center; t.VerticalAlignment = VerticalAlignment.Center; }));
            }
            else artworkHost.Children.Add(new ArtworkImage { Hash = tracks[0].ArtworkHash, IsLarge = true, Radius = 0 });
            return;
        }
        _ = ShowNewCoverAsync();
    }

    private async Task ShowNewCoverAsync()
    {
        if (newCover is null) return;
        var bitmap = await Images.FromBytesAsync(newCover);
        artworkHost.Children.Clear();
        artworkHost.Children.Add(new Image { Source = bitmap, Stretch = Stretch.UniformToFill });
        headerImage.Source = bitmap;
    }

    private async Task UseImageAsync(string path)
    {
        try
        {
            var data = await File.ReadAllBytesAsync(path);
            using var image = SkiaSharp.SKBitmap.Decode(data);
            if (image is null) throw new InvalidDataException();
            newCover = data;
            ShowArtwork();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            model.ErrorMessage = $"{Path.GetFileName(path)} is not an image Groovelight can read.";
        }
    }

    private FrameworkElement Lyrics()
    {
        if (!IsSingle) return Ui.Unavailable(Glyphs.Lyrics, "Lyrics are per song", "Select a single song to edit its lyrics.");
        lyrics.Text = initialLyrics;
        return Ui.Column(6, lyrics, Ui.Text("Plain text, or synced lyrics in LRC format (\"[01:23.45] line\"). Leave empty to remove them.", "CaptionText").With(t => t.TextWrapping = TextWrapping.Wrap));
    }

    private FrameworkElement FileInfo()
    {
        if (!IsSingle) return Ui.Unavailable("", $"{tracks.Count} songs", "Select a single song to see its file details.");
        var track = tracks[0];
        var spec = track.AudioSpec;
        var grid = Ui.Grid("auto,*");
        grid.ColumnSpacing = 12;
        grid.RowSpacing = 7;
        var row = 0;
        void Add(string label, FrameworkElement value)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            grid.Children.Add(Ui.Text(label, "SecondaryText").With(t => t.HorizontalAlignment = HorizontalAlignment.Right).At(0, row));
            grid.Children.Add(value.At(1, row));
            row++;
        }
        TextBlock Value(string text) => new() { Text = text, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap };
        Add("Format", Value(spec.Tier == QualityTier.Standard ? spec.Summary : $"{spec.Tier.DisplayName()} · {spec.Summary}"));
        Add("Bit rate", Value(spec.BitrateText ?? ""));
        Add("Channels", Value(spec.ChannelsText ?? ""));
        Add("Duration", Value(Format.Duration(track.Duration)));
        Add("Size", Value(Format.Bytes(track.FileSize)));
        Add("Date Added", Value(Format.DateTime(track.DateAdded)));
        Add("Plays", Value($"{track.PlayCount}{(track.LastPlayedAt is { } last ? $", last {Format.DateTime(last)}" : "")}"));
        var location = Ui.Column(4, Value(track.FilePath));
        var show = new HyperlinkButton { Content = "Show in File Explorer", Padding = new Thickness(0) };
        show.Click += (_, _) => AppModel.ShowInExplorer([track]);
        location.Children.Add(show);
        Add("Location", location);
        if (track.IsCueTrack && track.CueSheetPath is { } sheet)
        {
            Add("Cue Sheet", Value(string.Equals(sheet, track.FilePath, StringComparison.OrdinalIgnoreCase) ? "Embedded in the file" : Path.GetFileName(sheet)));
            Add("Range", Value($"{Format.Duration(track.StartTime ?? 0)} to {(track.EndTime is { } end ? Format.Duration(end) : "end of file")}"));
        }
        return grid;
    }

    private static bool IsValidNumber(string text)
    {
        var trimmed = text.Trim();
        return trimmed.Length == 0 || (int.TryParse(trimmed, NumberStyles.None, CultureInfo.InvariantCulture, out var value) && value >= 0);
    }

    private bool IsValid => boxes.Where(pair => IsNumber(pair.Key)).All(pair => IsValidNumber(pair.Value.Text));

    /// <summary>The edits (fields left alone stay null). Empty text or numbers clear the tag.</summary>
    private TrackMetadata Edits()
    {
        string? Changed(Field field)
        {
            var value = boxes.TryGetValue(field, out var box) ? box.Text : initial[field];
            // A mixed field left empty was not edited.
            if (value == initial[field] || (mixed.Contains(field) && value.Length == 0)) return null;
            return value;
        }
        int? Number(Field field) => Changed(field) is { } text ? (int.TryParse(text.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var value) ? value : 0) : null;
        bool? flag = compilation.SelectedIndex switch { 0 => false, 1 => true, _ => null };
        return new TrackMetadata
        {
            Title = IsSingle ? Changed(Field.Title) : null,
            Artist = Changed(Field.Artist), Album = Changed(Field.Album), AlbumArtist = Changed(Field.AlbumArtist), Composer = Changed(Field.Composer),
            Genre = Changed(Field.Genre), Comment = Changed(Field.Comment), Year = Number(Field.Year), Bpm = Number(Field.Bpm),
            TrackNumber = IsSingle ? Number(Field.TrackNumber) : null, TrackTotal = Number(Field.TrackTotal), DiscNumber = Number(Field.DiscNumber),
            DiscTotal = Number(Field.DiscTotal), IsCompilation = flag != initialCompilation ? flag : null,
            Lyrics = IsSingle && lyrics.Text.Replace("\r", "\n") != initialLyrics.Replace("\r\n", "\n") ? lyrics.Text.Replace("\r\n", "\n").Replace('\r', '\n') : null,
        };
    }

    private async Task SaveAsync()
    {
        var metadata = Edits();
        var ids = tracks.Select(track => track.Id).OfType<long>().ToList();
        if (metadata.IsEmpty && newCover is null) return;
        var changes = metadata.IsEmpty ? new Dictionary<long, TrackMetadata>() : ids.ToDictionary(id => id, _ => metadata);
        var result = await model.Metadata.ApplyAsync(changes, newCover, newCover is null ? [] : ids, writeToFiles.IsChecked == true);
        if (result.FailedWrites.Count > 0)
        {
            model.ErrorMessage = $"Could not write tags to {result.FailedWrites.Count} file(s): {string.Join(", ", result.FailedWrites.Take(3))}. The changes were saved in the library instead.";
        }
        // The album may have been renamed: reopen its page under the new name.
        await model.ShowAlbumContainingAsync(ids.FirstOrDefault());
    }
}
