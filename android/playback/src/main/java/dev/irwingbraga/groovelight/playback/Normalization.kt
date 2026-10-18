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

    fun extras(gain: Double?): Bundle = Bundle().apply { if (gain != null) putDouble(GAIN, gain) }

    fun volume(item: MediaItem?): Float {
        val extras = item?.mediaMetadata?.extras ?: return 1f
        if (!extras.containsKey(GAIN)) return 1f
        return 10.0.pow(extras.getDouble(GAIN) / 20).toFloat().coerceIn(0f, 1f)
    }

    internal fun listener(player: Player) = object : Player.Listener {
        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            player.volume = volume(mediaItem)
        }
    }
}
