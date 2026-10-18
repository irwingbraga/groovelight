package dev.irwingbraga.groovelight.library

import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey

// The library as the Mac knows it, for the songs on this device. Ids are the Mac's, so what happens here (plays,
// loves, ratings) maps back to the same songs there. Filled from the library snapshot (protocol v2).

@Entity(tableName = "artist")
data class Artist(
    @PrimaryKey val id: Long,
    val name: String,
    val sortName: String = name,
)

@Entity(tableName = "album", indices = [Index("artistId")])
data class Album(
    @PrimaryKey val id: Long,
    val title: String,
    val artistId: Long?,
    /** As the Mac shows it ("Various Artists" for compilations). */
    val artistName: String,
    val year: Int? = null,
    val isCompilation: Boolean = false,
    /** Content hash of the cover in the artwork cache. */
    val artworkHash: String? = null,
)

@Entity(
    tableName = "track",
    indices = [Index("albumId"), Index("artistId"), Index(value = ["path"], unique = true)],
    foreignKeys = [ForeignKey(entity = Album::class, parentColumns = ["id"], childColumns = ["albumId"], onDelete = ForeignKey.SET_NULL)],
)
data class Track(
    @PrimaryKey val id: Long,
    val title: String,
    val artistId: Long?,
    val artistName: String,
    val albumId: Long?,
    val discNumber: Int? = null,
    val trackNumber: Int? = null,
    val genre: String? = null,
    val durationMs: Long = 0,
    /** Relative to the music folder, as in the sync manifest. */
    val path: String,
    /** Codec and resolution, for the quality badge ("flac", 96000, 24). */
    val codec: String? = null,
    val sampleRate: Int? = null,
    val bitDepth: Int? = null,
    /** Gain in dB from ReplayGain tags or the Mac's loudness measurement. */
    val trackGain: Double? = null,
    val albumGain: Double? = null,
    val loved: Boolean = false,
    val rating: Int = 0,
    val playCount: Int = 0,
    /** Epoch milliseconds. */
    val lastPlayed: Long? = null,
    val dateAdded: Long = 0,
)

@Entity(tableName = "playlist")
data class Playlist(
    @PrimaryKey val id: Long,
    val name: String,
    /** Smart playlists come with their rules (phase 3); until then, with their songs as the Mac evaluated them. */
    val isSmart: Boolean = false,
    val artworkHash: String? = null,
)

@Entity(
    tableName = "playlist_item",
    primaryKeys = ["playlistId", "position"],
    indices = [Index("trackId")],
    foreignKeys = [
        ForeignKey(entity = Playlist::class, parentColumns = ["id"], childColumns = ["playlistId"], onDelete = ForeignKey.CASCADE),
        ForeignKey(entity = Track::class, parentColumns = ["id"], childColumns = ["trackId"], onDelete = ForeignKey.CASCADE),
    ],
)
data class PlaylistItem(
    val playlistId: Long,
    val position: Int,
    val trackId: Long,
)
