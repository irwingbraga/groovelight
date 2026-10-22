package dev.irwingbraga.groovelight.sync

import android.content.Context
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import dev.irwingbraga.groovelight.library.ArtworkStore
import dev.irwingbraga.groovelight.library.Snapshot
import java.io.File
import java.security.MessageDigest

/** Album covers on the device: whether Android can show them, and the ones embedded in the songs as a fallback. */
object Covers {
    /** Whether Android's decoder reads the image (it cannot read CMYK JPEGs, which some scanned covers are). */
    fun decodes(image: ByteArray): Boolean =
        BitmapFactory.decodeByteArray(image, 0, image.size, BitmapFactory.Options().apply { inSampleSize = 8 }) != null

    fun decodes(file: File): Boolean = BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = 8 }) != null

    /**
     * Albums without a cover here (the Mac had none to send, or it could not be read) get the picture embedded in one of
     * their songs on the device, as other players show; their songs without a cover get it too.
     */
    fun fillFromFiles(context: Context, snapshot: Snapshot, artwork: ArtworkStore, tree: Uri): Snapshot {
        val missing = snapshot.albums.filter { album -> album.artworkHash?.let(artwork::has) != true }
        if (missing.isEmpty()) return snapshot
        val found = mutableMapOf<String, String>()
        for (album in missing) {
            val songs = snapshot.tracks.filter { it.albumKey == album.key }.sortedWith(compareBy({ it.discNumber ?: 1 }, { it.trackNumber ?: 0 }))
            for (song in songs.take(3)) {
                val image = embeddedPicture(context, DeviceFolder.documentUri(tree, song.path))?.takeIf(::decodes) ?: continue
                val hash = "embedded-" + MessageDigest.getInstance("SHA-256").digest(image).take(16).joinToString("") { "%02x".format(it) }
                if (!artwork.has(hash)) artwork.save(hash, image)
                found[album.key] = hash
                break
            }
        }
        if (found.isEmpty()) return snapshot
        return snapshot.copy(
            albums = snapshot.albums.map { album -> found[album.key]?.let { album.copy(artworkHash = it) } ?: album },
            tracks = snapshot.tracks.map { track ->
                val hash = found[track.albumKey]
                if (hash != null && track.artworkHash?.let(artwork::has) != true) track.copy(artworkHash = hash) else track
            },
        )
    }

    private fun embeddedPicture(context: Context, uri: Uri): ByteArray? = runCatching {
        MediaMetadataRetriever().run {
            try {
                setDataSource(context, uri)
                embeddedPicture
            } finally {
                release()
            }
        }
    }.getOrNull()
}
