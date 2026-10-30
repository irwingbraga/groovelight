package dev.irwingbraga.groovelight.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.irwingbraga.groovelight.R

/** A sample song on the cassettes in the lists and the editor, its reels turning (or still). */
private val SAMPLE = SkinPlayback("Side A", "Groovelight", isPlaying = false, time = 20.0, duration = 60.0)

/**
 * The look of Now Playing (Cover, Vinyl, Cassette, CD) and the cassettes: the built-in ones and the user's, which can be
 * made from a copy, edited, imported from a shared `.cassette` (zip) or `cassette.json`, shared and deleted.
 */
@Composable
fun CassettesScreen() {
    val actions = LocalActions.current
    val context = LocalContext.current
    val skin by Cassettes.skin.collectAsStateWithLifecycle()
    val chosen by Cassettes.cassetteId.collectAsStateWithLifecycle()
    val custom by Cassettes.custom.collectAsStateWithLifecycle()
    var problem by remember { mutableStateOf<String?>(null) }
    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) runCatching { Cassettes.import(context, uri) }
            .onSuccess { Cassettes.choose(it); Cassettes.setSkin(NowPlayingSkin.CASSETTE) }
            .onFailure { problem = it.message ?: "This file could not be opened" }
    }
    fun make(from: CassetteDesign) {
        val copy = Cassettes.duplicate(from, if (from.isBuiltIn) "My ${from.name}" else null)
        Cassettes.choose(copy)
        actions.open(Route.CassetteEditor(copy.id))
    }
    GlassTop(bar = { SettingsBar("Now Playing Look") }) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())
            .padding(top = LocalTopInset.current, bottom = 24.dp + LocalBottomInset.current)) {
            ChoiceRow("Look", skin.label, NowPlayingSkin.entries.map { it.label to { Cassettes.setSkin(it) } })
            val pcTheme by Cassettes.pcTheme.collectAsStateWithLifecycle()
            ChoiceRow("PC Player theme", pcTheme.label, PcTheme.entries.map { theme ->
                theme.label to { Cassettes.setPcTheme(theme); Cassettes.setSkin(NowPlayingSkin.PC_PLAYER) }
            })
            val tapeCue by Cassettes.tapeCue.collectAsStateWithLifecycle()
            SwitchRow("Tape sound when cueing", tapeCue, Cassettes::setTapeCue)
            Text("In the cassette deck, holding Rewind or Fast Forward plays the tape racing past the heads, as a real deck does.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp))
            SectionTitle("Built In")
            CassetteDesign.BUILT_IN.forEach { design ->
                CassetteRow(design, design.id == chosen, onChoose = { Cassettes.choose(design); Cassettes.setSkin(NowPlayingSkin.CASSETTE) },
                    onDuplicate = { make(design) })
            }
            SectionTitle("Yours")
            custom.forEach { design ->
                CassetteRow(design, design.id == chosen, onChoose = { Cassettes.choose(design); Cassettes.setSkin(NowPlayingSkin.CASSETTE) },
                    onDuplicate = { make(design) }, onEdit = { actions.open(Route.CassetteEditor(design.id)) },
                    onShare = { Cassettes.share(context, design) }, onDelete = { Cassettes.delete(design) })
            }
            Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { make(Cassettes.design(chosen)) }) { Text("New Cassette") }
                OutlinedButton(onClick = { importer.launch(arrayOf("application/zip", "application/json", "application/octet-stream")) }) { Text("Import") }
            }
            Text("Make your own from a copy of any cassette: its colors, its label and its text, or your own pictures of the shell and the label. " +
                "Share one as a .cassette: it opens on the Mac, iPhone and iPad as well. Draw a shell on the template saved from the Mac's or the iPhone's cassettes.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
        }
    }
    problem?.let { message ->
        AlertDialog(onDismissRequest = { problem = null }, confirmButton = { TextButton({ problem = null }) { Text("OK") } },
            title = { Text("Cassette") }, text = { Text(message) })
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(text, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 4.dp))
}

@Composable
private fun CassetteRow(
    design: CassetteDesign,
    chosen: Boolean,
    onChoose: () -> Unit,
    onDuplicate: () -> Unit,
    onEdit: (() -> Unit)? = null,
    onShare: (() -> Unit)? = null,
    onDelete: (() -> Unit)? = null,
) {
    var menu by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().clickable(onClickLabel = "Choose", onClick = onChoose).semantics { selected = chosen }
        .padding(horizontal = 16.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        CassetteFace(design, SAMPLE, null, Modifier.width(88.dp).aspectRatio(design.resolvedGeometry.aspectRatio))
        Column(Modifier.weight(1f).padding(start = 12.dp)) {
            Text(design.name, style = MaterialTheme.typography.bodyLarge)
            design.author?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        if (chosen) Icon(painterResource(R.drawable.ic_check_circle), contentDescription = "Chosen", tint = MaterialTheme.colorScheme.primary)
        Box {
            IconButton(onClick = { menu = true }) { Icon(painterResource(R.drawable.ic_more), contentDescription = "More for ${design.name}") }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                onEdit?.let { DropdownMenuItem(text = { Text("Edit") }, leadingIcon = { Icon(painterResource(R.drawable.ic_edit), null) }, onClick = { menu = false; it() }) }
                DropdownMenuItem(text = { Text("Duplicate") }, leadingIcon = { Icon(painterResource(R.drawable.ic_add_circle), null) },
                    onClick = { menu = false; onDuplicate() })
                onShare?.let { DropdownMenuItem(text = { Text("Share") }, leadingIcon = { Icon(painterResource(R.drawable.ic_share), null) }, onClick = { menu = false; it() }) }
                onDelete?.let { DropdownMenuItem(text = { Text("Delete") }, leadingIcon = { Icon(painterResource(R.drawable.ic_delete), null) }, onClick = { menu = false; it() }) }
            }
        }
    }
}

/** Colors to pick from (Android has no system color picker), and a hex field for any other. */
private val SWATCHES = listOf(
    "#1E1E21", "#4A4A50", "#8D8F94", "#ECECEA", "#FFFFFF", "#F2EBDD", "#FFF6D8", "#C9A750",
    "#D8432E", "#EE8A2C", "#F3C340", "#47B5C9", "#1F4E9C", "#1C2A6B", "#E4497A", "#7A4FBF",
    "#3A2618", "#2B6E3F", "#9FB4C2", "#000000",
).map { CassetteDesign.parseHex(it)!! }

/** Edits a design of the user's: the preview at the top, then the shell, the label, the text, the reels and the pictures. */
@Composable
fun CassetteEditor(id: String) {
    val context = LocalContext.current
    val goBack = LocalBack.current
    val custom by Cassettes.custom.collectAsStateWithLifecycle()
    val stored = custom.firstOrNull { it.id == id } ?: return
    var design by remember(id) { mutableStateOf(stored) }
    var choosing by remember { mutableStateOf<Cassettes.Picture?>(null) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        val picture = choosing ?: return@rememberLauncherForActivityResult
        if (uri != null) {
            val ext = if (context.contentResolver.getType(uri) == "image/jpeg") "jpg" else "png"
            design = Cassettes.setPicture(design, picture, context.contentResolver.openInputStream(uri), ext)
        }
        choosing = null
    }
    GlassTop(bar = {
        SettingsBar(design.name.ifBlank { "Cassette" }) {
            TextButton(onClick = { Cassettes.save(design); goBack() }) { Text("Save") }
        }
    }) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState())
            .padding(top = LocalTopInset.current, bottom = 24.dp + LocalBottomInset.current)) {
            CassetteFace(design, SAMPLE, null, Modifier.padding(16.dp).widthIn(max = 420.dp).fillMaxWidth()
                .aspectRatio(design.resolvedGeometry.aspectRatio).align(Alignment.CenterHorizontally))
            Field("Name", design.name) { design = design.copy(name = it) }
            Field("Made By", design.author.orEmpty()) { design = design.copy(author = it.ifBlank { null }) }
            SectionTitle("Shell")
            ColorRow("Plastic", design.shellColor) { design = design.copy(shellColor = it) }
            Column(Modifier.padding(horizontal = 16.dp)) {
                Text("Clear", style = MaterialTheme.typography.bodyLarge)
                Slider(design.shellClarity, { design = design.copy(shellClarity = it) }, valueRange = 0f..0.8f,
                    modifier = Modifier.semantics { contentDescription = "Clear" })
            }
            ColorRow("Screws and Edges", design.detailColor) { design = design.copy(detailColor = it) }
            SectionTitle("Label")
            FinishRow("Paper", design.label.backgroundFinish, plain = "Color") { design = design.copy(label = design.label.copy(backgroundFinish = it)) }
            if (design.label.backgroundFinish == null) {
                ColorRow("Paper Color", design.label.background) { design = design.copy(label = design.label.copy(background = it)) }
            }
            ColorRow("Writing", design.label.textColor) { design = design.copy(label = design.label.copy(textColor = it)) }
            design.label.stripes.forEachIndexed { index, stripe ->
                ColorRow("Band ${index + 1}", stripe, onRemove = {
                    design = design.copy(label = design.label.copy(stripes = design.label.stripes.filterIndexed { i, _ -> i != index }))
                }) { color -> design = design.copy(label = design.label.copy(stripes = design.label.stripes.mapIndexed { i, s -> if (i == index) color else s })) }
            }
            if (design.label.stripes.size < 5) {
                TextButton(onClick = {
                    design = design.copy(label = design.label.copy(stripes = design.label.stripes + (design.label.stripes.lastOrNull() ?: design.label.textColor)))
                }, modifier = Modifier.padding(horizontal = 8.dp)) { Text("Add Band") }
            }
            SwitchRow("Song Written on It", design.label.showsText) { design = design.copy(label = design.label.copy(showsText = it)) }
            SwitchRow("Handwriting", design.label.handwritten) { design = design.copy(label = design.label.copy(handwritten = it)) }
            SwitchRow("Cover on It", design.label.showsArtwork) { design = design.copy(label = design.label.copy(showsArtwork = it)) }
            SectionTitle("Printed")
            Field("Brand", design.brand) { design = design.copy(brand = it) }
            Field("Tape Type", design.tapeType) { design = design.copy(tapeType = it) }
            Field("Side", design.side) { design = design.copy(side = it) }
            FinishRow("Print", design.label.textFinish, plain = "Writing's Color") { design = design.copy(label = design.label.copy(textFinish = it)) }
            SectionTitle("Reels")
            ColorRow("Hubs", design.reels.hubColor) { design = design.copy(reels = design.reels.copy(hubColor = it)) }
            ColorRow("Tape", design.reels.tapeColor) { design = design.copy(reels = design.reels.copy(tapeColor = it)) }
            // Rings around the hubs: none, a color, or foil (with its color, for apps that draw no foil).
            val rings = listOf("None", "Color", "Gold Foil", "Silver Foil")
            val ring = when {
                design.reels.ringColor == null -> 0
                design.reels.ringFinish == Finish.GOLD -> 2
                design.reels.ringFinish == Finish.SILVER -> 3
                else -> 1
            }
            Text("Rings Around the Hubs", style = MaterialTheme.typography.bodyLarge, modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp))
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
                rings.forEachIndexed { index, title ->
                    SegmentedButton(selected = ring == index, shape = SegmentedButtonDefaults.itemShape(index, rings.size), onClick = {
                        design = design.copy(reels = when (index) {
                            0 -> design.reels.copy(ringColor = null, ringFinish = null)
                            1 -> design.reels.copy(ringColor = design.reels.ringColor ?: design.label.textColor, ringFinish = null)
                            2 -> design.reels.copy(ringColor = Color(0xFFC9A04A), ringFinish = Finish.GOLD)
                            else -> design.reels.copy(ringColor = Color(0xFFBFC4CE), ringFinish = Finish.SILVER)
                        })
                    }) { Text(title, maxLines = 1) }
                }
            }
            if (ring == 1) design.reels.ringColor?.let { color ->
                ColorRow("Rings' Color", color) { design = design.copy(reels = design.reels.copy(ringColor = it)) }
            }
            SectionTitle("Your Pictures")
            Cassettes.Picture.entries.forEach { picture ->
                val has = Cassettes.pictureFile(design, picture) != null
                Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(if (picture == Cassettes.Picture.SHELL) "Shell Picture" else "Label Picture", Modifier.weight(1f))
                    if (has) TextButton(onClick = { design = Cassettes.setPicture(design, picture, null) }) { Text("Remove") }
                    TextButton(onClick = { choosing = picture; picker.launch(arrayOf("image/png", "image/jpeg")) }) {
                        Text(if (has) "Change" else "Choose")
                    }
                }
            }
            Text("A shell picture is drawn over the reels: make the window and the hubs' holes transparent (a PNG), drawn on the template the Mac's " +
                "or the iPhone's cassettes save. The song is still written on the label. Pictures are kept at once; the rest when saved.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
        }
    }
}

@Composable
private fun Field(label: String, value: String, onChange: (String) -> Unit) {
    OutlinedTextField(value, onChange, label = { Text(label) }, singleLine = true,
        keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp))
}

/** Plain ([plain]) or in gold or silver foil. */
@Composable
private fun FinishRow(label: String, finish: Finish?, plain: String, onChange: (Finish?) -> Unit) {
    val choices = listOf<Finish?>(null, Finish.GOLD, Finish.SILVER)
    Text(label, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp))
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
        choices.forEachIndexed { index, choice ->
            SegmentedButton(selected = finish == choice, onClick = { onChange(choice) }, shape = SegmentedButtonDefaults.itemShape(index, choices.size)) {
                Text(when (choice) { null -> plain; Finish.GOLD -> "Gold Foil"; Finish.SILVER -> "Silver Foil" }, maxLines = 1)
            }
        }
    }
}

/** A setting with a few choices: its name and the one chosen; tapped, the choices in a menu under it. */
@Composable
private fun ChoiceRow(label: String, value: String, choices: List<Pair<String, () -> Unit>>) {
    var open by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().clickable { open = true }.padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
        // The menu opens under the value it changes.
        Box {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(value, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.primary)
                Icon(painterResource(R.drawable.ic_expand_more), contentDescription = null, tint = MaterialTheme.colorScheme.primary)
            }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                choices.forEach { (title, choose) ->
                    DropdownMenuItem(text = { Text(title) }, onClick = { open = false; choose() },
                        trailingIcon = if (title == value) ({ Icon(painterResource(R.drawable.ic_check_circle), contentDescription = "Chosen") }) else null)
                }
            }
        }
    }
}

@Composable
private fun SwitchRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().clickable { onChange(!checked) }.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
        Switch(checked, onChange)
    }
}

/** A color: its swatch and hex, the swatches to pick from shown under it when tapped. */
@Composable
private fun ColorRow(label: String, color: Color, onRemove: (() -> Unit)? = null, onChange: (Color) -> Unit) {
    var open by remember { mutableStateOf(false) }
    var text by remember(color) { mutableStateOf(color.hex()) }
    Column {
        Row(Modifier.fillMaxWidth().clickable(onClickLabel = "Change color") { open = !open }.padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
            Text(color.hex(), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.width(8.dp))
            Box(Modifier.size(28.dp).clip(CircleShape).background(color).border(1.dp, MaterialTheme.colorScheme.outline, CircleShape))
            onRemove?.let { IconButton(onClick = it) { Icon(painterResource(R.drawable.ic_remove_circle), contentDescription = "Remove $label") } }
        }
        if (open) {
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                SWATCHES.forEach { swatch ->
                    Box(Modifier.size(32.dp).clip(CircleShape).background(swatch)
                        .border(if (swatch == color) 3.dp else 1.dp, if (swatch == color) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline, CircleShape)
                        .clickable(onClickLabel = swatch.hex()) { onChange(swatch) })
                }
            }
            OutlinedTextField(text, { value ->
                text = value
                CassetteDesign.parseHex(value)?.let(onChange)
            }, label = { Text("Hex") }, singleLine = true, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp))
            HorizontalDivider(Modifier.padding(top = 8.dp))
        }
    }
}
