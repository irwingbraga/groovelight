package dev.irwingbraga.groovelight.ui

import android.graphics.BitmapFactory
import android.util.LruCache
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.graphics.Color
import androidx.core.graphics.ColorUtils
import androidx.palette.graphics.Palette
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Colors taken from a cover, as Groovelight's cover wash on the Mac: a deep `background` that white text reads on, and
 * a light `accent` for controls on it.
 */
@Immutable
data class ArtworkColors(val background: Color, val accent: Color)

private val cache = LruCache<String, ArtworkColors>(100)

/** The cover's colors, worked out off the main thread (null until known, or without a cover). */
@Composable
fun rememberArtworkColors(file: File?): ArtworkColors? {
    val colors by produceState(file?.let { cache[it.path] }, file?.path) {
        value = file?.let { withContext(Dispatchers.Default) { artworkColors(it) } }
    }
    return colors
}

fun artworkColors(file: File): ArtworkColors? {
    cache[file.path]?.let { return it }
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(file.path, bounds)
    var sample = 1
    while (bounds.outWidth / (sample * 2) >= 96 && bounds.outHeight / (sample * 2) >= 96) sample *= 2
    val bitmap = BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return null
    val palette = Palette.from(bitmap).maximumColorCount(16).generate()
    bitmap.recycle()
    val base = (palette.darkVibrantSwatch ?: palette.dominantSwatch ?: palette.darkMutedSwatch ?: return null).rgb
    val accentBase = (palette.lightVibrantSwatch ?: palette.vibrantSwatch ?: palette.lightMutedSwatch ?: palette.dominantSwatch)?.rgb ?: base
    val colors = ArtworkColors(background = Color(tone(base, maxLightness = 0.22f, maxSaturation = 0.6f)),
        accent = Color(tone(accentBase, minLightness = 0.72f)))
    cache.put(file.path, colors)
    return colors
}

/** The color with its lightness (and saturation) kept within bounds, so text and controls stay readable. */
private fun tone(rgb: Int, minLightness: Float = 0f, maxLightness: Float = 1f, maxSaturation: Float = 1f): Int {
    val hsl = FloatArray(3)
    ColorUtils.colorToHSL(rgb, hsl)
    hsl[1] = hsl[1].coerceAtMost(maxSaturation)
    hsl[2] = hsl[2].coerceIn(minLightness, maxLightness)
    return ColorUtils.HSLToColor(hsl)
}
