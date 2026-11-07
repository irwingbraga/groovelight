using Windows.Storage;
using Windows.Storage.Pickers;

namespace Groovelight.Support;

/// <summary>File and folder pickers for the library window (the Mac's open and save panels).</summary>
public static class Pickers
{
    private static IntPtr Window => WinRT.Interop.WindowNative.GetWindowHandle(MainWindow.Current);

    public static async Task<string?> FolderAsync(string commitText = "Select Folder")
    {
        var picker = new FolderPicker { SuggestedStartLocation = PickerLocationId.MusicLibrary, CommitButtonText = commitText };
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Window);
        return (await picker.PickSingleFolderAsync())?.Path;
    }

    /// <summary><paramref name="extensions"/>: ".jpg" and the like, or empty for any file.</summary>
    public static async Task<string?> FileAsync(IEnumerable<string> extensions, string commitText = "Open", PickerLocationId start = PickerLocationId.MusicLibrary)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = start, CommitButtonText = commitText };
        foreach (var extension in extensions.DefaultIfEmpty("*")) picker.FileTypeFilter.Add(extension);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Window);
        return (await picker.PickSingleFileAsync())?.Path;
    }

    public static async Task<IReadOnlyList<string>> FilesAsync(IEnumerable<string> extensions, string commitText = "Open")
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.MusicLibrary, CommitButtonText = commitText };
        foreach (var extension in extensions.DefaultIfEmpty("*")) picker.FileTypeFilter.Add(extension);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Window);
        return (await picker.PickMultipleFilesAsync()).Select(file => file.Path).ToList();
    }

    /// <summary>A file to save to: <paramref name="types"/> maps a description ("M3U8 playlist") to its extensions.</summary>
    public static async Task<string?> SaveAsync(string suggestedName, IReadOnlyList<(string Description, string[] Extensions)> types,
                                                PickerLocationId start = PickerLocationId.DocumentsLibrary)
    {
        var picker = new FileSavePicker { SuggestedStartLocation = start, SuggestedFileName = suggestedName };
        foreach (var (description, extensions) in types) picker.FileTypeChoices.Add(description, extensions.ToList());
        WinRT.Interop.InitializeWithWindow.Initialize(picker, Window);
        var file = await picker.PickSaveFileAsync();
        if (file is null) return null;
        var path = file.Path;
        // The picker creates an empty file: callers write it whole.
        try { if (new FileInfo(path).Length == 0) await file.DeleteAsync(StorageDeleteOption.PermanentDelete); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        return path;
    }

    public static readonly string[] ImageExtensions = [".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp", ".tif", ".tiff", ".heic"];
}
