package dev.irwingbraga.groovelight.sync

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Home from the Mac (or the PC), as GroovelightKit's `HomeSnapshot` writes it: the day's picks, each kind with a few
 * more for "Something Else", and the listening dashboard for every range. The Mac works it out from its listening log.
 */
data class HomeSnapshot(
    /** Days since 1970 (the Mac's calendar) the picks are for. */
    val day: Long,
    val song: List<Card>,
    val album: List<Card>,
    val artist: List<Card>,
    val stats: List<Stats>,
) {
    /** A pick: the day's first, then the others. */
    data class Card(
        /** "song", "album" or "artist". */
        val kind: String,
        /** The song id, the album key or the artist's name. */
        val key: String,
        val reason: String,
        val reasonText: String,
        val title: String,
        val subtitle: String,
        val artworkHash: String?,
        val trackIds: List<Long>,
    )

    data class Bucket(val label: String, val minutes: Map<String, Double>) {
        val total: Double get() = minutes.values.sum()
    }

    data class Ranked(val name: String, val detail: String, val key: String, val plays: Long, val artworkHash: String?)

    data class Stats(
        /** "week", "month", "year" or "all". */
        val range: String,
        val minutes: Double,
        val plays: Long,
        val songs: Long,
        val newSongs: Long,
        val streak: Long,
        val buckets: List<Bucket>,
        /** Plays by weekday (0 is Sunday) and hour. */
        val hours: List<List<Long>>,
        val topSongs: List<Ranked>,
        val topAlbums: List<Ranked>,
        val topArtists: List<Ranked>,
        val genres: List<Ranked>,
        val decades: List<Ranked>,
        /** Plays by place: "here" (the Mac or the PC), "devices", "lastfm". */
        val places: Map<String, Long>,
        val librarySongs: Long,
        val neverPlayed: Long,
        val loved: Long,
    )

    fun cards(kind: String): List<Card> = when (kind) {
        "song" -> song
        "album" -> album
        else -> artist
    }

    fun stats(range: String): Stats? = stats.firstOrNull { it.range == range }

    companion object {
        val KINDS = listOf("song", "album", "artist")
        val RANGES = listOf("week", "month", "year", "all")
        val PLACES = listOf("here", "devices", "lastfm")

        fun read(json: String): HomeSnapshot {
            val root = JSONObject(json)
            return HomeSnapshot(
                day = root.optLong("day"),
                song = cards(root.optJSONArray("song")),
                album = cards(root.optJSONArray("album")),
                artist = cards(root.optJSONArray("artist")),
                stats = root.optJSONArray("stats").objects().map(::stats),
            )
        }

        private fun JSONArray?.objects(): List<JSONObject> = if (this == null) emptyList() else (0 until length()).map { getJSONObject(it) }

        private fun JSONObject.text(name: String): String? = if (isNull(name)) null else optString(name)

        private fun cards(array: JSONArray?) = array.objects().map {
            val ids = it.optJSONArray("trackIds")
            Card(
                kind = it.optString("kind"), key = it.optString("key"), reason = it.optString("reason"), reasonText = it.optString("reasonText"),
                title = it.optString("title"), subtitle = it.optString("subtitle"), artworkHash = it.text("artworkHash"),
                trackIds = if (ids == null) emptyList() else (0 until ids.length()).map { index -> ids.getLong(index) },
            )
        }

        private fun ranked(array: JSONArray?) = array.objects().map {
            Ranked(it.optString("name"), it.optString("detail"), it.optString("key"), it.optLong("plays"), it.text("artworkHash"))
        }

        private fun stats(it: JSONObject): Stats {
            val hours = it.optJSONArray("hours")
            val places = it.optJSONObject("places")
            return Stats(
                range = it.optString("range"), minutes = it.optDouble("minutes", 0.0), plays = it.optLong("plays"), songs = it.optLong("songs"),
                newSongs = it.optLong("newSongs"), streak = it.optLong("streak"),
                buckets = it.optJSONArray("buckets").objects().map { bucket ->
                    val minutes = bucket.optJSONObject("minutes")
                    Bucket(bucket.optString("label"), minutes?.keys()?.asSequence()?.associateWith { key -> minutes.optDouble(key, 0.0) }.orEmpty())
                },
                hours = (0 until 7).map { day ->
                    val row = hours?.optJSONArray(day)
                    (0 until 24).map { hour -> row?.optLong(hour) ?: 0L }
                },
                topSongs = ranked(it.optJSONArray("topSongs")), topAlbums = ranked(it.optJSONArray("topAlbums")),
                topArtists = ranked(it.optJSONArray("topArtists")), genres = ranked(it.optJSONArray("genres")),
                decades = ranked(it.optJSONArray("decades")),
                places = places?.keys()?.asSequence()?.associateWith { key -> places.optLong(key) }.orEmpty(),
                librarySongs = it.optLong("librarySongs"), neverPlayed = it.optLong("neverPlayed"), loved = it.optLong("loved"),
            )
        }
    }
}

/**
 * Home on the device: the last one from the Mac, kept in a file for when it is away, and asked for again (only sent
 * when it changed).
 */
object HomeStore {
    private val fetching = Mutex()
    private val _home = MutableStateFlow<HomeSnapshot?>(null)
    private var loaded = false

    /** The last Home (null until the Mac sent one). */
    fun home(context: Context): StateFlow<HomeSnapshot?> {
        if (!loaded) {
            loaded = true
            _home.value = runCatching { HomeSnapshot.read(file(context).readText()) }.getOrNull()
        }
        return _home
    }

    /** When the Mac last answered with Home (0: never). */
    fun fetchedAt(context: Context): Long = context.getSharedPreferences("home", Context.MODE_PRIVATE).getLong("fetchedAt", 0L)

    /** Asks the Mac for Home; nothing comes back when it has not changed. */
    suspend fun refresh(context: Context, client: MacClient) = fetching.withLock {
        home(context)
        val prefs = context.getSharedPreferences("home", Context.MODE_PRIVATE)
        val tag = prefs.getString("tag", null).takeIf { _home.value != null }
        val fetched = withContext(Dispatchers.IO) { client.home(tag) }
        if (fetched != null) {
            val (json, version) = fetched
            val home = HomeSnapshot.read(json.decodeToString())
            withContext(Dispatchers.IO) { file(context).writeBytes(json) }
            prefs.edit().putString("tag", version).apply()
            _home.value = home
        }
        prefs.edit().putLong("fetchedAt", System.currentTimeMillis()).apply()
    }

    /** Forgets Home (the Mac was forgotten). */
    fun clear(context: Context) {
        _home.value = null
        file(context).delete()
        context.getSharedPreferences("home", Context.MODE_PRIVATE).edit().clear().apply()
    }

    private fun file(context: Context) = File(context.filesDir, "home.json")
}
