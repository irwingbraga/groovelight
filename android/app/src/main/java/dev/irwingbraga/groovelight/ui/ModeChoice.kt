package dev.irwingbraga.groovelight.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.Button
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.irwingbraga.groovelight.sync.Prefs

/** First run: Groovelight plays the music, or another player app does and Groovelight only syncs it. */
@Composable
fun ModeChoice(onChoose: (Prefs.Mode) -> Unit) {
    Column(Modifier.fillMaxSize().safeDrawingPadding().verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("How will you listen?", style = MaterialTheme.typography.headlineMedium)
        Text("Groovelight brings the music you choose on your Mac to this device over Wi-Fi. You can change this later.",
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        ModeCard(
            title = "With Groovelight",
            detail = "Play your Mac library here: albums, playlists, lyrics and the sound settings you know, and what you play goes back to the Mac.",
            action = "Use Groovelight Player",
            primary = true,
        ) { onChoose(Prefs.Mode.PLAYER) }
        ModeCard(
            title = "With another player",
            detail = "Groovelight copies the music into a folder, and your player app (FiiO Music, HiBy Music, Poweramp or another) plays it.",
            action = "Sync Only",
            primary = false,
        ) { onChoose(Prefs.Mode.SYNC_ONLY) }
    }
}

@Composable
private fun ModeCard(title: String, detail: String, action: String, primary: Boolean, onClick: () -> Unit) {
    Card(Modifier.fillMaxWidth(), colors = if (primary) CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)
        else CardDefaults.cardColors()) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(title, style = MaterialTheme.typography.titleLarge)
            Text(detail, style = MaterialTheme.typography.bodyMedium)
            if (primary) Button(onClick = onClick) { Text(action) } else OutlinedButton(onClick = onClick) { Text(action) }
        }
    }
}

/** In the Sync screen: how the music is listened to now, and the switch to the other mode. */
@Composable
fun ListeningCard(mode: Prefs.Mode, onChange: (Prefs.Mode) -> Unit) {
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("Listening", style = MaterialTheme.typography.titleMedium)
            if (mode == Prefs.Mode.PLAYER) {
                Text("Groovelight plays the music.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                TextButton(onClick = { onChange(Prefs.Mode.SYNC_ONLY) }) { Text("Use another player instead") }
            } else {
                Text("Another player app plays the music; Groovelight keeps it in sync.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                TextButton(onClick = { onChange(Prefs.Mode.PLAYER) }) { Text("Try Groovelight Player") }
            }
        }
    }
}
