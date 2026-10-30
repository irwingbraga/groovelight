package dev.irwingbraga.groovelight.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
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
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.scale
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import dev.irwingbraga.groovelight.playback.AudioTap
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// The PC Player's Corona theme, as on the Mac and the iPhone (GroovelightKit's PCCorona): the glassy blue media player
// of 2002, its main window (a screen in a periwinkle frame) over the transport drawer, the playlist drawer beside or
// under it. Drawn in its own pixels (the main window 346 wide), scaled to the screen.

/** The PC Player's themes: the classic two-window skin, or Corona. */
enum class PcTheme(val label: String) { CLASSIC("Classic"), CORONA("Corona") }

private object Corona {
    val frame = Color(0xFFC0D3EA)
    val frameEdge = Color(0xFFA1B5D5)
    val frameDark = Color(0xFF60647F)
    val tube = listOf(Color(0xFFB7CBEA), Color(0xFF94AAD9), Color(0xFF7D94CC), Color(0xFF6577B9), Color(0xFF505FA6), Color(0xFF44549C))
    val navy = Color(0xFF202852)
    val lit = Color(0xFF2B6CD8)
    val glyph = listOf(Color(0xFF182B3C), Color(0xFF33597C), Color(0xFF4D7BA2))
    val green = Color(0xFF00FF00)
    val seek = listOf(Color(0xFF779C8C), Color(0xFF8EB599), Color(0xFFA0C8A1), Color(0xFFBBDEAE))
    val thumbGreen = listOf(Color(0xFF1CE249), Color(0xFF53D324), Color(0xFF28A949))
    val block = listOf(Color(0xFFA6B9DE), Color(0xFF8AA3CC), Color(0xFF8396BB))
    const val WIDTH = 346f
    /** Around the screen: 26 above it, 19 under it (the metadata strip and the frame), then the drawer (60, one pixel behind). */
    const val CHROME = 26f + 19f + 59f
    const val PLAYLIST_WIDTH = 263f
}

/** Where Corona's parts go and the scale they are drawn at, as on the Mac and the iPhone. */
internal class CoronaLayout(val main: Rect, val playlist: Rect, val scale: Float, val screenHeight: Float) {
    companion object {
        fun of(size: Size, margin: Float, fold: Rect?): CoronaLayout {
            val area = Rect(margin, 0f, size.width - margin, size.height - margin)
            fun screen(height: Float, scale: Float) = (height / scale - Corona.CHROME).coerceIn(120f, 240f)
            if (fold != null && fold.height >= size.height * 0.5f && fold.left > area.left + margin * 8 && fold.right < area.right - margin * 8) {
                val right = Rect(fold.right + margin, area.top, area.right, area.bottom)
                val scale = right.width / Corona.WIDTH
                val sh = screen(right.height, scale)
                return CoronaLayout(Rect(Offset(right.left, right.top), Size(Corona.WIDTH * scale, (sh + Corona.CHROME) * scale)),
                    Rect(area.left, area.top, fold.left - margin, area.bottom), scale, sh)
            }
            if (fold != null && fold.width >= size.width * 0.5f && fold.top > area.top + margin * 8 && fold.bottom < area.bottom - margin * 8) {
                val scale = area.width / Corona.WIDTH
                val sh = screen(fold.top - margin - area.top, scale)
                val main = Rect(Offset(area.left, area.top), Size(area.width, (sh + Corona.CHROME) * scale))
                return CoronaLayout(main, Rect(area.left, fold.bottom + margin, area.right, area.bottom), scale, sh)
            }
            if (area.width >= area.height * 1.25f) {
                // Wide: the playlist slid out on the player's left, as in the original.
                val total = Corona.WIDTH + Corona.PLAYLIST_WIDTH - 13
                val scale = min(area.width / total, area.height / (240 + Corona.CHROME))
                val sh = screen(area.height, scale)
                val left = area.center.x - total * scale / 2
                val main = Rect(Offset(left + (Corona.PLAYLIST_WIDTH - 13) * scale, area.top), Size(Corona.WIDTH * scale, (sh + Corona.CHROME) * scale))
                // From under the top bar down to the window's foot piece, as the original's.
                return CoronaLayout(main, Rect(Offset(left, main.top + 33 * scale), Size(Corona.PLAYLIST_WIDTH * scale, (sh - 3) * scale)), scale, sh)
            }
            // Tall: the playlist under the player, the screen giving it room.
            val scale = area.width / Corona.WIDTH
            val sh = screen(area.height * 0.5f, scale)
            val main = Rect(Offset(area.left, area.top), Size(area.width, (sh + Corona.CHROME) * scale))
            return CoronaLayout(main, Rect(area.left, main.bottom + 4 * scale, area.right, max(area.bottom, main.bottom + 84 * scale)), scale, sh)
        }
    }
}

@Composable
fun CoronaPlayer(song: DeckSong, actions: DeckActions, playlist: PlayerModel.Playlist?, onPlay: ((Int) -> Unit)?, fold: Rect?, cover: File?,
                 overlay: (@Composable () -> Unit)?, modifier: Modifier = Modifier) {
    var showsPlaylist by remember { mutableStateOf(true) }
    val out by androidx.compose.animation.core.animateFloatAsState(if (showsPlaylist) 1f else 0f,
        androidx.compose.animation.core.tween(350), label = "playlist")
    BoxWithConstraints(modifier) {
        val density = LocalDensity.current
        val layout = CoronaLayout.of(Size(constraints.maxWidth.toFloat(), constraints.maxHeight.toFloat()), with(density) { 10.dp.toPx() }, fold)
        val beside = layout.playlist.right <= layout.main.left + 20 * layout.scale
        // On a wide screen (not across a fold) the window sits centered while the playlist is closed; opening it, the
        // window and the drawer slide apart, together centered.
        val shift = if (beside && fold == null) (layout.playlist.width - 13 * layout.scale) / 2 * (1 - out) else 0f
        with(density) {
            // The playlist drawer slides out: from behind the window to its left (as the original), or down from under it.
            Box(Modifier.offset { IntOffset(layout.playlist.left.roundToInt(), layout.playlist.top.roundToInt()) }
                .size(layout.playlist.width.toDp(), layout.playlist.height.toDp()).clipToBounds()) {
                Box(Modifier.fillMaxSize().offset {
                    if (beside) IntOffset(((layout.main.left - layout.playlist.left) * (1 - out) - shift).roundToInt(), 0)
                    else IntOffset(0, (-layout.playlist.height * (1 - out)).roundToInt())
                }.then(if (showsPlaylist) Modifier else Modifier.pointerInput(Unit) { awaitEachGesture { awaitFirstDown().consume() } })) {
                    if (out > 0f) CoronaPlaylist(layout.scale, song, actions, playlist, onPlay, overlay) { showsPlaylist = false }
                }
            }
            Box(Modifier.offset { IntOffset((layout.main.left - shift).roundToInt(), layout.main.top.roundToInt()) }
                .size(layout.main.width.toDp(), layout.main.height.toDp())) {
                CoronaMain(layout.scale, layout.screenHeight, song, actions, cover, showsPlaylist,
                    showsHandle = !(beside && showsPlaylist)) { showsPlaylist = !showsPlaylist }
            }
        }
    }
}

/** A key's place on the skin, what it is called and what it does (tapped, and held: repeating). */
private class CoronaKey(val id: String, val title: String, val rect: Rect, val round: Boolean = true, val enabled: Boolean = true,
                        val state: String? = null, val hold: (() -> Unit)? = null, val tap: () -> Unit)

/** A glossy round key: a silver rim, a pale face lit from above and bluer below; held, it sinks. */
private fun DrawScope.roundKey(rect: Rect, u: Float, pressed: Boolean) {
    val c = rect.center
    val r = rect.width / 2
    drawCircle(Color.Black.copy(alpha = 0.22f), r, c + Offset(0f, u * 0.8f))
    drawCircle(Brush.verticalGradient(listOf(Color(0xFFB0B3BA), Color(0xFF607279)), rect.top, rect.bottom), r, c)
    drawCircle(Brush.verticalGradient(listOf(Color.White, Color(0xFFF6F7FA), Color(0xFFA9ABB0)), rect.top, rect.bottom), r - u * 0.8f, c)
    val inner = r - u * (if (rect.width / u > 26) 3f else 2.2f)
    drawCircle(Brush.verticalGradient(0f to (if (pressed) Color(0xFFB9CBE4) else Color.White), 0.45f to (if (pressed) Color(0xFFA9C0DD) else Color(0xFFD5DCEF)),
        1f to (if (pressed) Color(0xFF9DB8D6) else Color(0xFFC3E0F2)), startY = c.y - inner, endY = c.y + inner), inner, c)
    drawCircle(Color(0xFF5D686F).copy(alpha = 0.55f), inner, c, style = Stroke(max(0.5f, u * 0.6f)))
}

private fun DrawScope.navyGlyph(kind: Glyph, center: Offset, w: Float, h: Float, u: Float, alpha: Float = 1f, mirrored: Boolean = false) {
    val rect = Rect(Offset(center.x - w * u / 2, center.y - h * u / 2), Size(w * u, h * u))
    scale(if (mirrored) -1f else 1f, 1f, center) {
        drawPath(glyphPath(kind, rect), Brush.verticalGradient(Corona.glyph.map { it.copy(alpha = alpha) }, rect.top, rect.bottom))
    }
}

/** A small symbol on a key, in navy (or blue when on). */
private fun DrawScope.keySymbol(id: String, c: Offset, u: Float, on: Boolean, alpha: Float) {
    val color = (if (on) Corona.lit else Corona.navy).copy(alpha = alpha)
    val stroke = Stroke(max(1f, u * 1.1f))
    when (id) {
        "open" -> {
            drawRect(color, c - Offset(3.2f * u, 2f * u), Size(6.4f * u, 4.6f * u), style = stroke)
            drawRect(color, c - Offset(3.2f * u, 3f * u), Size(2.6f * u, 1.2f * u))
        }
        "list" -> repeat(3) { i ->
            drawCircle(color, 0.6f * u, c + Offset(-2.8f * u, (i - 1) * 2f * u))
            drawRect(color, c + Offset(-1.6f * u, (i - 1) * 2f * u - 0.5f * u), Size(4.6f * u, u))
        }
        "vis" -> repeat(4) { i ->
            val a = Math.PI * i / 4
            val d = Offset((kotlin.math.cos(a) * 3.2 * u).toFloat(), (kotlin.math.sin(a) * 3.2 * u).toFloat())
            drawLine(color, c - d, c + d, u * 1.2f)
        }
        "eq" -> listOf(2.2f, 4.2f, 3f).forEachIndexed { i, h -> drawRect(color, Offset(c.x + (i - 1) * 2.2f * u - 0.7f * u, c.y + 2.4f * u - h * u), Size(1.4f * u, h * u)) }
        "shuffle" -> {
            // Two crossing paths with arrowheads on the right.
            drawLine(color, c + Offset(-3.5f * u, -2f * u), c + Offset(2.6f * u, 2f * u), u * 1.1f)
            drawLine(color, c + Offset(-3.5f * u, 2f * u), c + Offset(2.6f * u, -2f * u), u * 1.1f)
            listOf(-2f, 2f).forEach { y ->
                drawPath(Path().apply {
                    moveTo(c.x + 4f * u, c.y + y * u); lineTo(c.x + 1.8f * u, c.y + (y - 1.4f) * u); lineTo(c.x + 1.8f * u, c.y + (y + 1.4f) * u); close()
                }, color)
            }
        }
        "mute" -> {
            drawPath(Path().apply {
                moveTo(c.x - 3.5f * u, c.y - 1.3f * u); lineTo(c.x - 1.8f * u, c.y - 1.3f * u); lineTo(c.x + 0.6f * u, c.y - 3.3f * u)
                lineTo(c.x + 0.6f * u, c.y + 3.3f * u); lineTo(c.x - 1.8f * u, c.y + 1.3f * u); lineTo(c.x - 3.5f * u, c.y + 1.3f * u); close()
            }, Brush.verticalGradient(Corona.glyph.map { it.copy(alpha = alpha) }, c.y - 3.3f * u, c.y + 3.3f * u))
            if (on) {
                drawLine(color, c + Offset(1.8f * u, -1.6f * u), c + Offset(4.2f * u, 1.6f * u), u)
                drawLine(color, c + Offset(1.8f * u, 1.6f * u), c + Offset(4.2f * u, -1.6f * u), u)
            } else drawArc(color, -45f, 90f, false, c + Offset(-1f * u, -2.4f * u), Size(4.8f * u, 4.8f * u), style = Stroke(u))
        }
    }
}

/**
 * The window's blue edge as one bent tube: from behind the frame along the top, around a rounded corner, and down the
 * left side [length] pixels (from its top, 7 down) to a diagonal cut, lit on its outer side and darker on its inner side.
 */
private fun DrawScope.edge(u: Float, length: Float, gap: ClosedFloatingPointRange<Float>? = null) {
    if (gap != null) {
        // The drawer's piece slid out: the window's pieces end flat at the gap.
        clipRect(bottom = gap.start * u) { edge(u, length) }
        clipRect(top = gap.endInclusive * u) { edge(u, length) }
        return
    }
    val thickness = 13f
    val radius = 10f
    val top = 7f
    val bottom = top + length
    fun p(x: Float, y: Float) = Offset(x * u, y * u)
    val outline = Path().apply {
        moveTo(p(radius, top).x, p(radius, top).y)
        // Its top runs on behind the frame.
        lineTo(p(130f, top).x, p(130f, top).y)
        lineTo(p(130f, top + thickness).x, p(130f, top + thickness).y)
        lineTo(p(thickness + 3, top + thickness).x, p(thickness + 3, top + thickness).y)
        quadraticTo(p(thickness, top + thickness).x, p(thickness, top + thickness).y, p(thickness, top + thickness + 3).x, p(thickness, top + thickness + 3).y)
        // The foot: cut on a diagonal, the inner side the longer.
        lineTo(p(thickness, bottom - 2).x, p(thickness, bottom - 2).y)
        quadraticTo(p(thickness, bottom).x, p(thickness, bottom).y, p(thickness - 1.5f, bottom - 0.5f).x, p(thickness - 1.5f, bottom - 0.5f).y)
        lineTo(p(0f, bottom - thickness).x, p(0f, bottom - thickness).y)
        lineTo(p(0f, top + radius).x, p(0f, top + radius).y)
        arcTo(Rect(p(0f, top), Size(radius * 2 * u, radius * 2 * u)), 180f, 90f, false)
        close()
    }
    clipPath(outline) {
        drawPath(outline, Corona.tube.last())
        // Bands from the outer edge in, each following the bend: the light stays outside around the corner.
        val bands = (thickness * u).toInt() * 2
        for (band in 0 until bands) {
            val d = (band + 0.5f) * thickness / bands
            // The tube's colors blended smoothly across its width.
            val position = d / thickness * (Corona.tube.size - 1)
            val lower = min(position.toInt(), Corona.tube.size - 2)
            val color = androidx.compose.ui.graphics.lerp(Corona.tube[lower], Corona.tube[lower + 1], position - lower)
            val line = Path().apply {
                moveTo(p(130f, top + d).x, p(130f, top + d).y)
                lineTo(p(radius, top + d).x, p(radius, top + d).y)
                if (radius - d > 0) arcTo(Rect(p(d, top + d), Size((radius - d) * 2 * u, (radius - d) * 2 * u)), 270f, -90f, false)
                else lineTo(p(d, top + d).x, p(d, top + d).y)
                lineTo(p(d, bottom + 2).x, p(d, bottom + 2).y)
            }
            drawPath(line, color, style = Stroke(thickness / bands * u + 1f))
        }
    }
    drawPath(outline, Color(0xFF45549D), style = Stroke(max(0.6f, u * 0.6f)))
}

/** The playlist drawer's grip on its blue tube: two columns of light dots, the first at [origin]. */
private fun DrawScope.grip(origin: Offset, u: Float) {
    for (row in 0 until 8) for (column in 0 until 2) drawCircle(Color.White.copy(alpha = 0.7f), 0.8f * u, origin + Offset(column * 3.6f * u, row * 3.6f * u))
}

/** The window's periwinkle frame: the top bar rising with an S curve from the tab, down around the screen. */
private fun coronaFrame(u: Float, screenHeight: Float): Path = Path().apply {
    fun p(x: Float, y: Float) = Offset(x * u, y * u)
    val bottom = 26 + screenHeight + 19
    fillType = PathFillType.EvenOdd
    moveTo(p(13f, 24f).x, p(13f, 24f).y)
    lineTo(p(13f, bottom).x, p(13f, bottom).y)
    lineTo(p(346f, bottom).x, p(346f, bottom).y)
    lineTo(p(346f, 10f).x, p(346f, 10f).y)
    quadraticTo(p(346f, 0f).x, p(346f, 0f).y, p(336f, 0f).x, p(336f, 0f).y)
    lineTo(p(118f, 0f).x, p(118f, 0f).y)
    cubicTo(p(104f, 0f).x, p(104f, 0f).y, p(106f, 20f).x, p(106f, 20f).y, p(92f, 20f).x, p(92f, 20f).y)
    lineTo(p(20f, 20f).x, p(20f, 20f).y)
    quadraticTo(p(13f, 20f).x, p(13f, 20f).y, p(13f, 24f).x, p(13f, 24f).y)
    close()
    addRect(Rect(p(19f, 26f), Size(320 * u, screenHeight * u)))
    addRect(Rect(p(19f, 26 + screenHeight + 1), Size(320 * u, 15 * u)))
}

/** The window's outline without its foot, where the drawer flows on from it (and the screen's and the strip's edges). */
private fun coronaFrameOutline(u: Float, screenHeight: Float): Path = Path().apply {
    fun p(x: Float, y: Float) = Offset(x * u, y * u)
    val bottom = 26 + screenHeight + 19
    moveTo(p(13f, bottom).x, p(13f, bottom).y)
    lineTo(p(13f, 24f).x, p(13f, 24f).y)
    quadraticTo(p(13f, 20f).x, p(13f, 20f).y, p(20f, 20f).x, p(20f, 20f).y)
    lineTo(p(92f, 20f).x, p(92f, 20f).y)
    cubicTo(p(106f, 20f).x, p(106f, 20f).y, p(104f, 0f).x, p(104f, 0f).y, p(118f, 0f).x, p(118f, 0f).y)
    lineTo(p(336f, 0f).x, p(336f, 0f).y)
    quadraticTo(p(346f, 0f).x, p(346f, 0f).y, p(346f, 10f).x, p(346f, 10f).y)
    lineTo(p(346f, bottom).x, p(346f, bottom).y)
    addRect(Rect(p(19f, 26f), Size(320 * u, screenHeight * u)))
    addRect(Rect(p(19f, 26 + screenHeight + 1), Size(320 * u, 15 * u)))
}

/**
 * The drawer: a tray flowing on from the window (the same edges), with a large rounded lower left corner, its right end
 * lower; at [top]. [open]: its outline without its top.
 */
private fun coronaDrawer(u: Float, top: Float, open: Boolean = false): Path = Path().apply {
    fun p(x: Float, y: Float) = Offset((13 + x * 333 / 334) * u, (top + y) * u)
    if (open) moveTo(p(334f, 0f).x, p(334f, 0f).y) else { moveTo(p(0f, 0f).x, p(0f, 0f).y); lineTo(p(334f, 0f).x, p(334f, 0f).y) }
    // The right end: the blue block's foot with its rounded corner, then the S curve's lower half down to the tray's foot.
    lineTo(p(334f, 32f).x, p(334f, 32f).y)
    quadraticTo(p(334f, 40f).x, p(334f, 40f).y, p(326f, 40f).x, p(326f, 40f).y)
    lineTo(p(229f, 40f).x, p(229f, 40f).y)
    cubicTo(p(222f, 48f).x, p(222f, 48f).y, p(218f, 58f).x, p(218f, 58f).y, p(205f, 58f).x, p(205f, 58f).y)
    lineTo(p(22f, 58f).x, p(22f, 58f).y)
    quadraticTo(p(0f, 58f).x, p(0f, 58f).y, p(0f, 36f).x, p(0f, 36f).y)
    if (open) lineTo(p(0f, 0f).x, p(0f, 0f).y) else close()
}

/**
 * The blue block at the drawer's lower right (in the drawer's frame, at [top]): from the drawer's S curve's top across to
 * the right end, down to its rounded corner, back along its foot and up the curve's upper half (the curve goes on, as the
 * drawer's outline, down to the tray's foot). [edgeOnly]: just its top and its curved edge.
 */
private fun coronaBlock(u: Float, top: Float, edgeOnly: Boolean = false): Path = Path().apply {
    fun p(x: Float, y: Float) = Offset((13 + x * 333 / 334) * u, (top + y) * u)
    if (edgeOnly) {
        moveTo(p(334f, 17f).x, p(334f, 17f).y); lineTo(p(256f, 17f).x, p(256f, 17f).y)
        moveTo(p(229f, 40f).x, p(229f, 40f).y)
        cubicTo(p(236f, 32f).x, p(236f, 32f).y, p(240f, 17f).x, p(240f, 17f).y, p(256f, 17f).x, p(256f, 17f).y)
        return@apply
    }
    moveTo(p(256f, 17f).x, p(256f, 17f).y)
    lineTo(p(334f, 17f).x, p(334f, 17f).y); lineTo(p(334f, 32f).x, p(334f, 32f).y)
    quadraticTo(p(334f, 40f).x, p(334f, 40f).y, p(326f, 40f).x, p(326f, 40f).y)
    lineTo(p(229f, 40f).x, p(229f, 40f).y)
    cubicTo(p(236f, 32f).x, p(236f, 32f).y, p(240f, 17f).x, p(240f, 17f).y, p(256f, 17f).x, p(256f, 17f).y)
    close()
}

private fun DrawScope.tube(rect: Rect, horizontal: Boolean, flat: Boolean = false) {
    val radius = if (flat) 0f else (if (horizontal) rect.height else rect.width) / 2
    val brush = if (horizontal) Brush.verticalGradient(Corona.tube, rect.top, rect.bottom) else Brush.horizontalGradient(Corona.tube, rect.left, rect.right)
    drawRoundRect(brush, rect.topLeft, rect.size, CornerRadius(radius))
    drawRoundRect(Color(0xFF45549D), rect.topLeft, rect.size, CornerRadius(radius), style = Stroke(1f))
}

/** Corona's slider thumb: silver, with green caps at its ends (along the seek bar, or above and below on the volume). */
private fun DrawScope.coronaThumb(rect: Rect, u: Float, horizontal: Boolean) {
    val radius = CornerRadius(3 * u)
    drawRoundRect(if (horizontal) Brush.horizontalGradient(Corona.thumbGreen, rect.left, rect.right) else Brush.verticalGradient(Corona.thumbGreen, rect.top, rect.bottom),
        rect.topLeft, rect.size, radius)
    val body = if (horizontal) Rect(rect.left + 4.5f * u, rect.top + u, rect.right - 4.5f * u, rect.bottom - u)
        else Rect(rect.left + u, rect.top + 4.5f * u, rect.right - u, rect.bottom - 4.5f * u)
    drawRoundRect(Brush.verticalGradient(listOf(Color.White, Color(0xFFCCD8E7), Color(0xFFA3B3CA)), body.top, body.bottom), body.topLeft, body.size, radius)
    drawRoundRect(Color(0xFF747475), rect.topLeft, rect.size, radius, style = Stroke(max(0.5f, u * 0.6f)))
}

@Composable
private fun CoronaMain(u: Float, screenHeight: Float, song: DeckSong, actions: DeckActions, cover: File?, showsPlaylist: Boolean, showsHandle: Boolean,
                       togglePlaylist: () -> Unit) {
    val measurer = androidx.compose.ui.text.rememberTextMeasurer()
    val haptics = LocalHapticFeedback.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    var pressed by remember { mutableStateOf<String?>(null) }
    var position by remember { mutableStateOf<Float?>(null) }
    var bars by remember { mutableStateOf(true) }
    var mutedVolume by remember { mutableStateOf<Float?>(null) }
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
    val screenBottom = 26 + screenHeight
    val drawerTop = screenBottom + 18
    fun scan(direction: Int): () -> Unit = { current.seek((clock.value + direction * 5.0).coerceIn(0.0, max(song.duration - 1, 0.0))) }
    fun r(x: Float, y: Float, w: Float, h: Float) = Rect(x * u, y * u, (x + w) * u, (y + h) * u)
    val keys = listOf(
        CoronaKey("open", "Close Now Playing", r(117f, 3f, 18f, 18f), enabled = actions.eject != null) { current.eject?.invoke() },
        CoronaKey("list", if (showsPlaylist) "Hide Playlist" else "Show Playlist", r(144f, 3f, 18f, 18f), state = if (showsPlaylist) "On" else "Off") { togglePlaylist() },
        CoronaKey("vis", "Next Visualization", r(167f, 3f, 18f, 18f)) { bars = !bars },
        CoronaKey("eq", "Equalizer", r(190f, 3f, 18f, 18f), enabled = actions.equalizer != null, state = if (actions.equalizer == true) "On" else "Off") {
            current.toggleEqualizer()
        },
        CoronaKey("close", "Close Now Playing", r(324f, 4f, 16f, 16f), round = false, enabled = actions.eject != null) { current.eject?.invoke() },
        CoronaKey("rew", "Rewind", r(18f, drawerTop + 1, 35f, 13f), round = false, hold = scan(-1)) { scan(-1)() },
        CoronaKey("ffwd", "Fast Forward", r(303f, drawerTop + 1, 35f, 13f), round = false, hold = scan(1)) { scan(1)() },
        CoronaKey("play", if (song.playing) "Pause" else "Play", r(20f, drawerTop + 20, 30f, 30f)) { current.playPause() },
        CoronaKey("stop", "Stop", r(54f, drawerTop + 24, 22f, 22f)) { if (song.playing) current.playPause(); current.seek(0.0) },
        CoronaKey("prev", "Previous", r(78f, drawerTop + 24, 22f, 22f), hold = scan(-1)) { current.previous() },
        CoronaKey("next", "Next", r(101f, drawerTop + 24, 22f, 22f), hold = scan(1)) { current.next() },
        CoronaKey("mute", if (mutedVolume == null) "Mute" else "Sound", r(128f, drawerTop + 24, 22f, 22f), enabled = actions.volume != null) {
            val level = mutedVolume
            if (level != null) { current.onVolume(level); mutedVolume = null } else { mutedVolume = max(current.volume ?: 1f, 0.05f); current.onVolume(0f) }
        },
    )
    Box(Modifier.fillMaxSize()) {
        Canvas(Modifier.fillMaxSize()) {
            frame.longValue
            // The transport drawer, under the window.
            // The transport drawer, flowing on from the window: the seek row on the frame's periwinkle, then the glossy
            // tray (outlined on its sides and foot only, so it is one piece with the window).
            val drawer = coronaDrawer(u, drawerTop)
            drawPath(drawer, Brush.verticalGradient(0f to Corona.frame, 0.2f to Color(0xFFD3E0F1), 0.27f to Color.White, 0.42f to Color(0xFFF1F3FA),
                0.55f to Color(0xFFE5EAF5), 0.66f to Color(0xFFF4F6FB), 0.86f to Color(0xFFD5DCEF), 1f to Color(0xFFB6C2D9),
                startY = drawerTop * u, endY = (drawerTop + 58) * u))
            drawPath(coronaDrawer(u, drawerTop, open = true), Color(0xFF646871), style = Stroke(max(0.6f, u * 0.8f)))
            val block = coronaBlock(u, drawerTop)
            drawPath(block, Brush.verticalGradient(Corona.block, (drawerTop + 17) * u, (drawerTop + 40) * u))
            drawPath(coronaBlock(u, drawerTop, edgeOnly = true), Color(0xFF6D7285), style = Stroke(max(0.5f, u * 0.6f)))
            val note = notesPath(r(272f, drawerTop + 21, 13f, 13f))
            drawPath(Path().apply { addPath(note, Offset(0.6f, 0.6f)) }, Color(0xFF45549D).copy(alpha = 0.7f))
            drawPath(note, Brush.verticalGradient(listOf(Color.White, Color(0xFFDDE6F7)), (drawerTop + 21) * u, (drawerTop + 34) * u))
            drawRect(Color.White.copy(alpha = 0.95f), Offset(296 * u, (drawerTop + 22) * u), Size(9 * u, 7 * u), style = Stroke(u))
            drawLine(Color.White.copy(alpha = 0.95f), Offset(315 * u, (drawerTop + 22) * u), Offset(321 * u, (drawerTop + 28) * u), u)
            drawLine(Color.White.copy(alpha = 0.95f), Offset(315 * u, (drawerTop + 22) * u), Offset(318 * u, (drawerTop + 22) * u), u)
            for (row in 0 until 3) for (column in 0 until 3 - row) {
                drawCircle(Color.White.copy(alpha = 0.7f), 0.8f * u, Offset((338.8f - column * 3) * u, (drawerTop + 36.3f - row * 3) * u))
            }
            // The seek row: the green groove and the thumb.
            // Between the seek keys: the thumb never goes under them.
            val track = r(54f, drawerTop + 3, 249f, 9f)
            drawRect(Brush.verticalGradient(Corona.seek, track.top, track.bottom), track.topLeft, track.size)
            drawRect(Color.White, Offset(track.left, track.bottom), Size(track.width, 2 * u))
            if (song.duration > 0) {
                val x = 54f + (249f - 23f) * (position ?: song.progress)
                coronaThumb(r(x, drawerTop + 1, 23f, 13f), u, horizontal = true)
            }
            // The pill behind previous and next; the volume wedge and its thumb.
            val pill = r(78f, drawerTop + 24, 45f, 22f)
            drawRoundRect(Brush.verticalGradient(listOf(Color(0xFFEAF0F8), Color(0xFFC4CCDD)), pill.top, pill.bottom), pill.topLeft, pill.size, CornerRadius(11 * u))
            drawRoundRect(Color(0xFF9297A5).copy(alpha = 0.7f), pill.topLeft, pill.size, CornerRadius(11 * u), style = Stroke(max(0.5f, u * 0.5f)))
            val vol = r(158f, drawerTop + 25, 70f, 18f)
            val wedge = Path().apply {
                moveTo(vol.left, vol.top + vol.height * 0.72f); lineTo(vol.right, vol.top + vol.height * 0.2f); lineTo(vol.right, vol.top + vol.height * 0.72f); close()
            }
            drawPath(wedge, Brush.verticalGradient(listOf(Color(0xFFDFE6F7), Color(0xFFA3ADCB)), vol.top, vol.bottom))
            val level = (actions.volume ?: 1f).coerceIn(0f, 1f)
            clipRect(vol.left, vol.top, vol.left + 5 * u + (vol.width - 10 * u) * level, vol.bottom) {
                drawPath(wedge, Brush.verticalGradient(listOf(Color(0xFF72A382), Color(0xFF99D295)), vol.top, vol.bottom))
            }
            drawPath(wedge, Color(0xFF9FAACB), style = Stroke(max(0.5f, u * 0.5f)))
            coronaThumb(Rect(Offset(vol.left + (vol.width - 10 * u) * level, vol.top), Size(10 * u, vol.height)), u, horizontal = false)
            // The window: the blue tubes, the frame.
            // One bent tube along the top left and (where the playlist drawer is behind the window) down the left side, with
            // the drawer's grip.
            // The window's top piece and foot, and between them the drawer's piece while the drawer is behind the window.
            edge(u, screenBottom + 12, gap = if (showsHandle) null else 33f..(screenBottom + 4))
            if (showsHandle) grip(Offset(4.3f * u, (26 + screenHeight / 2 - 13.2f) * u), u)
            val shape = coronaFrame(u, screenHeight)
            drawPath(shape, Brush.verticalGradient(0f to Color.White, 0.01f to Color(0xFFDFE8F4), 0.06f to Corona.frame, 1f to Corona.frame,
                startY = 0f, endY = (screenBottom + 19) * u))
            drawPath(coronaFrameOutline(u, screenHeight), Corona.frameDark, style = Stroke(max(0.6f, u * 0.8f)))
            drawRect(Color(0xFFFAFDFF), Offset(13 * u, 22 * u), Size(u, (screenHeight + 4) * u))
            // The separators of the top bar's keys, and minimize (for the look).
            listOf(138f, 302f).forEach { x ->
                drawRect(Corona.frameEdge, Offset(x * u, 5 * u), Size(u, 15 * u)); drawRect(Color.White, Offset((x + 1) * u, 5 * u), Size(u, 15 * u))
            }
            drawRect(Corona.navy, Offset(311 * u, 13 * u), Size(7 * u, 2 * u))
            // The screen: bars of the spectrum (the cover is drawn over it otherwise).
            val screen = r(19f, 26f, 320f, screenHeight)
            drawRect(Color.Black, screen.topLeft, screen.size)
            if (bars) {
                val target = if (!song.playing) DoubleArray(PcSpectrumState.BARS) else if (song.heardHere && analyzer.live) {
                    DoubleArray(PcSpectrumState.BARS) { i ->
                        val from = i * Spectrum.BANDS / PcSpectrumState.BARS
                        val to = max((i + 1) * Spectrum.BANDS / PcSpectrumState.BARS, from + 1)
                        (from until to).maxOf { analyzer.bands[it] }.toDouble().coerceAtMost(1.0)
                    }
                } else PcSpectrumState.madeUp(clock.value)
                val (levels, peaks) = spectrum.update(target, frame.longValue)
                val count = PcSpectrumState.BARS
                val gap = screen.width * 0.012f
                val width = (screen.width - gap * (count + 1)) / count
                val gradient = Brush.verticalGradient(listOf(Color(0xFFE8F6FF), Color(0xFF3FA9F5), Color(0xFF1E4FB5), Color(0xFF0B1F5C)),
                    screen.top + screen.height * 0.1f, screen.bottom)
                for (i in 0 until count) {
                    val x = screen.left + gap + i * (width + gap)
                    val height = (screen.height * 0.9f * levels[i]).toFloat()
                    if (height > 0) drawRect(gradient, Offset(x, screen.bottom - height), Size(width, height))
                    val peak = (screen.height * 0.9f * peaks[i]).toFloat()
                    if (peak > 2) drawRect(Color.White.copy(alpha = 0.85f), Offset(x, screen.bottom - peak - 2 * u), Size(width, 1.5f * u))
                }
            }
            drawRect(Corona.frameDark, screen.topLeft, screen.size, style = Stroke(max(0.6f, u * 0.8f)))
            // The metadata strip: title, artist and album in turn, the time on the right.
            val strip = r(19f, screenBottom + 1, 320f, 15f)
            drawRect(Color.Black, strip.topLeft, strip.size)
            val fields = listOf(song.title, song.artist, song.album).filter { it.isNotBlank() }
            val field = if (fields.isEmpty()) "" else fields[((System.currentTimeMillis() / 4000) % fields.size).toInt()]
            val style = TextStyle(fontSize = (8.5f * u).toSp(), fontWeight = FontWeight.Bold, color = Corona.green)
            val time = measurer.measure(clockText(clock.value), style)
            drawText(time, topLeft = Offset(strip.right - 4 * u - time.size.width, strip.center.y - time.size.height / 2))
            val text = measurer.measure(field, style, maxLines = 1, overflow = TextOverflow.Ellipsis,
                constraints = androidx.compose.ui.unit.Constraints(maxWidth = (strip.width - time.size.width - 14 * u).toInt().coerceAtLeast(1)))
            drawText(text, topLeft = Offset(strip.left + 4 * u, strip.center.y - text.size.height / 2))
            // The keys.
            keys.forEach { k ->
                val down = pressed == k.id
                val alpha = if (k.enabled) 1f else 0.4f
                when (k.id) {
                    "close" -> {
                        val c = k.rect.center
                        val d = 3.2f * u
                        drawLine(Corona.navy.copy(alpha = alpha), c - Offset(d, d), c + Offset(d, d), u * 1.8f)
                        drawLine(Corona.navy.copy(alpha = alpha), c + Offset(-d, d), c + Offset(d, -d), u * 1.8f)
                    }
                    "rew", "ffwd" -> {
                        val rect = k.rect
                        drawRoundRect(Brush.verticalGradient(listOf(Color(0xFFB2B4BE), Color(0xFF98ADB7)), rect.top, rect.bottom), rect.topLeft, rect.size,
                            CornerRadius(rect.height / 2))
                        val inner = rect.deflate(0.8f * u)
                        drawRoundRect(Brush.verticalGradient(0f to Color.White, 0.5f to Color(0xFFECEDF3), 1f to (if (down) Color(0xFFA8C8E4) else Color(0xFFC0E0F0)),
                            startY = inner.top, endY = inner.bottom), inner.topLeft, inner.size, CornerRadius(inner.height / 2))
                        listOf(-2.3f, 2.3f).forEach { dx ->
                            navyGlyph(Glyph.PLAY, rect.center + Offset(dx * u, 0f), 4f, 4f, u, mirrored = k.id == "rew")
                        }
                    }
                    else -> {
                        roundKey(k.rect, u, down)
                        val c = k.rect.center + Offset(0f, if (down) u * 0.5f else 0f)
                        when (k.id) {
                            "play" -> if (song.playing) navyGlyph(Glyph.PAUSE, c, 9f, 10f, u) else navyGlyph(Glyph.PLAY, c + Offset(u, 0f), 10f, 12f, u)
                            "stop" -> navyGlyph(Glyph.STOP, c, 6.5f, 6.5f, u)
                            "prev" -> navyGlyph(Glyph.PREVIOUS, c, 7.5f, 7.5f, u)
                            "next" -> navyGlyph(Glyph.NEXT, c, 7.5f, 7.5f, u)
                            "mute" -> keySymbol("mute", c, u, mutedVolume != null, alpha)
                            else -> keySymbol(k.id, c, u, k.state == "On", alpha)
                        }
                    }
                }
            }
        }
        // The cover on the screen, when it shows the cover.
        if (!bars) Box(Modifier.pc(19f, 26f, 320f, screenHeight, u), contentAlignment = Alignment.Center) {
            val side = with(LocalDensity.current) { (screenHeight * 0.78f * u).toDp() }
            Cover(cover, Modifier.size(side), corner = 0.dp)
        }
        // The taps.
        if (showsHandle) Box(Modifier.pc(0f, 26f, 13f, screenHeight, u)
            .semantics { contentDescription = if (showsPlaylist) "Hide Playlist" else "Show Playlist"; role = Role.Button }.clickable { togglePlaylist() })
        Box(Modifier.pc(19f, 26f, 320f, screenHeight, u).semantics { contentDescription = "Visualization"; role = Role.Button }.clickable { bars = !bars })
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
                        var held = false
                        val repeat: Job? = k.hold?.let { hold ->
                            scope.launch {
                                delay(450)
                                while (true) { held = true; hold(); delay(150) }
                            }
                        }
                        val released = tryAwaitRelease()
                        repeat?.cancel()
                        pressed = null
                        if (released && !held) k.tap()
                    })
                })
        }
        Box(Modifier.pc(54f, drawerTop + 1, 249f, 13f, u).semantics { contentDescription = "Position" }.pointerInput(Unit) {
            awaitEachGesture {
                val down = awaitFirstDown()
                down.consume()
                fun at(x: Float) = ((x - 11.5f * u) / (size.width - 23 * u)).coerceIn(0f, 1f)
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
        if (actions.volume != null) Box(Modifier.pc(158f, drawerTop + 25, 70f, 18f, u).semantics { contentDescription = "Volume" }.pointerInput(Unit) {
            awaitEachGesture {
                val down = awaitFirstDown()
                fun set(x: Float) = current.onVolume(((x - 5 * u) / (size.width - 10 * u)).coerceIn(0f, 1f))
                set(down.position.x)
                while (true) {
                    val change = awaitPointerEvent().changes.firstOrNull() ?: break
                    if (!change.pressed) break
                    change.consume()
                    set(change.position.x)
                }
            }
        })
    }
}

@Composable
private fun CoronaPlaylist(u: Float, song: DeckSong, actions: DeckActions, playlist: PlayerModel.Playlist?, onPlay: ((Int) -> Unit)?,
                           overlay: (@Composable () -> Unit)?, onClose: () -> Unit) {
    val measurer = androidx.compose.ui.text.rememberTextMeasurer()
    val list = rememberLazyListState()
    val entries = playlist?.entries?.takeIf { it.isNotEmpty() }
        ?: listOf(PlayerModel.PlaylistEntry(song.title, song.artist, (song.duration * 1000).toLong()))
    val current = if (playlist?.entries.isNullOrEmpty()) 0 else playlist?.current
    LaunchedEffect(current) { current?.let { list.animateScrollToItem((it - 3).coerceAtLeast(0)) } }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val w = constraints.maxWidth / u
        val h = constraints.maxHeight / u
        Canvas(Modifier.fillMaxSize()) {
            val body = Rect(6 * u, 0f, size.width, size.height)
            drawRoundRect(Brush.verticalGradient(0f to Color.White, 0.02f to Color(0xFFC9DAEF), 0.05f to Corona.frame, 0.95f to Corona.frame,
                1f to Corona.frameEdge), body.topLeft, body.size, CornerRadius(8 * u))
            drawRoundRect(Color(0xFF73767B), body.topLeft, body.size, CornerRadius(8 * u), style = Stroke(max(0.6f, u * 0.8f)))
            tube(Rect(0f, 0f, 13 * u, size.height), horizontal = false, flat = true)
            grip(Offset(4.3f * u, (h / 2 - 13.2f) * u), u)
            roundKey(Rect(Offset(26 * u, 9 * u), Size(19 * u, 19 * u)), u, false)
            keySymbol("shuffle", Offset(35.5f * u, 18.5f * u), u, actions.shuffled, 1f)
            val field = Rect(52 * u, 11 * u, (w - 58) * u, 26 * u)
            drawRoundRect(Color.White, field.topLeft, field.size, CornerRadius(2 * u))
            drawRoundRect(Color(0xFF7F9DB9), field.topLeft, field.size, CornerRadius(2 * u), style = Stroke(max(0.5f, u * 0.6f)))
            val name = measurer.measure("Now Playing", TextStyle(fontSize = (8.5f * u).toSp(), color = Color.Black))
            drawText(name, topLeft = Offset(field.left + 4 * u, field.center.y - name.size.height / 2))
            drawPath(Path().apply {
                moveTo(field.right - 9 * u, field.center.y - 1.5f * u); lineTo(field.right - 4 * u, field.center.y - 1.5f * u); lineTo(field.right - 6.5f * u, field.center.y + 1.5f * u); close()
            }, Corona.navy)
            val c = Offset((w - 14.5f) * u, 18.5f * u)
            val d = 3.2f * u
            drawLine(Corona.navy, c - Offset(d, d), c + Offset(d, d), u * 1.8f)
            drawLine(Corona.navy, c + Offset(-d, d), c + Offset(d, -d), u * 1.8f)
            val listRect = Rect(26 * u, 34 * u, (w - 11) * u, (h - 12) * u)
            drawRect(Color.Black, listRect.topLeft, listRect.size)
            drawRect(Corona.frameDark, listRect.topLeft, listRect.size, style = Stroke(max(0.6f, u * 0.8f)))
        }
        Box(Modifier.pc(26f, 9f, 19f, 19f, u).semantics { contentDescription = "Shuffle"; stateDescription = if (actions.shuffled) "On" else "Off" }
            .clickable { actions.toggleShuffle() })
        Box(Modifier.pc(w - 22, 11f, 15f, 15f, u).semantics { contentDescription = "Hide Playlist" }.clickable { onClose() })
        Box(Modifier.pc(26f, 34f, w - 37, h - 46, u).padding(1.dp).clipToBounds()) {
            if (overlay != null) {
                Box(Modifier.fillMaxSize().padding((6 * u / LocalDensity.current.density).dp)) {
                    CompositionLocalProvider(LocalContentColor provides Color.White) { overlay() }
                }
            } else {
                val density = LocalDensity.current
                LazyColumn(state = list, modifier = Modifier.fillMaxSize().background(Color.Black)) {
                    itemsIndexed(entries) { index, entry ->
                        val playing = index == current
                        val style = TextStyle(fontSize = with(density) { (9f * u).toSp() }, color = if (playing) Corona.green else Color.White,
                            fontWeight = if (playing) FontWeight.Bold else FontWeight.Normal)
                        Row(Modifier.fillMaxWidth().height(with(density) { (13f * u).toDp() })
                            .then(if (onPlay != null) Modifier.clickable { onPlay(index) } else Modifier)
                            .padding(horizontal = with(density) { (3 * u).toDp() }), verticalAlignment = Alignment.CenterVertically) {
                            Text(listOfNotNull(entry.title, entry.artist?.takeIf { it.isNotBlank() }).joinToString(" - "), style = style, maxLines = 1,
                                overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                            Spacer(Modifier.width(with(density) { (4 * u).toDp() }))
                            Text(clockText(entry.durationMs / 1000.0).removePrefix("0"), style = style)
                        }
                    }
                }
            }
        }
    }
}
