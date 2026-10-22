package dev.irwingbraga.groovelight.widget

import android.content.Context
import android.graphics.Bitmap
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.ColorFilter
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalSize
import androidx.glance.action.actionParametersOf
import androidx.glance.action.actionStartActivity
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ContentScale
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import dev.irwingbraga.groovelight.R
import dev.irwingbraga.groovelight.library.Album
import dev.irwingbraga.groovelight.library.ArtworkStore
import dev.irwingbraga.groovelight.library.LibraryDatabase
import dev.irwingbraga.groovelight.sync.MainActivity
import kotlinx.coroutines.flow.first

/** The albums played lately (or added lately, before any is played), as covers: tapping one plays it. */
class RecentlyPlayedWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val recent = LibraryDatabase.get(context).library().recentlyPlayedAlbums(MAX)
        val first = recent.first()
        val artwork = ArtworkStore(context)
        provideContent {
            // Follows the library while the widget's session runs.
            val albums by recent.collectAsState(first)
            val covers = remember(albums) {
                albums.associate { album -> album.key to widgetCover(album.artworkHash?.let { artwork.file(it) }?.takeIf { it.exists() }?.path, 220) }
            }
            GlanceTheme { RecentContent(albums, covers) }
        }
    }

    companion object {
        const val MAX = 8
    }
}

class RecentlyPlayedWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = RecentlyPlayedWidget()
}

@Composable
private fun RecentContent(albums: List<Album>, covers: Map<String, Bitmap?>) {
    val size = LocalSize.current
    Column(
        GlanceModifier.fillMaxSize().cornerRadius(20.dp).background(GlanceTheme.colors.widgetBackground).padding(12.dp),
    ) {
        Text("Recently Played", style = TextStyle(color = GlanceTheme.colors.onSurface, fontWeight = FontWeight.Bold, fontSize = 14.sp),
            modifier = GlanceModifier.clickable(actionStartActivity<MainActivity>()))
        Spacer(GlanceModifier.height(8.dp))
        if (albums.isEmpty()) {
            Text("Your albums show here after a sync.", style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 12.sp))
            return@Column
        }
        // As many covers as fit across, in one row, or two when tall enough.
        val cell = 76.dp
        val perRow = ((size.width - 24.dp + 8.dp) / (cell + 8.dp)).toInt().coerceAtLeast(1)
        // A cover with its title under it is about 110 dp tall.
        val rows = if (size.height >= 290.dp) 2 else 1
        albums.take(perRow * rows).chunked(perRow).forEachIndexed { index, row ->
            if (index > 0) Spacer(GlanceModifier.height(8.dp))
            Row(GlanceModifier.fillMaxWidth()) {
                row.forEachIndexed { column, album ->
                    if (column > 0) Spacer(GlanceModifier.width(8.dp))
                    AlbumCover(album, covers[album.key], cell)
                }
            }
        }
    }
}

@Composable
private fun AlbumCover(album: Album, cover: Bitmap?, side: androidx.compose.ui.unit.Dp) {
    val play = actionRunCallback<PlayerAction>(actionParametersOf(AlbumKey to album.key))
    Column(GlanceModifier.width(side).clickable(play)) {
        val shape = GlanceModifier.size(side).cornerRadius(12.dp)
        if (cover != null) Image(ImageProvider(cover), contentDescription = "Play ${album.title}", contentScale = ContentScale.Crop, modifier = shape)
        else Box(shape.background(GlanceTheme.colors.secondaryContainer), contentAlignment = Alignment.Center) {
            Image(ImageProvider(R.drawable.ic_album), contentDescription = "Play ${album.title}",
                colorFilter = ColorFilter.tint(GlanceTheme.colors.onSecondaryContainer), modifier = GlanceModifier.size(28.dp))
        }
        Text(album.title, maxLines = 1, style = TextStyle(color = GlanceTheme.colors.onSurface, fontSize = 12.sp), modifier = GlanceModifier.padding(top = 4.dp))
        Text(album.artist, maxLines = 1, style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 11.sp))
    }
}
