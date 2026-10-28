# Groovelight for Android

The Android companion of Groovelight: syncs music from Groovelight on the Mac to an Android 12+ player (FiiO, HiBy, Shanling, Sony and other Android DAPs) or phone over the local Wi-Fi.

It has two modes, chosen at first run:

- **Player** (in releases since 0.5.0): Groovelight plays the music too, with the library as the Mac knows it: albums, artists, songs and playlists with their covers, Sound Check style normalization, gapless playback and crossfade. Release builds include it with `-Pplayer=true` (the release workflow passes it); without it, the build is Groovelight Sync, the sync-only app of 0.4 and earlier.
- **Sync only** (Groovelight Sync, as it always was): Groovelight copies the music into a folder and another player app plays it.

Devices that synced before the modes existed stay in Sync only; the Sync screen offers to try the player.

## How sync works

- Groovelight on the Mac serves on the local network (Bonjour `_groovelight._tcp`, port 52300 by default) once Settings, Devices, "Sync with phones and players over Wi-Fi" is on.
- While the Mac plays (Play On), a tap on a song of the Mac's library plays it there with the rest of its album, here or not; the Mac's album page then has Play and Shuffle on the Mac. Now Playing shows the cover and the lyrics of a song that is not on the device from the Mac (`GET /catalog/lyrics/<id>`, HTTPS; the Mac looks lyrics up online first when it has none).
- Away from home, the app reaches the Mac through Tailscale when it is on on both and the Mac allows the device on its page ("Let ... connect away from home"): the Mac gives its Tailscale addresses at each connection, and the app tries them when the Mac is not at its address at home or found on the network. Pairing is only at home. Syncing away waits for Wi-Fi unless Settings, "Sync over Mobile Data" is on.
- The app finds the Mac (or takes its address, shown in the same settings), and pairs once: an X25519 key exchange, with a 6-digit code shown on both screens that the user compares before clicking Allow on the Mac. The derived key never travels; every later request is signed with it (HMAC-SHA256 over method, path, time, nonce and body hash).
- A sync pulls: the app sends the folder's file list and its `.groovelight-device.json` (the same manifest Groovelight writes on memory cards), the Mac answers with a plan (made by the same engine as for cards), and the app removes and downloads files (resuming cut-off downloads with Range requests), keeps the manifest current and asks Android's media library to rescan, so player apps see the songs.
- What a device gets is chosen on the Mac, on its page under Devices (all music, or playlists, artists, albums, genres), along with the folder layout, covers, lyrics and playlists. "Send to" on the Mac queues songs for the device's next sync.
- **Protocol v2 (Groovelight 0.5 on the Mac):** the Mac also serves HTTPS on the next port (52301), reported by `/info`. The app asks once, over HTTP, for the certificate's fingerprint with a proof made with the pairing key (only the paired Mac can make it), pins it, and from then on talks only HTTPS to that certificate; a Mac that stops offering HTTPS after that is refused. Each plan carries a download token, and every file comes with its SHA-256, checked after writing (a damaged copy is downloaded again).
- **Player mode** sends the formats this device decodes (`Formats`, from Android's codec list): the Mac converts the others to FLAC (ALAC, AIFF and WavPack on the phones and DAPs tested), splits CUE albums into one FLAC per song, sends only the songs (no cover.jpg, .lrc or playlist files), and after the files the app fetches the library snapshot (with credits, playlist covers, the artists' photos from the Mac's artist pages and the Mac's equalizer presets) and the covers it needs, and replaces its database with it. Loves, ratings, plays and playlist edits made on the device are journaled and kept over the next snapshots until the Mac has them. Sync only mode gets what Groovelight Sync always got.
- **The Mac's whole library** (Player mode, v2): after each sync the app fetches the Mac's catalog (`GET /catalog`, deflated, only when its version changed) and shows it under Library, On the Mac, each album and song marked as on this device, arriving at the next sync, waiting for the Mac, or leaving. Albums, artists and songs can be added or removed there: the requests are kept on the device (`transfer_request`) and sent with `POST /requests`, which changes this device's selection on the Mac. When the Mac is away they wait: `RequestWorker` retries (30 seconds more each time), the app asks every few seconds while open, and the automatic sync sends them first; a sync follows, so the music arrives.
- **Loves and ratings** travel both ways: the Mac's arrive with each sync's snapshot; the device's go to the Mac (`POST /history`, HTTPS) at the start of each sync, within seconds while the app is open, or later from `RequestWorker` when the Mac is away. On a conflict the newer change wins (a song loved on the Mac after it was unloved here stays loved). Loves made here reach Last.fm through the Mac.
- **Plays and skips** count as on the Mac: a play from half of a song (or 4 minutes), a skip under 20 seconds. The device counts them at once and sends them with the loves, with the time each song started; the Mac counts each once (by its id, even when sent again), moves Last Played only forward, and scrobbles them to Last.fm with their original times (Last.fm takes up to two weeks back).
- **Playlists** can be made, added to, cleaned (Remove from Playlist), renamed and deleted on the device; the edits go to the Mac the same way. A playlist made here has a negative id until the next sync brings the Mac's (the Mac remembers which one it made, so later edits find it). Smart playlists come with their rules and are evaluated on the device's songs after each sync, love, rating and play (and at start, for date rules); rules on what the device does not know (composer, comments, format, skips, bit rate, BPM, quality, sizes) keep the Mac's songs. Empty smart playlists are hidden.
- **Removing from this device:** songs, albums, artists and playlists can be removed on the device (their menus): the Mac leaves their songs off this device whatever brings them (a playlist, all music, a send) and the next sync deletes their files; the Mac's library is never changed. Adding them again from On the Mac brings them back.
- **Share:** songs and albums share their title, artist and cover through Android's share sheet; a song can also share its file.
- **Lossy formats:** each device can get lossless songs as Opus 160 kbps, AAC 192 kbps or MP3 320 kbps, for memory cards and players too; lossy songs are copied as they are. The device's default is set in its Settings (Lossless Songs, sent with each sync) or on its page on the Mac; an album or artist can also be added in a format of its own ("Add as" on its page in the Mac's library), and an album's format changed later (the next sync makes its songs again). A song's own format wins over its album's, its album's over its artist's, and those over the device's.
- **One library:** with Downloaded off (or Settings, Show the Mac's Music), the Library shows the Mac's whole library with this device's music; what is here is marked with a check and opens its full page, what is only on the Mac opens its page there, to add it.
- **Play on the Mac or another phone** (Player mode, v2): the speaker button in the Library and Now Playing ("Play On") picks this device, the paired Mac, or another phone or iPad with Groovelight open, when the Mac allows it ("Let <device> play music on this Mac and your other devices" on the device's page there). With the Mac chosen, Now Playing ("PLAYING ON <Mac>"), the mini player and the controls follow and drive the Mac's player (`MacRemote`: `GET /remote`, held by the Mac until its state changes, and `POST /remote` with flat commands such as `{"command": "seek", "position": 42}`; `RemoteState` and `RemoteCommand` in `sync`). Choosing the Mac moves what plays here to the Mac at the same place and pauses here; choosing this device takes the Mac's queue (the songs here) at the same place and pauses the Mac, unless this device is not synced with the Mac's current library (the song playing there has another id here). Up Next, Play Next and Add to Queue are this device's only. Another phone is reached through the Mac (`GET /remote/devices`, then the same routes with `?device=<id>`); choosing one moves the queue there, from this device or from wherever it played. This device can be played on too, while the app is open (`RelayReceiver`: waits on `GET /relay`, applies the commands, reports with `POST /relay/state`; "Let other devices play here" in Sync).
- Syncs run as WorkManager foreground jobs with a notification; the automatic one checks every 15 minutes on Wi-Fi (optionally only while charging) and only syncs when the Mac's Sync button was pressed, songs were sent, or 6 hours passed. While the app is open it checks every 5 seconds.

## Modules

| Module | What it holds |
|---|---|
| `sync` | Pairing, signed requests, the Mac client, the sync engine, the music folder (Storage Access Framework) and the WorkManager worker. Class names are Groovelight Sync's, which scheduled syncs depend on across the update |
| `library` | The library on the device: a Room database (songs, albums, playlists with their covers, credits, the Mac's equalizer presets, an FTS search index; the Mac's ids and album keys) replaced from the Mac's library snapshot after each Player-mode sync (`Snapshot`), the history journal of loves, ratings, plays and playlist edits made here, smart playlist rules evaluated on the device's songs (`SmartRules`), and the covers (`ArtworkStore`). Schemas are kept in `library/schemas`. `src/test/resources/snapshot-v1.json` is written by the Mac's `SnapshotFixtureTests`, so both sides read the same file |
| `playback` | The Media3 library service (notification, lock screen, headset and player buttons, and Android Auto browsing the library through `Browsing`, which the app provides), with two players for crossfade (`Crossfade`: near a song's end the idle player starts the next song rising while the other fades out, and the session moves to it; not within an album, which stays gapless), `NowPlayingInfo` (what plays, for the widgets), `AudioTap` (what is heard, for the visualizers), `QueueStore` (the queue saved across restarts, for the app and for Bluetooth's play button), `Normalization` (each song's or album's gain from the Mac, as the player's volume), the 15-band parametric equalizer (`Equalizer`: the Mac's RBJ biquads, presets and AutoEq files; `EqualizerSink`, which runs it in float in front of the audio sink, since Media3 skips audio processors for hi-res float output), `BitPerfect` (a USB DAC's mixer set to the song's format on Android 14 and later), `SleepTimer`, `Listens` (how long each song was heard, for plays and skips; the app's `GroovelightApp` counts them), `PlaybackSettings` and `AudioPathReport`: the file's format, the decoder, and what goes to Android's mixer |
| `app` | The screens (Compose, Material 3 with Groovelight's colors): the mode choice, the Sync screen, and the player: Library, Search, Shelf and Settings tabs (Navigation 3, each tab keeping its pages; a bar on phones and a rail in landscape and on medium-width screens; from 840 dp wide, an unfolded foldable or a tablet, the iPad's sidebar instead, `Sidebar.kt`: Search, the Library's sections, Shelf, Loved Songs and the playlists, Settings), bars of frosted glass over the page (Haze, `Glass.kt`: the bottom bar, and every screen's top bar, which on album, artist and playlist pages shows once the header scrolls away), a theme setting as on the Mac (System, Light, Dark; the Shelf is always dark), Library sections with sorting, an A to Z index beside Artists and Songs of 40 or more (`AlphabetIndex.kt`: always shown, tap or drag along it to jump, the letter shown large beside the finger, letters with nothing under them dimmed, every second or third letter in short windows; a fast scroller instead for songs by date added) and covers sized by pinching, album pages with credits ("Produced by"), artist, person and playlist pages (playlist covers drawn as on the Mac), search with credits, song menus (Play Next, Add to Queue, Add to Playlist, Go to Album or Artist), playlist editing (New Playlist, Remove from Playlist, Rename, Delete), a mini player (glass; Now Playing grows out of it, a container transform with the cover flying between the two, driven by one seekable transition so a swipe up, or down on Now Playing, moves it with the finger and it finishes past a quarter of the way or on a flick; swipe down or hold for Close Player, Clear Up Next and Clear Queue; hidden after a while paused, 15 minutes by default, set in Settings; from 600 dp wide, a player bar docked along the bottom of the page instead, as Material's large screen media apps have it: a tonal surface with the progress along its top edge, the song with its quality, shuffle, previous, play, next and repeat in the middle, and Lyrics, Play On and Up Next, which open Now Playing on theirs), Now Playing on the cover's colors (its cover fits short screens such as a passport-shaped foldable's cover screen; from 840 dp wide, as on the iPad, the cover and controls with the lyrics or Up Next beside them) with "artist — album" links to their pages (here, or on the Mac), the cover swiped left for the next song and right for the previous, love and rating, synced lyrics, Up Next (reorder, remove), shuffle, repeat, speed, sleep timer and the audio details, the Shelf (Cover Flow, flips to the songs), the equalizer's curve editor and the sound settings (crossfade, 0 to 12 seconds), the visualizers (Bars, Waves, and with Android 13 the AGSL shaders Lights and Tunnel, from an FFT of `AudioTap`), the Quick Settings tile (`PlayerTile`), the home screen widgets Now Playing and Recently Played (Glance), Android Auto's library (`LibraryBrowsing`, with covers from `ArtworkProvider`) and voice search ("play ... on Groovelight"), and, in the GitHub build only, the update check (`update/`: the latest GitHub release, its APK checked against its SHA-256 and installed by Android's package installer; the Play build has none of it) |

## Build

Needs JDK 17 and the Android SDK (no Android Studio required). The app compiles against Android 37 and targets 36 (the level Google Play requires):

```sh
brew install openjdk@17 && brew install --cask android-commandlinetools
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
sdkmanager "platforms;android-37.0" "build-tools;37.0.0" "platform-tools"

cd android
./gradlew testDebugUnitTest :app:testGithubDebugUnitTest   # pairing test vector shared with the Mac's WirelessSyncTests, the database
./gradlew assembleGithubDebug        # app/build/outputs/apk/github/debug/app-github-debug.apk (with the player)
./gradlew assembleGithubRelease      # app/build/outputs/apk/github/release/app-github-release.apk (Sync only; -Pplayer=true adds the player)
```

Two flavors, by where the app is distributed: `github` (the APK attached to releases; it will carry the in-app update check) and `play` (an App Bundle for Google Play, which does not allow apps to update themselves).

### Google Play readiness

The app is not on Google Play, but every release is kept ready to submit. CI builds and checks the Play flavor:

```sh
./gradlew bundlePlayRelease checkPlayReleasePolicy :app:lintPlayRelease
```

`checkPlayReleasePolicy` fails when the merged manifest asks for a permission that is not on the list in `app/build.gradle.kts` (each with its reason) or targets an API level below Play's requirement. The store paperwork (privacy policy, Data safety answers, listing) is drafted in [`play/`](play/).

### Checking formats on a device

Debug builds show the audio path in Now Playing (tap the mini player): the file's format, the decoder, and the format handed to Android ("32-bit float, 192 kHz" keeps a 24-bit file's resolution). A song this device cannot decode pauses with "This device cannot decode ..." instead of playing silence. Every player event is logged:

```sh
adb logcat -s EventLogger
```

Results on the emulator (Android 16), a phone and a HiBy R4: FLAC up to 24-bit 192 kHz (handed to Android as 32-bit float, full resolution), WAV, AAC, MP3 and Opus play; ALAC has no decoder; AIFF and WavPack cannot be read by Media3. The Mac converts these to FLAC for Player mode.

### Integration test against a running Groovelight (debug build)

```sh
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold wireless -GLDebugAutoPair YES [-GLDebugSyncEverything YES]   # writes /tmp/tour/PORT
GL_MAC_PORT=52300 ./gradlew :sync:testDebugUnitTest --tests '*MacIntegrationTest*'
```

The Mac's HTTPS certificate lives in the login keychain. Each unsandboxed debug build makes its own (labeled `dev.irwingbraga.groovelight.wireless-tls.unsandboxed.<build time>`), since macOS asks before a build uses a key another build made; old ones can be deleted in Keychain Access.

The emulator reaches the Mac at `10.0.2.2` (enter it as the Mac's address: Bonjour does not cross the emulator's network).

## Install

Each Groovelight release on GitHub has the APK attached (`Groovelight-<version>.apk` since 0.5.0, `GroovelightSync-<version>.apk` before; signed with the release key, so new versions install over old ones, Groovelight Sync included). The GitHub build then checks the releases once a day and offers each new version (Settings, App Updates). Apps installed from a local build are signed with the debug key: uninstall them once before installing a release.

Enable USB debugging on the device (Settings, About, tap Build number seven times; then Developer options, USB debugging), connect it and run `adb install -r app/build/outputs/apk/github/debug/app-github-debug.apk`. Or copy the APK to the device and open it (allow installing unknown apps for the file manager).

Then: open the app, pick the Mac, compare the code and click Allow on the Mac, choose the music folder ("Choose on SD card" opens the picker on the card; pick a folder such as Music, as Android does not let apps pick a drive's root; switching folders offers to remove Groovelight's songs from the old one), and choose what to sync on the Mac's device page.
