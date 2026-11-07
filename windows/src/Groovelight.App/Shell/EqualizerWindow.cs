using System.ComponentModel;
using System.Globalization;
using Groovelight.Audio;
using Groovelight.Controls;
using Groovelight.Model;
using Groovelight.Support;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using SkiaSharp;
using SkiaSharp.Views.Windows;

namespace Groovelight.Shell;

/// <summary>
/// The 15-band parametric equalizer in its own window (the Mac's Equalizer window): a draggable response curve over the
/// live spectrum, vertical sliders per band, the selected band's exact values, presets and AutoEq files.
/// </summary>
public sealed class EqualizerWindow : Window
{
    private static EqualizerWindow? shown;
    private static AppModel Model => AppModel.Current;
    private static EqualizerStore Store => Model.Equalizer;
    private int selectedBand = 7;
    private readonly ToggleSwitch enabled = new() { OnContent = "Equalizer", OffContent = "Equalizer" };
    private readonly ComboBox presets = new() { Width = 220 };
    private readonly SKXamlCanvas curve = new() { Height = 260 };
    private readonly Grid strip = new();
    private readonly StackPanel inspector = new() { Spacing = 6 };
    private readonly ToggleSwitch autoPreamp = new() { OnContent = "Auto preamp", OffContent = "Auto preamp" };
    private readonly Slider preamp = new() { Minimum = -24, Maximum = 12, StepFrequency = 0.1, Width = 160 };
    private readonly TextBlock preampValue = new() { Width = 64, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
    private readonly InfoBar bitPerfectNote = new() { Message = "Paused while Bit-perfect playback is on (Controls, Bit-Perfect Playback).", Severity = InfoBarSeverity.Informational, IsClosable = false };
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer timer;
    private bool updating;
    private int? dragging;

    private static readonly (double Min, double Max) DbRange = (-24, 24);

    public static void Show()
    {
        shown ??= new EqualizerWindow();
        shown.Activate();
    }

    private EqualizerWindow()
    {
        Title = "Equalizer";
        SystemBackdrop = new Microsoft.UI.Xaml.Media.MicaBackdrop();
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Groovelight.ico"));
        var scale = MainWindow.Current.RootXamlRoot?.RasterizationScale ?? 1;
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(900 * scale), (int)(700 * scale)));

        enabled.Toggled += (_, _) => { if (!updating) Store.IsEnabled = enabled.IsOn; };
        presets.SelectionChanged += (_, _) =>
        {
            if (updating || presets.SelectedItem is not ComboBoxItem { Tag: EQPreset preset }) return;
            Store.Select(preset);
        };
        var more = new Button { Content = new FontIcon { Glyph = Glyphs.More, FontSize = 14 } };
        more.Click += (_, _) => Menus.Flyout(MoreItems()).ShowAt(more, new FlyoutShowOptions { Placement = FlyoutPlacementMode.BottomEdgeAlignedRight });
        var top = Ui.Grid("auto,*,auto,auto");
        top.ColumnSpacing = 12;
        top.Children.Add(enabled);
        top.Children.Add(presets.At(2));
        top.Children.Add(more.At(3));

        curve.PaintSurface += (_, args) => Draw(args.Surface.Canvas, args.Info.Width, args.Info.Height, (float)(curve.XamlRoot?.RasterizationScale ?? 1));
        var curveHost = new Border { CornerRadius = new CornerRadius(14), Child = curve };
        curve.PointerPressed += OnCurvePressed;
        curve.PointerMoved += OnCurveMoved;
        curve.PointerReleased += (_, args) => { dragging = null; curve.ReleasePointerCapture(args.Pointer); };
        curve.DoubleTapped += OnCurveDoubleTapped;
        // Scroll over the curve to widen or narrow the selected band (changes Q), like pro EQ plug-ins.
        curve.PointerWheelChanged += (_, args) =>
        {
            var delta = args.GetCurrentPoint(curve).Properties.MouseWheelDelta / 120.0;
            Store.UpdateBand(selectedBand, band => band with { Q = Math.Clamp(band.Q * (1 + delta * 0.1), EQMath.QRange.Min, EQMath.QRange.Max) });
            args.Handled = true;
        };

        autoPreamp.Toggled += (_, _) => { if (!updating) Store.AutoPreamp = autoPreamp.IsOn; };
        ToolTipService.SetToolTip(autoPreamp, "Lowers the preamp by the largest boost so the EQ never clips.");
        preamp.ValueChanged += (_, args) => { if (!updating) Store.SetPreamp(Math.Round(args.NewValue, 1)); };
        var preampBlock = Ui.Column(6, autoPreamp, Ui.Row(8, new TextBlock { Text = "Preamp", VerticalAlignment = VerticalAlignment.Center }, preamp, preampValue));
        var bottom = Ui.Grid("auto,auto,*");
        bottom.ColumnSpacing = 24;
        bottom.Children.Add(inspector);
        bottom.Children.Add(new Border { Width = 1, Height = 60, Background = Ui.Brush("DividerStrokeColorDefaultBrush") }.At(1));
        bottom.Children.Add(preampBlock.At(2));

        var panel = Ui.Column(14, bitPerfectNote, top, curveHost, strip, bottom);
        panel.Padding = new Thickness(20);
        Content = new ScrollViewer { Content = panel };
        timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(33);
        timer.Tick += (_, _) => { if (Model.Player.State == PlaybackState.Playing) curve.Invalidate(); };
        timer.Start();
        Store.PropertyChanged += OnStoreChanged;
        Model.Player.PropertyChanged += OnPlayerChanged;
        Closed += (_, _) =>
        {
            timer.Stop();
            Store.PropertyChanged -= OnStoreChanged;
            Model.Player.PropertyChanged -= OnPlayerChanged;
            shown = null;
        };
        (Content as FrameworkElement)!.RequestedTheme = Views.AppTheme.Current;
        Update(rebuildStrip: true);
        if (Environment.GetCommandLineArgs().Contains("--debug-equalizer")) Support.DebugSnapshot.Target = this;
    }

    private void OnStoreChanged(object? sender, PropertyChangedEventArgs args) => Update(rebuildStrip: args.PropertyName != nameof(EqualizerStore.Preset) || dragging is null);

    private void OnPlayerChanged(object? sender, PropertyChangedEventArgs args)
    {
        if (args.PropertyName == nameof(PlaybackController.BitPerfect)) Update(rebuildStrip: false);
    }

    private IEnumerable<MenuFlyoutItemBase> MoreItems()
    {
        yield return Menus.Item("Save Preset…", async () =>
        {
            var name = new TextBox { Text = Store.Preset.Name == "Custom" ? "" : Store.Preset.Name, PlaceholderText = "Name" };
            var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = "Save Preset", Content = name, PrimaryButtonText = "Save", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
            if (await ContentDialogs.ShowAsync(dialog) == ContentDialogResult.Primary && name.Text.Trim() is { Length: > 0 } chosen) Store.SaveCurrent(chosen);
        });
        if (Store.UserPresets.Any(preset => preset.Name == Store.Preset.Name))
            yield return Menus.Item("Delete Preset", () => Store.DeleteUserPreset(Store.Preset), Glyphs.Delete);
        yield return new MenuFlyoutSeparator();
        yield return Menus.Item("Import AutoEq / Equalizer APO…", async () =>
        {
            if (await Pickers.FileAsync([".txt"], "Import", Windows.Storage.Pickers.PickerLocationId.Downloads) is not { } path) return;
            try { Store.ImportParametricEQ(path); }
            catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException)
            {
                Model.ErrorMessage = $"Could not read {Path.GetFileName(path)} as a ParametricEQ file.";
            }
        });
        yield return Menus.Item("Export as ParametricEQ.txt…", async () =>
        {
            if (await Pickers.SaveAsync($"{Store.Preset.Name} ParametricEQ", [("Text", [".txt"])]) is { } path) Store.ExportParametricEQ(path);
        });
        yield return new MenuFlyoutSeparator();
        yield return Menus.Item("Reset to Flat", Store.Reset);
    }

    private void Update(bool rebuildStrip)
    {
        updating = true;
        var preset = Store.Preset;
        enabled.IsOn = Store.IsEnabled;
        bitPerfectNote.IsOpen = Model.Player.BitPerfect;
        presets.Items.Clear();
        if (!Store.AllPresets.Any(item => item.Name == preset.Name)) presets.Items.Add(new ComboBoxItem { Content = preset.Name, Tag = preset });
        foreach (var item in Store.AllPresets) presets.Items.Add(new ComboBoxItem { Content = item.Name, Tag = item });
        presets.SelectedIndex = presets.Items.OfType<ComboBoxItem>().ToList().FindIndex(item => (string)item.Content == preset.Name);
        autoPreamp.IsOn = Store.AutoPreamp;
        preamp.Value = preset.Preamp;
        preampValue.Text = preset.Preamp.ToString("+0.0;-0.0;0.0", CultureInfo.CurrentCulture) + " dB";
        curve.Opacity = Store.IsEnabled ? 1 : 0.5;
        if (rebuildStrip) BuildStrip();
        BuildInspector();
        updating = false;
        curve.Invalidate();
    }

    /// <summary>Classic vertical sliders, one per band (gain), for quick graphic-EQ style tweaks.</summary>
    private void BuildStrip()
    {
        strip.Children.Clear();
        strip.ColumnDefinitions.Clear();
        var bands = Store.Preset.Bands;
        for (var index = 0; index < bands.Count; index++)
        {
            strip.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var band = bands[index];
            var position = index;
            var value = Ui.Text(band.Gain.ToString("+0.0;-0.0;0.0", CultureInfo.CurrentCulture), "CaptionText", 9).With(t => t.HorizontalAlignment = HorizontalAlignment.Center);
            var slider = new Slider
            {
                Orientation = Orientation.Vertical, Height = 90, Minimum = EQMath.GainRange.Min, Maximum = EQMath.GainRange.Max, StepFrequency = 0.5,
                Value = band.Gain, IsEnabled = band.Type.UsesGain(), HorizontalAlignment = HorizontalAlignment.Center, IsThumbToolTipEnabled = false,
            };
            slider.ValueChanged += (_, args) =>
            {
                if (updating) return;
                selectedBand = position;
                Store.UpdateBand(position, item => item with { Gain = Math.Round(args.NewValue * 2) / 2 });
            };
            var label = new TextBlock
            {
                Text = Label(band.Frequency), FontSize = 10, HorizontalAlignment = HorizontalAlignment.Center,
                FontWeight = index == selectedBand ? FontWeights.Bold : FontWeights.Normal,
            };
            if (index == selectedBand) label.Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Orange);
            else label.Style = Ui.Style("CaptionText");
            var column = Ui.Column(4, value, slider, label);
            column.Background = Images.Transparent;
            column.Tapped += (_, _) => { selectedBand = position; Update(rebuildStrip: true); };
            strip.Children.Add(column.At(index));
        }
    }

    public static string Label(double frequency) =>
        frequency >= 1000 ? (frequency / 1000).ToString(frequency >= 10_000 ? "0" : "0.0", CultureInfo.InvariantCulture) + "k" : frequency.ToString("0", CultureInfo.InvariantCulture);

    /// <summary>Exact values for the selected band: on, type, frequency, gain, Q.</summary>
    private void BuildInspector()
    {
        inspector.Children.Clear();
        var bands = Store.Preset.Bands;
        if (selectedBand < 0 || selectedBand >= bands.Count) return;
        var band = bands[selectedBand];
        var index = selectedBand;
        var on = new CheckBox { Content = "On", IsChecked = band.IsEnabled, MinWidth = 0 };
        on.Click += (_, _) => Store.UpdateBand(index, item => item with { IsEnabled = on.IsChecked == true });
        var type = new ComboBox { Width = 130 };
        foreach (var kind in Enum.GetValues<EQFilterType>()) type.Items.Add(kind.DisplayName());
        type.SelectedIndex = (int)band.Type;
        type.SelectionChanged += (_, _) => { if (!updating) Store.UpdateBand(index, item => item with { Type = (EQFilterType)type.SelectedIndex }); };
        NumberBox Number(double value, double min, double max, Func<EQBand, double, EQBand> change, bool enabled = true)
        {
            var box = new NumberBox { Value = value, Minimum = min, Maximum = max, Width = 90, IsEnabled = enabled, SmallChange = 0.1 };
            box.ValueChanged += (_, args) => { if (!updating && !double.IsNaN(args.NewValue)) Store.UpdateBand(index, item => change(item, args.NewValue)); };
            return box;
        }
        inspector.Children.Add(Ui.Row(10, Ui.Text($"Band {index + 1}", "StrongText").With(t => t.VerticalAlignment = VerticalAlignment.Center), on, type));
        inspector.Children.Add(Ui.Row(8, Ui.Text("Freq", "BodyText").With(t => { t.Width = 40; t.VerticalAlignment = VerticalAlignment.Center; }),
            Number(Math.Round(band.Frequency, 1), EQMath.FrequencyRange.Min, EQMath.FrequencyRange.Max, (item, value) => item with { Frequency = value }), Ui.Text("Hz", "SecondaryText").With(t => t.VerticalAlignment = VerticalAlignment.Center)));
        inspector.Children.Add(Ui.Row(8, Ui.Text("Gain", "BodyText").With(t => { t.Width = 40; t.VerticalAlignment = VerticalAlignment.Center; }),
            Number(Math.Round(band.Gain, 1), EQMath.GainRange.Min, EQMath.GainRange.Max, (item, value) => item with { Gain = value }, band.Type.UsesGain()), Ui.Text("dB", "SecondaryText").With(t => t.VerticalAlignment = VerticalAlignment.Center)));
        inspector.Children.Add(Ui.Row(8, Ui.Text("Q", "BodyText").With(t => { t.Width = 40; t.VerticalAlignment = VerticalAlignment.Center; }),
            Number(Math.Round(band.Q, 2), EQMath.QRange.Min, EQMath.QRange.Max, (item, value) => item with { Q = value }),
            Ui.Text($"{EQMath.Bandwidth(band.Q):0.00} oct", "SecondaryText").With(t => t.VerticalAlignment = VerticalAlignment.Center)));
    }

    // MARK: The curve

    private static double X(double frequency, double width)
    {
        double lo = Math.Log10(EQMath.FrequencyRange.Min), hi = Math.Log10(EQMath.FrequencyRange.Max);
        return (Math.Log10(frequency) - lo) / (hi - lo) * width;
    }

    private static double Y(double db, double height) => (1 - (db - DbRange.Min) / (DbRange.Max - DbRange.Min)) * height;

    private static (double Frequency, double Db) ValueAt(Windows.Foundation.Point point, double width, double height)
    {
        double lo = Math.Log10(EQMath.FrequencyRange.Min), hi = Math.Log10(EQMath.FrequencyRange.Max);
        var fraction = Math.Clamp(point.X / width, 0, 1);
        var db = DbRange.Max - Math.Clamp(point.Y / height, 0, 1) * (DbRange.Max - DbRange.Min);
        return (Math.Pow(10, lo + fraction * (hi - lo)), db);
    }

    private (double X, double Y) Handle(EQBand band) =>
        (X(band.Frequency, curve.ActualWidth), Y(Math.Clamp(band.Type.UsesGain() ? band.Gain : 0, DbRange.Min, DbRange.Max), curve.ActualHeight));

    private void OnCurvePressed(object sender, PointerRoutedEventArgs args)
    {
        var point = args.GetCurrentPoint(curve).Position;
        var bands = Store.Preset.Bands;
        var nearest = Enumerable.Range(0, bands.Count).OrderBy(index =>
        {
            var (x, y) = Handle(bands[index]);
            return Math.Pow(x - point.X, 2) + Math.Pow(y - point.Y, 2);
        }).First();
        var (hx, hy) = Handle(bands[nearest]);
        if (Math.Pow(hx - point.X, 2) + Math.Pow(hy - point.Y, 2) > 16 * 16) return;
        selectedBand = nearest;
        dragging = nearest;
        curve.CapturePointer(args.Pointer);
        Update(rebuildStrip: true);
    }

    private void OnCurveMoved(object sender, PointerRoutedEventArgs args)
    {
        if (dragging is not { } index) return;
        var (frequency, gain) = ValueAt(args.GetCurrentPoint(curve).Position, curve.ActualWidth, curve.ActualHeight);
        Store.UpdateBand(index, band => band with
        {
            Frequency = Math.Round(frequency * 10) / 10,
            Gain = band.Type.UsesGain() ? Math.Round(gain * 10) / 10 : band.Gain,
            IsEnabled = true,
        });
    }

    private void OnCurveDoubleTapped(object sender, DoubleTappedRoutedEventArgs args)
    {
        Store.UpdateBand(selectedBand, band => band with { Gain = 0 });
    }

    /// <summary>Log-frequency graph: the live spectrum behind, the combined response curve, one numbered handle per band.</summary>
    private void Draw(SKCanvas canvas, int width, int height, float scale)
    {
        canvas.Clear(new SKColor(0, 0, 0, 217));
        canvas.Save();
        canvas.Scale(scale);
        var w = width / scale;
        var h = height / scale;
        using var grid = new SKPaint { Color = SKColors.White.WithAlpha(20), StrokeWidth = 1, IsAntialias = true };
        using var labelPaint = new SKPaint { Color = SKColors.White.WithAlpha(102), IsAntialias = true };
        using var font = new SKFont(SKTypeface.FromFamilyName("Segoe UI"), 9);
        foreach (var frequency in new[] { 31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 })
        {
            var x = (float)X(frequency, w);
            canvas.DrawLine(x, 0, x, h, grid);
            canvas.DrawText(frequency >= 1000 ? $"{(int)(frequency / 1000)}k" : $"{(int)frequency}", x + 2, h - 4, SKTextAlign.Left, font, labelPaint);
        }
        for (var db = -18.0; db <= 18; db += 6)
        {
            var y = (float)Y(db, h);
            using var line = new SKPaint { Color = SKColors.White.WithAlpha(db == 0 ? (byte)64 : (byte)20), StrokeWidth = 1 };
            canvas.DrawLine(0, y, w, y, line);
            canvas.DrawText(db.ToString("+0;-0;0", CultureInfo.InvariantCulture), 4, y - 3, SKTextAlign.Left, font, labelPaint);
        }
        // The live spectrum.
        var frame = Model.Player.Analyzer.LatestFrame;
        if (frame.Bands.Length > 0 && Model.Player.State == PlaybackState.Playing)
        {
            using var builder = new SKPathBuilder();
            double lo = Math.Log10(30), hi = Math.Log10(16000);
            builder.MoveTo((float)X(30, w), h);
            for (var index = 0; index < frame.Bands.Length; index++)
            {
                var frequency = Math.Pow(10, lo + (hi - lo) * (index + 0.5) / frame.Bands.Length);
                builder.LineTo((float)X(frequency, w), (float)(h * (1 - frame.Bands[index] * 0.9)));
            }
            builder.LineTo((float)X(16000, w), h);
            builder.Close();
            using var spectrum = builder.Detach();
            using var fill = new SKPaint { IsAntialias = true };
            fill.Shader = SKShader.CreateLinearGradient(new SKPoint(0, 0), new SKPoint(0, h),
                [SKColors.Cyan.WithAlpha(89), SKColors.Blue.WithAlpha(13)], SKShaderTileMode.Clamp);
            canvas.DrawPath(spectrum, fill);
        }
        // The bands' response (the preamp is shown separately so the handles sit on the curve).
        var preset = Store.Preset with { Preamp = 0 };
        var frequencies = EQMath.LogSpacedFrequencies((int)(w / 2));
        using (var builder = new SKPathBuilder())
        {
            for (var index = 0; index < frequencies.Length; index++)
            {
                var x = (float)X(frequencies[index], w);
                var y = (float)Y(Math.Clamp(EQMath.Response(preset, frequencies[index]), DbRange.Min, DbRange.Max), h);
                if (index == 0) builder.MoveTo(x, y); else builder.LineTo(x, y);
            }
            using var line = builder.Snapshot();
            builder.LineTo(w, (float)Y(0, h));
            builder.LineTo(0, (float)Y(0, h));
            builder.Close();
            using var area = builder.Detach();
            using var fill = new SKPaint { Color = SKColors.Orange.WithAlpha(31), IsAntialias = true };
            canvas.DrawPath(area, fill);
            using var stroke = new SKPaint { Color = SKColors.Orange, StrokeWidth = 2.5f, Style = SKPaintStyle.Stroke, IsAntialias = true, StrokeJoin = SKStrokeJoin.Round };
            canvas.DrawPath(line, stroke);
        }
        // The handles.
        using var number = new SKFont(SKTypeface.FromFamilyName("Segoe UI", SKFontStyle.Bold), 9);
        for (var index = 0; index < Store.Preset.Bands.Count; index++)
        {
            var band = Store.Preset.Bands[index];
            var x = (float)X(band.Frequency, w);
            var y = (float)Y(Math.Clamp(band.Type.UsesGain() ? band.Gain : 0, DbRange.Min, DbRange.Max), h);
            var selected = index == selectedBand;
            using var circle = new SKPaint { IsAntialias = true, Color = selected ? SKColors.Orange : SKColors.White.WithAlpha(band.IsEnabled ? (byte)77 : (byte)26) };
            canvas.DrawCircle(x, y, 10, circle);
            using var ring = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = 1.5f, Color = SKColors.Orange.WithAlpha(band.IsEnabled ? (byte)255 : (byte)77) };
            canvas.DrawCircle(x, y, 10, ring);
            using var text = new SKPaint { IsAntialias = true, Color = selected ? SKColors.Black : SKColors.White };
            canvas.DrawText($"{index + 1}", x, y + 3.2f, SKTextAlign.Center, number, text);
        }
        canvas.Restore();
    }
}
