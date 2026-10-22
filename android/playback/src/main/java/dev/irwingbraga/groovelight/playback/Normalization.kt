package dev.irwingbraga.groovelight.playback

import android.os.Bundle
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import kotlin.math.pow

/**
 * Volume normalization, as the Mac's Sound Check: each song plays at the gain its item carries ([GAIN], in dB, from
 * ReplayGain or the Mac's loudness measurement). Applied as the player's volume when the song starts, which follows
 * gapless transitions exactly; gains above 0 dB are capped there (most songs need less, not more).
 */
object Normalization {
    /** Extra of a media item's metadata: its gain in dB. */
    const val GAIN = "dev.irwingbraga.groovelight.gain"
    /** Its album's ReplayGain (dB), for the Album setting. */
    const val ALBUM_GAIN = "dev.irwingbraga.groovelight.albumGain"

    fun extras(gain: Double?, albumGain: Double? = null): Bundle = Bundle().apply {
        if (gain != null) putDouble(GAIN, gain)
        if (albumGain != null) putDouble(ALBUM_GAIN, albumGain)
    }

    /** The gain applied to an item (dB) with the current setting, or null for none. */
    fun gain(item: MediaItem?, mode: PlaybackSettings.Normalization = PlaybackSettings.normalization.value): Double? {
        val extras = item?.mediaMetadata?.extras ?: return null
        return when (mode) {
            PlaybackSettings.Normalization.OFF -> null
            // Album gain when the song has one, else its own (as Sound Check falls back on the Mac).
            PlaybackSettings.Normalization.ALBUM -> if (extras.containsKey(ALBUM_GAIN)) extras.getDouble(ALBUM_GAIN) else gainOf(extras)
            PlaybackSettings.Normalization.TRACK -> gainOf(extras)
        }
    }

    private fun gainOf(extras: Bundle): Double? = if (extras.containsKey(GAIN)) extras.getDouble(GAIN) else null

    fun volume(item: MediaItem?): Float {
        // Bit-perfect output takes the samples as they are.
        if (PlaybackSettings.bitPerfectActive.value) return 1f
        val gain = gain(item) ?: return 1f
        return 10.0.pow(gain / 20).toFloat().coerceIn(0f, 1f)
    }

    /** Sets the player's volume when its song changes (`level`: a crossfade's, which multiplies the gain). */
    internal fun listener(player: Player, level: (Player) -> Float = { 1f }) = object : Player.Listener {
        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            player.volume = volume(mediaItem) * level(player)
        }
    }
}
