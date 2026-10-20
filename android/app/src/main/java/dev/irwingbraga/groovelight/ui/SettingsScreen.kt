package dev.irwingbraga.groovelight.ui

import android.os.Build
import android.text.format.DateUtils
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.irwingbraga.groovelight.R
import dev.irwingbraga.groovelight.playback.PlaybackSettings
import dev.irwingbraga.groovelight.sync.SyncViewModel

/** The Settings tab: the Mac and syncing, then what changes the sound (equalizer, volume, bit-perfect output). */
@Composable
fun SettingsScreen(sync: SyncViewModel) {
    val actions = LocalActions.current
    val context = LocalContext.current
    val reachable by sync.reachable.collectAsStateWithLifecycle()
    val eqEnabled by PlaybackSettings.eqEnabled.collectAsStateWithLifecycle()
    val curve by PlaybackSettings.curve.collectAsStateWithLifecycle()
    val normalization by PlaybackSettings.normalization.collectAsStateWithLifecycle()
    val bitPerfect by PlaybackSettings.bitPerfect.collectAsStateWithLifecycle()
    val bitPerfectActive by PlaybackSettings.bitPerfectActive.collectAsStateWithLifecycle()
    val version = runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull()
    Column(Modifier.fillMaxSize()) {
        SettingsBar("Settings", back = false)
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(bottom = 16.dp + LocalBottomInset.current)) {
            SettingsSection("Mac")
            val mac = sync.prefs.macName
            val last = sync.prefs.lastSync.takeIf { it > 0 }?.let {
                "Synced " + DateUtils.getRelativeTimeSpanString(it, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS)
            }
            SettingsRow(
                icon = R.drawable.ic_laptop,
                title = if (mac != null) "Sync with $mac" else "Sync",
                detail = when {
                    mac == null -> "Pair with Groovelight on your Mac"
                    reachable == false -> listOfNotNull("The Mac is not reachable", last).joinToString(" · ")
                    else -> last ?: "Not synced yet"
                },
                onClick = { actions.open(Route.Sync) },
            )

            SettingsSection("Sound")
            SettingsRow(
                icon = R.drawable.ic_equalizer, title = "Equalizer",
                detail = if (eqEnabled) "On · ${curve.name.ifEmpty { "Custom" }}" else "Off",
                onClick = { actions.open(Route.Equalizer) },
            ) {
                Switch(checked = eqEnabled, onCheckedChange = PlaybackSettings::setEqEnabled)
            }
            ListItem(
                leadingContent = { Icon(painterResource(R.drawable.ic_volume), contentDescription = null) },
                headlineContent = { Text("Volume Normalization") },
                supportingContent = {
                    Column {
                        Text(when (normalization) {
                            PlaybackSettings.Normalization.TRACK -> "Every song at the same loudness (ReplayGain, or the Mac's measurement)."
                            PlaybackSettings.Normalization.ALBUM -> "Albums keep their own dynamics: quiet songs stay quiet."
                            PlaybackSettings.Normalization.OFF -> "Songs play as they were mastered."
                        })
                        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(top = 8.dp)) {
                            PlaybackSettings.Normalization.entries.forEachIndexed { index, mode ->
                                SegmentedButton(selected = normalization == mode, onClick = { PlaybackSettings.setNormalization(mode) },
                                    shape = SegmentedButtonDefaults.itemShape(index, PlaybackSettings.Normalization.entries.size)) { Text(mode.label) }
                            }
                        }
                    }
                },
                colors = ListItemDefaults.colors(containerColor = Color.Transparent),
            )
            val supported = Build.VERSION.SDK_INT >= 34
            SettingsRow(
                icon = R.drawable.ic_usb, title = "Bit-Perfect USB Output",
                detail = when {
                    !supported -> "Needs Android 14 or later."
                    bitPerfectActive -> "Playing bit-perfect now. The equalizer, volume normalization and speed are off meanwhile."
                    else -> "Sends songs to a USB DAC exactly as they are, at their own sample rate, when it accepts them."
                },
                enabled = supported,
                onClick = { PlaybackSettings.setBitPerfect(!bitPerfect) },
            ) {
                Switch(checked = bitPerfect && supported, enabled = supported, onCheckedChange = PlaybackSettings::setBitPerfect)
            }

            SettingsSection("About")
            SettingsRow(icon = R.drawable.ic_info, title = "Groovelight", detail = listOfNotNull(version?.let { "Version $it" }, "Plays the music your Mac syncs")
                .joinToString(" · "))
        }
    }
}

@Composable
private fun SettingsSection(title: String) {
    Text(title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, top = 24.dp, bottom = 4.dp).semantics { heading() })
}

@Composable
private fun SettingsRow(
    icon: Int,
    title: String,
    detail: String? = null,
    enabled: Boolean = true,
    onClick: (() -> Unit)? = null,
    trailing: (@Composable RowScope.() -> Unit)? = null,
) {
    ListItem(
        leadingContent = { Icon(painterResource(icon), contentDescription = null) },
        headlineContent = { Text(title) },
        supportingContent = detail?.let { { Text(it) } },
        trailingContent = when {
            trailing != null -> ({ Row { trailing() } })
            onClick != null -> ({ Icon(painterResource(R.drawable.ic_chevron_right), contentDescription = null) })
            else -> null
        },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        modifier = if (onClick != null) Modifier.clickable(enabled = enabled, onClick = onClick) else Modifier,
    )
}

/** The bar of Settings and its pages: Back (but on the tab's first screen), the title, and actions. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsBar(title: String, back: Boolean = true, actions: @Composable RowScope.() -> Unit = {}) {
    val goBack = LocalBack.current
    TopAppBar(
        title = { Text(title) },
        navigationIcon = { if (back) IconButton(onClick = goBack) { Icon(painterResource(R.drawable.ic_back), contentDescription = "Back") } },
        actions = actions,
    )
}
