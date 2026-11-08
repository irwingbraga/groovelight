package dev.irwingbraga.groovelight.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.irwingbraga.groovelight.R
import dev.irwingbraga.groovelight.library.TransferRequest
import dev.irwingbraga.groovelight.sync.HomeSnapshot
import dev.irwingbraga.groovelight.sync.Host
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.Locale

private val RANGES = listOf("week" to "Week", "month" to "Month", "year" to "Year", "all" to "All Time")

/**
 * Home, as on the Mac and the iPhone: a greeting, Song, Album and Artist of the Day, and Your Listening (tiles, charts
 * drawn on a Canvas, top lists), all worked out by the Mac from its listening log and kept here for when it is away.
 */
@Composable
fun HomeScreen() {
    val actions = LocalActions.current
    val library = actions.library
    val home by library.home.collectAsStateWithLifecycle()
    val state by library.homeState.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { library.refreshHome() }
    val top = Modifier.padding(top = LocalTopInset.current, bottom = LocalBottomInset.current)
    GlassTop(bar = { Spacer(Modifier.windowInsetsPadding(WindowInsets.statusBars)) }) {
        val shown = home
        when {
            shown == null && !library.isPaired -> EmptyState(R.drawable.ic_home, "Home",
                "Pair with your ${Host.word} in Settings, Sync to see your song, album and artist of the day, and charts of your listening.", top) {
                Button(onClick = { actions.open(Route.Sync) }) { Text("Pair") }
            }
            shown == null -> EmptyState(R.drawable.ic_home, "Home",
                state.error ?: if (state.loading) "Asking your ${Host.word}…" else "Your ${Host.word} could not be reached. Home shows once it is.", top) {
                if (!state.loading) Button(onClick = library::refreshHome) { Text("Try Again") }
            }
            else -> PullToRefreshBox(isRefreshing = state.loading, onRefresh = library::refreshHome, modifier = Modifier.fillMaxSize()) {
                HomeContent(shown)
            }
        }
    }
}

@Composable
private fun HomeContent(home: HomeSnapshot) {
    val library = LocalActions.current.library
    var range by rememberSaveable { mutableStateOf("month") }
    // "Something Else": which card of each kind is shown.
    val shown = remember(home.day) { mutableStateMapOf<String, Int>() }
    val today = LocalDate.now()
    val stale = home.day != today.toEpochDay()
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(top = LocalTopInset.current + 8.dp, bottom = 24.dp + LocalBottomInset.current)) {
        item(key = "header") {
            Column(Modifier.padding(horizontal = 16.dp)) {
                Text(today.format(DateTimeFormatter.ofPattern("EEEE, d MMMM", Locale.getDefault())).uppercase(), style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(greeting(), style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, modifier = Modifier.semantics { heading() })
                if (stale) {
                    Text("From an earlier day: your ${Host.word} was not reachable since.", style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 4.dp))
                }
            }
        }
        item(key = "picks") {
            val cards = HomeSnapshot.KINDS.mapNotNull { kind ->
                home.cards(kind).takeIf { it.isNotEmpty() }?.let { it[(shown[kind] ?: 0) % it.size] }
            }
            BoxWithConstraints(Modifier.fillMaxWidth().padding(top = 16.dp)) {
                val width = minOf(maxWidth * 0.78f, 320.dp)
                LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    items(cards, key = { it.kind }) { card ->
                        PickCard(card, alternatives = home.cards(card.kind).size > 1, modifier = Modifier.width(width)) {
                            shown[card.kind] = (shown[card.kind] ?: 0) + 1
                        }
                    }
                }
            }
        }
        item(key = "listening") {
            Column(Modifier.padding(horizontal = 16.dp).padding(top = 28.dp)) {
                Text("Your Listening", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, modifier = Modifier.semantics { heading() })
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(top = 12.dp)) {
                    RANGES.forEachIndexed { index, (value, label) ->
                        SegmentedButton(selected = range == value, onClick = { range = value },
                            shape = SegmentedButtonDefaults.itemShape(index, RANGES.size)) { Text(label, maxLines = 1) }
                    }
                }
            }
        }
        item(key = "dashboard") {
            val stats = home.stats(range)
            AnimatedContent(stats, label = "range") { current ->
                Column(Modifier.padding(horizontal = 16.dp).padding(top = 16.dp)) {
                    when {
                        current == null -> {}
                        current.plays == 0L && current.minutes == 0.0 -> Text(
                            "Nothing played yet. Play some music, or import your Last.fm history on your ${Host.word}, and your listening shows here.",
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                        else -> Dashboard(current)
                    }
                }
            }
        }
    }
}

private fun greeting(): String = when (LocalTime.now().hour) {
    in 5..11 -> "Good Morning"
    in 12..17 -> "Good Afternoon"
    else -> "Good Evening"
}

private fun kindTitle(kind: String) = when (kind) {
    "song" -> "Song of the Day"
    "album" -> "Album of the Day"
    else -> "Artist of the Day"
}

/** One of the day's picks: the cover (opens it), what it is and why, Play, Shuffle, Bring Here and Something Else. */
@Composable
private fun PickCard(card: HomeSnapshot.Card, alternatives: Boolean, modifier: Modifier, somethingElse: () -> Unit) {
    val actions = LocalActions.current
    val holdings by actions.library.holdings.collectAsStateWithLifecycle()
    val catalogTracks by actions.library.catalogTracks.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()
    val here = card.trackIds.filter { it in holdings.trackIds }
    val isArtist = card.kind == "artist"
    val route: Route? = when (card.kind) {
        "artist" -> if (here.isNotEmpty()) Route.ArtistPage(card.key) else Route.MacArtistPage(card.key)
        "album" -> if (card.key in holdings.albumKeys) Route.AlbumPage(card.key) else Route.MacAlbumPage(card.key)
        else -> catalogTracks?.firstOrNull { it.id == card.key.toLongOrNull() }?.albumKey
            ?.let { if (it in holdings.albumKeys) Route.AlbumPage(it) else Route.MacAlbumPage(it) }
    }
    val play = { shuffle: Boolean ->
        if (actions.player.playsOnMac) {
            actions.player.playOnMac(card.trackIds, 0, shuffle)
        } else scope.launch {
            val tracks = actions.library.tracksWithIds(here)
            if (tracks.isNotEmpty()) actions.player.play(actions.library.mediaItems(tracks, kindTitle(card.kind)), 0, if (shuffle) true else null)
        }
        Unit
    }
    Column(modifier.clip(RoundedCornerShape(20.dp)).background(MaterialTheme.colorScheme.surfaceContainer).padding(14.dp)) {
        Text(kindTitle(card.kind).uppercase(), style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(10.dp))
        CatalogCover(card.artworkHash, Modifier.fillMaxWidth().aspectRatio(1f).clickable(enabled = route != null) { route?.let(actions.open) },
            round = isArtist, corner = 12.dp)
        Spacer(Modifier.height(10.dp))
        Text(card.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(card.subtitle, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(card.reasonText, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.outline, maxLines = 2, minLines = 2,
            overflow = TextOverflow.Ellipsis)
        Spacer(Modifier.height(10.dp))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            val playable = actions.player.playsOnMac || here.isNotEmpty()
            if (playable) {
                Button(onClick = { play(false) }) {
                    Icon(painterResource(R.drawable.ic_play), contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Play")
                }
                if (card.trackIds.size > 1) FilledTonalIconButton(onClick = { play(true) }) {
                    Icon(painterResource(R.drawable.ic_shuffle), contentDescription = "Shuffle")
                }
            }
            if (here.size < card.trackIds.size) {
                FilledTonalButton(onClick = {
                    if (card.kind == "album") actions.library.request(TransferRequest.ADD, TransferRequest.ALBUM, card.key)
                    else card.trackIds.filter { it !in holdings.trackIds }.forEach { actions.library.request(TransferRequest.ADD, TransferRequest.SONG, it.toString()) }
                    actions.notify("\"${card.title}\" will come to this device")
                }, contentPadding = PaddingValues(horizontal = 12.dp)) {
                    Icon(painterResource(R.drawable.ic_download), contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(if (playable) "Bring" else "Bring Here", maxLines = 1)
                }
            }
            Spacer(Modifier.weight(1f))
            if (alternatives) FilledTonalIconButton(onClick = somethingElse) {
                Icon(painterResource(R.drawable.ic_refresh), contentDescription = "Something Else")
            }
        }
    }
}

// MARK: Dashboard

private fun hours(minutes: Double): String =
    if (minutes >= 120) "${Math.round(minutes / 60)} hr" else "${Math.round(minutes)} min"

private fun placeName(place: String) = when (place) {
    "here" -> Host.word
    "devices" -> "Phones"
    else -> "Last.fm"
}

@Composable
private fun placeColor(place: String): Color = when (place) {
    "here" -> MaterialTheme.colorScheme.primary
    "devices" -> Color(0xFF14B8A6)
    else -> Color(0xFFE5484D)
}

@Composable
private fun Dashboard(stats: HomeSnapshot.Stats) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        val tiles = listOf(
            Triple("Listening", hours(stats.minutes), R.drawable.ic_schedule),
            Triple("Plays", "%,d".format(stats.plays), R.drawable.ic_play),
            Triple("Songs", "%,d".format(stats.songs), R.drawable.ic_music),
            Triple(if (stats.range == "all") "Songs Heard" else "New to You", "%,d".format(stats.newSongs), R.drawable.ic_library_add),
            Triple("Streak", if (stats.streak == 1L) "1 day" else "${stats.streak} days", R.drawable.ic_timer),
            Triple("Loved", "%,d".format(stats.loved), R.drawable.ic_favorite),
        )
        tiles.chunked(2).forEach { pair ->
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                pair.forEach { (title, value, icon) -> Tile(title, value, icon, Modifier.weight(1f)) }
            }
        }
        Panel("Listening Time") { OverTime(stats) }
        Panel("When You Listen") { HeatMap(stats) }
        Panel("Where") { Places(stats) }
        Panel("Top Songs") { RankedRows(stats.topSongs, RankedKind.SONG) }
        Panel("Top Albums") { RankedRows(stats.topAlbums, RankedKind.ALBUM) }
        Panel("Top Artists") { RankedRows(stats.topArtists, RankedKind.ARTIST) }
        if (stats.genres.isNotEmpty()) Panel("Genres") { Bars(stats.genres) }
        if (stats.decades.isNotEmpty()) Panel("Decades") { Decades(stats.decades) }
        Text("${"%,d".format(stats.librarySongs)} songs on your ${Host.word}, ${"%,d".format(stats.neverPlayed)} never played.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun Tile(title: String, value: String, icon: Int, modifier: Modifier) {
    Column(modifier.clip(RoundedCornerShape(18.dp)).background(MaterialTheme.colorScheme.surfaceContainer).padding(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(painterResource(icon), contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(4.dp))
            Text(title, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
        }
        Text(value, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, maxLines = 1)
    }
}

@Composable
private fun Panel(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(MaterialTheme.colorScheme.surfaceContainer).padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, modifier = Modifier.semantics { heading() })
        content()
    }
}

/** "Mon" for a day of the week, "8" for a day of the month, "Nov" for a month, the year as is. */
private fun shortLabel(label: String, range: String): String {
    val parts = label.split("-")
    return runCatching {
        when (range) {
            "week" -> LocalDate.parse(label).dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.getDefault())
            "month" -> parts[2].toInt().toString()
            "year" -> java.time.Month.of(parts[1].toInt()).getDisplayName(TextStyle.SHORT, Locale.getDefault())
            else -> label
        }
    }.getOrDefault(label)
}

/** Minutes per day, month or year, stacked by place. */
@Composable
private fun OverTime(stats: HomeSnapshot.Stats) {
    val colors = HomeSnapshot.PLACES.associateWith { placeColor(it) }
    val most = maxOf(stats.buckets.maxOfOrNull { it.total } ?: 0.0, 1.0)
    val grid = MaterialTheme.colorScheme.outlineVariant
    Canvas(Modifier.fillMaxWidth().height(170.dp).semantics { contentDescription = "Listening time, ${hours(stats.minutes)} in all" }) {
        val count = stats.buckets.size.coerceAtLeast(1)
        val slot = size.width / count
        val bar = slot * 0.7f
        for (line in 0..2) {
            val y = size.height * line / 2f
            drawLine(grid, Offset(0f, y), Offset(size.width, y), strokeWidth = 1f)
        }
        stats.buckets.forEachIndexed { index, bucket ->
            var bottom = size.height
            HomeSnapshot.PLACES.forEach { place ->
                val minutes = bucket.minutes[place] ?: 0.0
                if (minutes <= 0) return@forEach
                val height = (minutes / most * size.height).toFloat()
                drawRoundRect(colors.getValue(place), Offset(index * slot + (slot - bar) / 2, bottom - height), Size(bar, height), CornerRadius(3f, 3f))
                bottom -= height
            }
        }
    }
    // Every few bars' label.
    val step = maxOf(1, (stats.buckets.size + 6) / 7)
    Row(Modifier.fillMaxWidth()) {
        stats.buckets.forEachIndexed { index, bucket ->
            Text(if (index % step == 0) shortLabel(bucket.label, stats.range) else "", style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, softWrap = false,
                modifier = Modifier.weight(1f).wrapContentWidth(Alignment.Start, unbounded = true))
        }
    }
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        HomeSnapshot.PLACES.forEach { Legend(placeName(it), colors.getValue(it)) }
    }
    Text("Most in one ${if (stats.range == "year") "month" else if (stats.range == "all") "year" else "day"}: ${hours(most)}",
        style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun Legend(name: String, color: Color) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(8.dp).clip(CircleShape).background(color))
        Spacer(Modifier.width(4.dp))
        Text(name, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Plays by weekday and hour, the busiest hour darkest. */
@Composable
private fun HeatMap(stats: HomeSnapshot.Stats) {
    val most = maxOf(stats.hours.flatten().maxOrNull() ?: 0L, 1L)
    val color = MaterialTheme.colorScheme.primary
    // Sunday first, as the Mac sends them.
    val days = (0 until 7).map { java.time.DayOfWeek.of(if (it == 0) 7 else it).getDisplayName(TextStyle.NARROW, Locale.getDefault()) }
    Column(Modifier.semantics { contentDescription = "Plays by weekday and hour" }, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        stats.hours.forEachIndexed { day, row ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(days[day], style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.width(14.dp))
                row.forEach { plays ->
                    val alpha = if (plays == 0L) 0.08f else 0.2f + 0.8f * plays / most
                    Box(Modifier.weight(1f).height(14.dp).clip(RoundedCornerShape(2.dp)).background(color.copy(alpha = alpha)))
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            Spacer(Modifier.width(14.dp))
            (0 until 24).forEach { hour ->
                Text(if (hour % 6 == 0) "$hour" else "", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1, softWrap = false,
                modifier = Modifier.weight(1f).wrapContentWidth(Alignment.Start, unbounded = true))
            }
        }
    }
}

/** Plays by place, as a ring. */
@Composable
private fun Places(stats: HomeSnapshot.Stats) {
    val shares = HomeSnapshot.PLACES.mapNotNull { place -> stats.places[place]?.takeIf { it > 0 }?.let { place to it } }
    val total = shares.sumOf { it.second }.coerceAtLeast(1)
    val colors = HomeSnapshot.PLACES.associateWith { placeColor(it) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Canvas(Modifier.size(120.dp)) {
            val stroke = size.minDimension * 0.18f
            var start = -90f
            shares.forEach { (place, plays) ->
                val sweep = 360f * plays / total
                drawArc(colors.getValue(place), start + 1f, (sweep - 2f).coerceAtLeast(0.5f), useCenter = false,
                    topLeft = Offset(stroke / 2, stroke / 2), size = Size(size.width - stroke, size.height - stroke), style = Stroke(stroke))
                start += sweep
            }
        }
        Spacer(Modifier.width(20.dp))
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            shares.forEach { (place, plays) ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Legend(placeName(place), colors.getValue(place))
                    Spacer(Modifier.width(8.dp))
                    Text("${plays * 100 / total}%", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
                }
            }
        }
    }
}

private enum class RankedKind { SONG, ALBUM, ARTIST }

/** A top list: rank, cover, name and a bar for the plays; albums and artists open their page. */
@Composable
private fun RankedRows(items: List<HomeSnapshot.Ranked>, kind: RankedKind) {
    val actions = LocalActions.current
    val holdings by actions.library.holdings.collectAsStateWithLifecycle()
    val artists by actions.library.artists.collectAsStateWithLifecycle()
    if (items.isEmpty()) {
        Text("Nothing yet", color = MaterialTheme.colorScheme.onSurfaceVariant)
        return
    }
    val most = maxOf(items.first().plays, 1L)
    items.take(8).forEachIndexed { index, item ->
        val route = when (kind) {
            RankedKind.SONG -> null
            RankedKind.ALBUM -> if (item.key in holdings.albumKeys) Route.AlbumPage(item.key) else Route.MacAlbumPage(item.key)
            RankedKind.ARTIST -> if (artists.orEmpty().any { it.name == item.key }) Route.ArtistPage(item.key) else Route.MacArtistPage(item.key)
        }
        Row(Modifier.fillMaxWidth().clickable(enabled = route != null) { route?.let(actions.open) }, verticalAlignment = Alignment.CenterVertically) {
            Text("${index + 1}", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.widthIn(min = 20.dp))
            if (kind != RankedKind.ARTIST) {
                CatalogCover(item.artworkHash, Modifier.size(40.dp), corner = 6.dp)
                Spacer(Modifier.width(10.dp))
            }
            Column(Modifier.weight(1f)) {
                Text(item.name, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Box(Modifier.padding(vertical = 3.dp).fillMaxWidth(item.plays.toFloat() / most).height(4.dp).clip(CircleShape)
                    .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.5f)))
                if (item.detail.isNotEmpty()) Text(item.detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Spacer(Modifier.width(8.dp))
            Text("%,d".format(item.plays), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** Horizontal bars (genres), with their plays. */
@Composable
private fun Bars(items: List<HomeSnapshot.Ranked>) {
    val most = maxOf(items.maxOf { it.plays }, 1L)
    items.forEach { item ->
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(item.name, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.width(96.dp))
            Box(Modifier.weight(1f)) {
                Box(Modifier.fillMaxWidth(item.plays.toFloat() / most).height(14.dp).clip(RoundedCornerShape(4.dp))
                    .background(MaterialTheme.colorScheme.primary))
            }
            Text("%,d".format(item.plays), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 6.dp).widthIn(min = 28.dp))
        }
    }
}

/** Plays per decade, as columns. */
@Composable
private fun Decades(items: List<HomeSnapshot.Ranked>) {
    val most = maxOf(items.maxOf { it.plays }, 1L)
    val color = Color(0xFF8B5CF6)
    Canvas(Modifier.fillMaxWidth().height(120.dp)) {
        val slot = size.width / items.size
        val bar = minOf(slot * 0.6f, 48.dp.toPx())
        items.forEachIndexed { index, item ->
            val height = size.height * item.plays / most
            drawRoundRect(color, Offset(index * slot + (slot - bar) / 2, size.height - height), Size(bar, height), CornerRadius(4.dp.toPx()))
        }
    }
    Row(Modifier.fillMaxWidth()) {
        items.forEach {
            Text(it.name, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center, modifier = Modifier.weight(1f))
        }
    }
}
