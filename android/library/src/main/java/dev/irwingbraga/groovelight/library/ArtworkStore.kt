package dev.irwingbraga.groovelight.library

import android.content.Context
import java.io.File

/** Covers from the Mac (600 pixels, JPEG), by content hash, in the app's own storage. */
class ArtworkStore(context: Context) {
    val folder = File(context.filesDir, "artwork").apply { mkdirs() }

    fun file(hash: String): File = File(folder, "$hash.jpg")

    fun has(hash: String): Boolean = file(hash).length() > 0

    /** Saves a cover (written beside, then renamed, so a cover is never half there). */
    fun save(hash: String, data: ByteArray) {
        val partial = File(folder, ".$hash.partial")
        partial.writeBytes(data)
        partial.renameTo(file(hash))
    }

    /** Removes covers no song or album uses any more. */
    fun prune(keeping: Set<String>) {
        folder.listFiles()?.filter { it.extension == "jpg" && it.nameWithoutExtension !in keeping }?.forEach { it.delete() }
    }
}
