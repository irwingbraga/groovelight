using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
using NAudio.Wave;

namespace Groovelight.Audio.Windows;

/// <summary>
/// The default output device through WASAPI: in shared mode at the device's mix format (Windows mixes the app with other
/// sounds), or in exclusive mode at the song's own rate and an integer format deep enough for it, the samples passing
/// untouched (bit-perfect). Follows the default device when it changes.
/// </summary>
public sealed class WasapiOutput : IAudioOutput
{
    private readonly MMDeviceEnumerator enumerator = new();
    private readonly NotificationClient notifications;
    private MMDevice? device;
    private WasapiOut? player;
    private OutputDeviceInfo? deviceInfo;
    private readonly Dictionary<string, OutputDeviceInfo> probed = [];

    public AudioFormat? Format { get; private set; }
    public bool IsExclusive { get; private set; }
    public double Latency { get; private set; }
    public event Action? DeviceChanged;

    /// <summary>Exclusive mode needs a device period: shorter is snappier, longer survives a busy system.</summary>
    public int LatencyMilliseconds { get; set; } = 60;

    public WasapiOutput()
    {
        notifications = new NotificationClient(this);
        enumerator.RegisterEndpointNotificationCallback(notifications);
    }

    public OutputDeviceInfo? Device
    {
        get
        {
            try
            {
                var current = device ?? enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
                return deviceInfo is not null && device is not null ? deviceInfo : Describe(current);
            }
            catch (COMException)
            {
                return null;
            }
        }
    }

    public float? DeviceVolume
    {
        get
        {
            try { return (device ?? enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia)).AudioEndpointVolume.MasterVolumeLevelScalar; }
            catch (COMException) { return null; }
        }
        set
        {
            if (value is not { } level) return;
            try { (device ?? enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia)).AudioEndpointVolume.MasterVolumeLevelScalar = Math.Clamp(level, 0, 1); }
            catch (COMException) { }
        }
    }

    public AudioFormat Open(OutputRequest request, IAudioSource source)
    {
        try
        {
            return OpenStream(request, source);
        }
        catch (Exception error) when (error is COMException or ArgumentException)
        {
            Close();
            throw new AudioOutputException($"The sound output could not be opened ({error.Message.Trim()}). Check the output device in Windows' sound settings.", error);
        }
    }

    private AudioFormat OpenStream(OutputRequest request, IAudioSource source)
    {
        Close();
        device = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
        deviceInfo = Describe(device);
        WaveFormat waveFormat;
        AudioClientShareMode mode;
        int engineRate;
        if (request.Exclusive && ExclusiveFormat(device, request.SampleRate, request.BitDepth) is { } exclusive)
        {
            waveFormat = exclusive;
            mode = AudioClientShareMode.Exclusive;
            engineRate = request.SampleRate;
        }
        else
        {
            // Shared: the mix format (32-bit float at the device's rate and channels).
            var mix = device.AudioClient.MixFormat;
            waveFormat = WaveFormat.CreateIeeeFloatWaveFormat(mix.SampleRate, mix.Channels);
            mode = AudioClientShareMode.Shared;
            engineRate = mix.SampleRate;
        }
        var format = new AudioFormat(engineRate, request.Channels);
        var provider = new RenderProvider(source, format, waveFormat);
        player = new WasapiOut(device, mode, useEventSync: true, LatencyMilliseconds);
        player.Init(provider);
        IsExclusive = mode == AudioClientShareMode.Exclusive;
        Format = format;
        Latency = LatencyMilliseconds / 1000.0;
        return format;
    }

    /// <summary>
    /// The integer format the device takes exclusively at <paramref name="rate"/>: as deep as the song (16-bit songs
    /// fit any container exactly; 24-bit ones need 24 or 32), so the samples pass untouched.
    /// </summary>
    private static WaveFormat? ExclusiveFormat(MMDevice device, int rate, int? bits)
    {
        int[] depths = bits is <= 16 ? [16, 24, 32] : [24, 32];
        foreach (var depth in depths)
        {
            foreach (var format in new WaveFormat[] { new WaveFormatExtensible(rate, depth, 2), new WaveFormat(rate, depth, 2) })
            {
                try
                {
                    if (device.AudioClient.IsFormatSupported(AudioClientShareMode.Exclusive, format)) return format;
                }
                catch (COMException) { }
            }
        }
        return null;
    }

    private static readonly int[] CommonRates = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000];

    /// <summary>The device's name, mix rate and the rates it takes exclusively (probed once per device).</summary>
    private OutputDeviceInfo Describe(MMDevice target)
    {
        if (probed.TryGetValue(target.ID, out var known)) return known;
        var mix = target.AudioClient.MixFormat;
        var rates = new List<int>();
        int? deepest = null;
        var exclusive = false;
        foreach (var rate in CommonRates)
        {
            if (ExclusiveFormat(target, rate, 24) is { } format)
            {
                rates.Add(rate);
                deepest = Math.Max(deepest ?? 0, format.BitsPerSample);
                exclusive = true;
            }
            else if (ExclusiveFormat(target, rate, 16) is not null)
            {
                rates.Add(rate);
                deepest ??= 16;
                exclusive = true;
            }
        }
        if (rates.Count == 0) rates.Add(mix.SampleRate);
        var info = new OutputDeviceInfo(target.FriendlyName, mix.SampleRate, deepest, rates, exclusive);
        probed[target.ID] = info;
        return info;
    }

    public void Start() => player?.Play();

    public void Pause() => player?.Pause();

    public void Close()
    {
        if (player is not null)
        {
            player.Stop();
            player.Dispose();
            player = null;
        }
        Format = null;
        IsExclusive = false;
    }

    public void Dispose()
    {
        Close();
        try { enumerator.UnregisterEndpointNotificationCallback(notifications); } catch (COMException) { }
        enumerator.Dispose();
    }

    /// <summary>Pulls the engine's float frames and hands them to WASAPI in the device's format.</summary>
    private sealed class RenderProvider(IAudioSource source, AudioFormat format, WaveFormat waveFormat) : IWaveProvider
    {
        private float[] buffer = [];

        public WaveFormat WaveFormat => waveFormat;

        public int Read(byte[] output, int offset, int count)
        {
            var bytesPerSample = waveFormat.BitsPerSample / 8;
            var deviceChannels = waveFormat.Channels;
            var frames = count / (bytesPerSample * deviceChannels);
            if (buffer.Length < frames * format.Channels) buffer = new float[frames * format.Channels];
            source.Render(buffer, frames, format);
            var isFloat = waveFormat.Encoding == WaveFormatEncoding.IeeeFloat
                || (waveFormat is WaveFormatExtensible extensible && extensible.SubFormat == NAudio.Dmo.AudioMediaSubtypes.MEDIASUBTYPE_IEEE_FLOAT);
            var target = output.AsSpan(offset, frames * bytesPerSample * deviceChannels);
            target.Clear();
            for (var frame = 0; frame < frames; frame++)
            {
                // The engine renders stereo: left and right go to the first two channels (the others stay silent).
                for (var channel = 0; channel < Math.Min(deviceChannels, format.Channels); channel++)
                {
                    var sample = buffer[frame * format.Channels + channel];
                    var at = target[((frame * deviceChannels + channel) * bytesPerSample)..];
                    if (isFloat)
                    {
                        BitConverter.TryWriteBytes(at, sample);
                        continue;
                    }
                    // Integer: exact for samples that came from integers of this depth or less (scale by 2^(bits-1)).
                    var scale = 1L << (waveFormat.BitsPerSample - 1);
                    var value = (long)Math.Round(Math.Clamp(sample, -1f, 1f) * scale);
                    value = Math.Clamp(value, -scale, scale - 1);
                    switch (bytesPerSample)
                    {
                        case 2: BitConverter.TryWriteBytes(at, (short)value); break;
                        case 3: at[0] = (byte)value; at[1] = (byte)(value >> 8); at[2] = (byte)(value >> 16); break;
                        default: BitConverter.TryWriteBytes(at, (int)value); break;
                    }
                }
            }
            return frames * bytesPerSample * deviceChannels;
        }
    }

    /// <summary>The default device changing (headphones plugged in, a DAC switched on) reopens the stream there.</summary>
    private sealed class NotificationClient(WasapiOutput owner) : IMMNotificationClient
    {
        public void OnDefaultDeviceChanged(DataFlow flow, Role role, string defaultDeviceId)
        {
            if (flow == DataFlow.Render && role == Role.Multimedia) owner.DeviceChanged?.Invoke();
        }

        public void OnDeviceStateChanged(string deviceId, DeviceState newState)
        {
            if (owner.device?.ID == deviceId && newState != DeviceState.Active) owner.DeviceChanged?.Invoke();
        }

        public void OnDeviceAdded(string pwstrDeviceId) { }
        public void OnDeviceRemoved(string deviceId) { }
        public void OnPropertyValueChanged(string pwstrDeviceId, PropertyKey key) { }
    }
}
