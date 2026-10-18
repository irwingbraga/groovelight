# Groovelight for Android

The Android companion of Groovelight: syncs music from Groovelight on the Mac to an Android 12+ player (FiiO, HiBy, Shanling, Sony and other Android DAPs) or phone over the local Wi-Fi.

It has two modes, chosen at first run:

- **Sync only** (Groovelight Sync, as released): Groovelight copies the music into a folder and another player app plays it.
- **Player** (in development, see the plan in Obsidian, "Groovelight for Android - Implementation Plan"): Groovelight plays the music too. It is built into debug builds, and into release builds only with `-Pplayer=true`, so releases stay Groovelight Sync until the player is ready.

Devices that synced before the modes existed stay in Sync only; the Sync screen offers to try the player.

## How sync works

- Groovelight on the Mac serves on the local network (Bonjour `_groovelight._tcp`, port 52300 by default) once Settings, Devices, "Sync with Android devices over Wi-Fi" is on.
- The app finds the Mac (or takes its address, shown in the same settings), and pairs once: an X25519 key exchange, with a 6-digit code shown on both screens that the user compares before clicking Allow on the Mac. The derived key never travels; every later request is signed with it (HMAC-SHA256 over method, path, time, nonce and body hash).
- A sync pulls: the app sends the folder's file list and its `.groovelight-device.json` (the same manifest Groovelight writes on memory cards), the Mac answers with a plan (made by the same engine as for cards), and the app removes and downloads files (resuming cut-off downloads with Range requests), keeps the manifest current and asks Android's media library to rescan, so player apps see the songs.
- What a device gets is chosen on the Mac, on its page under Devices (all music, or playlists, artists, albums, genres), along with the folder layout, covers, lyrics and playlists. "Send to" on the Mac queues songs for the device's next sync.
- Syncs run as WorkManager foreground jobs with a notification; the automatic one checks every 15 minutes on Wi-Fi (optionally only while charging) and only syncs when the Mac's Sync button was pressed, songs were sent, or 6 hours passed. While the app is open it checks every 5 seconds.

## Modules

| Module | What it holds |
|---|---|
| `sync` | Pairing, signed requests, the Mac client, the sync engine, the music folder (Storage Access Framework) and the WorkManager worker. Class names are Groovelight Sync's, which scheduled syncs depend on across the update |
| `library` | The library on the device: a Room database (songs, albums, artists, playlists, keyed by the Mac's ids), filled from the Mac's library snapshot in phase 1. Schemas are kept in `library/schemas` |
| `playback` | The Media3 session service (notification, lock screen, headset and player buttons) and `AudioPathReport`: the file's format, the decoder, and what goes to Android's mixer |
| `app` | The screens (Compose, Material 3 with Groovelight's colors): the mode choice, the Sync screen, and the player (phase 0: the songs in the folder, a mini player and Now Playing with the audio path) |

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

Results on the emulator (Android 16): FLAC up to 24-bit 192 kHz, WAV, AAC, MP3 and Opus play; ALAC (16 and 24-bit) has no decoder; AIFF and WavPack cannot be read by Media3 (the plan converts these on the Mac).

### Integration test against a running Groovelight (debug build)

```sh
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold wireless -GLDebugAutoPair YES   # writes /tmp/tour/PORT
GL_MAC_PORT=52300 ./gradlew :sync:testDebugUnitTest --tests '*MacIntegrationTest*'
```

The emulator reaches the Mac at `10.0.2.2` (enter it as the Mac's address: Bonjour does not cross the emulator's network).

## Install

Each Groovelight release on GitHub has the APK attached (`GroovelightSync-<version>.apk`, signed with the release key, so new versions install over old ones). Apps installed from a local build are signed with the debug key: uninstall them once before installing a release.

Enable USB debugging on the device (Settings, About, tap Build number seven times; then Developer options, USB debugging), connect it and run `adb install -r app/build/outputs/apk/github/debug/app-github-debug.apk`. Or copy the APK to the device and open it (allow installing unknown apps for the file manager).

Then: open the app, pick the Mac, compare the code and click Allow on the Mac, choose the music folder ("Choose on SD card" opens the picker on the card; pick a folder such as Music, as Android does not let apps pick a drive's root; switching folders offers to remove Groovelight's songs from the old one), and choose what to sync on the Mac's device page.
