package dev.irwingbraga.groovelight.sync

import android.Manifest
import android.os.Build
import android.app.SearchManager
import android.content.Intent
import android.os.Bundle
import android.provider.MediaStore
import androidx.lifecycle.lifecycleScope
import dev.irwingbraga.groovelight.app.VoiceSearch
import kotlinx.coroutines.launch
import dev.irwingbraga.groovelight.playback.PlaybackSettings
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.irwingbraga.groovelight.BuildConfig
import dev.irwingbraga.groovelight.ui.Appearance
import dev.irwingbraga.groovelight.ui.Cassettes
import dev.irwingbraga.groovelight.ui.GroovelightTheme
import dev.irwingbraga.groovelight.ui.SystemBarIcons
import dev.irwingbraga.groovelight.ui.UpdatePrompt
import dev.irwingbraga.groovelight.ui.ListeningCard
import dev.irwingbraga.groovelight.ui.ModeChoice
import dev.irwingbraga.groovelight.ui.PlayerShell

// In Groovelight Sync's package: the launcher's component name stays the same across the update.
class MainActivity : ComponentActivity() {
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        playFromSearch(intent)
    }

    /** "Play ... on Groovelight" asked by voice: plays what is found (the app opens as well). */
    private fun playFromSearch(intent: Intent?) {
        if (intent?.action != MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH) return
        val query = intent.getStringExtra(SearchManager.QUERY)
        lifecycleScope.launch { VoiceSearch.play(this@MainActivity, query) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        playFromSearch(intent)
        PlaybackSettings.init(this)
        Appearance.init(this)
        Cassettes.init(this)
        enableEdgeToEdge()
        setContent {
            val dark = Appearance.isDark()
            SystemBarIcons(dark)
            GroovelightTheme(dark) {
                Surface(Modifier.fillMaxSize()) {
                    GroovelightApp()
                    UpdatePrompt()
                }
            }
        }
    }
}

/**
 * Sync only: the sync screen, as Groovelight Sync always was. Player (in builds with the player): the mode is chosen at
 * first run, set up (pairing and folder) on the sync screen, then the player.
 */
@Composable
private fun GroovelightApp(sync: SyncViewModel = viewModel()) {
    val notifications = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
    LaunchedEffect(Unit) {
        if (Build.VERSION.SDK_INT >= 33) notifications.launch(Manifest.permission.POST_NOTIFICATIONS)
    }
    if (!BuildConfig.PLAYER) {
        SyncScreen("Groovelight Sync", sync)
        return
    }
    val mode by sync.mode.collectAsStateWithLifecycle()
    val paired by sync.paired.collectAsStateWithLifecycle()
    val folder by sync.folder.collectAsStateWithLifecycle()
    when (val current = mode) {
        null -> ModeChoice(sync::setMode)
        Prefs.Mode.SYNC_ONLY -> SyncScreen("Groovelight", sync) { ListeningCard(current, sync::setMode) }
        Prefs.Mode.PLAYER -> if (!paired || folder == null) SyncScreen("Groovelight", sync) else PlayerShell(sync)
    }
}
