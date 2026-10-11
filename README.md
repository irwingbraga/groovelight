# Groovelight

Native macOS music library manager and player (SwiftUI, Liquid Glass) with iTunes-era nostalgia: Cover Flow shelf, Metal visualizers and a 15-band parametric EQ.

Requirements: macOS 26+, Xcode 26+ (developed with Xcode 27), [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Layout

- `GroovelightKit/`: Swift package shared with the future iOS app
  - `PlayerCore`: SFBAudioEngine playback, gapless queue, 15-band `AVAudioUnitEQ`, FFT spectrum analyzer
  - `LibraryKit`: GRDB (SQLite + FTS5) library, tag reader, artwork cache, folder scanner and watcher
  - `Visualizers`: Metal visualizers (Bars & Waves, Lights, Ambience, Magnetosphere), shaders compiled at runtime
  - `MetadataKit`: MusicBrainz, Cover Art Archive, iTunes Search and LRCLIB clients, release matching, LRC parser
- `App/`: the macOS app (SwiftUI views, app model, Now Playing / media keys)
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
"$APP" -GLDebugTour /tmp/tour -GLDebugTourMiniPlayer YES   # menu bar panel (in a test window) and the menu bar note
"$APP" -GLDebugTour /tmp/tour -GLDebugTourCue YES          # cue album songs, playback ranges and the move to the next song
"$APP" -GLDebugTour /tmp/tour -GLDebugTourFiles YES -GLDebugImportInbox /path/to/inbox   # organize, import, undo (use a scratch library copy)
```

Do not clear debug preferences with `defaults delete dev.irwingbraga.groovelight`: the `defaults` tool resolves the
bundle id to the installed (sandboxed) app's container and wipes its settings. Use `-GLDebugResetPreferences YES`.

`GL_SNAPSHOT_DIR=/tmp/viz swift test --filter Visualizer` writes offscreen renders of every visualizer.
