using Groovelight.Core.Library;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace Groovelight.Controls;

/// <summary>Small capsule showing the quality tier, like Apple Music's Lossless mark (none for standard lossy files).</summary>
public sealed partial class QualityBadge : UserControl
{
    private readonly TextBlock label = new() { FontWeight = FontWeights.Bold, CharacterSpacing = 40, VerticalAlignment = VerticalAlignment.Center };
    private readonly FontIcon icon = new() { Glyph = "" };

    public QualityBadge(QualityTier tier, bool isMini = false)
    {
        var tint = Tint(tier);
        var border = new Border();
        Content = border;
        border.CornerRadius = new CornerRadius(8);
        border.BorderThickness = new Thickness(0.8);
        VerticalAlignment = VerticalAlignment.Center;
        border.Padding = isMini ? new Thickness(4, 1, 4, 1) : new Thickness(6, 2, 6, 2);
        label.FontSize = isMini ? 8 : 9;
        icon.FontSize = isMini ? 7 : 8;
        label.Text = BadgeText(tier).ToUpperInvariant();
        label.Foreground = icon.Foreground = new SolidColorBrush(tint);
        border.Background = new SolidColorBrush(Color.FromArgb((byte)(255 * 0.14), tint.R, tint.G, tint.B));
        border.BorderBrush = new SolidColorBrush(Color.FromArgb((byte)(255 * 0.55), tint.R, tint.G, tint.B));
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 3 };
        if (tier is QualityTier.HiResLossless or QualityTier.Lossless or QualityTier.Dsd) row.Children.Add(icon);
        row.Children.Add(label);
        border.Child = row;
        Visibility = HasBadge(tier) ? Visibility.Visible : Visibility.Collapsed;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(this, tier.DisplayName());
    }

    public static bool HasBadge(QualityTier tier) => tier != QualityTier.Standard;

    /// <summary>Gold for Hi-Res, teal for Lossless, purple for DSD, neutral for high quality lossy.</summary>
    public static Color Tint(QualityTier tier) => tier switch
    {
        QualityTier.HiResLossless => Color.FromArgb(255, 224, 179, 77),
        QualityTier.Lossless => Color.FromArgb(255, 89, 191, 204),
        QualityTier.Dsd => Color.FromArgb(255, 179, 128, 242),
        _ => Color.FromArgb(255, 140, 140, 145),
    };

    public static string BadgeText(QualityTier tier) => tier switch
    {
        QualityTier.HiResLossless => "Hi-Res",
        QualityTier.Lossless => "Lossless",
        QualityTier.Dsd => "DSD",
        QualityTier.HighQuality => "HQ",
        _ => "",
    };
}
