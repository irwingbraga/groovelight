package dev.irwingbraga.groovelight.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Card
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.irwingbraga.groovelight.R
import dev.irwingbraga.groovelight.playback.AudioPath
import dev.irwingbraga.groovelight.sync.SyncScreen
import dev.irwingbraga.groovelight.sync.SyncViewModel

/** Player mode: Music and Sync tabs, with the mini player above the navigation bar and Now Playing as a sheet. */
@Composable
fun PlayerShell(sync: SyncViewModel, player: PlayerModel = viewModel()) {
    var tab by rememberSaveable { mutableIntStateOf(0) }
    var showNowPlaying by rememberSaveable { mutableStateOf(false) }
    val nowPlaying by player.nowPlaying.collectAsStateWithLifecycle()
    val mode by sync.mode.collectAsStateWithLifecycle()

    Scaffold(bottomBar = {
        Column {
            nowPlaying?.let { MiniPlayer(it, player, onOpen = { showNowPlaying = true }) }
            NavigationBar {
                NavigationBarItem(selected = tab == 0, onClick = { tab = 0 }, label = { Text("Music") },
                    icon = { Icon(painterResource(R.drawable.ic_music), contentDescription = null) })
                NavigationBarItem(selected = tab == 1, onClick = { tab = 1 }, label = { Text("Sync") },
                    icon = { Icon(painterResource(R.drawable.ic_sync), contentDescription = null) })
            }
        }
    }) { padding ->
        when (tab) {
            0 -> FolderMusicScreen(padding, player)
            else -> Box(Modifier.padding(padding).consumeWindowInsets(padding)) {
                SyncScreen("Sync", sync) { mode?.let { ListeningCard(it, sync::setMode) } }
            }
        }
    }

    val current = nowPlaying
    if (showNowPlaying && current != null) NowPlayingSheet(current, player) { showNowPlaying = false }
}

@Composable
private fun MiniPlayer(song: PlayerModel.NowPlaying, player: PlayerModel, onOpen: () -> Unit) {
    val path by player.audioPath.collectAsStateWithLifecycle()
    val problem = song.error ?: path.unsupported?.let { "Cannot decode $it" }
    Surface(color = MaterialTheme.colorScheme.surfaceContainerHigh, modifier = Modifier.fillMaxWidth().clickable(onClick = onOpen)) {
        Row(Modifier.padding(start = 16.dp, end = 8.dp, top = 8.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(song.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(problem ?: song.artist ?: "", style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    color = if (problem != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
            }
            IconButton(onClick = player::togglePlayPause) {
                Icon(painterResource(if (song.isPlaying) R.drawable.ic_pause else R.drawable.ic_play), contentDescription = if (song.isPlaying) "Pause" else "Play")
            }
            IconButton(onClick = player::next, enabled = song.hasNext) {
                Icon(painterResource(R.drawable.ic_skip_next), contentDescription = "Next")
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NowPlayingSheet(song: PlayerModel.NowPlaying, player: PlayerModel, onDismiss: () -> Unit) {
    val path by player.audioPath.collectAsStateWithLifecycle()
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Column {
                Text(song.title, style = MaterialTheme.typography.headlineSmall)
                listOfNotNull(song.artist, song.album).takeIf { it.isNotEmpty() }?.let {
                    Text(it.joinToString(" · "), style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = player::previous) { Icon(painterResource(R.drawable.ic_skip_previous), contentDescription = "Previous") }
                FilledIconButton(onClick = player::togglePlayPause, modifier = Modifier.padding(horizontal = 24.dp).size(64.dp)) {
                    Icon(painterResource(if (song.isPlaying) R.drawable.ic_pause else R.drawable.ic_play),
                        contentDescription = if (song.isPlaying) "Pause" else "Play", modifier = Modifier.size(32.dp))
                }
                IconButton(onClick = player::next, enabled = song.hasNext) { Icon(painterResource(R.drawable.ic_skip_next), contentDescription = "Next") }
            }
            AudioPathCard(path, song.error)
        }
    }
}

/** How this device plays the song: the check each format gets in phase 0 (on the phone and the HiBy R4). */
@Composable
private fun AudioPathCard(path: AudioPath, error: String?) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("Audio path", style = MaterialTheme.typography.titleSmall)
            if (error != null) Text("Cannot play: $error", color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
            path.unsupported?.let {
                Text("This device cannot decode $it.", color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium)
            }
            if (error == null) {
                PathLine("File", path.source)
                PathLine("Decoder", path.decoder)
                PathLine("To Android", path.output?.let { if (path.offloaded) "$it (offloaded)" else it })
            }
        }
    }
}

@Composable
private fun PathLine(label: String, value: String?) {
    Row {
        Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(0.35f))
        Text(value ?: "-", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(0.65f))
    }
}
