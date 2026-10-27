package dev.irwingbraga.groovelight.ui

import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.ui.unit.Dp
import androidx.compose.animation.core.Transition
import androidx.compose.animation.EnterExitState
import androidx.compose.animation.SharedTransitionScope
import androidx.compose.animation.core.animateDp
import androidx.compose.ui.layout.onSizeChanged
import android.os.SystemClock
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.RadioButton
import androidx.compose.material3.TextButton
import androidx.compose.runtime.produceState
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.style.TextAlign
import dev.irwingbraga.groovelight.playback.PlaybackSettings
import dev.irwingbraga.groovelight.playback.SleepTimer
import kotlinx.coroutines.delay
import androidx.activity.compose.PredictiveBackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.basicMarquee
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
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
import androidx.compose.foundation.lazy.items
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
import androidx.compose.ui.graphics.compositeOver
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
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
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.flowOf
import java.io.File

private enum class Panel { COVER, LYRICS, QUEUE }

/**
 * Now Playing, over everything: the cover (or the lyrics, or Up Next) on the colors of the cover, the song, the seek
 * bar and the controls. Swipe down or Back (with the predictive gesture) closes it. In landscape, the cover sits beside
 * the controls.
 *
 * It grows out of the mini player and shrinks back into it ([sharedPlayer], with the cover flying between the two):
 * `transition` is open (true) or at the mini player (false). Dragging it down reports how far toward the mini player
 * to `onDrag` (null when let go), which moves the transition with the finger.
 */
@Composable
fun NowPlaying(transition: Transition<Boolean>, player: PlayerModel, onClose: () -> Unit, onDrag: (Float?) -> Unit,
               requestedPanel: String? = null, onPanelShown: () -> Unit = {}) {
    var backProgress by remember { mutableFloatStateOf(0f) }
    PredictiveBackHandler(enabled = transition.currentState && transition.targetState) { events ->
        try {
            events.collect { backProgress = it.progress }
            onClose()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } finally {
            backProgress = 0f
        }
    }
    transition.AnimatedVisibility(visible = { it }, enter = EnterTransition.None, exit = ExitTransition.None) {
        val song = LocalNowPlaying.current ?: return@AnimatedVisibility
        val density = LocalDensity.current
        var height by remember { mutableFloatStateOf(1f) }
        // Swiping it down shrinks it toward the mini player with the finger; far or fast enough closes it from there.
        var dragged by remember { mutableFloatStateOf(0f) }
        val dismiss = rememberDraggableState { delta ->
            dragged = (dragged + delta).coerceAtLeast(0f)
            onDrag(dragged / (height * 0.7f))
        }
        CompositionLocalProvider(LocalPageScope provides this) {
            Box(
                Modifier.fillMaxSize()
                    .onSizeChanged { height = it.height.toFloat().coerceAtLeast(1f) }
                    .sharedPlayer(open = true)
                    .graphicsLayer {
                        val scale = 1f - backProgress * 0.08f
                        scaleX = scale
                        scaleY = scale
                        shape = RoundedCornerShape((backProgress * 32).dp)
                        clip = backProgress > 0f
                    }
                    .draggable(dismiss, Orientation.Vertical, onDragStopped = { velocity ->
                        val close = dragged > with(density) { 140.dp.toPx() } || velocity > 2_000f
                        dragged = 0f
                        if (close) onClose()
                        onDrag(null)
                    }),
            ) {
                NowPlayingContent(song, player, onClose, requestedPanel, onPanelShown)
            }
        }
    }
}

/** The cover shared by the mini player and Now Playing, so it flies between the two. */
const val PLAYER_COVER = "nowPlaying"

/**
 * The mini player to Now Playing motion: linear inside, so following a finger (seeking the transition) moves the
 * container exactly with it; [PLAYER_EASING] shapes it when it runs on its own (a tap, or finishing after letting go).
 */
const val PLAYER_MOTION_MS = 420
val PLAYER_EASING = tween<Float>(PLAYER_MOTION_MS, easing = FastOutSlowInEasing)
private val PLAYER_MOTION_DP = tween<Dp>(PLAYER_MOTION_MS, easing = LinearEasing)

/**
 * The mini player and Now Playing as one container ([NowPlaying] grows out of it): the same bounds in both, which
 * move and resize between the two while their contents cross-fade, and corners rounding as the mini player's
 * (`open`: Now Playing's square ones). Inside the player's [LocalSharedTransition] and [LocalPageScope] only.
 */
@Composable
fun Modifier.sharedPlayer(open: Boolean): Modifier {
    val shared = LocalSharedTransition.current ?: return this
    val scope = LocalPageScope.current ?: return this
    val corner by scope.transition.animateDp({ PLAYER_MOTION_DP }, label = "corner") { state ->
        if ((state == EnterExitState.Visible) == open) 0.dp else 16.dp
    }
    return with(shared) {
        this@sharedPlayer.sharedBounds(
            rememberSharedContentState("player"), animatedVisibilityScope = scope,
            // Each side's look cross-fades within the first quarter, so the container is solid while it grows.
            enter = fadeIn(tween(PLAYER_MOTION_MS / 4, easing = LinearEasing)),
            exit = fadeOut(tween(PLAYER_MOTION_MS / 4, easing = LinearEasing)),
            boundsTransform = { _, _ -> tween(PLAYER_MOTION_MS, easing = LinearEasing) },
            // Now Playing is scaled into the container; the mini player's card stretches to it (its glass fills the
            // container, its row stays centered), so the container is whole all the way in both directions.
            resizeMode = if (open) SharedTransitionScope.ResizeMode.scaleToBounds(ContentScale.FillWidth, Alignment.Center)
                else SharedTransitionScope.ResizeMode.RemeasureToBounds,
            clipInOverlayDuringTransition = OverlayClip(RoundedCornerShape(corner)),
        )
    }
}

@Composable
private fun NowPlayingContent(song: PlayerModel.NowPlaying, player: PlayerModel, onClose: () -> Unit, requestedPanel: String?,
                              onPanelShown: () -> Unit) {
    val cover = song.artwork?.path?.let(::File)
    val colors = rememberArtworkColors(cover)
    val background by animateColorAsState(colors?.background ?: Color(0xFF151A2C), tween(600), label = "background")
    val accent by animateColorAsState(colors?.accent ?: Color(0xFFB4C5FF), tween(600), label = "accent")
    // Surfaces (dialogs, menus, sheets) are the cover's color lifted with white, opaque: see-through ones let the
    // cover show through the sleep timer and speed dialogs. Only the toggles' and lines' tints are translucent.
    fun lifted(alpha: Float) = Color.White.copy(alpha = alpha).compositeOver(background)
    val scheme = darkColorScheme(
        primary = accent, onPrimary = background, surface = background, onSurface = Color.White,
        onSurfaceVariant = Color.White.copy(alpha = 0.7f), surfaceContainerLow = lifted(0.05f), surfaceContainer = lifted(0.08f),
        surfaceContainerHigh = lifted(0.12f), surfaceContainerHighest = lifted(0.16f),
        secondaryContainer = Color.White.copy(alpha = 0.16f), onSecondaryContainer = Color.White,
        outlineVariant = Color.White.copy(alpha = 0.2f),
    )
    // Light status bar icons over the dark wash while open.
    LightSystemBarIcons()
    MaterialTheme(colorScheme = scheme, typography = MaterialTheme.typography) {
        Box(Modifier.fillMaxSize().background(background)) {
          CompositionLocalProvider(LocalContentColor provides Color.White) {
            CoverWash(cover, background)
            var panel by rememberSaveable { mutableStateOf(Panel.COVER) }
            var details by rememberSaveable { mutableStateOf(false) }
            var dialog by rememberSaveable { mutableStateOf<Dialog?>(null) }
            val togglePanel = { shown: Panel -> panel = if (panel == shown) Panel.COVER else shown }
            // Lyrics or Up Next asked for from the player bar (wide windows).
            LaunchedEffect(requestedPanel) {
                requestedPanel?.let { asked -> Panel.entries.firstOrNull { it.name == asked }?.let { panel = it } }
                if (requestedPanel != null) onPanelShown()
            }
            // The layout follows the window, not the phone's orientation: split screen beside a map in a car leaves a
            // half or a third of a landscape screen.
            BoxWithConstraints(Modifier.fillMaxSize().safeDrawingPadding()) {
            val layout = when {
                maxHeight < 560.dp && maxWidth < 640.dp -> Layout.COMPACT
                maxWidth >= 840.dp && maxHeight >= 560.dp -> Layout.TABLET
                maxWidth >= 640.dp && maxWidth > maxHeight -> Layout.SIDE_BY_SIDE
                maxWidth < 360.dp -> Layout.COMPACT
                else -> Layout.PORTRAIT
            }
            val wide = maxWidth >= 560.dp
            val roomForSource = maxWidth >= 360.dp
            Column(Modifier.fillMaxSize()) {
                TopRow(song, player, onClose, onDetails = { details = true }, onDialog = { dialog = it },
                    panels = if (layout == Layout.COMPACT) panel else null, onPanel = togglePanel, showSource = roomForSource)
                if (layout == Layout.COMPACT) {
                    CompactBody(panel, song, player, cover, wide, onDetails = { details = true }, onDialog = { dialog = it })
                } else if (layout == Layout.TABLET) {
                    // As on the iPad: the cover with the song and the controls, and beside them the lyrics, or Up Next.
                    val side = if (panel == Panel.QUEUE) Panel.QUEUE else Panel.LYRICS
                    Row(Modifier.fillMaxSize().padding(horizontal = 32.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(48.dp)) {
                        Column(Modifier.weight(1f).fillMaxHeight(), horizontalAlignment = Alignment.CenterHorizontally) {
                            Column(Modifier.widthIn(max = 520.dp).fillMaxHeight()) {
                                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) { PanelContent(Panel.COVER, song, player, cover) }
                                Controls(song, player, side, onPanel = { panel = if (it == Panel.QUEUE && panel == Panel.QUEUE) Panel.LYRICS else it },
                                    onDetails = { details = true }, onDialog = { dialog = it })
                            }
                        }
                        Box(Modifier.weight(1f).fillMaxHeight()) { PanelContent(side, song, player, cover) }
                    }
                } else if (layout == Layout.SIDE_BY_SIDE) {
                    Row(Modifier.fillMaxSize().padding(horizontal = 24.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(32.dp)) {
                        Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.Center) { PanelContent(panel, song, player, cover) }
                        Column(Modifier.weight(1f).fillMaxHeight(), verticalArrangement = Arrangement.Center) {
                            Controls(song, player, panel, onPanel = { panel = if (panel == it) Panel.COVER else it }, onDetails = { details = true },
                                onDialog = { dialog = it })
                        }
                    }
                } else {
                    // A tall unfolded screen keeps the phone's proportions in its middle.
                    Box(Modifier.weight(1f).widthIn(max = 640.dp).fillMaxWidth().align(Alignment.CenterHorizontally).padding(horizontal = 24.dp),
                        contentAlignment = Alignment.Center) {
                        PanelContent(panel, song, player, cover)
                    }
                    Column(Modifier.widthIn(max = 640.dp).align(Alignment.CenterHorizontally).padding(horizontal = 24.dp).padding(bottom = 12.dp)) {
                        Controls(song, player, panel, onPanel = { panel = if (panel == it) Panel.COVER else it }, onDetails = { details = true },
                            onDialog = { dialog = it })
                    }
                }
            }
            }
            if (details) AudioDetails(song, player) { details = false }
            when (dialog) {
                Dialog.SPEED -> SpeedDialog(player) { dialog = null }
                Dialog.SLEEP -> SleepDialog(player) { dialog = null }
                Dialog.RATING -> song.id?.let { id -> RatingDialog(id) { dialog = null } }
                Dialog.VISUALIZER -> Visualizer(song.title, song.artist, accent) { dialog = null }
                null -> {}
            }
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
private fun TopRow(
    song: PlayerModel.NowPlaying,
    player: PlayerModel,
    onClose: () -> Unit,
    onDetails: () -> Unit,
    onDialog: (Dialog) -> Unit,
    /** In the compact layout, the panel shown: Lyrics and Up Next are switched from here. */
    panels: Panel? = null,
    onPanel: (Panel) -> Unit = {},
    showSource: Boolean = true,
) {
    val actions = LocalActions.current
    var menu by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = if (panels != null) 0.dp else 4.dp), verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = onClose) { Icon(painterResource(R.drawable.ic_expand_more), contentDescription = "Close Now Playing") }
        Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
            if (song.playingOn != null) {
                if (panels == null) Text("PLAYING ON", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
                Text(song.playingOn, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary, maxLines = 1,
                    overflow = TextOverflow.Ellipsis)
                val skipped by player.remote.skipped.collectAsStateWithLifecycle()
                if (skipped > 0) Text(if (skipped == 1) "1 song is not there: skipped" else "$skipped songs are not there: skipped",
                    style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            } else if (showSource) song.source?.let { source ->
                if (panels == null) Text("PLAYING FROM", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(source, style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
        if (panels != null) {
            PanelButton(panels == Panel.LYRICS, R.drawable.ic_lyrics, "Lyrics") { onPanel(Panel.LYRICS) }
            PanelButton(panels == Panel.QUEUE, R.drawable.ic_queue, "Up Next") { onPanel(Panel.QUEUE) }
        }
        PlayOnButton(player)
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
                if (song.id != null) {
                    DropdownMenuItem(text = { Text("Rating") }, leadingIcon = { Icon(painterResource(R.drawable.ic_star), null) },
                        onClick = { menu = false; onDialog(Dialog.RATING) })
                }
                HorizontalDivider()
                DropdownMenuItem(text = { Text("Equalizer") }, leadingIcon = { Icon(painterResource(R.drawable.ic_equalizer), null) },
                    onClick = { menu = false; actions.open(Route.Equalizer) })
                DropdownMenuItem(text = { Text("Playback Speed") }, leadingIcon = { Icon(painterResource(R.drawable.ic_speed), null) },
                    onClick = { menu = false; onDialog(Dialog.SPEED) })
                DropdownMenuItem(text = { Text("Visualizer") }, leadingIcon = { Icon(painterResource(R.drawable.ic_visualizer), null) },
                    onClick = { menu = false; onDialog(Dialog.VISUALIZER) })
                DropdownMenuItem(text = { Text("Sleep Timer") }, leadingIcon = { Icon(painterResource(R.drawable.ic_timer), null) },
                    onClick = { menu = false; onDialog(Dialog.SLEEP) })
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
            Panel.COVER -> BoxWithConstraints(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                // Paused, the cover steps back a little.
                val scale by animateFloatAsState(if (song.isPlaying || song.isBuffering) 1f else 0.86f, spring(dampingRatio = 0.6f), label = "cover")
                // Square, as big as the room allows: a short screen (a passport-shaped cover screen) has less height than width.
                Cover(cover, Modifier.sharedCover(PLAYER_COVER).size(minOf(maxWidth, maxHeight, 480.dp)).graphicsLayer { scaleX = scale; scaleY = scale }
                    .shadow(24.dp, RoundedCornerShape(12.dp)), corner = 12.dp)
            }
            Panel.LYRICS -> LyricsPanel(song, player)
            Panel.QUEUE -> QueuePanel(player)
        }
    }
}

@Composable
private fun ColumnScope.Controls(
    song: PlayerModel.NowPlaying,
    player: PlayerModel,
    panel: Panel,
    onPanel: (Panel) -> Unit,
    onDetails: () -> Unit,
    onDialog: (Dialog) -> Unit,
    /** Smaller buttons and type, without the panel buttons (the top row has them): small windows. */
    compact: Boolean = false,
) {
    val actions = LocalActions.current
    val shuffle by player.shuffle.collectAsStateWithLifecycle()
    val path by player.audioPath.collectAsStateWithLifecycle()
    val track by remember(song.id) { song.id?.let { actions.library.track(it) } ?: flowOf(null) }.collectAsStateWithLifecycle(null)
    val speed by player.speed.collectAsStateWithLifecycle()
    val sleep by player.sleepTimer.collectAsStateWithLifecycle()
    val bitPerfect by PlaybackSettings.bitPerfectActive.collectAsStateWithLifecycle()
    Spacer(Modifier.height(if (compact) 4.dp else 16.dp))
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(song.title, style = if (compact) MaterialTheme.typography.titleLarge else MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.SemiBold, maxLines = 1,
                modifier = Modifier.basicMarquee(iterations = Int.MAX_VALUE, initialDelayMillis = 2_000))
            Text(song.artist ?: "", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.clickable(enabled = artistOf(song) != null, onClickLabel = "Go to artist") {
                    artistOf(song)?.let { actions.open(Route.ArtistPage(it)) }
                })
        }
        track?.let { current ->
            IconToggleButton(checked = current.loved, onCheckedChange = { actions.library.setLoved(current.id, it) },
                modifier = Modifier.padding(start = 8.dp)) {
                Icon(painterResource(if (current.loved) R.drawable.ic_favorite else R.drawable.ic_favorite_border),
                    contentDescription = if (current.loved) "Loved" else "Love",
                    tint = if (current.loved) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
    val problem = song.error ?: path.unsupported?.let { "This device cannot decode $it" }
    Row(Modifier.padding(top = if (compact) 2.dp else 8.dp).height(24.dp), verticalAlignment = Alignment.CenterVertically) {
        if (problem != null) {
            Text(problem, style = MaterialTheme.typography.bodySmall, color = Color(0xFFFFB4AB), maxLines = 1, overflow = TextOverflow.Ellipsis)
        } else {
            track?.let { listOf(it) }?.let(::quality)?.let { badge ->
                Box(Modifier.clip(RoundedCornerShape(4.dp)).clickable(onClick = onDetails, onClickLabel = "Audio details")) {
                    QualityBadge(badge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            if (bitPerfect) Text("BIT-PERFECT", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(start = 8.dp))
            if (speed != 1f) Text(speedLabel(speed), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(start = 8.dp).clip(RoundedCornerShape(4.dp)).clickable(onClickLabel = "Playback speed") { onDialog(Dialog.SPEED) })
            track?.rating?.takeIf { it > 0 }?.let { stars ->
                Row(Modifier.padding(start = 8.dp).clip(RoundedCornerShape(4.dp)).clickable(onClickLabel = "Rating") { onDialog(Dialog.RATING) }
                    .semantics(mergeDescendants = true) { contentDescription = "$stars stars" }) {
                    repeat(stars) { Icon(painterResource(R.drawable.ic_star), null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(12.dp)) }
                }
            }
        }
    }
    SeekBar(player)
    // Smaller in small windows, so all five fit in a third of a landscape screen.
    val side = if (compact) 48.dp else 56.dp
    val sideIcon = if (compact) 32.dp else 36.dp
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
        ModeButton(on = shuffle, icon = R.drawable.ic_shuffle, label = "Shuffle", onClick = player::toggleShuffle)
        IconButton(onClick = player::previous, modifier = Modifier.size(side)) {
            Icon(painterResource(R.drawable.ic_skip_previous), contentDescription = "Previous", modifier = Modifier.size(sideIcon))
        }
        FilledIconButton(onClick = player::togglePlayPause, modifier = Modifier.size(if (compact) 64.dp else 76.dp),
            colors = IconButtonDefaults.filledIconButtonColors(containerColor = Color.White, contentColor = Color.Black)) {
            if (song.isBuffering) CircularProgressIndicator(Modifier.size(32.dp), color = Color.Black, strokeWidth = 3.dp) else {
                Icon(painterResource(if (song.isPlaying) R.drawable.ic_pause else R.drawable.ic_play),
                    contentDescription = if (song.isPlaying) "Pause" else "Play", modifier = Modifier.size(40.dp))
            }
        }
        IconButton(onClick = player::next, enabled = song.hasNext || song.repeatMode != Player.REPEAT_MODE_OFF, modifier = Modifier.size(side)) {
            Icon(painterResource(R.drawable.ic_skip_next), contentDescription = "Next", modifier = Modifier.size(sideIcon))
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
    RemoteVolume(player)
    if (!compact) Spacer(Modifier.height(12.dp))
    // The compact layout has Lyrics and Up Next in its top row, the sleep timer and details in the menu.
    if (!compact) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
        PanelButton(panel == Panel.LYRICS, R.drawable.ic_lyrics, "Lyrics") { onPanel(Panel.LYRICS) }
        PanelButton(sleep != SleepTimer.State.Off, R.drawable.ic_timer, sleepLabel(sleep)) { onDialog(Dialog.SLEEP) }
        PanelButton(false, R.drawable.ic_visualizer, "Visualizer") { onDialog(Dialog.VISUALIZER) }
        IconButton(onClick = onDetails) {
            Icon(painterResource(R.drawable.ic_info), contentDescription = "Audio details", tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        PanelButton(panel == Panel.QUEUE, R.drawable.ic_queue, "Up Next") { onPanel(Panel.QUEUE) }
    }
    SleepCountdown(sleep)
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
 * there), plain ones scroll. A song playing elsewhere that this device does not have gets them from the Mac.
 */
@Composable
private fun LyricsPanel(song: PlayerModel.NowPlaying, player: PlayerModel) {
    val actions = LocalActions.current
    val track by remember(song.id) { song.id?.let { actions.library.track(it) } ?: flowOf(null) }.collectAsStateWithLifecycle(null)
    val fromMac by player.macLyrics.collectAsStateWithLifecycle()
    val text = track?.lyrics?.takeIf { it.isNotBlank() } ?: song.id?.let { fromMac[it] }
    LaunchedEffect(song.id, song.playingOn, track?.lyrics) {
        val id = song.id ?: return@LaunchedEffect
        if (song.playingOn != null && track?.lyrics.isNullOrBlank()) player.fetchLyrics(id)
    }
    val lyrics = remember(text) { Lyrics.parse(text) }
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
    // Sized to the space it has (a whole phone, or a third of a car's screen): the line sung sits a third of the way
    // down, with the next ones under it, in type that stays readable at a glance.
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val height = maxHeight
        val style = when {
            maxWidth < 340.dp -> MaterialTheme.typography.titleLarge.copy(fontSize = 24.sp, lineHeight = 30.sp)
            height < 300.dp -> MaterialTheme.typography.headlineSmall.copy(lineHeight = 32.sp)
            else -> MaterialTheme.typography.headlineSmall
        }
        LaunchedEffect(current) {
            // Follows the song, unless the lyrics were scrolled by hand in the last seconds. The list's top padding puts
            // the line a third of the way down.
            if (current >= 0 && System.currentTimeMillis() - touchedAt > 3_000) list.animateScrollToItem(current)
        }
        // Lines fade out at the top and bottom edges rather than being cut.
        LazyColumn(state = list, contentPadding = PaddingValues(top = height * 0.3f, bottom = height * 0.6f),
            modifier = Modifier.fillMaxSize().graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }.drawWithContent {
                drawContent()
                drawRect(Brush.verticalGradient(0f to Color.Transparent, 0.08f to Color.Black, 0.85f to Color.Black, 1f to Color.Transparent),
                    blendMode = BlendMode.DstIn)
            }) {
            itemsIndexed(lyrics.lines) { index, line ->
                // The line sung bright; the next ones readable; the ones sung already faint.
                val alpha by animateFloatAsState(when {
                    index == current -> 1f
                    index > current -> 0.55f
                    else -> 0.3f
                }, label = "line")
                Text(line.text.ifEmpty { "♪" }, style = style, fontWeight = FontWeight.Bold,
                    modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).clickable { player.seekTo(line.timeMs) }
                        .graphicsLayer { this.alpha = alpha }.padding(vertical = if (height < 300.dp) 6.dp else 10.dp, horizontal = 4.dp))
            }
        }
    }
}

/** The Mac's volume while music plays there (a phone's own buttons set its level, as this device's do here). */
@Composable
private fun RemoteVolume(player: PlayerModel) {
    val target by player.target.collectAsStateWithLifecycle()
    if (target != PlayerModel.Target.MAC) return
    val received by player.remote.state.collectAsStateWithLifecycle()
    var dragging by remember { mutableStateOf<Float?>(null) }
    var lastSent by remember { mutableStateOf(0L) }
    Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(painterResource(R.drawable.ic_speaker), null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Slider(
            value = dragging ?: (received?.state?.volume ?: 1.0).toFloat(),
            onValueChange = { value ->
                dragging = value
                // Followed as it is dragged, a few times a second.
                val now = System.currentTimeMillis()
                if (now - lastSent > 150) { lastSent = now; player.setRemoteVolume(value) }
            },
            onValueChangeFinished = { dragging?.let(player::setRemoteVolume); dragging = null },
            modifier = Modifier.weight(1f).padding(horizontal = 8.dp).semantics { contentDescription = "Volume on ${player.targetName()}" },
        )
    }
}

/** Up Next: tap plays a song, the handle drags it to another place, swiping removes it. Elsewhere, shown only. */
@Composable
private fun QueuePanel(player: PlayerModel) {
    val upNext by player.upNext.collectAsStateWithLifecycle()
    val target by player.target.collectAsStateWithLifecycle()
    if (target != PlayerModel.Target.THIS_DEVICE) return RemoteQueue(upNext, player.targetName(target))
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

/** What plays next where music plays now (the songs this device has; edited there). */
@Composable
private fun RemoteQueue(upNext: List<PlayerModel.QueueEntry>, place: String) {
    Column(Modifier.fillMaxSize()) {
        Text("Up Next", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.semantics { heading() })
        Text("On $place", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (upNext.isEmpty()) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("Nothing plays after this song", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            return@Column
        }
        LazyColumn(Modifier.fillMaxSize()) {
            items(upNext, key = { it.key }) { entry ->
                ListItem(
                    headlineContent = { Text(entry.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    supportingContent = entry.artist?.let { { Text(it, maxLines = 1, overflow = TextOverflow.Ellipsis) } },
                    leadingContent = { Cover(entry.artwork?.path?.let(::File), Modifier.size(44.dp), corner = 6.dp) },
                    colors = ListItemDefaults.colors(containerColor = Color.Transparent, headlineColor = Color.White,
                        supportingColor = MaterialTheme.colorScheme.onSurfaceVariant),
                )
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
    val mode by PlaybackSettings.normalization.collectAsStateWithLifecycle()
    val bitPerfect by PlaybackSettings.bitPerfectActive.collectAsStateWithLifecycle()
    val eqEnabled by PlaybackSettings.eqEnabled.collectAsStateWithLifecycle()
    val curve by PlaybackSettings.curve.collectAsStateWithLifecycle()
    val speed by player.speed.collectAsStateWithLifecycle()
    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = MaterialTheme.colorScheme.surface) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("Audio Details", style = MaterialTheme.typography.titleLarge, modifier = Modifier.semantics { heading() })
            track?.let { file ->
                quality(listOf(file))?.let { QualityBadge(it, color = MaterialTheme.colorScheme.primary) }
                DetailCard {
                    PathLine("Format", formatOf(file))
                    PathLine("Volume", volumeLine(file, mode, bitPerfect))
                    PathLine("Equalizer", when {
                        bitPerfect -> "Off (bit-perfect)"
                        eqEnabled -> curve.name.ifEmpty { "Custom" }
                        else -> "Off"
                    })
                    if (speed != 1f) PathLine("Speed", speedLabel(speed))
                }
            }
            DetailCard {
                if (song.error != null) Text(song.error, color = Color(0xFFFFB4AB), style = MaterialTheme.typography.bodyMedium)
                path.unsupported?.let { Text("This device cannot decode $it.", color = Color(0xFFFFB4AB), style = MaterialTheme.typography.bodyMedium) }
                if (song.error == null) {
                    PathLine("File", path.source)
                    PathLine("Decoder", path.decoder)
                    PathLine("To Android", path.output?.let { if (path.offloaded) "$it (offloaded)" else it }?.let { if (bitPerfect) "$it, bit-perfect to the USB DAC" else it })
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

private enum class Dialog { SPEED, SLEEP, RATING, VISUALIZER }

/** The volume adjustment applied to a song, and why. */
private fun volumeLine(track: Track, mode: PlaybackSettings.Normalization, bitPerfect: Boolean): String {
    if (bitPerfect) return "As recorded (bit-perfect)"
    val album = mode == PlaybackSettings.Normalization.ALBUM && track.albumGain != null
    val gain = when (mode) {
        PlaybackSettings.Normalization.OFF -> null
        PlaybackSettings.Normalization.ALBUM -> track.albumGain ?: track.normalizationGain
        PlaybackSettings.Normalization.TRACK -> track.normalizationGain
    } ?: return if (mode == PlaybackSettings.Normalization.OFF) "As recorded (normalization off)" else "As recorded"
    val source = when {
        album -> "album ReplayGain"
        track.trackGain != null -> "ReplayGain"
        else -> "measured on the Mac"
    }
    return "%+.1f dB (%s)".format(gain.coerceAtMost(0.0), source)
}

private val SPEEDS = listOf(0.5f, 0.75f, 0.9f, 1f, 1.1f, 1.25f, 1.5f, 2f)

private fun speedLabel(speed: Float): String = if (speed == speed.toInt().toFloat()) "${speed.toInt()}×" else "${"%.2f".format(speed).trimEnd('0')}×"

@Composable
private fun SpeedDialog(player: PlayerModel, onDismiss: () -> Unit) {
    val speed by player.speed.collectAsStateWithLifecycle()
    val bitPerfect by PlaybackSettings.bitPerfectActive.collectAsStateWithLifecycle()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Playback Speed") },
        text = {
            Column {
                if (bitPerfect) Text("Bit-perfect output plays at normal speed.", style = MaterialTheme.typography.bodyMedium,
                    modifier = Modifier.padding(bottom = 8.dp))
                SPEEDS.forEach { option ->
                    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).selectable(selected = speed == option, enabled = !bitPerfect || option == 1f) {
                        player.setSpeed(option)
                        onDismiss()
                    }.padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                        RadioButton(selected = speed == option, onClick = null, enabled = !bitPerfect || option == 1f)
                        Text(if (option == 1f) "Normal" else speedLabel(option), modifier = Modifier.padding(start = 12.dp))
                    }
                }
                Text("The pitch stays the same.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 8.dp))
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
    )
}

private val SLEEP_MINUTES = listOf(5, 15, 30, 45, 60, 90)

@Composable
private fun SleepDialog(player: PlayerModel, onDismiss: () -> Unit) {
    val state by player.sleepTimer.collectAsStateWithLifecycle()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Sleep Timer") },
        text = {
            Column {
                SLEEP_MINUTES.forEach { minutes ->
                    SleepOption("$minutes minutes") { player.sleepIn(minutes); onDismiss() }
                }
                SleepOption("End of this song", selected = state == SleepTimer.State.EndOfSong) { player.sleepIn(null); onDismiss() }
            }
        },
        confirmButton = {
            if (state != SleepTimer.State.Off) TextButton(onClick = { player.sleepIn(0); onDismiss() }) { Text("Turn Off Timer") }
            else TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

@Composable
private fun SleepOption(label: String, selected: Boolean = false, onClick: () -> Unit) {
    Text(label, style = MaterialTheme.typography.bodyLarge, color = if (selected) MaterialTheme.colorScheme.primary else Color.Unspecified,
        modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).clickable(onClick = onClick).padding(vertical = 12.dp, horizontal = 4.dp))
}

private fun sleepLabel(state: SleepTimer.State): String = when (state) {
    SleepTimer.State.Off -> "Sleep timer"
    SleepTimer.State.EndOfSong -> "Sleep timer: end of song"
    is SleepTimer.State.At -> "Sleep timer on"
}

/** "Pauses in 12:30" while a timer runs. */
@Composable
private fun SleepCountdown(state: SleepTimer.State) {
    val text = when (state) {
        SleepTimer.State.Off -> null
        SleepTimer.State.EndOfSong -> "Pauses at the end of this song"
        is SleepTimer.State.At -> {
            val now by produceState(SystemClock.elapsedRealtime(), state) {
                while (true) {
                    value = SystemClock.elapsedRealtime()
                    delay(1_000)
                }
            }
            "Pauses in " + duration((state.endsAt - now).coerceAtLeast(0))
        }
    }
    if (text != null) Text(text, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary,
        textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth().padding(top = 4.dp))
}

/** Five stars; tapping the rating given clears it. */
@Composable
private fun RatingDialog(id: Long, onDismiss: () -> Unit) {
    val actions = LocalActions.current
    val track by remember(id) { actions.library.track(id) }.collectAsStateWithLifecycle(null)
    val rating = track?.rating ?: 0
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Rating") },
        text = {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
                for (star in 1..5) {
                    IconButton(onClick = { actions.library.setRating(id, if (star == rating) 0 else star) }) {
                        Icon(painterResource(if (star <= rating) R.drawable.ic_star else R.drawable.ic_star_border),
                            contentDescription = if (star == 1) "1 star" else "$star stars",
                            tint = if (star <= rating) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(32.dp))
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
    )
}

private enum class Layout { PORTRAIT, SIDE_BY_SIDE, TABLET, COMPACT }

/**
 * Now Playing in a small window (a half or a third of a landscape screen, beside a map): the controls on their own, or
 * the lyrics or Up Next with a bar of the song and its main buttons, so the panel gets all the height.
 */
@Composable
private fun CompactBody(
    panel: Panel,
    song: PlayerModel.NowPlaying,
    player: PlayerModel,
    cover: File?,
    showCover: Boolean,
    onDetails: () -> Unit,
    onDialog: (Dialog) -> Unit,
) {
    if (panel == Panel.COVER) {
        Row(Modifier.fillMaxSize().padding(horizontal = 16.dp).padding(bottom = 8.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(20.dp)) {
            if (showCover) Cover(cover, Modifier.sharedCover(PLAYER_COVER).fillMaxHeight(0.9f).aspectRatio(1f, matchHeightConstraintsFirst = true), corner = 10.dp)
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.Center) {
                Controls(song, player, panel, onPanel = {}, onDetails = onDetails, onDialog = onDialog, compact = true)
            }
        }
        return
    }
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.weight(1f).fillMaxWidth().padding(horizontal = 16.dp)) { PanelContent(panel, song, player, cover) }
        CompactBar(song, player, cover)
    }
}

/** The song and its main buttons under the lyrics or Up Next in a small window, with how far it is. */
@Composable
private fun CompactBar(song: PlayerModel.NowPlaying, player: PlayerModel, cover: File?) {
    val progress by player.progress.collectAsStateWithLifecycle(PlayerModel.Progress(0, 0))
    val fraction = if (progress.durationMs > 0) (progress.positionMs.toFloat() / progress.durationMs).coerceIn(0f, 1f) else 0f
    Column(Modifier.fillMaxWidth()) {
        Box(Modifier.fillMaxWidth().padding(horizontal = 16.dp).height(3.dp).clip(RoundedCornerShape(2.dp)).background(Color.White.copy(alpha = 0.2f))) {
            Box(Modifier.fillMaxWidth(fraction).fillMaxHeight().background(Color.White))
        }
        Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp, top = 6.dp, bottom = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Cover(cover, Modifier.size(48.dp), corner = 6.dp)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(song.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1,
                    modifier = Modifier.basicMarquee(iterations = Int.MAX_VALUE, initialDelayMillis = 2_000))
                Text(song.artist ?: "", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            IconButton(onClick = player::previous, modifier = Modifier.size(48.dp)) {
                Icon(painterResource(R.drawable.ic_skip_previous), contentDescription = "Previous", modifier = Modifier.size(30.dp))
            }
            FilledIconButton(onClick = player::togglePlayPause, modifier = Modifier.size(56.dp),
                colors = IconButtonDefaults.filledIconButtonColors(containerColor = Color.White, contentColor = Color.Black)) {
                Icon(painterResource(if (song.isPlaying) R.drawable.ic_pause else R.drawable.ic_play),
                    contentDescription = if (song.isPlaying) "Pause" else "Play", modifier = Modifier.size(32.dp))
            }
            IconButton(onClick = player::next, enabled = song.hasNext || song.repeatMode != Player.REPEAT_MODE_OFF, modifier = Modifier.size(48.dp)) {
                Icon(painterResource(R.drawable.ic_skip_next), contentDescription = "Next", modifier = Modifier.size(30.dp))
            }
        }
    }
}
