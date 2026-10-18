package dev.irwingbraga.groovelight.ui

import androidx.activity.compose.BackHandler
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
import androidx.compose.material3.Surface
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
    data object Sync : Route
    data class AlbumPage(val key: String) : Route
    data class ArtistPage(val name: String) : Route
    data class PlaylistPage(val id: Long) : Route
    data object LovedSongs : Route

    companion object {
        /** As text, for saving the tabs' screens across process death. */
        fun encode(route: Route): String = when (route) {
            Library -> "library"
            Search -> "search"
            Sync -> "sync"
            LovedSongs -> "loved"
            is AlbumPage -> "album:${route.key}"
            is ArtistPage -> "artist:${route.name}"
            is PlaylistPage -> "playlist:${route.id}"
        }

        fun decode(text: String): Route? {
            val kind = text.substringBefore(':')
            val value = text.substringAfter(':', "")
            return when (kind) {
                "library" -> Library
                "search" -> Search
                "sync" -> Sync
                "loved" -> LovedSongs
                "album" -> AlbumPage(value)
                "artist" -> ArtistPage(value)
                "playlist" -> value.toLongOrNull()?.let(::PlaylistPage)
                else -> null
            }
        }
    }
}

enum class Tab(val label: String, val icon: Int, val root: Route) {
    LIBRARY("Library", R.drawable.ic_library, Route.Library),
    SEARCH("Search", R.drawable.ic_search, Route.Search),
    SYNC("Sync", R.drawable.ic_sync, Route.Sync),
}

private val stackSaver = listSaver<SnapshotStateList<Route>, String>(
    save = { stack -> stack.map(Route::encode) },
    restore = { saved -> saved.mapNotNull(Route::decode).toMutableStateList() },
)

/**
 * Player mode: Library, Search and Sync, each keeping its own pages (Back and the predictive back gesture return,
 * tapping the current tab again goes to its first screen); a bar on phones, a rail on wider screens and in landscape.
 * The mini player sits above the navigation, and Now Playing opens over everything.
 */
@Composable
fun PlayerShell(sync: SyncViewModel, player: PlayerModel = viewModel(), library: LibraryModel = viewModel()) {
    var tab by rememberSaveable { mutableStateOf(Tab.LIBRARY) }
    val stacks = Tab.entries.associateWith { rememberSaveable(saver = stackSaver) { mutableStateListOf(it.root) } }
    var expanded by rememberSaveable { mutableStateOf(false) }
    val nowPlaying by player.nowPlaying.collectAsStateWithLifecycle()
    val mode by sync.mode.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    val tabStates = rememberSaveableStateHolder()

    val actions = remember(library, player) {
        Actions(library, player, snackbar, scope, open = { route ->
            expanded = false
            if (tab == Tab.SYNC) tab = Tab.LIBRARY
            val stack = stacks.getValue(tab)
            if (stack.lastOrNull() != route) stack.add(route)
        }, showTab = { tab = it })
    }

    // A rail on wide windows, and on short ones (phones and players in landscape), where a bar takes too much height.
    val window = currentWindowAdaptiveInfoV2().windowSizeClass
    val layout = if (window.isWidthAtLeastBreakpoint(WindowSizeClass.WIDTH_DP_MEDIUM_LOWER_BOUND) ||
        !window.isHeightAtLeastBreakpoint(WindowSizeClass.HEIGHT_DP_MEDIUM_LOWER_BOUND)) NavigationSuiteType.NavigationRail
        else NavigationSuiteType.NavigationBar
    val showMini = nowPlaying != null
    // A rail leaves the gesture bar to the content.
    val systemBottom = if (layout == NavigationSuiteType.NavigationBar) 0.dp else WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding()
    val bottomInset = systemBottom + if (showMini) 80.dp else 0.dp

    CompositionLocalProvider(LocalActions provides actions, LocalNowPlaying provides nowPlaying, LocalBottomInset provides bottomInset) {
        Box(Modifier.fillMaxSize()) {
            NavigationSuiteScaffold(
                layoutType = layout,
                navigationSuiteItems = {
                    Tab.entries.forEach { item ->
                        item(
                            selected = tab == item,
                            onClick = {
                                if (tab == item) stacks.getValue(item).run { while (size > 1) removeAt(lastIndex) } else tab = item
                            },
                            icon = { Icon(painterResource(item.icon), contentDescription = null) },
                            label = { Text(item.label) },
                        )
                    }
                },
            ) {
                Box(Modifier.fillMaxSize()) {
                    // Back from another tab's first screen goes to the Library before leaving the app.
                    BackHandler(enabled = tab != Tab.LIBRARY && stacks.getValue(tab).size == 1) { tab = Tab.LIBRARY }
                    tabStates.SaveableStateProvider(tab.name) {
                        val stack = stacks.getValue(tab)
                        NavDisplay(
                            backStack = stack,
                            onBack = { if (stack.size > 1) stack.removeAt(stack.lastIndex) },
                            entryDecorators = listOf(rememberSaveableStateHolderNavEntryDecorator()),
                            entryProvider = { route ->
                                NavEntry(route, contentKey = Route.encode(route)) {
                                    CompositionLocalProvider(LocalBack provides { if (stack.size > 1) stack.removeAt(stack.lastIndex) }) {
                                    when (it) {
                                        Route.Library -> LibraryHome()
                                        Route.Search -> SearchScreen()
                                        Route.Sync -> Box(Modifier.padding(bottom = bottomInset)) {
                                            SyncScreen("Sync", sync) { mode?.let { current -> ListeningCard(current, sync::setMode) } }
                                        }
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
                    Column(Modifier.align(Alignment.BottomCenter).padding(bottom = systemBottom)) {
                        SnackbarHost(snackbar)
                        AnimatedVisibility(showMini, enter = slideInVertically { it } + fadeIn(), exit = slideOutVertically { it } + fadeOut()) {
                            nowPlaying?.let { MiniPlayer(it, player, onOpen = { expanded = true }) }
                        }
                    }
                }
            }
            NowPlaying(visible = expanded && nowPlaying != null, player = player, onClose = { expanded = false })
        }
    }
}

/**
 * The song playing, above the navigation: tap or swipe up opens Now Playing, swipe sideways changes song. A line
 * along its bottom shows how far the song is.
 */
@Composable
private fun MiniPlayer(song: PlayerModel.NowPlaying, player: PlayerModel, onOpen: () -> Unit) {
    val path by player.audioPath.collectAsStateWithLifecycle()
    val progress by player.progress.collectAsStateWithLifecycle(PlayerModel.Progress(0, 0))
    val problem = song.error ?: path.unsupported?.let { "This device cannot decode $it" }
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        tonalElevation = 3.dp,
        shadowElevation = 6.dp,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 8.dp).height(64.dp)
            .clip(RoundedCornerShape(16.dp))
            .clickable(onClick = onOpen, onClickLabel = "Open Now Playing")
            .pointerInput(Unit) {
                var dx = 0f
                var dy = 0f
                detectDragGestures(onDragStart = { dx = 0f; dy = 0f }, onDragEnd = {
                    when {
                        dy < -48.dp.toPx() && abs(dy) > abs(dx) -> onOpen()
                        dx < -64.dp.toPx() -> player.next()
                        dx > 64.dp.toPx() -> player.previous()
                    }
                }) { _, amount ->
                    dx += amount.x
                    dy += amount.y
                }
            }
            .semantics { onClick("Open Now Playing") { onOpen(); true } },
    ) {
        Box {
            Row(Modifier.fillMaxSize().padding(start = 8.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Cover(song.artwork?.path?.let(::File), Modifier.size(48.dp), corner = 8.dp)
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
    }
}
