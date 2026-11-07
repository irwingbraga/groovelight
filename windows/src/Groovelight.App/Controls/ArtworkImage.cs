using Groovelight.Core.Library;
using Groovelight.Model;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.UI;

namespace Groovelight.Controls;

/// <summary>Album artwork from the cache with the Mac's placeholder (a gradient from the hash, and a note).</summary>
public sealed partial class ArtworkImage : Grid
{
    private readonly Border border = new();
    private readonly FontIcon note = new() { Glyph = "", Foreground = new SolidColorBrush(Color.FromArgb(128, 255, 255, 255)) };
    private readonly Image image = new() { Stretch = Stretch.UniformToFill };

    public ArtworkImage()
    {
        border.Child = new Grid { Children = { note, image } };
        Children.Add(border);
        SizeChanged += (_, args) => note.FontSize = Math.Clamp(args.NewSize.Width * 0.28, 10, 48);
        Update();
    }

    public static readonly DependencyProperty HashProperty = DependencyProperty.Register(nameof(Hash), typeof(string), typeof(ArtworkImage),
        new PropertyMetadata(null, (owner, _) => ((ArtworkImage)owner).Update()));

    public string? Hash
    {
        get => (string?)GetValue(HashProperty);
        set => SetValue(HashProperty, value);
    }

    public static readonly DependencyProperty IsLargeProperty = DependencyProperty.Register(nameof(IsLarge), typeof(bool), typeof(ArtworkImage),
        new PropertyMetadata(false, (owner, _) => ((ArtworkImage)owner).Update()));

    /// <summary>The 800 pixel image instead of the 256 pixel one.</summary>
    public bool IsLarge
    {
        get => (bool)GetValue(IsLargeProperty);
        set => SetValue(IsLargeProperty, value);
    }

    public static readonly DependencyProperty RadiusProperty = DependencyProperty.Register(nameof(Radius), typeof(double), typeof(ArtworkImage),
        new PropertyMetadata(8.0, (owner, args) => ((ArtworkImage)owner).border.CornerRadius = new CornerRadius((double)args.NewValue)));

    public double Radius
    {
        get => (double)GetValue(RadiusProperty);
        set => SetValue(RadiusProperty, value);
    }

    private void Update()
    {
        border.CornerRadius = new CornerRadius(Radius);
        border.Background = Placeholder(Hash ?? "");
        image.Source = Hash is { } hash ? Images.Artwork(hash, IsLarge ? ArtworkCache.Size.Large : ArtworkCache.Size.Small) : null;
        note.Visibility = image.Source is null ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>A gradient whose hue comes from the seed, like the Mac's PlaceholderArtwork.</summary>
    public static Brush Placeholder(string seed)
    {
        var value = 7;
        foreach (var character in seed) value = (value * 31 + character) & 0xFFFF;
        var hue = value % 360 / 360.0;
        return new LinearGradientBrush
        {
            StartPoint = new Windows.Foundation.Point(0, 0),
            EndPoint = new Windows.Foundation.Point(1, 1),
            GradientStops =
            {
                new GradientStop { Color = Hsb(hue, 0.35, 0.45), Offset = 0 },
                new GradientStop { Color = Hsb(hue, 0.5, 0.2), Offset = 1 },
            },
        };
    }

    public static Color Hsb(double hue, double saturation, double brightness, byte alpha = 255)
    {
        var h = hue * 6;
        var i = (int)Math.Floor(h) % 6;
        var f = h - Math.Floor(h);
        var p = brightness * (1 - saturation);
        var q = brightness * (1 - f * saturation);
        var t = brightness * (1 - (1 - f) * saturation);
        var (r, g, b) = i switch
        {
            0 => (brightness, t, p),
            1 => (q, brightness, p),
            2 => (p, brightness, t),
            3 => (p, q, brightness),
            4 => (t, p, brightness),
            _ => (brightness, p, q),
        };
        return Color.FromArgb(alpha, (byte)(r * 255), (byte)(g * 255), (byte)(b * 255));
    }
}

/// <summary>Decoded artwork images, shared by every view that shows the same cover.</summary>
public static class Images
{
    private static readonly Dictionary<string, WeakReference<BitmapImage>> cache = [];

    public static ImageSource? Artwork(string hash, ArtworkCache.Size size)
    {
        var path = AppModel.Current.Artwork.PathFor(hash, size);
        var key = path;
        if (cache.TryGetValue(key, out var weak) && weak.TryGetTarget(out var cached)) return cached;
        if (!File.Exists(path))
        {
            if (size == ArtworkCache.Size.Large) return Artwork(hash, ArtworkCache.Size.Small);
            return null;
        }
        var bitmap = new BitmapImage { DecodePixelWidth = (int)size, UriSource = new Uri(path) };
        cache[key] = new WeakReference<BitmapImage>(bitmap);
        if (cache.Count > 2000)
        {
            foreach (var stale in cache.Where(pair => !pair.Value.TryGetTarget(out _)).Select(pair => pair.Key).ToList()) cache.Remove(stale);
        }
        return bitmap;
    }

    /// <summary>An image from PNG or JPEG bytes.</summary>
    public static async Task<BitmapImage> FromBytesAsync(byte[] data)
    {
        var bitmap = new BitmapImage();
        using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
        using (var writer = new Windows.Storage.Streams.DataWriter(stream.GetOutputStreamAt(0)))
        {
            writer.WriteBytes(data);
            await writer.StoreAsync();
            await writer.FlushAsync();
            writer.DetachStream();
        }
        stream.Seek(0);
        await bitmap.SetSourceAsync(stream);
        return bitmap;
    }

    public static Color Brand(bool dark) => dark ? Color.FromArgb(255, 0x6F, 0x98, 0xE8) : Color.FromArgb(255, 0x2A, 0x4C, 0xA0);

    public static readonly SolidColorBrush Pink = new(Color.FromArgb(255, 0xFF, 0x2D, 0x55));
    public static readonly SolidColorBrush Transparent = new(Colors.Transparent);
}
