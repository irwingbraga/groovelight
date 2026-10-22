package dev.irwingbraga.groovelight.widget

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
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
import androidx.glance.layout.fillMaxHeight
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import android.graphics.Bitmap
import dev.irwingbraga.groovelight.R
import dev.irwingbraga.groovelight.playback.NowPlayingInfo
import dev.irwingbraga.groovelight.sync.MainActivity

/**
 * Now Playing on the home screen: the cover, the song and the artist, and Previous, Play or Pause and Next. A row in
 * a short widget; taller, the cover above the song. Tapping it (but the buttons) opens the app.
 */
class NowPlayingWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val saved = NowPlayingInfo.of(context)
        provideContent {
            // Live while the widget's session runs; the saved queue's song (paused) when the player is not running.
            val live by NowPlayingInfo.current.collectAsState()
            val info = live ?: saved
            val cover = remember(info?.artwork) { widgetCover(info?.artwork?.path, 360) }
            GlanceTheme { NowPlayingContent(info, cover) }
        }
    }
}

class NowPlayingWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = NowPlayingWidget()
}

@Composable
private fun NowPlayingContent(info: NowPlayingInfo.Info?, cover: Bitmap?) {
    val size = LocalSize.current
    val tall = size.height >= 160.dp && size.width >= 140.dp
    Box(
        GlanceModifier.fillMaxSize().cornerRadius(20.dp).background(GlanceTheme.colors.widgetBackground)
            .clickable(actionStartActivity<MainActivity>()).padding(12.dp),
    ) {
        if (info == null) {
            Column(GlanceModifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically, horizontalAlignment = Alignment.CenterHorizontally) {
                Text("Nothing playing", style = TextStyle(color = GlanceTheme.colors.onSurface, fontWeight = FontWeight.Medium, fontSize = 14.sp))
                Text("Tap to open Groovelight", style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 12.sp))
            }
        } else if (tall) {
            Column(GlanceModifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
                val side = minOf(size.width - 24.dp, size.height - 24.dp - 92.dp)
                CoverImage(cover, GlanceModifier.size(side).cornerRadius(14.dp))
                Spacer(GlanceModifier.height(8.dp))
                Titles(info, GlanceModifier.fillMaxWidth(), centered = true)
                Spacer(GlanceModifier.defaultWeight())
                Controls(info, GlanceModifier.fillMaxWidth())
            }
        } else {
            Row(GlanceModifier.fillMaxSize(), verticalAlignment = Alignment.CenterVertically) {
                val side = minOf(size.height - 24.dp, 72.dp)
                if (size.width >= 220.dp) {
                    CoverImage(cover, GlanceModifier.size(side).cornerRadius(10.dp))
                    Spacer(GlanceModifier.width(10.dp))
                }
                Titles(info, GlanceModifier.defaultWeight())
                Controls(info, GlanceModifier, compact = size.width < 220.dp)
            }
        }
    }
}

@Composable
private fun CoverImage(cover: Bitmap?, modifier: GlanceModifier) {
    if (cover != null) Image(ImageProvider(cover), contentDescription = null, contentScale = ContentScale.Crop, modifier = modifier)
    else Box(modifier.background(GlanceTheme.colors.secondaryContainer), contentAlignment = Alignment.Center) {
        Image(ImageProvider(R.drawable.ic_music), contentDescription = null, colorFilter = ColorFilter.tint(GlanceTheme.colors.onSecondaryContainer),
            modifier = GlanceModifier.size(28.dp))
    }
}

@Composable
private fun Titles(info: NowPlayingInfo.Info, modifier: GlanceModifier, centered: Boolean = false) {
    val align = if (centered) androidx.glance.text.TextAlign.Center else androidx.glance.text.TextAlign.Start
    Column(modifier) {
        Text(info.title, maxLines = 1, style = TextStyle(color = GlanceTheme.colors.onSurface, fontWeight = FontWeight.Bold, fontSize = 15.sp, textAlign = align),
            modifier = GlanceModifier.fillMaxWidth())
        info.artist?.let {
            Text(it, maxLines = 1, style = TextStyle(color = GlanceTheme.colors.onSurfaceVariant, fontSize = 13.sp, textAlign = align),
                modifier = GlanceModifier.fillMaxWidth())
        }
    }
}

@Composable
private fun Controls(info: NowPlayingInfo.Info, modifier: GlanceModifier, compact: Boolean = false) {
    Row(modifier, horizontalAlignment = Alignment.CenterHorizontally, verticalAlignment = Alignment.CenterVertically) {
        if (!compact) Button(R.drawable.ic_skip_previous, "Previous", "previous", GlanceTheme.colors.onSurface)
        Box(
            GlanceModifier.size(48.dp).cornerRadius(24.dp).background(GlanceTheme.colors.primary)
                .clickable(actionRunCallback<PlayerAction>(actionParametersOf(Command to "playPause"))),
            contentAlignment = Alignment.Center,
        ) {
            Image(ImageProvider(if (info.isPlaying) R.drawable.ic_pause else R.drawable.ic_play), contentDescription = if (info.isPlaying) "Pause" else "Play",
                colorFilter = ColorFilter.tint(GlanceTheme.colors.onPrimary), modifier = GlanceModifier.size(26.dp))
        }
        Button(R.drawable.ic_skip_next, "Next", "next", if (info.hasNext) GlanceTheme.colors.onSurface else GlanceTheme.colors.outline)
    }
}

@Composable
private fun Button(icon: Int, label: String, command: String, tint: androidx.glance.unit.ColorProvider) {
    Box(GlanceModifier.size(44.dp).clickable(actionRunCallback<PlayerAction>(actionParametersOf(Command to command))), contentAlignment = Alignment.Center) {
        Image(ImageProvider(icon), contentDescription = label, colorFilter = ColorFilter.tint(tint), modifier = GlanceModifier.size(24.dp))
    }
}
