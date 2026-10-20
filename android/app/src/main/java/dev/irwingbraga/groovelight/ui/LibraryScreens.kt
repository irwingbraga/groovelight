package dev.irwingbraga.groovelight.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridScope
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.PrimaryScrollableTabRow
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import dev.irwingbraga.groovelight.R
import dev.irwingbraga.groovelight.library.Album
import dev.irwingbraga.groovelight.library.Credit
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.layout.width
import androidx.compose.ui.unit.Dp
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.launch
import java.io.File

/** Back from a page (given by the shell's navigation). */
val LocalBack = staticCompositionLocalOf<() -> Unit> { {} }

private enum class Section(val title: String) { ALBUMS("Albums"), ARTISTS("Artists"), SONGS("Songs"), PLAYLISTS("Playlists") }

/** The Library tab: Albums, Artists, Songs and Playlists, swiped or picked from the tabs, with sorting where it helps. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibraryHome() {
    val library = LocalActions.current.library
    val albums by library.albums.collectAsStateWithLifecycle()
    val pager = rememberPagerState { Section.entries.size }
    val scope = rememberCoroutineScope()
    val section = Section.entries[pager.currentPage]
    Column(Modifier.fillMaxSize()) {
        val source by library.source.collectAsStateWithLifecycle()
        val sortable = source == LibraryModel.Source.DEVICE && (section == Section.ALBUMS || section == Section.SONGS)
        // A short window: no title bar, the switch and sorting on one row.
        if (LocalWindowShape.current.short) {
            Row(Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.statusBars).padding(end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                SourceSwitch(Modifier.weight(1f))
                if (sortable) SortMenu(section)
            }
        } else {
            TopAppBar(
                title = { Text("Library", fontWeight = FontWeight.SemiBold) },
                actions = { if (sortable) SortMenu(section) },
            )
            SourceSwitch()
        }
        if (source == LibraryModel.Source.MAC) return@Column MacLibraryContent()
        PrimaryScrollableTabRow(selectedTabIndex = pager.currentPage, edgePadding = 8.dp, containerColor = Color.Transparent, divider = {}) {
            Section.entries.forEachIndexed { index, item ->
                Tab(selected = pager.currentPage == index, onClick = { scope.launch { pager.animateScrollToPage(index) } }, text = { Text(item.title) },
                    unselectedContentColor = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        when {
            albums == null -> Loading()
            albums?.isEmpty() == true -> EmptyState(R.drawable.ic_library, "No music yet",
                "Choose what this device gets on your Mac (Groovelight, Devices), then sync.",
                Modifier.padding(bottom = LocalBottomInset.current)) {
                val actions = LocalActions.current
                Button(onClick = { actions.open(Route.Sync) }) { Text("Go to Sync") }
            }
            else -> HorizontalPager(pager, Modifier.fillMaxSize(), key = { it }) { page ->
                when (Section.entries[page]) {
                    Section.ALBUMS -> AlbumsSection(albums.orEmpty())
                    Section.ARTISTS -> ArtistsSection()
                    Section.SONGS -> SongsSection()
                    Section.PLAYLISTS -> PlaylistsSection()
                }
            }
        }
    }
}

@Composable
private fun SortMenu(section: Section) {
    val library = LocalActions.current.library
    var open by remember { mutableStateOf(false) }
    val albumOrder by library.albumOrder.collectAsStateWithLifecycle()
    val songOrder by library.songOrder.collectAsStateWithLifecycle()
    Box {
        IconButton(onClick = { open = true }) { Icon(painterResource(R.drawable.ic_sort), contentDescription = "Sort ${section.title.lowercase()}") }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            Text("Sort by", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
            if (section == Section.ALBUMS) LibraryModel.AlbumOrder.entries.forEach { order ->
                DropdownMenuItem(text = { Text(order.label) }, leadingIcon = { RadioButton(selected = order == albumOrder, onClick = null) },
                    onClick = { open = false; library.setAlbumOrder(order) })
            } else LibraryModel.SongOrder.entries.forEach { order ->
                DropdownMenuItem(text = { Text(order.label) }, leadingIcon = { RadioButton(selected = order == songOrder, onClick = null) },
                    onClick = { open = false; library.setSongOrder(order) })
            }
        }
    }
}

@Composable
private fun AlbumsSection(albums: List<Album>) {
    val actions = LocalActions.current
    val order by actions.library.albumOrder.collectAsStateWithLifecycle()
    val grid = rememberLazyGridState()
    // A new sort order starts from the top.
    LaunchedEffect(Unit) { actions.library.albumOrder.drop(1).collect { grid.scrollToItem(0) } }
    val size by actions.library.gridSize.collectAsStateWithLifecycle()
    // Pinching makes the covers bigger or smaller (fewer or more per row); one finger still scrolls.
    Box(Modifier.fillMaxSize().pinchToResize { zoom -> actions.library.setGridSize(size * zoom) }) {
        // Two covers a row at least in a narrow window (split screen), where the size set by pinching may fit one.
        val minSize = if (LocalWindowShape.current.narrow) minOf(size, 128f).dp else size.dp
        AlbumGrid(albums, grid = grid, minSize = minSize) { actions.open(Route.AlbumPage(it.key)) }
        val first by remember { derivedStateOf { grid.firstVisibleItemIndex } }
        val visible by remember { derivedStateOf { grid.layoutInfo.visibleItemsInfo.size } }
        FastScroller(
            count = albums.size, firstVisible = first, visibleCount = visible,
            scrolling = grid.isScrollInProgress, scrollTo = { grid.scrollToItem(it) },
            label = { index ->
                albums.getOrNull(index)?.let { album ->
                    when (order) {
                        LibraryModel.AlbumOrder.ARTIST -> indexLetter(album.artist)
                        LibraryModel.AlbumOrder.TITLE -> indexLetter(album.title)
                        LibraryModel.AlbumOrder.YEAR -> album.year?.toString() ?: "-"
                        LibraryModel.AlbumOrder.RECENT -> null
                    }
                }
            },
            modifier = Modifier.align(Alignment.TopEnd).padding(bottom = LocalBottomInset.current),
        )
    }
}

@Composable
private fun AlbumGrid(
    albums: List<Album>,
    grid: LazyGridState = rememberLazyGridState(),
    minSize: Dp = 152.dp,
    subtitle: (Album) -> String = { it.artist },
    header: (LazyGridScope.() -> Unit)? = null,
    footer: (LazyGridScope.() -> Unit)? = null,
    onOpen: (Album) -> Unit,
) {
    LazyVerticalGrid(
        GridCells.Adaptive(minSize), Modifier.fillMaxSize(), state = grid,
        contentPadding = PaddingValues(start = 12.dp, end = 12.dp, top = 8.dp, bottom = 16.dp + LocalBottomInset.current),
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        header?.invoke(this)
        items(albums, key = { it.key }) { album -> AlbumCard(album, subtitle(album)) { onOpen(album) } }
        footer?.invoke(this)
    }
}

@Composable
private fun ArtistsSection() {
    val actions = LocalActions.current
    val artists by actions.library.artists.collectAsStateWithLifecycle()
    val list = rememberLazyListState()
    val all = artists.orEmpty()
    Box(Modifier.fillMaxSize()) {
        LazyColumn(Modifier.fillMaxSize(), state = list, contentPadding = PaddingValues(bottom = 16.dp + LocalBottomInset.current)) {
            items(all, key = { it.name }) { artist ->
                ListItem(
                    headlineContent = { Text(artist.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    supportingContent = { Text(if (artist.albums == 1) "1 album" else "${artist.albums} albums") },
                    leadingContent = { Cover(actions.library.cover(artist.artworkHash), Modifier.sharedCover("artist:${artist.name}").size(52.dp), round = true) },
                    colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                    modifier = Modifier.clickable { actions.open(Route.ArtistPage(artist.name)) },
                )
            }
        }
        val first by remember { derivedStateOf { list.firstVisibleItemIndex } }
        val visible by remember { derivedStateOf { list.layoutInfo.visibleItemsInfo.size } }
        FastScroller(all.size, first, visible, list.isScrollInProgress, { list.scrollToItem(it) },
            { all.getOrNull(it)?.name?.let(::indexLetter) }, Modifier.align(Alignment.TopEnd).padding(bottom = LocalBottomInset.current))
    }
}

@Composable
private fun SongsSection() {
    val actions = LocalActions.current
    val tracks by actions.library.tracks.collectAsStateWithLifecycle()
    val albums by actions.library.albumsByKey.collectAsStateWithLifecycle()
    val order by actions.library.songOrder.collectAsStateWithLifecycle()
    val list = rememberLazyListState()
    LaunchedEffect(Unit) { actions.library.songOrder.drop(1).collect { list.scrollToItem(0) } }
    val all = tracks.orEmpty()
    val play = { start: Int, shuffle: Boolean? -> actions.player.play(actions.library.mediaItems(all, "Songs"), start, shuffle) }
    Box(Modifier.fillMaxSize()) {
        LazyColumn(Modifier.fillMaxSize(), state = list, contentPadding = PaddingValues(bottom = 16.dp + LocalBottomInset.current)) {
            item(key = "buttons") {
                PlayButtons(onPlay = { play(0, false) }, onShuffle = { play(0, true) }, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
            }
            itemsIndexed(all, key = { _, track -> track.id }) { index, track ->
                SongRow(track, listOfNotNull(track.artist, albums[track.albumKey]?.title).joinToString(" · "), onClick = { play(index, null) })
            }
        }
        val first by remember { derivedStateOf { (list.firstVisibleItemIndex - 1).coerceAtLeast(0) } }
        val visible by remember { derivedStateOf { list.layoutInfo.visibleItemsInfo.size } }
        FastScroller(all.size, first, visible, list.isScrollInProgress, { list.scrollToItem(it + 1) },
            { index ->
                all.getOrNull(index)?.let { track ->
                    when (order) {
                        LibraryModel.SongOrder.TITLE -> indexLetter(track.title)
                        LibraryModel.SongOrder.ARTIST -> indexLetter(track.artist)
                        LibraryModel.SongOrder.ALBUM -> indexLetter(albums[track.albumKey]?.title ?: "")
                        LibraryModel.SongOrder.RECENT -> null
                    }
                }
            }, Modifier.align(Alignment.TopEnd).padding(bottom = LocalBottomInset.current))
    }
}

@Composable
private fun PlaylistsSection() {
    val actions = LocalActions.current
    val playlists by actions.library.playlists.collectAsStateWithLifecycle()
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 16.dp + LocalBottomInset.current)) {
        item(key = "loved") {
            ListItem(
                headlineContent = { Text("Loved Songs") },
                supportingContent = { Text("The songs you love, here and on the Mac") },
                leadingContent = { LovedCover(Modifier.sharedCover("playlist:loved").size(56.dp)) },
                colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                modifier = Modifier.clickable { actions.open(Route.LovedSongs) },
            )
        }
        items(playlists.orEmpty(), key = { it.id }) { playlist ->
            val art = rememberPlaylistArt(playlist) { actions.library.playlistArt(playlist) }
            ListItem(
                headlineContent = { Text(playlist.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                supportingContent = { Text((if (playlist.songs == 1) "1 song" else "${playlist.songs} songs") + if (playlist.isSmart) " · Smart" else "") },
                leadingContent = {
                    val shared = Modifier.sharedCover("playlist:${playlist.id}")
                    if (art != null) PlaylistCover(art, shared.size(56.dp), hideTitle = true)
                    else Cover(actions.library.cover(playlist.artworkHash), shared.size(56.dp))
                },
                colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                modifier = Modifier.clickable { actions.open(Route.PlaylistPage(playlist.id)) },
            )
        }
    }
}

/** Loved Songs' cover: a heart on Groovelight's colors. */
@Composable
private fun LovedCover(modifier: Modifier, corner: Int = 8) {
    Box(modifier.aspectRatio(1f).clip(RoundedCornerShape(corner.dp))
        .background(Brush.linearGradient(listOf(Color(0xFF2A4CA0), Color(0xFF8E5A8A)))),
        contentAlignment = Alignment.Center) {
        Icon(painterResource(R.drawable.ic_favorite), contentDescription = null, tint = Color.White, modifier = Modifier.fillMaxSize(0.45f))
    }
}

/** A page's bar: Back, and the title once the header has scrolled away. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PageBar(title: String, showTitle: Boolean, actions: @Composable () -> Unit = {}) {
    val back = LocalBack.current
    TopAppBar(
        title = { if (showTitle) Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        navigationIcon = { IconButton(onClick = back) { Icon(painterResource(R.drawable.ic_back), contentDescription = "Back") } },
        actions = { actions() },
        colors = TopAppBarDefaults.topAppBarColors(containerColor = if (showTitle) MaterialTheme.colorScheme.surfaceContainer else Color.Transparent),
    )
}

/** The header of album, artist and playlist pages: the cover on a wash of its colors, titles, and Play and Shuffle. */
@Composable
private fun PageHeader(
    cover: @Composable (Modifier) -> Unit,
    title: String,
    subtitle: String? = null,
    onSubtitle: (() -> Unit)? = null,
    details: String? = null,
    badge: String? = null,
    credit: String? = null,
    onCredit: (() -> Unit)? = null,
    onPlay: (() -> Unit)? = null,
    onShuffle: (() -> Unit)? = null,
) {
    // A short window (landscape, split screen): the cover beside the titles, so the songs show at once.
    if (LocalWindowShape.current.short) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 4.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            cover(Modifier.size(if (LocalWindowShape.current.narrow) 88.dp else 112.dp).shadow(8.dp, RoundedCornerShape(8.dp)))
            Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.semantics { heading() })
                subtitle?.let {
                    Text(it, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary, maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.clip(RoundedCornerShape(4.dp)).clickable(enabled = onSubtitle != null) { onSubtitle?.invoke() })
                }
                details?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1) }
                if (onPlay != null && onShuffle != null) CompactPlayButtons(onPlay, onShuffle, Modifier.padding(top = 8.dp))
            }
        }
        return
    }
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(top = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        cover(Modifier.widthIn(max = 260.dp).fillMaxWidth(0.7f).shadow(16.dp, RoundedCornerShape(10.dp)))
        Spacer(Modifier.height(20.dp))
        Text(title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center,
            modifier = Modifier.semantics { heading() })
        subtitle?.let {
            Text(it, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary, textAlign = TextAlign.Center,
                modifier = Modifier.clip(RoundedCornerShape(4.dp)).clickable(enabled = onSubtitle != null) { onSubtitle?.invoke() }.padding(4.dp))
        }
        Row(Modifier.padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            details?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            badge?.let { QualityBadge(it) }
        }
        credit?.let {
            Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center,
                maxLines = 2, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 4.dp).clip(RoundedCornerShape(4.dp)).clickable(enabled = onCredit != null, onClickLabel = "Show the credits") {
                    onCredit?.invoke()
                }.padding(4.dp))
        }
        Spacer(Modifier.height(16.dp))
        if (onPlay != null && onShuffle != null) PlayButtons(onPlay, onShuffle, Modifier.widthIn(max = 420.dp))
        Spacer(Modifier.height(8.dp))
    }
}

/** A page's background: a wash of its cover's color at the top, behind the bar (Groovelight's cover wash). */
@Composable
private fun coverWash(cover: File?): Brush {
    val wash = rememberArtworkColors(cover)?.accent?.copy(alpha = 0.22f) ?: Color.Transparent
    return Brush.verticalGradient(0f to wash, 0.45f to Color.Transparent)
}

@Composable
private fun PageLoading() {
    Column(Modifier.fillMaxSize()) {
        PageBar("", false)
        Loading()
    }
}

@Composable
fun AlbumPage(key: String) {
    val actions = LocalActions.current
    // Drawn at once with what the list knew (the album's title and cover), so its cover can move into place while the
    // songs load.
    val known by actions.library.albumsByKey.collectAsStateWithLifecycle()
    val album by remember(key) { actions.library.album(key) }.collectAsStateWithLifecycle(known[key])
    val tracks by remember(key) { actions.library.tracksOfAlbum(key) }.collectAsStateWithLifecycle(null)
    val credits by remember(key) { actions.library.creditsOfAlbum(key) }.collectAsStateWithLifecycle(emptyList())
    val current = album ?: known[key] ?: return PageLoading()
    val songs = tracks.orEmpty()
    val source = "Album · ${current.title}"
    val play = { start: Int, shuffle: Boolean? -> actions.player.play(actions.library.mediaItems(songs, source), start, shuffle) }
    val discs = remember(songs) { songs.groupBy { it.discNumber ?: 1 } }
    val list = rememberLazyListState()
    val scrolled by remember { derivedStateOf { list.firstVisibleItemIndex > 0 } }
    val coverFile = actions.library.cover(current.artworkHash)
    val people = remember(credits) { albumCredits(credits) }
    val producers = remember(people) { people.filter { (_, roles) -> roles.any { it == "producer" || it == "co-producer" } }.take(3).map { it.first } }
    val scope = rememberCoroutineScope()
    Column(Modifier.fillMaxSize().background(coverWash(coverFile))) {
        PageBar(current.title, scrolled) {
            var menu by remember { mutableStateOf(false) }
            Box {
                IconButton(onClick = { menu = true }) { Icon(painterResource(R.drawable.ic_more), contentDescription = "More") }
                SongMenu(songs, menu, onDismiss = { menu = false }, artist = current.artist.takeUnless { current.isCompilation },
                    subject = MenuSubject.AlbumOf(current))
            }
        }
        LazyColumn(Modifier.fillMaxSize(), state = list, contentPadding = PaddingValues(bottom = 24.dp + LocalBottomInset.current)) {
            item(key = "header") {
                PageHeader(
                    cover = { Cover(coverFile, Modifier.sharedCover("album:$key").then(it), corner = 10.dp) },
                    title = current.title,
                    subtitle = current.artist,
                    onSubtitle = if (current.isCompilation) null else ({ actions.open(Route.ArtistPage(current.artist)) }),
                    details = listOfNotNull(songs.firstNotNullOfOrNull { it.genre }, current.year?.toString()).joinToString(" · ").ifEmpty { null },
                    badge = quality(songs),
                    credit = producers.takeIf { it.isNotEmpty() }?.let { "Produced by " + joinNames(it) },
                    onCredit = { scope.launch { list.animateScrollToItem(list.layoutInfo.totalItemsCount - 1) } },
                    onPlay = { play(0, false) }, onShuffle = { play(0, true) },
                )
            }
            discs.forEach { (disc, discTracks) ->
                if (discs.size > 1) item(key = "disc$disc") { SectionTitle("Disc $disc") }
                items(discTracks, key = { it.id }) { track ->
                    SongRow(
                        track,
                        supporting = track.artist.takeIf { it != current.artist },
                        onClick = { play(songs.indexOf(track), null) },
                        leading = SongLeading.Number(track.trackNumber?.toString() ?: ""),
                        showDuration = true,
                        showAlbumLink = false,
                    )
                }
            }
            if (tracks != null) item(key = "footer") {
                Text(songsSummary(songs), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(16.dp))
            }
            if (people.isNotEmpty()) {
                item(key = "credits") { SectionTitle("Credits") }
                items(people, key = { "credit:${it.first}" }) { (name, roles) ->
                    ListItem(
                        headlineContent = { Text(name) },
                        supportingContent = { Text(roles.joinToString(", ") { role -> role.replaceFirstChar(Char::uppercase) }) },
                        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                        modifier = Modifier.clickable(onClickLabel = "Show $name's credits") { actions.open(Route.PersonPage(name)) },
                    )
                }
            }
        }
    }
}

/** An album's people with their roles, album credits first then the songs' (as the Mac's credits list them). */
private fun albumCredits(credits: List<Credit>): List<Pair<String, List<String>>> {
    val roles = LinkedHashMap<String, MutableList<String>>()
    for (credit in credits.sortedBy { it.trackId != null }) {
        val list = roles.getOrPut(credit.name) { mutableListOf() }
        credit.roleList.forEach { if (it !in list) list += it }
    }
    return roles.map { it.key to it.value }
}

/** "A", "A and B", "A, B and C". */
private fun joinNames(names: List<String>): String =
    if (names.size <= 1) names.joinToString() else names.dropLast(1).joinToString(", ") + " and " + names.last()

/** A person's page, from the credits: the albums they are credited on and their songs, with their roles. */
@Composable
fun PersonPage(name: String) {
    val actions = LocalActions.current
    val page by remember(name) { actions.library.person(name) }.collectAsStateWithLifecycle(null)
    val albums by actions.library.albumsByKey.collectAsStateWithLifecycle()
    val person = page ?: return PageLoading()
    val songs = person.songs.map { it.first }
    val list = rememberLazyListState()
    val scrolled by remember { derivedStateOf { list.firstVisibleItemIndex > 0 } }
    val coverFile = actions.library.cover(person.albums.firstOrNull()?.first?.artworkHash)
    Column(Modifier.fillMaxSize().background(coverWash(coverFile))) {
        PageBar(name, scrolled)
        LazyColumn(Modifier.fillMaxSize(), state = list, contentPadding = PaddingValues(bottom = 24.dp + LocalBottomInset.current)) {
            item(key = "header") {
                PageHeader(
                    cover = { Cover(null, it, round = true) }, title = name,
                    details = person.roles.take(4).joinToString(", ") { it.replaceFirstChar(Char::uppercase) }.ifEmpty { null },
                    onPlay = if (songs.isEmpty()) null else ({ actions.player.play(actions.library.mediaItems(songs, name), 0, false) }),
                    onShuffle = if (songs.isEmpty()) null else ({ actions.player.play(actions.library.mediaItems(songs, name), 0, true) }),
                )
            }
            if (person.albums.isNotEmpty()) {
                item(key = "albumsTitle") { SectionTitle("Albums") }
                item(key = "albums") {
                    LazyRow(contentPadding = PaddingValues(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        items(person.albums, key = { it.first.key }) { (album, roles) ->
                            Box(Modifier.width(150.dp)) {
                                AlbumCard(album, roles.joinToString(", ") { it.replaceFirstChar(Char::uppercase) }.ifEmpty { album.artist }) {
                                    actions.open(Route.AlbumPage(album.key))
                                }
                            }
                        }
                    }
                }
            }
            if (person.songs.isNotEmpty()) {
                item(key = "songsTitle") { SectionTitle("Songs") }
                itemsIndexed(person.songs, key = { _, it -> "song:${it.first.id}" }) { index, (track, roles) ->
                    SongRow(track, listOfNotNull(roles.joinToString(", ") { it.replaceFirstChar(Char::uppercase) }.ifEmpty { null },
                        albums[track.albumKey]?.title).joinToString(" · "),
                        onClick = { actions.player.play(actions.library.mediaItems(songs, name), index, null) })
                }
            }
        }
    }
}

/** An artist's albums and the albums by others they are on, with Play and Shuffle for all their songs. */
@Composable
fun ArtistPage(name: String) {
    val actions = LocalActions.current
    val all by actions.library.albums.collectAsStateWithLifecycle()
    val albums by remember(name) { actions.library.albumsOf(name) }.collectAsStateWithLifecycle(all?.filter { it.artist == name })
    val appearsOn by remember(name) { actions.library.albumsAppearingOn(name) }.collectAsStateWithLifecycle(emptyList())
    val tracks by remember(name) { actions.library.tracksOfArtist(name) }.collectAsStateWithLifecycle(emptyList())
    val own = albums ?: return PageLoading()
    val play = { shuffle: Boolean -> actions.player.play(actions.library.mediaItems(tracks, "Artist · $name"), 0, shuffle) }
    val grid = rememberLazyGridState()
    val scrolled by remember { derivedStateOf { grid.firstVisibleItemIndex > 0 } }
    val coverFile = actions.library.cover(own.firstOrNull()?.artworkHash ?: appearsOn.firstOrNull()?.artworkHash)
    Column(Modifier.fillMaxSize().background(coverWash(coverFile))) {
        PageBar(name, scrolled) {
            var menu by remember { mutableStateOf(false) }
            Box {
                IconButton(onClick = { menu = true }) { Icon(painterResource(R.drawable.ic_more), contentDescription = "More") }
                SongMenu(tracks, menu && tracks.isNotEmpty(), onDismiss = { menu = false }, subject = MenuSubject.Artist(name))
            }
        }
        AlbumGrid(
            own, grid = grid, subtitle = { it.year?.toString() ?: "" },
            header = {
                item(key = "header", span = { GridItemSpan(maxLineSpan) }) {
                    PageHeader(
                        cover = { Cover(coverFile, Modifier.sharedCover("artist:$name").then(it), round = true) }, title = name,
                        details = listOfNotNull(
                            own.size.takeIf { it > 0 }?.let { if (it == 1) "1 album" else "$it albums" },
                            if (tracks.size == 1) "1 song" else "${tracks.size} songs",
                        ).joinToString(" · "),
                        onPlay = if (tracks.isEmpty()) null else ({ play(false) }),
                        onShuffle = if (tracks.isEmpty()) null else ({ play(true) }),
                    )
                }
                if (own.isNotEmpty()) item(key = "albums", span = { GridItemSpan(maxLineSpan) }) { SectionTitle("Albums", Modifier.padding(start = 0.dp)) }
            },
            footer = {
                if (appearsOn.isNotEmpty()) {
                    item(key = "appears", span = { GridItemSpan(maxLineSpan) }) { SectionTitle("Appears On") }
                    items(appearsOn, key = { "appears:${it.key}" }) { album -> AlbumCard(album) { actions.open(Route.AlbumPage(album.key)) } }
                }
            },
        ) { actions.open(Route.AlbumPage(it.key)) }
    }
}

/** A playlist's page, or Loved Songs (`id` null). */
@Composable
fun PlaylistPage(id: Long?) {
    val actions = LocalActions.current
    val playlist by remember(id) { id?.let { actions.library.playlist(it) } ?: flowOf(null) }.collectAsStateWithLifecycle(null)
    val tracks by remember(id) { id?.let { actions.library.tracksOfPlaylist(it) } ?: actions.library.lovedTracks() }.collectAsStateWithLifecycle(null)
    val albums by actions.library.albumsByKey.collectAsStateWithLifecycle()
    val songs = tracks ?: return PageLoading()
    val name = if (id == null) "Loved Songs" else playlist?.name ?: ""
    val play = { start: Int, shuffle: Boolean? ->
        actions.player.play(actions.library.mediaItems(songs, if (id == null) name else "Playlist · $name"), start, shuffle)
    }
    val list = rememberLazyListState()
    val scrolled by remember { derivedStateOf { list.firstVisibleItemIndex > 0 } }
    val covers = remember(songs) { songs.mapNotNull { it.artworkHash }.distinct().take(4).mapNotNull { actions.library.cover(it) } }
    val art = playlist?.let { current -> rememberPlaylistArt(current to songs.size) { actions.library.playlistArt(current) } }
    Column(Modifier.fillMaxSize().background(coverWash(covers.firstOrNull()))) {
        PageBar(name, scrolled) {
            var menu by remember { mutableStateOf(false) }
            Box {
                IconButton(onClick = { menu = true }) { Icon(painterResource(R.drawable.ic_more), contentDescription = "More") }
                SongMenu(songs, menu && songs.isNotEmpty(), onDismiss = { menu = false },
                    subject = id?.let { MenuSubject.PlaylistOf(it, name) })
            }
        }
        LazyColumn(Modifier.fillMaxSize(), state = list, contentPadding = PaddingValues(bottom = 24.dp + LocalBottomInset.current)) {
            item(key = "header") {
                PageHeader(
                    cover = { base ->
                        val modifier = Modifier.sharedCover("playlist:${id ?: "loved"}").then(base)
                        when {
                            id == null -> LovedCover(modifier, corner = 10)
                            art != null -> PlaylistCover(art, modifier, corner = 10.dp)
                            else -> MosaicCover(covers, modifier, corner = 10.dp)
                        }
                    },
                    title = name,
                    details = listOfNotNull(songsSummary(songs), if (playlist?.isSmart == true) "Smart playlist" else null).joinToString(" · "),
                    onPlay = if (songs.isEmpty()) null else ({ play(0, false) }),
                    onShuffle = if (songs.isEmpty()) null else ({ play(0, true) }),
                )
            }
            if (songs.isEmpty()) item(key = "empty") {
                Text(if (id == null) "Tap the heart in Now Playing, or love songs on the Mac: they show here." else "None of this playlist's songs are on this device.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth().padding(32.dp))
            }
            itemsIndexed(songs, key = { index, track -> "$index:${track.id}" }) { index, track ->
                SongRow(track, listOfNotNull(track.artist, albums[track.albumKey]?.title).joinToString(" · "), onClick = { play(index, null) })
            }
        }
    }
}
