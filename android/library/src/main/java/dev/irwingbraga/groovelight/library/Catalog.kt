package dev.irwingbraga.groovelight.library

import android.util.JsonReader
import android.util.JsonToken
import java.io.InputStream
import java.io.InputStreamReader

/** The Mac's whole library (`DeviceCatalog` on the Mac), read as a stream: a large library's is several megabytes. */
class Catalog(val albums: List<CatalogAlbum>, val tracks: List<CatalogTrack>, val choice: Choice, val encoding: String? = null,
              val artists: List<CatalogArtistPhoto> = emptyList()) {
    suspend fun importInto(database: LibraryDatabase) = database.catalog().replace(albums, tracks, choice.rows(), artists)

    companion object {
        /** What this reader keeps (2: artists' photos): a catalog read by an older one is fetched whole again. */
        const val READER = 2

        fun read(input: InputStream): Catalog = JsonReader(InputStreamReader(input, Charsets.UTF_8)).use { reader ->
            val albums = mutableListOf<CatalogAlbum>()
            val tracks = mutableListOf<CatalogTrack>()
            var choice = Choice()
            var encoding: String? = null
            val artists = mutableListOf<CatalogArtistPhoto>()
            reader.beginObject()
            while (reader.hasNext()) {
                when (reader.nextName()) {
                    "albums" -> reader.array { albums += album(reader) }
                    "songs" -> reader.array { tracks += song(reader) }
                    "chosen" -> choice = Choice.read(reader)
                    "encoding" -> encoding = reader.stringOrNull()
                    "artists" -> if (!reader.isNull()) reader.array {
                        var name = ""; var hash = ""
                        reader.obj { field ->
                            when (field) {
                                "name" -> name = reader.nextString()
                                "artworkHash" -> hash = reader.nextString()
                                else -> reader.skipValue()
                            }
                        }
                        artists += CatalogArtistPhoto(name, hash)
                    }
                    "version" -> require(reader.nextInt() <= 1) { "This library comes from a newer Groovelight: update the app" }
                    else -> reader.skipValue()
                }
            }
            reader.endObject()
            val keys = albums.map { it.key }.toSet()
            Catalog(albums, tracks.filter { it.albumKey in keys }, choice, encoding, artists)
        }

        private fun album(reader: JsonReader): CatalogAlbum {
            var album = CatalogAlbum("", "", "")
            reader.obj { name ->
                album = when (name) {
                    "key" -> album.copy(key = reader.nextString())
                    "title" -> album.copy(title = reader.nextString())
                    "artist" -> album.copy(artist = reader.nextString())
                    "year" -> album.copy(year = reader.intOrNull())
                    "isCompilation" -> album.copy(isCompilation = reader.nextBoolean())
                    "artworkHash" -> album.copy(artworkHash = reader.stringOrNull())
                    else -> album.also { reader.skipValue() }
                }
            }
            return album
        }

        private fun song(reader: JsonReader): CatalogTrack {
            var id = 0L; var title = ""; var artist = ""; var albumKey = ""; var disc: Int? = null; var number: Int? = null
            var duration = 0.0; var codec = ""; var rate: Int? = null; var bits: Int? = null; var genre: String? = null
            var year: Int? = null; var artwork: String? = null
            reader.obj { name ->
                when (name) {
                    "id" -> id = reader.nextLong()
                    "title" -> title = reader.nextString()
                    "artist" -> artist = reader.nextString()
                    "albumKey" -> albumKey = reader.nextString()
                    "discNumber" -> disc = reader.intOrNull()
                    "trackNumber" -> number = reader.intOrNull()
                    "duration" -> duration = reader.nextDouble()
                    "codec" -> codec = reader.nextString()
                    "sampleRate" -> rate = reader.intOrNull()
                    "bitDepth" -> bits = reader.intOrNull()
                    "genre" -> genre = reader.stringOrNull()
                    "year" -> year = reader.intOrNull()
                    "artworkHash" -> artwork = reader.stringOrNull()
                    else -> reader.skipValue()
                }
            }
            return CatalogTrack(id, title, artist, albumKey, disc, number, (duration * 1000).toLong(), codec, rate, bits, genre, year, artwork)
        }
    }
}

/**
 * What the device's selection on the Mac holds (`DeviceCatalog.Chosen`): everything, albums, artists and songs, and
 * whether playlists, genres or Loved Songs are chosen there too (the app cannot tell which songs those bring).
 */
data class Choice(
    val everything: Boolean = false,
    val albumKeys: Set<String> = emptySet(),
    val artists: Set<String> = emptySet(),
    val trackIds: Set<Long> = emptySet(),
    /** Songs removed from this device: off it whatever else is chosen (the Mac keeps them). */
    val excludedTrackIds: Set<Long> = emptySet(),
    /** Formats chosen per album, artist or song ("album:<key>" to "opus160"...), over the device's own. */
    val encodings: Map<String, String> = emptyMap(),
    val hasOthers: Boolean = false,
) {
    /**
     * With requests not sent yet applied, in order, as the Mac will apply them: removing leaves out the songs of what is
     * removed (from `songs`: an album's, an artist's...), adding brings them back.
     */
    fun applying(requests: List<TransferRequest>, songs: (kind: String, key: String) -> Set<Long> = { kind, key ->
        if (kind == TransferRequest.SONG) setOfNotNull(key.toLongOrNull()) else emptySet()
    }): Choice = requests.fold(this) { choice, request ->
        val add = request.action == TransferRequest.ADD
        val ids = songs(request.kind, request.key)
        val excluded = if (add) choice.excludedTrackIds - ids else choice.excludedTrackIds + ids
        // Adding sets its format (or the device's again, without one); removing forgets it.
        val formatKey = "${request.kind}:${request.key}"
        val formatted = if (request.kind == TransferRequest.PLAYLIST) choice
            else choice.copy(encodings = if (add && request.encoding != null) choice.encodings + (formatKey to request.encoding) else choice.encodings - formatKey)
        @Suppress("NAME_SHADOWING") val choice = formatted
        when (request.kind) {
            TransferRequest.ALBUM -> choice.copy(albumKeys = if (add) choice.albumKeys + request.key else choice.albumKeys - request.key, excludedTrackIds = excluded)
            TransferRequest.ARTIST -> choice.copy(artists = if (add) choice.artists + request.key else choice.artists - request.key, excludedTrackIds = excluded)
            TransferRequest.SONG -> request.key.toLongOrNull()?.let { id ->
                choice.copy(trackIds = if (add) choice.trackIds + id else choice.trackIds - id, excludedTrackIds = excluded)
            } ?: choice
            else -> choice.copy(excludedTrackIds = excluded)
        }
    }

    /** Whether the album comes to the device (`songs`: its songs, to tell whether all were removed). */
    fun holdsAlbum(album: CatalogAlbum, songs: Set<Long> = emptySet()): Boolean =
        (everything || album.key in albumKeys || album.artist in artists) && !(songs.isNotEmpty() && excludedTrackIds.containsAll(songs))

    fun holdsSong(track: CatalogTrack, album: CatalogAlbum?): Boolean = track.id !in excludedTrackIds &&
        (everything || track.id in trackIds || track.albumKey in albumKeys || (album != null && album.artist in artists) || track.artist in artists)

    /** Whether the song was removed from the device (and stays off it). */
    fun excludes(trackId: Long) = trackId in excludedTrackIds

    /** The format chosen for an album (or its artist), or null for the device's own. */
    fun encodingOf(album: CatalogAlbum): String? = encodings["album:${album.key}"] ?: encodings["artist:${album.artist}"]

    fun rows(): List<CatalogChosen> = buildList {
        if (everything) add(CatalogChosen("everything", ""))
        if (hasOthers) add(CatalogChosen("others", ""))
        albumKeys.forEach { add(CatalogChosen(TransferRequest.ALBUM, it)) }
        artists.forEach { add(CatalogChosen(TransferRequest.ARTIST, it)) }
        trackIds.forEach { add(CatalogChosen(TransferRequest.SONG, it.toString())) }
        excludedTrackIds.forEach { add(CatalogChosen("excluded", it.toString())) }
        encodings.forEach { (key, format) -> add(CatalogChosen("format:$format", key)) }
    }

    companion object {
        fun of(rows: List<CatalogChosen>) = Choice(
            everything = rows.any { it.kind == "everything" },
            albumKeys = rows.filter { it.kind == TransferRequest.ALBUM }.map { it.key }.toSet(),
            artists = rows.filter { it.kind == TransferRequest.ARTIST }.map { it.key }.toSet(),
            trackIds = rows.filter { it.kind == TransferRequest.SONG }.mapNotNull { it.key.toLongOrNull() }.toSet(),
            excludedTrackIds = rows.filter { it.kind == "excluded" }.mapNotNull { it.key.toLongOrNull() }.toSet(),
            encodings = rows.filter { it.kind.startsWith("format:") }.associate { it.key to it.kind.removePrefix("format:") },
            hasOthers = rows.any { it.kind == "others" },
        )

        fun read(reader: JsonReader): Choice {
            var choice = Choice()
            reader.obj { name ->
                choice = when (name) {
                    "everything" -> choice.copy(everything = reader.nextBoolean())
                    "hasOthers" -> choice.copy(hasOthers = reader.nextBoolean())
                    "albumKeys" -> choice.copy(albumKeys = buildSet { reader.array { add(reader.nextString()) } })
                    "artists" -> choice.copy(artists = buildSet { reader.array { add(reader.nextString()) } })
                    "trackIds" -> choice.copy(trackIds = buildSet { reader.array { add(reader.nextLong()) } })
                    "excludedTrackIds" -> choice.copy(excludedTrackIds = buildSet { reader.array { add(reader.nextLong()) } })
                    "encodings" -> choice.copy(encodings = buildMap { reader.obj { key -> put(key, reader.nextString()) } })
                    else -> choice.also { reader.skipValue() }
                }
            }
            return choice
        }
    }
}

/** Where an album or song of the Mac's library stands for this device. */
enum class Availability {
    /** Here, and kept by the selection (or by a playlist or genre chosen on the Mac). */
    ON_DEVICE,
    /** Asked for: the next sync brings it. */
    ARRIVING,
    /** Asked for while the Mac is away: sent when it is reachable. */
    WAITING,
    /** No longer asked for: the next sync removes it. */
    LEAVING,
    /** Only on the Mac. */
    ON_MAC;

    companion object {
        /**
         * `onDevice`: it is in the device's library; `chosen` and `chosenAfter`: whether the selection holds it as the
         * Mac knows it and once the waiting requests are applied; `others`: playlists or genres chosen on the Mac may
         * hold it (so not being chosen does not mean it leaves).
         */
        fun of(onDevice: Boolean, chosen: Boolean, chosenAfter: Boolean, others: Boolean, removed: Boolean = false): Availability = when {
            chosenAfter != chosen -> WAITING
            onDevice && removed -> LEAVING
            onDevice && !chosen && !others -> LEAVING
            onDevice -> ON_DEVICE
            chosen -> ARRIVING
            else -> ON_MAC
        }
    }
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
