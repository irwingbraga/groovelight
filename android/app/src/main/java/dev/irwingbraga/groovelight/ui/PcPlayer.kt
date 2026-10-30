package dev.irwingbraga.groovelight.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import dev.irwingbraga.groovelight.R
import dev.irwingbraga.groovelight.playback.AudioTap
import kotlin.math.PI
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin

// The PC Player, as on the Mac and the iPhone (GroovelightKit's PCPlayer): a desktop music player of the late 1990s,
// after the classic two-window skin, drawn on the original's pixel grid (the main window 275 by 116) and scaled up.

/** A song file's bit rate (kbps), sample rate (kHz) and channels, as the PC Player shows them. */
data class PcFormat(val kbps: Int?, val kHz: Int?, val channels: Int?) {
    companion object {
        /** From a file's sample rate and bit depth: a lossless file's bit rate is the PCM rate (1411 for a CD). */
        fun of(sampleRate: Int?, bitDepth: Int?, channels: Int? = null): PcFormat? {
            if (sampleRate == null) return null
            val kbps = bitDepth?.let { (sampleRate.toLong() * it * (channels ?: 2) / 1000).toInt() }
            return PcFormat(kbps, (sampleRate / 1000.0).roundToInt(), channels)
        }
    }
}

private object Pc {
    val digits = Color(0xFF00F800)
    val text = Color(0xFF00E200)
    val listText = Color(0xFF00FF00)
    val dots = Color(0xFF182129)
    val keyFace = Color(0xFFBDCED6)
    val keyLight = Color(0xFFEFFFFF)
    val keyEdge = Color(0xFFADB5C6)
    val keyShade = Color(0xFF7B8494)
    val keyDark = Color(0xFF4A5A6B)
    val glyph = Color(0xFF97A8B9)
    val ink = Color(0xFF2F374D)
    val frameLight = Color(0xFF73738A)
    val goldLight = Color(0xFFECCE7A)
    val goldDim = Color(0xFFA3946A)
    val goldDark = Color(0xFF45413C)
    /** The spectrum's colors, from the top of a bar to its foot (the base skin's VISCOLOR 2 to 17), and its peaks. */
    val spectrum = listOf(0xFFEF3110, 0xFFCE2910, 0xFFD65A00, 0xFFD66600, 0xFFD67300, 0xFFC67B08, 0xFFDEA518, 0xFFD6B521, 0xFFBDDE29,
        0xFF94DE21, 0xFF29CE10, 0xFF32BE10, 0xFF39B510, 0xFF319C08, 0xFF299400, 0xFF188408).map { Color(it) }
    val peak = Color(0xFF969696)
    const val WIDTH = 275f
    const val HEIGHT = 116f
}

private val pixelFont = FontFamily(Font(R.font.silkscreen_regular), Font(R.font.silkscreen_bold, FontWeight.Bold))

/**
 * The PC Player filling Now Playing: the main window docked over the playlist (or on either side of a fold), its own
 * keys for everything (the heart too). [overlay] (the lyrics, Up Next) takes the playlist's place inside its window.
 */
@Composable
fun PcPlayer(song: DeckSong, actions: DeckActions, playlist: PlayerModel.Playlist?, onPlay: ((Int) -> Unit)?, fold: Rect?,
             overlay: (@Composable () -> Unit)?, modifier: Modifier = Modifier) {
    var showsPlaylist by remember { mutableStateOf(true) }
    BoxWithConstraints(modifier) {
        val density = LocalDensity.current
        val size = Size(constraints.maxWidth.toFloat(), constraints.maxHeight.toFloat())
        val layout = PcLayout.of(size, with(density) { 10.dp.toPx() }, 0f, fold)
        with(density) {
            Box(Modifier.offset { IntOffset(layout.main.left.roundToInt(), layout.main.top.roundToInt()) }
                .size(layout.main.width.toDp(), layout.main.height.toDp())) {
                PcMainWindow(layout.scale, song, actions, showsPlaylist) { showsPlaylist = !showsPlaylist }
            }
            if (showsPlaylist) {
                Box(Modifier.offset { IntOffset(layout.playlist.left.roundToInt(), layout.playlist.top.roundToInt()) }
                    .size(layout.playlist.width.toDp(), layout.playlist.height.toDp())) {
                    PcPlaylistWindow(layout.scale, song, actions, playlist, onPlay, overlay)
                }
            }
        }
    }
}

/** Where the windows go, and the scale they are drawn at (pixels per pixel of the original). */
internal class PcLayout(val main: Rect, val playlist: Rect, val accessory: Rect, val scale: Float) {
    companion object {
        fun of(size: Size, margin: Float, accessoryHeight: Float, fold: Rect?): PcLayout {
            val area = Rect(margin, 0f, size.width - margin, size.height - margin)
            val aspect = Pc.WIDTH / Pc.HEIGHT
            if (fold != null && fold.height >= size.height * 0.5f && fold.left > area.left + margin * 8 && fold.right < area.right - margin * 8) {
                val left = Rect(area.left, area.top, fold.left - margin, area.bottom)
                val width = min(min(left.width, left.height * 0.6f * aspect), Pc.WIDTH * 3 * margin / 10)
                val main = Rect(Offset(left.center.x - width / 2, left.top), Size(width, width / aspect))
                return PcLayout(main, Rect(fold.right + margin, area.top, area.right, area.bottom),
                    Rect(left.left, main.bottom + margin, left.right, main.bottom + margin + accessoryHeight), width / Pc.WIDTH)
            }
            if (fold != null && fold.width >= size.width * 0.5f && fold.top > area.top + margin * 8 && fold.bottom < area.bottom - margin * 8) {
                val width = min(area.width, (fold.top - margin - area.top) * aspect)
                val main = Rect(Offset(area.center.x - width / 2, area.top), Size(width, width / aspect))
                val playlist = Rect(main.left, fold.bottom + margin, main.right, area.bottom - accessoryHeight)
                return PcLayout(main, playlist, Rect(area.left, playlist.bottom, area.right, area.bottom), width / Pc.WIDTH)
            }
            // Docked, the playlist under the main window: as wide as the screen while the playlist keeps half the height.
            val width = min(area.width, (area.height - accessoryHeight) * 0.45f * aspect)
            val main = Rect(Offset(area.center.x - width / 2, area.top), Size(width, width / aspect))
            val playlist = Rect(main.left, main.bottom, main.right, max(area.bottom - accessoryHeight, main.bottom + 60f))
            return PcLayout(main, playlist, Rect(area.left, playlist.bottom, area.right, area.bottom), width / Pc.WIDTH)
        }
    }
}

/** Placed at ([x], [y]), [w] by [h] on the original's pixel grid, drawn at [u] pixels each. */
internal fun Modifier.pc(x: Float, y: Float, w: Float, h: Float, u: Float): Modifier = composed {
    val density = LocalDensity.current
    with(density) { offset { IntOffset((x * u).roundToInt(), (y * u).roundToInt()) }.size((w * u).toDp(), (h * u).toDp()) }
}

private fun r(x: Float, y: Float, w: Float, h: Float, u: Float) = Rect(x * u, y * u, (x + w) * u, (y + h) * u)

/** A rectangle of whole pixels on the original's grid, [u] pixels each. */
private fun DrawScope.px(x: Float, y: Float, w: Float, h: Float, color: Color, u: Float) {
    if (w > 0 && h > 0) drawRect(color, Offset(x * u, y * u), Size(w * u, h * u))
}

/** An engraved line around a rectangle: shaded above and on the left, lit below and on the right. */
private fun DrawScope.groove(x: Float, y: Float, w: Float, h: Float, u: Float, dark: Color = Color(0xFF101019), light: Color = Pc.frameLight) {
    px(x, y, w, 1f, dark, u); px(x, y, 1f, h, dark, u)
    px(x, y + h - 1, w, 1f, light, u); px(x + w - 1, y, 1f, h, light, u)
}

private val faceStops = listOf(0xFF0D0D14, 0xFF1A1927, 0xFF202033, 0xFF27283E, 0xFF2E2D48, 0xFF343351, 0xFF383758, 0xFF39395A, 0xFF383757,
    0xFF343351, 0xFF2E2D47, 0xFF26263B).mapIndexed { i, c -> i / 11f to Color(c) }.toTypedArray()

/**
 * A window's face as the base skin paints it: nearly black at its left edge, lightening to a slate violet a little right
 * of the middle and darkening again to the right, with a darker band low across it ([band], fractions of the height).
 */
private fun DrawScope.windowFace(band: ClosedFloatingPointRange<Float>? = null) {
    drawRect(Brush.horizontalGradient(*faceStops))
    band?.let {
        drawRect(Brush.verticalGradient(it.start - 0.08f to Color.Transparent, it.start to Color.Black.copy(alpha = 0.13f),
            it.endInclusive to Color.Black.copy(alpha = 0.13f), it.endInclusive + 0.08f to Color.Transparent))
    }
}

/**
 * A title bar: the gold double rails on either side of the name in white, the menu's gold squiggle (the main window's),
 * and the minimize, shade and close buttons (for the look: the app's own buttons do those things).
 */
private fun DrawScope.titleBar(title: String, u: Float, playlist: Boolean, measurer: androidx.compose.ui.text.TextMeasurer) {
    val width = size.width / u
    val top = if (playlist) 5f else 4f
    val textWidth = title.length * (if (playlist) 6.4f else 7.2f) + 10
    val left = if (playlist) 7f else 20f
    val right = width - if (playlist) 20f else 34f
    listOf(left to width / 2 - textWidth / 2, width / 2 + textWidth / 2 to right).forEach { (from, to) ->
        if (to - from <= 4) return@forEach
        px(from, top, to - from, 7f, Color(0xFF1E1F25), u)
        listOf(Pc.goldLight, Color.White, Pc.goldDark, Pc.goldDim, Pc.goldLight, Color(0xFF25262C)).forEachIndexed { i, c ->
            px(from + 1, top + 1 + i, to - from - 2, 1f, c, u)
        }
        listOf(from + 1, to - 2).forEach { x -> px(x, top + 1, 1f, 1f, Pc.goldDim, u); px(x, top + 5, 1f, 1f, Color(0xFF736C52), u) }
    }
    if (!playlist) listOf(8 to 7, 9 to 6, 9 to 5, 10 to 4, 11 to 5, 11 to 6, 12 to 7, 13 to 8, 13 to 9, 14 to 10, 15 to 9, 15 to 8, 16 to 7)
        .forEach { (x, y) -> px(x.toFloat(), y.toFloat(), 1f, 1f, Color(0xFFEFBE66), u) }
    val buttons = if (playlist) listOf(width - 20, width - 11) else listOf(width - 31, width - 21, width - 11)
    val y = if (playlist) 4f else 3f
    buttons.forEachIndexed { index, x ->
        if (index < buttons.size - 1) {
            px(x + 2, y, 5f, 1f, Color(0xFFB3B6B8), u)
            px(x + 1, y + 1, 7f, 1f, Color(0xFFCEE2D1), u)
            px(x, y + 2, 9f, 4f, Color(0xFF6B5D43), u)
            px(x, y + 5, 9f, 2f, Color(0xFF5A573A), u)
            px(x + 1, y + 7, 7f, 1f, Pc.goldDark, u)
        } else {
            val ring = Color(0xFF352D10)
            px(x + 2, y, 5f, 1f, ring, u); px(x, y + 2, 1f, 5f, ring, u); px(x + 8, y + 2, 1f, 5f, ring, u); px(x + 2, y + 8, 5f, 1f, ring, u)
            repeat(7) { step -> px(x + 1 + step, y + 1 + step, 1f, 1f, Color(0xFFB69C54), u); px(x + 7 - step, y + 1 + step, 1f, 1f, Color(0xFFB69C54), u) }
            px(x + 4, y + 4, 1f, 1f, Color.White, u)
        }
    }
    val text = measurer.measure(title, TextStyle(fontWeight = FontWeight.Black, fontSize = ((if (playlist) 7f else 8.5f) * u).toSp(), color = Color.White,
        letterSpacing = (0.4f * u).toSp(), shadow = androidx.compose.ui.graphics.Shadow(Color.Black.copy(alpha = 0.8f), Offset(u * 0.5f, u * 0.5f), 0f)))
    drawText(text, topLeft = Offset(size.width / 2 - text.size.width / 2, (if (playlist) 8.5f else 7.5f) * u - text.size.height / 2))
}

/** A key's face as the base skin draws it: pale blue-gray with a white highlight; held, it sinks dark and black-edged. */
private fun DrawScope.keyFace(rect: Rect, u: Float, down: Boolean) {
    val x = rect.left / u
    val y = rect.top / u
    val w = rect.width / u
    val h = rect.height / u
    if (down) {
        px(x, y, w, h, Color(0xFF080810), u)
        px(x + 1, y + 1, w - 2, h - 2, Color(0xFF7B8C9C), u)
        px(x + 2, y + 2, w - 4, 1f, Color(0xFFADBDC6), u)
        px(x + 2, y + 2, 1f, h - 4, Color(0xFFADBDC6), u)
    } else {
        px(x, y, w, h, Pc.keyFace, u)
        px(x, y, w, 1f, Pc.keyEdge, u); px(x, y, 1f, h, Pc.keyEdge, u)
        px(x + 1, y + 1, w - 2, 1f, Pc.keyLight, u); px(x + 1, y + 1, 1f, h - 2, Pc.keyLight, u)
        px(x + 2, y + h - 3, w - 4, 1f, Pc.keyEdge, u); px(x + w - 3, y + 2, 1f, h - 4, Pc.keyEdge, u)
        px(x + 1, y + h - 2, w - 2, 1f, Pc.keyShade, u); px(x + w - 2, y + 1, 1f, h - 2, Pc.keyShade, u)
        px(x, y + h - 1, w, 1f, Pc.keyDark, u); px(x + w - 1, y, 1f, h, Pc.keyDark, u)
    }
}

/** A key: its face (sunk while [down]) and what is on it, moved a pixel when held. */
private fun DrawScope.key(rect: Rect, u: Float, down: Boolean, content: DrawScope.(Rect) -> Unit) {
    keyFace(rect, u, down)
    content(if (down) rect.translate(u, u) else rect)
}

/** A glyph engraved in a key: shaded on its upper and left edges, lit on its lower and right ones, gray within. */
private fun DrawScope.glyph(kind: Glyph, center: Offset, w: Float, h: Float, u: Float, alpha: Float = 1f) {
    val rect = Rect(Offset((center.x / u - w / 2).roundToInt() * u, (center.y / u - h / 2).roundToInt() * u), Size(w * u, h * u))
    val path = glyphPath(kind, rect)
    val shifted = Path().apply { addPath(path, Offset(u, u)) }
    drawPath(shifted, Pc.keyLight.copy(alpha = alpha))
    drawPath(path, Pc.keyDark.copy(alpha = alpha))
    clipPath(shifted) { drawPath(path, Pc.glyph.copy(alpha = alpha)) }
}

/** A key's small light: green when on, its edge shaded above and lit below. */
private fun DrawScope.led(x: Float, y: Float, u: Float, on: Boolean) {
    px(x, y, 5f, 1f, Pc.keyDark, u); px(x, y, 1f, 4f, Pc.keyDark, u)
    px(x + 1, y + 1, 3f, 2f, if (on) Color(0xFF00D600) else Color(0xFF8C9AA8), u)
    px(x + 1, y + 3, 4f, 1f, Color(0xFFD5DEF2), u); px(x + 4, y + 1, 1f, 3f, Color(0xFFD5DEF2), u)
}

/** The gold thumb of the position bar (and, upright, of the playlist's scroll bar): cream ridges, a dark edge. */
private fun DrawScope.goldThumb(rect: Rect, u: Float, upright: Boolean = false) {
    val rows = listOf(0xFFDBCB9E, 0xFF836930, 0xFFF4EAC7, 0xFFF5F5F5, 0xFF755B22, 0xFFAF9861, 0xFFF4EAC7, 0xFFAF9861, 0xFF8D753A, 0xFF090202)
    val x = rect.left / u
    val y = rect.top / u
    val w = rect.width / u
    val h = rect.height / u
    if (upright) {
        rows.forEachIndexed { i, c -> px(x + i * w / rows.size, y, w / rows.size + 0.05f, h, Color(c), u) }
        px(x, y, w - 1, 1f, Color(0xFFDBCB9E), u); px(x + 1, y + 1, w - 2, 1f, Color(0xFF836930), u)
        px(x + 1, y + h - 2, w - 1, 1f, Color(0xFF8D753A), u); px(x, y + h - 1, w, 1f, Color(0xFF090202), u)
    } else {
        rows.forEachIndexed { i, c -> px(x, y + i * h / rows.size, w, h / rows.size + 0.05f, Color(c), u) }
        px(x, y, 1f, h - 1, Color(0xFFDBCB9E), u); px(x + 1, y + 1, 1f, h - 2, Color(0xFF836930), u)
        px(x + w - 2, y + 1, 1f, h - 1, Color(0xFF8D753A), u); px(x + w - 1, y, 1f, h, Color(0xFF090202), u)
    }
}

internal enum class Glyph { PREVIOUS, PLAY, PAUSE, STOP, NEXT, EJECT }

internal fun glyphPath(kind: Glyph, rect: Rect): Path = Path().apply {
    val w = rect.width
    val h = rect.height
    fun triangle(x: Float, right: Boolean, width: Float) {
        moveTo(rect.left + x + if (right) 0f else width, rect.top)
        lineTo(rect.left + x + if (right) width else 0f, rect.center.y)
        lineTo(rect.left + x + if (right) 0f else width, rect.bottom)
        close()
    }
    when (kind) {
        Glyph.PREVIOUS -> { addRect(Rect(rect.left, rect.top, rect.left + w * 0.2f, rect.bottom)); triangle(w * 0.3f, false, w * 0.7f) }
        Glyph.PLAY -> triangle(w * 0.15f, true, w * 0.75f)
        Glyph.PAUSE -> {
            addRect(Rect(rect.left + w * 0.12f, rect.top, rect.left + w * 0.42f, rect.bottom))
            addRect(Rect(rect.left + w * 0.58f, rect.top, rect.left + w * 0.88f, rect.bottom))
        }
        Glyph.STOP -> addRect(Rect(rect.left + w * 0.08f, rect.top + h * 0.04f, rect.right - w * 0.08f, rect.bottom - h * 0.04f))
        Glyph.NEXT -> { triangle(0f, true, w * 0.7f); addRect(Rect(rect.left + w * 0.8f, rect.top, rect.right, rect.bottom)) }
        Glyph.EJECT -> {
            moveTo(rect.center.x, rect.top); lineTo(rect.right, rect.top + h * 0.6f); lineTo(rect.left, rect.top + h * 0.6f); close()
            addRect(Rect(rect.left, rect.top + h * 0.78f, rect.right, rect.bottom))
        }
    }
}

/** A key's place and what it does, for the taps over the drawn window. */
private class PcKey(val id: String, val title: String, val rect: Rect, val enabled: Boolean = true, val state: String? = null, val tap: () -> Unit)

@Composable
private fun PcMainWindow(u: Float, song: DeckSong, actions: DeckActions, showsPlaylist: Boolean, togglePlaylist: () -> Unit) {
    val measurer = rememberTextMeasurer()
    val haptics = LocalHapticFeedback.current
    var pressed by remember { mutableStateOf<String?>(null) }
    var remaining by remember { mutableStateOf(false) }
    var position by remember { mutableStateOf<Float?>(null) }
    val spectrum = remember { PcSpectrumState() }
    val analyzer = remember { Spectrum() }
    val frame = remember { mutableLongStateOf(0L) }
    if (song.heardHere) DisposableEffect(Unit) {
        AudioTap.start()
        onDispose { AudioTap.stop() }
    }
    LaunchedEffect(song.playing) {
        while (song.playing || !spectrum.isQuiet) withFrameNanos { now ->
            if (song.heardHere) analyzer.update()
            frame.longValue = now
        }
    }
    val current by rememberUpdatedState(actions)
    val clock = song.clock
    fun stop() {
        if (song.playing) current.playPause()
        current.seek(0.0)
    }
    val keys = listOf(
        PcKey("prev", "Previous", r(16f, 88f, 23f, 18f, u)) { current.previous() },
        PcKey("play", "Play", r(39f, 88f, 23f, 18f, u)) { if (song.playing) current.seek(0.0) else current.playPause() },
        PcKey("pause", "Pause", r(62f, 88f, 23f, 18f, u)) { if (song.playing || clock.value > 0.5) current.playPause() },
        PcKey("stop", "Stop", r(85f, 88f, 23f, 18f, u)) { stop() },
        PcKey("next", "Next", r(108f, 88f, 22f, 18f, u)) { current.next() },
        PcKey("eject", "Close Now Playing", r(136f, 89f, 22f, 16f, u), enabled = actions.eject != null) { current.eject?.invoke() },
        PcKey("shuffle", "Shuffle", r(164f, 89f, 46f, 15f, u), state = if (actions.shuffled) "On" else "Off") { current.toggleShuffle() },
        PcKey("repeat", "Repeat", r(210f, 89f, 28f, 15f, u), state = actions.repeat.name.lowercase()) { current.cycleRepeat() },
        PcKey("eq", "Equalizer", r(219f, 58f, 23f, 12f, u), enabled = actions.equalizer != null,
            state = if (actions.equalizer == true) "On" else "Off") { current.toggleEqualizer() },
        PcKey("pl", "Playlist", r(242f, 58f, 23f, 12f, u), state = if (showsPlaylist) "On" else "Off") { togglePlaylist() },
        PcKey("love", if (actions.loved == true) "Unlove" else "Love", r(239f, 89f, 15f, 15f, u), enabled = actions.loved != null) { current.toggleLove() },
    )
    Box(Modifier.fillMaxSize().clipToBounds()) {
        Canvas(Modifier.fillMaxSize()) {
            val now = frame.longValue
            // The window: its face, its edges and the groove within them; the display's black panel, the title's, the
            // bit rate's and sample rate's, and the position bar's groove.
            windowFace(0.57f..0.73f)
            px(0f, 0f, 275f, 1f, Color(0xFF26263B), u); px(0f, 0f, 1f, 116f, Color(0xFF0F0F17), u)
            px(1f, 1f, 273f, 1f, Pc.frameLight, u); px(1f, 1f, 1f, 114f, Color(0xFF5C5C63), u)
            px(0f, 115f, 275f, 1f, Color(0xFF28273E), u); px(274f, 0f, 1f, 116f, Color(0xFF1E1E2F), u)
            px(4f, 12f, 267f, 2f, Color(0xFF101019), u); px(4f, 12f, 2f, 100f, Color(0xFF101019), u)
            px(6f, 14f, 263f, 1f, Pc.frameLight, u); px(6f, 14f, 1f, 98f, Color(0xFF5F5F68), u)
            px(4f, 110f, 267f, 2f, Color(0xFF101019), u); px(4f, 112f, 267f, 1f, Pc.frameLight, u)
            px(267f, 12f, 2f, 100f, Color(0xFF101019), u); px(269f, 12f, 1f, 101f, Pc.frameLight, u)
            px(11f, 22f, 93f, 43f, Color.Black, u)
            for (y in 24 until 64 step 2) for (x in 24 until 102 step 2) px(x.toFloat(), y.toFloat(), 1f, 1f, Pc.dots, u)
            for (y in 43 until 61 step 2) px(23f, y.toFloat(), 1f, 1f, Color(0xFF3E6AB2), u)
            for (x in 24 until 101 step 2) px(x.toFloat(), 61f, 1f, 1f, Color(0xFF3E6AB2), u)
            groove(10f, 21f, 95f, 45f, u, light = Color(0xFF5F5F68))
            listOf(listOf(111f, 24f, 154f, 12f), listOf(111f, 43f, 15f, 8f), listOf(156f, 43f, 10f, 8f)).forEach { (x, y, w, h) ->
                px(x, y, w, h, Color.Black, u)
                groove(x - 1, y - 1, w + 2, h + 2, u, light = Color(0xFF5F5F68))
            }
            px(16f, 72f, 248f, 12f, Color(0xFF1C1B2B), u); px(16f, 72f, 248f, 2f, Color(0xFF11111B), u); px(16f, 72f, 2f, 12f, Color(0xFF11111B), u)
            px(16f, 83f, 248f, 1f, Color(0xFF656572), u); px(263f, 72f, 1f, 12f, Color(0xFF656572), u)
            titleBar("GROOVELIGHT", u, false, measurer)
            // The clutter bar's letters, the play state, the time and the spectrum.
            listOf("O", "A", "I", "D", "V").forEachIndexed { i, letter ->
                val text = measurer.measure(letter, TextStyle(fontFamily = pixelFont, fontSize = (6 * u).toSp(), color = Color(0xFF6A6A80)))
                drawText(text, topLeft = Offset(15 * u - text.size.width / 2, (24 + i * 8f) * u))
            }
            val time = clock.value
            val paused = !song.playing && time > 0.5
            val state = r(25f, 28f, 9f, 9f, u)
            drawPath(glyphPath(if (song.playing) Glyph.PLAY else if (paused) Glyph.PAUSE else Glyph.STOP,
                if (song.playing) state.deflate(u * 0.5f) else state.deflate(u * 1.5f)), Color(0xFF00E800))
            val shown = if (remaining) max(song.duration - time, 0.0) else time
            val blink = paused && (System.currentTimeMillis() / 500) % 2 == 0L
            val lit = Pc.digits.copy(alpha = if (blink) 0.1f else 1f)
            val digits = measurer.measure(clockText(shown), TextStyle(fontFamily = dsegDigits, fontSize = (13 * u).toSp(), color = lit))
            drawText(digits, topLeft = Offset(102 * u - digits.size.width, 32.5f * u - digits.size.height / 2))
            if (remaining) drawRect(lit, Offset(36 * u, 32 * u), Size(5 * u, 1.5f * u))
            val target = if (!song.playing) DoubleArray(PcSpectrumState.BARS) else if (song.heardHere && analyzer.live) {
                DoubleArray(PcSpectrumState.BARS) { i ->
                    val from = i * Spectrum.BANDS / PcSpectrumState.BARS
                    val to = max((i + 1) * Spectrum.BANDS / PcSpectrumState.BARS, from + 1)
                    (from until to).maxOf { analyzer.bands[it] }.toDouble().coerceAtMost(1.0)
                }
            } else PcSpectrumState.madeUp(time)
            val (bars, peaks) = spectrum.update(target, now)
            for (i in 0 until PcSpectrumState.BARS) {
                val x = 24f + i * 4
                val height = (16 * bars[i]).roundToInt()
                // Each row its color: a bar's foot green, its top as far up the colors as it reaches.
                for (row in 0 until height) px(x, 58f - row, 3f, 1f, Pc.spectrum[max(0, Pc.spectrum.size - 1 - row)], u)
                val peak = (16 * peaks[i]).roundToInt()
                if (peak > 0) px(x, 59f - peak, 3f, 1f, Pc.peak, u)
            }
            // The scrolling title.
            val marquee = r(111f, 24f, 154f, 12f, u)
            val name = listOf(song.artist, song.title).filter { it.isNotBlank() }.joinToString(" - ")
            val line = "$name (${clockText(song.duration).removePrefix("0")})".uppercase()
            val style = TextStyle(fontFamily = pixelFont, fontSize = (7.5f * u).toSp(), color = Pc.text)
            val measured = measurer.measure(line, style)
            clipRect(marquee.left, marquee.top, marquee.right, marquee.bottom) {
                val y = marquee.center.y - measured.size.height / 2
                if (measured.size.width <= marquee.width - 4 * u) {
                    drawText(measured, topLeft = Offset(marquee.left + 2 * u, y))
                } else {
                    val gap = measurer.measure("  ***  ", style)
                    val loop = measured.size.width + gap.size.width
                    val pixels = ((System.nanoTime() / 1e9 * 24).toLong() * u) % loop
                    var x = marquee.left + 2 * u - pixels
                    while (x < marquee.right) {
                        drawText(measured, topLeft = Offset(x, y))
                        drawText(gap, topLeft = Offset(x + measured.size.width, y))
                        x += loop
                    }
                }
            }
            // The bit rate, the sample rate, mono and stereo.
            val small = TextStyle(fontFamily = pixelFont, fontSize = (6 * u).toSp())
            val bold = small.copy(fontWeight = FontWeight.Bold)
            fun info(text: String, x: Float, w: Float) {
                val t = measurer.measure(text, small.copy(color = Pc.text))
                drawText(t, topLeft = Offset((x + w / 2) * u - t.size.width / 2f, 47 * u - t.size.height / 2f))
            }
            fun label(text: String, x: Float, color: Color) {
                val t = measurer.measure(text, bold.copy(color = color))
                drawText(t, topLeft = Offset(x * u, 47 * u - t.size.height / 2))
            }
            info(song.format?.kbps?.toString() ?: "", 111f, 15f)
            label("kbps", 128f, Color.White)
            info(song.format?.kHz?.toString() ?: "", 156f, 10f)
            label("kHz", 168f, Color.White)
            val channels = song.format?.channels
            label("mono", 212f, if (channels == 1) Pc.text else Color(0xFF4C4C66))
            label("stereo", 238f, if (channels == null || channels >= 2) Pc.text else Color(0xFF4C4C66))
            // Volume and balance.
            slider(107f, 57f, 68f, u, actions.volume ?: 1f, volume = true)
            slider(177f, 57f, 38f, u, 0.5f, volume = false)
            // The position bar's thumb.
            if (song.duration > 0) {
                val x = 16f + ((248f - 29f) * (position ?: song.progress)).roundToInt()
                goldThumb(r(x, 72f, 29f, 10f, u), u)
            }
            // The keys.
            val keyText = TextStyle(fontFamily = pixelFont, fontWeight = FontWeight.Bold, fontSize = (6 * u).toSp(), color = Pc.ink)
            keys.forEach { k ->
                val down = pressed == k.id
                val alpha = if (k.enabled) 1f else 0.45f
                when (k.id) {
                    "prev" -> key(k.rect, u, down) { glyph(Glyph.PREVIOUS, it.center, 9f, 8f, u) }
                    "play" -> key(k.rect, u, down) { glyph(Glyph.PLAY, it.center, 8f, 9f, u) }
                    "pause" -> key(k.rect, u, down) { glyph(Glyph.PAUSE, it.center, 8f, 9f, u) }
                    "stop" -> key(k.rect, u, down) { glyph(Glyph.STOP, it.center, 9f, 9f, u) }
                    "next" -> key(k.rect, u, down) { glyph(Glyph.NEXT, it.center, 9f, 8f, u) }
                    "eject" -> key(k.rect, u, down) { glyph(Glyph.EJECT, it.center, 10f, 8f, u, alpha) }
                    "shuffle" -> key(k.rect, u, down) {
                        led(it.left / u + 4, it.center.y / u - 2, u, actions.shuffled)
                        val t = measurer.measure("SHUFFLE", keyText)
                        drawText(t, topLeft = Offset(it.left + 11.5f * u, it.center.y - t.size.height / 2))
                    }
                    "repeat" -> key(k.rect, u, down) {
                        led(it.left / u + 4, it.center.y / u - 2, u, actions.repeat != DeckRepeat.OFF)
                        // A loop of arrows (with a 1 for one song).
                        val c = Offset(it.left + 18 * u, it.center.y)
                        drawRoundRect(Pc.ink, c - Offset(5 * u, 3 * u), Size(10 * u, 6 * u), androidx.compose.ui.geometry.CornerRadius(2 * u), style = Stroke(u * 1.2f))
                        drawPath(Path().apply { moveTo(c.x + 1 * u, c.y - 5 * u); lineTo(c.x + 3.5f * u, c.y - 3 * u); lineTo(c.x + 1 * u, c.y - 1 * u); close() }, Pc.ink)
                        if (actions.repeat == DeckRepeat.ONE) {
                            val t = measurer.measure("1", TextStyle(fontFamily = pixelFont, fontSize = (5 * u).toSp(), color = Pc.ink))
                            drawText(t, topLeft = c - Offset(t.size.width / 2f, t.size.height / 2f))
                        }
                    }
                    "love" -> key(k.rect, u, down) { heart(it.center, u, actions.loved == true, k.enabled) }
                    "eq", "pl" -> key(k.rect, u, down) {
                        led(it.left / u + 3, it.center.y / u - 2, u, if (k.id == "eq") actions.equalizer == true else showsPlaylist)
                        val t = measurer.measure(k.id.uppercase(), keyText.copy(color = Pc.ink.copy(alpha = alpha)))
                        drawText(t, topLeft = Offset(it.left + 10 * u, it.center.y - t.size.height / 2))
                    }
                }
            }
            drawLogo(r(252f, 89f, 16f, 17f, u), u)
        }
        // The taps: the keys, the time (elapsed or remaining), the volume and the position.
        keys.forEach { k ->
            Box(Modifier.pc(k.rect.left / u, k.rect.top / u, k.rect.width / u, k.rect.height / u, u)
                .semantics {
                    contentDescription = k.title
                    role = Role.Button
                    k.state?.let { stateDescription = it }
                    onClick { if (k.enabled) k.tap(); true }
                }
                .pointerInput(k.id, k.enabled) {
                    detectTapGestures(onPress = {
                        if (!k.enabled) return@detectTapGestures
                        pressed = k.id
                        haptics.performHapticFeedback(HapticFeedbackType.TextHandleMove)
                        tryAwaitRelease()
                        pressed = null
                    }, onTap = { if (k.enabled) k.tap() })
                })
        }
        Box(Modifier.pc(34f, 25f, 68f, 15f, u).clickable { remaining = !remaining }.semantics { contentDescription = if (remaining) "Time remaining" else "Time" })
        if (actions.volume != null) Box(Modifier.pc(107f, 57f, 68f, 13f, u).semantics { contentDescription = "Volume" }.pointerInput(Unit) {
            awaitEachGesture {
                val down = awaitFirstDown()
                fun set(x: Float) = current.onVolume(((x - 7 * u) / (size.width - 14 * u)).coerceIn(0f, 1f))
                set(down.position.x)
                while (true) {
                    val change = awaitPointerEvent().changes.firstOrNull() ?: break
                    if (!change.pressed) break
                    change.consume()
                    set(change.position.x)
                }
            }
        })
        Box(Modifier.pc(16f, 72f, 248f, 10f, u).semantics { contentDescription = "Position" }.pointerInput(Unit) {
            awaitEachGesture {
                val down = awaitFirstDown()
                down.consume()
                fun at(x: Float) = ((x - 14.5f * u) / (size.width - 29 * u)).coerceIn(0f, 1f)
                position = at(down.position.x)
                while (true) {
                    val change = awaitPointerEvent().changes.firstOrNull() ?: break
                    if (!change.pressed) break
                    change.consume()
                    position = at(change.position.x)
                }
                position?.let { if (song.duration > 0) current.seek(it.coerceAtMost(0.995f) * song.duration) }
                position = null
            }
        })
    }
}

/** The base skin's volume colors, from its quietest to its loudest. */
private val volumeStops = listOf(0f to 0xFF18920B, 0.15f to 0xFF7ADA30, 0.33f to 0xFFBDE238, 0.52f to 0xFFE0DA30, 0.67f to 0xFFE0B228,
    0.85f to 0xFFE0721E, 1f to 0xFFE00E15)

private fun volumeColor(level: Float): Color {
    val upper = volumeStops.indexOfFirst { it.first >= level }.let { if (it < 0) volumeStops.lastIndex else it }
    if (upper == 0) return Color(volumeStops[0].second)
    val (a, b) = volumeStops[upper - 1] to volumeStops[upper]
    return androidx.compose.ui.graphics.lerp(Color(a.second), Color(b.second), (level - a.first) / (b.first - a.first))
}

/**
 * The volume or balance slider at ([x], [y]), [w] wide: a slim groove colored by its level (the balance green in the
 * middle), and the silver thumb with its three grip lines.
 */
private fun DrawScope.slider(x: Float, y: Float, w: Float, u: Float, value: Float, volume: Boolean) {
    val level = value.coerceIn(0f, 1f)
    val color = volumeColor(if (volume) level else kotlin.math.abs(level - 0.5f) * 2)
    px(x, y + 3, w, 1f, Color(0xFF161623), u)
    px(x, y + 4, w, 1f, androidx.compose.ui.graphics.lerp(color, Color.Black, 0.25f), u)
    px(x, y + 5, w, 1f, androidx.compose.ui.graphics.lerp(color, Color.Black, 0.12f), u)
    px(x, y + 6, w, 1f, color, u)
    px(x, y + 7, w, 1f, androidx.compose.ui.graphics.lerp(color, Color.White, 0.08f), u)
    px(x, y + 8, w, 1f, Color(0xFF7D7C90), u)
    px(x, y + 3, 1f, 6f, Color(0xFF1F1F31), u)
    val t = x + ((w - 14) * level).roundToInt()
    px(t, y, 14f, 11f, Color(0xFF0B0F16), u)
    px(t + 1, y + 1, 12f, 1f, Color(0xFFDAE7EA), u); px(t + 1, y + 1, 1f, 8f, Color(0xFFDAE7EA), u)
    px(t + 2, y + 2, 9f, 6f, Color(0xFFADBCC4), u)
    px(t + 11, y + 2, 1f, 7f, Pc.keyShade, u); px(t + 2, y + 8, 10f, 1f, Pc.keyShade, u)
    px(t + 1, y + 9, 12f, 1f, Pc.keyDark, u); px(t + 12, y + 2, 1f, 8f, Pc.keyDark, u)
    listOf(4f, 6f, 8f).forEach { px(t + it, y + 3, 1f, 4f, Color(0xFF0B0F16), u) }
}

/** A heart: filled red when the song is loved, outlined otherwise. */
private fun DrawScope.heart(center: Offset, u: Float, loved: Boolean, enabled: Boolean) {
    val s = 3.6f * u
    val path = Path().apply {
        moveTo(center.x, center.y + s * 1.1f)
        cubicTo(center.x - s * 2.2f, center.y - s * 0.2f, center.x - s * 1.1f, center.y - s * 1.8f, center.x, center.y - s * 0.6f)
        cubicTo(center.x + s * 1.1f, center.y - s * 1.8f, center.x + s * 2.2f, center.y - s * 0.2f, center.x, center.y + s * 1.1f)
        close()
    }
    if (loved) drawPath(path, Color(0xFFDB1A33))
    drawPath(path, Pc.ink.copy(alpha = if (enabled) 1f else 0.4f), style = Stroke(max(1f, u * 1.1f)))
}

/**
 * Groovelight's mark in the corner, as the classic skin frames its own: a tilted tile with a silver edge, filled with the
 * app icon's blue, and the icon's two beamed notes in gold standing in front of it.
 */
private fun DrawScope.drawLogo(rect: Rect, u: Float) {
    val side = min(rect.width, rect.height)
    val tile = Rect(Offset(rect.center.x - side * 0.35f, rect.center.y - side * 0.35f), Size(side * 0.7f, side * 0.7f))
    rotate(45f, rect.center) {
        drawRoundRect(Color.Black.copy(alpha = 0.5f), tile.topLeft + Offset(u * 0.7f, 0f), tile.size, androidx.compose.ui.geometry.CornerRadius(side * 0.12f))
        drawRoundRect(Color(0xFF484848), tile.topLeft, tile.size, androidx.compose.ui.geometry.CornerRadius(side * 0.12f))
        val silver = tile.deflate(u * 0.8f)
        drawRoundRect(Brush.linearGradient(listOf(Color(0xFFE4E6EA), Color(0xFF8F9196)), silver.topLeft, silver.bottomRight), silver.topLeft, silver.size,
            androidx.compose.ui.geometry.CornerRadius(side * 0.1f))
        val face = tile.deflate(u * 1.8f)
        drawRoundRect(Brush.linearGradient(listOf(Color(0xFF2A4CA0), Color(0xFF09143B)), face.topLeft, face.bottomRight), face.topLeft, face.size,
            androidx.compose.ui.geometry.CornerRadius(side * 0.07f))
    }
    // The notes, upright and inside the tile.
    val box = Rect(rect.left + rect.width * 0.3f, rect.top + rect.height * 0.29f, rect.left + rect.width * 0.72f, rect.top + rect.height * 0.71f)
    val notes = notesPath(box)
    drawPath(Path().apply { addPath(notes, Offset(u * 0.5f, u * 0.5f)) }, Color.Black.copy(alpha = 0.6f))
    drawPath(notes, Brush.linearGradient(listOf(Color(0xFFFFE9A0), Color(0xFFE0B44A), Color(0xFFB07A22)), box.topLeft, box.bottomRight))
}

/** The app icon's notes (its 1024-point drawing: two beamed sixteenths) fitted in [rect]. */
internal fun notesPath(rect: Rect): Path {
    val box = Rect(250f, 66f, 820f, 776f)
    val fit = min(rect.width / box.width, rect.height / box.height)
    val ox = rect.center.x - box.width * fit / 2
    val oy = rect.center.y - box.height * fit / 2
    fun p(x: Float, y: Float) = Offset(ox + (x - box.left) * fit, oy + (y - box.top) * fit)
    return Path().apply {
        listOf(370f to 690f, 690f to 610f).forEach { (cx, cy) ->
            // A note head: an ellipse 224 by 160, tilted 20 degrees.
            val steps = 24
            for (i in 0..steps) {
                val a = 2 * PI * i / steps
                val ex = 112 * kotlin.math.cos(a)
                val ey = 80 * sin(a)
                val t = -20 * PI / 180
                val q = p((cx + ex * kotlin.math.cos(t) - ey * sin(t)).toFloat(), (cy + ex * sin(t) + ey * kotlin.math.cos(t)).toFloat())
                if (i == 0) moveTo(q.x, q.y) else lineTo(q.x, q.y)
            }
            close()
        }
        listOf(441f to 161f, 778f to 81f).forEach { (x, y) ->
            val a = p(x, y)
            val b = p(x + 34, y + 509)
            addRect(Rect(a, b))
        }
        listOf(151f to 223f, 261f to 333f).forEach { (top, bottom) ->
            val a = p(441f, top); val b = p(812f, top - 80); val c = p(812f, bottom - 80); val d = p(441f, bottom)
            moveTo(a.x, a.y); lineTo(b.x, b.y); lineTo(c.x, c.y); lineTo(d.x, d.y); close()
        }
    }
}

/** The spectrum's nineteen bars falling at their pace, their peaks held a moment, then falling. */
internal class PcSpectrumState {
    private val levels = DoubleArray(BARS)
    private val peaks = DoubleArray(BARS)
    private val held = DoubleArray(BARS)
    private var last = 0L

    val isQuiet: Boolean get() = levels.all { it < 0.01 } && peaks.all { it < 0.01 }

    fun update(target: DoubleArray, now: Long): Pair<DoubleArray, DoubleArray> {
        val elapsed = if (last == 0L) 0.0 else ((now - last) / 1e9).coerceIn(0.0, 0.25)
        last = now
        for (i in 0 until BARS) {
            val goal = target.getOrElse(i) { 0.0 }
            levels[i] = if (goal > levels[i]) goal else max(goal, levels[i] - elapsed * 2)
            if (levels[i] >= peaks[i]) { peaks[i] = levels[i]; held[i] = 0.4 }
            else if (held[i] > 0) held[i] -= elapsed
            else peaks[i] = max(levels[i], peaks[i] - elapsed * 0.8)
        }
        return levels to peaks
    }

    companion object {
        const val BARS = 19

        /** A made-up dance, for music not heard here. */
        fun madeUp(time: Double) = DoubleArray(BARS) { index ->
            val i = index.toDouble()
            val tilt = 1 - i / BARS * 0.55
            val swing = 0.5 + 0.25 * sin(time * (3.1 + i * 0.37) + i) + 0.2 * sin(time * (7.3 + i * 0.21) + i * 2.1)
            val beat = max(sin(time * 2 * PI * 2.05), 0.0).pow(8) * 0.3 * tilt
            (swing * tilt + beat).coerceIn(0.02, 1.0)
        }
    }
}

@Composable
private fun PcPlaylistWindow(u: Float, song: DeckSong, actions: DeckActions, playlist: PlayerModel.Playlist?, onPlay: ((Int) -> Unit)?,
                             overlay: (@Composable () -> Unit)?) {
    val measurer = rememberTextMeasurer()
    val list = rememberLazyListState()
    val entries = playlist?.entries?.takeIf { it.isNotEmpty() }
        ?: listOf(PlayerModel.PlaylistEntry(song.title, song.artist, (song.duration * 1000).toLong()))
    val current = if (playlist?.entries.isNullOrEmpty()) 0 else playlist?.current
    LaunchedEffect(current) { current?.let { list.animateScrollToItem((it - 3).coerceAtLeast(0)) } }
    BoxWithConstraints(Modifier.fillMaxSize().clipToBounds()) {
        val w = constraints.maxWidth / u
        val h = constraints.maxHeight / u
        val wi = kotlin.math.floor(w)
        val hi = kotlin.math.floor(h)
        Canvas(Modifier.fillMaxSize()) {
            windowFace()
            // The frame's edges and its engraved inner lines, down the sides and across the foot.
            val dark = Color(0xFF1D1D2D)
            val light = Color(0xFF6A6A7A)
            px(0f, 0f, wi, 1f, dark, u); px(0f, 0f, 1f, hi, dark, u); px(1f, 1f, wi - 2, 1f, light, u); px(1f, 1f, 1f, hi - 2, light, u)
            px(0f, hi - 1, wi, 1f, Color(0xFF0E0E16), u); px(wi - 1, 0f, 1f, hi, Color(0xFF0E0E16), u)
            px(4f, 12f, wi - 8, 2f, dark, u); px(6f, 14f, wi - 12, 1f, Color(0xFF6B6B7C), u)
            px(4f, 12f, 2f, hi - 16, dark, u); px(6f, 14f, 1f, hi - 18, light, u)
            px(wi - 6, 12f, 2f, hi - 16, dark, u); px(wi - 7, 14f, 1f, hi - 18, light, u)
            px(4f, hi - 4, wi - 8, 1f, light, u)
            // The list's black, the scroll bar's groove and gold thumb, the bottom bar's displays and keys.
            px(11f, 20f, wi - 31, hi - 58, Color.Black, u)
            groove(10f, 19f, wi - 29, hi - 56, u, dark, light)
            px(wi - 16, 20f, 8f, hi - 58, Color(0xFF14141F), u)
            val info = list.layoutInfo
            val fraction = if (info.totalItemsCount <= info.visibleItemsInfo.size) 0f
                else list.firstVisibleItemIndex.toFloat() / (info.totalItemsCount - info.visibleItemsInfo.size).coerceAtLeast(1)
            goldThumb(r(wi - 16, 20f + ((hi - 58 - 18) * fraction.coerceIn(0f, 1f)).roundToInt(), 8f, 18f, u), u, upright = true)
            px(wi - 145, hi - 29, 94f, 10f, Color.Black, u)
            groove(wi - 146, hi - 30, 96f, 12f, u, dark, light)
            px(wi - 86, hi - 16, 34f, 8f, Color.Black, u)
            groove(wi - 87, hi - 17, 36f, 10f, u, dark, light)
            for (step in 0 until 4) for (d in 0 until 10 - step * 3) px(wi - 6 - d, hi - 15 + step * 3 + d, 1f, 1f, light, u)
            titleBar("GROOVELIGHT PLAYLIST", u, true, measurer)
            val tiny = TextStyle(fontFamily = pixelFont, fontWeight = FontWeight.Bold, fontSize = (5.5f * u).toSp(), color = Pc.ink)
            listOf("ADD", "REM", "SEL", "MISC").forEachIndexed { i, title ->
                val rect = r(11f + i * 29, hi - 30, 25f, 18f, u)
                keyFace(rect, u, false)
                val t = measurer.measure(title, tiny)
                drawText(t, topLeft = rect.center - Offset(t.size.width / 2f, t.size.height / 2f))
            }
            val total = entries.sumOf { it.durationMs } / 1000.0
            val selected = current?.let { entries.getOrNull(it)?.durationMs?.div(1000.0) } ?: song.duration
            val green = TextStyle(fontFamily = pixelFont, fontSize = (5.5f * u).toSp(), color = Pc.text)
            val lengths = measurer.measure("${shortClock(selected)}/${shortClock(total)}", green)
            drawText(lengths, topLeft = Offset((wi - 98) * u - lengths.size.width / 2, (hi - 24) * u - lengths.size.height / 2))
            listOf(Glyph.PREVIOUS, Glyph.PLAY, Glyph.PAUSE, Glyph.STOP, Glyph.NEXT, Glyph.EJECT).forEachIndexed { i, kind ->
                drawPath(glyphPath(kind, r(wi - 144 + i * 9.3f, hi - 14.5f, 5f, 5f, u)), Color(0xFFE0C070))
            }
            val time = measurer.measure(clockText(song.clock.value), green)
            drawText(time, topLeft = Offset((wi - 69) * u - time.size.width / 2, (hi - 12) * u - time.size.height / 2))
            val opts = r(wi - 47, hi - 30, 25f, 18f, u)
            keyFace(opts, u, false)
            listOf("LIST" to -1, "OPTS" to 1).forEach { (word, line) ->
                val t = measurer.measure(word, tiny)
                drawText(t, topLeft = Offset(opts.center.x - t.size.width / 2, opts.center.y + line * 3.3f * u - t.size.height / 2))
            }
        }
        // The small transport keys.
        val mini = listOf<Pair<String, () -> Unit>>("Previous" to actions.previous, "Play" to { if (!song.playing) actions.playPause() },
            "Pause" to { if (song.playing) actions.playPause() }, "Stop" to { if (song.playing) actions.playPause(); actions.seek(0.0) }, "Next" to actions.next,
            "Close Now Playing" to { actions.eject?.invoke() })
        mini.forEachIndexed { i, (title, tap) ->
            Box(Modifier.pc(wi - 146 + i * 9.3f, hi - 17, 9.3f, 10f, u).semantics { contentDescription = title }.clickable { tap() })
        }
        // The list: green on black, the song playing in white; or the lyrics or Up Next in its place.
        Box(Modifier.pc(11f, 20f, wi - 31, hi - 58, u).padding(1.dp)) {
            if (overlay != null) {
                Box(Modifier.fillMaxSize().padding((6 * u / LocalDensity.current.density).dp)) {
                    CompositionLocalProvider(LocalContentColor provides Color.White) { overlay() }
                }
            } else {
                val density = LocalDensity.current
                LazyColumn(state = list, modifier = Modifier.fillMaxSize()) {
                    itemsIndexed(entries) { index, entry ->
                        val color = if (index == current) Color.White else Pc.listText
                        val style = TextStyle(fontSize = with(density) { (9.5f * u).toSp() }, color = color)
                        Row(Modifier.fillMaxWidth().height(with(density) { (12.5f * u).toDp() })
                            .then(if (onPlay != null) Modifier.clickable { onPlay(index) } else Modifier)
                            .padding(horizontal = with(density) { (3 * u).toDp() }), verticalAlignment = Alignment.CenterVertically) {
                            Text("${index + 1}. " + listOfNotNull(entry.artist?.takeIf { it.isNotBlank() }, entry.title).joinToString(" - "),
                                style = style, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                            Spacer(Modifier.width(with(density) { (4 * u).toDp() }))
                            Text(clockText(entry.durationMs / 1000.0).removePrefix("0"), style = style)
                        }
                    }
                }
            }
        }
    }
}

private fun shortClock(seconds: Double): String {
    val whole = max(seconds, 0.0).toInt()
    return if (whole >= 3600) "%d:%02d:%02d".format(whole / 3600, whole / 60 % 60, whole % 60) else "%d:%02d".format(whole / 60, whole % 60)
}
