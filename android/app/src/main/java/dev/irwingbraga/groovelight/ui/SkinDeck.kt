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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.withFrameNanos
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.res.imageResource
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.BlendMode
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
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.text.font.FontFamily
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
               val heardHere: Boolean = false, val format: PcFormat? = null) {
    val progress: Float get() = if (duration > 0) (clock.value / duration).toFloat().coerceIn(0f, 1f) else 0f
    fun playback() = SkinPlayback(title, artist, playing, clock.value, duration)
}

enum class DeckRepeat { OFF, ALL, ONE }

/**
 * What the player's keys, knobs and switches do. [volume] null hides the volume knob; [equalizer] (on or off, null
 * where not offered) is the PC Player's EQ key, and [eject] its eject key (leaving Now Playing).
 */
class DeckActions(
    val playPause: () -> Unit, val previous: () -> Unit, val next: () -> Unit, val seek: (Double) -> Unit,
    val volume: Float?, val onVolume: (Float) -> Unit,
    val shuffled: Boolean, val toggleShuffle: () -> Unit, val repeat: DeckRepeat, val cycleRepeat: () -> Unit,
    val equalizer: Boolean? = null, val toggleEqualizer: () -> Unit = {}, val eject: (() -> Unit)? = null,
    /** The song loved or not (the PC Player's heart key); null where it cannot be loved. */
    val loved: Boolean? = null, val toggleLove: () -> Unit = {},
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
        // The desktop of the time, teal.
        NowPlayingSkin.PC_PLAYER -> androidx.compose.foundation.Image(androidx.compose.ui.res.painterResource(R.drawable.skin_hill), null, modifier,
            contentScale = androidx.compose.ui.layout.ContentScale.Crop)
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
             stageOverlay: (@Composable () -> Unit)? = null, playlist: PlayerModel.Playlist? = null, onPlaylistPlay: ((Int) -> Unit)? = null,
             accessory: @Composable () -> Unit = {}) {
    val hinge = currentWindowAdaptiveInfo().windowPosture.hingeList.firstOrNull { it.isSeparating || !it.isFlat }?.bounds
    var origin by remember { mutableStateOf(Offset.Zero) }
    BoxWithConstraints(modifier.onGloballyPositioned { origin = it.positionInWindow() }) {
        val density = LocalDensity.current
        val size = Size(constraints.maxWidth.toFloat(), constraints.maxHeight.toFloat())
        val margin = with(density) { 14.dp.toPx() }
        val fold = hinge?.let { Rect(it.left - origin.x, it.top - origin.y, it.right - origin.x, it.bottom - origin.y) }
        if (skin == NowPlayingSkin.PC_PLAYER) {
            val theme by Cassettes.pcTheme.collectAsStateWithLifecycle()
            if (theme == PcTheme.CORONA) CoronaPlayer(song, actions, playlist, onPlaylistPlay, fold, cover, stageOverlay, Modifier.fillMaxSize())
            else PcPlayer(song, actions, playlist, onPlaylistPlay, fold, stageOverlay, Modifier.fillMaxSize())
            return@BoxWithConstraints
        }
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

/** A step of the cassette deck's Rewind or Fast Forward held, with the tape's sound as a deck makes it. */
private fun cue(song: DeckSong, actions: DeckActions, direction: Int): () -> Unit {
    val step = scan(song, actions, direction)
    return { TapeCue.cue(); step() }
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
        DialWindow(song, actions.seek, scale)
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
    // 33⅓ turns a minute; a direct-drive motor is up to speed in a second, the platter coasts to a stop.
    val spin = rememberSpin(song.playing, speed = 200.0, spinUp = 1.0, spinDown = 2.6)
    val vinyl = ImageBitmap.imageResource(R.drawable.skin_vinyl)
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
                    .graphicsLayer { rotationZ = spin.value }) {
                    Canvas(Modifier.fillMaxSize()) { drawRecord(vinyl) }
                    Cover(cover, Modifier.align(Alignment.Center).size((record * 0.68f).toDp()), round = true)
                }
            }
            // The light on the record stays where it is while the record turns under it.
            Canvas(Modifier.fillMaxSize().graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }) { drawVinylSheen(vinyl, center, record) }
            Canvas(Modifier.fillMaxSize()) {
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

/** Black vinyl, its grooves ([vinyl], how much each point scatters the light) faintly seen in the room's light. */
private fun DrawScope.drawRecord(vinyl: ImageBitmap) {
    drawCircle(Color(0xFF090909))
    drawImage(vinyl, dstSize = IntSize(size.width.roundToInt(), size.height.roundToInt()), alpha = 0.17f)
}

/** The grooves' light as a mask: white where they scatter it, clear where they don't. */
private val luminanceToAlpha = ColorFilter.colorMatrix(ColorMatrix(floatArrayOf(
    0f, 0f, 0f, 0f, 255f,
    0f, 0f, 0f, 0f, 255f,
    0f, 0f, 0f, 0f, 255f,
    0.2126f, 0.7152f, 0.0722f, 0f, 0f,
)))

/**
 * The lamp's light on a record of [radius] at [center]: two bright wedges across from each other, where the grooves face
 * the light, each made of the grooves' fine lines (the record's own grooves are its mask). Drawn in its own layer.
 */
private fun DrawScope.drawVinylSheen(vinyl: ImageBitmap, center: Offset, radius: Float) {
    val white = Color.White
    rotate(-20f, center) {
        drawCircle(Brush.sweepGradient(
            0f to Color.Transparent, 0.06f to white.copy(alpha = 0.18f), 0.11f to white.copy(alpha = 0.75f), 0.16f to white.copy(alpha = 0.18f),
            0.24f to Color.Transparent, 0.53f to Color.Transparent, 0.57f to white.copy(alpha = 0.12f), 0.61f to white.copy(alpha = 0.5f),
            0.65f to white.copy(alpha = 0.12f), 0.72f to Color.Transparent, 1f to Color.Transparent, center = center), radius, center)
    }
    val side = (radius * 2).roundToInt()
    drawImage(vinyl, dstOffset = IntOffset((center.x - radius).roundToInt(), (center.y - radius).roundToInt()), dstSize = IntSize(side, side),
        colorFilter = luminanceToAlpha, blendMode = BlendMode.DstIn)
}

/** Polished chrome: a mirror of the room, so a bright window, a dark floor and the sky, sharply, rather than a soft gray. */
private object Chrome {
    private val stops = arrayOf(
        0f to Color(0xFF292B30), 0.1f to Color(0xFF6B6E73), 0.2f to Color(0xFFDBDEE0), 0.25f to Color.White, 0.31f to Color(0xFFCCCCC9),
        0.44f to Color(0xFF666663), 0.54f to Color(0xFF212124), 0.66f to Color(0xFF4D4F54), 0.79f to Color(0xFFBDC4D1), 0.9f to Color(0xFF8C9199),
        1f to Color(0xFF242429),
    )

    /** A rod's or a cylinder's chrome, across it from [start] to [end]. */
    fun cylinder(start: Offset, end: Offset) = Brush.linearGradient(*stops, start = start, end = end)

    /** A dome's chrome (a pivot's cap, a screw head) of [radius] at [center]: the window's reflection near the top left. */
    fun dome(center: Offset, radius: Float) = Brush.radialGradient(
        0f to Color.White, 0.12f to Color(0xFFEBEBEB), 0.35f to Color(0xFF737373), 0.62f to Color(0xFF1F1F24), 0.86f to Color(0xFF8C94A1),
        1f to Color(0xFF333333), center = center - Offset(radius * 0.28f, radius * 0.36f), radius = radius * 1.3f,
    )

    /** Turned (lathe-cut) metal seen from above: light and dark sectors where the fine rings catch the light. */
    fun turned(center: Offset) = Brush.sweepGradient(listOf(Color(0xFFF7F7F7), Color(0xFF9E9E9E), Color(0xFF595959), Color(0xFFB3B3B3),
        Color(0xFFFAFAFA), Color(0xFF999999), Color(0xFF4D4D4D), Color(0xFFADADAD), Color(0xFFF7F7F7)), center)
}

private fun DrawScope.drawTonearm(side: Float, angle: Float) {
    val pivot = Offset(side * 0.88f, side * 0.14f)
    val length = side * 0.66f
    // The rest the arm sits on: a black rubber cradle on a chrome post.
    val rest = Offset(pivot.x + side * 0.035f, pivot.y + length * 0.72f)
    drawCircle(Color.Black.copy(alpha = 0.4f), side * 0.013f, rest + Offset(0f, side * 0.015f))
    drawCircle(Chrome.dome(rest + Offset(0f, side * 0.012f), side * 0.012f), side * 0.012f, rest + Offset(0f, side * 0.012f))
    drawRoundRect(Brush.horizontalGradient(listOf(Color(0xFF333333), Color(0xFF0F0F0F)), rest.x - side * 0.015f, rest.x + side * 0.015f),
        Offset(rest.x - side * 0.015f, rest.y - side * 0.03f), Size(side * 0.03f, side * 0.04f), CornerRadius(side * 0.006f))
    // The arm's base: a disc of turned aluminum, its lathe rings.
    val base = side * 0.065f
    drawCircle(Color.Black.copy(alpha = 0.45f), base * 1.04f, pivot + Offset(0f, side * 0.01f))
    drawCircle(Chrome.turned(pivot), base, pivot)
    var ring = base - 1f
    var index = 0
    while (ring > base * 0.2f) {
        drawCircle(if (index % 3 == 0) Color.White.copy(alpha = 0.2f) else Color.Black.copy(alpha = 0.07f), ring, pivot, style = Stroke(0.6f))
        ring -= max(1f, base * 0.024f)
        index++
    }
    drawCircle(Brush.linearGradient(listOf(Color.White.copy(alpha = 0.85f), Color.Black.copy(alpha = 0.5f)), pivot - Offset(base, base), pivot + Offset(base, base)),
        base, pivot, style = Stroke(1.5f))
    rotate(angle, pivot) {
        val shadow = Offset(side * 0.01f, side * 0.016f)
        fun across(half: Float) = Chrome.cylinder(Offset(pivot.x - half, 0f), Offset(pivot.x + half, 0f))
        drawRoundRect(Color.Black.copy(alpha = 0.35f), Offset(pivot.x - side * 0.0085f, pivot.y) + shadow, Size(side * 0.017f, length), CornerRadius(side * 0.0085f))
        // The counterweight behind the pivot: a chrome cylinder, knurled, a black ring at its end.
        val weight = Offset(pivot.x - side * 0.0275f, pivot.y - side * 0.095f)
        drawRoundRect(Color.Black.copy(alpha = 0.35f), weight + shadow, Size(side * 0.055f, side * 0.07f), CornerRadius(side * 0.005f))
        drawRoundRect(across(side * 0.0275f), weight, Size(side * 0.055f, side * 0.07f), CornerRadius(side * 0.005f))
        repeat(7) { i ->
            val y = weight.y + side * 0.018f + i * side * 0.0055f
            drawLine(Color.Black.copy(alpha = 0.28f), Offset(weight.x, y), Offset(weight.x + side * 0.055f, y), max(0.5f, side * 0.0018f))
        }
        drawRoundRect(Brush.horizontalGradient(listOf(Color(0xFF0D0D0D), Color(0xFF4D4D4D), Color(0xFF0A0A0A)), weight.x, weight.x + side * 0.055f),
            weight, Size(side * 0.055f, side * 0.012f), CornerRadius(side * 0.004f))
        // The tube, polished chrome.
        drawRoundRect(across(side * 0.0085f), Offset(pivot.x - side * 0.0085f, pivot.y), Size(side * 0.017f, length), CornerRadius(side * 0.0085f))
        drawRoundRect(Color.Black.copy(alpha = 0.3f), Offset(pivot.x - side * 0.0085f, pivot.y), Size(side * 0.017f, length), CornerRadius(side * 0.0085f),
            style = Stroke(0.6f))
        // The headshell (brushed aluminum, a chrome edge), its screws, the cartridge under it and the chrome finger lift.
        val shell = Offset(pivot.x - side * 0.0225f, pivot.y + length - side * 0.06f)
        val shellSize = Size(side * 0.045f, side * 0.08f)
        drawRoundRect(Color.Black.copy(alpha = 0.35f), shell + shadow, shellSize, CornerRadius(side * 0.006f))
        drawRoundRect(Brush.horizontalGradient(listOf(Color(0xFF8A8C90), Color(0xFFE6E8EA), Color(0xFFB0B2B5), Color(0xFF6E7074)), shell.x, shell.x + shellSize.width),
            shell, shellSize, CornerRadius(side * 0.006f))
        drawRoundRect(Chrome.cylinder(shell, Offset(shell.x, shell.y + shellSize.height)), shell, shellSize, CornerRadius(side * 0.006f), style = Stroke(side * 0.003f))
        listOf(-1, 1).forEach { sign ->
            val screw = Offset(pivot.x + sign * side * 0.012f, shell.y + side * 0.028f)
            drawCircle(Chrome.dome(screw, side * 0.004f), side * 0.004f, screw)
            drawCircle(Color.Black.copy(alpha = 0.5f), side * 0.004f, screw, style = Stroke(0.6f))
        }
        drawRoundRect(Brush.horizontalGradient(listOf(Color(0xFF8C0F0D), Color(0xFFD9261A), Color(0xFF800D0A)), pivot.x - side * 0.015f, pivot.x + side * 0.015f),
            Offset(pivot.x - side * 0.015f, shell.y + side * 0.045f), Size(side * 0.03f, side * 0.025f), CornerRadius(side * 0.003f))
        val lift = Offset(pivot.x + side * 0.0225f, shell.y + side * 0.0165f)
        drawRoundRect(Chrome.cylinder(lift, lift + Offset(0f, side * 0.007f)), lift, Size(side * 0.03f, side * 0.007f), CornerRadius(side * 0.0035f))
    }
    // The pivot's chrome cap.
    drawCircle(Color.Black.copy(alpha = 0.45f), side * 0.021f, pivot + Offset(0f, side * 0.004f))
    drawCircle(Chrome.dome(pivot, side * 0.02f), side * 0.02f, pivot)
    drawCircle(Color.Black.copy(alpha = 0.45f), side * 0.02f, pivot, style = Stroke(1f))
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
            PianoKey("Rewind", R.drawable.ic_fast_rewind, key.first, key.second, actions.previous, cue(song, actions, -1))
            PianoKey("Play", R.drawable.ic_play, key.first, key.second, { if (!song.playing) actions.playPause() }, latched = song.playing,
                accent = Color(0xCC34C759))
            PianoKey("Fast Forward", R.drawable.ic_fast_forward, key.first, key.second, actions.next, cue(song, actions, 1))
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

private val dialLettering = Color(0xFFFFEDC7)
private val dialGlow = Color(0xFFFF992E)

/**
 * A receiver's dial window, set into the plate: smoked glass lit warm from behind by its lamps, the song in cream
 * lettering, the artist and the album under it, and the printed scale along the bottom, its red pointer where the song
 * is (dragged along the scale, it goes there).
 */
@Composable
private fun DialWindow(song: DeckSong, seek: (Double) -> Unit, scale: Float) {
    val corner = RoundedCornerShape((5 * scale).dp)
    val subtitle = listOf(song.artist, song.album).filter { it.isNotBlank() }.joinToString("  ·  ")
    val glow = Shadow(dialGlow.copy(alpha = 0.85f), Offset.Zero, 8 * scale)
    Column(Modifier.fillMaxWidth()
        .background(Color.Black.copy(alpha = 0.12f), RoundedCornerShape((7 * scale).dp)).padding((2 * scale).dp)
        .clip(corner)
        .drawBehind {
            // The glass, dark, warmed by the lamps behind it (brightest low in the middle), darker at its ends.
            drawRect(Color(0xFF120B06))
            drawRect(Brush.radialGradient(listOf(dialGlow.copy(alpha = 0.42f), dialGlow.copy(alpha = 0.12f), Color.Transparent),
                Offset(size.width / 2, size.height * 0.85f), size.width * 0.5f))
            drawRect(Brush.horizontalGradient(listOf(Color.Black.copy(alpha = 0.55f), Color.Transparent, Color.Transparent, Color.Black.copy(alpha = 0.55f))))
        }
        .drawWithContent {
            drawContent()
            // The glass's reflection, across its top.
            drawRect(Brush.verticalGradient(0f to Color.White.copy(alpha = 0.13f), 0.42f to Color.White.copy(alpha = 0.04f), 0.46f to Color.Transparent))
        }
        .border((1.5f * scale).dp, Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.7f), Color.White.copy(alpha = 0.6f))), corner)
        .semantics(mergeDescendants = true) {}
        .padding(start = (12 * scale).dp, end = (12 * scale).dp, top = (9 * scale).dp, bottom = (6 * scale).dp)) {
        Text(song.title.ifEmpty { " " }, maxLines = 1, overflow = TextOverflow.Ellipsis, style = TextStyle(fontSize = (16 * scale).sp,
            fontWeight = FontWeight.Medium, letterSpacing = (1.2 * scale).sp, color = dialLettering, shadow = glow,
            fontFamily = FontFamily.SansSerif))
        Gap((3 * scale).dp)
        Text(subtitle.ifEmpty { " " }, maxLines = 1, overflow = TextOverflow.Ellipsis, style = TextStyle(fontSize = (10.5f * scale).sp,
            letterSpacing = (0.9f * scale).sp, color = dialLettering.copy(alpha = 0.72f), shadow = glow, fontFamily = FontFamily.SansSerif))
        DialScale(song, seek, scale, Modifier.padding(top = (7 * scale).dp).fillMaxWidth().height((20 * scale).dp))
    }
}

/** The dial's printed scale: fine ticks, longer every fifth, and the red pointer along it where the song is. */
@Composable
private fun DialScale(song: DeckSong, seek: (Double) -> Unit, scale: Float, modifier: Modifier) {
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
            dragging?.let { if (song.duration > 0) currentSeek(it.coerceAtMost(0.995f) * song.duration) }
            dragging = null
        }
    }) {
        val ticks = 50
        val top = size.height * 0.35f
        for (tick in 0..ticks) {
            val x = size.width * tick / ticks
            val long = tick % 5 == 0
            drawLine(dialLettering.copy(alpha = if (long) 0.75f else 0.45f), Offset(x, top), Offset(x, size.height * (if (long) 0.95f else 0.7f)),
                if (long) 1.5f else 1f)
        }
        drawLine(dialLettering.copy(alpha = 0.5f), Offset(0f, top), Offset(size.width, top), 1f)
        val x = size.width * (dragging ?: song.progress)
        val width = max(3f, 2.2f * scale * density)
        drawRoundRect(Color(0x66FF3319), Offset(x - width * 1.6f, -size.height * 0.2f), Size(width * 3.2f, size.height * 1.3f), CornerRadius(width))
        drawRoundRect(Color(0xFFFF3820), Offset(x - width / 2, -size.height * 0.15f), Size(width, size.height * 1.2f), CornerRadius(width / 2))
    }
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
    val spin = rememberSpin(song.playing, speed = 300.0, spinUp = 1.5, spinDown = 2.0)
    BoxWithConstraints(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        val side = if (maxWidth < maxHeight) maxWidth else maxHeight
        Box(Modifier.size(side), contentAlignment = Alignment.Center) {
            Canvas(Modifier.fillMaxSize().shadow(12.dp, CircleShape)) {
                drawCircle(Brush.sweepGradient(listOf(Color(0xFFD9D9D9), Color(0xFF4D4D4D), Color(0xFFBFBFBF), Color(0xFF404040), Color(0xFFD9D9D9))))
            }
            Box(Modifier.fillMaxSize().padding(side * 0.025f).textured(SkinTexture.BLACK_PLASTIC, -0.08f, shape = CircleShape)
                .background(Brush.radialGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.6f)), radius = Float.POSITIVE_INFINITY), CircleShape))
            // The spindle motor spins the disc up in a second and a half, and brakes it in two.
            Box(Modifier.size(side * 0.86f).clip(DiscShape(DiscRadii.HOLE)).graphicsLayer { rotationZ = spin.value }) {
                CompactDisc(cover)
            }
            // The rainbow the light makes stays with the light; the clamp; the smoked lid.
            Canvas(Modifier.size(side * 0.86f).clip(DiscShape(DiscRadii.MIRROR))) {
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

/** A compact disc's radii over its width: the hole, the hub's stacking ring, the mirror's start, the print's start. */
internal object DiscRadii {
    const val HOLE = 0.0625f
    const val STACKING_RING = 0.115f
    const val MIRROR = 0.17f
    const val PRINT = 0.183f
}

/**
 * The disc as a real one is (120 mm across): the 15 mm hole, the clear hub out to 41 mm, the mirror's edge, and the cover
 * printed from 44 mm to the rim.
 */
@Composable
private fun CompactDisc(cover: File?) {
    Box(Modifier.fillMaxSize()) {
        Canvas(Modifier.fillMaxSize()) {
            val w = size.width
            // The clear polycarbonate hub: the well shows through it, a little lighter.
            drawCircle(Brush.radialGradient(listOf(Color.White.copy(alpha = 0.22f), Color.White.copy(alpha = 0.38f)), radius = w * DiscRadii.MIRROR),
                w * DiscRadii.MIRROR)
            drawCircle(Brush.sweepGradient(listOf(Color.Transparent, Color.White.copy(alpha = 0.3f), Color.Transparent, Color.Transparent,
                Color.White.copy(alpha = 0.22f), Color.Transparent)), w * DiscRadii.MIRROR)
            drawCircle(Color.White.copy(alpha = 0.28f), w * DiscRadii.STACKING_RING, style = Stroke(w * 0.004f))
            drawCircle(Color.White.copy(alpha = 0.35f), w * (DiscRadii.HOLE + 0.002f), style = Stroke(w * 0.002f))
            // The mirror, a ring from the hub to the rim.
            val mirror = w / 2 - w * DiscRadii.MIRROR
            drawCircle(Brush.sweepGradient(listOf(Color(0xFFD9D9D9), Color(0xFF999999), Color(0xFFEBEBEB), Color(0xFF8C8C8C), Color(0xFFD9D9D9))),
                w * DiscRadii.MIRROR + mirror / 2, style = Stroke(mirror))
        }
        Box(Modifier.fillMaxSize().clip(DiscShape(DiscRadii.PRINT, inset = 0.008f))) { Cover(cover, Modifier.fillMaxSize(), corner = 0.dp) }
        Canvas(Modifier.fillMaxSize()) {
            val w = size.width
            // The mirror's dark inner edge, the print's edge, and the rim.
            drawCircle(Color(0xB3333333), w * DiscRadii.MIRROR - w * 0.0025f, style = Stroke(w * 0.005f))
            drawCircle(Color.Black.copy(alpha = 0.15f), w * DiscRadii.PRINT, style = Stroke(w * 0.002f))
            drawCircle(Color.White.copy(alpha = 0.4f), w / 2 - w * 0.002f, style = Stroke(w * 0.004f))
        }
    }
}

/**
 * A motor's turning: its angle (degrees) at any moment, from the clock rather than the song's time (which jumps a little
 * each time the player reports its position). A change of speed takes [spinUp] seconds from rest to full speed (or
 * [spinDown] from full speed to rest), easing in and out as a real platter or disc does.
 */
class SpinMotion(private val speed: Double, private val spinUp: Double, private val spinDown: Double, isOn: Boolean) {
    private var angle = 0.0
    private var velocity = if (isOn) speed else 0.0
    private var target = velocity
    private var duration = 0.0
    private var since = 0.0

    /** Where it is and how fast it turns (degrees, degrees a second) at [time] (seconds). */
    fun state(time: Double): Pair<Double, Double> {
        val elapsed = max(time - since, 0.0)
        if (duration <= 0) return (angle + velocity * elapsed) to velocity
        // The speed follows smoothstep (3u² - 2u³) from `velocity` to `target`; the angle is its integral.
        val u = min(elapsed / duration, 1.0)
        val change = target - velocity
        val turned = velocity * duration * u + change * duration * (u * u * u - u * u * u * u / 2)
        return (angle + turned + target * max(elapsed - duration, 0.0)) to (velocity + change * (3 * u * u - 2 * u * u * u))
    }

    /** Starts the motor ([isOn]) or stops it, at [time]. */
    fun turn(isOn: Boolean, time: Double) {
        val (angleNow, velocityNow) = state(time)
        angle = angleNow % 360
        velocity = velocityNow
        target = if (isOn) speed else 0.0
        since = time
        duration = kotlin.math.abs(target - velocity) / speed * (if (isOn) spinUp else spinDown)
    }

    /** Whether it still turns at [time]. */
    fun isTurning(time: Double) = state(time).second > 0.001 || target > 0
}

/** The angle of something turned by a motor that runs while [isOn]: it speeds up when it starts and coasts to a stop. */
@Composable
fun rememberSpin(isOn: Boolean, speed: Double, spinUp: Double, spinDown: Double): State<Float> {
    val motion = remember { SpinMotion(speed, spinUp, spinDown, isOn) }
    val angle = remember { mutableFloatStateOf(0f) }
    LaunchedEffect(isOn) {
        motion.turn(isOn, System.nanoTime() / 1e9)
        var turning = true
        while (turning) withFrameNanos { frame ->
            val time = frame / 1e9
            angle.floatValue = (motion.state(time).first % 360).toFloat()
            turning = motion.isTurning(time)
        }
    }
    return angle
}

/** A cap of the app's own buttons over a player: [content] (an icon button) on round aluminum. */
@Composable
fun DeckCapBox(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Box(modifier.padding(4.dp).size(40.dp).deckCap(), contentAlignment = Alignment.Center) { content() }
}

