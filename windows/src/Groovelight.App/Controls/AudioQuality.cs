using System.Globalization;
using Groovelight.Core.Library;
using Groovelight.Model;
using Groovelight.Support;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;

namespace Groovelight.Controls;

/// <summary>Full technical details of a song plus where it is being played (the Mac's AudioDetailsView), in a flyout.</summary>
public static class AudioQualityFlyout
{
    public static void Show(FrameworkElement anchor, Track track) =>
        new Flyout { Content = Details(track), Placement = FlyoutPlacementMode.Bottom }.ShowAt(anchor);

    /// <summary>A badge and the spec text ("FLAC · 24-bit / 96 kHz"); click for the details.</summary>
    public static FrameworkElement Button(Track track, bool showsText = true, bool isMini = false, bool compactText = false)
    {
        var spec = track.AudioSpec;
        var row = Ui.Row(6);
        if (QualityBadge.HasBadge(spec.Tier)) row.Children.Add(new QualityBadge(spec.Tier, isMini));
        if (showsText) row.Children.Add(Ui.Text(compactText ? spec.CompactText : spec.Summary, "CaptionText"));
        var button = new Button { Content = row, Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = Images.Transparent };
        ToolTipService.SetToolTip(button, spec.Tier == QualityTier.Standard ? spec.Summary : $"{spec.Tier.DisplayName()} · {spec.Summary}");
        button.Click += (_, _) => Show(button, track);
        return button;
    }

    public static FrameworkElement Details(Track track)
    {
        var model = AppModel.Current;
        var spec = track.AudioSpec;
        var player = model.Player;
        var isCurrent = player.Current?.Id == track.Id;
        var panel = Ui.Column(12);
        panel.Width = 290;
        var head = Ui.Row(8);
        if (QualityBadge.HasBadge(spec.Tier)) head.Children.Add(new QualityBadge(spec.Tier));
        head.Children.Add(Ui.Text(spec.Tier == QualityTier.Standard ? "Compressed" : spec.Tier.DisplayName(), "StrongText"));
        panel.Children.Add(head);
        var grid = Ui.Grid("auto,*");
        grid.ColumnSpacing = 14;
        grid.RowSpacing = 5;
        var format = spec.FormatName is { } name ? (name == spec.Codec.ShortName() ? name : $"{spec.Codec.ShortName()} ({name})") : spec.Codec.ShortName();
        void Row(string label, string? value)
        {
            if (string.IsNullOrEmpty(value)) return;
            var index = grid.RowDefinitions.Count;
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            grid.Children.Add(Ui.Text(label, "SecondaryText", 13).At(0, index));
            grid.Children.Add(Ui.Text(value, "BodyText", 13).At(1, index));
        }
        Row("Format", format);
        Row("Encoding", spec.Codec.IsLossless() ? "Lossless" : "Lossy");
        Row("Sample rate", spec.SampleRateText);
        Row("Bit depth", spec.Codec.IsDsd() ? "1-bit" : spec.BitDepth is { } bits ? $"{bits}-bit" : null);
        Row("Bitrate", spec.BitrateText);
        Row("Channels", spec.ChannelsText);
        Row("File size", Format.Bytes(track.FileSize));
        panel.Children.Add(grid);
        if (isCurrent && player.BitPerfect)
        {
            panel.Children.Add(Ui.Separator());
            panel.Children.Add(OutputStatus());
        }
        else if (isCurrent && player.OutputSampleRate > 0)
        {
            panel.Children.Add(Ui.Separator());
            panel.Children.Add(Ui.Column(4,
                Ui.Row(6, Ui.Icon(Glyphs.Speaker, 13), Ui.Text(player.OutputDeviceName ?? "Output", "StrongText", 13)),
                Ui.Text(OutputDescription(spec.SampleRate, player.OutputSampleRate, spec.Codec.IsDsd()), "CaptionText").With(t => { t.TextWrapping = TextWrapping.Wrap; t.TextTrimming = TextTrimming.None; })));
        }
        return panel;
    }

    private static string OutputDescription(double? fileRate, double outputRate, bool isDsd)
    {
        var output = $"{(outputRate / 1000).ToString("0.###", CultureInfo.CurrentCulture)} kHz";
        if (isDsd) return $"Converted from DSD to PCM, playing at {output}.";
        if (fileRate is not { } rate) return $"Playing at {output}.";
        if (Math.Abs(rate - outputRate) < 1) return $"Playing at the file's native rate ({output}).";
        return $"Resampled from {(rate / 1000).ToString("0.###", CultureInfo.CurrentCulture)} kHz to {output}. Turn on Bit-perfect playback (Settings, Playback) to play at the file's rate.";
    }

    /// <summary>Where the sound goes and whether it gets there untouched (the Mac's OutputStatusRow).</summary>
    public static FrameworkElement OutputStatus()
    {
        var model = AppModel.Current;
        var output = model.Player.Output;
        var head = Ui.Grid("auto,*,auto");
        head.ColumnSpacing = 6;
        var icon = Ui.Icon(output.IsBitPerfect ? "" : Glyphs.Speaker, 13);
        icon.Foreground = output.IsBitPerfect ? new SolidColorBrush(Microsoft.UI.Colors.MediumSeaGreen) : Ui.Brush("TextFillColorSecondaryBrush");
        head.Children.Add(icon);
        head.Children.Add(Ui.Text(output.DeviceName ?? "Output device", "BodyText", 13).At(1));
        head.Children.Add(Ui.Text(FormatRate(output.DeviceRate, output.DeviceBitDepth), "SecondaryText", 13).At(2));
        var panel = Ui.Column(4, head);
        if (model.Player.Current is not null)
        {
            var note = Ui.Text(output.IsBitPerfect ? "Bit-perfect: the song reaches the device untouched." : string.Join(" ", output.Notes), "BodyText", 12);
            note.TextWrapping = TextWrapping.Wrap;
            note.TextTrimming = TextTrimming.None;
            note.Foreground = new SolidColorBrush(output.IsBitPerfect ? Microsoft.UI.Colors.MediumSeaGreen : Microsoft.UI.Colors.Orange);
            panel.Children.Add(note);
        }
        return panel;
    }

    public static string FormatRate(double rate, int? bits)
    {
        if (rate <= 0) return "";
        var khz = (rate / 1000).ToString("0.#", CultureInfo.CurrentCulture);
        return bits is { } depth ? $"{khz} kHz, {depth}-bit" : $"{khz} kHz";
    }
}
