package dev.irwingbraga.groovelight.ui

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.irwingbraga.groovelight.R
import dev.irwingbraga.groovelight.playback.EqBand
import dev.irwingbraga.groovelight.playback.EqFilter
import dev.irwingbraga.groovelight.playback.EqMath
import dev.irwingbraga.groovelight.playback.EqPreset
import dev.irwingbraga.groovelight.playback.ParametricEqFile
import dev.irwingbraga.groovelight.playback.PlaybackSettings
import kotlin.math.hypot
import kotlin.math.log10
import kotlin.math.pow

/**
 * The 15-band parametric equalizer, as on the Mac: drag a band's point on the curve (sideways for its frequency, up
 * and down for its gain), pinch it to make it wider or narrower (Q), or set it exactly below. Presets: the built-in
 * ones, the Mac's (with the curve it uses), the ones saved here, and AutoEq files for headphones.
 */
@Composable
fun EqualizerScreen() {
    val enabled by PlaybackSettings.eqEnabled.collectAsStateWithLifecycle()
    val curve by PlaybackSettings.curve.collectAsStateWithLifecycle()
    val autoPreamp by PlaybackSettings.autoPreamp.collectAsStateWithLifecycle()
    val bitPerfect by PlaybackSettings.bitPerfectActive.collectAsStateWithLifecycle()
    var selected by rememberSaveable { mutableIntStateOf(8) }
    var presets by rememberSaveable { mutableStateOf(false) }
    GlassTop(bar = {
        SettingsBar("Equalizer") {
            Switch(checked = enabled, onCheckedChange = PlaybackSettings::setEqEnabled, modifier = Modifier.padding(end = 12.dp)
                .semantics { contentDescription = "Equalizer" })
        }
    }) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(top = LocalTopInset.current, bottom = 24.dp + LocalBottomInset.current)) {
            if (bitPerfect) {
                Notice("Playing bit-perfect to the USB DAC: the equalizer is off until the next song that is not.")
            }
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f).clickable(onClickLabel = "Choose a preset") { presets = true }.padding(vertical = 8.dp)) {
                    Text("Preset", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(curve.name.ifEmpty { "Custom" }, style = MaterialTheme.typography.titleMedium)
                }
                OutlinedButton(onClick = { presets = true }) { Text("Presets") }
            }
            CurveEditor(curve, enabled, selected, onSelect = { selected = it }, modifier = Modifier.padding(horizontal = 16.dp))
            // The band chosen on the curve comes into view among the chips.
            val chips = rememberLazyListState()
            LaunchedEffect(selected) { chips.animateScrollToItem((selected - 2).coerceAtLeast(0)) }
            LazyRow(state = chips, contentPadding = PaddingValues(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier.padding(top = 8.dp)) {
                itemsIndexed(curve.bands) { index, band ->
                    FilterChip(selected = index == selected, onClick = { selected = index },
                        label = { Text(frequencyLabel(band.frequency), color = if (band.enabled) Color.Unspecified else MaterialTheme.colorScheme.outline) })
                }
            }
            curve.bands.getOrNull(selected)?.let { band -> BandEditor(selected, band) }
            Card(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
                Column(Modifier.padding(16.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("Preamp", style = MaterialTheme.typography.titleSmall)
                            Text("%+.1f dB".format(curve.preamp), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Text("Auto", style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(end = 8.dp))
                        Switch(checked = autoPreamp, onCheckedChange = PlaybackSettings::setAutoPreamp)
                    }
                    Slider(value = curve.preamp.toFloat(), onValueChange = { PlaybackSettings.setPreamp(it.toDouble()) },
                        valueRange = -24f..24f, modifier = Modifier.semantics { stateDescription = "%+.1f dB".format(curve.preamp) })
                    Text(if (autoPreamp) "Lowers the volume by the curve's loudest boost, so it never clips." else "Set by hand.",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            TextButton(onClick = { PlaybackSettings.setCurve(EqPreset.FLAT) }, modifier = Modifier.padding(horizontal = 8.dp)) { Text("Reset to Flat") }
        }
    }
    if (presets) PresetSheet(curve) { presets = false }
}

/** The response curve on a log frequency axis (20 Hz to 20 kHz, -24 to +24 dB), with a point per band. */
@Composable
private fun CurveEditor(curve: EqPreset, enabled: Boolean, selected: Int, onSelect: (Int) -> Unit, modifier: Modifier = Modifier) {
    val line = if (enabled) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline
    val grid = MaterialTheme.colorScheme.outlineVariant
    val node = MaterialTheme.colorScheme.onSurface
    val bands by rememberUpdatedState(curve.bands)
    val pick by rememberUpdatedState(onSelect)
    val chosen by rememberUpdatedState(selected)
    Card(modifier.fillMaxWidth().height(220.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh)) {
        Canvas(Modifier.fillMaxSize().padding(12.dp)
            .semantics { contentDescription = "Equalizer curve. Drag a point to change its band, pinch it to change its width." }
            .pointerInput(Unit) {
                awaitEachGesture {
                    val down = awaitFirstDown()
                    // The nearest band's point, within reach of a finger; otherwise the band selected keeps it.
                    val nearest = bands.indices.minByOrNull { hypot(x(bands[it].frequency, size.width.toFloat()) - down.position.x,
                        y(nodeGain(bands[it]), size.height.toFloat()) - down.position.y) }
                    val index = nearest?.takeIf { hypot(x(bands[it].frequency, size.width.toFloat()) - down.position.x,
                        y(nodeGain(bands[it]), size.height.toFloat()) - down.position.y) < 48.dp.toPx() } ?: chosen
                    pick(index)
                    var spread: Float? = null
                    while (true) {
                        val event = awaitPointerEvent()
                        val pressed = event.changes.filter { it.pressed }
                        if (pressed.isEmpty()) break
                        if (pressed.size >= 2) {
                            // Two fingers: closer or wider apart changes Q (wider apart, a wider band: lower Q).
                            val distance = (pressed[0].position - pressed[1].position).getDistance()
                            spread?.let { previous ->
                                if (previous > 0f) {
                                    val factor = previous / distance
                                    PlaybackSettings.updateBand(index) { it.copy(q = (it.q * factor).coerceIn(EqMath.Q_RANGE)) }
                                }
                            }
                            spread = distance
                        } else {
                            spread = null
                            val change = pressed[0]
                            val delta = change.positionChange()
                            if (delta != Offset.Zero) {
                                val position = change.position
                                PlaybackSettings.updateBand(index) { band ->
                                    val frequency = frequencyAt(position.x, size.width.toFloat()).coerceIn(EqMath.FREQUENCY_RANGE)
                                    if (band.type.usesGain) band.copy(enabled = true, frequency = frequency,
                                        gain = (gainAt(position.y, size.height.toFloat())).coerceIn(EqMath.GAIN_RANGE).roundTo(0.5))
                                    else band.copy(enabled = true, frequency = frequency)
                                }
                            }
                        }
                        event.changes.forEach { it.consume() }
                    }
                }
            }) {
            for (db in listOf(-12.0, 0.0, 12.0)) {
                drawLine(grid, Offset(0f, y(db, size.height)), Offset(size.width, y(db, size.height)), strokeWidth = if (db == 0.0) 2f else 1f,
                    pathEffect = if (db == 0.0) null else PathEffect.dashPathEffect(floatArrayOf(8f, 8f)))
            }
            for (f in listOf(100.0, 1_000.0, 10_000.0)) drawLine(grid, Offset(x(f, size.width), 0f), Offset(x(f, size.width), size.height), strokeWidth = 1f)
            // The bands' curve without the preamp, as on the Mac, so it passes through their points.
            val path = Path()
            val bandsOnly = curve.copy(preamp = 0.0)
            EqMath.logSpaced(160).forEachIndexed { index, f ->
                val point = Offset(x(f, size.width), y(EqMath.response(bandsOnly, f).coerceIn(-24.0, 24.0), size.height))
                if (index == 0) path.moveTo(point.x, point.y) else path.lineTo(point.x, point.y)
            }
            drawPath(path, line, style = Stroke(width = 3.dp.toPx(), cap = StrokeCap.Round))
            curve.bands.forEachIndexed { index, band ->
                val center = Offset(x(band.frequency, size.width), y(nodeGain(band), size.height))
                val color = if (!band.enabled) grid else if (index == selected) line else node
                drawCircle(color, radius = if (index == selected) 9.dp.toPx() else 5.dp.toPx(), center = center)
                if (index == selected) drawCircle(Color.White, radius = 4.dp.toPx(), center = center)
            }
        }
    }
}

/** Where a band's point sits: its gain (peak and shelves), or the 0 dB line (filters without gain). */
private fun nodeGain(band: EqBand): Double = if (band.type.usesGain) band.gain else 0.0

private val LOG_LOW = log10(EqMath.FREQUENCY_RANGE.start)
private val LOG_HIGH = log10(EqMath.FREQUENCY_RANGE.endInclusive)

private fun x(frequency: Double, width: Float): Float = ((log10(frequency) - LOG_LOW) / (LOG_HIGH - LOG_LOW) * width).toFloat()
private fun y(db: Double, height: Float): Float = ((24 - db) / 48 * height).toFloat()
private fun frequencyAt(x: Float, width: Float): Double = 10.0.pow(LOG_LOW + (x / width).coerceIn(0f, 1f) * (LOG_HIGH - LOG_LOW))
private fun gainAt(y: Float, height: Float): Double = 24 - (y / height).coerceIn(0f, 1f) * 48.0
private fun Double.roundTo(step: Double) = Math.round(this / step) * step

private fun frequencyLabel(frequency: Double): String =
    if (frequency >= 1_000) "%s kHz".format(if (frequency % 1_000 == 0.0) "%.0f".format(frequency / 1_000) else "%.1f".format(frequency / 1_000))
    else "%.0f Hz".format(frequency)

/** The selected band exactly: on or off, its filter, frequency, gain and Q. */
@Composable
private fun BandEditor(index: Int, band: EqBand) {
    var types by remember { mutableStateOf(false) }
    Card(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Band ${index + 1}", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f).semantics { heading() })
                Box {
                    TextButton(onClick = { types = true }) { Text(band.type.label) }
                    DropdownMenu(expanded = types, onDismissRequest = { types = false }) {
                        EqFilter.entries.forEach { type ->
                            DropdownMenuItem(text = { Text(type.label) }, onClick = {
                                types = false
                                PlaybackSettings.updateBand(index) { it.copy(type = type) }
                            })
                        }
                    }
                }
                Switch(checked = band.enabled, onCheckedChange = { on -> PlaybackSettings.updateBand(index) { it.copy(enabled = on) } },
                    modifier = Modifier.semantics { contentDescription = "Band ${index + 1}" })
            }
            LabeledSlider("Frequency", frequencyLabel(band.frequency),
                current = ((log10(band.frequency) - LOG_LOW) / (LOG_HIGH - LOG_LOW)).toFloat(), range = 0f..1f) { fraction ->
                PlaybackSettings.updateBand(index) { it.copy(frequency = 10.0.pow(LOG_LOW + fraction * (LOG_HIGH - LOG_LOW)).roundToSignificant()) }
            }
            if (band.type.usesGain) {
                LabeledSlider("Gain", "%+.1f dB".format(band.gain), band.gain.toFloat(), -24f..24f) { gain ->
                    PlaybackSettings.updateBand(index) { it.copy(gain = gain.toDouble().roundTo(0.5)) }
                }
            }
            // Q on a log scale: 0.1 to 18.
            LabeledSlider("Q", "%.2f".format(band.q), log10(band.q).toFloat(), log10(0.1f)..log10(18f)) { value ->
                PlaybackSettings.updateBand(index) { it.copy(q = 10.0.pow(value.toDouble()).roundTo(0.01).coerceIn(EqMath.Q_RANGE)) }
            }
        }
    }
}

private fun Double.roundToSignificant(): Double = when {
    this < 100 -> Math.round(this).toDouble()
    this < 1_000 -> Math.round(this / 5) * 5.0
    else -> Math.round(this / 50) * 50.0
}

@Composable
private fun LabeledSlider(label: String, value: String, current: Float, range: ClosedFloatingPointRange<Float>, onChange: (Float) -> Unit) {
    Row(Modifier.padding(top = 8.dp)) {
        Text(label, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
        Text(value, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    Slider(value = current.coerceIn(range), onValueChange = onChange, valueRange = range,
        modifier = Modifier.semantics { contentDescription = label; stateDescription = value })
}

/** Presets to pick: the Mac's, the ones saved here, the built-in ones; and saving, importing and deleting. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PresetSheet(curve: EqPreset, onDismiss: () -> Unit) {
    val actions = LocalActions.current
    val context = LocalContext.current
    val saved by PlaybackSettings.userPresets.collectAsStateWithLifecycle()
    val mac by actions.library.macPresets.collectAsStateWithLifecycle()
    var naming by remember { mutableStateOf(false) }
    val import = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        uri ?: return@rememberLauncherForActivityResult
        val name = uri.lastPathSegment?.substringAfterLast('/')?.substringBeforeLast('.')?.removeSuffix(" ParametricEQ")?.ifBlank { null } ?: "Imported"
        val text = runCatching { context.contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() } }.getOrNull()
        val preset = text?.let { ParametricEqFile.parse(it, name) }
        if (preset == null) actions.notify("That file has no equalizer filters") else {
            PlaybackSettings.importPreset(preset)
            actions.notify("Imported \"${preset.name}\"")
            onDismiss()
        }
    }
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false)) {
        LazyColumn(contentPadding = PaddingValues(bottom = 24.dp)) {
            item {
                Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = { naming = true }) {
                        Icon(painterResource(R.drawable.ic_save), null)
                        Spacer(Modifier.width(8.dp))
                        Text("Save Curve")
                    }
                    OutlinedButton(onClick = { import.launch(arrayOf("text/*", "application/octet-stream")) }) {
                        Icon(painterResource(R.drawable.ic_file), null)
                        Spacer(Modifier.width(8.dp))
                        Text("Import AutoEq")
                    }
                }
            }
            if (mac.isNotEmpty()) {
                item { SectionTitle("From the Mac") }
                items(mac, key = { "mac:${it.isCurrent}:${it.preset.name}" }) { preset ->
                    PresetRow(preset.preset, curve, if (preset.isCurrent) "In use on the Mac" + if (preset.enabled) "" else " (off there)" else null, onDismiss)
                }
            }
            if (saved.isNotEmpty()) {
                item { SectionTitle("On This Device") }
                items(saved, key = { "saved:${it.name}" }) { preset ->
                    PresetRow(preset, curve, null, onDismiss) {
                        IconButton(onClick = { PlaybackSettings.deletePreset(preset.name) }) {
                            Icon(painterResource(R.drawable.ic_delete), contentDescription = "Delete ${preset.name}")
                        }
                    }
                }
            }
            item { SectionTitle("Built In") }
            items(EqPreset.BUILT_INS, key = { "builtin:${it.name}" }) { preset -> PresetRow(preset, curve, null, onDismiss) }
        }
    }
    if (naming) {
        var name by remember { mutableStateOf(curve.name.takeUnless { EqPreset.isBuiltInName(it) || it == "Custom" } ?: "") }
        AlertDialog(
            onDismissRequest = { naming = false },
            title = { Text("Save Curve") },
            text = { OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("Name") }, singleLine = true) },
            confirmButton = {
                TextButton(enabled = name.isNotBlank() && !EqPreset.isBuiltInName(name.trim()), onClick = {
                    PlaybackSettings.saveCurve(name.trim())
                    naming = false
                }) { Text("Save") }
            },
            dismissButton = { TextButton(onClick = { naming = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun PresetRow(preset: EqPreset, curve: EqPreset, detail: String?, onDone: () -> Unit, trailing: (@Composable () -> Unit)? = null) {
    val current = preset.name == curve.name && preset.bands == curve.bands
    ListItem(
        headlineContent = { Text(preset.name, fontWeight = if (current) FontWeight.SemiBold else null) },
        supportingContent = detail?.let { { Text(it) } },
        leadingContent = { MiniCurve(preset) },
        trailingContent = trailing,
        colors = ListItemDefaults.colors(containerColor = Color.Transparent,
            headlineColor = if (current) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface),
        modifier = Modifier.clickable {
            PlaybackSettings.setCurve(preset)
            PlaybackSettings.setEqEnabled(true)
            onDone()
        },
    )
}

/** A preset's curve, small, beside its name. */
@Composable
private fun MiniCurve(preset: EqPreset) {
    val color = MaterialTheme.colorScheme.primary
    val base = MaterialTheme.colorScheme.outlineVariant
    Canvas(Modifier.width(48.dp).height(28.dp)) {
        drawLine(base, Offset(0f, size.height / 2), Offset(size.width, size.height / 2))
        val path = Path()
        val flat = preset.copy(preamp = 0.0)
        EqMath.logSpaced(32).forEachIndexed { index, f ->
            val point = Offset(x(f, size.width), ((12 - EqMath.response(flat, f).coerceIn(-12.0, 12.0)) / 24 * size.height).toFloat())
            if (index == 0) path.moveTo(point.x, point.y) else path.lineTo(point.x, point.y)
        }
        drawPath(path, color, style = Stroke(width = 2.dp.toPx()))
    }
}

/** A short explanation at the top of a settings page. */
@Composable
fun Notice(text: String) {
    Card(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), shape = RoundedCornerShape(12.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer)) {
        Text(text, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(16.dp))
    }
}
