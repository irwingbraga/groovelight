namespace Groovelight.Core;

/// <summary>Where Groovelight keeps its data on this computer.</summary>
public static class AppInfo
{
    public const string Name = "Groovelight";

    /// <summary>
    /// The folder for the library database, the artwork cache, cassettes and presets: <c>%LOCALAPPDATA%\Groovelight</c>
    /// on Windows, the counterpart of the Mac's Application Support folder.
    /// </summary>
    public static string DataDirectory(string? overrideDirectory = null) =>
        overrideDirectory ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), Name);
}
