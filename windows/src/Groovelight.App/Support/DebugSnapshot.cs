using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Groovelight.Support;

/// <summary>
/// <c>--debug-snapshot &lt;file.png&gt;</c>: once the window has laid out, renders its content to a PNG and quits. For
/// checking the UI over SSH, where the PC's screen may be locked (the counterpart of the Mac's debug tour snapshots).
/// The window's backdrop (Mica) is not part of the content, so the PNG shows the content on transparency.
/// </summary>
internal static class DebugSnapshot
{
    public static string? RequestedPath()
    {
        var args = Environment.GetCommandLineArgs();
        var index = Array.IndexOf(args, "--debug-snapshot");
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }

    /// <summary>Another window to capture instead of the library window (<c>--debug-equalizer</c>, <c>--debug-mini</c>).</summary>
    public static Window? Target { get; set; }

    public static async Task CaptureAsync(Window window, string path, TimeSpan delay)
    {
        await Task.Delay(delay);
        window = Target ?? window;
        if (window.Content is not FrameworkElement root) return;
        // A dialog shows in the popup layer, which rendering the window's content leaves out: render the dialog.
        UIElement target = root;
        if (Environment.GetCommandLineArgs().Contains("--debug-snapshot-popup")
            && Microsoft.UI.Xaml.Media.VisualTreeHelper.GetOpenPopupsForXamlRoot(root.XamlRoot).OrderBy(item => item.Child is Microsoft.UI.Xaml.Controls.ContentDialog ? 0 : 1).FirstOrDefault() is { Child: { } popup }) target = popup;
        // The backdrop (Mica) is not part of what is rendered: a solid background keeps the snapshot readable.
        var background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["SolidBackgroundFillColorBaseBrush"];
        if (root is Microsoft.UI.Xaml.Controls.Panel panel) panel.Background = background;
        else if (root is Microsoft.UI.Xaml.Controls.Control control) control.Background = background;
        await Task.Delay(300);
        var bitmap = new RenderTargetBitmap();
        // Nothing renders while the session is locked: give up rather than wait forever.
        var render = bitmap.RenderAsync(target).AsTask();
        if (await Task.WhenAny(render, Task.Delay(TimeSpan.FromSeconds(15))) != render)
        {
            await File.WriteAllTextAsync(Path.ChangeExtension(path, ".txt"), "Nothing rendered in 15 s: is the screen locked?");
            Application.Current.Exit();
            return;
        }
        var pixels = await bitmap.GetPixelsAsync();
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        using (var stream = new InMemoryRandomAccessStream())
        {
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
            var dpi = 96 * root.XamlRoot.RasterizationScale;
            encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight,
                                 dpi, dpi, pixels.ToArray());
            await encoder.FlushAsync();
            var bytes = new byte[stream.Size];
            stream.Seek(0);
            await stream.ReadAsync(bytes.AsBuffer(), (uint)bytes.Length, InputStreamOptions.None);
            await File.WriteAllBytesAsync(path, bytes);
        }
        Application.Current.Exit();
    }
}
