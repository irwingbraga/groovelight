package dev.irwingbraga.groovelight.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.ui.geometry.Rect
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.FilledIconButton
import androidx.compose.runtime.Immutable
import dev.irwingbraga.groovelight.library.TransferRequest
import androidx.compose.material3.TextButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.AlertDialog
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.TextFieldValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.SharedTransitionScope
import androidx.compose.animation.AnimatedVisibilityScope
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import coil3.compose.AsyncImage
import coil3.request.ImageRequest
import coil3.request.crossfade
import androidx.compose.ui.platform.LocalContext
import dev.irwingbraga.groovelight.R
import dev.irwingbraga.groovelight.library.Album
import dev.irwingbraga.groovelight.library.Track
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.io.File
import kotlin.math.roundToInt

/** What screens do with songs, and where they go: given by the shell. */
class Actions(
    val library: LibraryModel,
    val player: PlayerModel,
    private val snackbar: SnackbarHostState,
    private val scope: CoroutineScope,
    val open: (Route) -> Unit,
    /** Shows a tab's first screen (the empty library sends to Sync). */
    val showTab: (Tab) -> Unit,
) {
    fun playNext(tracks: List<Track>) {
        player.playNext(library.mediaItems(tracks))
        notify(if (tracks.size == 1) "\"${tracks[0].title}\" will play next" else "${tracks.size} songs will play next")
    }

    fun addToQueue(tracks: List<Track>) {
        player.addToQueue(library.mediaItems(tracks))
        notify(if (tracks.size == 1) "Added \"${tracks[0].title}\" to the queue" else "Added ${tracks.size} songs to the queue")
    }

    fun notify(message: String) {
        scope.launch {
            snackbar.currentSnackbarData?.dismiss()
            snackbar.showSnackbar(message)
        }
    }
}

val LocalActions = staticCompositionLocalOf<Actions> { error("Screens are shown inside PlayerShell") }

/** The song playing, for lists to mark it. */
val LocalNowPlaying = compositionLocalOf<PlayerModel.NowPlaying?> { null }

/** Room the lists leave at their end for the mini player (and the navigation bar's inset when a rail is shown). */
val LocalBottomInset = compositionLocalOf { 0.dp }

/** A cover from the Mac, or a placeholder. */
@Composable
fun Cover(file: File?, modifier: Modifier, round: Boolean = false, corner: Dp = 8.dp) {
    val shape = if (round) CircleShape else RoundedCornerShape(corner)
    Box(modifier.aspectRatio(1f).clip(shape).background(MaterialTheme.colorScheme.surfaceContainerHighest), contentAlignment = Alignment.Center) {
        if (file != null) {
            AsyncImage(
                // One memory cache entry per cover, whatever its size: a page shows the image its list had at once.
                model = ImageRequest.Builder(LocalContext.current).data(file).memoryCacheKey(file.path).placeholderMemoryCacheKey(file.path)
                    .crossfade(true).build(),
                contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize(),
            )
        } else {
            Icon(painterResource(if (round) R.drawable.ic_person else R.drawable.ic_music), contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.fillMaxSize(0.4f))
        }
    }
}

/** A playlist's cover: its songs' covers, four in a square when it has that many. */
@Composable
fun MosaicCover(files: List<File>, modifier: Modifier, corner: Dp = 8.dp) {
    if (files.size < 4) return Cover(files.firstOrNull(), modifier, corner = corner)
    Column(modifier.aspectRatio(1f).clip(RoundedCornerShape(corner))) {
        for (row in 0..1) Row(Modifier.weight(1f)) {
            for (column in 0..1) {
                AsyncImage(model = files[row * 2 + column], contentDescription = null, contentScale = ContentScale.Crop,
                    modifier = Modifier.weight(1f).fillMaxHeight())
            }
        }
    }
}

/** Three bars moving while playing (still when paused): marks the song playing in lists. */
@Composable
fun PlayingBars(playing: Boolean, modifier: Modifier = Modifier, color: Color = MaterialTheme.colorScheme.primary) {
    val transition = rememberInfiniteTransition(label = "bars")
    val heights = listOf(0.9f to 420, 0.6f to 330, 1f to 510).map { (rest, duration) ->
        val moving by transition.animateFloat(0.25f, 1f, infiniteRepeatable(tween(duration), RepeatMode.Reverse), label = "bar")
        if (playing) moving else rest * 0.5f
    }
    Row(modifier.size(18.dp), horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.Bottom) {
        heights.forEach { height ->
            Box(Modifier.weight(1f).fillMaxHeight(height).clip(RoundedCornerShape(1.dp)).background(color))
        }
    }
}

/** How a song row starts: its cover, its number on the album, or nothing. */
sealed interface SongLeading {
    data object Artwork : SongLeading
    data class Number(val text: String) : SongLeading
}

/**
 * A song in a list: tap plays, long press or the menu button offers Play Next, Add to Queue and going to its album
 * or artist. The song playing is marked.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun SongRow(
    track: Track,
    supporting: String?,
    onClick: () -> Unit,
    leading: SongLeading = SongLeading.Artwork,
    showDuration: Boolean = false,
    showAlbumLink: Boolean = true,
    /** The playlist the row is in (one that can be edited): its menu offers Remove from Playlist. */
    playlistId: Long? = null,
) {
    val actions = LocalActions.current
    val playing = LocalNowPlaying.current?.takeIf { it.id == track.id }
    val haptics = LocalHapticFeedback.current
    var menu by remember { mutableStateOf(false) }
    ListItem(
        headlineContent = {
            Text(track.title, maxLines = 1, overflow = TextOverflow.Ellipsis,
                color = if (playing != null) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                fontWeight = if (playing != null) FontWeight.SemiBold else null)
        },
        supportingContent = supporting?.let { { Text(it, maxLines = 1, overflow = TextOverflow.Ellipsis) } },
        leadingContent = {
            when (leading) {
                SongLeading.Artwork -> Box(contentAlignment = Alignment.Center) {
                    Cover(actions.library.cover(track.artworkHash), Modifier.size(48.dp), corner = 6.dp)
                    if (playing != null) {
                        Box(Modifier.size(48.dp).clip(RoundedCornerShape(6.dp)).background(Color.Black.copy(alpha = 0.45f)))
                        PlayingBars(playing.isPlaying, color = Color.White)
                    }
                }
                is SongLeading.Number -> Box(Modifier.width(32.dp), contentAlignment = Alignment.Center) {
                    if (playing != null) PlayingBars(playing.isPlaying) else {
                        Text(leading.text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                            textAlign = TextAlign.Center, maxLines = 1)
                    }
                }
            }
        },
        trailingContent = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (showDuration) Text(duration(track.durationMs), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Box {
                    IconButton(onClick = { menu = true }) {
                        Icon(painterResource(R.drawable.ic_more), contentDescription = "More for ${track.title}",
                            tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    SongMenu(listOf(track), expanded = menu, onDismiss = { menu = false },
                        albumKey = track.albumKey.takeIf { showAlbumLink }, artist = track.artist, subject = MenuSubject.Song(track),
                        fromPlaylist = playlistId)
                }
            }
        },
        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
        modifier = Modifier.combinedClickable(onClick = onClick, onLongClick = {
            haptics.performHapticFeedback(HapticFeedbackType.LongPress)
            menu = true
        }, onLongClickLabel = "More actions"),
    )
}

/** What a menu is about, for Share and Remove from This Device. */
sealed interface MenuSubject {
    data class Song(val track: Track) : MenuSubject
    data class AlbumOf(val album: Album) : MenuSubject
    data class Artist(val name: String) : MenuSubject
    /** `editable`: not smart, so it can be renamed and deleted here. */
    data class PlaylistOf(val id: Long, val name: String, val editable: Boolean = false) : MenuSubject
}

/**
 * Play Next, Add to Queue, Add to Playlist, going to the album or artist (when given), and for `subject`: Share (songs
 * and albums), Share File (a song), Rename and Delete (playlists made by hand) and Remove from This Device, which asks
 * first. Removing deletes the songs from this device only: the Mac's library keeps them. `fromPlaylist`: the playlist
 * the song is shown in, for Remove from Playlist.
 */
@Composable
fun SongMenu(tracks: List<Track>, expanded: Boolean, onDismiss: () -> Unit, albumKey: String? = null, artist: String? = null,
             subject: MenuSubject? = null, fromPlaylist: Long? = null) {
    val actions = LocalActions.current
    val context = LocalContext.current
    var removing by remember { mutableStateOf(false) }
    var adding by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    DropdownMenu(expanded = expanded, onDismissRequest = onDismiss) {
        DropdownMenuItem(text = { Text("Play Next") }, leadingIcon = { Icon(painterResource(R.drawable.ic_play_next), null) },
            onClick = { onDismiss(); actions.playNext(tracks) })
        DropdownMenuItem(text = { Text("Add to Queue") }, leadingIcon = { Icon(painterResource(R.drawable.ic_queue_add), null) },
            onClick = { onDismiss(); actions.addToQueue(tracks) })
        DropdownMenuItem(text = { Text("Add to Playlist…") }, leadingIcon = { Icon(painterResource(R.drawable.ic_library_add), null) },
            onClick = { onDismiss(); adding = true })
        if (fromPlaylist != null && tracks.size == 1) {
            DropdownMenuItem(text = { Text("Remove from Playlist") }, leadingIcon = { Icon(painterResource(R.drawable.ic_remove_circle), null) },
                onClick = {
                    onDismiss()
                    actions.library.removeFromPlaylist(fromPlaylist, tracks.first())
                    actions.notify("Removed “${tracks.first().title}” from the playlist")
                })
        }
        if (albumKey != null) {
            DropdownMenuItem(text = { Text("Go to Album") }, leadingIcon = { Icon(painterResource(R.drawable.ic_album), null) },
                onClick = { onDismiss(); actions.open(Route.AlbumPage(albumKey)) })
        }
        if (artist != null) {
            DropdownMenuItem(text = { Text("Go to Artist") }, leadingIcon = { Icon(painterResource(R.drawable.ic_person), null) },
                onClick = { onDismiss(); actions.open(Route.ArtistPage(artist)) })
        }
        when (subject) {
            is MenuSubject.Song -> {
                val track = subject.track
                DropdownMenuItem(text = { Text("Share") }, leadingIcon = { Icon(painterResource(R.drawable.ic_share), null) }, onClick = {
                    onDismiss()
                    val album = actions.library.albumsByKey.value[track.albumKey]
                    shareText(context, track.title, songShareText(track.title, track.artist, album?.title, track.year ?: album?.year),
                        actions.library.cover(track.artworkHash ?: album?.artworkHash))
                })
                actions.library.fileUri(track)?.let { uri ->
                    DropdownMenuItem(text = { Text("Share File") }, leadingIcon = { Icon(painterResource(R.drawable.ic_file), null) }, onClick = {
                        onDismiss()
                        shareFile(context, track.title, uri, audioMimeType(track.codec))
                    })
                }
            }
            is MenuSubject.AlbumOf -> {
                val album = subject.album
                // Its page on the Mac: its songs that are not here, and the format it comes in.
                DropdownMenuItem(text = { Text("Format and Songs on the Mac") }, leadingIcon = { Icon(painterResource(R.drawable.ic_laptop), null) },
                    onClick = { onDismiss(); actions.open(Route.MacAlbumPage(album.key)) })
                DropdownMenuItem(text = { Text("Share") }, leadingIcon = { Icon(painterResource(R.drawable.ic_share), null) }, onClick = {
                    onDismiss()
                    shareText(context, album.title, albumShareText(album.title, album.artist, album.year), actions.library.cover(album.artworkHash))
                })
            }
            is MenuSubject.PlaylistOf -> if (subject.editable) {
                DropdownMenuItem(text = { Text("Rename") }, leadingIcon = { Icon(painterResource(R.drawable.ic_edit), null) },
                    onClick = { onDismiss(); renaming = true })
                DropdownMenuItem(text = { Text("Delete Playlist") }, leadingIcon = { Icon(painterResource(R.drawable.ic_delete), null) },
                    onClick = { onDismiss(); deleting = true })
            }
            else -> {}
        }
        // A playlist made here is not on the Mac yet: there is nothing to remove from this device.
        if (subject != null && !(subject is MenuSubject.PlaylistOf && subject.id < 0)) {
            HorizontalDivider()
            DropdownMenuItem(text = { Text("Remove from This Device") }, leadingIcon = { Icon(painterResource(R.drawable.ic_delete), null) },
                onClick = { onDismiss(); removing = true })
        }
    }
    if (removing && subject != null) RemoveDialog(subject, tracks.size) { removing = false }
    if (adding) AddToPlaylistDialog(tracks) { adding = false }
    if (subject is MenuSubject.PlaylistOf) {
        if (renaming) PlaylistNameDialog("Rename Playlist", subject.name, "Rename", onDismiss = { renaming = false }) { name ->
            actions.library.renamePlaylist(subject.id, name)
        }
        if (deleting) DeletePlaylistDialog(subject) { deleting = false }
    }
}

/** Chooses the playlist to add songs to, or makes a new one with them. */
@Composable
fun AddToPlaylistDialog(tracks: List<Track>, onDone: () -> Unit) {
    val actions = LocalActions.current
    val playlists by actions.library.editablePlaylists.collectAsStateWithLifecycle()
    var naming by remember { mutableStateOf(false) }
    val what = if (tracks.size == 1) "“${tracks.first().title}”" else "${tracks.size} songs"
    if (naming) {
        PlaylistNameDialog("New Playlist", "", "Create", onDismiss = onDone) { name ->
            actions.library.createPlaylist(name, tracks)
            actions.notify("Added $what to “$name”")
        }
        return
    }
    AlertDialog(
        onDismissRequest = onDone,
        title = { Text("Add to Playlist") },
        text = {
            LazyColumn(Modifier.heightIn(max = 360.dp)) {
                item(key = "new") {
                    ListItem(
                        headlineContent = { Text("New Playlist…") },
                        leadingContent = { Icon(painterResource(R.drawable.ic_add_circle), null) },
                        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                        modifier = Modifier.clickable { naming = true },
                    )
                }
                items(playlists, key = { it.id }) { playlist ->
                    ListItem(
                        headlineContent = { Text(playlist.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                        leadingContent = { Icon(painterResource(R.drawable.ic_queue), null, tint = MaterialTheme.colorScheme.onSurfaceVariant) },
                        colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                        modifier = Modifier.clickable {
                            actions.library.addToPlaylist(playlist.id, tracks)
                            actions.notify("Added $what to “${playlist.name}”")
                            onDone()
                        },
                    )
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDone) { Text("Cancel") } },
    )
}

/** Asks for a playlist's name (a new one, or renaming). */
@Composable
fun PlaylistNameDialog(title: String, initial: String, confirm: String, onDismiss: () -> Unit, onConfirm: (String) -> Unit) {
    var name by remember { mutableStateOf(TextFieldValue(initial, TextRange(0, initial.length))) }
    val focus = remember { FocusRequester() }
    val done = { if (name.text.isNotBlank()) { onConfirm(name.text.trim()); onDismiss() } }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            OutlinedTextField(name, { name = it }, singleLine = true, label = { Text("Name") },
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Done),
                keyboardActions = KeyboardActions(onDone = { done() }),
                modifier = Modifier.fillMaxWidth().focusRequester(focus))
            LaunchedEffect(Unit) { focus.requestFocus() }
        },
        confirmButton = { TextButton(onClick = done, enabled = name.text.isNotBlank()) { Text(confirm) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

/** Asks before deleting a playlist: it goes on the Mac too (its songs stay). */
@Composable
private fun DeletePlaylistDialog(subject: MenuSubject.PlaylistOf, onDone: () -> Unit) {
    val actions = LocalActions.current
    val back = LocalBack.current
    AlertDialog(
        onDismissRequest = onDone,
        title = { Text("Delete “${subject.name}”?") },
        text = { Text("The playlist is deleted here and on your Mac. Its songs stay in your library and on this device.") },
        confirmButton = {
            TextButton(onClick = {
                actions.library.deletePlaylist(subject.id)
                actions.notify("Deleted “${subject.name}”")
                onDone()
                back()
            }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
        },
        dismissButton = { TextButton(onClick = onDone) { Text("Cancel") } },
    )
}

/** Asks before removing an album, artist, song or playlist from this device (the Mac keeps it). */
@Composable
private fun RemoveDialog(subject: MenuSubject, songs: Int, onDone: () -> Unit) {
    val actions = LocalActions.current
    val (kind, key, name, what) = when (subject) {
        is MenuSubject.Song -> listOf(TransferRequest.SONG, subject.track.id.toString(), subject.track.title, "This song")
        is MenuSubject.AlbumOf -> listOf(TransferRequest.ALBUM, subject.album.key, subject.album.title, if (songs == 1) "Its song" else "Its $songs songs")
        is MenuSubject.Artist -> listOf(TransferRequest.ARTIST, subject.name, subject.name, "Their songs")
        is MenuSubject.PlaylistOf -> listOf(TransferRequest.PLAYLIST, subject.id.toString(), subject.name, "The playlist and its songs")
    }
    AlertDialog(
        onDismissRequest = onDone,
        title = { Text("Remove “$name” from This Device?") },
        text = {
            Text("$what will be deleted from this device at the next sync, to free its space. Your Mac's library keeps everything; " +
                "add it again from Library, On the Mac.")
        },
        confirmButton = {
            TextButton(onClick = {
                actions.library.request(TransferRequest.REMOVE, kind, key)
                actions.notify("“$name” will be removed from this device")
                onDone()
            }) { Text("Remove", color = MaterialTheme.colorScheme.error) }
        },
        dismissButton = { TextButton(onClick = onDone) { Text("Cancel") } },
    )
}

/** An album in a grid: cover, title and artist; long press offers the album's menu. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun AlbumCard(album: Album, subtitle: String = album.artist, onOpen: () -> Unit) {
    val actions = LocalActions.current
    val haptics = LocalHapticFeedback.current
    var menu by remember { mutableStateOf(false) }
    var tracks by remember { mutableStateOf<List<Track>>(emptyList()) }
    Column(Modifier.clip(RoundedCornerShape(10.dp)).combinedClickable(onClick = onOpen, onLongClick = {
        haptics.performHapticFeedback(HapticFeedbackType.LongPress)
        menu = true
    }, onLongClickLabel = "More actions").padding(4.dp)) {
        Cover(actions.library.cover(album.artworkHash), Modifier.sharedCover("album:${album.key}").fillMaxWidth())
        Spacer(Modifier.height(8.dp))
        Text(album.title, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1, overflow = TextOverflow.Ellipsis)
        LaunchedEffect(menu) { if (menu) tracks = actions.library.tracksOfAlbum(album.key).first() }
        Box { SongMenu(tracks, expanded = menu && tracks.isNotEmpty(), onDismiss = { menu = false },
            artist = album.artist.takeUnless { album.isCompilation }, subject = MenuSubject.AlbumOf(album)) }
    }
}

/** Play and Shuffle side by side, small, for headers in short windows. */
@Composable
fun CompactPlayButtons(onPlay: () -> Unit, onShuffle: () -> Unit, modifier: Modifier = Modifier) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        FilledIconButton(onClick = onPlay, modifier = Modifier.size(44.dp)) {
            Icon(painterResource(R.drawable.ic_play), contentDescription = "Play")
        }
        FilledTonalIconButton(onClick = onShuffle, modifier = Modifier.size(44.dp)) {
            Icon(painterResource(R.drawable.ic_shuffle), contentDescription = "Shuffle")
        }
    }
}

@Composable
fun PlayButtons(onPlay: () -> Unit, onShuffle: () -> Unit, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Button(onClick = onPlay, modifier = Modifier.weight(1f)) {
            Icon(painterResource(R.drawable.ic_play), contentDescription = null, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text("Play")
        }
        FilledTonalButton(onClick = onShuffle, modifier = Modifier.weight(1f)) {
            Icon(painterResource(R.drawable.ic_shuffle), contentDescription = null, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text("Shuffle")
        }
    }
}

/** "Hi-Res Lossless" or "Lossless", as the Mac's badge. */
@Composable
fun QualityBadge(text: String, color: Color = MaterialTheme.colorScheme.onSurfaceVariant) {
    Surface(shape = RoundedCornerShape(4.dp), color = Color.Transparent, contentColor = color,
        border = androidx.compose.foundation.BorderStroke(1.dp, color.copy(alpha = 0.6f))) {
        Text(text, style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp))
    }
}

@Composable
fun SectionTitle(text: String, modifier: Modifier = Modifier) {
    Text(text, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold,
        modifier = modifier.padding(horizontal = 16.dp).padding(top = 20.dp, bottom = 8.dp).semantics { heading() })
}

@Composable
fun EmptyState(icon: Int, title: String, detail: String, modifier: Modifier = Modifier, action: (@Composable () -> Unit)? = null) {
    Column(modifier.fillMaxSize().padding(32.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(painterResource(icon), contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(48.dp))
        Spacer(Modifier.height(16.dp))
        Text(title, style = MaterialTheme.typography.titleLarge, textAlign = TextAlign.Center)
        Spacer(Modifier.height(8.dp))
        Text(detail, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center, modifier = Modifier.widthIn(max = 360.dp))
        action?.let {
            Spacer(Modifier.height(20.dp))
            it()
        }
    }
}

@Composable
fun Loading() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
}

/**
 * A thumb on the right edge for long lists: shown while scrolling, dragged to jump, with the letter (or year) of the
 * place it is at.
 */
@Composable
fun FastScroller(
    count: Int,
    firstVisible: Int,
    visibleCount: Int,
    scrolling: Boolean,
    scrollTo: suspend (Int) -> Unit,
    label: (Int) -> String?,
    modifier: Modifier = Modifier,
) {
    if (count < 40 || visibleCount >= count) return
    var dragging by remember { mutableStateOf(false) }
    var dragIndex by remember { mutableIntStateOf(0) }
    val shown = scrolling || dragging
    val alpha by animateFloatAsState(if (shown) 1f else 0f, tween(if (shown) 150 else 500, delayMillis = if (shown) 0 else 1200), label = "scroller")
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
    BoxWithConstraints(modifier.fillMaxHeight().width(28.dp).graphicsLayer { this.alpha = alpha }) {
        val track = constraints.maxHeight.toFloat()
        val thumb = with(density) { 44.dp.toPx() }
        val last = (count - visibleCount).coerceAtLeast(1)
        val position = ((if (dragging) dragIndex else firstVisible).toFloat() / last).coerceIn(0f, 1f) * (track - thumb)
        fun jump(y: Float) {
            val fraction = ((y - thumb / 2) / (track - thumb)).coerceIn(0f, 1f)
            dragIndex = (fraction * last).roundToInt()
            scope.launch { scrollTo(dragIndex) }
        }
        val drag = if (alpha > 0f) Modifier.pointerInput(count, track) {
            detectVerticalDragGestures(
                onDragStart = { dragging = true; jump(it.y) },
                onDragEnd = { dragging = false },
                onDragCancel = { dragging = false },
            ) { change, _ -> jump(change.position.y) }
        } else Modifier
        Box(Modifier.fillMaxSize().then(drag)) {
            Box(Modifier.align(Alignment.TopEnd).offset { IntOffset(0, position.roundToInt()) }.padding(end = 4.dp)
                .size(width = 6.dp, height = 44.dp).clip(CircleShape)
                .background(if (dragging) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f)))
        }
        if (dragging) label(dragIndex)?.let { text ->
            Surface(shape = CircleShape, color = MaterialTheme.colorScheme.primaryContainer,
                modifier = Modifier.offset { IntOffset(-with(density) { 76.dp.roundToPx() }, (position + thumb / 2 - with(density) { 28.dp.toPx() }).roundToInt()) }
                    .size(56.dp)) {
                Box(contentAlignment = Alignment.Center) {
                    Text(text, style = MaterialTheme.typography.titleLarge, color = MaterialTheme.colorScheme.onPrimaryContainer, maxLines = 1)
                }
            }
        }
    }
}

/** The letter a name is filed under in the A to Z index and the fast scroller: its first letter without accents ("É" under E), or "#" for digits, symbols and other scripts. */
fun indexLetter(text: String): String {
    val first = text.trimStart().firstOrNull { it.isLetterOrDigit() } ?: return "#"
    val folded = java.text.Normalizer.normalize(first.toString(), java.text.Normalizer.Form.NFD).first().uppercaseChar()
    return if (folded in 'A'..'Z') folded.toString() else "#"
}

/** "Hi-Res Lossless", "Lossless" or nothing, from the files on the device (as the Mac's badge). */
fun quality(tracks: List<Track>): String? {
    if (tracks.isEmpty()) return null
    val lossless = setOf("flac", "alac", "wav", "aiff", "wavPack")
    if (!tracks.all { it.codec in lossless }) return null
    return if (tracks.any { (it.bitDepth ?: 16) > 16 || (it.sampleRate ?: 44_100) > 48_000 }) "Hi-Res Lossless" else "Lossless"
}

fun duration(milliseconds: Long): String {
    val seconds = milliseconds / 1000
    return if (seconds >= 3600) "%d:%02d:%02d".format(seconds / 3600, seconds / 60 % 60, seconds % 60) else "%d:%02d".format(seconds / 60, seconds % 60)
}

/** "12 songs, 48 minutes" (hours past one). */
fun songsSummary(tracks: List<Track>): String {
    val songs = if (tracks.size == 1) "1 song" else "${tracks.size} songs"
    val seconds = (tracks.sumOf { it.durationMs } / 1_000).toInt()
    // To the nearest minute; under a minute, in seconds.
    val minutes = (seconds + 30) / 60
    val length = when {
        seconds < 60 -> if (seconds == 1) "1 second" else "$seconds seconds"
        minutes >= 60 -> "${minutes / 60} hr ${minutes % 60} min"
        minutes == 1 -> "1 minute"
        else -> "$minutes minutes"
    }
    return "$songs, $length"
}

/**
 * Two fingers pinching: `onZoom` gets how much they spread (above 1) or closed (below 1) since the last call. One
 * finger is left alone, so lists under it still scroll.
 */
fun Modifier.pinchToResize(onZoom: (Float) -> Unit): Modifier = pointerInput(Unit) {
    awaitEachGesture {
        var previous: Float? = null
        do {
            val event = awaitPointerEvent(PointerEventPass.Initial)
            val pressed = event.changes.filter { it.pressed }
            if (pressed.size >= 2) {
                val distance = (pressed[0].position - pressed[1].position).getDistance()
                previous?.let { if (it > 0f) onZoom(distance / it) }
                previous = distance
                event.changes.forEach { it.consume() }
            } else previous = null
        } while (pressed.isNotEmpty())
    }
}

/** The shared transition of the player's pages (covers moving between a list and their page). */
val LocalSharedTransition = staticCompositionLocalOf<SharedTransitionScope?> { null }

/** The animation of the page being shown, for its shared elements (null outside pages, as in Now Playing). */
val LocalPageScope = staticCompositionLocalOf<AnimatedVisibilityScope?> { null }

/**
 * Links a cover to the same one on another page (`key`: "album:<key>", "artist:<name>", "playlist:<id>"...): opening
 * the page, the tapped cover grows into the page's cover, and Back puts it back. Nothing outside pages.
 */
@Composable
fun Modifier.sharedCover(key: String): Modifier {
    val shared = LocalSharedTransition.current ?: return this
    val page = LocalPageScope.current ?: return this
    // The player's cover moves linearly, with the finger that opens Now Playing ([PLAYER_MOTION_MS]).
    val motion = if (key == PLAYER_COVER) tween<Rect>(PLAYER_MOTION_MS, easing = LinearEasing) else tween(340, easing = FastOutSlowInEasing)
    return with(shared) {
        this@sharedCover.sharedElement(rememberSharedContentState("cover:$key"), animatedVisibilityScope = page,
            boundsTransform = { _, _ -> motion })
    }
}

/**
 * How small the app's window is: `short` under 480 dp tall (a phone in landscape, or split screen beside a map in a
 * car), `narrow` under 360 dp wide (a third of a landscape screen; a phone held upright is wider). Screens trade
 * decoration for content there.
 */
@Immutable
data class WindowShape(val short: Boolean = false, val narrow: Boolean = false) {
    val compact: Boolean get() = short || narrow

    companion object {
        /** From the window's size class (short) and its actual width in dp (size classes only step at 600 dp). */
        fun of(window: androidx.window.core.layout.WindowSizeClass, widthDp: Float) = WindowShape(
            short = !window.isHeightAtLeastBreakpoint(androidx.window.core.layout.WindowSizeClass.HEIGHT_DP_MEDIUM_LOWER_BOUND),
            narrow = widthDp < 360f,
        )
    }
}

val LocalWindowShape = staticCompositionLocalOf { WindowShape() }
