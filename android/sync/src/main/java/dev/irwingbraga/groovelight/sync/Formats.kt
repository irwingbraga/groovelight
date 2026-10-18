package dev.irwingbraga.groovelight.sync

import android.media.MediaCodecList

/**
 * What this device can play, as the Mac names formats (`AudioSpec.Codec`): sent in Player mode, so the Mac converts the
 * rest to FLAC. Decoders come from Android's codec list (ALAC, for one, is missing on many devices); WAV needs none.
 * AIFF and WavPack are never listed: the player cannot read their files.
 */
object Formats {
    private val decoders = mapOf(
        "flac" to "audio/flac",
        "alac" to "audio/alac",
        "mp3" to "audio/mpeg",
        "aac" to "audio/mp4a-latm",
        "opus" to "audio/opus",
        "vorbis" to "audio/vorbis",
    )

    fun decodable(): List<String> {
        val available = MediaCodecList(MediaCodecList.ALL_CODECS).codecInfos.filter { !it.isEncoder }
            .flatMap { it.supportedTypes.map(String::lowercase) }.toSet()
        return decoders.filterValues { it in available }.keys.sorted() + "wav"
    }
}
