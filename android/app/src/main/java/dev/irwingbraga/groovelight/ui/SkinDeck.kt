package dev.irwingbraga.groovelight.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfo
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.irwingbraga.groovelight.R
import java.io.File
import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * The song as a player shows it; its time ([clock], seconds) read where it is drawn, so only what moves redraws.
 * [heardHere]: it plays on this phone, so the VU meters follow its sound.
 */
class DeckSong(val title: String, val artist: String, val album: String, val playing: Boolean, val duration: Double, val clock: State<Double>,
               val heardHere: Boolean = false) {
    val progress: Float get() = if (duration > 0) (clock.value / duration).toFloat().coerceIn(0f, 1f) else 0f
    fun playback() = SkinPlayback(title, artist, playing, clock.value, duration)
}

enum class DeckRepeat { OFF, ALL, ONE }

/** What the player's keys, knobs and switches do. [volume] null hides the volume knob. */
class DeckActions(
    val playPause: () -> Unit, val previous: () -> Unit, val next: () -> Unit, val seek: (Double) -> Unit,
    val volume: Float?, val onVolume: (Float) -> Unit,
    val shuffled: Boolean, val toggleShuffle: () -> Unit, val repeat: DeckRepeat, val cycleRepeat: () -> Unit,
)

/** Held, rewind and fast forward move this far through the song at each step (of 0.15 s). */
private const val SCAN_STEP = 5.0

/**
 * Where the stage (the player itself) and the panel (its controls) go: one above the other on a tall screen, side by
 * side on a wide one, and on either side of a fold dividing it (a Galaxy Z Fold half open), as on the iPhone Duo.
 */
internal class DeckRegions(val stage: Rect, val panel: Rect) {
    companion object {
        fun of(size: Size, margin: Float, fold: Rect?, stageAspect: Float): DeckRegions {
            val area = Rect(margin, 0f, size.width - margin, size.height - margin)
            if (fold != null && fold.height >= size.height * 0.5f && fold.left > area.left + margin * 8 && fold.right < area.right - margin * 8) {
                return DeckRegions(Rect(area.left, area.top, fold.left - margin, area.bottom), Rect(fold.right + margin, area.top, area.right, area.bottom))
            }
            if (fold != null && fold.width >= size.width * 0.5f && fold.top > area.top + margin * 8 && fold.bottom < area.bottom - margin * 8) {
                return DeckRegions(Rect(area.left, area.top, area.right, fold.top - margin), Rect(area.left, fold.bottom + margin, area.right, area.bottom))
            }
            // Side by side only where clearly wide: a near square screen (a foldable open) keeps the panel under the
            // player, where it has the width to be large.
            return if (area.width >= area.height * 1.25f) {
                val width = min(area.height * stageAspect, area.width * 0.58f)
                DeckRegions(Rect(area.left, area.top, area.left + width, area.bottom), Rect(area.left + width + margin, area.top, area.right, area.bottom))
            } else {
                val height = min(area.width / stageAspect, area.height * 0.56f)
                DeckRegions(Rect(area.left, area.top, area.right, area.top + height), Rect(area.left, area.top + height + margin, area.right, area.bottom))
            }
        }

        /** How much a panel drawn for [reference] grows (or shrinks) to fill [size]. */
        fun scale(size: Size, reference: Size) = min(size.width / reference.width, size.height / reference.height).coerceIn(0.62f, 1.9f)
    }
}

/** What the player is made of, to the screen's edges: walnut, brushed aluminum with walnut ends, or black. */
@Composable
fun DeckSurface(skin: NowPlayingSkin, modifier: Modifier = Modifier) {
    when (skin) {
        NowPlayingSkin.CASSETTE -> Box(modifier.textured(SkinTexture.ALUMINUM, 0.14f)
            .background(Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.18f), Color.Transparent, Color.Black.copy(alpha = 0.15f))))) {
            listOf(Alignment.CenterStart, Alignment.CenterEnd).forEach { side ->
                Box(Modifier.align(side).width(10.dp).fillMaxHeight().textured(SkinTexture.WALNUT)
                    .background(Brush.horizontalGradient(listOf(Color.Black.copy(alpha = 0.4f), Color.White.copy(alpha = 0.1f), Color.Black.copy(alpha = 0.4f)))))
            }
        }
        NowPlayingSkin.CD -> Box(modifier.textured(SkinTexture.ALUMINUM, -0.12f, Color(0xFF525252))
            .background(Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.08f), Color.Transparent, Color.Black.copy(alpha = 0.3f)))))
        else -> Box(modifier.textured(SkinTexture.WALNUT, -0.04f)
            .background(Brush.radialGradient(listOf(Color.White.copy(alpha = 0.08f), Color.Black.copy(alpha = 0.45f)), radius = 2400f)))
    }
}

/** The color the app's own text and icons take over a player's surface. */
fun deckInk(skin: NowPlayingSkin): Color = if (skin == NowPlayingSkin.CASSETTE) Color.Black.copy(alpha = 0.72f) else Color.White.copy(alpha = 0.9f)

/**
 * Now Playing as the vintage player chosen (as GroovelightKit's `SkinDeck` on the Mac and the iPhone): the turntable,
 * the cassette deck or the CD player and their controls, laid out for the screen's shape and around a fold. Its
 * surface ([DeckSurface]) is drawn behind it by the caller, to the screen's edges. [stageOverlay] (the lyrics, Up Next)
 * takes the player's place behind smoked glass; [accessory] goes at the foot of the panel.
 */
@Composable
fun SkinDeck(skin: NowPlayingSkin, song: DeckSong, actions: DeckActions, cover: File?, cassette: CassetteDesign, modifier: Modifier = Modifier,
             stageOverlay: (@Composable () -> Unit)? = null, accessory: @Composable () -> Unit = {}) {
    val hinge = currentWindowAdaptiveInfo().windowPosture.hingeList.firstOrNull { it.isSeparating || !it.isFlat }?.bounds
    var origin by remember { mutableStateOf(Offset.Zero) }
    BoxWithConstraints(modifier.onGloballyPositioned { origin = it.positionInWindow() }) {
        val density = LocalDensity.current
        val size = Size(constraints.maxWidth.toFloat(), constraints.maxHeight.toFloat())
        val margin = with(density) { 14.dp.toPx() }
        val fold = hinge?.let { Rect(it.left - origin.x, it.top - origin.y, it.right - origin.x, it.bottom - origin.y) }
        val aspect = if (skin == NowPlayingSkin.CASSETTE && stageOverlay == null) cassette.resolvedGeometry.aspectRatio * 0.92f else 1f
        val regions = DeckRegions.of(size, margin, fold, aspect)
        with(density) {
            Box(Modifier.offset { IntOffset(regions.stage.left.roundToInt(), regions.stage.top.roundToInt()) }
                .size(regions.stage.width.toDp(), regions.stage.height.toDp())) {
                if (stageOverlay != null) {
                    Box(Modifier.fillMaxSize().recess(18.dp, Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.85f), Color.Black.copy(alpha = 0.75f))))
                        .padding(12.dp)) { stageOverlay() }
                } else when (skin) {
                    NowPlayingSkin.CASSETTE -> CassetteStage(cassette, song, cover)
                    NowPlayingSkin.CD -> DiscStage(song, cover)
                    else -> TurntableStage(song, cover, actions.seek)
                }
            }
            // Under the player, the panel follows it; beside it, it sits in the middle.
            val under = regions.panel.top > regions.stage.bottom
            Box(Modifier.offset { IntOffset(regions.panel.left.roundToInt(), regions.panel.top.roundToInt()) }
                .size(regions.panel.width.toDp(), regions.panel.height.toDp()), contentAlignment = if (under) Alignment.TopCenter else Alignment.Center) {
                val scale = DeckRegions.scale(Size(regions.panel.width.toDp().value, regions.panel.height.toDp().value), Size(376f, 300f))
                when (skin) {
                    NowPlayingSkin.CASSETTE -> CassettePanel(song, actions, scale, accessory)
                    NowPlayingSkin.CD -> DiscPanel(song, actions, scale, accessory)
                    else -> TurntablePanel(song, actions, scale, accessory)
                }
            }
        }
    }
}

private fun scan(song: DeckSong, actions: DeckActions, direction: Int): () -> Unit = {
    actions.seek((song.clock.value + direction * SCAN_STEP).coerceIn(0.0, max(song.duration - 1, 0.0)))
}

private fun repeatCaption(repeat: DeckRepeat) = when (repeat) {
    DeckRepeat.OFF -> "REPEAT OFF"
    DeckRepeat.ALL -> "REPEAT ALL"
    DeckRepeat.ONE -> "REPEAT ONE"
}

/** Repeat's toggle: down for off, the middle for all, up for one. */
private fun repeatPosition(repeat: DeckRepeat) = when (repeat) {
    DeckRepeat.OFF -> 2
    DeckRepeat.ALL -> 1
    DeckRepeat.ONE -> 0
}

@Composable
private fun Switches(actions: DeckActions, scale: Float, volumeCaption: String, onDark: Boolean = false) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
        Captioned("SHUFFLE", scale, onDark) {
            ToggleSwitch("Shuffle", if (actions.shuffled) 0 else 1, if (actions.shuffled) "On" else "Off", (44 * scale).dp, actions.toggleShuffle)
        }
        Gap((18 * scale).dp)
        Captioned(repeatCaption(actions.repeat), scale, onDark) {
            ToggleSwitch("Repeat", repeatPosition(actions.repeat), repeatCaption(actions.repeat), (44 * scale).dp, actions.cycleRepeat, positions = 3)
        }
        Spacer(Modifier.weight(1f))
        actions.volume?.let { volume ->
            Captioned(volumeCaption, scale, onDark) { Knob("Volume", volume, actions.onVolume, (66 * scale).dp, onDark) }
        }
    }
}

// MARK: Turntable

@Composable
private fun TurntablePanel(song: DeckSong, actions: DeckActions, scale: Float, accessory: @Composable () -> Unit) {
    Column(Modifier.widthIn(max = (360 * scale).dp).fillMaxWidth().heightIn(max = (300 * scale * 1.5f).dp)
        .plate(SkinTexture.ALUMINUM, (10 * scale).dp, 0.12f, (9 * scale).dp)
        .padding(horizontal = (20 * scale).dp, vertical = (16 * scale).dp), verticalArrangement = Arrangement.SpaceBetween) {
        Column(verticalArrangement = Arrangement.spacedBy((6 * scale).dp)) {
            DymoLabel(song.title, Color(0xFF1A1A1A), (15 * scale).sp)
            DymoLabel(listOf(song.artist, song.album).filter { it.isNotBlank() }.joinToString(" · "), Color(0xFFB81A1A), (11 * scale).sp,
                Modifier.graphicsLayer { rotationZ = 0.8f })
        }
        Spacer(Modifier.height((12 * scale).dp))
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
            Captioned("PREV", scale) { MetalKey("Previous", R.drawable.ic_skip_previous, (54 * scale).dp, (44 * scale).dp, actions.previous, scan(song, actions, -1)) }
            Gap((12 * scale).dp)
            Captioned("START · STOP", scale) {
                MetalKey(if (song.playing) "Stop" else "Start", if (song.playing) R.drawable.ic_stop else R.drawable.ic_play, (92 * scale).dp, (52 * scale).dp,
                    actions.playPause, lamp = song.playing)
            }
            Gap((12 * scale).dp)
            Captioned("NEXT", scale) { MetalKey("Next", R.drawable.ic_skip_next, (54 * scale).dp, (44 * scale).dp, actions.next, scan(song, actions, 1)) }
            Spacer(Modifier.weight(1f))
            Captioned("TIME", scale) { LedClock(song, scale) }
        }
        Spacer(Modifier.height((12 * scale).dp))
        Switches(actions, scale, "VOLUME")
        accessory()
    }
}

/** Elapsed time in red LED digits behind a dark window. */
@Composable
private fun LedClock(song: DeckSong, scale: Float) {
    Box(Modifier.recess((4 * scale).dp, Brush.verticalGradient(listOf(Color(0xFF140505), Color(0xFF140505)))).padding(horizontal = (7 * scale).dp, vertical = (6 * scale).dp)) {
        VFDText(clockText(song.clock.value), "88:88", dsegDigits, (15 * scale).sp, Color(0xFFFF4026))
    }
}

/**
 * The turntable from above: the platter in its felt mat, the record turning at 33⅓ with the cover as its label, and the
 * tonearm going in over the song (on its rest until it starts). The headshell dragged across the record seeks.
 */
@Composable
private fun TurntableStage(song: DeckSong, cover: File?, seek: (Double) -> Unit) {
    val clock = song.clock
    val started by remember(song.playing) { derivedStateOf { song.playing || clock.value > 0.5 } }
    val onRecord by animateFloatAsState(if (started) 1f else 0f, tween(900), label = "tonearm")
    var dragAngle by remember { mutableStateOf<Float?>(null) }
    val currentSeek by rememberUpdatedState(seek)
    BoxWithConstraints(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        val side = min(constraints.maxWidth, constraints.maxHeight).toFloat()
        val center = Offset(side * 0.43f, side * 0.5f)
        val record = side * 0.38f
        val outer = tonearmAngle(side, center, record * 0.95f)
        val inner = tonearmAngle(side, center, record * 0.4f)
        fun angle() = dragAngle ?: (-3f + (outer + (inner - outer) * song.progress + 3f) * onRecord)
        val density = LocalDensity.current
        Box(Modifier.size(with(density) { side.toDp() })
            .pointerInput(side) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    // Only the headshell: elsewhere the drag is Now Playing's (pulled down to close).
                    if ((down.position - stylus(side, angle())).getDistance() > side * 0.09f) return@awaitEachGesture
                    down.consume()
                    while (true) {
                        val event = awaitPointerEvent()
                        val change = event.changes.firstOrNull() ?: break
                        if (!change.pressed) {
                            dragAngle?.let { a ->
                                if (song.duration > 0) currentSeek(((a - outer) / (inner - outer)).coerceIn(0f, 0.995f) * song.duration)
                            }
                            dragAngle = null
                            break
                        }
                        change.consume()
                        val pivot = Offset(side * 0.88f, side * 0.14f)
                        val degrees = Math.toDegrees(atan2((pivot.x - change.position.x).toDouble(), (change.position.y - pivot.y).toDouble())).toFloat()
                        dragAngle = degrees.coerceIn(-3f, inner + 2f)
                    }
                }
            }) {
            Canvas(Modifier.fillMaxSize()) { drawPlatter(side, center) }
            // The record and its label, turning.
            with(density) {
                Box(Modifier.offset { IntOffset((center.x - record).roundToInt(), (center.y - record).roundToInt()) }.size((record * 2).toDp())
                    .shadow(4.dp, CircleShape)
                    .graphicsLayer { rotationZ = (song.clock.value * 200 % 360).toFloat() }) {
                    Canvas(Modifier.fillMaxSize()) { drawRecord() }
                    Cover(cover, Modifier.align(Alignment.Center).size((record * 0.68f).toDp()), round = true)
                }
            }
            Canvas(Modifier.fillMaxSize()) {
                // The light on the record stays where it is while the record turns under it.
                drawCircle(Brush.sweepGradient(listOf(Color.Transparent, Color.White.copy(alpha = 0.16f), Color.Transparent, Color.Transparent,
                    Color.White.copy(alpha = 0.11f), Color.Transparent), center), record, center)
                drawCircle(Brush.radialGradient(listOf(Color.White, Color(0xFF8C8C8C)), center - Offset(side * 0.004f, side * 0.004f), side * 0.012f), side * 0.01f, center)
                drawTonearm(side, angle())
            }
        }
    }
}

private fun stylus(side: Float, angle: Float): Offset {
    val pivot = Offset(side * 0.88f, side * 0.14f)
    val length = side * 0.66f * 0.97f
    val r = Math.toRadians(angle.toDouble())
    return Offset((pivot.x - sin(r) * length).toFloat(), (pivot.y + cos(r) * length).toFloat())
}

private fun DrawScope.drawPlatter(side: Float, center: Offset) {
    val radius = side * 0.42f
    drawCircle(Color.Black.copy(alpha = 0.45f), radius * 1.02f, center + Offset(0f, side * 0.015f))
    drawCircle(Brush.sweepGradient(listOf(Color(0xFFEBEBEB), Color(0xFF808080), Color(0xFFD9D9D9), Color(0xFF6B6B6B), Color(0xFFEBEBEB)), center), radius, center)
    repeat(90) { index ->
        val a = index / 90.0 * 2 * PI
        val p = center + Offset((cos(a) * radius * 0.976f).toFloat(), (sin(a) * radius * 0.976f).toFloat())
        val dot = side * 0.005f
        drawRect(Color.Black.copy(alpha = 0.4f), p - Offset(dot, dot), Size(dot * 2, dot * 2))
    }
    drawCircle(Color(0xFF2B2B2B), radius * 0.93f, center)
    drawCircle(Color.Black.copy(alpha = 0.5f), radius * 0.93f, center, style = Stroke(1f))
}

private fun DrawScope.drawRecord() {
    val outer = size.width / 2
    drawCircle(Color(0xFF0D0D0D))
    var radius = outer * 0.97f
    var index = 0
    while (radius > outer * 0.36f) {
        val gap = index % 23 == 22
        drawCircle(Color.White.copy(alpha = if (gap) 0.1f else if (index % 2 == 0) 0.035f else 0.015f), radius, style = Stroke(if (gap) 1.4f else 0.6f))
        radius -= outer * 0.0085f
        index++
    }
}

private fun DrawScope.drawTonearm(side: Float, angle: Float) {
    val pivot = Offset(side * 0.88f, side * 0.14f)
    val length = side * 0.66f
    // The rest, and the arm's base: a turned aluminum disc.
    drawRoundRect(Color(0xFF1F1F1F), Offset(pivot.x + side * 0.02f, pivot.y + length * 0.72f - side * 0.025f), Size(side * 0.03f, side * 0.05f),
        CornerRadius(side * 0.006f))
    drawCircle(Color.Black.copy(alpha = 0.45f), side * 0.068f, pivot + Offset(0f, side * 0.01f))
    drawCircle(Brush.sweepGradient(listOf(Color(0xFFF2F2F2), Color(0xFF808080), Color(0xFFE0E0E0), Color(0xFF737373), Color(0xFFF2F2F2)), pivot), side * 0.065f, pivot)
    rotate(angle, pivot) {
        val shadow = Offset(side * 0.01f, side * 0.016f)
        drawRoundRect(Color.Black.copy(alpha = 0.35f), Offset(pivot.x - side * 0.0085f, pivot.y) + shadow, Size(side * 0.017f, length), CornerRadius(side * 0.0085f))
        // The knurled counterweight behind the pivot.
        drawRoundRect(Brush.horizontalGradient(listOf(Color(0xFF404040), Color(0xFFB3B3B3), Color(0xFF333333)), pivot.x - side * 0.0275f, pivot.x + side * 0.0275f),
            Offset(pivot.x - side * 0.0275f, pivot.y - side * 0.095f), Size(side * 0.055f, side * 0.07f), CornerRadius(side * 0.006f))
        repeat(6) { i ->
            val y = pivot.y - side * 0.09f + i * side * 0.011f
            drawLine(Color.Black.copy(alpha = 0.35f), Offset(pivot.x - side * 0.0275f, y), Offset(pivot.x + side * 0.0275f, y), max(0.5f, side * 0.002f))
        }
        // The chrome tube.
        drawRoundRect(Brush.horizontalGradient(listOf(Color(0xFF8C8C8C), Color.White, Color(0xFFB3B3B3), Color(0xFF737373)), pivot.x - side * 0.0085f, pivot.x + side * 0.0085f),
            Offset(pivot.x - side * 0.0085f, pivot.y), Size(side * 0.017f, length), CornerRadius(side * 0.0085f))
        // The headshell, the cartridge and the finger lift.
        val shell = Offset(pivot.x - side * 0.0225f, pivot.y + length - side * 0.06f)
        drawRoundRect(Color.Black.copy(alpha = 0.35f), shell + shadow, Size(side * 0.045f, side * 0.08f), CornerRadius(side * 0.006f))
        drawRoundRect(Brush.horizontalGradient(listOf(Color(0xFF4D4D4D), Color(0xFF1F1F1F)), shell.x, shell.x + side * 0.045f), shell, Size(side * 0.045f, side * 0.08f),
            CornerRadius(side * 0.006f))
        drawRoundRect(Color(0xFFBF1A14), Offset(pivot.x - side * 0.015f, shell.y + side * 0.04f), Size(side * 0.03f, side * 0.025f), CornerRadius(side * 0.003f))
        drawRoundRect(Color(0xFFCCCCCC), Offset(pivot.x + side * 0.0225f, shell.y + side * 0.017f), Size(side * 0.03f, side * 0.006f), CornerRadius(side * 0.003f))
    }
    drawCircle(Brush.radialGradient(listOf(Color(0xFF666666), Color(0xFF141414)), pivot - Offset(side * 0.005f, side * 0.006f), side * 0.025f), side * 0.02f, pivot)
}

// MARK: Cassette deck

@Composable
private fun CassettePanel(song: DeckSong, actions: DeckActions, scale: Float, accessory: @Composable () -> Unit) {
    val key = (54 * scale).dp to (62 * scale).dp
    val clock = song.clock
    val paused by remember(song.playing) { derivedStateOf { !song.playing && clock.value > 0.5 } }
    Column(Modifier.widthIn(max = (376 * scale).dp).fillMaxWidth().heightIn(max = (300 * scale * 1.5f).dp).padding(horizontal = (8 * scale).dp),
        verticalArrangement = Arrangement.SpaceBetween) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
            Text("GROOVELIGHT", style = TextStyle(fontSize = (13 * scale).sp, fontWeight = FontWeight.Black, letterSpacing = (2 * scale).sp,
                color = Color.Black.copy(alpha = 0.7f)))
            Spacer(Modifier.weight(1f))
            Engraved("STEREO CASSETTE DECK", (7.5f * scale).sp)
        }
        Spacer(Modifier.height((12 * scale).dp))
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
            VUMeter(0, song.clock, song.playing, song.heardHere, Modifier.size((104 * scale).dp, (64 * scale).dp))
            Gap((10 * scale).dp)
            VUMeter(1, song.clock, song.playing, song.heardHere, Modifier.size((104 * scale).dp, (64 * scale).dp))
            Spacer(Modifier.weight(1f))
            Captioned("COUNTER", scale) {
                TapeCounter(song.clock, Modifier.recess((4 * scale).dp, Brush.verticalGradient(listOf(Color(0xFF1F1F1F), Color(0xFF1F1F1F))))
                    .padding((4 * scale).dp), (28 * scale).dp)
            }
        }
        Spacer(Modifier.height((12 * scale).dp))
        Row(Modifier.align(Alignment.CenterHorizontally).background(Color.Black.copy(alpha = 0.75f), RoundedCornerShape((6 * scale).dp)).padding((5 * scale).dp),
            horizontalArrangement = Arrangement.spacedBy((4 * scale).dp)) {
            PianoKey("Rewind", R.drawable.ic_fast_rewind, key.first, key.second, actions.previous, scan(song, actions, -1))
            PianoKey("Play", R.drawable.ic_play, key.first, key.second, { if (!song.playing) actions.playPause() }, latched = song.playing,
                accent = Color(0xCC34C759))
            PianoKey("Fast Forward", R.drawable.ic_fast_forward, key.first, key.second, actions.next, scan(song, actions, 1))
            PianoKey("Stop", R.drawable.ic_stop, key.first, key.second, { if (song.playing) actions.playPause(); actions.seek(0.0) })
            PianoKey("Pause", R.drawable.ic_pause, key.first, key.second, actions.playPause, latched = paused, accent = Color(0xCCFF9500))
        }
        Spacer(Modifier.height((12 * scale).dp))
        Switches(actions, scale, "OUTPUT LEVEL")
        accessory()
    }
}

/** The deck's cassette well: a door of black plastic, the cassette behind its smoked window, the reels turning. */
@Composable
private fun CassetteStage(design: CassetteDesign, song: DeckSong, cover: File?) {
    BoxWithConstraints(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        val aspect = design.resolvedGeometry.aspectRatio
        val width = min(maxWidth.value, maxHeight.value * aspect * 0.9f / 0.82f)
        val door = Size(width, width / aspect * 0.82f / 0.9f * 1.04f)
        val cassette = Size(door.width * 0.86f, door.width * 0.86f / aspect)
        val corner = (door.width * 0.03f).dp
        Box(Modifier.size(door.width.dp, door.height.dp).shadow(corner, RoundedCornerShape(corner))
            .textured(SkinTexture.BLACK_PLASTIC, -0.05f, shape = RoundedCornerShape(corner))
            .border(1.5.dp, Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.35f), Color.Black.copy(alpha = 0.6f))), RoundedCornerShape(corner))) {
            Box(Modifier.align(Alignment.Center).offset(y = (-door.height * 0.03f).dp)
                .size((cassette.width + door.width * 0.04f).dp, (cassette.height + door.width * 0.04f).dp)
                .clip(RoundedCornerShape(corner * 0.6f)).background(Color.Black)
                .border(2.dp, Brush.verticalGradient(listOf(Color(0xFF333333), Color(0xFFB3B3B3))), RoundedCornerShape(corner * 0.6f)),
                contentAlignment = Alignment.Center) {
                LiveCassette(design, song, cover, Modifier.size(cassette.width.dp, cassette.height.dp))
                // Smoked plexiglass: darker, the light across it.
                Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.24f))
                    .background(Brush.linearGradient(0f to Color.White.copy(alpha = 0.16f), 0.38f to Color.White.copy(alpha = 0.03f), 0.4f to Color.Transparent)))
            }
            Engraved("◀ TAPE ▶", (door.width * 0.022f).sp, onDark = true, modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = (door.height * 0.03f).dp))
        }
    }
}

/** The cassette at this frame (its own scope, so only it is drawn again as the reels turn). */
@Composable
private fun LiveCassette(design: CassetteDesign, song: DeckSong, cover: File?, modifier: Modifier) {
    CassetteFace(design, song.playback(), cover, modifier)
}

// MARK: CD player

@Composable
private fun DiscPanel(song: DeckSong, actions: DeckActions, scale: Float, accessory: @Composable () -> Unit) {
    Column(Modifier.widthIn(max = (376 * scale).dp).fillMaxWidth().heightIn(max = (300 * scale * 1.5f).dp).padding(horizontal = (8 * scale).dp),
        verticalArrangement = Arrangement.SpaceBetween) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
            Text("GROOVELIGHT", style = TextStyle(fontSize = (13 * scale).sp, fontWeight = FontWeight.Black, letterSpacing = (2 * scale).sp,
                color = Color.White.copy(alpha = 0.85f)))
            Spacer(Modifier.weight(1f))
            Engraved("COMPACT DISC PLAYER", (7.5f * scale).sp, onDark = true)
        }
        Spacer(Modifier.height((12 * scale).dp))
        DiscDisplay(song, actions, scale)
        Spacer(Modifier.height((12 * scale).dp))
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            RoundKey("Previous", R.drawable.ic_skip_previous, (46 * scale).dp, actions.previous, scan(song, actions, -1))
            Gap((12 * scale).dp)
            RoundKey(if (song.playing) "Pause" else "Play", R.drawable.ic_play_pause, (58 * scale).dp, actions.playPause)
            Gap((12 * scale).dp)
            RoundKey("Next", R.drawable.ic_skip_next, (46 * scale).dp, actions.next, scan(song, actions, 1))
            Gap((12 * scale).dp)
            RoundKey("Stop", R.drawable.ic_stop, (40 * scale).dp, { if (song.playing) actions.playPause(); actions.seek(0.0) })
            Spacer(Modifier.weight(1f))
            actions.volume?.let { volume ->
                Captioned("VOLUME", scale, onDark = true) { Knob("Volume", volume, actions.onVolume, (70 * scale).dp, onDark = true) }
            }
        }
        Spacer(Modifier.height((12 * scale).dp))
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
            Captioned("RANDOM", scale, onDark = true) {
                RoundKey("Shuffle", R.drawable.ic_shuffle, (30 * scale).dp, actions.toggleShuffle, state = if (actions.shuffled) "On" else "Off")
            }
            Gap((12 * scale).dp)
            Captioned("REPEAT", scale, onDark = true) {
                RoundKey("Repeat", if (actions.repeat == DeckRepeat.ONE) R.drawable.ic_repeat_one else R.drawable.ic_repeat, (30 * scale).dp, actions.cycleRepeat,
                    state = repeatCaption(actions.repeat).lowercase())
            }
            Spacer(Modifier.weight(1f))
            accessory()
        }
    }
}

/** The fluorescent display: play state, random and repeat, the time, the song stepping through, the position bar (dragged, it seeks). */
@Composable
private fun DiscDisplay(song: DeckSong, actions: DeckActions, scale: Float) {
    Column(Modifier.fillMaxWidth().recess((8 * scale).dp, Brush.verticalGradient(listOf(Color(0xFF051414), Color(0xFF030A0D)))).padding((14 * scale).dp),
        verticalArrangement = Arrangement.spacedBy((8 * scale).dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(verticalArrangement = Arrangement.spacedBy((4 * scale).dp)) {
                Indicator(if (song.playing) "PLAY" else "PAUSE", true, scale)
                Indicator("RANDOM", actions.shuffled, scale)
                Indicator(if (actions.repeat == DeckRepeat.ONE) "REPEAT 1" else "REPEAT", actions.repeat != DeckRepeat.OFF, scale)
            }
            Spacer(Modifier.weight(1f))
            DisplayClock(song, scale)
        }
        VFDMarquee(song.title, 14, (15 * scale).sp, song.playing)
        VFDMarquee(song.artist, 14, (15 * scale).sp, song.playing)
        PositionBar(song, actions.seek, Modifier.fillMaxWidth().height((8 * scale).dp))
    }
}

@Composable
private fun DisplayClock(song: DeckSong, scale: Float) = VFDText(clockText(song.clock.value), "88:88", dsegDigits, (34 * scale).sp)

@Composable
private fun Indicator(text: String, lit: Boolean, scale: Float) {
    Text(text, style = TextStyle(fontSize = (8 * scale).sp, fontWeight = FontWeight.Bold, letterSpacing = (1 * scale).sp,
        color = if (lit) vfdColor else vfdColor.copy(alpha = 0.1f)))
}

@Composable
private fun PositionBar(song: DeckSong, seek: (Double) -> Unit, modifier: Modifier) {
    var dragging by remember { mutableStateOf<Float?>(null) }
    val currentSeek by rememberUpdatedState(seek)
    Canvas(modifier.semantics { contentDescription = "Position" }.pointerInput(Unit) {
        awaitEachGesture {
            val down = awaitFirstDown()
            down.consume()
            dragging = (down.position.x / size.width).coerceIn(0f, 1f)
            while (true) {
                val change = awaitPointerEvent().changes.firstOrNull() ?: break
                if (!change.pressed) break
                change.consume()
                dragging = (change.position.x / size.width).coerceIn(0f, 1f)
            }
            dragging?.let { currentSeek(it * song.duration) }
            dragging = null
        }
    }) {
        val segments = 40
        val gap = size.width * 0.006f
        val width = (size.width - gap * (segments - 1)) / segments
        val lit = kotlin.math.ceil((dragging ?: song.progress) * segments).toInt()
        repeat(segments) { i ->
            val x = i * (width + gap)
            if (i < lit) drawRect(vfdColor.copy(alpha = 0.35f), Offset(x - 1, -1f), Size(width + 2, size.height + 2))
            drawRect(if (i < lit) vfdColor else vfdColor.copy(alpha = 0.07f), Offset(x, 0f), Size(width, size.height))
        }
    }
}

/** A top-loading CD player's well: the disc, printed with the cover, turning under a smoked lid. */
@Composable
private fun DiscStage(song: DeckSong, cover: File?) {
    BoxWithConstraints(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        val side = if (maxWidth < maxHeight) maxWidth else maxHeight
        Box(Modifier.size(side), contentAlignment = Alignment.Center) {
            Canvas(Modifier.fillMaxSize().shadow(12.dp, CircleShape)) {
                drawCircle(Brush.sweepGradient(listOf(Color(0xFFD9D9D9), Color(0xFF4D4D4D), Color(0xFFBFBFBF), Color(0xFF404040), Color(0xFFD9D9D9))))
            }
            Box(Modifier.fillMaxSize().padding(side * 0.025f).textured(SkinTexture.BLACK_PLASTIC, -0.08f, shape = CircleShape)
                .background(Brush.radialGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.6f)), radius = Float.POSITIVE_INFINITY), CircleShape))
            Box(Modifier.size(side * 0.86f).shadow(6.dp, CircleShape).clip(DiscShape(0.075f))
                .graphicsLayer { rotationZ = (song.clock.value * 300 % 360).toFloat() }) {
                Canvas(Modifier.fillMaxSize()) {
                    drawCircle(Brush.sweepGradient(listOf(Color(0xFFD9D9D9), Color(0xFF999999), Color(0xFFEBEBEB), Color(0xFF8C8C8C), Color(0xFFD9D9D9))))
                }
                Box(Modifier.fillMaxSize().clip(DiscShape(0.24f, inset = 0.012f))) { Cover(cover, Modifier.fillMaxSize(), corner = 0.dp) }
                Canvas(Modifier.fillMaxSize()) {
                    drawCircle(Color.White.copy(alpha = 0.5f), size.width * 0.17f, style = Stroke(size.width * 0.004f))
                    drawCircle(Color.Black.copy(alpha = 0.15f), size.width * 0.12f, style = Stroke(size.width * 0.002f))
                    drawCircle(Color.White.copy(alpha = 0.4f), size.width / 2 - size.width * 0.002f, style = Stroke(size.width * 0.004f))
                }
            }
            // The rainbow the light makes stays with the light; the clamp; the smoked lid.
            Canvas(Modifier.size(side * 0.86f).clip(DiscShape(0.075f))) {
                drawCircle(Brush.sweepGradient(listOf(Color.Transparent, Color.Cyan.copy(alpha = 0.2f), Color.Magenta.copy(alpha = 0.14f), Color.Transparent,
                    Color.Yellow.copy(alpha = 0.15f), Color(0xFFFF80C0).copy(alpha = 0.13f), Color.Transparent)))
            }
            Canvas(Modifier.size(side * 0.12f).shadow(4.dp, CircleShape)) {
                drawCircle(Brush.sweepGradient(listOf(Color(0xFFF2F2F2), Color(0xFF737373), Color(0xFFE6E6E6), Color(0xFF666666), Color(0xFFF2F2F2))))
                drawCircle(Color(0xFF262626), size.width * 0.25f)
            }
            Canvas(Modifier.fillMaxSize().padding(side * 0.025f)) {
                drawCircle(Brush.linearGradient(0f to Color.White.copy(alpha = 0.2f), 0.42f to Color.White.copy(alpha = 0.04f), 0.45f to Color.Transparent,
                    1f to Color.Black.copy(alpha = 0.18f), start = Offset.Zero, end = Offset(size.width, size.height)))
            }
        }
    }
}

/** A cap of the app's own buttons over a player: [content] (an icon button) on round aluminum. */
@Composable
fun DeckCapBox(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Box(modifier.padding(4.dp).size(40.dp).deckCap(), contentAlignment = Alignment.Center) { content() }
}

