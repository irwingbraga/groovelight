package dev.irwingbraga.groovelight.ui

import androidx.compose.ui.semantics.stateDescription
import kotlin.math.roundToInt
import androidx.compose.material3.Slider
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
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateOf
import androidx.compose.foundation.layout.Box
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.DpOffset
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.DropdownMenu
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.irwingbraga.groovelight.R
import dev.irwingbraga.groovelight.playback.PlaybackSettings
import dev.irwingbraga.groovelight.sync.SyncViewModel
import dev.irwingbraga.groovelight.update.AppUpdates
import dev.irwingbraga.groovelight.update.UpdateState

/** The Settings tab: the Mac and syncing, what changes the sound (equalizer, volume, bit-perfect output), and the theme. */
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
    GlassTop(bar = { SettingsBar("Settings", back = false) }) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(top = LocalTopInset.current, bottom = 16.dp + LocalBottomInset.current)) {
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
                    sync.prefs.isAway -> listOfNotNull("Away from home, through Tailscale", last).joinToString(" · ")
                    else -> last ?: "Not synced yet"
                },
                onClick = { actions.open(Route.Sync) },
            )
            // Away from home (the Mac reached through Tailscale), songs come down over mobile data only when allowed.
            if (mac != null && sync.prefs.awayHosts.isNotEmpty()) {
                var mobileData by remember { mutableStateOf(sync.prefs.syncsOverMobileData) }
                SettingsRow(
                    icon = R.drawable.ic_download, title = "Sync over Mobile Data",
                    detail = "Away from home, the Mac is reached through Tailscale when it is on here and on the Mac, and the Mac allows it on this device's page. Without this, syncing then waits for Wi-Fi.",
                    onClick = { mobileData = !mobileData; sync.prefs.syncsOverMobileData = mobileData },
                ) {
                    Switch(checked = mobileData, onCheckedChange = { mobileData = it; sync.prefs.syncsOverMobileData = it })
                }
            }

            // The library: only what is here, or the Mac's music too (the Library's Downloaded filter).
            val source by actions.library.source.collectAsStateWithLifecycle()
            SettingsRow(
                icon = R.drawable.ic_library, title = "Show the Mac's Music",
                detail = "The Library shows your Mac's whole library with what is here (marked with a check), to add music from it.",
                onClick = { actions.library.setSource(if (source == LibraryModel.Source.MAC) LibraryModel.Source.DEVICE else LibraryModel.Source.MAC) },
            ) {
                Switch(checked = source == LibraryModel.Source.MAC, onCheckedChange = {
                    actions.library.setSource(if (it) LibraryModel.Source.MAC else LibraryModel.Source.DEVICE)
                })
            }
            // The format lossless songs come in, unless one was chosen for an album or artist when adding it.
            val encoding by actions.library.encoding.collectAsStateWithLifecycle()
            val current = encoding ?: actions.library.macEncoding ?: "original"
            var formats by remember { mutableStateOf(false) }
            Box {
                SettingsRow(
                    icon = R.drawable.ic_file, title = "Lossless Songs",
                    detail = formatLabel(current) + if (current == "original") ": as they are (FLAC and the like)." else
                        ": smaller, about a fifth of the size. Albums can also be added in a format of their own.",
                    onClick = { formats = true },
                )
                FormatMenu(formats, onDismiss = { formats = false }, title = "Lossless songs come as", current = current) {
                    if (it != current) {
                        actions.library.setEncoding(it)
                        actions.notify("Songs here change to ${formatLabel(it)} at the next sync")
                    }
                }
            }

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
            val crossfade by PlaybackSettings.crossfade.collectAsStateWithLifecycle()
            ListItem(
                leadingContent = { Icon(painterResource(R.drawable.ic_shuffle), contentDescription = null) },
                headlineContent = { Text("Crossfade") },
                supportingContent = {
                    Column {
                        Text(if (crossfade == 0) "Off: songs follow each other without a gap." else
                            "$crossfade seconds: each song fades into the next. Songs of the same album stay gapless.")
                        Slider(value = crossfade.toFloat(), onValueChange = { PlaybackSettings.setCrossfade(it.roundToInt()) },
                            valueRange = 0f..12f, steps = 11, modifier = Modifier.fillMaxWidth().semantics {
                                stateDescription = if (crossfade == 0) "Off" else "$crossfade seconds"
                            })
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

            SettingsSection("Appearance")
            val theme by Appearance.theme.collectAsStateWithLifecycle()
            ListItem(
                leadingContent = { Icon(painterResource(R.drawable.ic_contrast), contentDescription = null) },
                headlineContent = { Text("Theme") },
                supportingContent = {
                    Column {
                        Text("System follows Android's setting. The Shelf is always dark.")
                        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(top = 8.dp)) {
                            AppTheme.entries.forEachIndexed { index, option ->
                                SegmentedButton(selected = theme == option, onClick = { Appearance.set(option) },
                                    shape = SegmentedButtonDefaults.itemShape(index, AppTheme.entries.size)) { Text(option.label) }
                            }
                        }
                    }
                },
                colors = ListItemDefaults.colors(containerColor = Color.Transparent),
            )

            val skin by Cassettes.skin.collectAsStateWithLifecycle()
            val cassetteId by Cassettes.cassetteId.collectAsStateWithLifecycle()
            SettingsRow(
                icon = R.drawable.ic_cassette, title = "Now Playing Look",
                detail = if (skin == NowPlayingSkin.CASSETTE) "Cassette · ${Cassettes.design(cassetteId).name}" else skin.label,
                onClick = { actions.open(Route.Cassettes) },
            )

            // The mini player put away after a while paused (playing anything brings it back).
            val hideAfter by actions.player.hideAfter.collectAsStateWithLifecycle()
            var hideMenu by remember { mutableStateOf(false) }
            Box {
                SettingsRow(
                    icon = R.drawable.ic_schedule, title = "Hide the Player When Paused",
                    detail = (if (hideAfter == 0) "Never" else "After $hideAfter minutes paused") +
                        ". Swipe it down, or hold it, to close it at any time.",
                    onClick = { hideMenu = true },
                )
                DropdownMenu(hideMenu, onDismissRequest = { hideMenu = false }, offset = DpOffset(56.dp, 0.dp)) {
                    listOf(10, 15, 20, 30, 0).forEach { minutes ->
                        DropdownMenuItem(
                            text = { Text(if (minutes == 0) "Never" else "After $minutes minutes") },
                            trailingIcon = { if (minutes == hideAfter) Icon(painterResource(R.drawable.ic_check_circle), null) },
                            onClick = { hideMenu = false; actions.player.setHideAfter(minutes) },
                        )
                    }
                }
            }

            SettingsSection("About")
            SettingsRow(icon = R.drawable.ic_info, title = "Groovelight", detail = listOfNotNull(version?.let { "Version $it" }, "Plays the music your Mac syncs")
                .joinToString(" · "))
            if (AppUpdates.SUPPORTED) {
                val update by AppUpdates.state.collectAsStateWithLifecycle()
                val ready = update is UpdateState.Available || (update as? UpdateState.Failed)?.available != null
                SettingsRow(
                    icon = R.drawable.ic_download, title = "App Updates",
                    detail = when (val state = update) {
                        UpdateState.Idle -> "Checks GitHub for a newer Groovelight once a day"
                        UpdateState.Checking -> "Checking…"
                        is UpdateState.UpToDate -> "Groovelight is up to date"
                        is UpdateState.Available -> "Version ${state.version} is available: tap to install"
                        is UpdateState.Downloading -> "Downloading ${state.version}… ${(state.fraction * 100).toInt()}%"
                        is UpdateState.Installing -> "Installing ${state.version}…"
                        is UpdateState.Failed -> state.message
                    },
                    onClick = { if (ready) AppUpdates.install(context) else AppUpdates.check(context) },
                )
            }
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

/** The bar of Settings and its pages: Back (but on the tab's first screen), the title, and actions; clear, for [GlassTop]. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsBar(title: String, back: Boolean = true, actions: @Composable RowScope.() -> Unit = {}) {
    val goBack = LocalBack.current
    TopAppBar(
        title = { Text(title) },
        navigationIcon = { if (back) IconButton(onClick = goBack) { Icon(painterResource(R.drawable.ic_back), contentDescription = "Back") } },
        actions = actions,
        // Clear: it sits on glass ([GlassTop]).
        colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent, scrolledContainerColor = Color.Transparent),
    )
}
