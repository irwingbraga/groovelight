package dev.irwingbraga.groovelight.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.NavigationDrawerItemDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.irwingbraga.groovelight.R

/** A place in the sidebar of wide windows. */
sealed interface SidebarPlace {
    data object Search : SidebarPlace
    data class Section(val section: LibrarySection) : SidebarPlace
    data object Shelf : SidebarPlace
    data object LovedSongs : SidebarPlace
    data class Playlist(val id: Long) : SidebarPlace
    data object Settings : SidebarPlace
}

/** The sidebar's width, beside the page. */
val SIDEBAR_WIDTH: Dp = 248.dp

/**
 * The sidebar of wide windows (an unfolded foldable, a tablet), in place of the tabs, as on the iPad and the Mac:
 * Search; Library (Albums, Artists, Songs, Playlists); Explore (Shelf); Playlists (Loved Songs, each playlist); Settings
 * at the bottom.
 */
@Composable
fun Sidebar(selected: SidebarPlace, onSelect: (SidebarPlace) -> Unit, modifier: Modifier = Modifier) {
    val library = LocalActions.current.library
    val playlists by library.playlists.collectAsStateWithLifecycle()
    Surface(modifier.width(SIDEBAR_WIDTH).fillMaxHeight(), color = MaterialTheme.colorScheme.surfaceContainerLow) {
        Column(Modifier.windowInsetsPadding(WindowInsets.statusBars).windowInsetsPadding(WindowInsets.navigationBars)) {
            LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp)) {
                item { Place(selected, SidebarPlace.Search, "Search", R.drawable.ic_search, onSelect) }
                item { Heading("Library") }
                items(LibrarySection.entries) { section ->
                    Place(selected, SidebarPlace.Section(section), section.title, section.icon, onSelect)
                }
                item { Heading("Explore") }
                item { Place(selected, SidebarPlace.Shelf, "Shelf", R.drawable.ic_shelf, onSelect) }
                item { Heading("Playlists") }
                item { Place(selected, SidebarPlace.LovedSongs, "Loved Songs", R.drawable.ic_favorite, onSelect) }
                items(playlists.orEmpty(), key = { it.id }) { playlist ->
                    Place(selected, SidebarPlace.Playlist(playlist.id), playlist.name, R.drawable.ic_queue, onSelect)
                }
            }
            HorizontalDivider(Modifier.padding(horizontal = 16.dp))
            Column(Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) {
                Place(selected, SidebarPlace.Settings, "Settings", R.drawable.ic_settings, onSelect)
            }
        }
    }
}

private val LibrarySection.icon: Int get() = when (this) {
    LibrarySection.ALBUMS -> R.drawable.ic_album
    LibrarySection.ARTISTS -> R.drawable.ic_person
    LibrarySection.SONGS -> R.drawable.ic_music
    LibrarySection.PLAYLISTS -> R.drawable.ic_library
}

@Composable
private fun Heading(title: String) {
    Text(title, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(start = 16.dp, top = 20.dp, bottom = 6.dp).semantics { heading() })
}

@Composable
private fun Place(selected: SidebarPlace, place: SidebarPlace, title: String, icon: Int, onSelect: (SidebarPlace) -> Unit) {
    NavigationDrawerItem(
        label = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        icon = { Icon(painterResource(icon), contentDescription = null, modifier = Modifier.size(22.dp)) },
        selected = selected == place,
        onClick = { onSelect(place) },
        colors = NavigationDrawerItemDefaults.colors(unselectedContainerColor = Color.Transparent),
        modifier = Modifier.padding(vertical = 1.dp),
    )
}
