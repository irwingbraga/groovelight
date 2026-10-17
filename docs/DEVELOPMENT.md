# Developing Groovelight

Requirements: Xcode 26+ (developed with Xcode 27), [XcodeGen](https://github.com/yonaskolb/XcodeGen). The app runs on macOS 15 and later: Liquid Glass is used on macOS 26, and `App/Sources/Support/Glass.swift` falls back to blur materials and bordered buttons before that. Use its wrappers (`glassBackground(in:)`, `glassButtonStyle()`, `glassProminentButtonStyle()`, `clearGlassButtonStyle()`, `GlassGroup`) instead of the glass APIs directly, and guard other macOS 26 APIs with `#available`. The Android companion app has its own guide in [`android/README.md`](../android/README.md).

## Layout

- `GroovelightKit/`: Swift package shared with the future iOS app
  - `PlayerCore`: SFBAudioEngine playback, gapless queue, 15-band `AVAudioUnitEQ`, FFT spectrum analyzer
  - `LibraryKit`: GRDB (SQLite + FTS5) library, tag reader, artwork cache, folder scanner and watcher
  - `Visualizers`: Metal visualizers (Bars & Waves, Lights, Ambience, Magnetosphere), shaders compiled at runtime
  - `MetadataKit`: MusicBrainz, Cover Art Archive, iTunes Search and LRCLIB clients, release matching, LRC parser
  - `Scrobbler`: Last.fm client (desktop auth, now playing, scrobbles, loves) and the sender of the offline queue
  - `WirelessSync`: wireless sync with the Android app: protocol (X25519 pairing, signed requests), local HTTP server with Bonjour
- `App/`: the macOS app (SwiftUI views, app model, Now Playing / media keys)
- `android/`: Groovelight Sync, the Android 12+ companion app for wireless sync (Kotlin, Compose; see `android/README.md`)
- `project.yml`: XcodeGen spec (the `.xcodeproj` is generated, not committed)

## Build and test

```sh
# If xcode-select points at the Command Line Tools:
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

(cd GroovelightKit && swift test)        # unit + integration tests (real audio fixtures via afconvert)
(cd GroovelightKit && GL_LIVE_TESTS=1 swift test --filter LiveMetadataTests)   # opt in: hits the real web services
xcodegen generate
xcodebuild -project Groovelight.xcodeproj -scheme Groovelight -configuration Debug build
```

### Testing on macOS 15

A macOS 15 virtual machine with [Tart](https://tart.run) (Apple Silicon; the image is about 30 GB):

```sh
tart clone ghcr.io/cirruslabs/macos-sequoia-base:latest sequoia
tart run sequoia --dir="share:$PWD/build"      # user and password: admin; the folder is in /Volumes/My Shared Files/share
```

Copy a Debug build into the shared folder and open it in the VM; the debug tours below work there too (`tart exec sequoia <command>` runs a command in the VM, and `screencapture -l` works inside it).

## Releases

`.github/workflows/release.yml` runs on version tags (`git tag v0.2.0 && git push --tags`) or by hand from the Actions tab. It tests the package, builds a Release DMG with `scripts/make-dmg.sh`, signs and notarizes it when the Developer ID secrets are set, writes the Sparkle update feed (`appcast.xml`, signed with `SPARKLE_PRIVATE_KEY`), builds Groovelight Sync for Android (signed with the release keystore secrets) and attaches the DMG, the feed and the APK to a GitHub Release. The release notes come from `docs/releases/<tag>.md` (for example `docs/releases/v0.2.2.md`) when that file exists, otherwise GitHub lists the changes. The app reads the feed from the latest release (`SUFeedURL` in `project.yml`); the public half of the update key is `SUPublicEDKey`.

Secrets: `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`, `DEVELOPER_ID_IDENTITY`, `NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` (signing and notarization), `SPARKLE_PRIVATE_KEY` (updates), `ANDROID_KEYSTORE`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` (Android).

## Demo library and performance

```sh
# The demo library of the screenshots: 12 original albums (synthesized music, generated covers, invented lyrics)
# in FLAC, ALAC and AAC up to 24-bit / 192 kHz.
(cd GroovelightKit && GL_DEMO_LIBRARY="$HOME/Library/Application Support/Groovelight/DemoLibrary" swift test --filter DemoLibraryTests)

# A 50,000-song library: timings of every page's queries and of device sync plans (fails above 1 s per page).
(cd GroovelightKit && GL_PERF=1 swift test -c release -Xswiftc -enable-testing --filter PerformanceTests)
# Keep it, then open the app on it and measure how long each page blocks the main thread:
(cd GroovelightKit && GL_PERF=1 GL_PERF_KEEP=/tmp/perf/Library.sqlite swift test -c release -Xswiftc -enable-testing --filter PerformanceTests)
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold perf -GLDebugDataDir /tmp/perf
```

## Debug helpers (Debug builds only)

Build without the sandbox to point the app at any folder:

```sh
xcodebuild -project Groovelight.xcodeproj -scheme Groovelight -configuration Debug \
  -derivedDataPath build/DebugUnsandboxed CODE_SIGN_ENTITLEMENTS= build
APP=build/DebugUnsandboxed/Build/Products/Debug/Groovelight.app/Contents/MacOS/Groovelight
"$APP" -GLDebugLibraryPath /path/to/music         # add a library folder without the open panel
"$APP" -GLDebugResetPreferences YES                # start from clean preferences (unsandboxed debug build only)
"$APP" -GLDebugTour /tmp/tour -GLDebugTourPersist set     # change equalizer, volume, queue and theme, quit; then `check` reports them
"$APP" -GLDebugTour /tmp/tour -ApplePersistenceIgnoreState YES   # walk all screens, save PNG snapshots
"$APP" -GLDebugTour /tmp/tour -GLDebugTourMetadata YES   # Fix Metadata + lyrics on the library's "Untagged" folder
"$APP" -GLDebugTour /tmp/tour -GLDebugTourArtistLink YES # click an album page's artist name
"$APP" -GLDebugTour /tmp/tour -GLDebugTourTrackMenu YES  # open the songs' "⋯" menus, use "Go to Album"
"$APP" -GLDebugTour /tmp/tour -GLDebugTourNowPlayingLinks YES  # click the artist and album links in Now Playing
"$APP" -GLDebugTour /tmp/tour -GLDebugTourSmartPlaylist YES  # smart playlist editor, page, edit and live update
"$APP" -GLDebugTour /tmp/tour -GLDebugTourPlaylists YES      # All Playlists grid, card click, Loved Songs
"$APP" -GLDebugTour /tmp/tour -GLDebugTourCovers YES         # playlist covers, titles and the Edit Playlist sheet
"$APP" -GLDebugTour /tmp/tour -GLDebugTourQueueMenus YES     # Play Next / Add to Up Next from album and playlist menus
"$APP" -GLDebugTour /tmp/tour -GLDebugTourFullScreenNowPlaying YES  # open and close Now Playing in full screen
"$APP" -GLDebugTour /tmp/tour -GLDebugTourLyricsPanel YES    # lyrics side panel (needs network) and Now Playing scaling
"$APP" -GLDebugTour /tmp/tour -GLDebugTourGetInfo YES        # Get Info editor for a song and a whole album
"$APP" -GLDebugTour /tmp/tour -GLDebugTourCredits YES        # album credits and Wikipedia background (needs network)
"$APP" -GLDebugTour /tmp/tour -GLDebugTourLibraryJob YES     # Fetch Missing Info over the whole library (needs network)
"$APP" -GLDebugTour /tmp/tour -GLDebugTourBackup YES         # backup, restore, relinking folders, automatic backups (~4 min)
"$APP" -GLDebugTour /tmp/tour -GLDebugLibraryPath "$L" -GLDebugSyncFolder "$L" -GLDebugTourSync live   # live folder changes ($L: a scratch library with a Source/ album); quits
"$APP" -GLDebugTour /tmp/tour -GLDebugSyncFolder "$L" -GLDebugTourSync check   # after changing $L while closed: caught up from the event history
"$APP" -GLDebugTour /tmp/tour -GLDebugSyncFolder "$L" -GLDebugSyncImage vol.dmg -GLDebugTourSync volume   # drive unplugged and plugged back (image of a volume "GLSyncTest" with Music/Source/*.flac)
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold artist [-GLDebugArtist Name]   # opens an artist page and writes the window frame to WINDOW (then: screencapture -R$(cat /tmp/tour/WINDOW) out.png)
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold hover [-GLDebugArtist Name]   # artist page held up 12 s; writes TOOLBAR and POINTS (song rows) for a pointer-moving script (needs Accessibility for the terminal)
"$APP" -GLDebugTour /tmp/tour -GLDebugTourPlayback YES   # crossfade, speed, sleep timer (end of song, minutes) and loudness measuring on the library
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold playback   # Settings, Playback with crossfade, Sound Check, speed and a sleep timer on (writes WINDOW)
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold bitperfect -GLDebugAlbum "Name"   # bit-perfect on, plays the album, writes BITPERFECT (device vs file) and WINDOW; turns it back off
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold readme -GLDebugDevice "FIIO M11"   # stages the README screenshots: SHOT-n names and WINDOWID-n windows for screencapture -l (see below)
"$APP" -GLDebugDataDir /path/to/folder           # use another library folder (database and artwork), e.g. the performance library
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold perf -GLDebugDataDir /tmp/perf   # how long each page blocks the main thread (PERF)
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold songs-sort -GLDebugDataDir /tmp/perf   # sorts the Songs table by each column: when the list arrived and the longest main thread block (SORT)
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold songs-scroll -GLDebugDataDir /tmp/perf [-GLDebugScrollStep 250]   # flings the Songs table and times each frame (SCROLL)
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold devices-settings   # Settings, Devices in a window (WINDOW, WINDOWID)
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold library-settings   # Settings, Library (music folders) in a window (WINDOW, WINDOWID)
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold lastfm   # Settings, Last.fm in a window (writes WINDOW for screencapture -R)
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold playlist-files   # exports a playlist in every format, imports each back (PLAYLISTS), then leaves an import report open (WINDOW, READY); deletes what it made
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold lyrics   # synced lyrics in the side panel and Now Playing, at the start and at 1:00 (WINDOW, WINDOWID for screencapture -l, READY-0 to READY-3); temporary lyrics are put back
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold devices -GLDebugDevice GLCARD   # sync, re-sync, removal, send and eject on a mounted drive (make one: hdiutil create -size 200m -fs "MS-DOS FAT32" -volname GLCARD card.dmg; hdiutil attach card.dmg, not -nobrowse); writes DEVICES, WINDOWID, READY-n
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold wireless -GLDebugAutoPair YES   # wireless sync on, pairing allowed at once (first 3 albums selected), PORT written; up for -GLDebugSeconds (120) or until a STOP file; then WIRELESS, unpairs, turns it off. Pair with android/ MacIntegrationTest
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold empty-playlist-panel   # empty playlists and Loved Songs with the lyrics and Up Next panels at several widths (PANELS; a layout loop crashes); -GLDebugPanelsAllPages YES for every page
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold sidebar-covers   # playlists with each kind of cover for the sidebar icons (WINDOWID, READY); deleted after
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold min-artists   # minimum window with the lyrics panel open, then Artists, Genres, Albums (WINDOWID, READY-n, LAYOUT with the split view column widths; -GLDebugWindowWidth to try others)
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold min-window   # album and artist pages from the minimum window width up, and with Up Next open (MINWINDOW; a layout loop crashes)
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold empty-playlist   # a new empty playlist for 8 s (WINDOW, READY), then deleted
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold covers   # Albums at three cover sizes and the Shelf at two (writes WINDOW, SIZE-n and SHELF-n for screencapture -R) and the cover size menu items
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold now-playing # plays and leaves Now Playing open, for a real screen capture (the tour snapshots do not render Liquid Glass)
"$APP" -GLDebugTour /tmp/tour -GLDebugTourShortcuts YES    # menu shortcuts (flags duplicates), key presses, remapping in Settings (launch with `open` so ⌘F focus can be checked)
"$APP" -GLDebugTour /tmp/tour -GLDebugTourSearch YES       # Search page: sidebar link, results by category, toolbar field
"$APP" -GLDebugTour /tmp/tour -GLDebugTourMiniPlayer YES   # menu bar panel (in a test window) and the menu bar note
"$APP" -GLDebugTour /tmp/tour -GLDebugTourCue YES          # cue album songs, playback ranges and the move to the next song
"$APP" -GLDebugTour /tmp/tour -GLDebugTourFiles YES -GLDebugImportInbox /path/to/inbox   # organize, import, undo (use a scratch library copy)
```

Do not clear debug preferences with `defaults delete dev.irwingbraga.groovelight`: the `defaults` tool resolves the
bundle id to the installed (sandboxed) app's container and wipes its settings. Use `-GLDebugResetPreferences YES`.

`GL_SNAPSHOT_DIR=/tmp/viz swift test --filter Visualizer` writes offscreen renders of every visualizer.

README screenshots: mount a scratch card (`hdiutil create -size 512m -fs "MS-DOS FAT32" -volname "FIIO M11" card.dmg && hdiutil attach card.dmg`), run the `readme` tour, and capture each `SHOT-n` with `screencapture -x -o -l$(cat WINDOWID-n) docs/screenshots/$(cat SHOT-n).png` (then `sips -Z 1800`). Only Groovelight's windows are captured.
