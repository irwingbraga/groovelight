package dev.irwingbraga.groovelight.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.irwingbraga.groovelight.R

/** Search across the library: artists, albums, songs and the people credited, matching the words typed. */
@Composable
fun SearchScreen() {
    val actions = LocalActions.current
    val query by actions.library.query.collectAsStateWithLifecycle()
    val results by actions.library.results.collectAsStateWithLifecycle()
    val albums by actions.library.albumsByKey.collectAsStateWithLifecycle()
    val focus = remember { FocusRequester() }
    val focusManager = LocalFocusManager.current
    // Opens with the keyboard up when there is nothing searched yet.
    LaunchedEffect(Unit) { if (query.isEmpty()) runCatching { focus.requestFocus() } }
    Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.statusBars)) {
        TextField(
            value = query,
            onValueChange = { actions.library.query.value = it },
            placeholder = { Text("Artists, albums, songs and credits") },
            leadingIcon = { Icon(painterResource(R.drawable.ic_search), contentDescription = null) },
            trailingIcon = {
                if (query.isNotEmpty()) IconButton(onClick = { actions.library.query.value = ""; runCatching { focus.requestFocus() } }) {
                    Icon(painterResource(R.drawable.ic_close), contentDescription = "Clear search")
                }
            },
            singleLine = true,
            shape = CircleShape,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { focusManager.clearFocus() }),
            colors = TextFieldDefaults.colors(focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent,
                disabledIndicatorColor = Color.Transparent),
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp).focusRequester(focus),
        )
        val found = results
        when {
            found == null -> EmptyState(R.drawable.ic_search, "Search your library", "Find artists, albums and songs on this device.",
                Modifier.padding(bottom = LocalBottomInset.current))
            found.isEmpty -> EmptyState(R.drawable.ic_search, "No results", "Nothing on this device matches \"${found.query}\".",
                Modifier.padding(bottom = LocalBottomInset.current))
            else -> LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 16.dp + LocalBottomInset.current)) {
                if (found.artists.isNotEmpty()) {
                    item(key = "artists") { SectionTitle("Artists") }
                    items(found.artists, key = { "artist:${it.name}" }) { artist ->
                        ListItem(
                            headlineContent = { Text(artist.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                            supportingContent = { Text("Artist") },
                            leadingContent = { Cover(actions.library.cover(artist.artworkHash), Modifier.sharedCover("artist:${artist.name}").size(48.dp), round = true) },
                            colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                            modifier = Modifier.clickable { focusManager.clearFocus(); actions.open(Route.ArtistPage(artist.name)) },
                        )
                    }
                }
                if (found.albums.isNotEmpty()) {
                    item(key = "albums") { SectionTitle("Albums") }
                    item(key = "albumRow") {
                        LazyRow(contentPadding = PaddingValues(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                            items(found.albums, key = { it.key }) { album ->
                                Box(Modifier.width(140.dp)) {
                                    AlbumCard(album) { focusManager.clearFocus(); actions.open(Route.AlbumPage(album.key)) }
                                }
                            }
                        }
                    }
                }
                if (found.people.isNotEmpty()) {
                    item(key = "people") { SectionTitle("People") }
                    items(found.people, key = { "person:${it.name}" }) { person ->
                        ListItem(
                            headlineContent = { Text(person.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                            supportingContent = { Text(if (person.albums == 1) "Credited on 1 album" else "Credited on ${person.albums} albums") },
                            leadingContent = { Cover(null, Modifier.size(48.dp), round = true) },
                            colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                            modifier = Modifier.clickable { focusManager.clearFocus(); actions.open(Route.PersonPage(person.name)) },
                        )
                    }
                }
                if (found.songs.isNotEmpty()) {
                    item(key = "songs") { SectionTitle("Songs") }
                    itemsIndexed(found.songs, key = { _, track -> "song:${track.id}" }) { index, track ->
                        SongRow(track, listOfNotNull(track.artist, albums[track.albumKey]?.title).joinToString(" · "),
                            onClick = {
                                focusManager.clearFocus()
                                actions.player.play(actions.library.mediaItems(found.songs, "Search · ${found.query}"), index, shuffle = false)
                            })
                    }
                }
            }
        }
    }
}
