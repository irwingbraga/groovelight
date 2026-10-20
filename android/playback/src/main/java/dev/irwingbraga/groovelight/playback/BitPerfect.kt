package dev.irwingbraga.groovelight.playback

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioMixerAttributes
import android.os.Build
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.media3.common.C

/**
 * Bit-perfect output to a USB DAC (Android 14 and later): before a song's audio goes out, the DAC's mixer is asked to
 * take its exact format, so Android neither resamples nor mixes it (no other sounds, no volume change). It only happens
 * when the DAC offers that format bit-perfect; otherwise the song plays through the normal mixer.
 *
 * The format sent is the decoder's: 16-bit songs as 16-bit, hi-res ones as 32-bit float (which holds 24 bits exactly).
 */
class BitPerfect(context: Context) {
    private val audio = context.getSystemService(AudioManager::class.java)
    private var preferred: AudioDeviceInfo? = null

    /** The USB DAC connected, if any. */
    private fun usbDevice(): AudioDeviceInfo? = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull {
        it.type == AudioDeviceInfo.TYPE_USB_DEVICE || it.type == AudioDeviceInfo.TYPE_USB_HEADSET
    }

    /**
     * Prepares the output for a stream (`encoding` as Media3 will write it), and says whether it goes out bit-perfect.
     * Called on the playback thread when a stream is configured.
     */
    fun prepare(sampleRate: Int, channels: Int, encoding: Int): Boolean {
        val active = Build.VERSION.SDK_INT >= 34 && PlaybackSettings.bitPerfectWanted && runCatching { engage(sampleRate, channels, encoding) }
            .onFailure { Log.w(TAG, "Bit-perfect output failed", it) }.getOrDefault(false)
        if (!active) release()
        PlaybackSettings.setBitPerfectActive(active)
        return active
    }

    @RequiresApi(34)
    private fun engage(sampleRate: Int, channels: Int, encoding: Int): Boolean {
        val device = usbDevice() ?: return false
        val platformEncoding = when (encoding) {
            C.ENCODING_PCM_16BIT -> AudioFormat.ENCODING_PCM_16BIT
            C.ENCODING_PCM_FLOAT -> AudioFormat.ENCODING_PCM_FLOAT
            C.ENCODING_PCM_24BIT -> AudioFormat.ENCODING_PCM_24BIT_PACKED
            C.ENCODING_PCM_32BIT -> AudioFormat.ENCODING_PCM_32BIT
            else -> return false
        }
        val mask = if (channels == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
        val match = audio.getSupportedMixerAttributes(device).firstOrNull {
            it.mixerBehavior == AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT && it.format.sampleRate == sampleRate &&
                it.format.encoding == platformEncoding && it.format.channelMask == mask
        } ?: return false
        if (audio.getPreferredMixerAttributes(MUSIC, device) != match && !audio.setPreferredMixerAttributes(MUSIC, device, match)) return false
        preferred = device
        return true
    }

    /** Back to the normal mixer (another format, the setting turned off, or the service stopping). */
    fun release() {
        val device = preferred ?: return
        preferred = null
        if (Build.VERSION.SDK_INT >= 34) runCatching { audio.clearPreferredMixerAttributes(MUSIC, device) }
    }

    private companion object {
        const val TAG = "BitPerfect"
        val MUSIC: AudioAttributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build()
    }
}
