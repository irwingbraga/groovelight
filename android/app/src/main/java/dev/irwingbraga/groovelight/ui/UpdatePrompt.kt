package dev.irwingbraga.groovelight.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.irwingbraga.groovelight.update.AppUpdates
import dev.irwingbraga.groovelight.update.UpdateState
import dev.irwingbraga.groovelight.update.readableNotes

/**
 * The GitHub build's update offer: checked once a day at launch; a newer release is offered once (Later skips that
 * version; Settings, App Updates still has it), and once accepted, its download and install show here.
 */
@Composable
fun UpdatePrompt() {
    if (!AppUpdates.SUPPORTED) return
    val context = LocalContext.current
    val state by AppUpdates.state.collectAsStateWithLifecycle()
    val dismissed by AppUpdates.dismissed.collectAsStateWithLifecycle()
    // Following an install the user started (here or in Settings): its progress and how it ended show.
    var following by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { AppUpdates.checkIfDue(context) }
    LaunchedEffect(state) { if (state is UpdateState.Downloading || state is UpdateState.Installing) following = true }
    when (val current = state) {
        is UpdateState.Available -> if (current.version != dismissed) UpdateDialog(current, onUpdate = { AppUpdates.install(context) },
            onLater = { AppUpdates.dismiss(context, current.version) })
        is UpdateState.Downloading -> if (following) AlertDialog(
            onDismissRequest = {},
            title = { Text("Downloading Groovelight ${current.version}") },
            text = {
                Column {
                    LinearProgressIndicator(progress = { current.fraction }, modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp))
                    Text("${(current.fraction * 100).toInt()}%", style = MaterialTheme.typography.bodySmall)
                }
            },
            confirmButton = {},
        )
        is UpdateState.Failed -> if (following) AlertDialog(
            onDismissRequest = { following = false },
            title = { Text("The update did not install") },
            text = { Text(current.message) },
            confirmButton = { if (current.available != null) TextButton(onClick = { AppUpdates.install(context) }) { Text("Try Again") } },
            dismissButton = { TextButton(onClick = { following = false }) { Text("Close") } },
        )
        else -> {}
    }
}

@Composable
fun UpdateDialog(update: UpdateState.Available, onUpdate: () -> Unit, onLater: () -> Unit) {
    AlertDialog(
        onDismissRequest = onLater,
        title = { Text("Groovelight ${update.version} is available") },
        text = {
            Column(Modifier.heightIn(max = 320.dp).verticalScroll(rememberScrollState())) {
                Text("You have ${dev.irwingbraga.groovelight.BuildConfig.VERSION_NAME}. Android asks to confirm the installation; your music, " +
                    "library and settings stay.", style = MaterialTheme.typography.bodyMedium)
                val notes = remember(update.notes) { readableNotes(update.notes) }
                if (notes.isNotBlank()) {
                    Text(notes.take(1_200), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 12.dp))
                }
            }
        },
        confirmButton = { TextButton(onClick = onUpdate) { Text("Update") } },
        dismissButton = { TextButton(onClick = onLater) { Text("Later") } },
    )
}
