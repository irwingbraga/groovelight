# Developing Groovelight

Requirements: Xcode 26+ (developed with Xcode 27), [XcodeGen](https://github.com/yonaskolb/XcodeGen). The app runs on macOS 15 and later: Liquid Glass is used on macOS 26, and `App/Sources/Support/Glass.swift` falls back to blur materials and bordered buttons before that. Use its wrappers (`glassBackground(in:)`, `glassButtonStyle()`, `glassProminentButtonStyle()`, `clearGlassButtonStyle()`, `GlassGroup`) instead of the glass APIs directly, and guard other macOS 26 APIs with `#available`. The Android companion app has its own guide in [`android/README.md`](../android/README.md).

## Layout

- `GroovelightKit/`: Swift package shared with the future iOS app
  - `PlayerCore`: SFBAudioEngine playback, gapless queue, 15-band `AVAudioUnitEQ` (with `EqualizerStore`, its saved presets, shared by the Mac and iOS), `SleepTimer`, FFT spectrum analyzer
  - `LibraryKit`: GRDB (SQLite + FTS5) library, tag reader, artwork cache, folder scanner and watcher; device sync plans, and `FormatConverter` (lossless FLAC for players that cannot decode a format, one file per song of a CUE album, and `LossyEncoding`: Opus 160, AAC 192 or MP3 320 for devices set to it)
  - `Visualizers`: Metal visualizers (Bars & Waves, Lights, Ambience, Magnetosphere), shaders compiled at runtime
  - `MetadataKit`: MusicBrainz, Cover Art Archive, iTunes Search and LRCLIB clients, release matching, LRC parser
  - `Scrobbler`: Last.fm client (desktop auth, now playing, scrobbles, loves) and the sender of the offline queue
  - `WirelessSync`: wireless sync with the Android and iOS apps: protocol (X25519 pairing, signed requests; v2 adds HTTPS with a certificate the device pins from a proof made with the pairing key, download tokens, per-file SHA-256, the library snapshot for Player mode with credits, playlist covers and the equalizer's presets, the whole library's catalog and the device's requests for albums, artists and songs, and `GET`/`POST /remote`: the Mac's player for a device allowed to control it, the state held until it changes, as `RemoteState` and `RemoteCommand`; with `?device=<id>` another device's player, relayed: a device that can be played on waits on `GET /relay` for `RelayedCommand`s and reports its player with `POST /relay/state`, and `GET /remote/devices` lists those there now, for devices allowed to control playback), local HTTP/HTTPS server with Bonjour, `TLSIdentity` (self-signed certificate in the login keychain), and away from home (`AwayNetwork`): a request is from home when it comes from the network of one of the Mac's own connections (not Tailscale or another VPN); away, pairing is refused and only devices allowed on their device page ("Let ... connect away from home", `PairedDevice.connectsAway`) get answers, and `/info` gives the Mac's Tailscale addresses (`awayAddresses`) for devices to try when the Mac is not on their network
  - `WirelessSyncClient`: the device's side of wireless sync, for Groovelight for iOS (builds on macOS too, so `CompanionSyncTests` run it against the server in-process): Bonjour browsing, pairing, the pinned HTTPS client, a player sync into a folder with the snapshot imported into a `LibraryDatabase`, and `FileDownloads`, which downloads the songs through a `URLSession` (the app's is a background one, so songs keep coming while the app is away) and records each in the manifest as it arrives; a cut download resumes with the Mac's ETag (`If-Range`). `PairedMac.connect` tries the Mac's address at home, then Bonjour, then its Tailscale addresses (`awayHosts`, from `/info`), straight to the pinned HTTPS port there (`tlsPort`); `MacClient.isAway` says which. The iOS app sets `NSAllowsArbitraryLoads`: App Transport Security counts Tailscale addresses as not local, and refuses the Mac's own certificate there; the app talks only to the Mac, pinning and signing itself
  - `ControlKit`: the command line tool talking to the app: requests and replies (JSON), the client and the app's server,
    the MCP server, and `ImportPaths` (the places imports may not read from, checked by the tool and the app)
- `App/`: the macOS app (SwiftUI views, app model, Now Playing / media keys); `App/Sources/Control/ControlService.swift` runs the tool's commands
- `CLI/`: `groovelight`, the command line tool (swift-argument-parser), embedded in the app at `Contents/Helpers/groovelight`
- `android/`: Groovelight for Android, the Android 12+ companion: wireless sync and the player (Kotlin, Compose, Media3, Room, Glance; modules `sync`, `library`, `playback`, `app`; see `android/README.md`)
- `iOS/`: Groovelight for iPhone, iPad and iPhone Duo (SwiftUI, iOS 26.1+, in development; plan in Obsidian, "Groovelight for iOS and iPadOS - Implementation Plan"). The `Groovelight iOS` target in `project.yml` links `PlayerCore`, `LibraryKit`, `MetadataKit` (synced lyrics), `Visualizers`, `WirelessSync` and `WirelessSyncClient`, which build for iOS with the macOS-only parts (`OutputDevice`'s Core Audio side, `FolderWatcher`, `LibraryChanges`, `ArchiveExtractor`, `TLSIdentity`) behind `#if os(macOS)`; on iOS, `OutputDevice` is the audio session. It pairs and syncs as a player device (protocol v2, HTTPS with the pinned certificate): `WirelessSyncClient` finds the Mac (`MacBrowser`), pairs (`DevicePairing`), connects (`PairedMac.connect`) and syncs into the app's music folder (`CompanionSync`, with the songs downloaded in the background; a sync the app was ended in finishes at the next launch; Settings' "Sync Automatically on Wi-Fi", on by default, has `SyncStore.checkForSync` check the Mac when the app comes to the front and when iOS wakes it for its app refresh task, `dev.irwingbraga.groovelight.sync.check`, then sync when the Mac asks, has songs waiting, a sync was left unfinished or the last is over 6 hours old, as Android's automatic sync does; not on mobile data or in Low Data Mode, and only while charging when asked), and can play on the Mac or on another phone through it instead (`RemoteStore` follows the chosen player; `AppModel.choose` hands the queue over between any two; `RelayReceiver` lets other devices play here, Settings' "Let Other Devices Play Here"), and `LibraryDatabase.importSnapshot` fills the same database the Mac keeps, with the Mac's ids. Now Playing is laid out as the Mac's (its drifting cover backdrop, the cover shrinking while paused or the visualizer in its place, "artist — album" links, the thin scrubber, the volume, round glass buttons at the top for the visualizer, lyrics, options and close, pulled down to close as a sheet would be (a full-screen cover has no swipe of its own: a drag below the scrubber's, the volume's and the lists', the page showing behind through a clear presentation background); `SongLinks` and `AppModel.show` open the album or artist from it, from the player bar and from the mini player), with the Mac's synced lyrics, Up Next (edited here, shown for the music elsewhere), AirPlay, Play On, the quality badge with the audio details (the Mac's badges are also on album pages, `AlbumQualitySummary`, on song rows, beside the title in the mini player and the iPad's player bar, and for the Mac's songs not here from the catalog's codec, rate and bit depth, `DeviceCatalog.Song.audioSpec`), speed, the sleep timer, the equalizer (`EqualizerScreen`) and the visualizers (`VisualizerScreen`); the Shelf is the Mac's Cover Flow (`Shelf.swift`); playlists show the Mac's covers (`PlaylistCovers.swift`), and All Playlists is the Mac's grid of cards (`PlaylistList`: Loved Songs first, "Smart Playlist" in a smart one's line, Play and Shuffle on the cover under the pointer and in each card's menu, songs dropped on a card added); Artists (the list and the iPad's column) and Songs of 40 or more have the A to Z index on the side, as in Contacts (`SectionIndex`: runs of the sorted list as sections with `sectionIndexLabel`, the first letter without accents, "#" for the rest); search is the Mac's (`LibraryDatabase.search`); Settings has the equalizer, Sound Check and crossfade. What happens here goes to the Mac in a `HistoryJournal` (`WirelessSyncClient`, a file of `DeviceHistoryEvent`s with their own ids): plays and skips counted as the Mac counts them, loves, and playlist edits (made, added to, taken from, renamed, deleted here, applied at once with the Mac's own `applyDeviceHistory`; a playlist made here has a negative id until a snapshot brings the Mac's, `LibraryDatabase.sentPlaylistId`), sent before each sync, at launch and when the app leaves the screen; the Mac counts each once and scrobbles the plays. The Mac's whole library is in the Library itself, as on Android: with Downloaded off (`DownloadedToggle`, the download symbol in the toolbar, highlighted while on, kept between launches, off by default and turned off again on pairing, as on Android), Recently Added, Albums, Artists (Compilations first, as on the Mac), Songs and Genres show the Mac's music with this device's (`MacLibrary.swift`), a mark on each album and song for where it stands (`CatalogAvailability`: here, arriving, waiting for the Mac, leaving), what is here playing and what is not opening its page on the Mac (or, while the Mac plays, playing on the Mac, which has it all: `AppModel.playOnMac`, also behind Play and Shuffle on the Mac's album and artist pages); a song playing elsewhere that is not here gets its cover and its lyrics from the Mac (`CatalogStore.fetchLyrics`, `GET /catalog/lyrics/<id>`, HTTPS only: the library's lyrics, looked up online first when it has none, 404 when there are none) (add to this device in its format or another, keep, remove, change the format). `CatalogStore` holds `MacClient.catalog` (kept on the device and fetched again only when its version changed), its covers (fetched over one kept connection, decoded covers kept in memory by hash), and the `requests` made here, kept in Requests.json until the Mac takes them (the marks show them at once, `DeviceCatalog.Chosen.applying`, and a notice says when the Mac is away). Layouts follow the window, never the device, and match the Mac: where the width is regular (iPad, the iPhone Duo's inner display) the Mac's sidebar (`LibrarySidebar`: Search, Library, Explore, Playlists, with the Mac's symbols) beside the page and the Mac's floating player bar (`PlayerBar`, over the split view at the page column's frame: pages pushed in the detail column are hosted by the split view, outside the column's stack and its modifiers; lists get room under it through `contentMargins`, and pages that place their own controls, such as the Shelf's scrubber, read its height from `playerBarInset`); Artists as on the Mac, with the artist list as a column of its own (`ArtistColumn`) and the bar spanning it and the page, and the Mac's artist page (`ArtistPage`: the photo beside the name, Play and Shuffle, then each album's cover beside its songs, stacked where the page is narrow; `ArtistDestination` picks it where the width is regular, the phone's pages where it is compact); where it is compact, tabs (Library, Shelf, Settings, Search) with the same places as a list and the mini player; standard containers, toolbar items with an icon and a title (iPhone Duo shows bars on the side), and the iPhone Duo APIs (`ArrangementView`, `ReservedRegion`) behind `#available(iOS 27.1, *)`. On the iPad: the Mac's Controls menu and page shortcuts in the menu bar and the Command key list (`PlayerCommands`, the Mac's default keys: Command-arrows for next and previous, Command-1 to 8 for the sidebar's pages, Command-F to search, Shift-Command-F for Now Playing), covers lifting under the pointer, songs and albums dragged onto a playlist or Loved Songs in the sidebar (`SongsTransfer`), each window with its own Now Playing, sheets and pages (`WindowModel`, in the environment and as a focused value; `AppModel.activeWindow` is the window in front), and the visualizer on an external display without Stage Manager (`ExternalDisplay.swift`: the app delegate holds the model, and a non-interactive external display scene shows `ExternalVisualizer`). Build for a simulator signed to run locally (the pairing key lives in the keychain, which an unsigned build cannot use): `xcodebuild -project Groovelight.xcodeproj -scheme "Groovelight iOS" -destination 'platform=iOS Simulator,name=iPhone Duo' CODE_SIGN_IDENTITY=- build`. Debug launch arguments: `-GLDebugMacAddress 127.0.0.1:<port>` pairs with the Mac's `wireless` debug tour (run with `-GLDebugAutoPair YES -GLDebugSyncEverything YES`), `-GLDebugSync YES` syncs at launch, `-GLDebugPlay YES` plays the first album, `-GLDebugHandOff <seconds>` moves playback to the Mac (or with `-GLDebugHandOffTo <name>` to that device) after that long and back after as long again (the Mac's tour run with `-GLDebugAllowRemote YES`), `-GLDebugOpenPicker YES` opens the Play On list, `-GLDebugNowPlaying YES` shows a sample song (with synced lyrics), `-GLDebugOpenNowPlaying YES` opens Now Playing (`-GLDebugNowPlayingPull <points>` pulled down that far, `-GLDebugNowPlayingPanel lyrics|upNext` on that panel, `-GLDebugOpenVisualizer YES` with the visualizer), `-GLDebugShelf YES` opens the Shelf, `-GLDebugPlayOnMac <album>` plays on the Mac, then that album of its library (here or not), `-GLDebugAway YES` acts as away from home (the Mac's home address unreachable and Bonjour finding nothing, so only its Tailscale address answers), `-GLDebugShowMac YES` turns Downloaded off for that launch, `-GLDebugSection recentlyAdded|artists|songs|genres` opens that place (where there is a sidebar), `-GLDebugOpenAlbum <title>` opens that album's page (here, or on the Mac), `-GLDebugOpenGenre <name>` that genre's, `-GLDebugOpenSection allPlaylists|lovedSongs|<a Library place>` that place, `-GLDebugPlayDelay <seconds>` delays `-GLDebugPlay`, `-GLDebugOpenPlaying album|artist` follows Now Playing's link 3 seconds after playing starts, `-GLDebugPlaylistEdits YES` makes and edits a playlist then syncs, `-GLDebugCatalogRequest remove:<album>` or `add:<album>[:<format>]` asks the Mac for an album, and `-GLDebugOpenSettings YES` (with `-GLDebugOpenEqualizer YES`) opens Settings, and `-GLDebugIndexMinimum <count>` shows the A to Z index on lists that short, for layout checks
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

### Command line tool

User documentation: [CLI.md](CLI.md) (commands) and [MCP.md](MCP.md) (Claude and AI tools). This section is how
it works inside.

`groovelight` never opens the library itself: it sends requests to the running app, so there is one writer and the
windows stay in step. How it reaches the sandboxed app:

- **Requests:** JSON in Mach messages (`CFMessagePort`) on a port named after the App Group,
  `MHW58UT524.dev.irwingbraga.groovelight.control`. A sandboxed app may only publish names that start with one of its
  App Groups (the `com.apple.security.application-groups` entitlement). Debug builds use `….control-debug`, so they run
  beside the installed app; `GROOVELIGHT_PORT` overrides both. A fork signed by another team changes the group and
  `ControlPort.appGroup` together.
- **Jobs:** quick commands answer at once. Imports, fixes, organize and rescans reply with a job id that the tool
  polls (`.poll`) for progress lines and the result, so no message waits long. One job runs at a time.
- **File access:** the sandboxed app cannot read paths it is sent. `import` first tells the app which paths are coming
  (`.expectFiles`), then opens them with the app through Launch Services, which grants a sandbox extension as Finder's
  Open With does (the app declares music, folders, archives and cue sheets as `Alternate` document types). The app
  takes announced files silently (`ControlService.open`); other opened files (Open With, the Dock icon) start the usual
  import sheet.
- **Results:** every reply has a `summary` for people and `data` (JSON) for `--json`, scripts and AI tools.
- **MCP:** `groovelight mcp` serves the same requests to AI tools (Model Context Protocol, newline-delimited
  JSON-RPC on stdin and stdout; `ControlKit/MCPServer.swift`, tested without the app in `MCPServerTests`). Tools that
  change files come in pairs: `preview_import`, `preview_fix_metadata` and `preview_organize` return a `preview_id`,
  and `import_music`, `apply_fix_metadata` and `organize_files` take only that id, running exactly what was previewed
  (the fix applies the previewed release). Tool results carry the summary as text and the data as
  `structuredContent`; job progress goes out as `notifications/progress` when the client sends a progress token.
- **Claude Desktop extension:** `extension/` holds the manifest and a launcher script that runs the installed app's
  `groovelight mcp` (so the extension always matches the app and carries no binary of its own). Its "Groovelight app"
  setting points it at another copy, such as a build from Xcode. `scripts/make-mcpb.sh path/to/Groovelight.app` packs
  `Groovelight-<version>.mcpb` (version from the app, icon from its `Groovelight.icns`); the release workflow attaches
  it to each release. `MCPServerTests` checks the manifest lists the server's tools.

Try it against a scratch library with a debug build (the tool inside it talks to the debug port):

```sh
APP=build/DebugUnsandboxed/Build/Products/Debug/Groovelight.app
"$APP/Contents/MacOS/Groovelight" -GLDebugDataDir /tmp/cli-data -GLDebugLibraryPath /tmp/cli-library &
"$APP/Contents/Helpers/groovelight" import ~/Music/some-album.zip --dry-run
```

To test the sandbox, sign a Debug copy under another bundle id with the Developer ID and the app's entitlements:
its keychain items and container are its own (`Keychain` adds the bundle id to the service of such copies), and
`-GLDebugLibraryPath` can point inside its container (it is created when missing).

### Testing on macOS 15

A macOS 15 virtual machine with [Tart](https://tart.run) (Apple Silicon; the image is about 30 GB):

```sh
tart clone ghcr.io/cirruslabs/macos-sequoia-base:latest sequoia
tart run sequoia --dir="share:$PWD/build"      # user and password: admin; the folder is in /Volumes/My Shared Files/share
```

Copy a Debug build into the shared folder and open it in the VM; the debug tours below work there too (`tart exec sequoia <command>` runs a command in the VM, and `screencapture -l` works inside it).

## Releases

`.github/workflows/release.yml` runs on version tags (`git tag v0.2.0 && git push --tags`) or by hand from the Actions tab. It tests the package, builds a Release DMG with `scripts/make-dmg.sh`, signs and notarizes it when the Developer ID secrets are set, writes the Sparkle update feed (`appcast.xml`, signed with `SPARKLE_PRIVATE_KEY`), builds Groovelight for Android with the player (`-Pplayer=true`, signed with the release keystore secrets; the APK is `Groovelight-<version>.apk`, which the Android app's update check looks for) and attaches the DMG, the feed and the APK to a GitHub Release. The release notes come from `docs/releases/<tag>.md` (for example `docs/releases/v0.2.2.md`) when that file exists, otherwise GitHub lists the changes. The app reads the feed from the latest release (`SUFeedURL` in `project.yml`); the public half of the update key is `SUPublicEDKey`.

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
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold general-settings   # Settings, General (appearance, updates, command line) in a window
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold lastfm   # Settings, Last.fm in a window (writes WINDOW for screencapture -R)
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold playlist-files   # exports a playlist in every format, imports each back (PLAYLISTS), then leaves an import report open (WINDOW, READY); deletes what it made
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold lyrics   # synced lyrics in the side panel and Now Playing, at the start and at 1:00 (WINDOW, WINDOWID for screencapture -l, READY-0 to READY-3); temporary lyrics are put back
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold devices -GLDebugDevice GLCARD   # sync, re-sync, removal, send and eject on a mounted drive (make one: hdiutil create -size 200m -fs "MS-DOS FAT32" -volname GLCARD card.dmg; hdiutil attach card.dmg, not -nobrowse); writes DEVICES, WINDOWID, READY-n
"$APP" -GLDebugTour /tmp/tour -GLDebugTourHold wireless -GLDebugAutoPair YES [-GLDebugSyncEverything YES] [-GLDebugEncoding opus160]   # wireless sync on, pairing allowed at once (first 3 albums selected, or the whole library; every device in that lossy format), PORT written; up for -GLDebugSeconds (120) or until a STOP file; then WIRELESS, unpairs, turns it off. Pair with android/ MacIntegrationTest. `-GLDebugDropOnDevice YES` drops the 4th album and the 5th's first song on the device 10 seconds after pairing, as dragged onto it in the sidebar (`DeviceStore.add`). `-GLDebugAllowAway YES` allows each paired device away from home (with Tailscale on, the iOS app's `-GLDebugAway YES` then reaches it only at its Tailscale address)
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
"$APP" -GLDebugTour /tmp/tour -GLDebugTourFiles YES -GLDebugImportInbox /path/to/inbox   # organize, import, undo (use a scratch library copy; the inbox can be an archive)
```

Do not clear debug preferences with `defaults delete dev.irwingbraga.groovelight`: the `defaults` tool resolves the
bundle id to the installed (sandboxed) app's container and wipes its settings. Use `-GLDebugResetPreferences YES`.

`GL_SNAPSHOT_DIR=/tmp/viz swift test --filter Visualizer` writes offscreen renders of every visualizer.

README screenshots: mount a scratch card (`hdiutil create -size 512m -fs "MS-DOS FAT32" -volname "FIIO M11" card.dmg && hdiutil attach card.dmg`), run the `readme` tour, and capture each `SHOT-n` with `screencapture -x -o -l$(cat WINDOWID-n) docs/screenshots/$(cat SHOT-n).png` (then `sips -Z 1800`). Only Groovelight's windows are captured.
