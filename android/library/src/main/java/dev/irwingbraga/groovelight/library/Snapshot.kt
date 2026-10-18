package dev.irwingbraga.groovelight.library

import android.util.JsonReader
import android.util.JsonToken
import java.io.InputStream
import java.io.InputStreamReader
import java.time.Instant

/**
 * The Mac's library snapshot (`DeviceSnapshot` on the Mac, version 1): read as a stream, since a large library's is
 * several megabytes.
 */
class Snapshot(val albums: List<Album>, val tracks: List<Track>, val playlists: List<Playlist>, val items: List<PlaylistItem>) {
    /** Every cover it refers to. */
    val artworkHashes: Set<String> get() = (albums.mapNotNull { it.artworkHash } + tracks.mapNotNull { it.artworkHash }).toSet()

    /** Replaces the device's library with this one. */
    suspend fun importInto(database: LibraryDatabase) = database.library().replace(albums, tracks, playlists, items)

    companion object {
        fun read(input: InputStream): Snapshot = JsonReader(InputStreamReader(input, Charsets.UTF_8)).use { reader ->
            val albums = mutableListOf<Album>()
            val tracks = mutableListOf<Track>()
            val playlists = mutableListOf<Playlist>()
            val items = mutableListOf<PlaylistItem>()
            reader.beginObject()
            while (reader.hasNext()) {
                when (reader.nextName()) {
                    "albums" -> reader.array { albums += album(reader) }
                    "songs" -> reader.array { tracks += song(reader) }
                    "playlists" -> reader.array {
                        val (playlist, songIds) = playlist(reader)
                        playlists += playlist
                        songIds.forEachIndexed { index, id -> items += PlaylistItem(playlist.id, index, id) }
                    }
                    "version" -> require(reader.nextInt() <= 1) { "This library comes from a newer Groovelight: update the app" }
                    else -> reader.skipValue()
                }
            }
            reader.endObject()
            // Songs whose album is missing (should not happen) would break the album link: dropped.
            val keys = albums.map { it.key }.toSet()
            val kept = tracks.filter { it.albumKey in keys }
            val ids = kept.map { it.id }.toSet()
            Snapshot(albums, kept, playlists, items.filter { it.trackId in ids })
        }

        private fun album(reader: JsonReader): Album {
            var key = ""; var title = ""; var artist = ""; var year: Int? = null; var compilation = false; var artwork: String? = null
            reader.obj { name ->
                when (name) {
                    "key" -> key = reader.nextString()
                    "title" -> title = reader.nextString()
                    "artist" -> artist = reader.nextString()
                    "year" -> year = reader.intOrNull()
                    "isCompilation" -> compilation = reader.nextBoolean()
                    "artworkHash" -> artwork = reader.stringOrNull()
                    else -> reader.skipValue()
                }
            }
            return Album(key, title, artist, year, compilation, artwork)
        }

        private fun song(reader: JsonReader): Track {
            var id = 0L; var path = ""; var title = ""; var artist = ""; var albumKey = ""; var disc: Int? = null; var number: Int? = null
            var genre: String? = null; var year: Int? = null; var duration = 0.0; var codec = ""; var rate: Int? = null; var bits: Int? = null
            var trackGain: Double? = null; var albumGain: Double? = null; var loudness: Double? = null; var loved = false; var lovedAt: Long? = null
            var rating = 0; var plays = 0; var lastPlayed: Long? = null; var added = 0L; var lyrics: String? = null; var artwork: String? = null
            reader.obj { name ->
                when (name) {
                    "id" -> id = reader.nextLong()
                    "path" -> path = reader.nextString()
                    "title" -> title = reader.nextString()
                    "artist" -> artist = reader.nextString()
                    "albumKey" -> albumKey = reader.nextString()
                    "discNumber" -> disc = reader.intOrNull()
                    "trackNumber" -> number = reader.intOrNull()
                    "genre" -> genre = reader.stringOrNull()
                    "year" -> year = reader.intOrNull()
                    "duration" -> duration = reader.nextDouble()
                    "codec" -> codec = reader.nextString()
                    "sampleRate" -> rate = reader.intOrNull()
                    "bitDepth" -> bits = reader.intOrNull()
                    "trackGain" -> trackGain = reader.doubleOrNull()
                    "albumGain" -> albumGain = reader.doubleOrNull()
                    "loudness" -> loudness = reader.doubleOrNull()
                    "loved" -> loved = reader.nextBoolean()
                    "lovedAt" -> lovedAt = reader.dateOrNull()
                    "rating" -> rating = reader.nextInt()
                    "playCount" -> plays = reader.nextInt()
                    "lastPlayed" -> lastPlayed = reader.dateOrNull()
                    "dateAdded" -> added = reader.dateOrNull() ?: 0
                    "lyrics" -> lyrics = reader.stringOrNull()
                    "artworkHash" -> artwork = reader.stringOrNull()
                    else -> reader.skipValue()
                }
            }
            return Track(id, title, artist, albumKey, disc, number, genre, year, (duration * 1000).toLong(), path, codec, rate, bits,
                trackGain, albumGain, loudness, loved, lovedAt, rating, plays, lastPlayed, added, lyrics, artwork)
        }

        private fun playlist(reader: JsonReader): Pair<Playlist, List<Long>> {
            var id = 0L; var name = ""; var smart = false; val songs = mutableListOf<Long>()
            reader.obj { field ->
                when (field) {
                    "id" -> id = reader.nextLong()
                    "name" -> name = reader.nextString()
                    "isSmart" -> smart = reader.nextBoolean()
                    "songIds" -> reader.array { songs += reader.nextLong() }
                    else -> reader.skipValue()
                }
            }
            return Playlist(id, name, smart) to songs
        }

        private inline fun JsonReader.array(each: () -> Unit) {
            beginArray()
            while (hasNext()) each()
            endArray()
        }

        private inline fun JsonReader.obj(each: (String) -> Unit) {
            beginObject()
            while (hasNext()) each(nextName())
            endObject()
        }

        private fun JsonReader.isNull(): Boolean = (peek() == JsonToken.NULL).also { if (it) nextNull() }
        private fun JsonReader.stringOrNull(): String? = if (isNull()) null else nextString()
        private fun JsonReader.intOrNull(): Int? = if (isNull()) null else nextInt()
        private fun JsonReader.doubleOrNull(): Double? = if (isNull()) null else nextDouble()
        /** ISO 8601 dates, as the Mac writes them. */
        private fun JsonReader.dateOrNull(): Long? = stringOrNull()?.let { runCatching { Instant.parse(it).toEpochMilli() }.getOrNull() }
    }
}
