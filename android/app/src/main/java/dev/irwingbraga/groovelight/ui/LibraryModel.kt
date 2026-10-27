package dev.irwingbraga.groovelight.ui

import android.app.Application
import android.content.Context
import android.net.Uri
import androidx.core.content.edit
import androidx.core.net.toUri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import dev.irwingbraga.groovelight.library.Album
import dev.irwingbraga.groovelight.library.ArtistSummary
import dev.irwingbraga.groovelight.library.ArtworkStore
import dev.irwingbraga.groovelight.library.LibraryDatabase
import dev.irwingbraga.groovelight.library.Playlist
import dev.irwingbraga.groovelight.library.PlaylistSummary
import dev.irwingbraga.groovelight.library.Track
import dev.irwingbraga.groovelight.library.Availability
import dev.irwingbraga.groovelight.library.CatalogAlbum
import dev.irwingbraga.groovelight.library.CatalogArtist
import dev.irwingbraga.groovelight.library.CatalogTrack
import dev.irwingbraga.groovelight.library.Choice
import dev.irwingbraga.groovelight.library.Credit
import dev.irwingbraga.groovelight.library.TransferRequest
import dev.irwingbraga.groovelight.sync.MacError
import dev.irwingbraga.groovelight.sync.RequestWorker
import dev.irwingbraga.groovelight.app.playerItems
import dev.irwingbraga.groovelight.sync.SyncEngine
import dev.irwingbraga.groovelight.sync.SyncWorker
import dev.irwingbraga.groovelight.sync.Transfers
import kotlinx.coroutines.Dispatchers
import dev.irwingbraga.groovelight.library.PersonSummary
import dev.irwingbraga.groovelight.library.ftsQuery
import dev.irwingbraga.groovelight.library.likePattern
import dev.irwingbraga.groovelight.playback.EqPreset
import dev.irwingbraga.groovelight.playback.Normalization
import kotlinx.coroutines.launch
import org.json.JSONArray
import dev.irwingbraga.groovelight.sync.DeviceFolder
import dev.irwingbraga.groovelight.sync.Prefs
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import java.io.File

/** The library from the Mac's snapshot, for the screens, and the songs as items the player can play. */
@OptIn(ExperimentalCoroutinesApi::class, FlowPreview::class)
class LibraryModel(application: Application) : AndroidViewModel(application) {
    enum class AlbumOrder(val label: String) { ARTIST("Artist"), TITLE("Title"), YEAR("Year"), RECENT("Recently added") }
    enum class SongOrder(val label: String) { TITLE("Title"), ARTIST("Artist"), ALBUM("Album"), RECENT("Recently added") }

    data class SearchResults(
        val query: String,
        val artists: List<ArtistSummary>,
        val albums: List<Album>,
        val songs: List<Track>,
        val people: List<PersonSummary> = emptyList(),
    ) {
        val isEmpty get() = artists.isEmpty() && albums.isEmpty() && songs.isEmpty() && people.isEmpty()
    }

    /** What a person did: albums credited to them (with their roles there) and songs (album by album). */
    data class PersonPage(val albums: List<Pair<Album, List<String>>>, val songs: List<Pair<Track, List<String>>>, val roles: List<String>)

    /** An equalizer curve from the Mac: one it saved, or the one it uses ([isCurrent]). */
    data class MacPreset(val preset: EqPreset, val isCurrent: Boolean, val enabled: Boolean)

    private val library = LibraryDatabase.get(application).library()
    val artwork = ArtworkStore(application)
    private val prefs = Prefs(application)
    private val settings = application.getSharedPreferences("library", Context.MODE_PRIVATE)

    val albumOrder = MutableStateFlow(settings.getString("albumOrder", null)?.let { runCatching { AlbumOrder.valueOf(it) }.getOrNull() } ?: AlbumOrder.ARTIST)
    val songOrder = MutableStateFlow(settings.getString("songOrder", null)?.let { runCatching { SongOrder.valueOf(it) }.getOrNull() } ?: SongOrder.TITLE)

    val albums: StateFlow<List<Album>?> = albumOrder.flatMapLatest { order ->
        when (order) {
            AlbumOrder.RECENT -> library.recentAlbums()
            else -> library.albums().map { albums ->
                when (order) {
                    AlbumOrder.TITLE -> albums.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.title })
                    AlbumOrder.YEAR -> albums.sortedWith(compareByDescending<Album> { it.year ?: 0 }.thenBy(String.CASE_INSENSITIVE_ORDER) { it.title })
                    else -> albums
                }
            }
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    /** Every album by key (for songs' album titles; kept while the model lives, as player items are made from it). */
    val albumsByKey: StateFlow<Map<String, Album>> = library.albums().map { albums -> albums.associateBy { it.key } }
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptyMap())

    val artists: StateFlow<List<ArtistSummary>?> = library.artists().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    val tracks: StateFlow<List<Track>?> = combine(library.tracks(), songOrder, albumsByKey) { tracks, order, albums ->
        when (order) {
            SongOrder.TITLE -> tracks
            SongOrder.ARTIST -> tracks.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it: Track -> it.artist }
                .thenBy(String.CASE_INSENSITIVE_ORDER) { albums[it.albumKey]?.title ?: "" }.thenBy { it.discNumber ?: 1 }.thenBy { it.trackNumber ?: 0 })
            SongOrder.ALBUM -> tracks.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it: Track -> albums[it.albumKey]?.title ?: "" }
                .thenBy { it.discNumber ?: 1 }.thenBy { it.trackNumber ?: 0 })
            SongOrder.RECENT -> tracks.sortedByDescending { it.dateAdded }
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    val playlists: StateFlow<List<PlaylistSummary>?> = library.playlists().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    fun setAlbumOrder(order: AlbumOrder) {
        albumOrder.value = order
        settings.edit { putString("albumOrder", order.name) }
    }

    fun setSongOrder(order: SongOrder) {
        songOrder.value = order
        settings.edit { putString("songOrder", order.name) }
    }

    fun album(key: String): Flow<Album?> = library.album(key)
    fun tracksOfAlbum(key: String): Flow<List<Track>> = library.tracksOfAlbum(key)
    fun albumsOf(artist: String): Flow<List<Album>> = library.albumsOf(artist)
    fun albumsAppearingOn(artist: String): Flow<List<Album>> = library.albumsAppearingOn(artist)
    fun tracksOfArtist(artist: String): Flow<List<Track>> = library.tracksOfArtist(artist)
    fun playlist(id: Long): Flow<Playlist?> = library.playlist(id)
    fun tracksOfPlaylist(id: Long): Flow<List<Track>> = library.tracksOfPlaylist(id)
    fun lovedTracks(): Flow<List<Track>> = library.lovedTracks()
    fun track(id: Long): Flow<Track?> = library.track(id)
    fun creditsOfAlbum(key: String): Flow<List<Credit>> = library.creditsOfAlbum(key)
    /** The artist's photo from the Mac (a hash in the artwork store), when it has one. */
    fun artistPhoto(name: String): Flow<String?> = library.artistPhoto(name)
    /** The same in the Mac's whole library (fetched small when shown). */
    fun catalogArtistPhoto(name: String): Flow<String?> = catalog.artistPhoto(name)

    fun person(name: String): Flow<PersonPage> = library.creditsOf(name).map { credits ->
        val albumRoles = LinkedHashMap<String, MutableList<String>>()
        val songRoles = LinkedHashMap<Long, MutableList<String>>()
        val wholeAlbums = mutableSetOf<String>()
        val counts = mutableMapOf<String, Int>()
        for (credit in credits) {
            val roles = credit.roles.split('\n').filter { it.isNotBlank() }
            roles.forEach { counts[it] = (counts[it] ?: 0) + 1 }
            if (credit.trackId == null) albumRoles.getOrPut(credit.albumKey) { mutableListOf() }.addAll(roles)
            else {
                songRoles.getOrPut(credit.trackId!!) { mutableListOf() }.addAll(roles)
                wholeAlbums += credit.albumKey
            }
        }
        val albums = library.albumsWithKeys((albumRoles.keys + wholeAlbums).toList())
        val songs = library.tracksWithIds(songRoles.keys.toList()).sortedWith(compareBy<Track> { albums.indexOfFirst { a -> a.key == it.albumKey } }
            .thenBy { it.discNumber ?: 1 }.thenBy { it.trackNumber ?: 0 })
        PersonPage(albums.map { it to (albumRoles[it.key]?.distinct() ?: songs.filter { s -> s.albumKey == it.key }.flatMap { s -> songRoles[s.id].orEmpty() }.distinct()) },
            songs.map { it to songRoles[it.id].orEmpty().distinct() }, counts.entries.sortedByDescending { it.value }.map { it.key })
    }

    // Loves and ratings change here at once, and go to the Mac (now, or when it is reachable).
    fun setLoved(id: Long, loved: Boolean) { viewModelScope.launch { library.setLoved(id, loved); RequestWorker.schedule(getApplication()) } }
    fun setRating(id: Long, stars: Int) { viewModelScope.launch { library.setRating(id, stars); RequestWorker.schedule(getApplication()) } }

    // Playlists edited here change at once, and the edits go to the Mac the same way.
    val editablePlaylists: StateFlow<List<Playlist>> = library.editablePlaylists().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    private fun editing(block: suspend () -> Unit) {
        viewModelScope.launch { block(); RequestWorker.schedule(getApplication()) }
    }

    fun createPlaylist(name: String, tracks: List<Track> = emptyList(), then: (Long) -> Unit = {}) =
        editing { then(library.createPlaylist(name, tracks.map { it.id })) }
    fun addToPlaylist(id: Long, tracks: List<Track>) = editing { library.addToPlaylist(id, tracks.map { it.id }) }
    fun removeFromPlaylist(id: Long, track: Track) = editing { library.removeFromPlaylist(id, listOf(track.id)) }
    fun renamePlaylist(id: Long, name: String) = editing { library.renamePlaylist(id, name) }
    fun deletePlaylist(id: Long) = editing { library.deletePlaylist(id) }

    /** The Mac's equalizer curves: the one it uses first, then its saved presets. */
    val macPresets: StateFlow<List<MacPreset>> = library.macEqPresets().map { rows ->
        rows.map { row ->
            val bands = runCatching { EqPreset.bands(JSONArray(row.bands)) }.getOrDefault(EqPreset.FLAT.bands)
            MacPreset(EqPreset(row.name, row.preamp, bands), row.isCurrent, row.enabled)
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    /** How to draw a playlist's cover (with its songs' covers, read when needed). */
    suspend fun playlistArt(playlist: Playlist): PlaylistArt = PlaylistArt(
        playlist.id, playlist.name, playlist.coverStyle, playlist.coverPalette, playlist.coverPattern, cover(playlist.coverHash),
        playlist.coverShowsTitle, library.playlistCovers(playlist.id).mapNotNull { cover(it) })

    suspend fun playlistArt(summary: PlaylistSummary): PlaylistArt = PlaylistArt(
        summary.id, summary.name, summary.coverStyle, summary.coverPalette, summary.coverPattern, cover(summary.coverHash),
        summary.coverShowsTitle, library.playlistCovers(summary.id).mapNotNull { cover(it) })

    // MARK: The Mac's whole library

    /** What the Library tab shows: only what is on this device (DEVICE), or the Mac's whole library with it (MAC, the default, and again on pairing). */
    enum class Source { DEVICE, MAC }

    val source = MutableStateFlow(settings.getString("source", null)?.let { runCatching { Source.valueOf(it) }.getOrNull() } ?: Source.MAC)

    fun setSource(value: Source) {
        source.value = value
        settings.edit { putString("source", value.name) }
        if (value == Source.MAC) refreshCatalog()
    }

    private val catalog = LibraryDatabase.get(application).catalog()
    val catalogAlbums: StateFlow<List<CatalogAlbum>?> = catalog.albums().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)
    val catalogArtists: StateFlow<List<CatalogArtist>?> = catalog.artists().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)
    val catalogTracks: StateFlow<List<CatalogTrack>?> = catalog.tracks().stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)
    fun catalogAlbum(key: String): Flow<CatalogAlbum?> = catalog.album(key)
    fun catalogTracksOfAlbum(key: String): Flow<List<CatalogTrack>> = catalog.tracksOfAlbum(key)
    /** An artist's albums, the Mac's and this device's (an album the Mac's list does not have yet), by year. */
    fun catalogAlbumsOf(artist: String): Flow<List<CatalogAlbum>> = combine(catalog.albumsOf(artist), library.albumsOf(artist)) { mac, here ->
        val known = mac.map { it.key }.toSet()
        val local = here.associateBy { it.key }
        (mac.map { album -> local[album.key]?.artworkHash?.let { album.copy(artworkHash = it) } ?: album } +
            here.filter { it.key !in known }.map { CatalogAlbum(it.key, it.title, it.artist, it.year, it.isCompilation, it.artworkHash) })
            .sortedWith(compareBy<CatalogAlbum> { it.year ?: 0 }.thenBy(String.CASE_INSENSITIVE_ORDER) { it.title })
    }
    val catalogAlbumsByKey: StateFlow<Map<String, CatalogAlbum>> = catalog.albums().map { albums -> albums.associateBy { it.key } }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyMap())

    /**
     * What this device holds and will hold: its albums and songs, the selection on the Mac as last known, and the same
     * with the requests not sent yet. Each album's or song's [Availability] comes from it.
     */
    data class Holdings(
        val albumKeys: Set<String> = emptySet(),
        val trackIds: Set<Long> = emptySet(),
        val chosen: Choice = Choice(),
        val after: Choice = Choice(),
        val waiting: Int = 0,
        /** The Mac's songs of each album, to tell an album whose songs were all removed. */
        val albumSongs: Map<String, Set<Long>> = emptyMap(),
    ) {
        fun of(album: CatalogAlbum): Availability {
            val songs = albumSongs[album.key].orEmpty()
            return Availability.of(album.key in albumKeys, chosen.holdsAlbum(album, songs), after.holdsAlbum(album, songs), chosen.hasOthers,
                removed = songs.isNotEmpty() && after.excludedTrackIds.containsAll(songs))
        }
        fun of(track: CatalogTrack, album: CatalogAlbum?) =
            Availability.of(track.id in trackIds, chosen.holdsSong(track, album), after.holdsSong(track, album), chosen.hasOthers,
                removed = after.excludes(track.id))
        /** Whether removing the album from here would do anything: it is chosen as an album (or all its artist's). */
        fun canRemove(album: CatalogAlbum) = !after.everything && (album.key in after.albumKeys || album.artist in after.artists)
        fun canRemove(track: CatalogTrack) = !after.everything && track.id in after.trackIds
    }

    val holdings: StateFlow<Holdings> = combine(library.albums(), library.tracks(), catalog.chosen(), catalog.pending(), catalog.tracks()) {
            albums, tracks, chosen, pending, catalogTracks ->
        val choice = Choice.of(chosen)
        val albumSongs = catalogTracks.groupBy { it.albumKey }.mapValues { (_, songs) -> songs.map { it.id }.toSet() }
        // Waiting removals and additions of albums, artists and songs stand for their songs, as on the Mac (playlists
        // are not shown there: the Mac works theirs out).
        val songs = { kind: String, key: String ->
            when (kind) {
                TransferRequest.ALBUM -> albumSongs[key].orEmpty()
                TransferRequest.ARTIST -> catalogTracks.filter { it.artist == key }.map { it.id }.toSet() + albumsOfArtist(key, albumSongs)
                TransferRequest.SONG -> setOfNotNull(key.toLongOrNull())
                else -> emptySet()
            }
        }
        Holdings(albums.map { it.key }.toSet(), tracks.map { it.id }.toSet(), choice, choice.applying(pending, songs), pending.size, albumSongs)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), Holdings())

    private val catalogAlbumArtists = catalog.albums().map { albums -> albums.associate { it.key to it.artist } }
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptyMap())

    private fun albumsOfArtist(artist: String, albumSongs: Map<String, Set<Long>>): Set<Long> =
        catalogAlbumArtists.value.filterValues { it == artist }.keys.flatMap { albumSongs[it].orEmpty() }.toSet()

    /** Whether the Mac's library is being fetched, and whether the Mac answered the last time. */
    data class CatalogState(val loading: Boolean = false, val reachable: Boolean? = null, val error: String? = null)

    val catalogState = MutableStateFlow(CatalogState())

    /** Fetches the Mac's library when it changed (and sends waiting requests while connected). */
    fun refreshCatalog() {
        if (catalogState.value.loading) return
        catalogState.value = catalogState.value.copy(loading = true)
        viewModelScope.launch(Dispatchers.IO) {
            val app = getApplication<Application>()
            val result = runCatching {
                val client = SyncEngine(app, prefs).connect()
                // The Mac's library only travels over HTTPS (it describes the whole library).
                if (prefs.tlsPort == 0) throw IllegalStateException(NO_TLS)
                if (Transfers.send(app, client) && prefs.folder != null) SyncWorker.syncNow(app)
                Transfers.refreshCatalog(app, client, prefs)
            }
            if (result.isSuccess) Transfers.retryCovers()
            // The Mac answered, even when its library could not be read.
            val answered = result.isSuccess || result.exceptionOrNull() is IllegalStateException ||
                (result.exceptionOrNull() as? MacError)?.status?.let { it > 0 } == true
            Transfers.reachable.value = answered
            catalogState.value = CatalogState(loading = false, reachable = answered, error = result.exceptionOrNull()?.message)
        }
    }

    private companion object {
        const val NO_TLS = "Groovelight on the Mac is not offering its secure connection, which its library needs here. If macOS asks " +
            "on the Mac whether Groovelight may use its key, choose Always Allow; otherwise quit Groovelight there and open it again."
    }

    /** Asks for an album, artist or song on this device (or to remove it); sent now or when the Mac is reachable. */
    fun request(action: String, kind: String, key: String, encoding: String? = null) {
        viewModelScope.launch { Transfers.request(getApplication(), action, kind, key, encoding) }
    }

    private val catalogCovers = Transfers.covers(application)

    /** A cover for the Mac's library: the device's when it has it, else the small one fetched from the Mac. */
    fun catalogCover(hash: String?): File? = hash?.let { cover(it) ?: catalogCovers.file(it).takeIf { file -> file.length() > 0 } }

    suspend fun fetchCatalogCover(hash: String): Boolean = Transfers.fetchCover(getApplication(), hash)

    // MARK: The merged library (the Mac's and this device's together)

    /** Every album: the Mac's, and this device's that the Mac's list does not have yet; in the albums' sort order. */
    val mergedAlbums: StateFlow<List<CatalogAlbum>?> = combine(catalog.albums(), library.albums(), library.recentAlbums(), albumOrder) {
            mac, here, recent, order ->
        val known = mac.map { it.key }.toSet()
        // An album here shows this device's cover (it may have come from the songs themselves).
        val local = here.associateBy { it.key }
        val all = mac.map { album -> local[album.key]?.artworkHash?.let { album.copy(artworkHash = it) } ?: album } +
            here.filter { it.key !in known }.map { CatalogAlbum(it.key, it.title, it.artist, it.year, it.isCompilation, it.artworkHash) }
        when (order) {
            AlbumOrder.ARTIST -> all.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it: CatalogAlbum -> it.artist }.thenBy { it.year ?: 0 }
                .thenBy(String.CASE_INSENSITIVE_ORDER) { it.title })
            AlbumOrder.TITLE -> all.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.title })
            AlbumOrder.YEAR -> all.sortedWith(compareByDescending<CatalogAlbum> { it.year ?: 0 }.thenBy(String.CASE_INSENSITIVE_ORDER) { it.title })
            // The ones here newest first (the Mac's list has no dates), then the rest by artist.
            AlbumOrder.RECENT -> {
                val rank = recent.withIndex().associate { it.value.key to it.index }
                all.sortedWith(compareBy<CatalogAlbum> { rank[it.key] ?: Int.MAX_VALUE }.thenBy(String.CASE_INSENSITIVE_ORDER) { it.artist })
            }
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    /** Every artist, the Mac's and this device's. */
    val mergedArtists: StateFlow<List<CatalogArtist>?> = combine(catalog.artists(), library.artists()) { mac, here ->
        val known = mac.map { it.name }.toSet()
        (mac + here.filter { it.name !in known }.map { CatalogArtist(it.name, it.albums, it.artworkHash) })
            .sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name })
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    /** Every song, the Mac's and this device's, in the songs' sort order. */
    val mergedTracks: StateFlow<List<CatalogTrack>?> = combine(catalog.tracks(), library.tracks(), catalog.albums(), songOrder) { mac, here, albums, order ->
        val known = mac.map { it.id }.toSet()
        val local = here.associateBy { it.id }
        val all = mac.map { track -> local[track.id]?.artworkHash?.let { track.copy(artworkHash = it) } ?: track } + here.filter { it.id !in known }.map {
            CatalogTrack(it.id, it.title, it.artist, it.albumKey, it.discNumber, it.trackNumber, it.durationMs, it.codec, it.sampleRate, it.bitDepth,
                it.genre, it.year, it.artworkHash)
        }
        val added = here.associate { it.id to it.dateAdded }
        val titles = albums.associate { it.key to it.title }
        when (order) {
            SongOrder.TITLE -> all.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.title })
            SongOrder.ARTIST -> all.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it: CatalogTrack -> it.artist }
                .thenBy(String.CASE_INSENSITIVE_ORDER) { titles[it.albumKey] ?: "" }.thenBy { it.discNumber ?: 1 }.thenBy { it.trackNumber ?: 0 })
            SongOrder.ALBUM -> all.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it: CatalogTrack -> titles[it.albumKey] ?: "" }
                .thenBy { it.discNumber ?: 1 }.thenBy { it.trackNumber ?: 0 })
            SongOrder.RECENT -> all.sortedByDescending { added[it.id] ?: 0 }
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    /** The format chosen here for lossless songs ("original", "opus160"...; null: the Mac's), and the Mac's. */
    val encoding = MutableStateFlow(prefs.encoding)
    val macEncoding: String? get() = prefs.macEncoding

    fun setEncoding(value: String) {
        prefs.encoding = value
        encoding.value = value
        val app = getApplication<Application>()
        if (prefs.folder != null) SyncWorker.syncNow(app)
    }

    /** Cover size in the Albums grid (dp), changed by pinching. */
    val gridSize = MutableStateFlow(settings.getFloat("gridSize", 160f))

    fun setGridSize(size: Float) {
        gridSize.value = size.coerceIn(96f, 280f)
        settings.edit { putFloat("gridSize", gridSize.value) }
    }

    /** The search field's text; results follow it, a moment after typing stops. */
    val query = MutableStateFlow("")
    val results: StateFlow<SearchResults?> = query.debounce { if (it.isBlank()) 0 else 150 }.flatMapLatest { text ->
        flow {
            if (text.isBlank()) emit(null) else {
                val pattern = likePattern(text)
                val songs = ftsQuery(text)?.let { library.searchTracks(it, 50) }.orEmpty()
                emit(SearchResults(text, library.searchArtists(pattern, 5), library.searchAlbums(pattern, 12), songs, library.searchPeople(pattern, 5)))
            }
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    /** A song's file in the music folder, to share it. */
    fun fileUri(track: Track): Uri? = prefs.folder?.toUri()?.let { DeviceFolder.documentUri(it, track.path) }

    /** A cover file, when the Mac sent one. */
    fun cover(hash: String?): File? = hash?.let { artwork.file(it) }?.takeIf { it.exists() }

    /** The songs as player items ([playerItems]): `source` is where they are played from, as Now Playing shows it. */
    fun mediaItems(tracks: List<Track>, source: String? = null): List<MediaItem> =
        playerItems(getApplication(), tracks, albumsByKey.value, source)
}
