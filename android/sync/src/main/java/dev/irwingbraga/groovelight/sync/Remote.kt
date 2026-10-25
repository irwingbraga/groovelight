package dev.irwingbraga.groovelight.sync

import org.json.JSONArray
import org.json.JSONObject

/**
 * The Mac's player as `GET /remote` and `POST /remote` describe it, for playing music on the Mac from this device:
 * what plays, where it is (as of the answer: moved on with this device's clock), and the queue's song ids, to take it
 * over here. `version` changes when anything but the steady progress of the song changes.
 */
data class RemoteState(
    val item: Item?,
    val playing: Boolean,
    val positionSeconds: Double,
    val rate: Double,
    val volume: Double,
    val shuffle: Boolean,
    val repeatMode: String,
    val queue: List<Long>,
    val queueIndex: Int?,
    val version: String,
) {
    data class Item(
        val id: Long,
        val title: String,
        val artist: String,
        val album: String,
        val albumKey: String?,
        val artworkHash: String?,
        val durationSeconds: Double,
    )

    /** As the Mac reads it (`POST /relay/state`): this device's player for the devices following it. */
    fun toJson(): JSONObject = JSONObject()
        .put("item", item?.let {
            JSONObject().put("id", it.id).put("title", it.title).put("artist", it.artist).put("album", it.album)
                .put("albumKey", it.albumKey ?: JSONObject.NULL).put("artworkHash", it.artworkHash ?: JSONObject.NULL)
                .put("duration", it.durationSeconds)
        } ?: JSONObject.NULL)
        .put("playing", playing).put("position", positionSeconds).put("rate", rate).put("volume", volume).put("shuffle", shuffle)
        .put("repeatMode", repeatMode).put("queue", JSONArray(queue)).put("queueIndex", queueIndex ?: JSONObject.NULL)
        .put("version", version)

    companion object {
        fun from(json: JSONObject): RemoteState {
            val item = json.optJSONObject("item")?.let {
                Item(
                    id = it.getLong("id"),
                    title = it.optString("title"),
                    artist = it.optString("artist"),
                    album = it.optString("album"),
                    albumKey = it.optString("albumKey").takeIf { key -> it.has("albumKey") && !it.isNull("albumKey") && key.isNotEmpty() },
                    artworkHash = it.optString("artworkHash").takeIf { hash -> it.has("artworkHash") && !it.isNull("artworkHash") && hash.isNotEmpty() },
                    durationSeconds = it.optDouble("duration", 0.0),
                )
            }
            val queue = json.optJSONArray("queue") ?: JSONArray()
            return RemoteState(
                item = item,
                playing = json.optBoolean("playing"),
                positionSeconds = json.optDouble("position", 0.0),
                rate = json.optDouble("rate", 1.0),
                volume = json.optDouble("volume", 1.0),
                shuffle = json.optBoolean("shuffle"),
                repeatMode = json.optString("repeatMode", "off"),
                queue = (0 until queue.length()).map { queue.getLong(it) },
                queueIndex = if (json.has("queueIndex") && !json.isNull("queueIndex")) json.getInt("queueIndex") else null,
                version = json.optString("version"),
            )
        }
    }
}

/** Another device music can play on, through the Mac (`GET /remote/devices`). */
data class RemoteDevice(val id: String, val name: String) {
    companion object {
        fun from(json: JSONObject) = RemoteDevice(json.getString("id"), json.optString("name", "Device"))
    }
}

/** What `POST /remote` takes: flat objects, as the Mac's `WirelessProtocol.RemoteCommand` reads them. */
object RemoteCommand {
    fun play(songIds: List<Long>, startAt: Int, positionSeconds: Double, shuffle: Boolean = false): JSONObject = JSONObject()
        .put("command", "play").put("songIds", JSONArray(songIds)).put("startAt", startAt).put("position", positionSeconds).put("shuffle", shuffle)
    fun pause(): JSONObject = simple("pause")
    fun resume(): JSONObject = simple("resume")
    fun next(): JSONObject = simple("next")
    fun previous(): JSONObject = simple("previous")
    fun stop(): JSONObject = simple("stop")
    fun seek(seconds: Double): JSONObject = simple("seek").put("position", seconds)
    fun volume(volume: Double): JSONObject = simple("volume").put("volume", volume)
    fun shuffle(on: Boolean): JSONObject = simple("shuffle").put("on", on)
    /** "off", "all" or "one". */
    fun repeatMode(mode: String): JSONObject = simple("repeatMode").put("mode", mode)

    private fun simple(command: String) = JSONObject().put("command", command)
}
