package dev.irwingbraga.groovelight.ui

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/** The index's letters, in the lists' order: names starting with a digit or a symbol sort first. */
private val INDEX_LETTERS = listOf("#") + ('A'..'Z').map { it.toString() }

/** The width the index takes at the right edge of a list, left free by the list's rows. */
val ALPHABET_INDEX_WIDTH = 24.dp

/** Lists shorter than this have no index: they are quick to scroll through. */
const val ALPHABET_INDEX_MINIMUM = 40

/** Where each letter starts in a sorted list: the first item filed under it ([indexLetter]), offset by rows above the items. */
fun <T> letterStarts(items: List<T>, offset: Int = 0, name: (T) -> String): Map<String, Int> {
    val starts = LinkedHashMap<String, Int>()
    items.forEachIndexed { index, item -> starts.putIfAbsent(indexLetter(name(item)), index + offset) }
    return starts
}

/**
 * The A to Z index beside long sorted lists (Artists, Songs), as in One UI's lists and on the iPhone: always there, a
 * tap or a drag along it jumps to the first item under that letter (or under the next letter that has some), with a
 * tick at each new letter and the letter shown large beside the finger. Letters with nothing under them are dimmed, and
 * a short window shows every second or third letter (a drag still reaches them all).
 */
@Composable
fun AlphabetIndex(starts: Map<String, Int>, scrollTo: suspend (Int) -> Unit, modifier: Modifier = Modifier) {
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current
    val density = LocalDensity.current
    var active by remember { mutableStateOf<String?>(null) }
    var activeY by remember { mutableFloatStateOf(0f) }
    fun jump(letter: String) {
        val from = INDEX_LETTERS.indexOf(letter)
        val target = INDEX_LETTERS.drop(from).firstNotNullOfOrNull { starts[it] } ?: starts.values.maxOrNull() ?: return
        scope.launch { scrollTo(target) }
    }
    BoxWithConstraints(modifier.fillMaxHeight().width(ALPHABET_INDEX_WIDTH)) {
        val row = 16.dp
        // Every letter where they fit, otherwise every second (or third...) one.
        val step = kotlin.math.ceil(row * INDEX_LETTERS.size / maxHeight).toInt().coerceAtLeast(1)
        val shown = INDEX_LETTERS.filterIndexed { i, _ -> i % step == 0 }
        val height = minOf(maxHeight, row * shown.size)
        val top = with(density) { ((maxHeight - height) / 2).toPx() }
        Column(
            Modifier.align(Alignment.Center).height(height).fillMaxWidth()
                .semantics { contentDescription = "Alphabet index" }
                .pointerInput(starts) {
                    fun select(y: Float) {
                        val letter = INDEX_LETTERS[(y / size.height * INDEX_LETTERS.size).toInt().coerceIn(INDEX_LETTERS.indices)]
                        activeY = y.coerceIn(0f, size.height.toFloat())
                        if (letter == active) return
                        active = letter
                        haptics.performHapticFeedback(HapticFeedbackType.SegmentTick)
                        jump(letter)
                    }
                    awaitEachGesture {
                        val down = awaitFirstDown()
                        down.consume()
                        select(down.position.y)
                        do {
                            val event = awaitPointerEvent()
                            event.changes.forEach { if (it.pressed) { select(it.position.y); it.consume() } }
                        } while (event.changes.any { it.pressed })
                        active = null
                    }
                },
            verticalArrangement = Arrangement.SpaceEvenly,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            shown.forEach { letter ->
                // With letters left out, each one shown stands for those after it too.
                val has = INDEX_LETTERS.indexOf(letter).let { from -> INDEX_LETTERS.subList(from, minOf(INDEX_LETTERS.size, from + step)) }
                    .any { it in starts }
                Text(
                    letter,
                    style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold,
                    color = if (has) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.38f),
                    modifier = Modifier.semantics { onClick("Jump to $letter") { jump(letter); true } },
                )
            }
        }
        active?.let { letter ->
            Surface(shape = CircleShape, color = MaterialTheme.colorScheme.primaryContainer,
                modifier = Modifier.align(Alignment.TopEnd).offset {
                    IntOffset(-with(density) { 48.dp.roundToPx() }, (top + activeY - with(density) { 28.dp.toPx() }).roundToInt())
                }.requiredSize(56.dp)) {
                Box(contentAlignment = Alignment.Center) {
                    Text(letter, style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.onPrimaryContainer, maxLines = 1)
                }
            }
        }
    }
}
