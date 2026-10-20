package dev.irwingbraga.groovelight.library

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Fts4
import androidx.room.FtsOptions
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
    /** How the Mac draws its cover: "generated" (palette and pattern), "image" or "songs"; null for the songs'. */
    val coverStyle: String? = null,
    val coverPalette: String? = null,
    val coverPattern: String? = null,
    val coverHash: String? = null,
    @ColumnInfo(defaultValue = "1") val coverShowsTitle: Boolean = true,
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

/** Someone credited on an album (`trackId` null) or one of its songs, from the Mac's credit index. */
@Entity(tableName = "credit", indices = [Index("albumKey"), Index("trackId"), Index("name")])
data class Credit(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val name: String,
    /** Roles as the Mac names them ("producer", "guitar"...), one per line. */
    val roles: String,
    val albumKey: String,
    val trackId: Long? = null,
    /** Credited on the release itself (mastering, design...): it applies to every song of the album. */
    val wholeRelease: Boolean = false,
) {
    val roleList: List<String> get() = roles.split('\n').filter { it.isNotBlank() }
}

/**
 * The search index: one row per song (rowid is its id) with the words it is found by, accents ignored. Credits make
 * "Nigel Godrich" find the songs he produced.
 */
@Fts4(tokenizer = FtsOptions.TOKENIZER_UNICODE61, tokenizerArgs = ["remove_diacritics=2"])
@Entity(tableName = "search")
data class SearchEntry(
    @PrimaryKey @ColumnInfo(name = "rowid") val rowid: Long,
    val title: String,
    val artist: String,
    val album: String,
    val credits: String,
)

/** An equalizer curve from the Mac: its saved presets, and the one it uses (`isCurrent`). Bands are JSON, as there. */
@Entity(tableName = "mac_eq_preset", primaryKeys = ["name", "isCurrent"])
data class MacEqPreset(
    val name: String,
    val isCurrent: Boolean,
    val preamp: Double,
    /** `[{"isEnabled":true,"type":"peak","frequency":63,"gain":6,"q":2.15}, ...]` */
    val bands: String,
    /** Whether the Mac's equalizer is on (kept on the current curve's row). */
    val enabled: Boolean = false,
)

/**
 * Something done on this device that the Mac should know (phase 3 sends them): loves and ratings for now. Until sent,
 * they win over the snapshot, so a sync does not undo them.
 */
@Entity(tableName = "history_event", indices = [Index("trackId"), Index("sent")])
data class HistoryEvent(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val trackId: Long,
    /** [LOVE] (value 1 or 0) or [RATING] (0 to 5 stars). */
    val kind: String,
    val value: Int,
    /** Epoch milliseconds. */
    val at: Long,
    val sent: Boolean = false,
) {
    companion object {
        const val LOVE = "love"
        const val RATING = "rating"
    }
}

/** A person credited in the library, with how many albums they are on. */
data class PersonSummary(val name: String, val albums: Int)

/** One credit of a person with what it is on: an album (`trackId` null) or one song. */
data class PersonCredit(val albumKey: String, val trackId: Long?, val roles: String)

/** An artist of the Artists list (album artists, as on the Mac), with how many albums it has here. */
data class ArtistSummary(val name: String, val albums: Int, val artworkHash: String?)

/** A playlist with its song count, its first song's cover, and how the Mac draws its own cover. */
data class PlaylistSummary(
    val id: Long,
    val name: String,
    val isSmart: Boolean,
    val songs: Int,
    val artworkHash: String?,
    val coverStyle: String? = null,
    val coverPalette: String? = null,
    val coverPattern: String? = null,
    val coverHash: String? = null,
    val coverShowsTitle: Boolean = true,
)

// The Mac's whole library (the catalog, protocol v2), for browsing what is not on the device and asking for it.

@Entity(tableName = "catalog_album", indices = [Index("artist")])
data class CatalogAlbum(
    @PrimaryKey val key: String,
    val title: String,
    val artist: String,
    val year: Int? = null,
    val isCompilation: Boolean = false,
    val artworkHash: String? = null,
)

@Entity(tableName = "catalog_track", indices = [Index("albumKey"), Index("artist")])
data class CatalogTrack(
    @PrimaryKey val id: Long,
    val title: String,
    val artist: String,
    val albumKey: String,
    val discNumber: Int? = null,
    val trackNumber: Int? = null,
    val durationMs: Long = 0,
    /** The file on the Mac ("flac", "alac", "mp3"...). */
    val codec: String,
    val sampleRate: Int? = null,
    val bitDepth: Int? = null,
    val genre: String? = null,
    val year: Int? = null,
    val artworkHash: String? = null,
)

/** What the device's selection on the Mac holds: [kind] is "album", "artist", "song", "everything" or "others". */
@Entity(tableName = "catalog_chosen", primaryKeys = ["kind", "key"])
data class CatalogChosen(val kind: String, val key: String)

/**
 * An album, artist or song asked for on the device (or to remove), waiting to reach the Mac: requests made while the
 * Mac is away are kept and sent, in order, when it is reachable again.
 */
@Entity(tableName = "transfer_request")
data class TransferRequest(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    /** "add" or "remove". */
    val action: String,
    /** "album", "artist", "song" or "playlist". */
    val kind: String,
    /** The album key, the artist's name, the song's id or the playlist's id. */
    val key: String,
    /** Epoch milliseconds. */
    val createdAt: Long = System.currentTimeMillis(),
) {
    companion object {
        const val ADD = "add"
        const val REMOVE = "remove"
        const val ALBUM = "album"
        const val ARTIST = "artist"
        const val SONG = "song"
        const val PLAYLIST = "playlist"
    }
}

/** An artist of the Mac's library, with how many albums it has there. */
data class CatalogArtist(val name: String, val albums: Int, val artworkHash: String?)
