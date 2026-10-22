package dev.irwingbraga.groovelight.app

import android.content.Context
import android.net.Uri
import androidx.core.net.toUri
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import dev.irwingbraga.groovelight.library.Album
import dev.irwingbraga.groovelight.library.ArtworkStore
import dev.irwingbraga.groovelight.library.Track
import dev.irwingbraga.groovelight.playback.Normalization
import dev.irwingbraga.groovelight.sync.DeviceFolder
import dev.irwingbraga.groovelight.sync.Prefs
import dev.irwingbraga.groovelight.ui.PlayerModel

/**
 * The songs as player items: their file in the music folder (no listing needed), what the Mac knows about them (the
 * files' own tags are not read), the cover, the normalization gain, and `source` (where they are played from, as Now
 * Playing shows it). For the screens, the widgets and Android Auto alike. Empty without a music folder.
 */
fun playerItems(context: Context, tracks: List<Track>, albums: Map<String, Album>, source: String? = null): List<MediaItem> {
    val tree = Prefs(context).folder?.toUri() ?: return emptyList()
    val artwork = ArtworkStore(context)
    return tracks.map { track ->
        val album = albums[track.albumKey]
        val extras = Normalization.extras(track.normalizationGain, track.albumGain).apply {
            putString(PlayerModel.ALBUM_KEY, track.albumKey)
            if (source != null) putString(PlayerModel.SOURCE, source)
        }
        val metadata = MediaMetadata.Builder()
            .setTitle(track.title)
            .setArtist(track.artist)
            .setAlbumTitle(album?.title)
            .setAlbumArtist(album?.artist)
            .setTrackNumber(track.trackNumber)
            .setDiscNumber(track.discNumber)
            .setDurationMs(track.durationMs)
            .setArtworkUri(track.artworkHash?.let { artwork.file(it) }?.takeIf { it.exists() }?.let(Uri::fromFile))
            .setIsPlayable(true)
            .setIsBrowsable(false)
            .setExtras(extras)
            .build()
        MediaItem.Builder()
            .setMediaId(track.id.toString())
            .setUri(DeviceFolder.documentUri(tree, track.path))
            .setMediaMetadata(metadata)
            .build()
    }
}
