package dev.irwingbraga.groovelight.ui

import android.app.Activity
import android.content.res.Configuration
import androidx.activity.compose.PredictiveBackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.basicMarquee
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsDraggedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.IconToggleButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.media3.common.Player
import coil3.compose.AsyncImage
import dev.irwingbraga.groovelight.R
import dev.irwingbraga.groovelight.library.Track
import dev.irwingbraga.groovelight.playback.AudioPath
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.flowOf
import java.io.File

private enum class Panel { COVER, LYRICS, QUEUE }

/**
 * Now Playing, over everything: the cover (or the lyrics, or Up Next) on the colors of the cover, the song, the seek
 * bar and the controls. Swipe down or Back (with the predictive gesture) closes it. In landscape, the cover sits beside
 * the controls.
 */
@Composable
fun NowPlaying(visible: Boolean, player: PlayerModel, onClose: () -> Unit) {
    var backProgress by remember { mutableFloatStateOf(0f) }
    var dragOffset by remember { mutableFloatStateOf(0f) }
    PredictiveBackHandler(enabled = visible) { events ->
        try {
            events.collect { backProgress = it.progress }
            onClose()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } finally {
            backProgress = 0f
        }
    }
    val offset by animateFloatAsState(dragOffset, if (dragOffset == 0f) spring() else tween(0), label = "drag")
    AnimatedVisibility(visible, enter = slideInVertically(tween(320)) { it } + fadeIn(), exit = slideOutVertically(tween(260)) { it } + fadeOut()) {
        val song = LocalNowPlaying.current ?: return@AnimatedVisibility
        val density = LocalDensity.current
        val dismiss = rememberDraggableState { delta -> dragOffset = (dragOffset + delta).coerceAtLeast(0f) }
        Box(
            Modifier.fillMaxSize()
                .graphicsLayer {
                    val scale = 1f - backProgress * 0.08f
                    scaleX = scale
                    scaleY = scale
                    translationY = offset
                    shape = RoundedCornerShape((backProgress * 32).dp)
                    clip = backProgress > 0f || offset > 0f
                }
                .draggable(dismiss, Orientation.Vertical, onDragStopped = { velocity ->
                    if (dragOffset > with(density) { 140.dp.toPx() } || velocity > 2_000f) onClose()
                    dragOffset = 0f
                }),
        ) {
            NowPlayingContent(song, player, onClose)
        }
    }
}

@Composable
private fun NowPlayingContent(song: PlayerModel.NowPlaying, player: PlayerModel, onClose: () -> Unit) {
    val cover = song.artwork?.path?.let(::File)
    val colors = rememberArtworkColors(cover)
    val background by animateColorAsState(colors?.background ?: Color(0xFF151A2C), tween(600), label = "background")
    val accent by animateColorAsState(colors?.accent ?: Color(0xFFB4C5FF), tween(600), label = "accent")
    val scheme = darkColorScheme(
        primary = accent, onPrimary = background, surface = background, onSurface = Color.White,
        onSurfaceVariant = Color.White.copy(alpha = 0.7f), surfaceContainerHigh = Color.White.copy(alpha = 0.12f),
        secondaryContainer = Color.White.copy(alpha = 0.16f), onSecondaryContainer = Color.White,
        outlineVariant = Color.White.copy(alpha = 0.2f), surfaceContainerHighest = Color.White.copy(alpha = 0.1f),
    )
    // Light status bar icons over the dark wash while open.
    val view = LocalView.current
    DisposableEffect(view) {
        val window = (view.context as? Activity)?.window
        val controller = window?.let { WindowCompat.getInsetsController(it, view) }
        val light = controller?.isAppearanceLightStatusBars
        controller?.isAppearanceLightStatusBars = false
        controller?.isAppearanceLightNavigationBars = false
        onDispose {
            if (light != null) {
                controller.isAppearanceLightStatusBars = light
                controller.isAppearanceLightNavigationBars = light
            }
        }
    }
    MaterialTheme(colorScheme = scheme, typography = MaterialTheme.typography) {
        Box(Modifier.fillMaxSize().background(background)) {
          CompositionLocalProvider(LocalContentColor provides Color.White) {
            CoverWash(cover, background)
            var panel by rememberSaveable { mutableStateOf(Panel.COVER) }
            var details by rememberSaveable { mutableStateOf(false) }
            val landscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE
            Column(Modifier.fillMaxSize().safeDrawingPadding()) {
                TopRow(song, onClose, onDetails = { details = true })
                if (landscape) {
                    Row(Modifier.fillMaxSize().padding(horizontal = 24.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(32.dp)) {
                        Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.Center) { PanelContent(panel, song, player, cover) }
                        Column(Modifier.weight(1f).fillMaxHeight(), verticalArrangement = Arrangement.Center) {
                            Controls(song, player, panel, onPanel = { panel = if (panel == it) Panel.COVER else it }, onDetails = { details = true })
                        }
                    }
                } else {
                    Box(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 24.dp), contentAlignment = Alignment.Center) {
                        PanelContent(panel, song, player, cover)
                    }
                    Column(Modifier.padding(horizontal = 24.dp).padding(bottom = 12.dp)) {
                        Controls(song, player, panel, onPanel = { panel = if (panel == it) Panel.COVER else it }, onDetails = { details = true })
                    }
                }
            }
            if (details) AudioDetails(song, player) { details = false }
          }
        }
    }
}

/** The cover, blurred and darkened, behind everything: Groovelight's cover wash. */
@Composable
private fun BoxScope.CoverWash(cover: File?, background: Color) {
    if (cover != null) {
        AsyncImage(model = cover, contentDescription = null, contentScale = ContentScale.Crop,
            modifier = Modifier.matchParentSize().graphicsLayer { alpha = 0.4f }.blur(80.dp))
    }
    Box(Modifier.matchParentSize().background(Brush.verticalGradient(listOf(background.copy(alpha = 0.5f), background.copy(alpha = 0.85f), background))))
}

@Composable
private fun TopRow(song: PlayerModel.NowPlaying, onClose: () -> Unit, onDetails: () -> Unit) {
    val actions = LocalActions.current
    var menu by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onClose) { Icon(painterResource(R.drawable.ic_expand_more), contentDescription = "Close Now Playing") }
        Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
            song.source?.let { source ->
                Text("PLAYING FROM", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(source, style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        Box {
            IconButton(onClick = { menu = true }) { Icon(painterResource(R.drawable.ic_more), contentDescription = "More") }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                song.albumKey?.let { key ->
                    DropdownMenuItem(text = { Text("Go to Album") }, leadingIcon = { Icon(painterResource(R.drawable.ic_album), null) },
                        onClick = { menu = false; actions.open(Route.AlbumPage(key)) })
                }
                artistOf(song)?.let { artist ->
                    DropdownMenuItem(text = { Text("Go to Artist") }, leadingIcon = { Icon(painterResource(R.drawable.ic_person), null) },
                        onClick = { menu = false; actions.open(Route.ArtistPage(artist)) })
                }
                DropdownMenuItem(text = { Text("Audio Details") }, leadingIcon = { Icon(painterResource(R.drawable.ic_info), null) },
                    onClick = { menu = false; onDetails() })
            }
        }
    }
}

/** The artist page to go to: the album's artist, or the song's on a compilation. */
private fun artistOf(song: PlayerModel.NowPlaying): String? =
    song.albumArtist?.takeUnless { it == "Various Artists" } ?: song.artist

@Composable
private fun PanelContent(panel: Panel, song: PlayerModel.NowPlaying, player: PlayerModel, cover: File?) {
    AnimatedContent(panel, transitionSpec = { fadeIn(tween(220)) togetherWith fadeOut(tween(180)) }, label = "panel") { shown ->
        when (shown) {
            Panel.COVER -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                // Paused, the cover steps back a little.
                val scale by animateFloatAsState(if (song.isPlaying || song.isBuffering) 1f else 0.86f, spring(dampingRatio = 0.6f), label = "cover")
                Cover(cover, Modifier.widthIn(max = 480.dp).fillMaxWidth().graphicsLayer { scaleX = scale; scaleY = scale }
                    .shadow(24.dp, RoundedCornerShape(12.dp)), corner = 12.dp)
            }
            Panel.LYRICS -> LyricsPanel(song, player)
            Panel.QUEUE -> QueuePanel(player)
        }
    }
}

@Composable
private fun ColumnScope.Controls(song: PlayerModel.NowPlaying, player: PlayerModel, panel: Panel, onPanel: (Panel) -> Unit, onDetails: () -> Unit) {
    val actions = LocalActions.current
    val shuffle by player.shuffle.collectAsStateWithLifecycle()
    val path by player.audioPath.collectAsStateWithLifecycle()
    val track by remember(song.id) { song.id?.let { actions.library.track(it) } ?: flowOf(null) }.collectAsStateWithLifecycle(null)
    Spacer(Modifier.height(16.dp))
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(song.title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold, maxLines = 1,
                modifier = Modifier.basicMarquee(iterations = Int.MAX_VALUE, initialDelayMillis = 2_000))
            Text(song.artist ?: "", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.clickable(enabled = artistOf(song) != null, onClickLabel = "Go to artist") {
                    artistOf(song)?.let { actions.open(Route.ArtistPage(it)) }
                })
        }
        if (track?.loved == true) {
            Icon(painterResource(R.drawable.ic_favorite), contentDescription = "Loved", tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(start = 12.dp).size(22.dp))
        }
    }
    val problem = song.error ?: path.unsupported?.let { "This device cannot decode $it" }
    Row(Modifier.padding(top = 8.dp).height(24.dp), verticalAlignment = Alignment.CenterVertically) {
        if (problem != null) {
            Text(problem, style = MaterialTheme.typography.bodySmall, color = Color(0xFFFFB4AB), maxLines = 1, overflow = TextOverflow.Ellipsis)
        } else {
            track?.let { listOf(it) }?.let(::quality)?.let { badge ->
                Box(Modifier.clip(RoundedCornerShape(4.dp)).clickable(onClick = onDetails, onClickLabel = "Audio details")) {
                    QualityBadge(badge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
    SeekBar(player)
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
        ModeButton(on = shuffle, icon = R.drawable.ic_shuffle, label = "Shuffle", onClick = player::toggleShuffle)
        IconButton(onClick = player::previous, modifier = Modifier.size(56.dp)) {
            Icon(painterResource(R.drawable.ic_skip_previous), contentDescription = "Previous", modifier = Modifier.size(36.dp))
        }
        FilledIconButton(onClick = player::togglePlayPause, modifier = Modifier.size(76.dp),
            colors = IconButtonDefaults.filledIconButtonColors(containerColor = Color.White, contentColor = Color.Black)) {
            if (song.isBuffering) CircularProgressIndicator(Modifier.size(32.dp), color = Color.Black, strokeWidth = 3.dp) else {
                Icon(painterResource(if (song.isPlaying) R.drawable.ic_pause else R.drawable.ic_play),
                    contentDescription = if (song.isPlaying) "Pause" else "Play", modifier = Modifier.size(40.dp))
            }
        }
        IconButton(onClick = player::next, enabled = song.hasNext || song.repeatMode != Player.REPEAT_MODE_OFF, modifier = Modifier.size(56.dp)) {
            Icon(painterResource(R.drawable.ic_skip_next), contentDescription = "Next", modifier = Modifier.size(36.dp))
        }
        ModeButton(
            on = song.repeatMode != Player.REPEAT_MODE_OFF,
            icon = if (song.repeatMode == Player.REPEAT_MODE_ONE) R.drawable.ic_repeat_one else R.drawable.ic_repeat,
            label = when (song.repeatMode) {
                Player.REPEAT_MODE_ONE -> "Repeat one"
                Player.REPEAT_MODE_ALL -> "Repeat all"
                else -> "Repeat"
            },
            onClick = player::cycleRepeat,
        )
    }
    Spacer(Modifier.height(12.dp))
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
        PanelButton(panel == Panel.LYRICS, R.drawable.ic_lyrics, "Lyrics") { onPanel(Panel.LYRICS) }
        IconButton(onClick = onDetails) {
            Icon(painterResource(R.drawable.ic_info), contentDescription = "Audio details", tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        PanelButton(panel == Panel.QUEUE, R.drawable.ic_queue, "Up Next") { onPanel(Panel.QUEUE) }
    }
}

/** Shuffle and repeat: tinted with a dot under them when on. */
@Composable
private fun ModeButton(on: Boolean, icon: Int, label: String, onClick: () -> Unit) {
    IconToggleButton(checked = on, onCheckedChange = { onClick() }, modifier = Modifier.semantics { stateDescription = if (on) "On" else "Off" }) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(painterResource(icon), contentDescription = label,
                tint = if (on) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
            Box(Modifier.padding(top = 2.dp).size(4.dp).clip(RoundedCornerShape(2.dp))
                .background(if (on) MaterialTheme.colorScheme.primary else Color.Transparent))
        }
    }
}

@Composable
private fun PanelButton(on: Boolean, icon: Int, label: String, onClick: () -> Unit) {
    IconToggleButton(checked = on, onCheckedChange = { onClick() },
        colors = IconButtonDefaults.iconToggleButtonColors(checkedContainerColor = MaterialTheme.colorScheme.secondaryContainer,
            checkedContentColor = MaterialTheme.colorScheme.onSecondaryContainer, contentColor = MaterialTheme.colorScheme.onSurfaceVariant)) {
        Icon(painterResource(icon), contentDescription = label)
    }
}

/** The song's position (dragging previews the time, and seeks when let go), elapsed and remaining time. */
@Composable
private fun SeekBar(player: PlayerModel) {
    val progress by player.progress.collectAsStateWithLifecycle(PlayerModel.Progress(0, 0))
    var dragging by remember { mutableStateOf<Float?>(null) }
    val total = progress.durationMs
    val shown = dragging?.let { (it * total).toLong() } ?: progress.positionMs
    Column(Modifier.padding(top = 8.dp)) {
        Slider(
            value = dragging ?: if (total > 0) (progress.positionMs.toFloat() / total).coerceIn(0f, 1f) else 0f,
            onValueChange = { dragging = it },
            onValueChangeFinished = {
                dragging?.let { player.seekTo((it * total).toLong()) }
                dragging = null
            },
            enabled = total > 0,
            colors = SliderDefaults.colors(thumbColor = Color.White, activeTrackColor = Color.White,
                inactiveTrackColor = Color.White.copy(alpha = 0.25f)),
            modifier = Modifier.semantics { stateDescription = "${duration(shown)} of ${duration(total)}" },
        )
        Row {
            Text(duration(shown), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.weight(1f))
            Text("-" + duration((total - shown).coerceAtLeast(0)), style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/**
 * The song's lyrics: synced ones follow the song (the line sung is bright and kept in view; tapping a line goes
 * there), plain ones scroll.
 */
@Composable
private fun LyricsPanel(song: PlayerModel.NowPlaying, player: PlayerModel) {
    val actions = LocalActions.current
    val track by remember(song.id) { song.id?.let { actions.library.track(it) } ?: flowOf(null) }.collectAsStateWithLifecycle(null)
    val lyrics = remember(track?.lyrics) { Lyrics.parse(track?.lyrics) }
    when (lyrics) {
        null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text("No lyrics for this song", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        is Lyrics.Plain -> Text(lyrics.text, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(vertical = 24.dp))
        is Lyrics.Synced -> SyncedLyrics(lyrics, player)
    }
}

@Composable
private fun SyncedLyrics(lyrics: Lyrics.Synced, player: PlayerModel) {
    val progress by player.progress.collectAsStateWithLifecycle(PlayerModel.Progress(0, 0))
    val current = lyrics.lineAt(progress.positionMs + 150)
    val list = rememberLazyListState()
    val dragged by list.interactionSource.collectIsDraggedAsState()
    var touchedAt by remember { mutableLongStateOf(0L) }
    LaunchedEffect(dragged) { if (dragged) touchedAt = System.currentTimeMillis() }
    LaunchedEffect(current) {
        // Follows the song, unless the lyrics were scrolled by hand in the last seconds.
        if (current >= 0 && System.currentTimeMillis() - touchedAt > 3_000) list.animateScrollToItem(current, scrollOffset = -160)
    }
    LazyColumn(state = list, modifier = Modifier.fillMaxSize(), contentPadding = PaddingValues(vertical = 160.dp)) {
        itemsIndexed(lyrics.lines) { index, line ->
            val alpha by animateFloatAsState(if (index == current) 1f else 0.4f, label = "line")
            Text(line.text.ifEmpty { "♪" }, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold,
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).clickable { player.seekTo(line.timeMs) }
                    .graphicsLayer { this.alpha = alpha }.padding(vertical = 10.dp, horizontal = 4.dp))
        }
    }
}

/** Up Next: tap plays a song, the handle drags it to another place, swiping removes it. */
@Composable
private fun QueuePanel(player: PlayerModel) {
    val upNext by player.upNext.collectAsStateWithLifecycle()
    val shuffle by player.shuffle.collectAsStateWithLifecycle()
    var order by remember(upNext) { mutableStateOf(upNext) }
    var draggingKey by remember { mutableStateOf<String?>(null) }
    var dragOffset by remember { mutableFloatStateOf(0f) }
    val list = rememberLazyListState()
    Column(Modifier.fillMaxSize()) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Up Next", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.semantics { heading() })
                if (shuffle) Text("Shuffled", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (upNext.isNotEmpty()) TextButton(onClick = player::clearUpNext) { Text("Clear") }
        }
        if (upNext.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("Nothing plays after this song", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            return@Column
        }
        LazyColumn(state = list, modifier = Modifier.fillMaxSize()) {
            itemsIndexed(order, key = { _, entry -> entry.key }) { position, entry ->
                val dragging = draggingKey == entry.key
                val dismiss = rememberSwipeToDismissBoxState()
                val swiping = dismiss.dismissDirection != SwipeToDismissBoxValue.Settled
                SwipeToDismissBox(
                    state = dismiss,
                    enableDismissFromStartToEnd = false,
                    onDismiss = { player.removeFromQueue(entry.index) },
                    backgroundContent = {
                        if (swiping) Box(Modifier.fillMaxSize().clip(RoundedCornerShape(8.dp)).background(Color(0xFF93000A)).padding(horizontal = 20.dp),
                            contentAlignment = Alignment.CenterEnd) { Text("Remove", color = Color.White) }
                    },
                    modifier = Modifier.zIndex(if (dragging) 1f else 0f)
                        .graphicsLayer { translationY = if (dragging) dragOffset else 0f }
                        .then(if (dragging) Modifier else Modifier.animateItem()),
                ) {
                    ListItem(
                        headlineContent = { Text(entry.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                        supportingContent = entry.artist?.let { { Text(it, maxLines = 1, overflow = TextOverflow.Ellipsis) } },
                        leadingContent = { Cover(entry.artwork?.path?.let(::File), Modifier.size(44.dp), corner = 6.dp) },
                        trailingContent = {
                            Icon(painterResource(R.drawable.ic_drag_handle), contentDescription = "Reorder",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(40.dp).padding(8.dp).pointerInput(entry.key) {
                                    detectDragGestures(
                                        onDragStart = { draggingKey = entry.key; dragOffset = 0f },
                                        onDragEnd = {
                                            val to = order.indexOfFirst { it.key == entry.key }
                                            val from = upNext.indexOfFirst { it.key == entry.key }
                                            draggingKey = null
                                            dragOffset = 0f
                                            if (from >= 0 && to >= 0 && from != to) player.moveInQueue(upNext[from].index, upNext[0].index + to)
                                        },
                                        onDragCancel = { draggingKey = null; dragOffset = 0f; order = upNext },
                                    ) { change, amount ->
                                        change.consume()
                                        dragOffset += amount.y
                                        val items = list.layoutInfo.visibleItemsInfo
                                        val at = order.indexOfFirst { it.key == entry.key }
                                        val size = items.firstOrNull { it.key == entry.key }?.size?.toFloat() ?: return@detectDragGestures
                                        if (dragOffset > size / 2 && at < order.lastIndex) {
                                            order = order.toMutableList().apply { add(at + 1, removeAt(at)) }
                                            dragOffset -= size
                                        } else if (dragOffset < -size / 2 && at > 0) {
                                            order = order.toMutableList().apply { add(at - 1, removeAt(at)) }
                                            dragOffset += size
                                        }
                                    }
                                })
                        },
                        colors = ListItemDefaults.colors(containerColor = if (dragging || swiping) MaterialTheme.colorScheme.surface else Color.Transparent,
                            headlineColor = Color.White, supportingColor = MaterialTheme.colorScheme.onSurfaceVariant),
                        modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { player.skipTo(entry.index) }
                            .semantics {
                                customActions = listOfNotNull(
                                    CustomAccessibilityAction("Remove from Up Next") { player.removeFromQueue(entry.index); true },
                                    if (position > 0) CustomAccessibilityAction("Move up") { player.moveInQueue(entry.index, entry.index - 1); true } else null,
                                    if (position < order.lastIndex) CustomAccessibilityAction("Move down") { player.moveInQueue(entry.index, entry.index + 1); true } else null,
                                )
                            },
                    )
                }
            }
        }
    }
}

/** How this device plays the song: the file, the decoder, and what goes to Android (from phase 0's check). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AudioDetails(song: PlayerModel.NowPlaying, player: PlayerModel, onDismiss: () -> Unit) {
    val actions = LocalActions.current
    val path by player.audioPath.collectAsStateWithLifecycle()
    val track by remember(song.id) { song.id?.let { actions.library.track(it) } ?: flowOf(null) }.collectAsStateWithLifecycle(null)
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = MaterialTheme.colorScheme.surface) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("Audio Details", style = MaterialTheme.typography.titleLarge, modifier = Modifier.semantics { heading() })
            track?.let { file ->
                quality(listOf(file))?.let { QualityBadge(it, color = MaterialTheme.colorScheme.primary) }
                DetailCard {
                    PathLine("Format", formatOf(file))
                    PathLine("Volume", file.normalizationGain?.let { "%+.1f dB (%s)".format(it.coerceAtMost(0.0), if (file.trackGain != null) "ReplayGain" else "measured on the Mac") }
                        ?: "As recorded")
                }
            }
            DetailCard {
                if (song.error != null) Text(song.error, color = Color(0xFFFFB4AB), style = MaterialTheme.typography.bodyMedium)
                path.unsupported?.let { Text("This device cannot decode $it.", color = Color(0xFFFFB4AB), style = MaterialTheme.typography.bodyMedium) }
                if (song.error == null) {
                    PathLine("File", path.source)
                    PathLine("Decoder", path.decoder)
                    PathLine("To Android", path.output?.let { if (path.offloaded) "$it (offloaded)" else it })
                }
            }
        }
    }
}

@Composable
private fun DetailCard(content: @Composable ColumnScope.() -> Unit) {
    Card(Modifier.fillMaxWidth(), colors = CardDefaults.cardColors(containerColor = Color.White.copy(alpha = 0.08f), contentColor = Color.White)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp), content = content)
    }
}

@Composable
private fun PathLine(label: String, value: String?) {
    Row {
        Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(0.35f))
        Text(value ?: "-", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(0.65f))
    }
}

/** "FLAC, 24-bit, 96 kHz". */
private fun formatOf(track: Track): String {
    val codec = when (track.codec) {
        "flac" -> "FLAC"
        "mp3" -> "MP3"
        "aac" -> "AAC"
        "opus" -> "Opus"
        "vorbis" -> "Ogg Vorbis"
        "wav" -> "WAV"
        else -> track.codec.uppercase()
    }
    val rate = track.sampleRate?.let { rate -> if (rate % 1000 == 0) "${rate / 1000} kHz" else "%.1f kHz".format(rate / 1000.0) }
    return listOfNotNull(codec, track.bitDepth?.let { "$it-bit" }, rate).joinToString(", ")
}
