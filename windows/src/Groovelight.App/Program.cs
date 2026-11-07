using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace Groovelight;

/// <summary>
/// One Groovelight per library: a second launch (a jump list task, a file opened with the app, the command line) hands
/// its arguments to the running app and quits.
/// </summary>
public static class Program
{
    /// <summary>Arguments of later launches, delivered on the UI thread.</summary>
    public static event Action<IReadOnlyList<string>>? Relaunched;

    [STAThread]
    public static int Main(string[] args)
    {
        // The installer's hooks (install, update, uninstall) run here and return at once; then the app starts as usual.
        Velopack.VelopackApp.Build()
            .OnAfterInstallFastCallback(_ =>
            {
                Support.FileTypes.Register(Environment.ProcessPath!);
                Support.CommandLineTool.AddToPath();
            })
            .OnAfterUpdateFastCallback(_ => Support.FileTypes.Register(Environment.ProcessPath!))
            .OnBeforeUninstallFastCallback(_ =>
            {
                Support.FileTypes.Unregister();
                Support.CommandLineTool.RemoveFromPath();
            })
            .Run();
        WinRT.ComWrappersSupport.InitializeComWrappers();
        var data = Support.DebugOptions.DataDirectory ?? Environment.GetEnvironmentVariable("GROOVELIGHT_DATA") ?? "";
        var key = "Groovelight-" + Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(data.ToLowerInvariant())))[..16];
        var instance = AppInstance.FindOrRegisterForKey(key);
        if (!instance.IsCurrent)
        {
            var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
            instance.RedirectActivationToAsync(activation).AsTask().Wait();
            return 0;
        }
        instance.Activated += (_, activation) =>
        {
            if (activation.Data is not Windows.ApplicationModel.Activation.ILaunchActivatedEventArgs launch) return;
            var arguments = SplitArguments(launch.Arguments).Skip(1).ToList();
            queue?.TryEnqueue(() => Relaunched?.Invoke(arguments));
        };
        Application.Start(parameters =>
        {
            queue = DispatcherQueue.GetForCurrentThread();
            SynchronizationContext.SetSynchronizationContext(new LoggingSynchronizationContext(new DispatcherQueueSynchronizationContext(queue)));
            new App();
        });
        return 0;
    }

    private static DispatcherQueue? queue;

    /// <summary>A command line split as Windows does (quotes group, backslashes before quotes escape).</summary>
    public static List<string> SplitArguments(string commandLine)
    {
        var result = new List<string>();
        var current = new System.Text.StringBuilder();
        var quoted = false;
        var any = false;
        for (var index = 0; index < commandLine.Length; index++)
        {
            var character = commandLine[index];
            if (character == '\\')
            {
                var slashes = 0;
                while (index < commandLine.Length && commandLine[index] == '\\') { slashes++; index++; }
                if (index < commandLine.Length && commandLine[index] == '"')
                {
                    current.Append('\\', slashes / 2);
                    if (slashes % 2 == 1) current.Append('"');
                    else { quoted = !quoted; any = true; }
                }
                else
                {
                    current.Append('\\', slashes);
                    index--;
                }
                continue;
            }
            if (character == '"') { quoted = !quoted; any = true; continue; }
            if (char.IsWhiteSpace(character) && !quoted)
            {
                if (current.Length > 0 || any) result.Add(current.ToString());
                current.Clear();
                any = false;
                continue;
            }
            current.Append(character);
        }
        if (current.Length > 0 || any) result.Add(current.ToString());
        return result;
    }
}

/// <summary>
/// The UI thread's context, writing an exception that escapes a continuation (an async void method, say) to Errors.log
/// before it ends the app: WinUI ends it from its dispatcher without raising Application.UnhandledException.
/// </summary>
internal sealed class LoggingSynchronizationContext(SynchronizationContext inner) : SynchronizationContext
{
    public override void Post(SendOrPostCallback callback, object? state) => inner.Post(Guarded(callback), state);

    public override void Send(SendOrPostCallback callback, object? state) => inner.Send(Guarded(callback), state);

    public override SynchronizationContext CreateCopy() => this;

    private static SendOrPostCallback Guarded(SendOrPostCallback callback) => value =>
    {
        try
        {
            callback(value);
        }
        catch (Exception error)
        {
            CrashLog.Write(error, "dispatcher");
            throw;
        }
    };
}
