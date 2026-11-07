namespace Groovelight.Audio;

/// <summary>Interleaved 32-bit float PCM at a rate, as the engine renders it.</summary>
public readonly record struct AudioFormat(int SampleRate, int Channels);

/// <summary>What the engine asks of the output device.</summary>
/// <param name="SampleRate">The rate wanted; in shared mode the device's own rate may be used instead.</param>
/// <param name="Exclusive">Take the device for this app alone, at exactly this rate and an integer format deep enough for <paramref name="BitDepth"/>.</param>
public sealed record OutputRequest(int SampleRate, int Channels, bool Exclusive = false, int? BitDepth = null);

/// <summary>The engine side of an output: renders <c>frames</c> frames into the buffer (silence when there is nothing to play).</summary>
public interface IAudioSource
{
    void Render(Span<float> buffer, int frames, AudioFormat format);
}

/// <summary>An output device and what it reports about itself.</summary>
public sealed record OutputDeviceInfo(string Name, int SampleRate, int? BitDepth, IReadOnlyList<int> SupportedRates, bool SupportsExclusive)
{
    public bool Supports(int rate) => SupportedRates.Contains(rate);
}

/// <summary>The sound output could not be opened (no device, a device in use by another app, an audio service problem).</summary>
public sealed class AudioOutputException(string message, Exception? inner = null) : InvalidOperationException(message, inner);

/// <summary>
/// Where the sound goes: WASAPI on Windows (shared, or exclusive for bit-perfect playback); a manual output in tests.
/// Calls come from the player's thread; <see cref="IAudioSource.Render"/> is called from the output's own thread.
/// </summary>
public interface IAudioOutput : IDisposable
{
    /// <summary>Opens a stream (closing the previous one) and returns the format it runs at; <see cref="AudioOutputException"/> when it cannot.</summary>
    AudioFormat Open(OutputRequest request, IAudioSource source);
    void Start();
    void Pause();
    /// <summary>Stops and closes the stream.</summary>
    void Close();
    /// <summary>The format of the open stream, if any.</summary>
    AudioFormat? Format { get; }
    /// <summary>Whether the open stream has the device to itself.</summary>
    bool IsExclusive { get; }
    /// <summary>Seconds between a frame rendered and it being heard.</summary>
    double Latency { get; }
    /// <summary>The device in use (the default one), when known.</summary>
    OutputDeviceInfo? Device { get; }
    /// <summary>The device's own volume (0...1), used instead of digital volume for bit-perfect playback; null without one.</summary>
    float? DeviceVolume { get; set; }
    /// <summary>The default device changed or went away: the player reopens its stream.</summary>
    event Action? DeviceChanged;
}

/// <summary>An output that renders only when asked (tests, and measuring without a device).</summary>
public sealed class ManualOutput(int deviceRate = 48_000, IReadOnlyList<int>? supportedRates = null) : IAudioOutput
{
    private IAudioSource? source;
    private bool running;

    public AudioFormat? Format { get; private set; }
    public bool IsExclusive { get; private set; }
    public double Latency { get; set; }
    public OutputDeviceInfo? Device { get; } = new("Test Output", deviceRate, 24, supportedRates ?? [44_100, 48_000, 88_200, 96_000, 176_400, 192_000], true);
    public float? DeviceVolume { get; set; } = 1;
    public event Action? DeviceChanged;
    /// <summary>Every frame rendered while running, for tests to inspect.</summary>
    public List<float> Rendered { get; } = [];
    public bool IsRunning => running;
    public int OpenCount { get; private set; }

    /// <summary>When set, opening fails with this reason (a missing or broken device).</summary>
    public string? FailsToOpen { get; set; }

    public AudioFormat Open(OutputRequest request, IAudioSource newSource)
    {
        if (FailsToOpen is { } reason) throw new AudioOutputException(reason);
        source = newSource;
        IsExclusive = request.Exclusive;
        OpenCount++;
        Format = new AudioFormat(request.Exclusive ? request.SampleRate : Device!.SampleRate, request.Channels);
        return Format.Value;
    }

    public void Start() => running = true;
    public void Pause() => running = false;

    public void Close()
    {
        running = false;
        Format = null;
    }

    /// <summary>Renders <paramref name="frames"/> frames as the device would, when running.</summary>
    public void Pump(int frames)
    {
        if (!running || source is null || Format is not { } format) return;
        var buffer = new float[frames * format.Channels];
        source.Render(buffer, frames, format);
        Rendered.AddRange(buffer);
    }

    public void SimulateDeviceChange() => DeviceChanged?.Invoke();

    public void Dispose() => Close();
}
