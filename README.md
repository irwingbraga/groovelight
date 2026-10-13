# Groovelight

Native macOS music library manager and player (SwiftUI, Liquid Glass) with iTunes-era nostalgia: Cover Flow shelf, Metal visualizers and a 15-band parametric EQ.

Requirements: macOS 26+, Xcode 26+ (developed with Xcode 27), [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Layout

- `GroovelightKit/`: Swift package shared with the future iOS app
  - `PlayerCore`: SFBAudioEngine playback, gapless queue, 15-band `AVAudioUnitEQ`, FFT spectrum analyzer
  - `LibraryKit`: GRDB (SQLite + FTS5) library, tag reader, artwork cache, folder scanner and watcher
  - `Visualizers`: Metal visualizers (Bars & Waves, Lights, Ambience, Magnetosphere), shaders compiled at runtime
  - `MetadataKit`: MusicBrainz, Cover Art Archive, iTunes Search and LRCLIB clients, release matching, LRC parser
  - `Scrobbler`: Last.fm client (desktop auth, now playing, scrobbles, loves) and the sender of the offline queue
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

## Keyboard shortcuts

The defaults are below. Every shortcut is also in the menus, and each one can be changed, removed or reset in Settings, Shortcuts (keys already used by another command or by macOS are refused). On non-US keyboards macOS may move some default keys (Back shows as ⌘Ç on a Portuguese layout); recorded shortcuts keep the exact keys pressed.

| Action | Shortcut |
|---|---|
| Play / Pause | Space (outside text fields), ⌥⌘P |
| Next / Previous | ⌘→ / ⌘← |
| Skip forward / back 10 seconds | ⌥⌘→ / ⌥⌘← |
| Volume up / down, Mute | ⌘↑ / ⌘↓, ⌥⌘↓ |
| Shuffle, cycle Repeat (off, all, one) | ⌘S, ⌘R |
| Love the current song, Go to Current Song | ⇧⌘L, ⌘L |
| Search Library | ⌘F |
| Recently Added, Artists, Albums, Songs, Genres, Shelf, All Playlists, Loved Songs | ⌘1 to ⌘8 |
| Back | ⌘[ |
| Now Playing (Esc closes it), Lyrics, Up Next | ⇧⌘F, ⌥⌘L, ⌥⌘U |
| Visualizer, Equalizer | ⌘T, ⌥⌘E |
| Bigger / Smaller covers (Albums page; also its toolbar slider and pinching) | ⌘+ / ⌘− |
| Library window (a single window; reopens it after closing) | ⌘0 |
| New Playlist, New Smart Playlist | ⌘N, ⌥⌘N |
| Import (songs or folders), Add Folder to Library | ⌘O, ⇧⌘O |
| Fetch Missing Info in Background, Back Up Library | ⇧⌘U, ⌥⌘B |
| Settings | ⌘, |

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
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold lastfm   # Settings, Last.fm in a window (writes WINDOW for screencapture -R)
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold covers   # Albums at three cover sizes (writes WINDOW and SIZE-n for screencapture -R) and the cover size menu items
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
