@file:OptIn(UnstableApi::class)

package dev.irwingbraga.groovelight.app

import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import android.content.Context
import android.net.Uri
import android.os.Bundle
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.session.MediaSession
import dev.irwingbraga.groovelight.library.Album
import dev.irwingbraga.groovelight.library.LibraryDatabase
import dev.irwingbraga.groovelight.library.Track
import dev.irwingbraga.groovelight.library.ftsQuery
import dev.irwingbraga.groovelight.playback.Browsing
import kotlinx.coroutines.flow.first

/**
 * The library as Android Auto browses it: Recently Played, Albums, Artists and Playlists (Loved Songs first), down to
 * the songs. Ids say what an item is: "album:<key>", "artist:<name>", "playlist:<id>", "loved", and for a song
 * "song:<id>@<where it was listed>", so choosing it plays the rest of that album or playlist after it.
 */
class LibraryBrowsing(context: Context) : Browsing {
    private val context = context.applicationContext
    private val library get() = LibraryDatabase.get(context).library()

    override suspend fun children(parentId: String): List<MediaItem> = when {
        parentId == Browsing.ROOT -> listOf(
            folder(RECENT, "Recently Played", grid = true),
            folder(ALBUMS, "Albums", grid = true),
            folder(ARTISTS, "Artists", grid = false),
            folder(PLAYLISTS, "Playlists", grid = false),
        )
        parentId == RECENT -> library.recentlyPlayedAlbums(40).first().map(::albumItem)
        parentId == ALBUMS -> library.albums().first().map(::albumItem)
        parentId == ARTISTS -> library.artists().first().map { artist ->
            browsable("artist:${artist.name}", artist.name, if (artist.albums == 1) "1 album" else "${artist.albums} albums", artist.artworkHash,
                MediaMetadata.MEDIA_TYPE_ARTIST, grid = true)
        }
        parentId == PLAYLISTS -> listOf(browsable(LOVED, "Loved Songs", null, null, MediaMetadata.MEDIA_TYPE_PLAYLIST, playable = true)) +
            library.playlists().first().map { playlist ->
                browsable("playlist:${playlist.id}", playlist.name, if (playlist.songs == 1) "1 song" else "${playlist.songs} songs",
                    playlist.coverHash ?: playlist.artworkHash, MediaMetadata.MEDIA_TYPE_PLAYLIST, playable = true)
            }
        parentId.startsWith("artist:") -> library.albumsOf(parentId.removePrefix("artist:")).first().map(::albumItem)
        else -> songsOf(parentId).map { songItem(it, parentId) }
    }

    override suspend fun item(id: String): MediaItem? = when {
        id.startsWith("song:") -> id.substringAfter("song:").substringBefore('@').toLongOrNull()
            ?.let { library.track(it).first() }?.let { songItem(it, id.substringAfter('@', "")) }
        id.startsWith("album:") -> library.albumNow(id.removePrefix("album:"))?.let(::albumItem)
        else -> null
    }

    override suspend fun search(query: String): List<MediaItem> {
        val match = ftsQuery(query) ?: return emptyList()
        return library.searchTracks(match, 50).map { songItem(it, "album:${it.albumKey}") }
    }

    override suspend fun playable(id: String): MediaSession.MediaItemsWithStartPosition? {
        val (songId, where) = if (id.startsWith("song:")) id.substringAfter("song:").substringBefore('@').toLongOrNull() to id.substringAfter('@', "")
            else null to id
        val songs = songsOf(where).ifEmpty { songId?.let { library.track(it).first() }?.let(::listOf).orEmpty() }
        if (songs.isEmpty()) return null
        val albums = library.albums().first().associateBy { it.key }
        val items = playerItems(context, songs, albums, source(where, albums))
        if (items.isEmpty()) return null
        val start = songId?.let { wanted -> songs.indexOfFirst { it.id == wanted } }?.coerceAtLeast(0) ?: 0
        return MediaSession.MediaItemsWithStartPosition(items, start, 0)
    }

    /** The songs listed under an id: an album's, an artist's, a playlist's, Loved Songs. */
    private suspend fun songsOf(where: String): List<Track> = when {
        where.startsWith("album:") -> library.tracksOfAlbumNow(where.removePrefix("album:"))
        where.startsWith("artist:") -> library.tracksOfArtist(where.removePrefix("artist:")).first()
        where.startsWith("playlist:") -> where.removePrefix("playlist:").toLongOrNull()?.let { library.tracksOfPlaylist(it).first() }.orEmpty()
        where == LOVED -> library.lovedTracks().first()
        else -> emptyList()
    }

    /** Where the songs play from, as Now Playing shows it. */
    private suspend fun source(where: String, albums: Map<String, Album>): String? = when {
        where.startsWith("album:") -> albums[where.removePrefix("album:")]?.let { "Album · ${it.title}" }
        where.startsWith("artist:") -> "Artist · ${where.removePrefix("artist:")}"
        where.startsWith("playlist:") -> where.removePrefix("playlist:").toLongOrNull()?.let { library.playlist(it).first() }?.let { "Playlist · ${it.name}" }
        where == LOVED -> "Loved Songs"
        else -> null
    }

    private fun albumItem(album: Album) =
        browsable("album:${album.key}", album.title, album.artist, album.artworkHash, MediaMetadata.MEDIA_TYPE_ALBUM, playable = true)

    private fun songItem(track: Track, where: String) = MediaItem.Builder()
        .setMediaId("song:${track.id}@$where")
        .setMediaMetadata(MediaMetadata.Builder()
            .setTitle(track.title)
            .setArtist(track.artist)
            .setArtworkUri(ArtworkProvider.uri(context, track.artworkHash))
            .setDurationMs(track.durationMs)
            .setIsBrowsable(false)
            .setIsPlayable(true)
            .setMediaType(MediaMetadata.MEDIA_TYPE_MUSIC)
            .build())
        .build()

    private fun folder(id: String, title: String, grid: Boolean) =
        browsable(id, title, null, null, MediaMetadata.MEDIA_TYPE_FOLDER_MIXED, grid = grid)

    private fun browsable(id: String, title: String, subtitle: String?, artwork: String?, type: Int, playable: Boolean = false,
                          grid: Boolean? = null) = MediaItem.Builder()
        .setMediaId(id)
        .setMediaMetadata(MediaMetadata.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
            .setArtist(subtitle)
            .setArtworkUri(ArtworkProvider.uri(context, artwork))
            .setIsBrowsable(true)
            .setIsPlayable(playable)
            .setMediaType(type)
            .apply {
                // How the car lays out what is inside: albums as a grid, songs and lists as lists.
                if (grid != null) setExtras(Bundle().apply { putInt("android.media.browse.CONTENT_STYLE_BROWSABLE_HINT", if (grid) 2 else 1) })
            }
            .build())
        .build()

    private companion object {
        const val RECENT = "recent"
        const val ALBUMS = "albums"
        const val ARTISTS = "artists"
        const val PLAYLISTS = "playlists"
        const val LOVED = "loved"
    }
}
