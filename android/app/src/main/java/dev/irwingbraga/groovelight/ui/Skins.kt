package dev.irwingbraga.groovelight.ui

import android.database.ContentObserver
import android.graphics.BitmapFactory
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.platform.LocalContext
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameMillis
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.io.File
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

/** What a skin needs of the song: what it is, whether it plays, where it is (seconds) and how long it is. */
data class SkinPlayback(val title: String, val artist: String, val isPlaying: Boolean, val time: Double, val duration: Double) {
    val progress: Float get() = if (duration > 0) (time / duration).toFloat().coerceIn(0f, 1f) else 0f
}

/**
 * The song's time in seconds at each frame while it plays: the player's position (sent four times a second) carried on
 * by the clock between them, so the players turn smoothly; still while paused. A report close to where the clock already
 * is only nudges it (a quarter of the way), so the reels and the counter never step back and forth; a seek or a new
 * song moves it at once. Read where it is drawn, so only what moves is drawn again.
 */
@Composable
fun rememberSongClock(positionMs: Long, isPlaying: Boolean): State<Double> {
    val clock = remember { mutableDoubleStateOf(positionMs / 1000.0) }
    LaunchedEffect(positionMs, isPlaying) {
        val received = System.nanoTime()
        val reported = positionMs / 1000.0
        val start = if (isPlaying && kotlin.math.abs(reported - clock.doubleValue) < 0.5) clock.doubleValue + (reported - clock.doubleValue) / 4 else reported
        clock.doubleValue = start
        while (isPlaying) withFrameNanos { clock.doubleValue = start + ((System.nanoTime() - received) / 1e9).coerceIn(0.0, 2.0) }
    }
    return clock
}

/** This device's media volume (0 to 1), followed as its buttons change it, and set by the players' volume knob. */
class MediaVolume(val value: Float, val set: (Float) -> Unit)

@Composable
fun rememberMediaVolume(): MediaVolume {
    val context = LocalContext.current
    val audio = remember { context.getSystemService(AudioManager::class.java) }
    val max = remember { audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1) }
    var level by remember { mutableIntStateOf(audio.getStreamVolume(AudioManager.STREAM_MUSIC)) }
    DisposableEffect(audio) {
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) { level = audio.getStreamVolume(AudioManager.STREAM_MUSIC) }
        }
        context.contentResolver.registerContentObserver(Settings.System.CONTENT_URI, true, observer)
        onDispose { context.contentResolver.unregisterContentObserver(observer) }
    }
    return MediaVolume(level / max.toFloat()) { value ->
        val steps = (value * max).roundToInt().coerceIn(0, max)
        if (steps != level) {
            level = steps
            audio.setStreamVolume(AudioManager.STREAM_MUSIC, steps, 0)
        }
    }
}

/** Degrees from resting beside the record (toward it is positive) putting the stylus `radius` from its center. */
internal fun tonearmAngle(side: Float, center: Offset, radius: Float): Float {
    val pivot = Offset(side * 0.88f, side * 0.14f)
    val length = side * 0.66f
    var low = 0.0
    var high = 60.0
    repeat(30) {
        val middle = (low + high) / 2
        val r = middle * PI / 180
        val stylus = Offset((pivot.x - sin(r) * length).toFloat(), (pivot.y + cos(r) * length).toFloat())
        if (hypot(stylus.x - center.x, stylus.y - center.y) > radius) low = middle else high = middle
    }
    return ((low + high) / 2).toFloat()
}

/** A disc with a hole: [hole] is the hole's radius over the whole width, [inset] takes in the rim (also over the width). */
internal class DiscShape(private val hole: Float, private val inset: Float = 0f) : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val path = Path().apply {
            fillType = PathFillType.EvenOdd
            val i = size.width * inset
            addOval(Rect(i, i, size.width - i, size.height - i))
            val r = size.width * hole
            addOval(Rect(Offset(size.width / 2, size.height / 2), r))
        }
        return Outline.Generic(path)
    }
}

// MARK: Cassette

/** How much tape each reel holds and how far each has turned (radii in pixels, angles in degrees). */
internal data class ReelState(val leftRadius: Float, val rightRadius: Float, val leftAngle: Float, val rightAngle: Float) {
    companion object {
        /**
         * The tape goes from the left reel to the right one over the song at one speed (a bare hub turning half a turn a
         * second). A pack grows as r² = r0² + k·s, so a reel has turned 2 (r − r0) / k.
         */
        fun of(geometry: CassetteGeometry, width: Float, playback: SkinPlayback): ReelState {
            val full = geometry.reelRadius * width
            val hub = geometry.hubRadius * width * 1.05f
            val wound = full * full - hub * hub
            val p = playback.progress
            val left = sqrt(full * full - wound * p)
            val right = sqrt(hub * hub + wound * p)
            if (playback.duration <= 0 || wound <= 0) {
                val a = (playback.time * 180).toFloat()
                return ReelState(left, right, a, a)
            }
            val k = wound / (playback.duration * PI * hub)
            return ReelState(left, right, Math.toDegrees(2 * (full - left) / k).toFloat(), Math.toDegrees(2 * (right - hub) / k).toFloat())
        }
    }
}

/** A user's picture, decoded once per file. */
private val pictures = mutableMapOf<String, ImageBitmap?>()

private fun picture(file: File?): ImageBitmap? = file?.let { f ->
    pictures.getOrPut("${f.path}#${f.lastModified()}") { runCatching { BitmapFactory.decodeFile(f.path)?.asImageBitmap() }.getOrNull() }
}

/** A cassette from the front at its own size: the reels behind the drawn shell and label, or behind the user's picture. */
@Composable
fun CassetteFace(design: CassetteDesign, playback: SkinPlayback, cover: File?, modifier: Modifier = Modifier) {
    val revision by Cassettes.revision.collectAsStateWithLifecycle()
    val shellPicture = remember(design, revision) { picture(Cassettes.pictureFile(design, Cassettes.Picture.SHELL)) }
    val labelPicture = remember(design, revision) { picture(Cassettes.pictureFile(design, Cassettes.Picture.LABEL)) }
    val g = design.resolvedGeometry
    BoxWithConstraints(modifier) {
        val w = constraints.maxWidth.toFloat()
        val h = w / g.aspectRatio
        val reels = ReelState.of(g, w, playback)
        val density = androidx.compose.ui.platform.LocalDensity.current
        val label = Rect(g.label.x * w, g.label.y * h, (g.label.x + g.label.width) * w, (g.label.y + g.label.height) * h)
        val window = Rect(g.window.x * w, g.window.y * h, (g.window.x + g.window.width) * w, (g.window.y + g.window.height) * h)
        val left = Offset(g.leftReel.x * w, g.leftReel.y * h)
        val right = Offset(g.rightReel.x * w, g.rightReel.y * h)
        val hubHole = g.hubRadius * w * 1.25f
        val corner = w * 0.035f
        val grain = rememberTextureBrush(SkinTexture.GRAIN)
        val foil = rememberTextureBrush(SkinTexture.FOIL)
        val paperGrain = rememberTextureBrush(SkinTexture.PAPER)
        Canvas(Modifier.fillMaxSize()) {
            val shell = design.shellColor
            val clarity = design.shellClarity
            if (shellPicture == null) {
                drawRoundRect(shell.copy(alpha = if (clarity > 0) 0.35f else 1f), cornerRadius = CornerRadius(corner))
                drawRoundRect(Color.Black.copy(alpha = 0.35f), cornerRadius = CornerRadius(corner))
            }
            drawReels(design, w, h, left, right, reels, g.hubRadius * w, showsTape = shellPicture != null || clarity > 0)
            if (shellPicture != null) {
                drawImage(shellPicture, dstSize = androidx.compose.ui.unit.IntSize(w.roundToInt(), h.roundToInt()))
            } else {
                val front = cutout(Rect(0f, 0f, w, h), corner, window, listOf(left, right), hubHole)
                drawPath(front, shell.copy(alpha = 1 - clarity))
                // The mould's matte grain, then the light across the plastic: a soft sheen high on the left.
                drawPath(front, grain, alpha = if (clarity > 0) 0.35f else 0.8f, blendMode = BlendMode.Overlay)
                drawPath(front, grain, alpha = 0.05f, blendMode = BlendMode.Screen)
                drawPath(front, Brush.linearGradient(0f to Color.White.copy(alpha = 0.2f), 0.35f to Color.White.copy(alpha = 0.05f), 0.6f to Color.Transparent,
                    1f to Color.Black.copy(alpha = 0.16f), start = Offset.Zero, end = Offset(w, h)))
            }
            if (shellPicture == null || labelPicture != null) {
                // The label with the window and the hubs' holes cut out.
                clipPath(cutout(label, label.height * 0.04f, window, listOf(left, right), hubHole)) {
                    if (labelPicture != null) {
                        drawImage(labelPicture, dstOffset = androidx.compose.ui.unit.IntOffset(label.left.roundToInt(), label.top.roundToInt()),
                            dstSize = androidx.compose.ui.unit.IntSize(label.width.roundToInt(), label.height.roundToInt()))
                    } else {
                        val finish = design.label.backgroundFinish
                        if (finish != null) {
                            with(Foil) { drawFoilRect(finish, label, foil) }
                        } else {
                            drawRect(design.label.background, label.topLeft, label.size)
                            // Printed on paper: its fibres show where the label is not clear.
                            if (design.label.background.alpha > 0.5f) {
                                drawRect(paperGrain, label.topLeft, label.size, alpha = design.label.background.alpha, blendMode = BlendMode.Multiply)
                            }
                        }
                        val stripes = design.label.stripes
                        if (stripes.isNotEmpty()) {
                            val band = label.height * 0.3f / stripes.size
                            stripes.forEachIndexed { i, stripe ->
                                drawRect(stripe, Offset(label.left, label.top + label.height * 0.62f + band * i), Size(label.width, band))
                            }
                        }
                        design.label.bands.forEach { band ->
                            val rect = Rect(Offset(label.left, label.top + label.height * band.y), Size(label.width, label.height * band.height))
                            val finish = band.finish
                            if (finish != null) with(Foil) { drawFoilRect(finish, rect, foil) } else drawRect(band.color, rect.topLeft, rect.size)
                        }
                        repeat(2) { i ->
                            val y = label.top + label.height * (0.15f + 0.09f * i)
                            drawLine(design.label.textColor.copy(alpha = 0.12f), Offset(label.left + label.width * 0.05f, y),
                                Offset(label.right - label.width * 0.05f, y), 1f)
                        }
                    }
                }
            }
            val paper = design.label.writing
            if (paper != null && shellPicture == null && labelPicture == null) {
                // The strip to write on, under the brand's line and above the window.
                val strip = Rect(label.left + label.width * 0.035f, label.top + h * 0.07f, label.left + label.width * 0.965f,
                    maxOf(window.top - h * 0.025f, label.top + h * 0.07f))
                drawRoundRect(paper.background, strip.topLeft, strip.size, CornerRadius(w * 0.006f))
                drawRoundRect(paperGrain, strip.topLeft, strip.size, CornerRadius(w * 0.006f), blendMode = BlendMode.Multiply)
                drawLine(paper.textColor.copy(alpha = 0.15f), Offset(strip.left + strip.width * 0.03f, strip.bottom - strip.height * 0.28f),
                    Offset(strip.right - strip.width * 0.03f, strip.bottom - strip.height * 0.28f), 1f)
            }
            if (shellPicture == null) design.reels.ringColor?.let { ring ->
                // Printed rings around the hubs' holes.
                listOf(left, right).forEach { center ->
                    val radius = hubHole + w * 0.0055f
                    val finish = design.reels.ringFinish
                    if (finish != null) {
                        drawCircle(Foil.brush(finish, center - Offset(radius, radius * 0.7f), center + Offset(radius, radius * 0.7f)), radius, center,
                            style = Stroke(w * 0.011f))
                        drawCircle(foil, radius, center, style = Stroke(w * 0.011f), blendMode = BlendMode.Multiply)
                    } else {
                        drawCircle(ring, radius, center, style = Stroke(w * 0.011f))
                    }
                }
            }
            if (shellPicture == null) {
                // The window's frame and clear plastic; the head opening, its holes; the screws; the edge.
                val windowCorner = CornerRadius(window.height * 0.18f)
                drawRoundRect(Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.16f), Color.White.copy(alpha = 0.03f)), window.top, window.bottom),
                    window.topLeft, window.size, windowCorner)
                drawRoundRect(design.detailColor, window.topLeft, window.size, windowCorner, style = Stroke(w * 0.005f))
                val head = Path().apply {
                    moveTo(w * 0.17f, h); lineTo(w * 0.22f, h * 0.79f); lineTo(w * 0.78f, h * 0.79f); lineTo(w * 0.83f, h); close()
                }
                drawPath(head, shell.copy(alpha = maxOf(1 - clarity, 0.55f)))
                drawPath(head, Color.Black.copy(alpha = 0.18f))
                drawPath(head, design.detailColor.copy(alpha = 0.8f), style = Stroke(w * 0.003f))
                // The grip's molded ribs along the head area.
                repeat(5) { rib ->
                    val y = h * (0.815f + rib * 0.012f)
                    val inset = w * (0.225f - rib * 0.0029f)
                    val line = maxOf(0.6f, w * 0.0025f)
                    drawLine(Color.Black.copy(alpha = 0.35f), Offset(inset, y), Offset(w - inset, y), line)
                    drawLine(Color.White.copy(alpha = 0.09f), Offset(inset, y + line), Offset(w - inset, y + line), maxOf(0.5f, w * 0.0015f))
                }
                listOf(0.25f to 0.04f, 0.38f to 0.05f, 0.5f to 0.04f, 0.62f to 0.05f, 0.75f to 0.04f).forEach { (x, width) ->
                    drawRoundRect(Color.Black.copy(alpha = 0.75f), Offset(w * (x - width / 2), h * 0.875f), Size(w * width, h * 0.05f), CornerRadius(w * 0.004f))
                }
                listOf(0.035f to 0.055f, 0.965f to 0.055f, 0.035f to 0.945f, 0.965f to 0.945f, 0.5f to 0.8f).forEach { (x, y) ->
                    val c = Offset(w * x, h * y)
                    val r = w * 0.014f
                    drawCircle(design.detailColor.copy(alpha = 0.8f), r, c)
                    drawLine(Color.Black.copy(alpha = 0.5f), c - Offset(r * 0.5f, 0f), c + Offset(r * 0.5f, 0f), r * 0.2f)
                    drawLine(Color.Black.copy(alpha = 0.5f), c - Offset(0f, r * 0.5f), c + Offset(0f, r * 0.5f), r * 0.2f)
                }
                drawRoundRect(design.detailColor.copy(alpha = 0.7f), cornerRadius = CornerRadius(corner), style = Stroke(w * 0.004f))
            }
        }
        with(density) {
            val text = design.label.textColor
            val ink = design.label.writing?.takeIf { labelPicture == null }?.textColor ?: text
            // Printed in foil: pressed into the label, a hairline shadow under it.
            val printed = design.label.textFinish?.let { finish ->
                TextStyle(brush = Foil.lettering(finish), shadow = Shadow(Color.Black.copy(alpha = 0.45f), Offset(0f, 1.5f), 0f))
            } ?: TextStyle(color = text.copy(alpha = 0.85f))
            if (shellPicture == null && labelPicture == null) {
                // The brand and the tape's type across the top, the side beside the left reel.
                Row(Modifier.offset { IntOffset((label.left + label.width * 0.035f).roundToInt(), (label.top + h * 0.012f).roundToInt()) }
                    .width((label.width * 0.93f).toDp())) {
                    Text(design.brand, style = printed.merge(TextStyle(fontSize = (w * 0.026f).toSp(), fontWeight = FontWeight.Black,
                        letterSpacing = (w * 0.002f).toSp())), maxLines = 1, modifier = Modifier.weight(1f))
                    Text(design.tapeType, style = printed.merge(TextStyle(fontSize = (w * 0.02f).toSp(), fontWeight = FontWeight.SemiBold)), maxLines = 1)
                }
                Text(design.side, style = printed.merge(TextStyle(fontSize = (w * 0.05f).toSp(), fontWeight = FontWeight.Black)),
                    modifier = Modifier.offset { IntOffset((label.left + label.width * 0.035f).roundToInt(), (window.top - w * 0.012f).roundToInt()) })
            }
            // The song, written above the window, and the cover beside it.
            val writing = Rect(label.left + label.width * 0.05f, label.top + h * 0.06f, label.right - label.width * 0.05f, window.top)
            Row(Modifier.offset { IntOffset(writing.left.roundToInt(), writing.top.roundToInt()) }.width(writing.width.toDp()),
                verticalAlignment = Alignment.CenterVertically) {
                if (design.label.showsArtwork) {
                    Cover(cover, Modifier.size((writing.height * 0.75f).toDp()), corner = 2.dp)
                    Box(Modifier.width((w * 0.02f).toDp()))
                }
                if (design.label.showsText) {
                    val family = if (design.label.handwritten) FontFamily.Cursive else FontFamily.SansSerif
                    // Printed, not written, on a label printed in foil: the song too.
                    val song = design.label.textFinish?.takeIf { !design.label.handwritten && design.label.writing == null && labelPicture == null }
                        ?.let { printed } ?: TextStyle(color = ink)
                    Column(Modifier.graphicsLayer { rotationZ = if (design.label.handwritten) -1.2f else 0f }) {
                        Text(playback.title, style = song.merge(TextStyle(fontSize = (w * 0.042f).toSp(), fontFamily = family, fontWeight = FontWeight.SemiBold)),
                            maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(playback.artist, style = song.merge(TextStyle(fontSize = (w * 0.03f).toSp(), fontFamily = family)), maxLines = 1,
                            overflow = TextOverflow.Ellipsis, modifier = Modifier.graphicsLayer { alpha = 0.85f })
                    }
                }
            }
        }
    }
}

/** A rounded rectangle with the window and round holes cut out (even-odd). */
private fun cutout(rect: Rect, corner: Float, window: Rect, holes: List<Offset>, holeRadius: Float) = Path().apply {
    fillType = PathFillType.EvenOdd
    addRoundRect(RoundRect(rect, CornerRadius(corner)))
    addRoundRect(RoundRect(window, CornerRadius(window.height * 0.18f)))
    holes.forEach { addOval(Rect(it, holeRadius)) }
}

private fun DrawScope.drawReels(design: CassetteDesign, w: Float, h: Float, left: Offset, right: Offset, reels: ReelState, hub: Float, showsTape: Boolean) {
    val tape = design.reels.tapeColor
    if (showsTape) {
        val path = Path().apply {
            moveTo(left.x - reels.leftRadius, left.y); lineTo(w * 0.1f, h * 0.86f); lineTo(w * 0.9f, h * 0.86f); lineTo(right.x + reels.rightRadius, right.y)
        }
        drawPath(path, tape.copy(alpha = 0.9f), style = Stroke(maxOf(1f, w * 0.004f)))
    }
    listOf(left to reels.leftRadius, right to reels.rightRadius).forEach { (c, r) ->
        drawCircle(Brush.radialGradient(listOf(tape.copy(alpha = 0.75f), tape, tape.copy(alpha = 0.85f)), c, r), r, c)
    }
    listOf(left to reels.leftAngle, right to reels.rightAngle).forEach { (c, a) ->
        drawCircle(design.reels.hubColor, hub, c)
        val hole = hub * 0.62f
        drawCircle(Color.Black.copy(alpha = 0.85f), hole, c)
        withTransform({ rotate(a, c) }) {
            repeat(6) { tooth ->
                rotate(tooth * 60f, c) {
                    drawRoundRect(design.reels.hubColor, Offset(c.x - hub * 0.09f, c.y - hole - 0.5f), Size(hub * 0.18f, hub * 0.26f), CornerRadius(hub * 0.03f))
                }
            }
        }
    }
}
