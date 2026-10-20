package dev.irwingbraga.groovelight.library

import android.content.Context
import androidx.room.AutoMigration
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase

@Database(
    entities = [Album::class, Track::class, Playlist::class, PlaylistItem::class, Credit::class, SearchEntry::class, MacEqPreset::class,
        HistoryEvent::class, CatalogAlbum::class, CatalogTrack::class, CatalogChosen::class, TransferRequest::class],
    version = 3,
    exportSchema = true,
    // 2: credits, the search index, the Mac's equalizer and the history journal. 3: the Mac's whole library (catalog)
    // and the requests for it.
    autoMigrations = [AutoMigration(from = 1, to = 2), AutoMigration(from = 2, to = 3)],
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
