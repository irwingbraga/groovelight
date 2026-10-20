package dev.irwingbraga.groovelight.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.calculateTargetValue
import androidx.compose.animation.core.exponentialDecay
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.irwingbraga.groovelight.R
import dev.irwingbraga.groovelight.library.Album
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.absoluteValue
import kotlin.math.roundToInt
import kotlin.math.sign

/**
 * The Shelf: every album as a cover in a row, as Cover Flow on the first iPod touch and on the Mac. Drag or fling
 * through them (the side covers turn away), tap the center one to flip it over to its songs, or use the scrubber
 * below for a long library. Always dark, as on the Mac.
 */
@Composable
fun ShelfScreen() {
    val actions = LocalActions.current
    val albums by actions.library.albums.collectAsStateWithLifecycle()
    val all = albums ?: return Loading()
    val scheme = darkColorScheme(primary = Color(0xFFB4C5FF), background = Color.Black, surface = Color.Black)
    MaterialTheme(colorScheme = scheme, typography = MaterialTheme.typography) {
        CompositionLocalProvider(androidx.compose.material3.LocalContentColor provides Color.White) {
            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFF0B0D14), Color.Black)))) {
                if (all.isEmpty()) {
                    EmptyState(R.drawable.ic_shelf, "Nothing on the shelf yet", "Albums appear here after a sync.",
                        Modifier.padding(bottom = LocalBottomInset.current))
                } else Shelf(all)
            }
        }
    }
}

@Composable
private fun Shelf(albums: List<Album>) {
    val actions = LocalActions.current
    val scope = rememberCoroutineScope()
    var saved by rememberSaveable { mutableStateOf(0f) }
    val position = remember { Animatable(saved.coerceIn(0f, (albums.size - 1).toFloat())) }
    var flipped by rememberSaveable { mutableStateOf<String?>(null) }
    val focus = remember { FocusRequester() }
    LaunchedEffect(albums.size) { if (position.value > albums.size - 1) position.snapTo((albums.size - 1).toFloat()) }
    LaunchedEffect(Unit) { snapshotFlow { position.value }.collect { saved = it } }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
    val center = position.value.roundToInt().coerceIn(albums.indices)
    val current = albums[center]
    fun goTo(index: Int) {
        flipped = null
        scope.launch { position.animateTo(index.coerceIn(albums.indices).toFloat(), spring(dampingRatio = 0.9f, stiffness = 400f)) }
    }

    Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.statusBars).padding(bottom = LocalBottomInset.current)
        .focusRequester(focus).focusable()
        // A keyboard, a remote or a player's buttons: left and right move, Enter flips.
        .onPreviewKeyEvent { event ->
            if (event.type != KeyEventType.KeyDown) return@onPreviewKeyEvent false
            when (event.key) {
                Key.DirectionLeft -> { goTo(center - 1); true }
                Key.DirectionRight -> { goTo(center + 1); true }
                Key.Enter, Key.DirectionCenter -> { flipped = if (flipped == current.key) null else current.key; true }
                else -> false
            }
        }) {
        BoxWithConstraints(Modifier.weight(1f).fillMaxWidth()) {
            val density = LocalDensity.current
            val coverSize = minOf(maxWidth * 0.62f, maxHeight * 0.62f, 360.dp)
            val coverPx = with(density) { coverSize.toPx() }
            // Center cover to the first side cover, then side covers to each other (stacked close, as Cover Flow); wider
            // screens spread them out.
            val widthPx = with(density) { maxWidth.toPx() }
            val nearStep = maxOf(coverPx * 0.72f, widthPx * 0.24f)
            val farStep = maxOf(coverPx * 0.22f, widthPx * 0.05f)
            Box(
                Modifier.fillMaxSize().semantics {
                    contentDescription = "Shelf: ${current.title} by ${current.artist}, album ${center + 1} of ${albums.size}"
                    customActions = listOf(
                        CustomAccessibilityAction("Previous album") { goTo(center - 1); true },
                        CustomAccessibilityAction("Next album") { goTo(center + 1); true },
                        CustomAccessibilityAction("Open album") { actions.open(Route.AlbumPage(current.key)); true },
                    )
                }.pointerInput(albums.size) {
                    val tracker = VelocityTracker()
                    detectHorizontalDragGestures(
                        onDragStart = { tracker.resetTracking(); flipped = null },
                        onDragEnd = {
                            val velocity = -tracker.calculateVelocity().x / nearStep
                            scope.launch {
                                // Fling: where the covers would coast to, then the nearest one.
                                val target = exponentialDecay<Float>(frictionMultiplier = 2f).calculateTargetValue(position.value, velocity)
                                position.animateTo(target.roundToInt().coerceIn(albums.indices).toFloat(),
                                    spring(dampingRatio = 0.9f, stiffness = 120f), initialVelocity = velocity)
                            }
                        },
                        onDragCancel = { scope.launch { position.animateTo(position.value.roundToInt().toFloat()) } },
                    ) { change, amount ->
                        tracker.addPosition(change.uptimeMillis, change.position)
                        change.consume()
                        scope.launch { position.snapTo((position.value - amount / nearStep).coerceIn(0f, (albums.size - 1).toFloat())) }
                    }
                }.pointerInput(center, flipped) {
                    detectTapGestures { offset ->
                        // A tap on the center cover flips it; on a side cover, brings it to the center.
                        val dx = offset.x - size.width / 2f
                        if (abs(dx) < coverPx / 2) flipped = if (flipped == current.key) null else current.key
                        else goTo(center + (if (dx > 0) 1 else -1) * (1 + ((abs(dx) - coverPx / 2) / farStep / 2).toInt()).coerceAtMost(6))
                    }
                },
                contentAlignment = Alignment.Center,
            ) {
                val from = (position.value - 7).toInt().coerceAtLeast(0)
                val to = (position.value + 7).toInt().coerceAtMost(albums.size - 1)
                for (index in from..to) {
                    val album = albums[index]
                    val d = index - position.value
                    val near = d.coerceIn(-1f, 1f)
                    val x = if (abs(d) <= 1) d * nearStep else d.sign * (nearStep + (abs(d) - 1) * farStep)
                    key(album.key) {
                        ShelfCover(
                            album, coverSize,
                            rotation = -near * 62f,
                            scale = 1f - 0.12f * near.absoluteValue,
                            flipped = flipped == album.key && index == center,
                            modifier = Modifier.offset { IntOffset(x.roundToInt(), 0) }.zIndex(-abs(d)),
                        )
                    }
                }
            }
        }
        // The album at the center, and a scrubber for long libraries.
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Text(current.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1,
                overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center,
                modifier = Modifier.clip(RoundedCornerShape(4.dp)).clickable(onClickLabel = "Open album") { actions.open(Route.AlbumPage(current.key)) })
            Text(current.artist, style = MaterialTheme.typography.bodyMedium, color = Color.White.copy(alpha = 0.65f), maxLines = 1,
                overflow = TextOverflow.Ellipsis)
            if (albums.size > 1) {
                Slider(
                    value = position.value, valueRange = 0f..(albums.size - 1).toFloat(),
                    onValueChange = { value -> flipped = null; scope.launch { position.snapTo(value) } },
                    onValueChangeFinished = { goTo(position.value.roundToInt()) },
                    colors = SliderDefaults.colors(thumbColor = Color.White, activeTrackColor = Color.White.copy(alpha = 0.6f),
                        inactiveTrackColor = Color.White.copy(alpha = 0.18f)),
                    modifier = Modifier.padding(top = 8.dp).semantics { contentDescription = "Scroll the shelf" },
                )
            } else Spacer(Modifier.height(16.dp))
        }
    }
}

/** A cover on the shelf, turned by `rotation` degrees, with its reflection; flipped, its songs on the back. */
@Composable
private fun ShelfCover(album: Album, size: androidx.compose.ui.unit.Dp, rotation: Float, scale: Float, flipped: Boolean, modifier: Modifier) {
    val actions = LocalActions.current
    val turn = remember { Animatable(0f) }
    LaunchedEffect(flipped) { turn.animateTo(if (flipped) 180f else 0f, tween(450)) }
    val showsBack = turn.value > 90f
    val cover = actions.library.cover(album.artworkHash)
    Column(modifier.graphicsLayer {
        rotationY = rotation + turn.value
        scaleX = scale
        scaleY = scale
        cameraDistance = 14 * density
        transformOrigin = TransformOrigin.Center
    }) {
        Box(Modifier.size(size)) {
            if (showsBack) {
                // The back, turned so it reads the right way.
                Box(Modifier.fillMaxSize().graphicsLayer { rotationY = 180f }) { ShelfBack(album) }
            } else {
                Cover(cover, Modifier.fillMaxSize(), corner = 2.dp)
            }
        }
        // The reflection (its place kept while flipped, so the cover does not move): the cover upside down, fading
        // into the floor.
        if (showsBack) Spacer(Modifier.size(size, size * 0.35f)) else {
            // The cover's bottom shows at the top of the clip once turned over; the mask (drawn before the turn) keeps its
            // bottom third, faint, and fades it out.
            Box(Modifier.size(size, size * 0.35f).clipToBounds()) {
                Cover(cover, Modifier.wrapContentSize(Alignment.TopCenter, unbounded = true).requiredSize(size).graphicsLayer {
                    scaleY = -1f
                    compositingStrategy = CompositingStrategy.Offscreen
                }.drawWithContent {
                    drawContent()
                    drawRect(Brush.verticalGradient(0f to Color.Transparent, 0.65f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.32f)),
                        blendMode = BlendMode.DstIn)
                }, corner = 2.dp)
            }
        }
    }
}

/** The back of a flipped cover: the album's songs, tap one to play the album from it. */
@Composable
private fun ShelfBack(album: Album) {
    val actions = LocalActions.current
    val tracks by remember(album.key) { actions.library.tracksOfAlbum(album.key) }.collectAsStateWithLifecycle(emptyList())
    val nowPlaying = LocalNowPlaying.current
    Column(Modifier.fillMaxSize().clip(RoundedCornerShape(2.dp)).background(Color(0xFF1B1E27))) {
        Row(Modifier.fillMaxWidth().padding(start = 12.dp, top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(album.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(album.artist, style = MaterialTheme.typography.bodySmall, color = Color.White.copy(alpha = 0.6f), maxLines = 1,
                    overflow = TextOverflow.Ellipsis)
            }
            IconButton(onClick = { actions.open(Route.AlbumPage(album.key)) }) {
                Icon(painterResource(R.drawable.ic_album), contentDescription = "Open album")
            }
        }
        LazyColumn(contentPadding = PaddingValues(bottom = 8.dp)) {
            itemsIndexed(tracks, key = { _, track -> track.id }) { index, track ->
                val playing = nowPlaying?.id == track.id
                Row(Modifier.fillMaxWidth().clickable {
                    actions.player.play(actions.library.mediaItems(tracks, "Album · ${album.title}"), index, null)
                }.padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.width(24.dp)) {
                        if (playing) PlayingBars(nowPlaying?.isPlaying == true, Modifier.size(14.dp))
                        else Text(track.trackNumber?.toString() ?: "", style = MaterialTheme.typography.bodySmall, color = Color.White.copy(alpha = 0.5f))
                    }
                    Text(track.title, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        color = if (playing) MaterialTheme.colorScheme.primary else Color.White, modifier = Modifier.weight(1f))
                    Text(duration(track.durationMs), style = MaterialTheme.typography.bodySmall, color = Color.White.copy(alpha = 0.5f))
                }
            }
        }
    }
}
