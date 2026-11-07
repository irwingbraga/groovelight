using System.Diagnostics;
using Groovelight.Controls;
using Groovelight.Model;
using Groovelight.Skins;
using Groovelight.Support;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using SkiaSharp;
using SkiaSharp.Views.Windows;

namespace Groovelight.SkinViews;

/// <summary>A cassette with a sample song on its label, still or with the reels turning.</summary>
public sealed partial class CassettePreview : UserControl
{
    private static readonly Stopwatch Clock = Stopwatch.StartNew();
    private readonly SKXamlCanvas canvas = new();
    private CassetteDesign design;
    private CassettePictures pictures;
    private readonly bool playing;

    public CassettePreview(CassetteDesign design, CassettePictures pictures, bool playing)
    {
        this.design = design;
        this.pictures = pictures;
        this.playing = playing;
        Content = canvas;
        canvas.PaintSurface += OnPaint;
        if (playing)
        {
            Loaded += (_, _) => CompositionTarget.Rendering += OnRendering;
            Unloaded += (_, _) => CompositionTarget.Rendering -= OnRendering;
        }
    }

    public void Show(CassetteDesign design, CassettePictures pictures)
    {
        this.design = design;
        this.pictures = pictures;
        canvas.Invalidate();
    }

    private void OnRendering(object? sender, object args) => canvas.Invalidate();

    private void OnPaint(object? sender, SKPaintSurfaceEventArgs args)
    {
        var surface = args.Surface.Canvas;
        surface.Clear(SKColors.Transparent);
        var width = (float)args.Info.Width;
        var height = (float)args.Info.Height;
        var aspect = (float)design.ResolvedGeometry.AspectRatio;
        var w = Math.Min(width, height * aspect) * 0.94f;
        var rect = SKRect.Create((width - w) / 2, (height - w / aspect) / 2, w, w / aspect);
        var start = Clock.Elapsed.TotalSeconds;
        var playback = new SkinPlayback { Title = "Side A", Artist = "Groovelight", IsPlaying = playing, Duration = 60, Time = () => start % 60 };
        using (var shadow = SKImageFilter.CreateDropShadow(0, 3 * w / 300, 3 * w / 300, 3 * w / 300, new SKColor(0, 0, 0, 77)))
        using (var paint = new SKPaint { ImageFilter = shadow })
        {
            surface.SaveLayer(paint);
            CassetteFace.Draw(surface, rect, design, pictures, playback);
            surface.Restore();
        }
    }
}

/// <summary>
/// The cassettes to choose from, with a preview of each (the Mac's CassetteLibrary): the built-in ones and the user's,
/// which can be made (from a copy), edited, imported, shared and deleted.
/// </summary>
public sealed class CassettesWindow : Window
{
    private static CassettesWindow? shown;
    private static AppModel Model => AppModel.Current;
    private static CassetteStore Store => SkinStore.Cassettes;
    private readonly StackPanel list = new() { Spacing = 2 };
    private readonly Grid root = new();

    public static void Show()
    {
        shown ??= new CassettesWindow();
        shown.Activate();
    }

    private CassettesWindow()
    {
        Title = "Cassettes";
        SystemBackdrop = new MicaBackdrop();
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Groovelight.ico"));
        var scale = MainWindow.Current.RootXamlRoot?.RasterizationScale ?? 1;
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(480 * scale), (int)(680 * scale)));
        root.RequestedTheme = Views.AppTheme.Current;
        root.Children.Add(new ScrollViewer { Content = new Border { Padding = new Thickness(20, 16, 20, 20), Child = list } });
        Content = root;
        Store.Changed += OnChanged;
        Model.Preferences.Changed += OnPreferenceChanged;
        Closed += (_, _) =>
        {
            Store.Changed -= OnChanged;
            Model.Preferences.Changed -= OnPreferenceChanged;
            shown = null;
        };
        Build();
        if (Environment.GetCommandLineArgs().Contains("--debug-cassettes")) DebugSnapshot.Target = this;
    }

    private void OnChanged() => DispatcherQueue.TryEnqueue(Build);

    private void OnPreferenceChanged(string key)
    {
        if (key == SkinInfo.CassetteStorageKey) DispatcherQueue.TryEnqueue(Build);
    }

    private Guid Chosen => Store.Design(Model.Preferences.String(SkinInfo.CassetteStorageKey)).Id;

    private static void Choose(CassetteDesign design)
    {
        Model.Preferences.Set(SkinInfo.CassetteStorageKey, design.Id.ToString().ToUpperInvariant());
        Model.Preferences.Set(SkinInfo.StorageKey, NowPlayingSkin.Cassette.RawValue());
    }

    private void Build()
    {
        list.Children.Clear();
        list.Children.Add(Ui.Text("Built In", "StrongText", 14).Margin(4, 0, 0, 6));
        foreach (var design in CassetteDesign.BuiltIn) list.Children.Add(Row(design));
        list.Children.Add(Ui.Text("Yours", "StrongText", 14).Margin(4, 18, 0, 6));
        foreach (var design in Store.Custom) list.Children.Add(Row(design));
        var actions = Ui.Row(8,
            Ui.Button("New Cassette", () => _ = MakeAsync(Store.Design(Chosen)), Glyphs.Add),
            Ui.Button("Import…", () => _ = ImportAsync(), Glyphs.Import),
            Ui.Button("Save Template…", () => _ = SaveTemplateAsync()));
        actions.Margin = new Thickness(0, 8, 0, 6);
        list.Children.Add(actions);
        list.Children.Add(Ui.Text("Make your own from a copy of any cassette: its colors, its label and its text, or your own pictures of the shell and the label, drawn on the template. "
            + "Share one as a .cassette file; it opens on the Mac, iPhone, iPad and Android.", "WrappingSecondaryText"));
    }

    private FrameworkElement Row(CassetteDesign design)
    {
        var grid = Ui.Grid("auto,*,auto");
        grid.ColumnSpacing = 12;
        grid.Children.Add(new CassettePreview(design, Store.Pictures(design), false) { Width = 76, Height = 48 });
        var text = Ui.Column(2, Ui.Text(design.Name));
        if (!string.IsNullOrEmpty(design.Author)) text.Children.Add(Ui.Text(design.Author, "CaptionText"));
        text.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(text.At(1));
        if (design.Id == Chosen)
        {
            var check = Ui.Icon(Glyphs.Check, 14, "BrandIcon");
            check.VerticalAlignment = VerticalAlignment.Center;
            AutomationProperties(check, "Chosen");
            grid.Children.Add(check.At(2));
        }
        var button = new Button
        {
            Content = grid, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = Images.Transparent, BorderThickness = new Thickness(0), Padding = new Thickness(6),
        };
        button.Click += (_, _) => Choose(design);
        var items = new List<MenuFlyoutItemBase>();
        if (!design.IsBuiltIn) items.Add(Menus.Item("Edit…", () => _ = EditAsync(design), Glyphs.Edit));
        items.Add(Menus.Item("Duplicate", () => _ = MakeAsync(design)));
        if (!design.IsBuiltIn)
        {
            items.Add(Menus.Item("Share…", () => _ = ShareAsync(design), Glyphs.Export));
            items.Add(Menus.Item("Delete", () => _ = DeleteAsync(design), Glyphs.Delete));
        }
        button.ContextFlyout = Menus.Flyout(items);
        return button;
    }

    private static void AutomationProperties(DependencyObject element, string name) => Ui.AutomationProperties(element, name);

    private async Task Problem(string message) => await Ui.Alert(root.XamlRoot, "Cassette", message);

    private async Task MakeAsync(CassetteDesign design)
    {
        try
        {
            var copy = Store.Duplicate(design, design.IsBuiltIn ? $"My {design.Name}" : null);
            await EditAsync(copy);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            await Problem(error.Message);
        }
    }

    private async Task EditAsync(CassetteDesign design)
    {
        var saved = await new CassetteEditor(design).ShowAsync(root.XamlRoot);
        if (saved is not null) Choose(saved);
    }

    private async Task ImportAsync()
    {
        var path = await Pickers.FileAsync([".cassette", ".zip", ".json"], "Import", Windows.Storage.Pickers.PickerLocationId.Downloads);
        if (path is null) return;
        try { Choose(Store.Import(path)); }
        catch (Exception error) when (error is IOException or FormatException or UnauthorizedAccessException or InvalidDataException)
        {
            await Problem(error.Message);
        }
    }

    private async Task ShareAsync(CassetteDesign design)
    {
        var path = await Pickers.SaveAsync(CassetteStore.SafeName(design.Name), [("Groovelight Cassette", [".cassette"])]);
        if (path is null) return;
        try { Store.Export(design, path); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            await Problem(error.Message);
        }
    }

    private async Task SaveTemplateAsync()
    {
        var path = await Pickers.SaveAsync("Cassette Template", [("PNG image", [".png"])], Windows.Storage.Pickers.PickerLocationId.PicturesLibrary);
        if (path is null) return;
        try { await File.WriteAllBytesAsync(path, CassetteTemplate.Png()); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            await Problem(error.Message);
        }
    }

    private async Task DeleteAsync(CassetteDesign design)
    {
        if (!await Ui.Confirm(root.XamlRoot, $"Delete “{design.Name}”?", "Its pictures are deleted with it.", "Delete", destructive: true)) return;
        var wasChosen = design.Id == Chosen;
        try
        {
            Store.Delete(design);
            if (wasChosen) Model.Preferences.Set(SkinInfo.CassetteStorageKey, CassetteDesign.BuiltIn[0].Id.ToString().ToUpperInvariant());
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            await Problem(error.Message);
        }
    }
}

/// <summary>
/// Edits a design of the user's (the Mac's CassetteEditor): the preview at the top, then the shell, the label, the
/// printing, the reels and the pictures. Pictures are kept at once; the rest when saved.
/// </summary>
public sealed class CassetteEditor
{
    private static CassetteStore Store => SkinStore.Cassettes;
    private CassetteDesign design;
    private readonly CassettePreview preview;
    private readonly StackPanel form = new() { Spacing = 6 };
    private XamlRoot? xamlRoot;

    public CassetteEditor(CassetteDesign design)
    {
        this.design = design.Copy();
        preview = new CassettePreview(this.design, Store.Pictures(this.design), true) { Height = 220, MaxWidth = 420 };
    }

    /// <summary>The design saved, or null when cancelled.</summary>
    public async Task<CassetteDesign?> ShowAsync(XamlRoot root)
    {
        xamlRoot = root;
        Build();
        var dialog = new ContentDialog
        {
            Title = "Cassette", PrimaryButtonText = "Save", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary, XamlRoot = root,
            Content = new ScrollViewer { Content = form, MaxHeight = 640, Padding = new Thickness(0, 0, 16, 0) },
        };
        dialog.Resources["ContentDialogMaxWidth"] = 560.0;
        while (true)
        {
            if (await ContentDialogs.ShowAsync(dialog) != ContentDialogResult.Primary) return null;
            try
            {
                Store.Save(design);
                return design;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException)
            {
                await Ui.Alert(root, "Cassette", error.Message);
            }
        }
    }

    private void Changed() => preview.Show(design, Store.Pictures(design));

    private void Build()
    {
        form.Children.Clear();
        form.Children.Add(preview);
        Section("Name");
        Field("Name", Text(design.Name, value => design.Name = value));
        Field("Made By", Text(design.Author ?? "", value => design.Author = value.Length == 0 ? null : value));
        Section("Shell");
        Field("Plastic", ColorButton(() => design.ShellColor, value => design.ShellColor = value));
        var clear = new Slider { Minimum = 0, Maximum = 0.8, StepFrequency = 0.01, Value = design.ShellClarity, Width = 200 };
        clear.ValueChanged += (_, args) =>
        {
            design.ShellClarity = args.NewValue;
            Changed();
        };
        Field("Clear", clear);
        Field("Screws and Edges", ColorButton(() => design.DetailColor, value => design.DetailColor = value));
        Section("Label");
        Field("Paper", FinishChoice(design.Label.BackgroundFinish, "Color", value =>
        {
            design.Label.BackgroundFinish = value;
            Rebuild();
        }));
        if (design.Label.BackgroundFinish is null) Field("Paper Color", ColorButton(() => design.Label.Background, value => design.Label.Background = value));
        Field("Writing", ColorButton(() => design.Label.TextColor, value => design.Label.TextColor = value));
        for (var index = 0; index < design.Label.Stripes.Count; index++)
        {
            var band = index;
            var remove = Ui.IconButton(Glyphs.Delete, "Remove Band", () =>
            {
                design.Label.Stripes.RemoveAt(band);
                Rebuild();
            }, 12);
            Field($"Band {band + 1}", Ui.Row(8, ColorButton(() => design.Label.Stripes[band], value => design.Label.Stripes[band] = value), remove));
        }
        if (design.Label.Stripes.Count < 5)
        {
            form.Children.Add(Ui.Button("Add Band", () =>
            {
                design.Label.Stripes.Add(design.Label.Stripes.Count > 0 ? design.Label.Stripes[^1] : design.Label.TextColor);
                Rebuild();
            }, Glyphs.Add));
        }
        Field("Song Written on It", Toggle(design.Label.ShowsText, value =>
        {
            design.Label.ShowsText = value;
            Rebuild();
        }));
        var handwriting = Toggle(design.Label.Handwritten, value => design.Label.Handwritten = value);
        handwriting.IsEnabled = design.Label.ShowsText;
        Field("Handwriting", handwriting);
        Field("Cover on It", Toggle(design.Label.ShowsArtwork, value => design.Label.ShowsArtwork = value));
        Section("Printed");
        Field("Brand", Text(design.Brand, value => design.Brand = value));
        Field("Tape Type", Text(design.TapeType, value => design.TapeType = value));
        Field("Side", Text(design.Side, value => design.Side = value));
        Field("Print", FinishChoice(design.Label.TextFinish, "Writing's Color", value => design.Label.TextFinish = value));
        Section("Reels");
        Field("Hubs", ColorButton(() => design.Reels.HubColor, value => design.Reels.HubColor = value));
        Field("Tape", ColorButton(() => design.Reels.TapeColor, value => design.Reels.TapeColor = value));
        var rings = new ComboBox { ItemsSource = new[] { "None", "Color", "Gold Foil", "Silver Foil" }, MinWidth = 160 };
        rings.SelectedIndex = design.Reels.RingColor is null ? 0 : design.Reels.RingFinish switch { Finish.Gold => 2, Finish.Silver => 3, _ => 1 };
        rings.SelectionChanged += (_, _) =>
        {
            switch (rings.SelectedIndex)
            {
                case 0:
                    design.Reels.RingColor = null;
                    design.Reels.RingFinish = null;
                    break;
                case 1:
                    design.Reels.RingColor ??= design.Label.TextColor;
                    design.Reels.RingFinish = null;
                    break;
                default:
                    // Their color for apps that draw no foil.
                    design.Reels.RingFinish = rings.SelectedIndex == 2 ? Finish.Gold : Finish.Silver;
                    design.Reels.RingColor = HexColor.Of(rings.SelectedIndex == 2 ? "#C9A04A" : "#BFC4CE");
                    break;
            }
            Rebuild();
        };
        Field("Rings Around the Hubs", rings);
        if (design.Reels.RingColor is not null && design.Reels.RingFinish is null)
            Field("Rings' Color", ColorButton(() => design.Reels.RingColor ?? HexColor.Of("#000000"), value => design.Reels.RingColor = value));
        Section("Your Pictures");
        PictureRow("Shell Picture", CassetteStore.Picture.Shell);
        PictureRow("Label Picture", CassetteStore.Picture.Label);
        form.Children.Add(Ui.Text("A shell picture is drawn over the reels: make the window and the hubs' holes transparent (a PNG). Draw it on the template "
            + "(Save Template in the list) and it fits; the song is still written on the label.", "WrappingSecondaryText"));
    }

    private void Rebuild()
    {
        Changed();
        Build();
    }

    private void Section(string title) => form.Children.Add(Ui.Text(title, "StrongText", 14).Margin(0, 14, 0, 2));

    private void Field(string title, FrameworkElement control)
    {
        var grid = Ui.Grid("*,auto");
        var label = Ui.Text(title);
        label.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(label);
        control.VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(control.At(1));
        form.Children.Add(grid);
    }

    private TextBox Text(string value, Action<string> changed)
    {
        var box = new TextBox { Text = value, Width = 240 };
        box.TextChanged += (_, _) =>
        {
            changed(box.Text);
            Changed();
        };
        return box;
    }

    private ToggleSwitch Toggle(bool value, Action<bool> changed)
    {
        var toggle = new ToggleSwitch { IsOn = value, OnContent = "", OffContent = "", MinWidth = 0 };
        toggle.Toggled += (_, _) =>
        {
            changed(toggle.IsOn);
            Changed();
        };
        return toggle;
    }

    /// <summary>Plain (<paramref name="plain"/>) or in gold or silver foil.</summary>
    private ComboBox FinishChoice(Finish? value, string plain, Action<Finish?> changed)
    {
        var box = new ComboBox { ItemsSource = new[] { plain, "Gold Foil", "Silver Foil" }, MinWidth = 160 };
        box.SelectedIndex = value switch { Finish.Gold => 1, Finish.Silver => 2, _ => 0 };
        box.SelectionChanged += (_, _) =>
        {
            changed(box.SelectedIndex switch { 1 => Finish.Gold, 2 => Finish.Silver, _ => null });
            Changed();
        };
        return box;
    }

    /// <summary>A swatch that opens a color picker.</summary>
    private Button ColorButton(Func<HexColor> get, Action<HexColor> set)
    {
        static Windows.UI.Color Of(HexColor color) => Windows.UI.Color.FromArgb(255, (byte)Math.Round(color.Red * 255), (byte)Math.Round(color.Green * 255),
            (byte)Math.Round(color.Blue * 255));
        var swatch = new Border
        {
            Width = 44, Height = 20, CornerRadius = new CornerRadius(4), Background = new SolidColorBrush(Of(get())),
            BorderBrush = Ui.Brush("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1),
        };
        var picker = new ColorPicker { Color = Of(get()), IsAlphaEnabled = false, IsMoreButtonVisible = false, IsColorPreviewVisible = false };
        picker.ColorChanged += (_, args) =>
        {
            // The design keeps its colors' opacity (a clear label stays clear).
            set(new HexColor(args.NewColor.R / 255.0, args.NewColor.G / 255.0, args.NewColor.B / 255.0, get().Alpha));
            swatch.Background = new SolidColorBrush(args.NewColor);
            Changed();
        };
        return new Button { Content = swatch, Padding = new Thickness(4), Flyout = new Flyout { Content = picker } };
    }

    private void PictureRow(string title, CassetteStore.Picture picture)
    {
        var has = Store.PathOf(picture, design) is not null;
        var buttons = Ui.Row(8);
        if (has)
        {
            buttons.Children.Add(Ui.Button("Remove", () => SetPicture(picture, null)));
        }
        buttons.Children.Add(Ui.Button(has ? "Change…" : "Choose…", async () =>
        {
            var path = await Pickers.FileAsync([".png", ".jpg", ".jpeg"], "Choose", Windows.Storage.Pickers.PickerLocationId.PicturesLibrary);
            if (path is not null) SetPicture(picture, path);
        }));
        Field(title, buttons);
    }

    private async void SetPicture(CassetteStore.Picture picture, string? path)
    {
        try
        {
            // Kept at once, with what has been changed so far.
            var saved = Store.SetPicture(picture, path, design);
            design.ShellImage = saved.ShellImage;
            design.LabelImage = saved.LabelImage;
            Rebuild();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            if (xamlRoot is not null) await Ui.Alert(xamlRoot, "Cassette", error.Message);
        }
    }
}
