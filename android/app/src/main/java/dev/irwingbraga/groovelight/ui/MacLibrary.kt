package dev.irwingbraga.groovelight.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import dev.irwingbraga.groovelight.library.Track
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.runtime.mutableStateOf
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.PrimaryScrollableTabRow
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.irwingbraga.groovelight.R
import dev.irwingbraga.groovelight.library.Availability
import dev.irwingbraga.groovelight.library.CatalogAlbum
import dev.irwingbraga.groovelight.library.CatalogTrack
import dev.irwingbraga.groovelight.library.TransferRequest
import dev.irwingbraga.groovelight.sync.Transfers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

// The Mac's whole library, browsed on the device: what is not here can be asked for (an album, an artist, a song), and
// what is here can be let go. Requests wait on the device until the Mac is reachable, then a sync brings the music.

/** "Downloaded": only what is on this device, or (off) the Mac's whole library with it. Also in Settings. */
@Composable
fun DownloadedFilter() {
    val library = LocalActions.current.library
    val source by library.source.collectAsStateWithLifecycle()
    val only = source == LibraryModel.Source.DEVICE
    FilterChip(
        selected = only,
        onClick = { library.setSource(if (only) LibraryModel.Source.MAC else LibraryModel.Source.DEVICE) },
        label = { Text("Downloaded") },
        leadingIcon = if (only) ({ Icon(painterResource(R.drawable.ic_check_circle), null, Modifier.size(18.dp)) }) else null,
        modifier = Modifier.padding(end = 4.dp).semantics { contentDescription = if (only) "Showing only music on this device" else "Showing the Mac's music too" },
    )
}

/** The Mac away, or requests waiting for it. */
@Composable
fun CatalogNotice(state: LibraryModel.CatalogState, waiting: Int, empty: Boolean) {
    val text = when {
        state.error != null && state.reachable != false && !empty -> state.error
        state.reachable == false && !empty -> "The Mac is not reachable: this is its library as of the last time." +
            if (waiting > 0) " ${requests(waiting)} will be sent when it is." else ""
        waiting > 0 && state.loading -> "Sending ${requests(waiting).lowercase()} to the Mac…"
        waiting > 0 -> "${requests(waiting)} waiting for the Mac."
        else -> null
    } ?: return
    Surface(color = MaterialTheme.colorScheme.secondaryContainer, shape = RoundedCornerShape(12.dp),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
        Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(painterResource(R.drawable.ic_schedule), null, Modifier.size(20.dp))
            Spacer(Modifier.width(12.dp))
            Text(text, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

private fun requests(count: Int) = if (count == 1) "1 request" else "$count requests"

/** A cover of the Mac's library: the device's copy, else a small one fetched from the Mac when shown. */
@Composable
fun CatalogCover(hash: String?, modifier: Modifier, round: Boolean = false, corner: androidx.compose.ui.unit.Dp = 8.dp) {
    val library = LocalActions.current.library
    var version by remember(hash) { mutableIntStateOf(0) }
    val file = remember(hash, version) { library.catalogCover(hash) }
    LaunchedEffect(hash, file) { if (hash != null && file == null && library.fetchCatalogCover(hash)) version++ }
    Cover(file, modifier, round = round, corner = corner)
}

/** A small mark of where an album or song stands: here, coming, waiting for the Mac, or leaving. */
@Composable
fun AvailabilityMark(availability: Availability, modifier: Modifier = Modifier) {
    val (icon, label) = when (availability) {
        Availability.ON_DEVICE -> R.drawable.ic_check_circle to "On this device"
        Availability.ARRIVING -> R.drawable.ic_download to "Arrives at the next sync"
        Availability.WAITING -> R.drawable.ic_schedule to "Waiting for the Mac"
        Availability.LEAVING -> R.drawable.ic_remove_circle to "Leaves at the next sync"
        Availability.ON_MAC -> return
    }
    Icon(painterResource(icon), contentDescription = label, modifier = modifier.size(18.dp),
        tint = if (availability == Availability.LEAVING) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary)
}

private fun availabilityText(availability: Availability): String = when (availability) {
    Availability.ON_DEVICE -> "On this device"
    Availability.ARRIVING -> "Arrives at the next sync"
    Availability.WAITING -> "Waiting for the Mac"
    Availability.LEAVING -> "Leaves at the next sync"
    Availability.ON_MAC -> "On the Mac"
}

@Composable
fun CatalogAlbumGrid(albums: List<CatalogAlbum>, header: (androidx.compose.foundation.lazy.grid.LazyGridScope.() -> Unit)? = null) {
    val actions = LocalActions.current
    val holdings by actions.library.holdings.collectAsStateWithLifecycle()
    val size by actions.library.gridSize.collectAsStateWithLifecycle()
    LazyVerticalGrid(GridCells.Adaptive(if (LocalWindowShape.current.narrow) minOf(size, 128f).dp else size.dp), Modifier.fillMaxSize().pinchToResize { actions.library.setGridSize(size * it) },
        state = rememberLazyGridState(),
        contentPadding = PaddingValues(start = 12.dp, end = 12.dp, top = 8.dp + LocalTopInset.current, bottom = 16.dp + LocalBottomInset.current),
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        header?.invoke(this)
        items(albums, key = { it.key }) { album ->
            val availability = holdings.of(album)
            // An album here opens its full page; one only on the Mac, its page there (to add it).
            val here = album.key in holdings.albumKeys
            Column(Modifier.clip(RoundedCornerShape(10.dp)).clickable(onClickLabel = "Open album") {
                actions.open(if (here) Route.AlbumPage(album.key) else Route.MacAlbumPage(album.key))
            }.padding(4.dp).semantics(mergeDescendants = true) {}) {
                Box {
                    CatalogCover(album.artworkHash, Modifier.sharedCover(if (here) "album:${album.key}" else "macalbum:${album.key}").fillMaxWidth())
                    if (availability != Availability.ON_MAC) {
                        Box(Modifier.align(Alignment.BottomEnd).padding(6.dp).clip(CircleShape).background(MaterialTheme.colorScheme.surface)
                            .padding(3.dp)) { AvailabilityMark(availability) }
                    }
                }
                Spacer(Modifier.height(8.dp))
                Text(album.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(album.artist, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
fun CatalogArtists() {
    val actions = LocalActions.current
    val artists by actions.library.mergedArtists.collectAsStateWithLifecycle()
    val holdings by actions.library.holdings.collectAsStateWithLifecycle()
    val local by actions.library.artists.collectAsStateWithLifecycle()
    val localNames = remember(local) { local.orEmpty().map { it.name }.toSet() }
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(top = LocalTopInset.current, bottom = 16.dp + LocalBottomInset.current)) {
        items(artists.orEmpty(), key = { it.name }) { artist ->
            ListItem(
                headlineContent = { Text(artist.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                supportingContent = { Text(if (artist.albums == 1) "1 album" else "${artist.albums} albums") },
                leadingContent = {
                    val shared = if (artist.name in localNames) "artist:${artist.name}" else "macartist:${artist.name}"
                    CatalogCover(artist.artworkHash, Modifier.sharedCover(shared).size(52.dp), round = true)
                },
                trailingContent = {
                    when {
                        (artist.name in holdings.after.artists) != (artist.name in holdings.chosen.artists) -> AvailabilityMark(Availability.WAITING)
                        artist.name in localNames -> AvailabilityMark(Availability.ON_DEVICE)
                    }
                },
                colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                modifier = Modifier.clickable { actions.open(if (artist.name in localNames) Route.ArtistPage(artist.name) else Route.MacArtistPage(artist.name)) },
            )
        }
    }
}

@Composable
fun CatalogSongs() {
    val actions = LocalActions.current
    val tracks by actions.library.mergedTracks.collectAsStateWithLifecycle()
    val albums by actions.library.catalogAlbumsByKey.collectAsStateWithLifecycle()
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(top = LocalTopInset.current, bottom = 16.dp + LocalBottomInset.current)) {
        items(tracks.orEmpty(), key = { it.id }) { track ->
            CatalogSongRow(track, albums[track.albumKey], showCover = true)
        }
    }
}

/**
 * A song of the Mac's library: plays when it is here (and long press offers its menu, as in the device's lists);
 * otherwise a button asks for it.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun CatalogSongRow(track: CatalogTrack, album: CatalogAlbum?, showCover: Boolean) {
    val actions = LocalActions.current
    val holdings by actions.library.holdings.collectAsStateWithLifecycle()
    val availability = holdings.of(track, album)
    val scope = rememberCoroutineScope()
    val haptics = LocalHapticFeedback.current
    // The song here, once its menu was asked for (kept after the menu closes, for the dialogs it opens).
    var local by remember { mutableStateOf<Track?>(null) }
    var menu by remember { mutableStateOf(false) }
    Box {
    local?.let {
        SongMenu(listOf(it), expanded = menu, onDismiss = { menu = false }, albumKey = it.albumKey, artist = it.artist, subject = MenuSubject.Song(it))
    }
    ListItem(
        headlineContent = { Text(track.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        supportingContent = {
            Text(listOfNotNull(if (showCover) track.artist else track.artist.takeIf { it != album?.artist }, if (showCover) album?.title else null,
                availabilityText(availability).takeIf { availability != Availability.ON_MAC }).joinToString(" · "),
                maxLines = 1, overflow = TextOverflow.Ellipsis)
        },
        leadingContent = {
            if (showCover) CatalogCover(track.artworkHash ?: album?.artworkHash, Modifier.size(48.dp), corner = 6.dp)
            else Text(track.trackNumber?.toString() ?: "", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center, modifier = Modifier.width(28.dp))
        },
        trailingContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (!showCover) Text(duration(track.durationMs), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                when {
                    availability == Availability.ON_MAC || availability == Availability.LEAVING -> IconButton(onClick = {
                        actions.library.request(TransferRequest.ADD, TransferRequest.SONG, track.id.toString())
                        actions.notify("\"${track.title}\" will come to this device")
                    }) { Icon(painterResource(R.drawable.ic_add_circle), contentDescription = "Add ${track.title} to this device") }
                    holdings.canRemove(track) -> IconButton(onClick = {
                        actions.library.request(TransferRequest.REMOVE, TransferRequest.SONG, track.id.toString())
                    }) { AvailabilityMark(availability) }
                    else -> Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) { AvailabilityMark(availability) }
                }
            }
        },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        modifier = Modifier.combinedClickable(onClick = {
            if (track.id in holdings.trackIds) scope.launch {
                // Here: played from the device's copy, with the rest of the album that is here.
                val local = actions.library.tracksOfAlbum(track.albumKey).first()
                val start = local.indexOfFirst { it.id == track.id }.coerceAtLeast(0)
                actions.player.play(actions.library.mediaItems(local, "Album · ${album?.title ?: ""}"), start, null)
            } else actions.notify("Add it to this device to play it")
        }, onLongClick = if (track.id in holdings.trackIds) ({
            scope.launch {
                actions.library.track(track.id).first()?.let {
                    haptics.performHapticFeedback(HapticFeedbackType.LongPress)
                    local = it
                    menu = true
                }
            }
        }) else null, onLongClickLabel = "More actions"),
    )
    }
}

/** An album of the Mac's library: add it to this device (or let it go), or open it when it is here. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun MacAlbumPage(key: String) {
    val actions = LocalActions.current
    val known = remember(key) { actions.library.catalogAlbums.value?.firstOrNull { it.key == key } }
    val album by remember(key) { actions.library.catalogAlbum(key) }.collectAsStateWithLifecycle(known)
    val tracks by remember(key) { actions.library.catalogTracksOfAlbum(key) }.collectAsStateWithLifecycle(emptyList())
    val holdings by actions.library.holdings.collectAsStateWithLifecycle()
    val current = album ?: return GlassTop(glassVisible = false, bar = { CatalogBar("") }) { Loading() }
    val availability = holdings.of(current)
    val list = rememberLazyListState()
    val scrolled by remember { derivedStateOf { list.firstVisibleItemIndex > 0 } }
    val here = tracks.count { it.id in holdings.trackIds }
    GlassTop(glassVisible = scrolled, bar = { CatalogBar(if (scrolled) current.title else "") }) {
        LazyColumn(Modifier.fillMaxSize(), state = list, contentPadding = PaddingValues(top = LocalTopInset.current, bottom = 24.dp + LocalBottomInset.current)) {
            item(key = "header") {
                Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    CatalogCover(current.artworkHash, Modifier.sharedCover("macalbum:$key").widthIn(max = if (LocalWindowShape.current.short) 120.dp else 240.dp)
                        .fillMaxWidth(0.65f), corner = 10.dp)
                    Spacer(Modifier.height(16.dp))
                    Text(current.title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center,
                        modifier = Modifier.semantics { heading() })
                    Text(current.artist, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.clip(RoundedCornerShape(4.dp)).clickable(enabled = !current.isCompilation) {
                            actions.open(Route.MacArtistPage(current.artist))
                        }.padding(4.dp))
                    Text(listOfNotNull(current.year?.toString(), songCount(tracks.size), catalogQuality(tracks)).joinToString(" · "),
                        style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.height(12.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        AvailabilityMark(availability)
                        if (availability != Availability.ON_MAC) Spacer(Modifier.width(6.dp))
                        Text(when {
                            availability == Availability.ON_DEVICE && here in 1 until tracks.size -> "$here of ${tracks.size} songs on this device"
                            else -> availabilityText(availability)
                        }, style = MaterialTheme.typography.labelLarge)
                    }
                    Spacer(Modifier.height(12.dp))
                    AlbumTransferButtons(current, availability, holdings)
                    Spacer(Modifier.height(8.dp))
                }
            }
            items(tracks, key = { it.id }) { track -> CatalogSongRow(track, current, showCover = false) }
        }
    }
}

@Composable
private fun AlbumTransferButtons(album: CatalogAlbum, availability: Availability, holdings: LibraryModel.Holdings) {
    val actions = LocalActions.current
    val default by actions.library.encoding.collectAsStateWithLifecycle()
    var addAs by remember { mutableStateOf(false) }
    var change by remember { mutableStateOf(false) }
    val add = { format: String? ->
        actions.library.request(TransferRequest.ADD, TransferRequest.ALBUM, album.key, format)
        actions.notify("\"${album.title}\" will come to this device" + (format?.let { " as ${formatLabel(it)}" } ?: ""))
    }
    val remove = {
        actions.library.request(TransferRequest.REMOVE, TransferRequest.ALBUM, album.key)
        actions.notify("\"${album.title}\" will leave this device at the next sync")
    }
    Row(Modifier.widthIn(max = 420.dp).fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        when (availability) {
            Availability.ON_MAC, Availability.LEAVING -> {
                Button(onClick = { add(null) }, modifier = Modifier.weight(1f)) {
                    Icon(painterResource(R.drawable.ic_download), null, Modifier.size(20.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(if (availability == Availability.LEAVING) "Keep on This Device" else "Add to This Device")
                }
                // Or in another format than this device's: Opus, AAC or MP3 for this album only.
                Box {
                    FilledTonalIconButton(onClick = { addAs = true }) {
                        Icon(painterResource(R.drawable.ic_expand_more), contentDescription = "Add in another format")
                    }
                    FormatMenu(addAs, onDismiss = { addAs = false }, title = "Add as", current = null) { add(it) }
                }
            }
            else -> {
                if (album.key in holdings.albumKeys) FilledTonalButton(onClick = { actions.open(Route.AlbumPage(album.key)) }, modifier = Modifier.weight(1f)) {
                    Icon(painterResource(R.drawable.ic_play), null, Modifier.size(20.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Open")
                }
                if (holdings.canRemove(album)) OutlinedButton(onClick = remove, modifier = Modifier.weight(1f)) {
                    Text(if (availability == Availability.ON_DEVICE) "Remove" else "Cancel")
                }
            }
        }
    }
    // Its format (chosen for it, else this device's), and changing it: the next sync makes its songs again.
    if (availability != Availability.ON_MAC) {
        val chosen = holdings.after.encodingOf(album)
        Box(Modifier.padding(top = 4.dp)) {
            TextButton(onClick = { change = true }) {
                Text("Format: " + formatLabel(chosen ?: default ?: actions.library.macEncoding) + if (chosen == null) " (this device's)" else "")
            }
            FormatMenu(change, onDismiss = { change = false }, title = "Change format", current = chosen) {
                add(it)
                actions.notify("\"${album.title}\" will change to ${formatLabel(it)} at the next sync")
            }
        }
    }
    // Here, but not as an album or artist chosen here: a playlist or genre on the Mac brings it.
    if (availability == Availability.ON_DEVICE && !holdings.canRemove(album) && !holdings.after.everything) {
        Text("It is here through a playlist or genre chosen on the Mac.", style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 8.dp))
    }
}

/** An artist of the Mac's library: all their albums to this device at once, or album by album. */
@Composable
fun MacArtistPage(name: String) {
    val actions = LocalActions.current
    val albums by remember(name) { actions.library.catalogAlbumsOf(name) }.collectAsStateWithLifecycle(emptyList())
    val holdings by actions.library.holdings.collectAsStateWithLifecycle()
    val chosen = holdings.after.everything || name in holdings.after.artists
    val waiting = (name in holdings.after.artists) != (name in holdings.chosen.artists)
    // The artist's photo on the Mac, or their first cover.
    val photo by remember(name) { actions.library.catalogArtistPhoto(name) }.collectAsStateWithLifecycle(null)
    GlassTop(bar = { CatalogBar("") }) {
        CatalogAlbumGrid(albums) {
            item(key = "header", span = { GridItemSpan(maxLineSpan) }) {
                Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    CatalogCover(photo ?: albums.firstOrNull()?.artworkHash, Modifier.sharedCover("macartist:$name").widthIn(max = 200.dp).fillMaxWidth(0.5f), round = true)
                    Spacer(Modifier.height(16.dp))
                    Text(name, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center,
                        modifier = Modifier.semantics { heading() })
                    Text(if (albums.size == 1) "1 album" else "${albums.size} albums", style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.height(12.dp))
                    if (!holdings.after.everything) {
                        if (chosen) OutlinedButton(onClick = {
                            actions.library.request(TransferRequest.REMOVE, TransferRequest.ARTIST, name)
                            actions.notify("$name will leave this device at the next sync (albums chosen one by one stay)")
                        }) { Text(if (waiting) "Cancel" else "Remove Artist from This Device") }
                        else Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            val add = { format: String? ->
                                actions.library.request(TransferRequest.ADD, TransferRequest.ARTIST, name, format)
                                actions.notify("$name will come to this device" + (format?.let { " as ${formatLabel(it)}" } ?: "") +
                                    ", with albums added on the Mac later")
                            }
                            Button(onClick = { add(null) }) {
                                Icon(painterResource(R.drawable.ic_download), null, Modifier.size(20.dp))
                                Spacer(Modifier.width(8.dp))
                                Text("Add Artist to This Device")
                            }
                            var addAs by remember { mutableStateOf(false) }
                            Box {
                                FilledTonalIconButton(onClick = { addAs = true }) {
                                    Icon(painterResource(R.drawable.ic_expand_more), contentDescription = "Add in another format")
                                }
                                FormatMenu(addAs, onDismiss = { addAs = false }, title = "Add as", current = null) { add(it) }
                            }
                        }
                    }
                    if (waiting) Text("Waiting for the Mac", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.padding(top = 8.dp))
                    Spacer(Modifier.height(8.dp))
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CatalogBar(title: String) {
    val back = LocalBack.current
    TopAppBar(
        title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        navigationIcon = { IconButton(onClick = back) { Icon(painterResource(R.drawable.ic_back), contentDescription = "Back") } },
        actions = {
            Icon(painterResource(R.drawable.ic_laptop), contentDescription = "From the Mac's library", tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(end = 16.dp))
        },
        colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent, scrolledContainerColor = Color.Transparent),
    )
}

private fun songCount(count: Int) = if (count == 1) "1 song" else "$count songs"

/** "Hi-Res Lossless" or "Lossless" for an album of the Mac's library, as its badge there. */
private fun catalogQuality(tracks: List<CatalogTrack>): String? {
    val lossless = setOf("flac", "alac", "wav", "aiff", "wavPack", "monkeysAudio", "trueAudio", "oggFLAC")
    if (tracks.isEmpty() || tracks.any { it.codec !in lossless }) return null
    return if (tracks.all { (it.bitDepth ?: 16) > 16 || (it.sampleRate ?: 44_100) > 48_000 }) "Hi-Res Lossless" else "Lossless"
}

/** The formats lossless songs can come in: as they are, or one of the lossy ones (about a fifth of the size). */
val FORMATS = listOf("original" to "Original", "opus160" to "Opus 160 kbps", "aac192" to "AAC 192 kbps", "mp3_320" to "MP3 320 kbps")

fun formatLabel(format: String?): String = FORMATS.firstOrNull { it.first == format }?.second ?: "Original"

/** A menu of the formats (`current` checked), for adding an album or artist in one, or changing an album's. */
@Composable
fun FormatMenu(expanded: Boolean, onDismiss: () -> Unit, title: String, current: String?, onPick: (String) -> Unit) {
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        Text(title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
        FORMATS.forEach { (format, label) ->
            DropdownMenuItem(
                text = { Text(label) },
                leadingIcon = { if (format == current) Icon(painterResource(R.drawable.ic_check_circle), null) else Spacer(Modifier.size(24.dp)) },
                onClick = { onDismiss(); onPick(format) },
            )
        }
    }
}
