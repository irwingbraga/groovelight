package dev.irwingbraga.groovelight.playback

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.Player
import androidx.media3.common.Tracks
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.audio.AudioSink
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** What happens to the sound of the song playing: the file's format, the decoder, and what goes to Android's mixer. */
data class AudioPath(
    /** "FLAC, 24-bit, 96 kHz, stereo". */
    val source: String? = null,
    /** "c2.android.flac.decoder". */
    val decoder: String? = null,
    /** "32-bit float, 96 kHz, stereo" (what the player hands to Android's audio output). */
    val output: String? = null,
    /** Compressed audio handed to the hardware as is (offload), which saves battery. */
    val offloaded: Boolean = false,
    /** The song's audio cannot be decoded on this device ("ALAC, 24-bit, 96 kHz"): playback pauses instead of playing
     *  silence. */
    val unsupported: String? = null,
    internal val sourceMime: String? = null,
)

/**
 * Collects [AudioPath] from the player as songs start. Phase 0 shows it in Now Playing to check which formats each
 * device plays and how; the quality badge (phase 2) builds on it.
 */
@OptIn(UnstableApi::class)
object AudioPathReport {
    private val state = MutableStateFlow(AudioPath())
    val current: StateFlow<AudioPath> = state.asStateFlow()

    /** Each song's tracks: what the file holds, and whether this device can decode it. */
    internal fun playerListener(player: Player) = object : Player.Listener {
        // A new song: nothing is known about it until its tracks are read (a file that cannot be read has none). The
        // decoder and output are kept for the same kind of file, as the player reuses them.
        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            state.value = state.value.copy(source = null, unsupported = null)
        }

        override fun onTracksChanged(tracks: Tracks) {
            val audio = tracks.groups.firstOrNull { it.type == C.TRACK_TYPE_AUDIO } ?: return
            val format = audio.getTrackFormat(0)
            val previous = state.value
            // A new kind of file: the previous decoder and output no longer apply (until the player reports them).
            val sameKind = previous.sourceMime == format.sampleMimeType
            state.value = AudioPath(
                source = describe(format),
                decoder = if (format.sampleMimeType == MimeTypes.AUDIO_RAW) "None (PCM)" else if (sameKind) previous.decoder else null,
                output = if (sameKind) previous.output else null,
                offloaded = sameKind && previous.offloaded,
                unsupported = if (audio.isSupported) null else describe(format),
                sourceMime = format.sampleMimeType,
            )
            if (!audio.isSupported) player.pause()
        }
    }

    internal val listener = object : AnalyticsListener {
        override fun onAudioInputFormatChanged(eventTime: AnalyticsListener.EventTime, format: Format, decoderReuseEvaluation: DecoderReuseEvaluation?) {
            state.value = state.value.copy(source = describe(format), sourceMime = format.sampleMimeType)
        }

        override fun onAudioDecoderInitialized(eventTime: AnalyticsListener.EventTime, decoderName: String, initializedTimestampMs: Long,
                                               initializationDurationMs: Long) {
            state.value = state.value.copy(decoder = decoderName)
        }

        override fun onAudioTrackInitialized(eventTime: AnalyticsListener.EventTime, audioTrackConfig: AudioSink.AudioTrackConfig) {
            val channels = Integer.bitCount(audioTrackConfig.channelConfig)
            state.value = state.value.copy(
                output = listOfNotNull(encoding(audioTrackConfig.encoding), rate(audioTrackConfig.sampleRate), channelNames(channels)).joinToString(", "),
                offloaded = audioTrackConfig.offload,
            )
        }
    }

    fun describe(format: Format): String {
        val codec = when (format.sampleMimeType) {
            MimeTypes.AUDIO_FLAC -> "FLAC"
            MimeTypes.AUDIO_ALAC -> "ALAC"
            MimeTypes.AUDIO_MPEG -> "MP3"
            MimeTypes.AUDIO_AAC -> "AAC"
            MimeTypes.AUDIO_OPUS -> "Opus"
            MimeTypes.AUDIO_VORBIS -> "Vorbis"
            MimeTypes.AUDIO_RAW -> "PCM"
            else -> format.sampleMimeType ?: format.codecs ?: "Unknown"
        }
        val bits = if (format.pcmEncoding != Format.NO_VALUE) encoding(format.pcmEncoding) else null
        val bitrate = if (format.bitrate != Format.NO_VALUE && bits == null) "${format.bitrate / 1000} kbps" else null
        return listOfNotNull(codec, bits, bitrate, rate(format.sampleRate), channelNames(format.channelCount)).joinToString(", ")
    }

    private fun encoding(encoding: Int): String? = when (encoding) {
        C.ENCODING_PCM_8BIT -> "8-bit"
        C.ENCODING_PCM_16BIT, C.ENCODING_PCM_16BIT_BIG_ENDIAN -> "16-bit"
        C.ENCODING_PCM_24BIT, C.ENCODING_PCM_24BIT_BIG_ENDIAN -> "24-bit"
        C.ENCODING_PCM_32BIT, C.ENCODING_PCM_32BIT_BIG_ENDIAN -> "32-bit"
        C.ENCODING_PCM_FLOAT -> "32-bit float"
        Format.NO_VALUE, C.ENCODING_INVALID -> null
        else -> "compressed"
    }

    private fun rate(hz: Int): String? = if (hz <= 0) null else if (hz % 1000 == 0) "${hz / 1000} kHz" else "%.1f kHz".format(hz / 1000.0)

    private fun channelNames(count: Int): String? = when (count) {
        Format.NO_VALUE, 0 -> null
        1 -> "mono"
        2 -> "stereo"
        else -> "$count channels"
    }
}
