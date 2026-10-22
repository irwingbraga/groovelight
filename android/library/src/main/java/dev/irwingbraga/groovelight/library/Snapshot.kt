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
data class Snapshot(
    val albums: List<Album>,
    val tracks: List<Track>,
    val playlists: List<Playlist>,
    val items: List<PlaylistItem>,
    val credits: List<Credit> = emptyList(),
    val equalizer: List<MacEqPreset> = emptyList(),
    /** The artists' photos (null from a Mac that sends none). */
    val artists: List<ArtistPhoto>? = null,
) {
    /** Every cover (and artist photo) it refers to. */
    val artworkHashes: Set<String> get() =
        (albums.mapNotNull { it.artworkHash } + tracks.mapNotNull { it.artworkHash } + playlists.mapNotNull { it.coverHash } +
            artists.orEmpty().map { it.artworkHash }).toSet()

    /** Replaces the device's library with this one. */
    suspend fun importInto(database: LibraryDatabase) = database.library().replace(this)

    /** The search index rows: each song's words, with the names credited on it (or on its whole album). */
    fun searchEntries(): List<SearchEntry> {
        val albumTitles = albums.associate { it.key to it.title }
        val albumCredits = credits.filter { it.trackId == null }.groupBy { it.albumKey }
        val songCredits = credits.filter { it.trackId != null }.groupBy { it.trackId }
        return tracks.map { track ->
            val names = (albumCredits[track.albumKey].orEmpty() + songCredits[track.id].orEmpty()).map { it.name }.distinct()
            SearchEntry(track.id, track.title, track.artist, albumTitles[track.albumKey].orEmpty(), names.joinToString(" "))
        }
    }

    companion object {
        fun read(input: InputStream): Snapshot = JsonReader(InputStreamReader(input, Charsets.UTF_8)).use { reader ->
            val albums = mutableListOf<Album>()
            val tracks = mutableListOf<Track>()
            val playlists = mutableListOf<Playlist>()
            val items = mutableListOf<PlaylistItem>()
            val credits = mutableListOf<Credit>()
            val equalizer = mutableListOf<MacEqPreset>()
            var artists: List<ArtistPhoto>? = null
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
                    "credits" -> if (!reader.isNull()) reader.array { credits += credit(reader) }
                    "equalizer" -> if (!reader.isNull()) equalizer += equalizer(reader)
                    "artists" -> if (!reader.isNull()) artists = buildList { reader.array { add(artistPhoto(reader)) } }
                    "version" -> require(reader.nextInt() <= 1) { "This library comes from a newer Groovelight: update the app" }
                    else -> reader.skipValue()
                }
            }
            reader.endObject()
            // Songs whose album is missing (should not happen) would break the album link: dropped.
            val keys = albums.map { it.key }.toSet()
            val kept = tracks.filter { it.albumKey in keys }
            val ids = kept.map { it.id }.toSet()
            Snapshot(albums, kept, playlists, items.filter { it.trackId in ids },
                credits.filter { it.albumKey in keys && (it.trackId == null || it.trackId in ids) }, equalizer, artists)
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

        private fun artistPhoto(reader: JsonReader): ArtistPhoto {
            var name = ""; var hash = ""
            reader.obj { field ->
                when (field) {
                    "name" -> name = reader.nextString()
                    "artworkHash" -> hash = reader.nextString()
                    else -> reader.skipValue()
                }
            }
            return ArtistPhoto(name, hash)
        }

        private fun credit(reader: JsonReader): Credit {
            var name = ""; val roles = mutableListOf<String>(); var albumKey = ""; var trackId: Long? = null; var whole = false
            reader.obj { field ->
                when (field) {
                    "name" -> name = reader.nextString()
                    "roles" -> reader.array { roles += reader.nextString() }
                    "albumKey" -> albumKey = reader.nextString()
                    "trackId" -> trackId = if (reader.isNull()) null else reader.nextLong()
                    "wholeRelease" -> whole = reader.nextBoolean()
                    else -> reader.skipValue()
                }
            }
            return Credit(name = name, roles = roles.joinToString("\n"), albumKey = albumKey, trackId = trackId, wholeRelease = whole)
        }

        /** The Mac's saved presets and its current curve (bands kept as JSON, read by the player's equalizer). */
        private fun equalizer(reader: JsonReader): List<MacEqPreset> {
            val presets = mutableListOf<MacEqPreset>(); var current: MacEqPreset? = null; var enabled = false
            reader.obj { field ->
                when (field) {
                    "presets" -> reader.array { presets += eqPreset(reader, isCurrent = false) }
                    "current" -> current = if (reader.isNull()) null else eqPreset(reader, isCurrent = true)
                    "isEnabled" -> enabled = reader.nextBoolean()
                    else -> reader.skipValue()
                }
            }
            return presets.distinctBy { it.name } + listOfNotNull(current?.copy(enabled = enabled))
        }

        private fun eqPreset(reader: JsonReader, isCurrent: Boolean): MacEqPreset {
            var name = ""; var preamp = 0.0; val bands = org.json.JSONArray()
            reader.obj { field ->
                when (field) {
                    "name" -> name = reader.nextString()
                    "preamp" -> preamp = reader.nextDouble()
                    "bands" -> reader.array {
                        val band = org.json.JSONObject()
                        reader.obj { key ->
                            when (key) {
                                "isEnabled" -> band.put(key, reader.nextBoolean())
                                "type" -> band.put(key, reader.nextString())
                                "frequency", "gain", "q" -> band.put(key, reader.nextDouble())
                                else -> reader.skipValue()
                            }
                        }
                        bands.put(band)
                    }
                    else -> reader.skipValue()
                }
            }
            return MacEqPreset(name, isCurrent, preamp, bands.toString())
        }

        private fun playlist(reader: JsonReader): Pair<Playlist, List<Long>> {
            var playlist = Playlist(0, ""); val songs = mutableListOf<Long>()
            reader.obj { field ->
                when (field) {
                    "id" -> playlist = playlist.copy(id = reader.nextLong())
                    "name" -> playlist = playlist.copy(name = reader.nextString())
                    "isSmart" -> playlist = playlist.copy(isSmart = reader.nextBoolean())
                    "songIds" -> reader.array { songs += reader.nextLong() }
                    "rules" -> if (!reader.isNull()) playlist = playlist.copy(smartRules = SmartRules.read(reader).toJson())
                    "cover" -> if (!reader.isNull()) reader.obj { key ->
                        when (key) {
                            "style" -> playlist = playlist.copy(coverStyle = reader.nextString())
                            "palette" -> playlist = playlist.copy(coverPalette = reader.stringOrNull())
                            "pattern" -> playlist = playlist.copy(coverPattern = reader.stringOrNull())
                            "imageHash" -> playlist = playlist.copy(coverHash = reader.stringOrNull())
                            "showsTitle" -> playlist = playlist.copy(coverShowsTitle = reader.nextBoolean())
                            else -> reader.skipValue()
                        }
                    }
                    else -> reader.skipValue()
                }
            }
            return playlist to songs
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
