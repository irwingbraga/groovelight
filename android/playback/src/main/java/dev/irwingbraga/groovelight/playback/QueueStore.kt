package dev.irwingbraga.groovelight.playback

import android.content.Context
import android.os.Bundle
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

/**
 * The queue as it was (songs, the one playing, where in it, repeat), saved after each change and while playing, so the
 * app opens where it was left and Bluetooth's play button (media resumption) picks it up after a restart.
 * Items keep what the screens gave them: uri, tags, cover, and the extras of their metadata (numbers and text).
 */
class QueueStore(context: Context) {
    data class Saved(val items: List<MediaItem>, val index: Int, val positionMs: Long, val repeatMode: Int)

    private val file = File(context.filesDir, "queue.json")
    private val writer = Executors.newSingleThreadExecutor()

    /** Saves the player's queue (read here, on the player's thread; written on another). */
    fun save(player: Player) {
        val items = (0 until player.mediaItemCount).map { player.getMediaItemAt(it) }
        val index = player.currentMediaItemIndex
        val position = player.currentPosition
        val repeat = player.repeatMode
        writer.execute {
            if (items.isEmpty()) {
                file.delete()
                return@execute
            }
            val json = JSONObject()
                .put("index", index)
                .put("position", position)
                .put("repeat", repeat)
                .put("items", JSONArray(items.map(::encode)))
            val temporary = File(file.parentFile, "${file.name}.tmp")
            temporary.writeText(json.toString())
            temporary.renameTo(file)
        }
    }

    fun load(): Saved? = runCatching {
        val json = JSONObject(file.readText())
        val array = json.getJSONArray("items")
        val items = (0 until array.length()).map { decode(array.getJSONObject(it)) }
        if (items.isEmpty()) return null
        Saved(items, json.optInt("index").coerceIn(0, items.lastIndex), json.optLong("position"), json.optInt("repeat", Player.REPEAT_MODE_OFF))
    }.getOrNull()

    private fun encode(item: MediaItem): JSONObject {
        val metadata = item.mediaMetadata
        val extras = JSONObject()
        metadata.extras?.let { bundle ->
            for (key in bundle.keySet()) {
                @Suppress("DEPRECATION")
                when (val value = bundle.get(key)) {
                    is Double, is Long, is Int -> extras.put(key, JSONObject().put("n", (value as Number).toDouble()).put("type", value.javaClass.simpleName))
                    is String -> extras.put(key, JSONObject().put("s", value))
                }
            }
        }
        return JSONObject()
            .put("id", item.mediaId)
            .put("uri", item.localConfiguration?.uri?.toString())
            .putOpt("title", metadata.title?.toString())
            .putOpt("artist", metadata.artist?.toString())
            .putOpt("album", metadata.albumTitle?.toString())
            .putOpt("albumArtist", metadata.albumArtist?.toString())
            .putOpt("track", metadata.trackNumber)
            .putOpt("disc", metadata.discNumber)
            .putOpt("duration", metadata.durationMs)
            .putOpt("artwork", metadata.artworkUri?.toString())
            .put("extras", extras)
    }

    private fun decode(json: JSONObject): MediaItem {
        val extras = Bundle()
        json.optJSONObject("extras")?.let { stored ->
            for (key in stored.keys()) {
                val value = stored.getJSONObject(key)
                when {
                    value.has("s") -> extras.putString(key, value.getString("s"))
                    value.optString("type") == "Long" -> extras.putLong(key, value.getDouble("n").toLong())
                    value.optString("type") == "Integer" -> extras.putInt(key, value.getDouble("n").toInt())
                    else -> extras.putDouble(key, value.getDouble("n"))
                }
            }
        }
        val metadata = MediaMetadata.Builder()
            .setTitle(json.optString("title").ifEmpty { null })
            .setArtist(json.optString("artist").ifEmpty { null })
            .setAlbumTitle(json.optString("album").ifEmpty { null })
            .setAlbumArtist(json.optString("albumArtist").ifEmpty { null })
            .setTrackNumber(if (json.has("track")) json.getInt("track") else null)
            .setDiscNumber(if (json.has("disc")) json.getInt("disc") else null)
            .setDurationMs(if (json.has("duration")) json.getLong("duration") else null)
            .setArtworkUri(json.optString("artwork").ifEmpty { null }?.let(Uri::parse))
            .setExtras(extras)
            .build()
        return MediaItem.Builder()
            .setMediaId(json.getString("id"))
            .setUri(json.optString("uri").ifEmpty { null }?.let(Uri::parse))
            .setMediaMetadata(metadata)
            .build()
    }
}
