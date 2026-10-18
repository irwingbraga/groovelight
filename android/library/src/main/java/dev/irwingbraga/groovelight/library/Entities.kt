package dev.irwingbraga.groovelight.library

import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey

// The library as the Mac knows it, for the songs on this device: filled from the Mac's library snapshot (protocol v2)
// after each sync, never from the files' tags. Song and playlist ids are the Mac's, and albums use its album keys, so
// what happens here (plays, loves, ratings) maps back to the same songs there.

@Entity(tableName = "album", indices = [Index("artist")])
data class Album(
    /** The Mac's album key. */
    @PrimaryKey val key: String,
    val title: String,
    /** The album artist as the Mac shows it ("Various Artists" for compilations). */
    val artist: String,
    val year: Int? = null,
    val isCompilation: Boolean = false,
    /** Content hash of the cover in the artwork store. */
    val artworkHash: String? = null,
)

@Entity(
    tableName = "track",
    indices = [Index("albumKey"), Index("artist"), Index(value = ["path"], unique = true)],
    foreignKeys = [ForeignKey(entity = Album::class, parentColumns = ["key"], childColumns = ["albumKey"], onDelete = ForeignKey.CASCADE)],
)
data class Track(
    @PrimaryKey val id: Long,
    val title: String,
    val artist: String,
    val albumKey: String,
    val discNumber: Int? = null,
    val trackNumber: Int? = null,
    val genre: String? = null,
    val year: Int? = null,
    val durationMs: Long = 0,
    /** Relative to the music folder, as in the sync manifest. */
    val path: String,
    /** The file on the device: "flac" for songs the Mac converted. */
    val codec: String,
    val sampleRate: Int? = null,
    val bitDepth: Int? = null,
    /** ReplayGain (dB) from the file's tags. */
    val trackGain: Double? = null,
    val albumGain: Double? = null,
    /** The Mac's loudness measurement (LUFS), for songs without ReplayGain. */
    val loudness: Double? = null,
    val loved: Boolean = false,
    /** Epoch milliseconds. */
    val lovedAt: Long? = null,
    val rating: Int = 0,
    val playCount: Int = 0,
    val lastPlayed: Long? = null,
    val dateAdded: Long = 0,
    /** LRC text when synced, plain text otherwise. */
    val lyrics: String? = null,
    val artworkHash: String? = null,
) {
    /** The gain to play it at (dB), as the Mac's Sound Check does: ReplayGain, else the measured loudness against -18 LUFS. */
    val normalizationGain: Double? get() = trackGain ?: loudness?.let { -18.0 - it }
}

@Entity(tableName = "playlist")
data class Playlist(
    @PrimaryKey val id: Long,
    val name: String,
    /** Evaluated by the Mac: its songs are as of the last sync. */
    val isSmart: Boolean = false,
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

/** An artist of the Artists list (album artists, as on the Mac), with how many albums it has here. */
data class ArtistSummary(val name: String, val albums: Int, val artworkHash: String?)

/** A playlist with its song count and a cover (its first song's). */
data class PlaylistSummary(val id: Long, val name: String, val isSmart: Boolean, val songs: Int, val artworkHash: String?)
