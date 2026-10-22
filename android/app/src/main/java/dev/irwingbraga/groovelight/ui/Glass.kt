package dev.irwingbraga.groovelight.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.HazeStyle
import dev.chrisbanes.haze.HazeTint
import dev.chrisbanes.haze.hazeEffect
import dev.chrisbanes.haze.hazeSource
import dev.chrisbanes.haze.rememberHazeState

/** The height of a glass bar over the top of the screen: lists start below it and scroll on behind it. */
val LocalTopInset = compositionLocalOf { 0.dp }

/**
 * Frosted glass for the bars: what scrolls behind is blurred and tinted with the theme's surface. The tint is denser
 * in the light theme, where a bright, saturated cover behind would otherwise leave dark icons and labels unreadable.
 */
@Composable
fun glassStyle(): HazeStyle {
    val scheme = MaterialTheme.colorScheme
    val light = scheme.surface.luminance() > 0.5f
    return HazeStyle(backgroundColor = scheme.surface, tint = HazeTint(scheme.surfaceContainer.copy(alpha = if (light) 0.84f else 0.66f)),
        blurRadius = 28.dp, noiseFactor = 0.08f)
}

/**
 * A glass bar over `haze`'s content, with a hairline on the edge facing the content (`edgeOnTop` for a bar at the
 * bottom of the screen). `visible` fades the glass (pages show it once their header has scrolled away). The bar's height is
 * reported to `onHeight`.
 */
@Composable
fun Modifier.glass(haze: HazeState, edgeOnTop: Boolean, visible: Boolean = true, onHeight: (Dp) -> Unit = {}): Modifier {
    val density = LocalDensity.current
    val style = glassStyle()
    val alpha by animateFloatAsState(if (visible) 1f else 0f, label = "glass")
    val edge = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f)
    return this.fillMaxWidth()
        .hazeEffect(haze, style) { this.alpha = alpha }
        .drawBehind {
            val y = if (edgeOnTop) 0f else size.height
            drawLine(edge.copy(alpha = edge.alpha * alpha), Offset(0f, y), Offset(size.width, y), strokeWidth = 1.dp.toPx())
        }
        .onSizeChanged { onHeight(with(density) { it.height.toDp() }) }
}

/**
 * A screen whose `bar` floats over its content as glass: the content fills the screen and scrolls on behind the bar,
 * and gets the bar's height as [LocalTopInset] to start its lists below it. `glassVisible` false keeps the bar clear
 * (over a page's header) until the page scrolls. `modifier` is the content's (a background is blurred with it).
 */
@Composable
fun GlassTop(bar: @Composable () -> Unit, modifier: Modifier = Modifier, glassVisible: Boolean = true, content: @Composable BoxScope.() -> Unit) {
    val haze = rememberHazeState()
    var height by remember { mutableStateOf(0.dp) }
    Box(Modifier.fillMaxSize()) {
        CompositionLocalProvider(LocalTopInset provides height) {
            Box(modifier.fillMaxSize().hazeSource(haze), content = content)
        }
        Box(Modifier.align(Alignment.TopCenter).glass(haze, edgeOnTop = false, visible = glassVisible) { height = it }) { bar() }
    }
}
