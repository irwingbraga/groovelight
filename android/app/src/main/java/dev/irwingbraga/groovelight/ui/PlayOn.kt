package dev.irwingbraga.groovelight.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.material3.Switch
import androidx.compose.material3.Card
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.irwingbraga.groovelight.R

/**
 * Where music plays: this device, the paired Mac, or another phone with Groovelight open (when the Mac lets this device
 * control playback, on its page for the device). Choosing another one takes what plays along, at the same place. Shown
 * only once paired.
 */
@Composable
fun PlayOnButton(player: PlayerModel) {
    val remote = player.remote
    if (!remote.isPaired) return
    val target by player.target.collectAsStateWithLifecycle()
    val availability by remote.availability.collectAsStateWithLifecycle()
    val devices by remote.devices.collectAsStateWithLifecycle()
    // Paired: other devices can play here from now on.
    LaunchedEffect(Unit) { player.relay.start() }
    var open by remember { mutableStateOf(false) }
    var moving by remember { mutableStateOf(false) }
    LaunchedEffect(open) { if (open) remote.check() }
    Box {
        IconButton(onClick = { open = true }) {
            Icon(painterResource(R.drawable.ic_speaker),
                contentDescription = if (target != PlayerModel.Target.THIS_DEVICE) "Playing on ${player.targetName(target)}" else "Play On",
                tint = if (target != PlayerModel.Target.THIS_DEVICE) MaterialTheme.colorScheme.primary else LocalContentColor.current)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, modifier = Modifier.widthIn(max = 320.dp)) {
            Text("Play On", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
            fun choose(choice: PlayerModel.Target) {
                moving = true
                player.choose(choice) { moving = false; open = false }
            }
            DropdownMenuItem(
                text = { Text("This device") },
                leadingIcon = { Icon(painterResource(R.drawable.ic_phone), null) },
                trailingIcon = { Marker(target == PlayerModel.Target.THIS_DEVICE, moving && target != PlayerModel.Target.THIS_DEVICE) },
                enabled = !moving,
                onClick = { choose(PlayerModel.Target.THIS_DEVICE) },
            )
            DropdownMenuItem(
                text = { Text(remote.macName) },
                leadingIcon = { Icon(painterResource(R.drawable.ic_laptop), null) },
                trailingIcon = { Marker(target == PlayerModel.Target.MAC, moving && target != PlayerModel.Target.MAC) },
                enabled = !moving && (availability == MacRemote.Availability.Available || target == PlayerModel.Target.MAC),
                onClick = { choose(PlayerModel.Target.MAC) },
            )
            // The devices there now, and the one music plays on even if it has just gone.
            val current = (target as? PlayerModel.Target.Device)?.device
            (devices + listOfNotNull(current?.takeIf { chosen -> devices.none { it.id == chosen.id } })).forEach { device ->
                val choice = PlayerModel.Target.Device(device)
                DropdownMenuItem(
                    text = { Text(device.name) },
                    leadingIcon = { Icon(painterResource(R.drawable.ic_phone), null) },
                    trailingIcon = { Marker(target == choice, moving && target != choice) },
                    enabled = !moving,
                    onClick = { choose(choice) },
                )
            }
            val note = when (availability) {
                MacRemote.Availability.Unknown, MacRemote.Availability.Checking -> "Looking for ${remote.macName}…"
                MacRemote.Availability.NotAllowed ->
                    "Turn on “Let this device play music on this Mac and your other devices” on this device's page under Devices on the Mac."
                is MacRemote.Availability.Unreachable -> "Open Groovelight on the Mac, on the same Wi-Fi as this device."
                MacRemote.Availability.Available -> null
            }
            note?.let {
                Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    if (availability == MacRemote.Availability.Checking) {
                        CircularProgressIndicator(Modifier.padding(end = 8.dp).size(14.dp), strokeWidth = 2.dp)
                    }
                    Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}

@Composable
private fun Marker(chosen: Boolean, moving: Boolean) {
    when {
        moving -> CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
        chosen -> Icon(painterResource(R.drawable.ic_check_circle), contentDescription = "Chosen", tint = MaterialTheme.colorScheme.primary)
    }
}

/** "Let other devices play here": this device in the Play On list of the others paired with the Mac. */
@Composable
fun PlayHereCard(player: PlayerModel) {
    val enabled by player.relay.enabled.collectAsStateWithLifecycle()
    Card(Modifier.fillMaxWidth()) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Let other devices play here", style = MaterialTheme.typography.bodyLarge)
                Text("While Groovelight is open here, your other phones paired with ${player.remote.macName} can choose this device under Play On and play its songs here. The Mac lets each device do this on its page under Devices.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Switch(enabled, player.relay::setEnabled, Modifier.padding(start = 12.dp))
        }
    }
}
