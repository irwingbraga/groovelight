package dev.irwingbraga.groovelight.ui

import android.app.Application
import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import dev.irwingbraga.groovelight.R
import dev.irwingbraga.groovelight.sync.DeviceFolder
import dev.irwingbraga.groovelight.sync.Prefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/**
 * Phase 0's music list: the songs in the synced folder, by folder, straight from the files. It lets each device show
 * which formats it plays; phase 1 replaces it with the library from the Mac's snapshot.
 */
class FolderMusicModel(application: Application) : AndroidViewModel(application) {
    data class Song(val path: String, val uri: Uri) {
        val name: String get() = path.substringAfterLast('/').substringBeforeLast('.')
        val folder: String get() = path.substringBeforeLast('/', "")
        val format: String get() = path.substringAfterLast('.').uppercase()
    }

    companion object {
        /** What Groovelight on the Mac may put in the folder; whether each plays here is what phase 0 checks. */
        val audioExtensions = setOf("flac", "mp3", "m4a", "aac", "ogg", "oga", "opus", "wav", "aif", "aiff", "wv", "ape", "mpc", "tta", "dsf", "dff")
    }

    val songs = MutableStateFlow<List<Song>?>(null)

    fun load() {
        viewModelScope.launch(Dispatchers.IO) {
            val tree = Prefs(getApplication()).folder ?: return@launch
            val folder = DeviceFolder(getApplication(), Uri.parse(tree))
            songs.value = folder.scan()
                .filter { path -> path.substringAfterLast('.').lowercase() in audioExtensions && !path.substringAfterLast('/').startsWith(".") }
                .sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it })
                .mapNotNull { path -> folder.documentUri(path)?.let { Song(path, it) } }
        }
    }

    fun mediaItems(songs: List<Song>): List<MediaItem> = songs.map { song ->
        MediaItem.Builder()
            .setMediaId(song.path)
            .setUri(song.uri)
            // Until the file's own tags are read by the player.
            .setMediaMetadata(MediaMetadata.Builder().setTitle(song.name).build())
            .build()
    }
}

@Composable
fun FolderMusicScreen(contentPadding: PaddingValues, player: PlayerModel, model: FolderMusicModel = viewModel()) {
    val songs by model.songs.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { model.load() }
    val list = songs
    when {
        list == null -> Box(Modifier.fillMaxSize().padding(contentPadding), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
        list.isEmpty() -> Column(Modifier.fillMaxSize().padding(contentPadding).padding(24.dp), verticalArrangement = Arrangement.Center) {
            Text("No music yet", style = MaterialTheme.typography.titleLarge)
            Text("Choose what this device gets on the Mac (Groovelight, Devices), then sync from the Sync tab.",
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        else -> LazyColumn(Modifier.fillMaxSize(), contentPadding = contentPadding) {
            val folders = list.groupBy { it.folder }
            for ((folder, inFolder) in folders) {
                item(key = "folder:$folder") {
                    ListItem(
                        headlineContent = { Text(folder.substringAfterLast('/').ifEmpty { "Music" }, style = MaterialTheme.typography.titleMedium) },
                        supportingContent = folder.substringBeforeLast('/', "").takeIf { it.isNotEmpty() }?.let { parent -> { Text(parent) } },
                        leadingContent = { Icon(painterResource(R.drawable.ic_folder), contentDescription = null) },
                    )
                }
                items(inFolder, key = { it.path }) { song ->
                    ListItem(
                        headlineContent = { Text(song.name) },
                        trailingContent = { Text(song.format, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant) },
                        modifier = Modifier.clickable { player.play(model.mediaItems(inFolder), inFolder.indexOf(song)) }.padding(start = 40.dp),
                    )
                }
            }
        }
    }
}
