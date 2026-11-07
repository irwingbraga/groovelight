using System.Runtime.InteropServices;
using FFmpeg.AutoGen;

namespace Groovelight.Audio;

public sealed class AudioDecoderException(string message) : IOException(message);

/// <summary>
/// Decodes an audio file with FFmpeg (SFBAudioEngine's role on the Mac) into interleaved 32-bit float samples: mono or
/// stereo (more channels are mixed down), at the file's rate or resampled to the output's. Seeking is sample accurate,
/// and a CUE track is a region of its file (so consecutive tracks of one file join without a gap).
/// </summary>
public sealed unsafe class AudioDecoder : IDisposable
{
    private AVFormatContext* format;
    private AVCodecContext* codec;
    private SwrContext* resampler;
    private AVPacket* packet;
    private AVFrame* frame;
    private readonly int streamIndex;
    private readonly AVRational timeBase;
    /// <summary>Converted samples not handed out yet.</summary>
    private float[] pending = [];
    private int pendingOffset, pendingCount;
    private bool endOfFile, flushed;
    /// <summary>Region of the file, in output frames: where it starts (in the file) and how long it is (-1: to the end).</summary>
    private readonly long regionStart;
    private readonly long regionLength;
    /// <summary>Frames handed out since the start of the region.</summary>
    private long position;
    /// <summary>After a seek: the output frame (from the file's start) to hand out from; earlier samples are dropped.</summary>
    private long? seekTarget;
    /// <summary>Whether the codec needs decoding before the target to warm up (lossy codecs overlap their frames).</summary>
    private readonly bool needsPreroll;

    /// <summary>The output rate (the file's, unless resampled).</summary>
    public int SampleRate { get; }
    /// <summary>Output channels: 1 or 2.</summary>
    public int Channels { get; }
    /// <summary>The file's own rate.</summary>
    public int FileSampleRate { get; }
    /// <summary>Bits per sample of the file (null for lossy codecs and float files).</summary>
    public int? FileBitDepth { get; }
    /// <summary>FFmpeg's codec name ("flac", "alac", "mp3"...).</summary>
    public string CodecName { get; }
    /// <summary>Length in output frames (an estimate from the container for some lossy files), -1 when unknown.</summary>
    public long Length { get; }
    public long Position => position;
    public double Duration => Length < 0 ? 0 : (double)Length / SampleRate;

    public static AudioDecoder Open(string path, double? start = null, double? end = null, int? outputSampleRate = null) =>
        new(path, start, end, outputSampleRate);

    private AudioDecoder(string path, double? start, double? end, int? outputSampleRate)
    {
        FFmpegLibraries.EnsureLoaded();
        try
        {
            AVFormatContext* context = null;
            Check(ffmpeg.avformat_open_input(&context, path, null, null), path);
            format = context;
            Check(ffmpeg.avformat_find_stream_info(format, null), path);
            AVCodec* decoder = null;
            streamIndex = ffmpeg.av_find_best_stream(format, AVMediaType.AVMEDIA_TYPE_AUDIO, -1, -1, &decoder, 0);
            if (streamIndex < 0 || decoder is null) throw new AudioDecoderException($"{Path.GetFileName(path)} has no audio.");
            var stream = format->streams[streamIndex];
            timeBase = stream->time_base;
            codec = ffmpeg.avcodec_alloc_context3(decoder);
            Check(ffmpeg.avcodec_parameters_to_context(codec, stream->codecpar), path);
            codec->pkt_timebase = stream->time_base;
            Check(ffmpeg.avcodec_open2(codec, decoder, null), path);

            FileSampleRate = codec->sample_rate;
            SampleRate = outputSampleRate is > 0 ? outputSampleRate.Value : FileSampleRate;
            Channels = Math.Clamp(codec->ch_layout.nb_channels, 1, 2);
            CodecName = Marshal.PtrToStringAnsi((IntPtr)decoder->name) ?? "";
            var bits = codec->bits_per_raw_sample > 0 ? codec->bits_per_raw_sample : stream->codecpar->bits_per_raw_sample;
            if (bits <= 0) bits = stream->codecpar->bits_per_coded_sample;
            FileBitDepth = IsLossy(CodecName) || bits <= 0 || bits > 32 ? null : bits;
            needsPreroll = IsLossy(CodecName);

            var outputLayout = new AVChannelLayout();
            ffmpeg.av_channel_layout_default(&outputLayout, Channels);
            SwrContext* swr = null;
            var inputLayout = codec->ch_layout;
            Check(ffmpeg.swr_alloc_set_opts2(&swr, &outputLayout, AVSampleFormat.AV_SAMPLE_FMT_FLT, SampleRate,
                                             &inputLayout, codec->sample_fmt, FileSampleRate, 0, null), path);
            resampler = swr;
            Check(ffmpeg.swr_init(resampler), path);
            packet = ffmpeg.av_packet_alloc();
            frame = ffmpeg.av_frame_alloc();

            var total = stream->duration > 0 ? stream->duration * timeBase.num / (double)timeBase.den
                : format->duration > 0 ? format->duration / (double)ffmpeg.AV_TIME_BASE : -1;
            regionStart = start is > 0 ? (long)Math.Round(start.Value * SampleRate) : 0;
            regionLength = end is { } stop ? (long)Math.Round((stop - (start ?? 0)) * SampleRate) : -1;
            Length = regionLength >= 0 ? regionLength : total > 0 ? (long)Math.Round(total * SampleRate) - regionStart : -1;
            if (regionStart > 0) SeekToFrame(regionStart);
        }
        catch
        {
            Dispose();
            throw;
        }
    }

    private static bool IsLossy(string codec) => codec is "mp3" or "mp3float" or "mp2" or "mp2float" or "mp1" or "aac" or "aac_fixed" or "aac_latm"
        or "vorbis" or "libvorbis" or "opus" or "libopus" or "musepack7" or "musepack8" or "speex" or "libspeex" or "wmav1" or "wmav2" or "wmapro";

    private static void Check(int result, string path)
    {
        if (result >= 0) return;
        var buffer = stackalloc byte[256];
        ffmpeg.av_strerror(result, buffer, 256);
        throw new AudioDecoderException($"{Path.GetFileName(path)}: {Marshal.PtrToStringAnsi((IntPtr)buffer)}");
    }

    /// <summary>Reads up to <c>samples.Length / Channels</c> frames; 0 at the end of the file (or region).</summary>
    public int Read(Span<float> samples)
    {
        var wanted = samples.Length / Channels;
        if (regionLength >= 0) wanted = (int)Math.Min(wanted, regionLength - position);
        var written = 0;
        while (written < wanted)
        {
            if (pendingCount == 0 && !Fill()) break;
            var count = Math.Min(wanted - written, pendingCount);
            pending.AsSpan(pendingOffset, count * Channels).CopyTo(samples[(written * Channels)..]);
            pendingOffset += count * Channels;
            pendingCount -= count;
            written += count;
        }
        position += written;
        return written;
    }

    /// <summary>Decodes the next packet's samples into <see cref="pending"/>; false at the end.</summary>
    private bool Fill()
    {
        while (true)
        {
            var result = ffmpeg.avcodec_receive_frame(codec, frame);
            if (result >= 0)
            {
                var start = FrameStart();
                Convert((byte**)&frame->data, frame->nb_samples);
                ffmpeg.av_frame_unref(frame);
                TrimBeforeSeekTarget(start);
                if (pendingCount > 0) return true;
                continue;
            }
            if (result == ffmpeg.AVERROR_EOF)
            {
                // The resampler may still hold a few samples.
                if (flushed) return false;
                flushed = true;
                Convert(null, 0);
                return pendingCount > 0;
            }
            if (result != ffmpeg.AVERROR(ffmpeg.EAGAIN)) return false;
            if (endOfFile) return false;
            // Feed the decoder.
            while (true)
            {
                var read = ffmpeg.av_read_frame(format, packet);
                if (read < 0)
                {
                    endOfFile = true;
                    ffmpeg.avcodec_send_packet(codec, null);
                    break;
                }
                if (packet->stream_index == streamIndex)
                {
                    ffmpeg.avcodec_send_packet(codec, packet);
                    ffmpeg.av_packet_unref(packet);
                    break;
                }
                ffmpeg.av_packet_unref(packet);
            }
        }
    }

    /// <summary>Resamples and converts a decoded frame (or flushes the resampler with null) into <see cref="pending"/>.</summary>
    private void Convert(byte** input, int inputSamples)
    {
        var capacity = ffmpeg.swr_get_out_samples(resampler, inputSamples);
        if (capacity <= 0) { pendingCount = 0; pendingOffset = 0; return; }
        if (pending.Length < capacity * Channels) pending = new float[capacity * Channels];
        int converted;
        fixed (float* output = pending)
        {
            var outputs = stackalloc byte*[1];
            outputs[0] = (byte*)output;
            converted = ffmpeg.swr_convert(resampler, outputs, capacity, input, inputSamples);
        }
        pendingOffset = 0;
        pendingCount = Math.Max(converted, 0);
    }

    /// <summary>Moves to <paramref name="seconds"/> into the region (sample accurate).</summary>
    public void Seek(double seconds) => SeekToFrame(regionStart + Math.Max(0, (long)Math.Round(seconds * SampleRate)));

    /// <summary>
    /// Seeks the file to an output frame: to a point before it (a little earlier for lossy codecs, which need a few
    /// frames to warm up), then decodes up to it, trimming each decoded frame by its own timestamp.
    /// </summary>
    private void SeekToFrame(long target)
    {
        var preroll = needsPreroll ? SampleRate / 10 : 0;
        var from = Math.Max(0, target - preroll);
        var timestamp = (long)(from / (double)SampleRate * timeBase.den / timeBase.num);
        var stream = format->streams[streamIndex];
        if (stream->start_time != ffmpeg.AV_NOPTS_VALUE) timestamp += stream->start_time;
        ffmpeg.av_seek_frame(format, streamIndex, timestamp, ffmpeg.AVSEEK_FLAG_BACKWARD);
        ffmpeg.avcodec_flush_buffers(codec);
        ffmpeg.swr_init(resampler);
        endOfFile = flushed = false;
        pendingCount = pendingOffset = 0;
        position = target - regionStart;
        seekTarget = target;
    }

    /// <summary>Where the decoded frame starts, in output frames from the file's start (null without a timestamp).</summary>
    private long? FrameStart()
    {
        var pts = frame->best_effort_timestamp;
        if (pts == ffmpeg.AV_NOPTS_VALUE) return null;
        var stream = format->streams[streamIndex];
        if (stream->start_time != ffmpeg.AV_NOPTS_VALUE) pts -= stream->start_time;
        return (long)Math.Round(pts * timeBase.num / (double)timeBase.den * SampleRate);
    }

    /// <summary>After a seek, drops the converted samples that come before the target.</summary>
    private void TrimBeforeSeekTarget(long? start)
    {
        if (seekTarget is not { } target || pendingCount == 0) return;
        if (start is not { } at)
        {
            // No timestamp: nothing to place the samples by; hand them out from here.
            seekTarget = null;
            return;
        }
        var drop = (int)Math.Clamp(target - at, 0, pendingCount);
        pendingOffset += drop * Channels;
        pendingCount -= drop;
        if (pendingCount > 0) seekTarget = null;
    }

    public void Dispose()
    {
        if (frame is not null) { var f = frame; ffmpeg.av_frame_free(&f); frame = null; }
        if (packet is not null) { var p = packet; ffmpeg.av_packet_free(&p); packet = null; }
        if (resampler is not null) { var r = resampler; ffmpeg.swr_free(&r); resampler = null; }
        if (codec is not null) { var c = codec; ffmpeg.avcodec_free_context(&c); codec = null; }
        if (format is not null) { var f = format; ffmpeg.avformat_close_input(&f); format = null; }
    }
}

/// <summary>Finds FFmpeg's libraries: next to the app (Windows builds ship them in "ffmpeg"), else Homebrew's on a Mac.</summary>
public static class FFmpegLibraries
{
    private static readonly Lock gate = new();
    private static bool loaded;

    /// <summary>Set before first use to load the libraries from a given folder.</summary>
    public static string? Folder { get; set; }

    public static void EnsureLoaded()
    {
        lock (gate)
        {
            if (loaded) return;
            string?[] candidates =
            [
                Folder,
                Environment.GetEnvironmentVariable("GROOVELIGHT_FFMPEG"),
                Path.Combine(AppContext.BaseDirectory, "ffmpeg"),
                AppContext.BaseDirectory,
                "/opt/homebrew/lib",
                "/usr/local/lib",
            ];
            var folder = candidates.FirstOrDefault(path => path is not null && Directory.Exists(path)
                && Directory.EnumerateFiles(path, "*avcodec*").Any());
            if (folder is null) throw new AudioDecoderException("FFmpeg's libraries were not found.");
            ffmpeg.RootPath = folder;
            ffmpeg.av_log_set_level(ffmpeg.AV_LOG_ERROR);
            loaded = true;
        }
    }
}
