using Groovelight.Core;
using Groovelight.Core.Library;
using Groovelight.Model;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Groovelight.Controls;

/// <summary>
/// A playlist's cover as configured (generated, a custom image or its songs' covers), with its name, drawn off the UI
/// thread at the size it is shown (the Mac's PlaylistCoverView). A gear badge marks smart playlists without a title.
/// </summary>
public sealed partial class PlaylistCoverImage : Grid
{
    private static readonly Dictionary<string, BitmapImage> cache = [];
    private readonly Border border = new();
    private readonly Image image = new() { Stretch = Stretch.UniformToFill };
    private readonly Border badge;
    private string? shownKey;
    private int version;

    public PlaylistCoverImage()
    {
        border.Child = image;
        Children.Add(border);
        badge = new Border
        {
            Width = 22, Height = 22, CornerRadius = new CornerRadius(11), Margin = new Thickness(6),
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(115, 0, 0, 0)),
            Child = new FontIcon { Glyph = "", FontSize = 11, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White) },
            Visibility = Visibility.Collapsed,
        };
        Children.Add(badge);
        SizeChanged += (_, _) => Update();
        Loaded += (_, _) => Update();
    }

    /// <summary>What to draw: a playlist summary, or the parts set one by one (the Edit Playlist preview).</summary>
    public void Set(string name, PlaylistCover? cover, IReadOnlyList<string> songHashes, long seed, bool isSmart = false, bool hidesTitle = false)
    {
        this.name = name;
        this.cover = cover;
        this.songHashes = songHashes;
        this.seed = seed;
        this.isSmart = isSmart;
        this.hidesTitle = hidesTitle;
        Update();
    }

    private string name = "";
    private PlaylistCover? cover;
    private IReadOnlyList<string> songHashes = [];
    private long seed;
    private bool isSmart;
    private bool hidesTitle;

    public static readonly DependencyProperty SummaryProperty = DependencyProperty.Register(nameof(Summary), typeof(PlaylistSummary),
        typeof(PlaylistCoverImage), new PropertyMetadata(null, (owner, args) =>
        {
            if (args.NewValue is PlaylistSummary summary)
                ((PlaylistCoverImage)owner).Set(summary.Playlist.Name, summary.Playlist.CoverStyle, summary.ArtworkHashes, summary.Id, summary.Playlist.IsSmart);
        }));

    public PlaylistSummary? Summary
    {
        get => (PlaylistSummary?)GetValue(SummaryProperty);
        set => SetValue(SummaryProperty, value);
    }

    public static readonly DependencyProperty RadiusProperty = DependencyProperty.Register(nameof(Radius), typeof(double), typeof(PlaylistCoverImage),
        new PropertyMetadata(10.0, (owner, args) => ((PlaylistCoverImage)owner).border.CornerRadius = new CornerRadius((double)args.NewValue)));

    public double Radius
    {
        get => (double)GetValue(RadiusProperty);
        set => SetValue(RadiusProperty, value);
    }

    private async void Update()
    {
        border.CornerRadius = new CornerRadius(Radius);
        badge.Visibility = isSmart && (hidesTitle || !PlaylistCovers.ShowsTitle(cover)) && ActualWidth > 60 ? Visibility.Visible : Visibility.Collapsed;
        var scale = XamlRoot?.RasterizationScale ?? 1;
        var side = (int)Math.Ceiling(Math.Max(ActualWidth, ActualHeight) * scale);
        if (side <= 0) return;
        // Small sizes are drawn at 200 pixels and shrunk, so the name wraps as on a full cover (the sidebar icon).
        var drawSide = Math.Max(side, 200);
        var coverJson = cover is null ? "" : System.Text.Encoding.UTF8.GetString(SwiftJson.Encode(cover));
        var key = $"{name}\u0001{coverJson}\u0001{string.Join(",", songHashes.Take(4))}\u0001{seed}\u0001{drawSide}\u0001{hidesTitle}";
        if (key == shownKey) return;
        shownKey = key;
        if (cache.TryGetValue(key, out var cached))
        {
            image.Source = cached;
            return;
        }
        var ticket = ++version;
        var (n, c, h, s, t) = (name, cover, songHashes.ToList(), seed, hidesTitle);
        var artwork = AppModel.Current.Artwork;
        var png = await Task.Run(() => PlaylistCovers.RenderPng(artwork, n, c, h, s, drawSide, t));
        if (ticket != version) return;
        var bitmap = await Images.FromBytesAsync(png);
        if (cache.Count > 300) cache.Clear();
        cache[key] = bitmap;
        if (ticket == version) image.Source = bitmap;
    }
}
