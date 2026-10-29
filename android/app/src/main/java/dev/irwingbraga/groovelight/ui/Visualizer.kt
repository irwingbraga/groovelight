package dev.irwingbraga.groovelight.ui

import android.graphics.RuntimeShader
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.irwingbraga.groovelight.playback.AudioTap
import kotlinx.coroutines.delay
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * The music's spectrum, as the visualizers draw it: an FFT of the latest audible samples ([AudioTap]), in [BANDS]
 * log-spaced bands from 40 Hz to 16 kHz (rising fast, falling slowly, with peaks that fall after a moment), the
 * waveform, and the bass, mids and treble levels with a beat that kicks on sudden bass.
 */
class Spectrum {
    val bands = FloatArray(BANDS)
    val peaks = FloatArray(BANDS)
    val wave = FloatArray(512)
    var bass = 0f; private set
    var mid = 0f; private set
    var treble = 0f; private set
    /** 1 on a beat, fading to 0. */
    var beat = 0f; private set
    /** Whether music is playing (the tap gave samples this frame). */
    var live = false; private set

    private val samples = FloatArray(SIZE)
    private val real = FloatArray(SIZE)
    private val imaginary = FloatArray(SIZE)
    private val window = FloatArray(SIZE) { (0.5 - 0.5 * cos(2 * PI * it / (SIZE - 1))).toFloat() }
    private val peakHold = IntArray(BANDS)
    private var bassAverage = 0f

    fun update() {
        live = AudioTap.read(samples)
        if (!live) {
            // Silence: everything falls.
            for (i in bands.indices) { bands[i] *= 0.9f; peaks[i] = max(0f, peaks[i] - 0.01f) }
            wave.fill(0f)
            bass *= 0.9f; mid *= 0.9f; treble *= 0.9f; beat *= 0.9f
            return
        }
        val step = SIZE / wave.size
        for (i in wave.indices) wave[i] = samples[SIZE - wave.size * step / 2 + i * step / 2 - 1].coerceIn(-1f, 1f)
        for (i in 0 until SIZE) { real[i] = samples[i] * window[i]; imaginary[i] = 0f }
        fft(real, imaginary)
        val rate = AudioTap.sampleRate.toFloat()
        val binHz = rate / SIZE
        for (band in 0 until BANDS) {
            val low = 40f * (16_000f / 40f).pow(band.toFloat() / BANDS)
            val high = 40f * (16_000f / 40f).pow((band + 1f) / BANDS)
            val from = (low / binHz).toInt().coerceIn(1, SIZE / 2 - 1)
            val to = (high / binHz).toInt().coerceIn(from + 1, SIZE / 2)
            var energy = 0f
            for (bin in from until to) energy = max(energy, sqrt(real[bin] * real[bin] + imaginary[bin] * imaginary[bin]))
            // dB, from -60 (silent) to 0 (loud), as 0 to 1; higher bands lifted a little (music has less there).
            val db = 20 * ln(max(energy / (SIZE / 4f), 1e-6f)) / ln(10f) + 6f * band / BANDS
            val level = ((db + 60f) / 60f).coerceIn(0f, 1f)
            bands[band] = if (level > bands[band]) bands[band] + (level - bands[band]) * 0.6f else bands[band] * 0.86f + level * 0.14f
            if (bands[band] >= peaks[band]) { peaks[band] = bands[band]; peakHold[band] = 20 }
            else if (peakHold[band] > 0) peakHold[band]--
            else peaks[band] = max(bands[band], peaks[band] - 0.012f)
        }
        // Square roots lift the averages: a few loud bands (a voice, a bass line) should show as much as a full spectrum.
        val newBass = sqrt(bands.copyOfRange(0, BANDS / 6).average().toFloat())
        mid = sqrt(bands.copyOfRange(BANDS / 6, BANDS * 2 / 3).average().toFloat())
        treble = sqrt(bands.copyOfRange(BANDS * 2 / 3, BANDS).average().toFloat())
        // A beat: bass well over its recent average.
        if (newBass > bassAverage * 1.2f && newBass > 0.55f && beat < 0.4f) beat = 1f else beat *= 0.88f
        bassAverage = bassAverage * 0.95f + newBass * 0.05f
        bass = newBass
    }

    companion object {
        const val SIZE = 2048
        const val BANDS = 48

        /** In-place radix-2 FFT. */
        fun fft(re: FloatArray, im: FloatArray) {
            val n = re.size
            var j = 0
            for (i in 1 until n) {
                var bit = n shr 1
                while (j and bit != 0) { j = j xor bit; bit = bit shr 1 }
                j = j xor bit
                if (i < j) {
                    var t = re[i]; re[i] = re[j]; re[j] = t
                    t = im[i]; im[i] = im[j]; im[j] = t
                }
            }
            var length = 2
            while (length <= n) {
                val angle = -2 * PI / length
                val wr = cos(angle).toFloat()
                val wi = sin(angle).toFloat()
                var start = 0
                while (start < n) {
                    var cr = 1f
                    var ci = 0f
                    for (k in 0 until length / 2) {
                        val a = start + k
                        val b = a + length / 2
                        val tr = re[b] * cr - im[b] * ci
                        val ti = re[b] * ci + im[b] * cr
                        re[b] = re[a] - tr; im[b] = im[a] - ti
                        re[a] += tr; im[a] += ti
                        val next = cr * wr - ci * wi
                        ci = cr * wi + ci * wr
                        cr = next
                    }
                    start += length
                }
                length = length shl 1
            }
        }
    }
}

/** The visualizers: two drawn with Canvas, two with AGSL shaders (Android 13 and later). */
enum class VisualizerStyle(val label: String, val shader: Boolean = false) {
    BARS("Bars"), WAVES("Waves"), LIGHTS("Lights", shader = true), TUNNEL("Tunnel", shader = true);

    companion object {
        val available: List<VisualizerStyle> get() = entries.filter { !it.shader || Build.VERSION.SDK_INT >= 33 }
    }
}

/**
 * The visualizer, full screen over Now Playing (as iTunes' was): the style in the song's colors. Swiping sideways
 * changes the style, tapping shows the song and the style's name for a moment, Back closes it. The screen stays on.
 */
@Composable
fun Visualizer(title: String, artist: String?, accent: Color, onClose: () -> Unit) {
    val styles = remember { VisualizerStyle.available }
    var index by rememberSaveable { mutableStateOf(0) }
    val style = styles[index.mod(styles.size)]
    val spectrum = remember { Spectrum() }
    var frame by remember { mutableLongStateOf(0L) }
    var started by remember { mutableLongStateOf(0L) }
    var overlay by remember { mutableStateOf(true) }
    val view = LocalView.current
    BackHandler(onBack = onClose)
    DisposableEffect(Unit) {
        AudioTap.start()
        view.keepScreenOn = true
        onDispose {
            AudioTap.stop()
            view.keepScreenOn = false
        }
    }
    LaunchedEffect(Unit) {
        while (true) withFrameNanos { now ->
            if (started == 0L) started = now
            spectrum.update()
            frame = now - started
        }
    }
    LaunchedEffect(overlay, index) { if (overlay) { delay(3_000); overlay = false } }
    val colors = remember(accent) { palette(accent) }
    Box(
        Modifier.fillMaxSize().background(Color.Black)
            .pointerInput(styles.size) {
                var dragged = 0f
                detectHorizontalDragGestures(onDragStart = { dragged = 0f }, onDragEnd = {
                    if (abs(dragged) > 80.dp.toPx()) index += if (dragged < 0) 1 else -1
                    overlay = true
                }) { _, amount -> dragged += amount }
            }
            .pointerInput(Unit) { detectTapGestures { overlay = !overlay } }
            .semantics { contentDescription = "${style.label} visualizer. Swipe sideways to change it." },
    ) {
        val time = frame / 1_000_000_000f
        when (style) {
            VisualizerStyle.BARS -> Bars(spectrum, colors, frame)
            VisualizerStyle.WAVES -> Waves(spectrum, colors, frame)
            VisualizerStyle.LIGHTS, VisualizerStyle.TUNNEL -> if (Build.VERSION.SDK_INT >= 33) ShaderStyle(style, spectrum, colors, time)
        }
        AnimatedVisibility(overlay, enter = fadeIn(), exit = fadeOut(), modifier = Modifier.align(Alignment.BottomStart)) {
            Column(Modifier.safeDrawingPadding().padding(24.dp)) {
                Text(title, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 22.sp)
                artist?.let { Text(it, color = Color.White.copy(alpha = 0.7f), fontSize = 16.sp) }
                Text("${style.label} · swipe for another", color = Color.White.copy(alpha = 0.5f), fontSize = 13.sp,
                    modifier = Modifier.padding(top = 8.dp))
            }
        }
    }
}

/** Three colors from the song's accent: itself, its hue turned a third, and two thirds. */
private fun palette(accent: Color): List<Color> {
    val hsv = FloatArray(3)
    android.graphics.Color.colorToHSV(accent.toArgb(), hsv)
    return listOf(0f, 120f, 240f).map { turn ->
        Color(android.graphics.Color.HSVToColor(floatArrayOf((hsv[0] + turn) % 360f, max(hsv[1], 0.55f), max(hsv[2], 0.85f))))
    }
}

/** The spectrum as bars with peak caps (Windows Media Player's), in the song's colors from bass to treble. */
@Composable
private fun Bars(spectrum: Spectrum, colors: List<Color>, frame: Long) {
    Canvas(Modifier.fillMaxSize().safeDrawingPadding().padding(16.dp)) {
        frame.hashCode()
        val count = Spectrum.BANDS
        val gap = size.width / count * 0.2f
        val width = size.width / count - gap
        val brush = Brush.verticalGradient(listOf(colors[0], colors[1], colors[2]), startY = size.height * 0.2f, endY = size.height)
        for (band in 0 until count) {
            val x = band * (width + gap) + gap / 2
            val height = spectrum.bands[band] * size.height * 0.85f
            drawRoundRect(brush, Offset(x, size.height - height), Size(width, height), CornerRadius(width / 4))
            // The peak cap, over bands that sound only.
            if (spectrum.peaks[band] > 0.02f) {
                val peak = size.height - spectrum.peaks[band] * size.height * 0.85f - 6.dp.toPx()
                drawRoundRect(Color.White.copy(alpha = 0.85f), Offset(x, peak), Size(width, 3.dp.toPx()), CornerRadius(2f))
            }
        }
    }
}

/** The waveform as an oscilloscope, glowing, with the spectrum's energy widening it. */
@Composable
private fun Waves(spectrum: Spectrum, colors: List<Color>, frame: Long) {
    Canvas(Modifier.fillMaxSize()) {
        frame.hashCode()
        val middle = size.height / 2
        val gain = size.height * (0.25f + spectrum.bass * 0.2f)
        listOf(Triple(colors[2], 18.dp.toPx(), 0.15f), Triple(colors[1], 8.dp.toPx(), 0.35f), Triple(colors[0], 3.dp.toPx(), 1f))
            .forEach { (color, width, alpha) ->
                val path = Path()
                spectrum.wave.forEachIndexed { i, value ->
                    val x = i * size.width / (spectrum.wave.size - 1)
                    val y = middle - value * gain
                    if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
                }
                drawPath(path, color.copy(alpha = alpha), style = Stroke(width = width, cap = StrokeCap.Round))
            }
    }
}

/** Lights and Tunnel: AGSL fragment shaders fed the time, the bass, mids and treble, the beat and the colors. */
@androidx.annotation.RequiresApi(33)
@Composable
private fun ShaderStyle(style: VisualizerStyle, spectrum: Spectrum, colors: List<Color>, time: Float) {
    val shader = remember(style) { RuntimeShader(if (style == VisualizerStyle.LIGHTS) LIGHTS else TUNNEL) }
    Canvas(Modifier.fillMaxSize()) {
        shader.setFloatUniform("resolution", size.width, size.height)
        shader.setFloatUniform("time", time)
        shader.setFloatUniform("levels", spectrum.bass, spectrum.mid, spectrum.treble, spectrum.beat)
        colors.forEachIndexed { i, color -> shader.setFloatUniform("color$i", color.red, color.green, color.blue) }
        drawRect(ShaderBrush(shader))
    }
}

/** iTunes 4 "Lights": soft blobs of the song's colors drifting, swelling with the bass, mids and treble. */
private const val LIGHTS = """
uniform float2 resolution;
uniform float time;
uniform float4 levels;
uniform float3 color0;
uniform float3 color1;
uniform float3 color2;

float blob(float2 p, float2 c, float r) {
    float d = length(p - c);
    return r * r / (d * d + 0.0004);
}

half4 main(float2 fragCoord) {
    float2 p = (fragCoord - 0.5 * resolution) / min(resolution.x, resolution.y);
    float t = time * 0.4;
    float3 sum = float3(0.0);
    for (int i = 0; i < 6; i++) {
        float k = float(i);
        float level = i < 2 ? levels.x : (i < 4 ? levels.y : levels.z);
        float2 c = 0.45 * float2(sin(t * (0.7 + 0.13 * k) + k * 1.7), cos(t * (0.5 + 0.11 * k) + k * 2.3));
        float3 col = i < 2 ? color0 : (i < 4 ? color1 : color2);
        sum += col * blob(p, c, 0.05 + 0.12 * level + 0.05 * levels.w);
    }
    float3 rgb = 1.0 - exp(-sum * 0.08);
    return half4(half3(rgb), 1.0);
}
"""

/** A tunnel of rings rushing out, faster and brighter with the music, flashing on the beat. */
private const val TUNNEL = """
uniform float2 resolution;
uniform float time;
uniform float4 levels;
uniform float3 color0;
uniform float3 color1;
uniform float3 color2;

half4 main(float2 fragCoord) {
    float2 p = (fragCoord - 0.5 * resolution) / min(resolution.x, resolution.y);
    float r = length(p) + 0.0001;
    float a = atan(p.y, p.x);
    float depth = 0.25 / r + time * (0.6 + 1.6 * levels.x);
    float rings = 0.5 + 0.5 * sin(depth * 6.2831 * 1.5);
    float spokes = 0.5 + 0.5 * sin(a * 8.0 + depth * 2.0 + levels.y * 3.0);
    float glow = pow(rings, 6.0 - 4.0 * levels.y) * (0.6 + 0.4 * spokes);
    float3 col = mix(color0, color1, 0.5 + 0.5 * sin(depth * 0.7));
    col = mix(col, color2, levels.z * 0.6);
    float fade = smoothstep(0.0, 0.35, r);
    float3 rgb = col * glow * fade * (0.5 + levels.x) + col * levels.w * 0.35 * (1.0 - r);
    return half4(half3(clamp(rgb, 0.0, 1.0)), 1.0);
}
"""
