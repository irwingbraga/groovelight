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
import dev.irwingbraga.groovelight.library.likePattern
import dev.irwingbraga.groovelight.playback.Normalization
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

    data class SearchResults(val query: String, val artists: List<ArtistSummary>, val albums: List<Album>, val songs: List<Track>) {
        val isEmpty get() = artists.isEmpty() && albums.isEmpty() && songs.isEmpty()
    }

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

    /** The search field's text; results follow it, a moment after typing stops. */
    val query = MutableStateFlow("")
    val results: StateFlow<SearchResults?> = query.debounce { if (it.isBlank()) 0 else 150 }.flatMapLatest { text ->
        flow {
            if (text.isBlank()) emit(null) else {
                val pattern = likePattern(text)
                emit(SearchResults(text, library.searchArtists(pattern, 5), library.searchAlbums(pattern, 12), library.searchTracks(pattern, 50)))
            }
        }
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    /** A cover file, when the Mac sent one. */
    fun cover(hash: String?): File? = hash?.let { artwork.file(it) }?.takeIf { it.exists() }

    /**
     * The songs as player items: their file in the music folder (no listing needed), what the Mac knows about them
     * (the files' own tags are not read), the cover, the normalization gain, and `source` (where they are played
     * from, as Now Playing shows it).
     */
    fun mediaItems(tracks: List<Track>, source: String? = null): List<MediaItem> {
        val tree = prefs.folder?.toUri() ?: return emptyList()
        val albums = albumsByKey.value
        return tracks.map { track ->
            val album = albums[track.albumKey]
            val extras = Normalization.extras(track.normalizationGain).apply {
                putString(PlayerModel.ALBUM_KEY, track.albumKey)
                if (source != null) putString(PlayerModel.SOURCE, source)
            }
            val metadata = MediaMetadata.Builder()
                .setTitle(track.title)
                .setArtist(track.artist)
                .setAlbumTitle(album?.title)
                .setAlbumArtist(album?.artist)
                .setTrackNumber(track.trackNumber)
                .setDiscNumber(track.discNumber)
                .setDurationMs(track.durationMs)
                .setArtworkUri(cover(track.artworkHash)?.let(Uri::fromFile))
                .setIsPlayable(true)
                .setIsBrowsable(false)
                .setExtras(extras)
                .build()
            MediaItem.Builder()
                .setMediaId(track.id.toString())
                .setUri(DeviceFolder.documentUri(tree, track.path))
                .setMediaMetadata(metadata)
                .build()
        }
    }
}
