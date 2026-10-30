package dev.irwingbraga.groovelight.ui

import androidx.annotation.DrawableRes
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.ImageShader
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.drawOutline
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.imageResource
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.irwingbraga.groovelight.R
import dev.irwingbraga.groovelight.playback.AudioTap
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.text.Normalizer
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.exp
import kotlin.math.log10

// The parts the vintage players are made of, as GroovelightKit's Skins draws them on the Mac and the iPhone: the
// photographed surfaces (ambientCG, CC0), the segment display fonts (DSEG, OFL), keys, knobs, switches and meters.

/** The photographed surfaces, tiled at half their pixel size. */
enum class SkinTexture(@param:DrawableRes val res: Int) {
    WALNUT(R.drawable.skin_walnut), ALUMINUM(R.drawable.skin_aluminum), FELT(R.drawable.skin_felt), BLACK_PLASTIC(R.drawable.skin_black_plastic),
    /** A cassette's molded plastic: the fine matte grain of a spark-eroded mould (neutral gray). */
    GRAIN(R.drawable.skin_grain),
    /** Hot-stamped foil: faint streaks and a fine sparkle (light gray), colored gold or silver. */
    FOIL(R.drawable.skin_foil),
    /** Paper's fibres (light gray): the labels and the VU meters' faces. */
    PAPER(R.drawable.skin_paper),
}

/** [texture] as a brush to paint with in a canvas, tiled at half its pixel size. */
@Composable
fun rememberTextureBrush(texture: SkinTexture): ShaderBrush {
    val image = ImageBitmap.imageResource(texture.res)
    val density = LocalDensity.current.density
    return remember(image, density) {
        val shader = ImageShader(image, TileMode.Repeated, TileMode.Repeated)
        shader.setLocalMatrix(android.graphics.Matrix().apply { setScale(density / 2, density / 2) })
        ShaderBrush(shader)
    }
}

/** Hot-stamped foil, gold or silver: a mirror of the room across it, bright and dark bands, sharply. */
object Foil {
    private val gold = listOf(0f to Color(0xFF6B4714), 0.14f to Color(0xFFC79433), 0.24f to Color(0xFFFFEB99), 0.3f to Color(0xFFDBA83D),
        0.46f to Color(0xFF805417), 0.6f to Color(0xFFD19E3D), 0.7f to Color(0xFFFFF2B3), 0.78f to Color(0xFFE6B84D), 0.92f to Color(0xFF8F611F),
        1f to Color(0xFFBD8C33))
    private val silver = listOf(0f to Color(0xFF5C5E66), 0.14f to Color(0xFFB8BDC7), 0.24f to Color.White, 0.3f to Color(0xFFCCD1D9),
        0.46f to Color(0xFF6B6E75), 0.6f to Color(0xFFC2C7D1), 0.7f to Color(0xFFFAFCFF), 0.78f to Color(0xFFD1D6E0), 0.92f to Color(0xFF80828C),
        1f to Color(0xFFB3B8C2))
    /** Down a letter: lit at the top, a dark band below the middle, the floor's light at the foot. */
    private val goldLettering = listOf(0f to Color(0xFFFFF0A8), 0.3f to Color(0xFFF2C75C), 0.55f to Color(0xFFB3802B), 0.78f to Color(0xFFE0AD47),
        1f to Color(0xFFFADE85))
    private val silverLettering = listOf(0f to Color.White, 0.3f to Color(0xFFDBE0E8), 0.55f to Color(0xFF8C919C), 0.78f to Color(0xFFCCD1DB),
        1f to Color(0xFFF2F5FA))

    /** Foil across a shape from [start] to [end]. */
    fun brush(finish: Finish, start: Offset, end: Offset): Brush =
        Brush.linearGradient(*(if (finish == Finish.GOLD) gold else silver).toTypedArray(), start = start, end = end)

    /** Foil down each line of lettering. */
    fun lettering(finish: Finish): Brush = Brush.verticalGradient(*(if (finish == Finish.GOLD) goldLettering else silverLettering).toTypedArray())

    /** Foil filling [rect] (diagonally across it), with its streaks and sparkle ([texture], the foil texture's brush). */
    fun DrawScope.drawFoilRect(finish: Finish, rect: Rect, texture: Brush) {
        drawRect(brush(finish, Offset(rect.left, rect.top + rect.height * 0.15f), Offset(rect.right, rect.bottom - rect.height * 0.15f)), rect.topLeft, rect.size)
        drawRect(texture, rect.topLeft, rect.size, blendMode = BlendMode.Multiply)
    }
}

/** Fills the shape with [texture], made lighter or darker ([brightness], -1 to 1) and colored ([tint], multiplied). */
fun Modifier.textured(texture: SkinTexture, brightness: Float = 0f, tint: Color = Color.White, shape: Shape = RectangleShape): Modifier = composed {
    val brush = rememberTextureBrush(texture)
    val filter = remember(brightness, tint) {
        val add = brightness * 255
        ColorFilter.colorMatrix(ColorMatrix(floatArrayOf(tint.red, 0f, 0f, 0f, add, 0f, tint.green, 0f, 0f, add, 0f, 0f, tint.blue, 0f, add, 0f, 0f, 0f, 1f, 0f)))
    }
    drawBehind { drawOutline(shape.createOutline(size, layoutDirection, this), brush, colorFilter = filter) }
}

val dsegDigits = FontFamily(Font(R.font.dseg7_classic_bold))
val dsegLetters = FontFamily(Font(R.font.dseg14_classic_bold))

/** Text the 14-segment font can show: capitals without accents, the rest blank (its "!" is a blank as wide as a character). */
fun segmentText(text: String): String {
    val plain = Normalizer.normalize(text, Normalizer.Form.NFD).replace(Regex("\\p{Mn}+"), "").uppercase()
    val allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.,'?/()&+:"
    return plain.map { if (it in allowed) it else '!' }.joinToString("")
}

/** Minutes and seconds, as the displays and counters show them. */
fun clockText(seconds: Double): String {
    val whole = max(seconds, 0.0).toInt()
    return "%02d:%02d".format(whole / 60 % 100, whole % 60)
}

/** A caption cut into metal (dark, lit from above) or printed on a dark panel (light). */
@Composable
fun Engraved(text: String, size: TextUnit, onDark: Boolean = false, modifier: Modifier = Modifier) {
    Text(text, modifier = modifier, maxLines = 1, softWrap = false, style = TextStyle(
        fontSize = size, fontWeight = FontWeight.Bold, letterSpacing = size * 0.18f,
        color = if (onDark) Color.White.copy(alpha = 0.78f) else Color.Black.copy(alpha = 0.62f),
        shadow = Shadow(if (onDark) Color.Black.copy(alpha = 0.7f) else Color.White.copy(alpha = 0.55f), Offset(0f, if (onDark) -1f else 1.2f), 0f),
    ))
}

/** A plate of [texture] fixed to the player: a lit top edge, a shadowed bottom one, screws in its corners. */
fun Modifier.plate(texture: SkinTexture, corner: Dp, brightness: Float = 0f, screws: Dp? = null): Modifier = composed {
    val shape = RoundedCornerShape(corner)
    shadow(corner, shape).textured(texture, brightness, shape = shape)
        .drawBehind {
            drawRoundRect(Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.16f), Color.Transparent, Color.Black.copy(alpha = 0.18f))),
                cornerRadius = CornerRadius(corner.toPx()))
        }
        .border(1.2.dp, Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.7f), Color.White.copy(alpha = 0.1f), Color.Black.copy(alpha = 0.35f))), shape)
        .drawWithScrews(screws)
}

private fun Modifier.drawWithScrews(screws: Dp?): Modifier = if (screws == null) this else drawBehind {
    val r = screws.toPx() / 2
    val inset = r * 2.8f
    listOf(Offset(inset, inset), Offset(size.width - inset, inset), Offset(inset, size.height - inset), Offset(size.width - inset, size.height - inset))
        .forEachIndexed { index, c -> drawScrew(c, r, index * 37f + 12f) }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawScrew(c: Offset, r: Float, angle: Float) {
    drawCircle(Color.Black.copy(alpha = 0.35f), r * 1.1f, c + Offset(0f, r * 0.2f))
    drawCircle(Brush.radialGradient(listOf(Color(0xFFEBEBEB), Color(0xFF8C8C8C), Color(0xFF4D4D4D)), c - Offset(r * 0.3f, r * 0.4f), r * 1.4f), r, c)
    rotate(angle, c) {
        drawLine(Color.Black.copy(alpha = 0.6f), c - Offset(r * 0.75f, 0f), c + Offset(r * 0.75f, 0f), r * 0.32f)
        drawLine(Color.Black.copy(alpha = 0.6f), c - Offset(0f, r * 0.75f), c + Offset(0f, r * 0.75f), r * 0.32f)
    }
}

/** A hollow in the player (a display's window): darker at its top edge, lit at its bottom one. */
fun Modifier.recess(corner: Dp, fill: Brush): Modifier {
    val shape = RoundedCornerShape(corner)
    return clip(shape).background(fill).drawBehind {
        drawRect(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.7f), Color.Transparent), 0f, 10.dp.toPx()))
    }.border(1.dp, Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.6f), Color.White.copy(alpha = 0.35f))), shape)
}

/**
 * Something pressed like a real key: down while touched, [onTap] on release, a tap felt. With [onHold], held past a
 * moment it does that over and over instead (rewind and fast forward scanning through the song).
 */
@Composable
fun DeckPress(title: String, onTap: () -> Unit, modifier: Modifier = Modifier, onHold: (() -> Unit)? = null, state: String? = null,
              content: @Composable BoxScope.(pressed: Boolean) -> Unit) {
    var pressed by remember { mutableStateOf(false) }
    val haptics = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    val tap by rememberUpdatedState(onTap)
    val hold by rememberUpdatedState(onHold)
    Box(modifier
        .semantics {
            contentDescription = title
            role = Role.Button
            if (state != null) stateDescription = state
            onClick { tap(); true }
        }
        .pointerInput(Unit) {
            awaitEachGesture {
                awaitFirstDown(requireUnconsumed = false)
                pressed = true
                haptics.performHapticFeedback(HapticFeedbackType.VirtualKey)
                var held = false
                val repeating = hold?.let { action ->
                    scope.launch {
                        delay(450)
                        while (isActive) { held = true; action(); delay(150) }
                    }
                }
                val up = waitForUpOrCancellation()
                repeating?.cancel()
                pressed = false
                if (up != null && !held) tap()
            }
        }, contentAlignment = Alignment.Center) { content(pressed) }
}

/** The turntable's square aluminum key, its symbol engraved, a lamp in its corner when it has one. */
@Composable
fun MetalKey(title: String, icon: Int, width: Dp, height: Dp, onTap: () -> Unit, onHold: (() -> Unit)? = null, lamp: Boolean? = null) {
    DeckPress(title, onTap, Modifier.size(width, height), onHold) { pressed ->
        val shape = RoundedCornerShape(height * 0.12f)
        Box(Modifier.fillMaxSize().padding(1.dp).background(Color.Black.copy(alpha = 0.75f), shape))
        Box(Modifier.fillMaxSize().padding(3.dp).graphicsLayer { translationY = if (pressed) 1.5.dp.toPx() else 0f }
            .shadow(if (pressed) 1.dp else 4.dp, shape)
            .textured(SkinTexture.ALUMINUM, if (pressed) 0.02f else 0.12f, shape = shape)
            .background(Brush.verticalGradient(listOf(Color.White.copy(alpha = if (pressed) 0.05f else 0.3f), Color.Transparent, Color.Black.copy(alpha = 0.25f))), shape)
            .border(1.dp, Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.8f), Color.Black.copy(alpha = 0.4f))), shape),
            contentAlignment = Alignment.Center) {
            Icon(painterResource(icon), null, Modifier.size(height * 0.36f), tint = Color.Black.copy(alpha = 0.6f))
        }
        if (lamp != null) PilotLamp(lamp, Modifier.align(Alignment.TopEnd).padding(height * 0.12f).size(height * 0.14f))
    }
}

/** A small lamp: lit, it glows in its color. */
@Composable
fun PilotLamp(on: Boolean, modifier: Modifier, color: Color = Color(0xFFFF4729)) {
    Canvas(modifier) {
        val r = size.minDimension / 2
        if (on) drawCircle(Brush.radialGradient(listOf(color.copy(alpha = 0.6f), Color.Transparent), center, r * 2.5f), r * 2.5f)
        drawCircle(Brush.radialGradient(if (on) listOf(Color.White, color, color.copy(alpha = 0.7f)) else listOf(Color(0xFF737373), Color(0xFF2E2E2E), Color(0xFF1A1A1A)),
            center - Offset(r * 0.2f, r * 0.3f), r * 1.2f), r)
        drawCircle(Color.Black.copy(alpha = 0.6f), r, style = Stroke(r * 0.24f))
    }
}

/** A cassette deck's piano key: long, latched down while what it does goes on (Play while playing, Pause while paused). */
@Composable
fun PianoKey(title: String, icon: Int, width: Dp, height: Dp, onTap: () -> Unit, onHold: (() -> Unit)? = null, latched: Boolean = false,
             accent: Color? = null) {
    DeckPress(title, onTap, Modifier.size(width, height), onHold, state = if (latched) "Down" else null) { pressed ->
        val down = pressed || latched
        val travel by animateFloatAsState(if (pressed) 0.14f else if (latched) 0.1f else 0f, spring(stiffness = 900f), label = "key")
        val corner = width * 0.1f
        Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.85f), RoundedCornerShape(corner)))
        Column(Modifier.fillMaxSize().padding(horizontal = width * 0.04f).clip(RoundedCornerShape(corner))
            .graphicsLayer { translationY = travel * height.toPx() }) {
            // The top of the key, as it comes out of the deck, and its face.
            Box(Modifier.fillMaxWidth().height(height * (0.32f - travel * 0.6f))
                .background(Brush.verticalGradient(listOf(Color(if (down) 0xFF595959 else 0xFF8C8C8C), Color(if (down) 0xFF383838 else 0xFF666666)))))
            Box(Modifier.fillMaxWidth().weight(1f).textured(SkinTexture.ALUMINUM, if (down) 0f else 0.16f)
                .background(Brush.verticalGradient(listOf(Color.White.copy(alpha = if (down) 0.1f else 0.45f), Color.White.copy(alpha = 0.05f), Color.Black.copy(alpha = 0.3f)))),
                contentAlignment = Alignment.Center) {
                Icon(painterResource(icon), null, Modifier.size(width * 0.36f), tint = Color.Black.copy(alpha = 0.62f))
                if (accent != null) Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(height * 0.06f).background(accent.copy(alpha = if (down) 0.7f else 0.9f)))
            }
        }
    }
}

/** A CD player's round key: black rubber in a polished ring, its symbol printed white. */
@Composable
fun RoundKey(title: String, icon: Int, diameter: Dp, onTap: () -> Unit, onHold: (() -> Unit)? = null, state: String? = null) {
    DeckPress(title, onTap, Modifier.size(diameter), onHold, state) { pressed ->
        Canvas(Modifier.fillMaxSize().shadow(if (pressed) 1.dp else 5.dp, CircleShape)) {
            drawCircle(Brush.sweepGradient(listOf(Color(0xFFD9D9D9), Color(0xFF595959), Color(0xFFE6E6E6), Color(0xFF4D4D4D), Color(0xFFD9D9D9))))
            val r = size.minDimension / 2 * 0.86f * (if (pressed) 0.96f else 1f)
            drawCircle(Brush.radialGradient(listOf(Color(if (pressed) 0xFF1A1A1A else 0xFF424242), Color(0xFF0F0F0F)), center - Offset(r * 0.2f, r * 0.4f), r * 1.1f), r)
        }
        Icon(painterResource(icon), null, Modifier.size(diameter * 0.34f), tint = Color.White.copy(alpha = 0.85f))
    }
}

/**
 * A knurled aluminum knob, its line on the printed scale around it: touch it and swipe up to turn it up, down to turn it
 * down, the whole scale over [KNOB_TRAVEL] whatever the knob's size. It turns from where the swipe began, so a level that
 * moves in steps (the media volume) follows the finger rather than sticking.
 */
/** How far a swipe goes to turn a knob from 0 to 10. */
private val KNOB_TRAVEL = 180.dp

@Composable
fun Knob(title: String, value: Float, onValue: (Float) -> Unit, diameter: Dp, onDark: Boolean = false) {
    val current by rememberUpdatedState(value)
    val change by rememberUpdatedState(onValue)
    val density = LocalDensity.current
    Canvas(Modifier.size(diameter)
        .semantics {
            contentDescription = title
            progressBarRangeInfo = ProgressBarRangeInfo(value, 0f..1f)
            setProgress { change(it.coerceIn(0f, 1f)); true }
        }
        .pointerInput(Unit) {
            val span = with(density) { KNOB_TRAVEL.toPx() }
            var start = 0f
            var moved = 0f
            detectVerticalDragGestures(onDragStart = { start = current; moved = 0f }) { pointer, dy ->
                pointer.consume()
                moved -= dy
                change((start + moved / span).coerceIn(0f, 1f))
            }
        }) {
        val r = size.minDimension / 2
        val ink = if (onDark) Color.White.copy(alpha = 0.7f) else Color.Black.copy(alpha = 0.6f)
        for (step in 0..10) {
            val a = Math.toRadians(-135.0 + step * 27 - 90)
            val inner = r * 0.86f
            val outer = r * (if (step % 5 == 0) 1f else 0.94f)
            drawLine(ink, center + Offset((cos(a) * inner).toFloat(), (sin(a) * inner).toFloat()),
                center + Offset((cos(a) * outer).toFloat(), (sin(a) * outer).toFloat()), max(1f, r * 0.025f))
        }
        val knob = r * 0.72f
        drawCircle(Color.Black.copy(alpha = 0.45f), knob, center + Offset(0f, knob * 0.1f))
        drawCircle(Color(0xFF333333), knob)
        for (i in 0 until 72) {
            val a = i / 72.0 * 2 * PI
            drawLine(Color.White.copy(alpha = if (i % 2 == 0) 0.55f else 0.15f),
                center + Offset((cos(a) * knob * 0.8f).toFloat(), (sin(a) * knob * 0.8f).toFloat()),
                center + Offset((cos(a) * knob).toFloat(), (sin(a) * knob).toFloat()), 1f)
        }
        val cap = knob * 0.86f
        drawCircle(Brush.sweepGradient(listOf(Color(0xFFF2F2F2), Color(0xFF8C8C8C), Color(0xFFE6E6E6), Color(0xFF808080), Color(0xFFF2F2F2))), cap)
        drawCircle(Brush.radialGradient(listOf(Color.White.copy(alpha = 0.25f), Color.Transparent), center, cap * 0.6f), cap)
        drawCircle(Color.Black.copy(alpha = 0.3f), cap, style = Stroke(1f))
        rotate(-135f + value * 270f) {
            drawLine(Color.Black.copy(alpha = 0.75f), center - Offset(0f, cap * 0.35f), center - Offset(0f, cap * 0.9f), max(2f, r * 0.05f), StrokeCap.Round)
        }
    }
}

/** A bat-handle toggle on its nut: up for on, down for off; with three positions, down, middle (towards you) and up. */
@Composable
fun ToggleSwitch(title: String, position: Int, value: String, size: Dp, onTap: () -> Unit, positions: Int = 2) {
    DeckPress(title, onTap, Modifier.size(size), state = value) {
        val lever by animateFloatAsState(if (position == 0) 1f else if (positions == 3 && position == 1) 0f else -1f, spring(stiffness = 900f), label = "lever")
        Canvas(Modifier.fillMaxSize()) {
            val s = this.size.minDimension
            drawCircle(Color.Black.copy(alpha = 0.4f), s * 0.21f, center + Offset(0f, s * 0.03f))
            drawCircle(Brush.radialGradient(listOf(Color(0xFFE6E6E6), Color(0xFF737373)), center - Offset(s * 0.06f, s * 0.08f), s * 0.3f), s * 0.21f)
            val length = s * (0.1f + kotlin.math.abs(lever) * 0.34f)
            val top = center.y - lever * s * 0.18f - length / 2
            drawRoundRect(Color.Black.copy(alpha = 0.45f), Offset(center.x - s * 0.085f + 2f, top + 3f), Size(s * 0.17f, length), CornerRadius(s * 0.085f))
            drawRoundRect(Brush.horizontalGradient(listOf(Color(0xFFFAFAFA), Color(0xFF8C8C8C), Color(0xFFCCCCCC)), center.x - s * 0.085f, center.x + s * 0.085f),
                Offset(center.x - s * 0.085f, top), Size(s * 0.17f, length), CornerRadius(s * 0.085f))
            val tip = Offset(center.x, center.y - lever * s * 0.36f)
            drawCircle(Brush.radialGradient(listOf(Color.White, Color(0xFF999999)), tip - Offset(s * 0.02f, s * 0.02f), s * 0.1f), s * 0.1f, tip)
        }
    }
}

/**
 * A VU meter: the needle over a backlit amber scale, red past 0 dB, following its channel's level as heard ([heardHere]:
 * the music plays on this phone) at a VU meter's pace, and falling back while paused. For music played on another
 * device, whose sound does not pass through this one, it swings with a made-up level (as on the Mac and the iPhone).
 */
@Composable
fun VUMeter(channel: Int, clock: State<Double>, playing: Boolean, heardHere: Boolean, modifier: Modifier) {
    val rest by animateFloatAsState(if (playing) 1f else 0f, spring(stiffness = 120f), label = "needle")
    // While shown, the player copies what it plays for the meter.
    if (heardHere) DisposableEffect(Unit) {
        AudioTap.start()
        onDispose { AudioTap.stop() }
    }
    val needle = remember { VUNeedle() }
    val paper = rememberTextureBrush(SkinTexture.PAPER)
    val measurer = rememberTextMeasurer()
    val ink = Color(0xFF1A140F)
    val red = Color(0xFFC71A0F)
    // The bezel: black plastic with a polished chamfer.
    Box(modifier.shadow(3.dp, RoundedCornerShape(5.dp))
        .background(Brush.verticalGradient(listOf(Color(0xFF292929), Color(0xFF0A0A0A))), RoundedCornerShape(5.dp))
        .border(1.dp, Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.45f), Color.White.copy(alpha = 0.05f), Color.Black.copy(alpha = 0.6f))),
            RoundedCornerShape(5.dp))
        .padding(4.dp)
        .clip(RoundedCornerShape(3.dp))) {
        // The face: printed paper lit from behind by a lamp low in the middle, darker at its corners; the scale, the
        // numbers and the words. Drawn once: only the needle moves.
        Canvas(Modifier.fillMaxSize()) {
            drawRect(Color(0xFFFAE09E))
            drawRect(paper, blendMode = BlendMode.Multiply)
            drawRect(Brush.radialGradient(listOf(Color(0xFFFFD973).copy(alpha = 0.55f), Color.Transparent), Offset(size.width / 2, size.height * 1.05f),
                size.width * 0.75f), blendMode = BlendMode.Screen)
            drawRect(Brush.radialGradient(0f to Color.Transparent, 0.55f to Color.Transparent, 1f to Color(0xFF59330D).copy(alpha = 0.45f),
                center = Offset(size.width / 2, size.height * 0.75f), radius = size.width * 0.62f))
            val radius = size.height * 0.86f
            val arc = Path()
            for (i in 0..40) { val p = vuPoint(0.78f * i / 40, radius); if (i == 0) arc.moveTo(p.x, p.y) else arc.lineTo(p.x, p.y) }
            drawPath(arc, ink.copy(alpha = 0.85f), style = Stroke(max(0.8f, size.height * 0.011f)))
            val redArc = Path()
            for (i in 0..12) { val p = vuPoint(0.78f + 0.22f * i / 12, radius); if (i == 0) redArc.moveTo(p.x, p.y) else redArc.lineTo(p.x, p.y) }
            drawPath(redArc, red, style = Stroke(max(1.5f, size.height * 0.045f)))
            listOf(0f, 0.25f, 0.38f, 0.47f, 0.58f, 0.65f, 0.71f, 0.78f, 0.85f, 0.92f, 1f).forEach { mark ->
                val long = mark == 0.78f || mark == 0f || mark == 1f
                drawLine(ink.copy(alpha = 0.85f), vuPoint(mark, radius), vuPoint(mark, radius + size.height * (if (long) 0.12f else 0.07f)),
                    max(0.8f, size.height * 0.011f))
            }
            fun label(text: String, at: Offset, style: TextStyle) {
                val layout = measurer.measure(text, style)
                drawText(layout, topLeft = at - Offset(layout.size.width / 2f, layout.size.height / 2f))
            }
            val numberSize = (size.height * 0.085f).toSp()
            listOf("20" to 0f, "10" to 0.25f, "7" to 0.38f, "5" to 0.47f, "3" to 0.58f, "0" to 0.78f, "1" to 0.85f, "2" to 0.92f).forEach { (text, at) ->
                label(text, vuPoint(at, size.height * (0.86f + 0.17f)), TextStyle(fontSize = numberSize, fontWeight = FontWeight.SemiBold,
                    color = if (at > 0.78f) red else ink.copy(alpha = 0.85f)))
            }
            label("VU", Offset(size.width / 2, size.height * 0.65f), TextStyle(fontSize = (size.height * 0.15f).toSp(), fontFamily = FontFamily.Serif,
                fontWeight = FontWeight.SemiBold, color = ink.copy(alpha = 0.8f)))
            label(if (channel == 0) "L" else "R", Offset(size.width * 0.1f, size.height * 0.72f), TextStyle(fontSize = (size.height * 0.09f).toSp(),
                fontWeight = FontWeight.Bold, color = ink.copy(alpha = 0.6f)))
            label("−", vuPoint(0.1f, size.height * (0.86f - 0.16f)), TextStyle(fontSize = (size.height * 0.11f).toSp(), fontWeight = FontWeight.Bold,
                color = ink.copy(alpha = 0.8f)))
            label("+", vuPoint(0.92f, size.height * (0.86f - 0.16f)), TextStyle(fontSize = (size.height * 0.11f).toSp(), fontWeight = FontWeight.Bold,
                color = red))
        }
        Canvas(Modifier.fillMaxSize()) {
            val time = clock.value
            val heard = if (heardHere) AudioTap.levels() else null
            val target = if (heard != null) vuPosition(if (channel == 0) heard.first else heard.second) else {
                val shift = channel * 1.7
                val beat = max(sin(time * 2 * PI * 2.05 + shift), 0.0).pow(6) * 0.14
                val swing = sin(time * 1.3 + shift) * 0.08 + sin(time * 4.7 + shift * 2) * 0.06 + sin(time * 11.3 + shift) * 0.04
                (0.62 + swing + beat).coerceIn(0.05, 1.0)
            }
            val level = (needle.position(target, System.nanoTime()) * rest).toFloat()
            val pivot = Offset(size.width / 2, size.height * 1.12f)
            val tip = vuPoint(level, size.height * 1.02f)
            // Its shadow on the face, a little below and to the right, soft; then the needle.
            val shadow = Offset(size.height * 0.025f, size.height * 0.04f)
            drawLine(Color.Black.copy(alpha = 0.18f), pivot + shadow, tip + shadow, max(2f, size.height * 0.04f), StrokeCap.Round)
            drawLine(Color.Black.copy(alpha = 0.22f), pivot + shadow, tip + shadow, max(1f, size.height * 0.02f), StrokeCap.Round)
            drawLine(Color(0xFF0F0F0F), pivot, tip, max(0.8f, size.height * 0.014f), StrokeCap.Round)
            // The pivot's cover: a black molded hood across the bottom, its edge catching the light.
            val hood = Rect(Offset(size.width / 2, size.height * 0.99f), Size(size.width * 0.62f, size.height * 0.34f))
                .let { Rect(it.left - it.width / 2, it.top - it.height / 2, it.left + it.width / 2, it.top + it.height / 2) }
            drawOval(Color.Black.copy(alpha = 0.35f), hood.topLeft - Offset(0f, size.height * 0.02f), hood.size)
            drawOval(Brush.verticalGradient(listOf(Color(0xFF383838), Color(0xFF0A0A0A)), hood.top, hood.bottom), hood.topLeft, hood.size)
            drawOval(Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.35f), Color.Transparent), hood.top, hood.center.y), hood.topLeft, hood.size,
                style = Stroke(max(0.6f, size.height * 0.01f)))
            // The glass: the bezel's shadow inside its top edge, the room's reflection across it.
            drawRect(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.4f), Color.Transparent), 0f, size.height * 0.12f))
            drawRect(Brush.linearGradient(0f to Color.White.copy(alpha = 0.3f), 0.38f to Color.White.copy(alpha = 0.08f), 0.4f to Color.Transparent,
                start = Offset.Zero, end = Offset(size.width, size.height)))
        }
    }
}

/** Where a level is on a VU meter's scale in this face, [radius] from the pivot below it. */
private fun DrawScope.vuPoint(level: Float, radius: Float): Offset {
    val pivot = Offset(size.width / 2, size.height * 1.12f)
    val angle = Math.toRadians(-135.0 + level * 90)
    return pivot + Offset((cos(angle) * radius).toFloat(), (sin(angle) * radius).toFloat())
}

/** The needle's movement: toward where the level puts it at a VU meter's pace (99% of the way in 300 ms). */
private class VUNeedle {
    private var value = 0.0
    private var last = 0L

    fun position(target: Double, now: Long): Double {
        val elapsed = if (last == 0L) 0.25 else ((now - last) / 1e9).coerceIn(0.0, 0.25)
        last = now
        value += (target - value) * (1 - exp(-elapsed / 0.065))
        return value
    }
}

/** The scale's place (0 at -20 VU, 0.78 at 0, 1 at +3) for an RMS level, 0 VU at -12 dBFS, as on the Mac and the iPhone. */
internal fun vuPosition(rms: Float): Double {
    val vu = 20 * log10(max(rms.toDouble(), 1e-6)) + 12
    val marks = listOf(-20.0 to 0.0, -10.0 to 0.25, -7.0 to 0.38, -5.0 to 0.47, -3.0 to 0.58, -2.0 to 0.65, -1.0 to 0.71,
        0.0 to 0.78, 1.0 to 0.85, 2.0 to 0.92, 3.0 to 1.0)
    if (vu <= marks.first().first) return 0.0
    if (vu >= marks.last().first) return minOf(1.04, 1 + (vu - 3) * 0.01)
    val upper = marks.indexOfFirst { it.first >= vu }
    val (lowVu, lowAt) = marks[upper - 1]
    val (highVu, highAt) = marks[upper]
    return lowAt + (highAt - lowAt) * (vu - lowVu) / (highVu - lowVu)
}

/** A tape counter: minutes and seconds on drums rolling on as the tape goes, each turning over as the one after it passes 9 (or 59). */
@Composable
fun TapeCounter(clock: State<Double>, modifier: Modifier, height: Dp) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.CenterVertically) {
        CounterDrum(clock, 600.0, 10.0, height)
        CounterDrum(clock, 60.0, 10.0, height)
        Text(":", style = TextStyle(fontSize = (height.value * 0.5f).sp, fontWeight = FontWeight.Bold, color = Color.Black.copy(alpha = 0.6f)))
        CounterDrum(clock, 10.0, 6.0, height)
        CounterDrum(clock, 1.0, 10.0, height)
    }
}

@Composable
private fun CounterDrum(clock: State<Double>, unit: Double, radix: Double, height: Dp) {
    val width = height * 0.78f
    Box(Modifier.size(width, height).clip(RoundedCornerShape(width * 0.12f)).background(Color(0xFF0F0F0F))) {
        val seconds = max(clock.value, 0.0)
        val whole = floor(seconds / unit) % radix
        val carry = if (unit == 1.0) seconds - floor(seconds) else max(0.0, seconds % unit - (unit - 1))
        val value = whole + carry
        val digit = floor(value).toInt() % 10
        val turn = (value - floor(value)).toFloat()
        for (offset in -1..2) {
            Text("${(digit + offset + 10) % 10}", Modifier.align(Alignment.Center).graphicsLayer { translationY = (offset - turn) * height.toPx() * 0.72f },
                style = TextStyle(fontSize = (height.value * 0.6f).sp, fontFamily = FontFamily.Monospace, fontWeight = FontWeight.SemiBold, color = Color(0xFFEBEBEB)))
        }
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0f to Color.Black.copy(alpha = 0.85f), 0.3f to Color.Transparent,
            0.7f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.85f))))
    }
}

/** The color of a vacuum fluorescent display's lit segments. */
val vfdColor = Color(0xFF73FFE6)

/** Text lit on a segment display, its unlit segments faintly behind. */
@Composable
fun VFDText(text: String, ghost: String, family: FontFamily, size: TextUnit, color: Color = vfdColor, modifier: Modifier = Modifier) {
    Box(modifier) {
        Text(ghost, maxLines = 1, softWrap = false, style = TextStyle(fontFamily = family, fontSize = size, color = color.copy(alpha = 0.07f)))
        Text(text, maxLines = 1, softWrap = false, style = TextStyle(fontFamily = family, fontSize = size, color = color,
            shadow = Shadow(color.copy(alpha = 0.8f), Offset.Zero, 10f)))
    }
}

/** A line of 14-segment characters, [count] wide; longer text steps through a character at a time. */
@Composable
fun VFDMarquee(text: String, count: Int, size: TextUnit, moving: Boolean) {
    val letters = segmentText(text)
    var step by remember(text) { mutableIntStateOf(0) }
    LaunchedEffect(text, moving) { while (moving && letters.length > count) { delay(350); step++ } }
    val shown = if (letters.length <= count) letters.padEnd(count, '!') else {
        val loop = "$letters!!!!"
        (0 until count).map { loop[(step + it) % loop.length] }.joinToString("")
    }
    VFDText(shown, "~".repeat(count), dsegLetters, size)
}

/** A round aluminum cap for the app's buttons over a player (close, lyrics, the menu). */
fun Modifier.deckCap(): Modifier = composed {
    shadow(3.dp, CircleShape).textured(SkinTexture.ALUMINUM, 0.16f, shape = CircleShape)
        .background(Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.35f), Color.Transparent, Color.Black.copy(alpha = 0.2f))), CircleShape)
        .border(1.dp, Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.8f), Color.Black.copy(alpha = 0.35f))), CircleShape)
}

/** A caption under a control. */
@Composable
fun Captioned(caption: String, scale: Float, onDark: Boolean = false, content: @Composable () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy((5 * scale).dp)) {
        content()
        Engraved(caption, (7.5f * scale).sp, onDark)
    }
}

/** A rest of [width] between controls. */
@Composable
fun Gap(width: Dp) = Box(Modifier.width(width))
