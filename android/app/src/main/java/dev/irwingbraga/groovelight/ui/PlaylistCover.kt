package dev.irwingbraga.groovelight.ui

import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.graphics.get
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin

// Playlist covers as the Mac draws them (App/Sources/Views/PlaylistCoverViews.swift): a generated gradient with an
// optional pattern, an image, or the songs' covers; with the playlist's name in the top left corner.

/** A diagonal two-color gradient (top left to bottom right), the Mac's `CoverPalette`. */
private class CoverPalette(val id: String, val top: Color, val bottom: Color) {
    /** How bright the top left corner is, where the title goes. */
    val titleCornerLuminance: Double get() = luma(top.red, top.green, top.blue)
}

private fun rgb(r: Double, g: Double, b: Double) = Color(r.toFloat(), g.toFloat(), b.toFloat())

private val PALETTES = listOf(
    CoverPalette("sunset", rgb(0.98, 0.58, 0.28), rgb(0.52, 0.09, 0.24)),
    CoverPalette("rose", rgb(1.00, 0.45, 0.60), rgb(0.50, 0.07, 0.25)),
    CoverPalette("grape", rgb(0.76, 0.46, 0.96), rgb(0.18, 0.05, 0.34)),
    CoverPalette("ocean", rgb(0.26, 0.56, 0.98), rgb(0.04, 0.09, 0.33)),
    CoverPalette("teal", rgb(0.36, 0.90, 0.84), rgb(0.04, 0.19, 0.29)),
    CoverPalette("forest", rgb(0.46, 0.86, 0.55), rgb(0.04, 0.24, 0.14)),
    CoverPalette("gold", rgb(0.96, 0.80, 0.34), rgb(0.38, 0.23, 0.04)),
    CoverPalette("ember", rgb(0.95, 0.35, 0.20), rgb(0.20, 0.03, 0.03)),
    CoverPalette("slate", rgb(0.74, 0.79, 0.88), rgb(0.19, 0.24, 0.34)),
    CoverPalette("midnight", rgb(0.32, 0.32, 0.48), rgb(0.03, 0.03, 0.08)),
    CoverPalette("mint", rgb(0.86, 0.98, 0.84), rgb(0.48, 0.80, 0.62)),
    CoverPalette("cream", rgb(0.99, 0.96, 0.88), rgb(0.84, 0.77, 0.66)),
)

private fun palette(id: String?) = PALETTES.firstOrNull { it.id == id } ?: PALETTES[0]

/** A stable palette for a playlist without a cover or songs (the Mac's `CoverPalette.forSeed`). */
private fun paletteFor(seed: Long) = PALETTES[java.lang.Long.remainderUnsigned(seed * 2_654_435_761L, PALETTES.size.toLong()).toInt()]

/** Rec. 709 luma of sRGB values (0 to 1), to choose black or white text. */
private fun luma(r: Float, g: Float, b: Float): Double = 0.2126 * r + 0.7152 * g + 0.0722 * b

/** What a playlist's cover is made of (from the snapshot, see [dev.irwingbraga.groovelight.library.Playlist]). */
data class PlaylistArt(
    val id: Long,
    val name: String,
    val style: String?,
    val palette: String?,
    val pattern: String?,
    /** The image of an image cover. */
    val image: File?,
    val showsTitle: Boolean,
    /** Up to four covers of its songs. */
    val songCovers: List<File>,
)

/** A playlist's art, loaded when shown (null until then). */
@Composable
fun rememberPlaylistArt(key: Any, load: suspend () -> PlaylistArt): PlaylistArt? {
    val art by produceState<PlaylistArt?>(null, key) { value = load() }
    return art
}

/** A playlist's cover as the Mac draws it, with its name unless `hideTitle` (small list icons). */
@Composable
fun PlaylistCover(art: PlaylistArt, modifier: Modifier, corner: Dp = 8.dp, hideTitle: Boolean = false) {
    val style = art.style ?: if (art.songCovers.isEmpty()) "generated" else "songs"
    BoxWithConstraints(modifier.aspectRatio(1f).clip(RoundedCornerShape(corner))) {
        val side = maxWidth
        when (style) {
            "image" -> {
                Cover(art.image ?: art.songCovers.firstOrNull(), Modifier.fillMaxSize(), corner = 0.dp)
                if (art.showsTitle && !hideTitle) CoverTitle(art.name, side, dark = rememberCornerLuminance(art.image) > 0.55)
            }
            "songs" -> {
                MosaicCover(art.songCovers, Modifier.fillMaxSize(), corner = 0.dp)
                if (!hideTitle) CoverTitle(art.name, side, dark = rememberCornerLuminance(art.songCovers.firstOrNull()) > 0.55)
            }
            else -> {
                val colors = if (art.style == null) paletteFor(art.id) else palette(art.palette)
                Box(Modifier.fillMaxSize().background(Brush.linearGradient(listOf(colors.top, colors.bottom))))
                Pattern(art.pattern)
                if (!hideTitle) CoverTitle(art.name, side, dark = colors.titleCornerLuminance > 0.55)
            }
        }
    }
}

/** The Mac's `CoverPattern`: a record, visualizer bars, a glow or waves over the gradient. */
@Composable
private fun Pattern(pattern: String?) {
    Canvas(Modifier.fillMaxSize()) {
        val side = minOf(size.width, size.height)
        when (pattern) {
            "vinyl" -> {
                val center = Offset(size.width * 0.82f, size.height * 0.82f)
                for (index in 0 until 16) {
                    drawCircle(Color.White.copy(alpha = if (index % 4 == 0) 0.16f else 0.08f), radius = side * (0.16f + index * 0.045f), center = center,
                        style = Stroke(width = side * 0.006f))
                }
                drawCircle(Color.White.copy(alpha = 0.22f), radius = side * 0.12f, center = center)
            }
            "spectrum" -> {
                val count = 14
                val gap = side * 0.012f
                val width = (size.width - gap * (count + 1)) / count
                for (index in 0 until count) {
                    val level = 0.25 + 0.55 * abs(sin(index * 1.7 + 0.6)) * (1 - index.toDouble() / count * 0.4)
                    val height = (size.height * 0.45 * level).toFloat()
                    drawRoundRect(Color.White.copy(alpha = 0.22f), topLeft = Offset(gap + index * (width + gap), size.height - height - gap),
                        size = Size(width, height), cornerRadius = CornerRadius(width * 0.25f))
                }
            }
            "glow" -> drawRect(Brush.radialGradient(listOf(Color.White.copy(alpha = 0.45f), Color.White.copy(alpha = 0f)),
                center = Offset(size.width * 0.78f, size.height * 0.8f), radius = side * 0.65f))
            "waves" -> for (index in 0 until 6) {
                val path = Path()
                val baseline = size.height * (0.55f + index * 0.075f)
                val amplitude = side * (0.05f + index * 0.006f)
                path.moveTo(0f, baseline)
                var x = 0f
                while (x <= size.width) {
                    path.lineTo(x, baseline + (sin(x / size.width * PI * 3 + index * 0.5) * amplitude).toFloat())
                    x += 2f
                }
                drawPath(path, Color.White.copy(alpha = 0.18f), style = Stroke(width = side * 0.008f))
            }
        }
    }
}

/** The name in the top left corner, sized to the cover; dark on light corners, white on dark ones. */
@Composable
private fun CoverTitle(name: String, side: Dp, dark: Boolean) {
    val size = maxOf(9f, side.value * 0.105f)
    Text(name, maxLines = 3, overflow = TextOverflow.Ellipsis,
        style = TextStyle(fontSize = size.sp, lineHeight = (size * 1.08f).sp, fontWeight = FontWeight.ExtraBold, letterSpacing = (-0.3).sp,
            color = if (dark) Color.Black.copy(alpha = 0.82f) else Color.White,
            shadow = Shadow((if (dark) Color.White else Color.Black).copy(alpha = 0.35f), blurRadius = side.value * 0.02f)),
        modifier = Modifier.fillMaxWidth(0.92f).padding(side * 0.075f))
}

private val luminance = LruCache<String, Double>(200)

/** How bright an image's top left area is (where the title goes), measured off the main thread. */
@Composable
private fun rememberCornerLuminance(file: File?): Double {
    val value by produceState(file?.let { luminance[it.path] } ?: 0.0, file?.path) {
        if (file == null) return@produceState
        value = withContext(Dispatchers.Default) {
            luminance[file.path] ?: runCatching {
                val bitmap = BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = 8 }) ?: return@runCatching 0.0
                val width = (bitmap.width * 0.6).toInt().coerceAtLeast(1)
                val height = (bitmap.height * 0.35).toInt().coerceAtLeast(1)
                var total = 0.0
                var count = 0
                for (y in 0 until height step maxOf(1, height / 24)) for (x in 0 until width step maxOf(1, width / 24)) {
                    val pixel = bitmap[x, y]
                    total += luma(((pixel shr 16) and 0xFF) / 255f, ((pixel shr 8) and 0xFF) / 255f, (pixel and 0xFF) / 255f)
                    count++
                }
                bitmap.recycle()
                total / count.coerceAtLeast(1)
            }.getOrDefault(0.0).also { luminance.put(file.path, it) }
        }
    }
    return value
}
