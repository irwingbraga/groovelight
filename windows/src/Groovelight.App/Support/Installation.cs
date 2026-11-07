using System.Diagnostics;
using Groovelight.Core;
using Groovelight.Model;
using Microsoft.Win32;
using Velopack;
using Velopack.Sources;

namespace Groovelight.Support;

/// <summary>
/// Updates from GitHub releases (Velopack): checked at launch and once a day, downloaded in the background, applied when
/// the user restarts. Velopack checks each package against the release's hashes before installing it.
/// </summary>
public sealed class Updates : Observable
{
    public const string RepositoryUrl = "https://github.com/irwingbraga/groovelight";
    public const string AutomaticKey = "updates.automatic";
    private readonly UpdateManager? manager;
    private UpdateInfo? ready;
    private string status = "";
    private bool busy;

    public Updates()
    {
        try
        {
            var candidate = new UpdateManager(new GithubSource(RepositoryUrl, null, false));
            if (candidate.IsInstalled) manager = candidate;
        }
        catch (Exception error) when (error is InvalidOperationException or IOException or NotSupportedException) { }
    }

    /// <summary>Installed with the installer (a development build does not update itself).</summary>
    public bool IsInstalled => manager is not null;
    public string CurrentVersion => manager?.CurrentVersion?.ToString() ?? typeof(Updates).Assembly.GetName().Version?.ToString(3) ?? "";
    /// <summary>A new version is downloaded: restarting installs it.</summary>
    public string? ReadyVersion => ready?.TargetFullRelease.Version.ToString();
    public string Status { get => status; private set => Set(ref status, value); }
    public bool IsBusy { get => busy; private set => Set(ref busy, value); }

    /// <summary>Checks now (Help, Check for Updates, or Settings); <paramref name="quiet"/> leaves the status alone when there is nothing new.</summary>
    public async Task CheckAsync(bool quiet = false)
    {
        if (manager is null)
        {
            if (!quiet) Status = "Updates come with the installed app (this build was not installed).";
            return;
        }
        if (IsBusy) return;
        IsBusy = true;
        try
        {
            if (!quiet) Status = "Checking…";
            var info = await manager.CheckForUpdatesAsync();
            if (info is null)
            {
                if (!quiet) Status = $"Groovelight {CurrentVersion} is the newest version.";
                return;
            }
            Status = $"Downloading Groovelight {info.TargetFullRelease.Version}…";
            await manager.DownloadUpdatesAsync(info);
            ready = info;
            Status = $"Groovelight {info.TargetFullRelease.Version} is ready: restart to install it.";
            OnPropertyChanged(nameof(ReadyVersion));
        }
        catch (Exception error) when (error is HttpRequestException or IOException or InvalidOperationException or TaskCanceledException)
        {
            if (!quiet) Status = "Could not check for updates: " + error.Message;
        }
        finally
        {
            IsBusy = false;
        }
    }

    /// <summary>Quits, installs the downloaded version and opens it again.</summary>
    public void RestartToUpdate()
    {
        if (manager is null || ready is null) return;
        AppModel.Current.Shutdown();
        manager.ApplyUpdatesAndRestart(ready);
    }

    /// <summary>At launch and every day after, when automatic updates are on (they are unless turned off).</summary>
    public void StartChecking(Preferences preferences, Microsoft.UI.Dispatching.DispatcherQueue queue)
    {
        if (manager is null) return;
        async void Check()
        {
            if (preferences.Bool(AutomaticKey, true)) await CheckAsync(quiet: true);
        }
        var timer = queue.CreateTimer();
        timer.Interval = TimeSpan.FromHours(24);
        timer.Tick += (_, _) => Check();
        timer.Start();
        var first = queue.CreateTimer();
        first.Interval = TimeSpan.FromSeconds(20);
        first.IsRepeating = false;
        first.Tick += (_, _) => Check();
        first.Start();
    }
}

/// <summary>
/// What the installer sets up for the user (Velopack installs per user, without asking for administrator rights):
/// <c>.cassette</c> files opening in Groovelight, Groovelight in Open With for music files, both under HKEY_CURRENT_USER.
/// </summary>
public static class FileTypes
{
    private const string CassetteProgId = "Groovelight.Cassette";
    private const string AudioProgId = "Groovelight.Audio";
    private static readonly string[] AudioExtensions =
        [".flac", ".mp3", ".m4a", ".aac", ".wav", ".aiff", ".aif", ".ogg", ".oga", ".opus", ".wv", ".ape", ".mpc", ".dsf", ".dff", ".cue", ".m3u", ".m3u8"];

    /// <summary>Registers the file types for <paramref name="exe"/> (the installed app), telling Explorer afterwards.</summary>
    public static void Register(string exe)
    {
        if (!OperatingSystem.IsWindows()) return;
        try
        {
            var open = $"\"{exe}\" \"%1\"";
            using (var cassette = Registry.CurrentUser.CreateSubKey($@"Software\Classes\{CassetteProgId}"))
            {
                cassette.SetValue("", "Groovelight Cassette");
                cassette.CreateSubKey("DefaultIcon").SetValue("", $"\"{exe}\",0");
                cassette.CreateSubKey(@"shell\open\command").SetValue("", open);
            }
            Registry.CurrentUser.CreateSubKey(@"Software\Classes\.cassette").SetValue("", CassetteProgId);
            using (var audio = Registry.CurrentUser.CreateSubKey($@"Software\Classes\{AudioProgId}"))
            {
                audio.SetValue("", "Music file");
                audio.CreateSubKey("DefaultIcon").SetValue("", $"\"{exe}\",0");
                audio.CreateSubKey(@"shell\open\command").SetValue("", open);
            }
            // Offered in Open With, never taking over a type the user chose another app for.
            foreach (var extension in AudioExtensions)
                Registry.CurrentUser.CreateSubKey($@"Software\Classes\{extension}\OpenWithProgids").SetValue(AudioProgId, Array.Empty<byte>(), RegistryValueKind.None);
            using (var application = Registry.CurrentUser.CreateSubKey(@"Software\Classes\Applications\Groovelight.exe"))
            {
                application.SetValue("FriendlyAppName", "Groovelight");
                application.CreateSubKey(@"shell\open\command").SetValue("", open);
                using var types = application.CreateSubKey("SupportedTypes");
                foreach (var extension in AudioExtensions.Append(".cassette")) types.SetValue(extension, "");
            }
            Changed();
        }
        catch (Exception error) when (error is UnauthorizedAccessException or IOException or System.Security.SecurityException) { }
    }

    public static void Unregister()
    {
        if (!OperatingSystem.IsWindows()) return;
        try
        {
            Registry.CurrentUser.DeleteSubKeyTree($@"Software\Classes\{CassetteProgId}", false);
            Registry.CurrentUser.DeleteSubKeyTree($@"Software\Classes\{AudioProgId}", false);
            Registry.CurrentUser.DeleteSubKeyTree(@"Software\Classes\Applications\Groovelight.exe", false);
            using (var cassette = Registry.CurrentUser.OpenSubKey(@"Software\Classes\.cassette"))
            {
                if (cassette?.GetValue("") as string == CassetteProgId) Registry.CurrentUser.DeleteSubKeyTree(@"Software\Classes\.cassette", false);
            }
            foreach (var extension in AudioExtensions)
            {
                using var progIds = Registry.CurrentUser.OpenSubKey($@"Software\Classes\{extension}\OpenWithProgids", true);
                progIds?.DeleteValue(AudioProgId, false);
            }
            Changed();
        }
        catch (Exception error) when (error is UnauthorizedAccessException or IOException or System.Security.SecurityException) { }
    }

    [System.Runtime.InteropServices.DllImport("shell32.dll")]
    private static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);

    /// <summary>Tells Explorer the associations changed (SHCNE_ASSOCCHANGED).</summary>
    private static void Changed() => SHChangeNotify(0x08000000, 0, IntPtr.Zero, IntPtr.Zero);
}

/// <summary>
/// The Windows Firewall rule letting phones reach wireless sync (ports 52300 and 52301, private networks only). Adding it
/// needs an administrator: Windows asks the user when they choose to allow it (Settings, Devices).
/// </summary>
public static class WindowsFirewall
{
    public const string RuleName = "Groovelight Wireless Sync";

    /// <summary>Whether the rule is there (reading the rules needs no administrator).</summary>
    public static bool HasRule()
    {
        if (!OperatingSystem.IsWindows()) return true;
        try
        {
            using var process = Process.Start(new ProcessStartInfo("netsh", $"advfirewall firewall show rule name=\"{RuleName}\"")
            {
                CreateNoWindow = true, UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true,
            });
            if (process is null) return false;
            process.StandardOutput.ReadToEnd();
            process.WaitForExit(5000);
            return process.ExitCode == 0;
        }
        catch (System.ComponentModel.Win32Exception) { return false; }
    }

    /// <summary>Adds the rule for this app, with Windows asking for an administrator's consent. True when it was added.</summary>
    public static async Task<bool> AllowAsync()
    {
        var exe = Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "Groovelight.exe");
        var add = $"advfirewall firewall add rule name=\"{RuleName}\" dir=in action=allow program=\"{exe}\" protocol=TCP localport=52300-52301 profile=private";
        try
        {
            using var process = Process.Start(new ProcessStartInfo("netsh", add) { UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden });
            if (process is null) return false;
            await process.WaitForExitAsync();
            return process.ExitCode == 0;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            // The user declined Windows' question.
            return false;
        }
    }
}

/// <summary>
/// The <c>groovelight</c> command (groovelight.com next to the app) in terminals: the installer adds the app's folder to
/// the user's PATH (HKEY_CURRENT_USER, no administrator needed) and the uninstaller takes it out again.
/// </summary>
public static class CommandLineTool
{
    public static string Folder => Path.TrimEndingDirectorySeparator(AppContext.BaseDirectory);
    public static string ToolPath => Path.Combine(Folder, "groovelight.com");
    public static bool Exists => File.Exists(ToolPath);

    /// <summary>Whether <paramref name="folder"/> (this app's by default) is in the user's PATH.</summary>
    public static bool IsOnPath(string? folder = null) => Entries().Any(entry => Same(entry, folder ?? Folder));

    public static void AddToPath(string? folder = null)
    {
        folder ??= Folder;
        if (IsOnPath(folder)) return;
        Write([.. Entries(), folder]);
    }

    public static void RemoveFromPath(string? folder = null)
    {
        folder ??= Folder;
        var entries = Entries();
        if (entries.RemoveAll(entry => Same(entry, folder)) > 0) Write(entries);
    }

    private static bool Same(string entry, string folder) =>
        string.Equals(Path.TrimEndingDirectorySeparator(Environment.ExpandEnvironmentVariables(entry.Trim())), Path.TrimEndingDirectorySeparator(folder), StringComparison.OrdinalIgnoreCase);

    private static List<string> Entries()
    {
        if (!OperatingSystem.IsWindows()) return [];
        using var environment = Registry.CurrentUser.OpenSubKey("Environment");
        // Unexpanded, so entries like %USERPROFILE%\bin stay as the user wrote them.
        var value = environment?.GetValue("Path", "", RegistryValueOptions.DoNotExpandEnvironmentNames) as string ?? "";
        return value.Split(';', StringSplitOptions.RemoveEmptyEntries).ToList();
    }

    private static void Write(List<string> entries)
    {
        if (!OperatingSystem.IsWindows()) return;
        try
        {
            using var environment = Registry.CurrentUser.CreateSubKey("Environment");
            environment.SetValue("Path", string.Join(';', entries), RegistryValueKind.ExpandString);
            // New terminals (and Explorer) read the change.
            SendMessageTimeout(new IntPtr(0xFFFF), 0x001A, IntPtr.Zero, "Environment", 0x0002, 5000, out _);
        }
        catch (Exception error) when (error is UnauthorizedAccessException or IOException or System.Security.SecurityException) { }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wParam, string lParam, uint flags, uint timeout, out IntPtr result);
}
