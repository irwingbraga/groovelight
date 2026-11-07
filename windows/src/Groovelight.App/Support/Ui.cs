using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Windows.UI.Text;

namespace Groovelight.Support;

/// <summary>Small builders for the views written in code.</summary>
public static class Ui
{
    public static T Resource<T>(string key) => (T)Application.Current.Resources[key];

    public static Style Style(string key) => Resource<Style>(key);

    public static TextBlock Text(string text, string style = "BodyText", double? size = null, FontWeight? weight = null)
    {
        var block = new TextBlock { Text = text, Style = Style(style) };
        if (size is { } value) block.FontSize = value;
        if (weight is { } bold) block.FontWeight = bold;
        return block;
    }

    public static FontIcon Icon(string glyph, double size = 16, string? style = null)
    {
        var icon = new FontIcon { Glyph = glyph, FontSize = size };
        if (style is not null) icon.Style = Style(style);
        return icon;
    }

    public static StackPanel Row(double spacing, params UIElement[] children)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = spacing };
        foreach (var child in children) panel.Children.Add(child);
        return panel;
    }

    public static StackPanel Column(double spacing, params UIElement[] children)
    {
        var panel = new StackPanel { Spacing = spacing };
        foreach (var child in children) panel.Children.Add(child);
        return panel;
    }

    public static Button Button(string text, Action action, string? glyph = null, string style = "PillButton", string? tooltip = null)
    {
        var button = new Button { Style = Style(style) };
        button.Content = glyph is null ? text : Row(8, Icon(glyph, 14), new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center });
        button.Click += (_, _) => action();
        if (tooltip is not null) ToolTipService.SetToolTip(button, tooltip);
        return button;
    }

    public static Button IconButton(string glyph, string tooltip, Action action, double size = 16, string style = "BarButton")
    {
        var button = new Button { Style = Style(style), Content = Icon(glyph, size) };
        ToolTipService.SetToolTip(button, tooltip);
        AutomationProperties(button, tooltip);
        button.Click += (_, _) => action();
        return button;
    }

    /// <summary>A circle button with a menu (the "⋯" of album pages).</summary>
    public static Button MenuButton(Func<MenuFlyout> menu, string tooltip = "More", string glyph = Glyphs.More, string style = "CircleButton")
    {
        var button = new Button { Style = Style(style), Content = Icon(glyph, 14) };
        ToolTipService.SetToolTip(button, tooltip);
        AutomationProperties(button, tooltip);
        button.Click += (_, _) => menu().ShowAt(button, new FlyoutShowOptions { Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft });
        return button;
    }

    public static void AutomationProperties(DependencyObject element, string name) =>
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(element, name);

    public static Border Separator() => new() { Style = Style("SeparatorBorder") };

    /// <summary>Text that acts as a link: underlined on hover. Plain text without an action.</summary>
    public static FrameworkElement Link(string text, Action? action, string style = "SecondaryText", string? tooltip = null)
    {
        var block = Text(text, style);
        if (action is null) return block;
        var button = new HyperlinkButton { Style = Style("LinkTextButton"), Content = block, Foreground = block.Foreground };
        ToolTipService.SetToolTip(button, tooltip ?? text);
        button.Click += (_, _) => action();
        return button;
    }

    /// <summary>An empty page's message: icon, title, explanation and an optional action (ContentUnavailableView).</summary>
    public static FrameworkElement Unavailable(string glyph, string title, string? message = null, (string Text, Action Action)? action = null)
    {
        var panel = Column(10, Icon(glyph, 44, "SecondaryIcon"), Text(title, "SectionTitleText"));
        panel.HorizontalAlignment = HorizontalAlignment.Center;
        panel.VerticalAlignment = VerticalAlignment.Center;
        panel.MaxWidth = 440;
        foreach (var child in panel.Children.OfType<FrameworkElement>()) child.HorizontalAlignment = HorizontalAlignment.Center;
        if (message is not null)
        {
            var text = Text(message, "WrappingSecondaryText");
            text.TextAlignment = TextAlignment.Center;
            text.HorizontalAlignment = HorizontalAlignment.Center;
            panel.Children.Add(text);
        }
        if (action is { } button)
        {
            var control = Button(button.Text, button.Action, style: "AccentPillButton");
            control.HorizontalAlignment = HorizontalAlignment.Center;
            control.Margin = new Thickness(0, 8, 0, 0);
            panel.Children.Add(control);
        }
        return panel;
    }

    public static Grid Grid(string columns = "", string rows = "")
    {
        var grid = new Grid();
        foreach (var column in Lengths(columns)) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = column });
        foreach (var row in Lengths(rows)) grid.RowDefinitions.Add(new RowDefinition { Height = row });
        return grid;
    }

    private static IEnumerable<GridLength> Lengths(string spec) => spec.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
        .Select(part => part == "auto" ? GridLength.Auto
            : part.EndsWith('*') ? new GridLength(part.Length == 1 ? 1 : double.Parse(part[..^1], System.Globalization.CultureInfo.InvariantCulture), GridUnitType.Star)
            : new GridLength(double.Parse(part, System.Globalization.CultureInfo.InvariantCulture)));

    public static T At<T>(this T element, int column, int row = 0, int columnSpan = 1, int rowSpan = 1) where T : FrameworkElement
    {
        Microsoft.UI.Xaml.Controls.Grid.SetColumn(element, column);
        Microsoft.UI.Xaml.Controls.Grid.SetRow(element, row);
        if (columnSpan > 1) Microsoft.UI.Xaml.Controls.Grid.SetColumnSpan(element, columnSpan);
        if (rowSpan > 1) Microsoft.UI.Xaml.Controls.Grid.SetRowSpan(element, rowSpan);
        return element;
    }

    public static T With<T>(this T element, Action<T> configure)
    {
        configure(element);
        return element;
    }

    public static T Tooltip<T>(this T element, string text) where T : DependencyObject
    {
        ToolTipService.SetToolTip(element, text);
        return element;
    }

    public static T Margin<T>(this T element, double left, double top, double right, double bottom) where T : FrameworkElement
    {
        element.Margin = new Thickness(left, top, right, bottom);
        return element;
    }

    public static Brush Brush(string key) => Resource<Brush>(key);

    /// <summary>Digits of equal width, for columns of times and counts.</summary>
    public static void FontFeatures(this TextBlock text) => Microsoft.UI.Xaml.Documents.Typography.SetNumeralAlignment(text, FontNumeralAlignment.Tabular);

    /// <summary>Shows a simple message dialog over <paramref name="root"/>.</summary>
    public static async Task Alert(XamlRoot root, string title, string message)
    {
        var dialog = new ContentDialog { XamlRoot = root, Title = title, Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap }, CloseButtonText = "OK" };
        await ContentDialogs.ShowAsync(dialog);
    }

    /// <summary>Asks a yes or no question; true for the primary button.</summary>
    public static async Task<bool> Confirm(XamlRoot root, string title, string message, string primary, bool destructive = false)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = root, Title = title, Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = primary, CloseButtonText = "Cancel", DefaultButton = destructive ? ContentDialogButton.Close : ContentDialogButton.Primary,
        };
        return await ContentDialogs.ShowAsync(dialog) == ContentDialogResult.Primary;
    }
}

/// <summary>One content dialog at a time (WinUI allows a single open dialog per window).</summary>
public static class ContentDialogs
{
    private static readonly SemaphoreSlim gate = new(1, 1);

    public static async Task<ContentDialogResult> ShowAsync(ContentDialog dialog)
    {
        await gate.WaitAsync();
        try
        {
            dialog.XamlRoot ??= MainWindow.Current.RootXamlRoot;
            if (dialog.XamlRoot is null) CrashLog.Write(null, "dialog without a window: " + dialog.Title);
            dialog.Style ??= Ui.Style("DefaultContentDialogStyle");
            if (dialog.XamlRoot?.Content is FrameworkElement root) dialog.RequestedTheme = root.ActualTheme;
            return await dialog.ShowAsync();
        }
        finally
        {
            gate.Release();
        }
    }
}
