package dev.irwingbraga.groovelight.sync

import android.content.Context
import android.content.Intent
import android.os.StatFs
import android.os.storage.StorageManager
import android.os.storage.StorageVolume
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** The device's storage: internal memory and SD cards (or USB drives), from Android's own list of volumes. */
object Storage {
    data class Volume(val name: String, val isRemovable: Boolean, val total: Long, val free: Long, val directory: File?,
                      val holdsMusic: Boolean)

    /** Mounted volumes; `musicRootId` (the picked folder's document id, "primary:Music" or "1234-5678:Music") marks
     *  the one holding the music. */
    fun volumes(context: Context, musicRootId: String?): List<Volume> {
        val manager = context.getSystemService(StorageManager::class.java)
        return manager.storageVolumes.filter { it.state == android.os.Environment.MEDIA_MOUNTED }.map { volume ->
            val directory = volume.directory
            val stats = directory?.let { runCatching { StatFs(it.path) }.getOrNull() }
            Volume(
                name = volume.getDescription(context) ?: if (volume.isRemovable) "SD card" else "Internal storage",
                isRemovable = volume.isRemovable,
                total = stats?.totalBytes ?: 0,
                free = stats?.availableBytes ?: 0,
                directory = directory,
                holdsMusic = musicRootId != null && matches(volume, musicRootId),
            )
        }
    }

    /** The volume a picked folder is on. */
    fun volume(context: Context, rootId: String): Volume? = volumes(context, rootId).firstOrNull { it.holdsMusic }

    private fun matches(volume: StorageVolume, rootId: String): Boolean {
        val id = rootId.substringBefore(':')
        return if (id == "primary") volume.isPrimary else volume.uuid.equals(id, ignoreCase = true)
    }

    /** Opens the folder picker on the first SD card, or nil when there is none. */
    fun sdCardPicker(context: Context): Intent? {
        val manager = context.getSystemService(StorageManager::class.java)
        return manager.storageVolumes.firstOrNull { it.isRemovable && it.state == android.os.Environment.MEDIA_MOUNTED }
            ?.createOpenDocumentTreeIntent()
    }

    fun json(volumes: List<Volume>): JSONArray = JSONArray(volumes.map { volume ->
        JSONObject().put("name", volume.name).put("removable", volume.isRemovable).put("total", volume.total)
            .put("free", volume.free).put("music", volume.holdsMusic)
    })
}
