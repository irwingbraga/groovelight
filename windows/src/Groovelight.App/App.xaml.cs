using Groovelight.Model;
using Groovelight.Support;
using Microsoft.UI.Xaml;

namespace Groovelight;

/// <summary>Groovelight for Windows: one library window, like the Mac app.</summary>
public partial class App : Application
{
    private MainWindow? window;

    public App()
    {
        InitializeComponent();
        // What went wrong is kept in the data folder's Errors.log (there is no console to read).
        UnhandledException += (_, args) => CrashLog.Write(args.Exception, args.Message);
        AppDomain.CurrentDomain.UnhandledException += (_, args) => CrashLog.Write(args.ExceptionObject as Exception, "domain");
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            CrashLog.Write(args.Exception, "task");
            args.SetObserved();
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            _ = new AppModel(DebugOptions.DataDirectory);
            Features.Register();
            window = new MainWindow();
            window.Activate();
            DebugOptions.Apply(window);
            var arguments = Environment.GetCommandLineArgs().Skip(1).ToList();
            if (!arguments.Any(argument => argument.StartsWith("--debug", StringComparison.Ordinal))) window.HandleArguments(arguments);
            if (DebugSnapshot.RequestedPath() is { } path) _ = DebugSnapshot.CaptureAsync(window, path, TimeSpan.FromSeconds(DebugOptions.SnapshotDelay));
        }
        catch (Exception error)
        {
            CrashLog.Write(error, "launch");
            throw;
        }
    }
}

/// <summary>Appends unexpected errors to Errors.log in the data folder.</summary>
internal static class CrashLog
{
    public static void Write(Exception? error, string context)
    {
        try
        {
            var folder = Groovelight.Core.AppInfo.DataDirectory(DebugOptions.DataDirectory ?? Environment.GetEnvironmentVariable("GROOVELIGHT_DATA"));
            Directory.CreateDirectory(folder);
            File.AppendAllText(Path.Combine(folder, "Errors.log"), $"{DateTime.Now:O} {context}\n{error}\n\n");
        }
        catch (IOException)
        {
        }
    }
}
