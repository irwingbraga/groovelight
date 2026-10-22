package dev.irwingbraga.groovelight.app

import android.app.Application
import dev.irwingbraga.groovelight.library.LibraryDatabase
import androidx.glance.appwidget.updateAll
import dev.irwingbraga.groovelight.playback.Browsing
import dev.irwingbraga.groovelight.playback.Listens
import dev.irwingbraga.groovelight.playback.NowPlayingInfo
import dev.irwingbraga.groovelight.widget.NowPlayingWidget
import dev.irwingbraga.groovelight.widget.RecentlyPlayedWidget
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import dev.irwingbraga.groovelight.sync.RequestWorker
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Connects the player to the library: songs heard count as plays or skips, and reach the Mac (and Last.fm); smart
 * playlists are evaluated again on start; the home screen widgets follow what plays and what was played; Android Auto
 * browses the library ([LibraryBrowsing]).
 */
class GroovelightApp : Application() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onCreate() {
        super.onCreate()
        // Android Auto browses the library through the player.
        Browsing.current = LibraryBrowsing(this)
        // Smart playlists with dates ("played in the last 2 weeks") change with time alone.
        scope.launch { LibraryDatabase.get(this@GroovelightApp).library().refreshSmartPlaylists() }
        // The home screen widgets follow the player and the library.
        scope.launch { NowPlayingInfo.current.collect { NowPlayingWidget().updateAll(this@GroovelightApp) } }
        scope.launch {
            LibraryDatabase.get(this@GroovelightApp).library().recentlyPlayedAlbums(RecentlyPlayedWidget.MAX)
                .map { albums -> albums.map { it.key to it.artworkHash } }.distinctUntilChanged()
                .collect { RecentlyPlayedWidget().updateAll(this@GroovelightApp) }
        }
        Listens.onListen = { listen ->
            scope.launch {
                val id = listen.mediaId.toLongOrNull() ?: return@launch
                if (LibraryDatabase.get(this@GroovelightApp).library().recordListen(id, listen.startedAt, listen.listenedMs)) {
                    RequestWorker.schedule(this@GroovelightApp)
                }
            }
        }
    }
}
