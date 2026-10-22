package dev.irwingbraga.groovelight.ui

import androidx.compose.animation.ExitTransition
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.core.SeekableTransitionState
import androidx.compose.animation.core.rememberTransition
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.border
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarResult
import androidx.compose.ui.text.font.FontWeight
import dev.chrisbanes.haze.hazeEffect
import kotlinx.coroutines.launch
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.hazeSource
import dev.chrisbanes.haze.rememberHazeState
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.ShortNavigationBar
import androidx.compose.material3.ShortNavigationBarItem
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.graphics.Color
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedContentTransitionScope
import androidx.compose.animation.ContentTransform
import androidx.compose.animation.SharedTransitionLayout
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.togetherWith
import androidx.navigation3.ui.LocalNavAnimatedContentScope
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfoV2
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffold
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteType
import androidx.compose.runtime.Composable
import androidx.window.core.layout.WindowSizeClass
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.runtime.toMutableStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation3.runtime.NavEntry
import androidx.navigation3.runtime.rememberSaveableStateHolderNavEntryDecorator
import androidx.navigation3.ui.NavDisplay
import dev.irwingbraga.groovelight.R
import dev.irwingbraga.groovelight.sync.SyncScreen
import dev.irwingbraga.groovelight.sync.SyncViewModel
import java.io.File
import kotlin.math.abs

/** A screen of the player: the tabs' first screens and the pages opened from them. */
sealed interface Route {
    data object Library : Route
    data object Search : Route
    data object Shelf : Route
    data object Settings : Route
    data object Sync : Route
    data object Equalizer : Route
    data class AlbumPage(val key: String) : Route
    data class ArtistPage(val name: String) : Route
    data class PlaylistPage(val id: Long) : Route
    data class PersonPage(val name: String) : Route
    data class MacAlbumPage(val key: String) : Route
    data class MacArtistPage(val name: String) : Route
    data object LovedSongs : Route

    /** A page of the library (it opens in the Library tab when asked from Settings). */
    val isLibraryPage: Boolean get() = this is AlbumPage || this is ArtistPage || this is PlaylistPage || this is PersonPage || this == LovedSongs ||
        this is MacAlbumPage || this is MacArtistPage

    companion object {
        /** As text, for saving the tabs' screens across process death. */
        fun encode(route: Route): String = when (route) {
            Library -> "library"
            Search -> "search"
            Shelf -> "shelf"
            Settings -> "settings"
            Sync -> "sync"
            Equalizer -> "equalizer"
            LovedSongs -> "loved"
            is AlbumPage -> "album:${route.key}"
            is ArtistPage -> "artist:${route.name}"
            is PlaylistPage -> "playlist:${route.id}"
            is PersonPage -> "person:${route.name}"
            is MacAlbumPage -> "macalbum:${route.key}"
            is MacArtistPage -> "macartist:${route.name}"
        }

        fun decode(text: String): Route? {
            val kind = text.substringBefore(':')
            val value = text.substringAfter(':', "")
            return when (kind) {
                "library" -> Library
                "search" -> Search
                "shelf" -> Shelf
                "settings" -> Settings
                "sync" -> Sync
                "equalizer" -> Equalizer
                "loved" -> LovedSongs
                "album" -> AlbumPage(value)
                "artist" -> ArtistPage(value)
                "person" -> PersonPage(value)
                "macalbum" -> MacAlbumPage(value)
                "macartist" -> MacArtistPage(value)
                "playlist" -> value.toLongOrNull()?.let(::PlaylistPage)
                else -> null
            }
        }
    }
}

enum class Tab(val label: String, val icon: Int, val root: Route) {
    LIBRARY("Library", R.drawable.ic_library, Route.Library),
    SEARCH("Search", R.drawable.ic_search, Route.Search),
    SHELF("Shelf", R.drawable.ic_shelf, Route.Shelf),
    SETTINGS("Settings", R.drawable.ic_settings, Route.Settings),
}

private val stackSaver = listSaver<SnapshotStateList<Route>, String>(
    save = { stack -> stack.map(Route::encode) },
    restore = { saved -> saved.mapNotNull(Route::decode).toMutableStateList() },
)

/**
 * Player mode: Library, Search, Shelf and Settings (with Sync), each keeping its own pages (Back and the predictive back gesture return,
 * tapping the current tab again goes to its first screen); a bar on phones, a rail on wider screens and in landscape.
 * The mini player sits above the navigation, and Now Playing opens over everything.
 */
@Composable
fun PlayerShell(sync: SyncViewModel, player: PlayerModel = viewModel(), library: LibraryModel = viewModel()) {
    var tab by rememberSaveable { mutableStateOf(Tab.LIBRARY) }
    val stacks = Tab.entries.associateWith { rememberSaveable(saver = stackSaver) { mutableStateListOf(it.root) } }
    var expanded by rememberSaveable { mutableStateOf(false) }
    // Now Playing grows out of the mini player and shrinks back into it (a container transform): one seekable
    // transition between the two, so a finger on either moves it, and letting go finishes it from there.
    val motion = remember { SeekableTransitionState(expanded) }
    val playerTransition = rememberTransition(motion, label = "nowPlaying")
    val nowPlaying by player.nowPlaying.collectAsStateWithLifecycle()
    val mode by sync.mode.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    val tabStates = rememberSaveableStateHolder()

    // While the player is on screen, the Mac is asked every few seconds whether it is there (requests made while it was
    // away go out as soon as it is) and whether its Sync button was pressed.
    androidx.lifecycle.compose.LifecycleStartEffect(sync) {
        sync.startPolling()
        onStopOrDispose { sync.stopPolling() }
    }

    val actions = remember(library, player) {
        Actions(library, player, snackbar, scope, open = { route ->
            expanded = false
            // Library pages asked from Settings open in the Library; Settings' own pages in Settings.
            if (tab == Tab.SETTINGS && route.isLibraryPage) tab = Tab.LIBRARY
            if (route == Route.Equalizer || route == Route.Sync) tab = Tab.SETTINGS
            val stack = stacks.getValue(tab)
            if (stack.lastOrNull() != route) stack.add(route)
        }, showTab = { tab = it })
    }

    // A rail on wide windows, and on short ones (phones and players in landscape), where a bar takes too much height;
    // a slim bar in narrow windows (split screen beside a map), where a rail takes too much width.
    val window = currentWindowAdaptiveInfoV2().windowSizeClass
    val windowWidth = with(androidx.compose.ui.platform.LocalDensity.current) {
        androidx.compose.ui.platform.LocalWindowInfo.current.containerSize.width.toDp().value
    }
    val compact = WindowShape.of(window, windowWidth)
    val wide = window.isWidthAtLeastBreakpoint(WindowSizeClass.WIDTH_DP_MEDIUM_LOWER_BOUND)
    val layout = when {
        compact.short && !wide -> NavigationSuiteType.ShortNavigationBarCompact
        wide || compact.short -> NavigationSuiteType.NavigationRail
        else -> NavigationSuiteType.NavigationBar
    }
    val bar = layout == NavigationSuiteType.NavigationBar || layout == NavigationSuiteType.ShortNavigationBarCompact
    // Bars are drawn over the content, as glass (what scrolls behind them shows through, blurred): their height, once
    // measured, is left free at the bottom of every list.
    val haze = rememberHazeState()
    var barHeight by remember { mutableStateOf(0.dp) }
    // The Shelf fills a short (landscape) screen, as Cover Flow did: no mini player over it.
    val shelfFullScreen = tab == Tab.SHELF && stacks.getValue(Tab.SHELF).lastOrNull() == Route.Shelf &&
        !window.isHeightAtLeastBreakpoint(WindowSizeClass.HEIGHT_DP_MEDIUM_LOWER_BOUND)
    val miniHidden by player.miniPlayerHidden.collectAsStateWithLifecycle()
    LaunchedEffect(expanded) { motion.animateTo(expanded, PLAYER_EASING) }
    LaunchedEffect(nowPlaying == null || miniHidden) { if (nowPlaying == null || miniHidden) expanded = false }
    // A finger moving it toward `open` (fraction of the way), or let go (null): on to `expanded` from where it is.
    val follow = { open: Boolean, fraction: Float? ->
        scope.launch { if (fraction != null) motion.seekTo(fraction.coerceIn(0f, 1f), targetState = open) else motion.animateTo(expanded, PLAYER_EASING) }
        Unit
    }
    val showMini = nowPlaying != null && !shelfFullScreen && !miniHidden
    // Closing the player: put away, with a way back.
    val closePlayer = {
        player.closePlayer()
        scope.launch {
            if (snackbar.showSnackbar("Player closed", actionLabel = "Undo", duration = SnackbarDuration.Short) == SnackbarResult.ActionPerformed) {
                player.reopen()
            }
        }
        Unit
    }
    // The Shelf is always dark (as on the Mac): so are the bar and the mini player over it.
    val onShelf = tab == Tab.SHELF && stacks.getValue(Tab.SHELF).lastOrNull() == Route.Shelf
    // A rail leaves the gesture bar to the content.
    val systemBottom = if (bar) 0.dp else WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    val above = systemBottom + if (bar) barHeight else 0.dp
    val bottomInset = above + if (showMini) (if (compact.short) 64.dp else 80.dp) else 0.dp
    val select = { item: Tab ->
        if (tab == item) stacks.getValue(item).run { while (size > 1) removeAt(lastIndex) } else tab = item
    }

    CompositionLocalProvider(LocalActions provides actions, LocalNowPlaying provides nowPlaying, LocalBottomInset provides bottomInset,
        LocalWindowShape provides compact) {
        SharedTransitionLayout(Modifier.fillMaxSize()) {
        val playerLayout = this
        Box(Modifier.fillMaxSize()) {
            NavigationSuiteScaffold(
                layoutType = if (bar) NavigationSuiteType.None else layout,
                navigationSuiteItems = {
                    Tab.entries.forEach { item ->
                        item(
                            selected = tab == item,
                            onClick = { select(item) },
                            icon = { Icon(painterResource(item.icon), contentDescription = if (compact.short) item.label else null) },
                            // Icons alone in a short window, where every row counts (the icon is then read out by its name).
                            label = if (compact.short) null else ({ Text(item.label) }),
                        )
                    }
                },
            ) {
                Box(Modifier.fillMaxSize()) {
                    Box(Modifier.fillMaxSize().hazeSource(haze)) {
                    // Back from another tab's first screen goes to the Library before leaving the app.
                    BackHandler(enabled = tab != Tab.LIBRARY && stacks.getValue(tab).size == 1) { tab = Tab.LIBRARY }
                    // Covers move between a list and their page (shared elements); tabs fade through.
                    SharedTransitionLayout {
                    CompositionLocalProvider(LocalSharedTransition provides this) {
                    AnimatedContent(tab, transitionSpec = { fadeThrough() }, label = "tab") { shownTab ->
                    tabStates.SaveableStateProvider(shownTab.name) {
                        val stack = stacks.getValue(shownTab)
                        NavDisplay(
                            backStack = stack,
                            onBack = { if (stack.size > 1) stack.removeAt(stack.lastIndex) },
                            entryDecorators = listOf(rememberSaveableStateHolderNavEntryDecorator()),
                            sharedTransitionScope = this@SharedTransitionLayout,
                            transitionSpec = { pageOpens() },
                            popTransitionSpec = { pageCloses() },
                            predictivePopTransitionSpec = { pageCloses() },
                            entryProvider = { route ->
                                NavEntry(route, contentKey = Route.encode(route)) {
                                    CompositionLocalProvider(LocalBack provides { if (stack.size > 1) stack.removeAt(stack.lastIndex) },
                                        LocalPageScope provides LocalNavAnimatedContentScope.current) {
                                    when (it) {
                                        Route.Library -> LibraryHome()
                                        Route.Search -> SearchScreen()
                                        Route.Shelf -> ShelfScreen()
                                        Route.Settings -> SettingsScreen(sync)
                                        Route.Equalizer -> EqualizerScreen()
                                        Route.Sync -> GlassTop(bar = { SettingsBar("Sync") }) {
                                            Box(Modifier.padding(top = LocalTopInset.current, bottom = bottomInset)) {
                                                SyncScreen(null, sync) { mode?.let { current -> ListeningCard(current, sync::setMode) } }
                                            }
                                        }
                                        is Route.PersonPage -> PersonPage(it.name)
                                        is Route.MacAlbumPage -> MacAlbumPage(it.key)
                                        is Route.MacArtistPage -> MacArtistPage(it.name)
                                        is Route.AlbumPage -> AlbumPage(it.key)
                                        is Route.ArtistPage -> ArtistPage(it.name)
                                        is Route.PlaylistPage -> PlaylistPage(it.id)
                                        Route.LovedSongs -> PlaylistPage(null)
                                    }
                                    }
                                }
                            },
                        )
                    }
                    }
                    }
                    }
                    }
                    GroovelightTheme(dark = onShelf || Appearance.isDark()) {
                    Column(Modifier.align(Alignment.BottomCenter).padding(bottom = above)) {
                        SnackbarHost(snackbar)
                        AnimatedVisibility(showMini, enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut()) {
                            // Gone while Now Playing is open: it grows into it, and comes back out of it.
                            playerTransition.AnimatedVisibility(visible = { !it }, enter = EnterTransition.None, exit = ExitTransition.None) {
                                CompositionLocalProvider(LocalSharedTransition provides playerLayout, LocalPageScope provides this) {
                                    nowPlaying?.let {
                                        MiniPlayer(it, player, haze, onOpen = { expanded = true }, onClose = closePlayer,
                                            onPeek = { fraction -> follow(true, fraction) })
                                    }
                                }
                            }
                        }
                    }
                    if (bar) {
                        GlassBar(haze, short = layout == NavigationSuiteType.ShortNavigationBarCompact, iconsOnly = compact.short, selected = tab,
                            onSelect = select, onHeight = { barHeight = it }, modifier = Modifier.align(Alignment.BottomCenter))
                    }
                    }
                }
            }
            CompositionLocalProvider(LocalSharedTransition provides playerLayout) {
                NowPlaying(playerTransition, player = player, onClose = { expanded = false }, onDrag = { fraction -> follow(false, fraction) })
            }
        }
        }
    }
}

/**
 * The tabs along the bottom, as frosted glass ([glass]): the page scrolls on behind them. A slim bar in short or narrow
 * windows.
 */
@Composable
private fun GlassBar(haze: HazeState, short: Boolean, iconsOnly: Boolean, selected: Tab, onSelect: (Tab) -> Unit, onHeight: (Dp) -> Unit,
                     modifier: Modifier) {
    val glass = modifier.glass(haze, edgeOnTop = true, onHeight = onHeight)
    val icon = @Composable { item: Tab ->
        Icon(painterResource(item.icon), contentDescription = if (iconsOnly) item.label else null)
    }
    if (short) {
        ShortNavigationBar(glass, containerColor = Color.Transparent) {
            Tab.entries.forEach { item ->
                ShortNavigationBarItem(selected = selected == item, onClick = { onSelect(item) }, icon = { icon(item) },
                    label = if (iconsOnly) null else ({ Text(item.label) }))
            }
        }
    } else {
        NavigationBar(glass, containerColor = Color.Transparent, tonalElevation = 0.dp) {
            Tab.entries.forEach { item ->
                NavigationBarItem(selected = selected == item, onClick = { onSelect(item) }, icon = { icon(item) },
                    label = if (iconsOnly) null else ({ Text(item.label) }))
            }
        }
    }
}

/**
 * The song playing, above the navigation, as glass over the page: tap or swipe up opens Now Playing (which follows
 * the finger up, `onPeek`, and opens or drops back when let go), swipe sideways
 * changes song, swipe down closes the player ([PlayerModel.closePlayer]), and long press offers its sheet (Close
 * Player, Clear Up Next, Clear Queue). A line along its bottom shows how far the song is.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun MiniPlayer(song: PlayerModel.NowPlaying, player: PlayerModel, haze: HazeState, onOpen: () -> Unit, onClose: () -> Unit,
                       onPeek: (Float?) -> Unit) {
    val windowHeight = LocalWindowInfo.current.containerSize.height.toFloat()
    val path by player.audioPath.collectAsStateWithLifecycle()
    val progress by player.progress.collectAsStateWithLifecycle(PlayerModel.Progress(0, 0))
    val problem = song.error ?: path.unsupported?.let { "This device cannot decode $it" }
    val haptics = LocalHapticFeedback.current
    val scope = rememberCoroutineScope()
    var sheet by remember { mutableStateOf(false) }
    // How far it was dragged down: it follows the finger, fading, and springs back unless let go far enough.
    val drop = remember { Animatable(0f) }
    val shape = RoundedCornerShape(16.dp)
    val short = LocalWindowShape.current.short
    Box(
        Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = if (short) 4.dp else 8.dp)
            .height(if (short) 56.dp else 64.dp)
            .sharedPlayer(open = false)
            .graphicsLayer {
                translationY = drop.value
                alpha = 1f - (drop.value / (size.height * 1.5f)).coerceIn(0f, 0.8f)
            }
            .shadow(6.dp, shape)
            .clip(shape)
            .hazeEffect(haze, glassStyle())
            .border(1.dp, MaterialTheme.colorScheme.onSurface.copy(alpha = 0.08f), shape)
            .combinedClickable(onClick = onOpen, onClickLabel = "Open Now Playing", onLongClick = {
                haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                sheet = true
            }, onLongClickLabel = "Player options")
            .pointerInput(windowHeight) {
                var dx = 0f
                var dy = 0f
                // The first clear movement decides: up opens Now Playing (it follows the finger), down closes, sideways
                // changes song.
                var vertical: Boolean? = null
                val velocity = VelocityTracker()
                var startedAt = 0L
                var lastAt = 0L
                val screen = windowHeight.coerceAtLeast(1f)
                fun settle() {
                    when {
                        vertical == false && dx < -64.dp.toPx() -> player.next()
                        vertical == false && dx > 64.dp.toPx() -> player.previous()
                        vertical == true && dy > 40.dp.toPx() -> { onClose(); scope.launch { drop.snapTo(0f) } }
                        // Past a quarter of the way, or flicked up (fast, or short and quick): open from where it is;
                        // otherwise back down.
                        vertical == true && dy < 0 && (-dy > screen * 0.25f || velocity.calculateVelocity().y < -1_500f ||
                            (-dy > 32.dp.toPx() && lastAt - startedAt < 300)) -> onOpen()
                    }
                    onPeek(null)
                    if (!(vertical == true && dy > 40.dp.toPx())) scope.launch { drop.animateTo(0f, spring(stiffness = Spring.StiffnessMediumLow)) }
                }
                detectDragGestures(onDragStart = { dx = 0f; dy = 0f; vertical = null; velocity.resetTracking(); startedAt = 0L }, onDragEnd = { settle() },
                    onDragCancel = { dx = 0f; dy = 0f; settle() }) { change, amount ->
                    dx += amount.x
                    dy += amount.y
                    velocity.addPosition(change.uptimeMillis, change.position)
                    if (startedAt == 0L) startedAt = change.previousUptimeMillis
                    lastAt = change.uptimeMillis
                    if (vertical == null && abs(dx) + abs(dy) > 12.dp.toPx()) vertical = abs(dy) > abs(dx)
                    if (vertical == true) {
                        scope.launch { drop.snapTo(dy.coerceAtLeast(0f)) }
                        onPeek((-dy / screen).coerceIn(0f, 1f))
                    }
                }
            }
            .semantics {
                onClick("Open Now Playing") { onOpen(); true }
                customActions = listOf(CustomAccessibilityAction("Close player") { onClose(); true })
            },
    ) {
        Row(Modifier.fillMaxSize().padding(start = 8.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Cover(song.artwork?.path?.let(::File), Modifier.sharedCover(PLAYER_COVER).size(48.dp), corner = 8.dp)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(song.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(problem ?: song.artist ?: "", style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    color = if (problem != null) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
            }
            IconButton(onClick = player::togglePlayPause) {
                Icon(painterResource(if (song.isPlaying) R.drawable.ic_pause else R.drawable.ic_play),
                    contentDescription = if (song.isPlaying) "Pause" else "Play")
            }
            IconButton(onClick = player::next, enabled = song.hasNext) {
                Icon(painterResource(R.drawable.ic_skip_next), contentDescription = "Next")
            }
        }
        val fraction = if (progress.durationMs > 0) (progress.positionMs.toFloat() / progress.durationMs).coerceIn(0f, 1f) else 0f
        Box(Modifier.align(Alignment.BottomStart).padding(horizontal = 12.dp).fillMaxWidth().height(2.dp)
            .clip(RoundedCornerShape(1.dp)).background(MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f)))
        Box(Modifier.align(Alignment.BottomStart).padding(horizontal = 12.dp).fillMaxWidth(fraction).height(2.dp)
            .clip(RoundedCornerShape(1.dp)).background(MaterialTheme.colorScheme.primary))
    }
    if (sheet) PlayerSheet(song, player, onOpen = onOpen, onClose = onClose) { sheet = false }
}

/** The mini player's sheet (long press): the song, then Open Now Playing, Clear Up Next, Close Player and Clear Queue. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PlayerSheet(song: PlayerModel.NowPlaying, player: PlayerModel, onOpen: () -> Unit, onClose: () -> Unit, onDone: () -> Unit) {
    val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    val upNext by player.upNext.collectAsStateWithLifecycle()
    // Each action closes the sheet first, then acts.
    fun then(action: () -> Unit) {
        scope.launch { state.hide() }.invokeOnCompletion { onDone(); action() }
    }
    ModalBottomSheet(onDismissRequest = onDone, sheetState = state) {
        ListItem(
            headlineContent = { Text(song.title, maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.SemiBold) },
            supportingContent = { Text(listOfNotNull(song.artist, song.album).joinToString(" · "), maxLines = 1, overflow = TextOverflow.Ellipsis) },
            leadingContent = { Cover(song.artwork?.path?.let(::File), Modifier.size(48.dp), corner = 8.dp) },
            colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        )
        HorizontalDivider(Modifier.padding(horizontal = 16.dp))
        SheetAction(R.drawable.ic_expand_more, "Open Now Playing", rotate = true) { then(onOpen) }
        if (upNext.isNotEmpty()) {
            SheetAction(R.drawable.ic_queue, "Clear Up Next", detail = if (upNext.size == 1) "1 song after this one" else "${upNext.size} songs after this one") {
                then(player::clearUpNext)
            }
        }
        SheetAction(R.drawable.ic_close, "Close Player", detail = "Stops and hides it; the queue is kept for next time") { then(onClose) }
        SheetAction(R.drawable.ic_delete, "Clear Queue", detail = "Stops and removes every song from the queue", danger = true) {
            then(player::clearQueue)
        }
        Spacer(Modifier.height(16.dp))
    }
}

@Composable
private fun SheetAction(icon: Int, title: String, detail: String? = null, danger: Boolean = false, rotate: Boolean = false, onClick: () -> Unit) {
    val color = if (danger) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface
    ListItem(
        headlineContent = { Text(title, color = color) },
        supportingContent = detail?.let { { Text(it) } },
        leadingContent = { Icon(painterResource(icon), null, tint = color, modifier = if (rotate) Modifier.rotate(180f) else Modifier) },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        modifier = Modifier.clickable(onClick = onClick),
    )
}

/** A page opening: it fades and grows slightly into place while its cover moves from the list (shared element). */
private fun <T> AnimatedContentTransitionScope<T>.pageOpens(): ContentTransform =
    (fadeIn(tween(260, delayMillis = 60)) + scaleIn(tween(300, easing = FastOutSlowInEasing), initialScale = 0.96f))
        .togetherWith(fadeOut(tween(160)))

/** Back: the page fades and shrinks slightly while its cover returns to the list. */
private fun <T> AnimatedContentTransitionScope<T>.pageCloses(): ContentTransform =
    fadeIn(tween(220, delayMillis = 40)).togetherWith(fadeOut(tween(180)) + scaleOut(tween(260, easing = FastOutSlowInEasing), targetScale = 0.96f))

/** Material's fade through, for tabs: the old one fades out, then the new one fades in growing from 92%. */
private fun <T> AnimatedContentTransitionScope<T>.fadeThrough(): ContentTransform =
    (fadeIn(tween(210, delayMillis = 90)) + scaleIn(tween(210, delayMillis = 90), initialScale = 0.92f)).togetherWith(fadeOut(tween(90)))
