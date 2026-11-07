using System.Globalization;
using Groovelight.Controls;
using Groovelight.Core.Library;
using Groovelight.Metadata;
using Groovelight.Model;
using Groovelight.Support;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Groovelight.Dialogs;

/// <summary>
/// Review of online metadata (the Mac's Fix Metadata sheet): pick the matching MusicBrainz release, then accept the
/// proposed changes field by field (album info), song by song, and the cover. The songs are fixed as one album even
/// when their tags name several; songs missing from the release can still take the album's info.
/// </summary>
public sealed class FixMetadataDialog(IReadOnlyList<Track> tracks)
{
    private enum AlbumField { Album, AlbumArtist, Year, Genre, Compilation }

    private static string Title(AlbumField field) => field switch
    {
        AlbumField.Album => "Album", AlbumField.AlbumArtist => "Album Artist", AlbumField.Year => "Year", AlbumField.Genre => "Genre", _ => "Compilation",
    };

    private readonly AppModel model = AppModel.Current;
    private readonly SongGroup group = new(tracks);
    private readonly TextBox albumQuery = new() { PlaceholderText = "Album", Width = 220 };
    private readonly TextBox artistQuery = new() { PlaceholderText = "Artist", Width = 180 };
    private readonly ListView candidateList = new() { SelectionMode = ListViewSelectionMode.Single };
    private readonly ContentControl candidateHost = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly ContentControl detail = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly CheckBox writeToFiles = new() { Content = "Write changes into the files" };
    private readonly ProgressBar progress = new() { Width = 200, Visibility = Visibility.Collapsed };
    private readonly TextBlock progressText = new() { VerticalAlignment = VerticalAlignment.Center };
    private List<MBRelease> candidates = [];
    private ReleaseMatch? match;
    private Dictionary<long, TrackMetadata> proposal = [];
    private HashSet<AlbumField> acceptedFields = [.. Enum.GetValues<AlbumField>()];
    private HashSet<long> acceptedTracks = [];
    private byte[]? cover;
    private string? coverSource;
    private bool isLoadingCover;
    private bool useCover = true;
    private bool isApplying;
    private bool ready;
    private CancellationTokenSource? load;
    private ContentDialog? dialog;
    private bool updatingList;

    public async Task ShowAsync(XamlRoot root)
    {
        albumQuery.Text = group.Album ?? "";
        artistQuery.Text = group.Artist ?? "";
        dialog = new ContentDialog { XamlRoot = root, PrimaryButtonText = "Apply", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary, IsPrimaryButtonEnabled = false };
        dialog.Resources["ContentDialogMaxWidth"] = 1000.0;
        dialog.Resources["ContentDialogMaxHeight"] = 820.0;
        var search = Ui.Button("Search", Search);
        foreach (var box in new[] { albumQuery, artistQuery })
            box.KeyDown += (_, args) => { if (args.Key == Windows.System.VirtualKey.Enter) { args.Handled = true; Search(); } };
        var header = Ui.Grid("*,auto,auto,auto");
        header.ColumnSpacing = 12;
        var subtitle = Ui.Text(Subtitle, "SecondaryText");
        if (group.IsMixed) ToolTipService.SetToolTip(subtitle, "The songs are now in different albums. The ones you accept become one album.");
        header.Children.Add(Ui.Column(2, Ui.Text("Fix Metadata", "SectionTitleText"), subtitle));
        header.Children.Add(albumQuery.At(1));
        header.Children.Add(artistQuery.At(2));
        header.Children.Add(search.At(3));
        foreach (var child in header.Children.OfType<FrameworkElement>()) child.VerticalAlignment = VerticalAlignment.Center;
        candidateList.SelectionChanged += (_, _) =>
        {
            if (updatingList || candidateList.SelectedIndex < 0 || candidateList.SelectedIndex >= candidates.Count) return;
            LoadRelease(candidates[candidateList.SelectedIndex].Id);
        };
        var body = Ui.Grid("270,*");
        body.ColumnSpacing = 0;
        body.Children.Add(new Border { Child = candidateHost, BorderThickness = new Thickness(0, 0, 1, 0), BorderBrush = Ui.Brush("DividerStrokeColorDefaultBrush"), Background = Ui.Brush("LayerFillColorDefaultBrush") });
        body.Children.Add(detail.At(1));
        body.Height = 520;
        writeToFiles.IsChecked = model.Preferences.Bool(MetadataStore.WriteTagsKey);
        writeToFiles.Click += (_, _) => model.Preferences.Set(MetadataStore.WriteTagsKey, writeToFiles.IsChecked == true);
        ToolTipService.SetToolTip(writeToFiles, "Off: fixes live in Groovelight's library only and survive rescans. On: tags and cover are saved into the audio files.");
        var footer = Ui.Row(12, writeToFiles, progress, progressText);
        var content = Ui.Column(12, header, Ui.Separator(), body, Ui.Separator(), footer);
        content.Width = 920;
        dialog.Content = content;
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            await ApplyAsync();
            deferral.Complete();
        };
        dialog.Closing += (_, args) => { if (isApplying) args.Cancel = true; };
        Search();
        await ContentDialogs.ShowAsync(dialog);
        load?.Cancel();
    }

    private string Subtitle
    {
        get
        {
            var songs = Format.Songs(tracks.Count);
            return group.IsMixed ? $"{songs} from {group.AlbumCount} albums, fixed as one album" : songs;
        }
    }

    private static FrameworkElement Centered(FrameworkElement element)
    {
        element.HorizontalAlignment = HorizontalAlignment.Center;
        element.VerticalAlignment = VerticalAlignment.Center;
        return element;
    }

    private static FrameworkElement Spinner(string text) => Centered(Ui.Column(10, Centered(new ProgressRing { IsActive = true }), Ui.Text(text, "SecondaryText")));

    private async void Search()
    {
        load?.Cancel();
        load = new CancellationTokenSource();
        var token = load.Token;
        ready = false;
        match = null;
        UpdateButtons();
        candidateHost.Content = Spinner("Searching MusicBrainz…");
        detail.Content = null;
        try
        {
            // The fields as typed: an emptied field searches without it instead of falling back to the tags.
            var found = await model.Metadata.Service.CandidatesAsync(tracks, albumQuery.Text.Trim(), artistQuery.Text.Trim(), token);
            if (token.IsCancellationRequested) return;
            candidates = found.Take(25).ToList();
            if (candidates.Count == 0)
            {
                candidateHost.Content = Ui.Unavailable(Glyphs.Search, "No Matches", "Try another album title or artist.");
                detail.Content = Centered(Ui.Text("Select a release", "SecondaryText"));
                return;
            }
            updatingList = true;
            candidateList.Items.Clear();
            foreach (var release in candidates) candidateList.Items.Add(new ListViewItem { Content = CandidateRow(release), Padding = new Thickness(12, 6, 12, 6) });
            candidateList.SelectedIndex = 0;
            updatingList = false;
            candidateHost.Content = candidateList;
            LoadRelease(candidates[0].Id);
        }
        catch (Exception error) when (MetadataStore.IsOffline(error))
        {
            if (!token.IsCancellationRequested) candidateHost.Content = Ui.Unavailable("", "Search Failed", error.Message);
        }
    }

    private static FrameworkElement CandidateRow(MBRelease release)
    {
        var row = Ui.Column(3, Ui.Text(release.Title, "StrongText", 13), Ui.Text(release.ArtistName, "CaptionText"),
            Ui.Text(string.Join(" · ", new[] { release.Year?.ToString(CultureInfo.InvariantCulture), release.Country, $"{release.TotalTracks} tracks", release.Media?.FirstOrDefault()?.Format }.OfType<string>()), "SmallText"));
        var tags = new[] { release.Status == "Official" ? null : release.Status }.Concat(release.ReleaseGroup?.SecondaryTypes ?? []).OfType<string>().ToList();
        if (tags.Count > 0)
        {
            var badges = Ui.Row(4);
            foreach (var tag in tags)
            {
                badges.Children.Add(new Border
                {
                    CornerRadius = new CornerRadius(6), Padding = new Thickness(5, 1, 5, 1), Background = new SolidColorBrush(Windows.UI.Color.FromArgb(46, 255, 165, 0)),
                    Child = new TextBlock { Text = tag.ToUpperInvariant(), FontSize = 8, FontWeight = FontWeights.Bold, Foreground = new SolidColorBrush(Microsoft.UI.Colors.Orange) },
                });
            }
            row.Children.Add(badges);
        }
        return row;
    }

    private async void LoadRelease(string id)
    {
        load?.Cancel();
        load = new CancellationTokenSource();
        var token = load.Token;
        ready = false;
        cover = null;
        coverSource = null;
        UpdateButtons();
        detail.Content = Spinner("Loading tracklist…");
        try
        {
            var service = model.Metadata.Service;
            var result = await service.MatchAsync(tracks, id, token);
            if (token.IsCancellationRequested) return;
            match = result;
            proposal = ReleaseMatcher.Proposal(result, includingUnmatched: true);
            // Songs not on the release are left out unless checked.
            acceptedTracks = result.Matches.Select(item => item.LocalId).ToHashSet();
            acceptedFields = [.. Enum.GetValues<AlbumField>()];
            ready = true;
            isLoadingCover = true;
            ShowDetail();
            var found = await service.CoverAsync(result.Release, result.Release.Title, result.Release.ArtistName, token);
            if (token.IsCancellationRequested) return;
            cover = found?.Data;
            coverSource = found?.Candidate.Source.Title();
            isLoadingCover = false;
            ShowDetail();
        }
        catch (Exception error) when (MetadataStore.IsOffline(error))
        {
            if (!token.IsCancellationRequested) detail.Content = Ui.Unavailable("", "Could Not Load the Release", error.Message);
        }
    }

    private void UpdateButtons()
    {
        if (dialog is not null) dialog.IsPrimaryButtonEnabled = !isApplying && ready && ChangeCount > 0;
    }

    private void ShowDetail()
    {
        if (match is null) return;
        var panel = Ui.Column(20, CoverRow(match), AlbumFields(), SongRows(match));
        panel.Padding = new Thickness(20);
        detail.Content = new ScrollViewer { Content = panel };
        UpdateButtons();
    }

    private FrameworkElement CoverRow(ReleaseMatch release)
    {
        var row = Ui.Grid("auto,auto,auto,*,auto");
        row.ColumnSpacing = 14;
        row.Children.Add(new ArtworkImage { Hash = tracks.Select(track => track.ArtworkHash).OfType<string>().FirstOrDefault(), Width = 90, Height = 90, Radius = 6 });
        row.Children.Add(Ui.Icon("", 14, "SecondaryIcon").With(icon => icon.VerticalAlignment = VerticalAlignment.Center).At(1));
        var box = new Grid { Width = 90, Height = 90, CornerRadius = new CornerRadius(6), Background = Ui.Brush("ControlFillColorSecondaryBrush") };
        if (cover is not null)
        {
            var image = new Image { Stretch = Stretch.UniformToFill };
            _ = SetImageAsync(image, cover);
            box.Children.Add(image);
        }
        else if (isLoadingCover) box.Children.Add(Centered(new ProgressRing { IsActive = true, Width = 20, Height = 20 }));
        else box.Children.Add(Centered(Ui.Icon("", 24, "SecondaryIcon")));
        row.Children.Add(box.At(2));
        var use = new CheckBox { Content = "Use this cover", IsChecked = useCover && cover is not null, IsEnabled = cover is not null };
        use.Click += (_, _) => { useCover = use.IsChecked == true; UpdateButtons(); };
        row.Children.Add(Ui.Column(6, use, Ui.Text(cover is null ? (isLoadingCover ? "Looking for a cover…" : "No cover found online") : $"From {coverSource ?? "the web"}", "CaptionText"))
            .With(column => column.VerticalAlignment = VerticalAlignment.Center).At(3));
        var matched = release.Matches.Count;
        var score = Ui.Column(2,
            Ui.Text($"{matched} of {tracks.Count} songs matched", "StrongText", 13).With(t => t.Foreground = new SolidColorBrush(matched == tracks.Count ? Microsoft.UI.Colors.MediumSeaGreen : Microsoft.UI.Colors.Orange)),
            Ui.Text($"Release has {release.Release.TotalTracks} tracks", "CaptionText"));
        score.HorizontalAlignment = HorizontalAlignment.Right;
        score.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(score.At(4));
        return row;
    }

    private static async Task SetImageAsync(Image image, byte[] data) => image.Source = await Images.FromBytesAsync(data);

    private FrameworkElement AlbumFields()
    {
        var sample = proposal.Values.FirstOrDefault() ?? new TrackMetadata();
        var grid = Ui.Grid("140,*");
        grid.RowSpacing = 6;
        var row = 0;
        foreach (var field in Enum.GetValues<AlbumField>())
        {
            var current = CurrentValue(field);
            var proposed = Value(field, sample);
            var changes = proposed is not null && proposed != current;
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var box = new CheckBox { Content = Title(field), IsChecked = changes && acceptedFields.Contains(field), IsEnabled = changes, MinWidth = 0 };
            box.Click += (_, _) =>
            {
                if (box.IsChecked == true) acceptedFields.Add(field); else acceptedFields.Remove(field);
                UpdateButtons();
            };
            grid.Children.Add(box.At(0, row));
            grid.Children.Add(ChangeText(current, proposed).With(text => text.VerticalAlignment = VerticalAlignment.Center).At(1, row));
            row++;
        }
        return Ui.Column(8, Ui.Text("Album", "StrongText"), grid);
    }

    private static FrameworkElement ChangeText(string? current, string? proposed)
    {
        if (proposed is not null && proposed != current)
        {
            var old = new TextBlock { Text = current ?? "Empty", Style = Ui.Style("SecondaryText") };
            if (current is not null) old.TextDecorations = Windows.UI.Text.TextDecorations.Strikethrough;
            return Ui.Row(8, old, Ui.Icon("", 10, "SecondaryIcon").With(i => i.VerticalAlignment = VerticalAlignment.Center), Ui.Text(proposed, "StrongText"));
        }
        return Ui.Row(8, Ui.Text(current ?? "Empty", "SecondaryText"), Ui.Text("unchanged", "SmallText").With(t => t.VerticalAlignment = VerticalAlignment.Center));
    }

    private FrameworkElement SongRows(ReleaseMatch release)
    {
        var ordered = tracks.OrderBy(track => track.Id is { } id && release.MatchFor(id) is { } item ? 0 : 1)
            .ThenBy(track => track.Id is { } id && release.MatchFor(id) is { } item ? item.DiscNumber * 1000 + item.TrackNumber : 0)
            .ThenBy(track => track.Title, StringComparer.CurrentCulture).ToList();
        var head = Ui.Grid("*,auto");
        head.Children.Add(Ui.Text("Songs", "StrongText"));
        var toggleAll = new HyperlinkButton { Content = acceptedTracks.Count == proposal.Count ? "Deselect All" : "Select All", IsEnabled = proposal.Count > 0 };
        toggleAll.Click += (_, _) =>
        {
            acceptedTracks = acceptedTracks.Count == proposal.Count ? [] : proposal.Keys.ToHashSet();
            ShowDetail();
        };
        head.Children.Add(toggleAll.At(1));
        var list = Ui.Column(0);
        var multiDisc = (release.Release.Media?.Count ?? 0) > 1;
        foreach (var track in ordered)
        {
            var id = track.Id ?? -1;
            var item = release.MatchFor(id);
            var row = Ui.Grid("auto,*,auto,*,auto");
            row.ColumnSpacing = 10;
            row.Padding = new Thickness(0, 6, 0, 6);
            var box = new CheckBox { IsChecked = acceptedTracks.Contains(id), IsEnabled = proposal.ContainsKey(id), MinWidth = 0 };
            box.Click += (_, _) =>
            {
                if (box.IsChecked == true) acceptedTracks.Add(id); else acceptedTracks.Remove(id);
                UpdateButtons();
            };
            row.Children.Add(box);
            var name = Ui.Text($"{(track.TrackNumber is { } number ? $"{number}. " : "")}{track.Title}", item is null ? "SecondaryText" : "BodyText");
            row.Children.Add(Ui.Column(2, name, Ui.Text(Path.GetFileName(track.Path), "SmallText")).At(1));
            row.Children.Add(Ui.Icon("", 10, "SecondaryIcon").With(i => i.VerticalAlignment = VerticalAlignment.Center).At(2));
            FrameworkElement target;
            if (item is not null)
            {
                var prefix = multiDisc ? $"{item.DiscNumber}-{item.TrackNumber}" : $"{item.TrackNumber}";
                var text = Ui.Text($"{prefix}. {item.Track.Title}", "BodyText");
                if (item.Score < 0.75) text.Foreground = new SolidColorBrush(Microsoft.UI.Colors.Orange);
                ToolTipService.SetToolTip(text, item.Score >= 0.75 ? "Good match" : "Uncertain match: check this song");
                target = text;
            }
            else
            {
                target = Ui.Text("Not on this release: album info only", "SecondaryText")
                    .Tooltip("Check it to give this song the album, album artist, year and genre, keeping its title and number");
            }
            target.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(target.At(3));
            row.Children.Add(Ui.Text(Format.Duration(track.Duration), "CaptionText").With(t => t.VerticalAlignment = VerticalAlignment.Center).At(4));
            list.Children.Add(row);
            list.Children.Add(Ui.Separator());
        }
        return Ui.Column(8, head, list);
    }

    private string? CurrentValue(AlbumField field)
    {
        // The songs' value, or the different ones they have now ("The Bends, Kid A").
        var distinct = tracks.Select(track => Value(field, track.Metadata())).OfType<string>().Distinct().ToList();
        if (distinct.Count <= 1) return distinct.FirstOrDefault();
        return distinct.Count <= 3 ? string.Join(", ", distinct) : $"{distinct.Count} different values";
    }

    private static string? Value(AlbumField field, TrackMetadata metadata) => field switch
    {
        AlbumField.Album => metadata.Album,
        AlbumField.AlbumArtist => metadata.AlbumArtist,
        AlbumField.Year => metadata.Year?.ToString(CultureInfo.InvariantCulture),
        AlbumField.Genre => metadata.Genre,
        _ => metadata.IsCompilation is { } flag ? (flag ? "Yes" : "No") : null,
    };

    /// <summary>Accepted changes, keeping only fields that differ from the current values.</summary>
    private Dictionary<long, TrackMetadata> Changes
    {
        get
        {
            var result = new Dictionary<long, TrackMetadata>();
            foreach (var track in tracks)
            {
                if (track.Id is not { } id || !acceptedTracks.Contains(id) || !proposal.TryGetValue(id, out var metadata)) continue;
                metadata = metadata with
                {
                    Album = acceptedFields.Contains(AlbumField.Album) ? metadata.Album : null,
                    AlbumArtist = acceptedFields.Contains(AlbumField.AlbumArtist) ? metadata.AlbumArtist : null,
                    Year = acceptedFields.Contains(AlbumField.Year) ? metadata.Year : null,
                    Genre = acceptedFields.Contains(AlbumField.Genre) ? metadata.Genre : null,
                    IsCompilation = acceptedFields.Contains(AlbumField.Compilation) ? metadata.IsCompilation : null,
                };
                var diff = ChangesFrom(metadata, track.Metadata());
                if (!diff.IsEmpty) result[id] = diff;
            }
            return result;
        }
    }

    /// <summary>Only the fields of <paramref name="proposed"/> that differ from <paramref name="current"/>.</summary>
    internal static TrackMetadata ChangesFrom(TrackMetadata proposed, TrackMetadata current) => new()
    {
        Title = proposed.Title != current.Title ? proposed.Title : null,
        Artist = proposed.Artist != current.Artist ? proposed.Artist : null,
        Album = proposed.Album != current.Album ? proposed.Album : null,
        AlbumArtist = proposed.AlbumArtist != current.AlbumArtist ? proposed.AlbumArtist : null,
        Genre = proposed.Genre != current.Genre ? proposed.Genre : null,
        Year = proposed.Year != current.Year ? proposed.Year : null,
        TrackNumber = proposed.TrackNumber != current.TrackNumber ? proposed.TrackNumber : null,
        TrackTotal = proposed.TrackTotal != current.TrackTotal ? proposed.TrackTotal : null,
        DiscNumber = proposed.DiscNumber != current.DiscNumber ? proposed.DiscNumber : null,
        DiscTotal = proposed.DiscTotal != current.DiscTotal ? proposed.DiscTotal : null,
        IsCompilation = proposed.IsCompilation != current.IsCompilation ? proposed.IsCompilation : null,
        MusicBrainzRecordingId = proposed.MusicBrainzRecordingId != current.MusicBrainzRecordingId ? proposed.MusicBrainzRecordingId : null,
        MusicBrainzReleaseId = proposed.MusicBrainzReleaseId != current.MusicBrainzReleaseId ? proposed.MusicBrainzReleaseId : null,
        Composer = proposed.Composer != current.Composer ? proposed.Composer : null,
        Comment = proposed.Comment != current.Comment ? proposed.Comment : null,
        Bpm = proposed.Bpm != current.Bpm ? proposed.Bpm : null,
        Lyrics = proposed.Lyrics != current.Lyrics ? proposed.Lyrics : null,
    };

    private int ChangeCount => Changes.Count + (useCover && cover is not null ? 1 : 0);

    private async Task ApplyAsync()
    {
        isApplying = true;
        UpdateButtons();
        progress.Visibility = Visibility.Visible;
        writeToFiles.Visibility = Visibility.Collapsed;
        var writes = writeToFiles.IsChecked == true;
        var result = await model.Metadata.ApplyAsync(Changes, useCover ? cover : null, tracks.Select(track => track.Id).OfType<long>().ToList(), writes,
            (done, total) => model.Queue.TryEnqueue(() =>
            {
                progress.Maximum = Math.Max(total, 1);
                progress.Value = done;
                progressText.Text = $"{(writes ? "Writing" : "Saving")} {Math.Min(done + 1, Math.Max(total, 1))} of {Math.Max(total, 1)} songs…";
            }));
        isApplying = false;
        if (result.FailedWrites.Count > 0)
            model.ErrorMessage = $"Could not write tags to {result.FailedWrites.Count} file(s): {string.Join(", ", result.FailedWrites.Take(3))}. The changes were saved in the library instead.";
        await model.ShowAlbumContainingAsync(tracks.Select(track => track.Id).OfType<long>().FirstOrDefault());
    }
}
