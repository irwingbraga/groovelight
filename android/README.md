# Groovelight Sync (Android)

The Android companion of Groovelight: syncs music from Groovelight on the Mac to an Android 12+ player (FiiO, HiBy, Shanling, Sony and other Android DAPs) or phone over the local Wi-Fi.

## How it works

- Groovelight on the Mac serves on the local network (Bonjour `_groovelight._tcp`, port 52300 by default) once Settings, Devices, "Sync with Android devices over Wi-Fi" is on.
- The app finds the Mac (or takes its address, shown in the same settings), and pairs once: an X25519 key exchange, with a 6-digit code shown on both screens that the user compares before clicking Allow on the Mac. The derived key never travels; every later request is signed with it (HMAC-SHA256 over method, path, time, nonce and body hash).
- A sync pulls: the app sends the folder's file list and its `.groovelight-device.json` (the same manifest Groovelight writes on memory cards), the Mac answers with a plan (made by the same engine as for cards), and the app removes and downloads files (resuming cut-off downloads with Range requests), keeps the manifest current and asks Android's media library to rescan, so player apps see the songs.
- What a device gets is chosen on the Mac, on its page under Devices (all music, or playlists, artists, albums, genres), along with the folder layout, covers, lyrics and playlists. "Send to" on the Mac queues songs for the device's next sync.
- Syncs run as WorkManager foreground jobs with a notification; the automatic one checks every 15 minutes on Wi-Fi (optionally only while charging) and only syncs when the Mac's Sync button was pressed, songs were sent, or 6 hours passed. While the app is open it checks every 5 seconds.

## Build

Needs JDK 17 and the Android SDK (no Android Studio required):

```sh
brew install openjdk@17 && brew install --cask android-commandlinetools
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
sdkmanager "platforms;android-35" "build-tools;35.0.0" "platform-tools"

cd android
./gradlew testDebugUnitTest       # pairing test vector shared with the Mac's WirelessSyncTests
./gradlew assembleRelease         # app/build/outputs/apk/release/app-release.apk (signed with the debug key, for sideloading)
```

Integration test against a running Groovelight (debug build):

```sh
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold wireless -GLDebugAutoPair YES   # writes /tmp/tour/PORT
GL_MAC_PORT=52300 ./gradlew testDebugUnitTest --tests '*MacIntegrationTest*'
```

## Install

Each Groovelight release on GitHub has the APK attached (`GroovelightSync-<version>.apk`, signed with the release key, so new versions install over old ones). Apps installed from a local build are signed with the debug key: uninstall them once before installing a release.

Enable USB debugging on the device (Settings, About, tap Build number seven times; then Developer options, USB debugging), connect it and run `adb install -r app/build/outputs/apk/release/app-release.apk`. Or copy the APK to the device and open it (allow installing unknown apps for the file manager).

Then: open the app, pick the Mac, compare the code and click Allow on the Mac, choose the music folder ("Choose on SD card" opens the picker on the card; pick a folder such as Music, as Android does not let apps pick a drive's root; switching folders offers to remove Groovelight's songs from the old one), and choose what to sync on the Mac's device page.
