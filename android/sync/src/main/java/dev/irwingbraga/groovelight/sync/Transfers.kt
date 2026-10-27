package dev.irwingbraga.groovelight.sync

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import dev.irwingbraga.groovelight.library.ArtworkStore
import dev.irwingbraga.groovelight.library.Catalog
import dev.irwingbraga.groovelight.library.Choice
import dev.irwingbraga.groovelight.library.LibraryDatabase
import dev.irwingbraga.groovelight.library.TransferRequest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * The Mac's whole library on the device, and asking for parts of it: albums, artists and songs are added to (or
 * removed from) this device's selection on the Mac. Requests are kept on the device and sent when the Mac is
 * reachable (now, or later by [RequestWorker], retried until it answers), then a sync brings the music.
 */
object Transfers {
    private val sending = Mutex()

    /** Whether the Mac answered the last time it was asked (null: not asked yet), for the screens. */
    val reachable = kotlinx.coroutines.flow.MutableStateFlow<Boolean?>(null)

    /** Asks for an album, artist or song (or to remove it): kept, then sent as soon as the Mac can be reached. */
    suspend fun request(context: Context, action: String, kind: String, key: String, encoding: String? = null) {
        LibraryDatabase.get(context).catalog().insertRequest(TransferRequest(action = action, kind = kind, key = key, encoding = encoding))
        RequestWorker.schedule(context)
    }

    /**
     * Sends the waiting requests to the Mac, in order; the selection it answers with replaces the one kept here. Returns
     * whether there were any (then a sync is due). Requests made while sending wait for the next time.
     */
    suspend fun send(context: Context, client: MacClient): Boolean = sending.withLock {
        val dao = LibraryDatabase.get(context).catalog()
        val pending = dao.pendingRequests()
        if (pending.isEmpty()) return false
        val body = JSONArray().apply {
            pending.forEach {
                put(JSONObject().put("id", it.id.toString()).put("action", it.action).put("kind", it.kind).put("key", it.key)
                    .apply { it.encoding?.let { format -> put("encoding", format) } })
            }
        }
        val chosen = withContext(Dispatchers.IO) { client.requests(body) }
        dao.setChosen(choice(chosen).rows())
        // (The catalog's version is kept: the next one fetched has these changes too.)
        dao.removeRequests(upTo = pending.last().id)
        true
    }

    /**
     * Sends the loves, ratings, plays, skips and playlist edits made here to the Mac (over HTTPS), and forgets them once it has them:
     * the Mac's library (and Last.fm) has them, and the next snapshots bring back how each song stands there. Returns whether
     * there were any.
     */
    suspend fun sendHistory(context: Context, client: MacClient): Boolean = sending.withLock {
        val library = LibraryDatabase.get(context).library()
        val events = library.unsentEvents()
        if (events.isEmpty()) return false
        // Ids with the time, so the Mac (which counts each play once) never takes a new one for one it had, even
        // after the app's data was cleared.
        val body = JSONArray().apply {
            events.forEach {
                put(JSONObject().put("id", "${it.id}-${it.at}").put("trackId", it.trackId).put("kind", it.kind).put("value", it.value).put("atMs", it.at)
                    .apply {
                        it.playlistId?.let { playlist -> put("playlistId", playlist) }
                        it.name?.let { name -> put("name", name) }
                        if (it.trackIds != null) put("trackIds", JSONArray(it.trackIdList))
                    })
            }
        }
        withContext(Dispatchers.IO) { client.history(body) }
        library.removeEvents(upTo = events.last().id)
        true
    }

    /** Fetches the Mac's library when it changed since the last time (only its version is asked otherwise). */
    suspend fun refreshCatalog(context: Context, client: MacClient, prefs: Prefs) {
        val database = LibraryDatabase.get(context)
        // The catalog may be gone (the app's data cleared), or read by an older app that skipped parts this one keeps
        // (artists' photos): ask for all of it then.
        val held = prefs.catalogTag?.takeIf { it.startsWith("${Catalog.READER}:") }?.substringAfter(':')
        val tag = held.takeIf { database.catalog().albumCount() > 0 }
        val (json, version) = withContext(Dispatchers.IO) { client.catalog(tag) } ?: return
        val catalog = Catalog.read(json.inputStream())
        catalog.importInto(database)
        prefs.macEncoding = catalog.encoding
        prefs.catalogTag = "${Catalog.READER}:$version"
    }

    private val fetching = Mutex()
    private val missing = mutableSetOf<String>()
    private var coverClient: MacClient? = null
    /** After failing to reach the Mac, covers wait a minute before trying again (instead of looking for it per cover). */
    private var unreachableUntil = 0L

    /** The catalog's covers (small), for albums that are not on the device: fetched from the Mac when shown. */
    fun covers(context: Context) = ArtworkStore(context, "catalog-artwork")

    /** Fetches a catalog cover from the Mac, if it is reachable; false when it could not. */
    suspend fun fetchCover(context: Context, hash: String): Boolean = fetching.withLock {
        val store = covers(context)
        if (store.has(hash)) return true
        if (hash in missing) return false
        val client = coverClient ?: run {
            if (System.currentTimeMillis() < unreachableUntil) return false
            runCatching { withContext(Dispatchers.IO) { SyncEngine(context, Prefs(context)).connect() } }.getOrNull().also {
                if (it == null) unreachableUntil = System.currentTimeMillis() + 60_000
            }
        } ?: return false
        coverClient = client
        val data = runCatching { withContext(Dispatchers.IO) { client.catalogArtwork(hash) } }
        if (data.isFailure) coverClient = null
        val image = data.getOrNull()
        if (image == null) {
            if (data.isSuccess) missing += hash
            return false
        }
        withContext(Dispatchers.IO) { store.save(hash, image) }
        return true
    }

    /**
     * A song's lyrics from the Mac, over the covers' connection: for a song playing elsewhere that this device does not
     * have. Null when the Mac has none or is not reachable.
     */
    suspend fun fetchLyrics(context: Context, id: Long): String? = fetching.withLock {
        val client = coverClient ?: run {
            if (System.currentTimeMillis() < unreachableUntil) return null
            runCatching { withContext(Dispatchers.IO) { SyncEngine(context, Prefs(context)).connect() } }.getOrNull().also {
                if (it == null) unreachableUntil = System.currentTimeMillis() + 60_000
            }
        } ?: return null
        coverClient = client
        val lyrics = runCatching { withContext(Dispatchers.IO) { client.catalogLyrics(id) } }
        if (lyrics.isFailure) coverClient = null
        lyrics.getOrNull()
    }

    /** A new chance for covers that could not be fetched (the Mac is reachable again). */
    fun retryCovers() = missing.clear()

    private fun choice(chosen: JSONObject): Choice {
        fun strings(name: String) = chosen.optJSONArray(name)?.let { array -> (0 until array.length()).map { array.getString(it) } }.orEmpty()
        return Choice(
            everything = chosen.optBoolean("everything"),
            albumKeys = strings("albumKeys").toSet(),
            artists = strings("artists").toSet(),
            trackIds = strings("trackIds").mapNotNull { it.toLongOrNull() }.toSet(),
            hasOthers = chosen.optBoolean("hasOthers"),
            excludedTrackIds = strings("excludedTrackIds").mapNotNull { it.toLongOrNull() }.toSet(),
            encodings = chosen.optJSONObject("encodings")?.let { formats -> formats.keys().asSequence().associateWith { formats.getString(it) } }.orEmpty(),
        )
    }
}

/**
 * Sends the requests made while the Mac was away: runs when there is a network, and again later (with growing waits)
 * until the Mac answers. Then it syncs, so the music arrives.
 */
class RequestWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    companion object {
        private const val NAME = "requests"

        fun schedule(context: Context) {
            val request = OneTimeWorkRequestBuilder<RequestWorker>()
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setBackoffCriteria(BackoffPolicy.LINEAR, 30, TimeUnit.SECONDS)
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(NAME, ExistingWorkPolicy.REPLACE, request)
        }
    }

    override suspend fun doWork(): Result {
        val prefs = Prefs(applicationContext)
        if (!prefs.isPaired) return Result.success()
        return try {
            val client = SyncEngine(applicationContext, prefs).connect()
            Transfers.reachable.value = true
            Transfers.sendHistory(applicationContext, client)
            if (Transfers.send(applicationContext, client) && prefs.folder != null) SyncWorker.syncNow(applicationContext)
            Result.success()
        } catch (error: Exception) {
            // The Mac is away (or Groovelight is closed there): tried again later (30 seconds more each time), until it answers.
            Transfers.reachable.value = false
            Result.retry()
        }
    }
}
