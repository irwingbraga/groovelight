package dev.irwingbraga.groovelight.library

import android.content.Context
import androidx.room.AutoMigration
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase

@Database(
    entities = [Album::class, Track::class, Playlist::class, PlaylistItem::class, Credit::class, SearchEntry::class, MacEqPreset::class,
        HistoryEvent::class, CatalogAlbum::class, CatalogTrack::class, CatalogChosen::class, TransferRequest::class, ArtistPhoto::class,
        CatalogArtistPhoto::class],
    version = 6,
    exportSchema = true,
    // 2: credits, the search index, the Mac's equalizer and the history journal. 3: the Mac's whole library (catalog)
    // and the requests for it. 4: a format with each request. 5: smart playlist rules, and playlist edits in the journal.
    // 6: artists' photos.
    autoMigrations = [AutoMigration(from = 1, to = 2), AutoMigration(from = 2, to = 3), AutoMigration(from = 3, to = 4),
        AutoMigration(from = 4, to = 5), AutoMigration(from = 5, to = 6)],
)
abstract class LibraryDatabase : RoomDatabase() {
    abstract fun library(): LibraryDao
    abstract fun catalog(): CatalogDao

    companion object {
        @Volatile private var instance: LibraryDatabase? = null

        fun get(context: Context): LibraryDatabase = instance ?: synchronized(this) {
            instance ?: Room.databaseBuilder(context.applicationContext, LibraryDatabase::class.java, "library.db").build().also { instance = it }
        }
    }
}
