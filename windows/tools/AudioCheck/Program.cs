using Groovelight.Audio;
using Groovelight.Audio.Windows;

// AudioCheck [--exclusive] <files...>: plays the files through the default device at volume 0 and reports.
var exclusive = args.Contains("--exclusive");
var files = args.Where(arg => !arg.StartsWith("--")).ToList();
using var output = new WasapiOutput();
var device = output.Device;
Console.WriteLine($"Device: {device?.Name}, mix rate {device?.SampleRate} Hz, exclusive {device?.SupportsExclusive}, deepest {device?.BitDepth}-bit");
Console.WriteLine($"Exclusive rates: {string.Join(", ", device?.SupportedRates ?? [])}");
if (files.Count == 0) return;

var player = new PlaybackController(output, new SynchronizationContextDispatcher(null));
var started = new List<string>();
player.ItemStarted += item => { lock (started) started.Add(Path.GetFileName(item.Path)); };
player.BitPerfect = exclusive;
player.Volume = 0;
if (exclusive) output.DeviceVolume = output.DeviceVolume; // leave the device's volume as it is
var items = files.Select((file, index) => new PlayableItem { Id = index + 1, Path = Path.GetFullPath(file), Title = Path.GetFileName(file), Duration = 1 }).ToList();
var clock = System.Diagnostics.Stopwatch.StartNew();
player.Play(items);
Console.WriteLine($"Output: {output.Format}, exclusive {output.IsExclusive}");
while (player.State != PlaybackState.Stopped && clock.Elapsed < TimeSpan.FromSeconds(30))
{
    Thread.Sleep(250);
    Console.WriteLine($"{clock.Elapsed.TotalSeconds,5:0.00} s  {player.State,-8} {player.Current?.Title,-20} {player.CurrentTime,5:0.00} / {player.Duration:0.00}");
}
Console.WriteLine($"Started: {string.Join(", ", started)}; took {clock.Elapsed.TotalSeconds:0.00} s; status: bit-perfect {player.Output.IsBitPerfect} {string.Join(" ", player.Output.Notes)}");
player.Dispose();
