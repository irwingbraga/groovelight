#if DEBUG
import AppKit
import LibraryKit
import MetadataKit
import PlayerCore
import SwiftUI

/// Debug-only visual check: `-GLDebugTour /output/dir` walks through the main screens, starts playback and saves a PNG of
/// every app window at each step (rendered by the app itself, so no screen recording permission is needed).
@MainActor
enum DebugTour {
    static func runIfRequested(model: AppModel, openWindow: OpenWindowAction) {
        guard let path = UserDefaults.standard.string(forKey: "GLDebugTour") else { return }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        Task {
            // `-GLDebugTourMetadata YES` only runs the online metadata test (needs the "Untagged" fixture folder).
            if UserDefaults.standard.bool(forKey: "GLDebugTourMetadata") {
                await metadataTest(model: model, output: output)
                try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                return
            }
            // `-GLDebugTourTrackMenu YES` only tests the songs' "⋯" menus.
            if UserDefaults.standard.bool(forKey: "GLDebugTourTrackMenu") {
                await trackMenuTest(model: model, output: output)
                try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                return
            }
            // `-GLDebugTourNowPlayingLinks YES` only clicks the artist and album links in Now Playing.
            if UserDefaults.standard.bool(forKey: "GLDebugTourNowPlayingLinks") {
                await nowPlayingLinksTest(model: model, output: output)
                try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                return
            }
            // `-GLDebugTourPersist set|check` changes the equalizer and volume and quits, then reports them on the next launch.
            if let phase = UserDefaults.standard.string(forKey: "GLDebugTourPersist") {
                try? await Task.sleep(for: .seconds(2))
                let eq = model.equalizer
                let player = model.player
                if phase == "set" {
                    eq.select(EQPreset.builtIns.first { $0.name != "Flat" } ?? .flat)
                    eq.updateBand(3) { $0.gain = 4.5 }
                    eq.isEnabled = true
                    player.volume = 0.37
                    // A queue: an album from its second song, 20 s in, plus a song from another album played next.
                    let albums = (try? await model.database.writer.read { try LibraryDatabase.albums($0) }) ?? []
                    let first = (try? await model.database.writer.read { try LibraryDatabase.tracks($0, albumKey: albums[0].albumKey) }) ?? []
                    let other = (try? await model.database.writer.read { try LibraryDatabase.tracks($0, albumKey: albums[1].albumKey) }) ?? []
                    model.play(first, startAt: 1)
                    try? await Task.sleep(for: .seconds(1))
                    player.seek(to: 20)
                    player.playNext([model.playableItem(for: other[0])])
                    player.repeatMode = .all
                    try? await Task.sleep(for: .seconds(1))
                    UserDefaults.standard.set(AppTheme.dark.rawValue, forKey: AppTheme.key)
                    model.saveQueue()
                }
                let queue = player.queue
                var report = "phase \(phase): eq '\(eq.preset.name)' on \(eq.isEnabled), band 4 gain \(eq.preset.bands[3].gain), engine eq on \(model.player.equalizerEnabled) '\(model.player.equalizerPreset.name)', volume \(model.player.volume)"
                report += "\nqueue: current '\(queue.current?.title ?? "-")' (#\(queue.currentIndex ?? -1) of \(queue.items.count)), next '\(queue.upcoming.first?.title ?? "-")', repeat \(queue.repeatMode), state \(player.state), time \(String(format: "%.0f", player.currentTime))"
                report += "\ntheme \(AppTheme.current.rawValue), app appearance \(NSApp.appearance?.name.rawValue ?? "system")"
                if phase == "check" {
                    model.isShowingNowPlaying = true
                    try? await Task.sleep(for: .seconds(1.5))
                    await snapshot("170-now-playing-restored", output)
                    // Seeking before Play moves where the restored song starts.
                    player.seek(to: 6)
                    report += "\nseek to 6 before Play: time \(String(format: "%.1f", player.currentTime)), duration \(String(format: "%.1f", player.duration))"
                    player.togglePlayPause()
                    try? await Task.sleep(for: .seconds(2))
                    report += "\nafter Play: '\(player.current?.title ?? "-")' \(player.state) at \(String(format: "%.1f", player.currentTime))"
                    player.togglePlayPause()
                }
                try? report.write(to: output.appendingPathComponent("PERSIST-\(phase)"), atomically: true, encoding: .utf8)
                try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                if phase == "set" { NSApp.terminate(nil) }
                return
            }
            // `-GLDebugTourShortcuts YES` lists the menu shortcuts (flagging duplicates) and presses a few of them.
            if UserDefaults.standard.bool(forKey: "GLDebugTourShortcuts") {
                await shortcutsTest(model: model, output: output)
                try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                return
            }
            // `-GLDebugTourHold now-playing` opens Now Playing while a song plays and leaves it up (for a real screen capture).
            if UserDefaults.standard.string(forKey: "GLDebugTourHold") == "now-playing" {
                try? await Task.sleep(for: .seconds(2))
                let tracks: [Track] = (try? await model.database.writer.read { db in
                    try LibraryKitQueries.firstAlbum(db).map { try LibraryKitQueries.tracks(db, albumKey: $0) } ?? []
                }) ?? []
                model.play(tracks)
                model.isShowingNowPlaying = true
                try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                return
            }
            // `-GLDebugTourSync live|check` tests keeping the library in step with `-GLDebugSyncFolder` (a scratch copy):
            // live changes, then (check, after the folder changed while the app was closed) catching up at launch.
            if let phase = UserDefaults.standard.string(forKey: "GLDebugTourSync") {
                await syncTest(model: model, phase: phase, output: output)
                try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                if phase != "check" { NSApp.terminate(nil) }
                return
            }
            // `-GLDebugTourHold artist` opens Radiohead's page and leaves it up, writing the window's frame (top-left
            // screen points) to WINDOW for a real screen capture of just the window (snapshots miss the color wash).
            if UserDefaults.standard.string(forKey: "GLDebugTourHold") == "artist" {
                try? await Task.sleep(for: .seconds(2))
                NSApp.activate()
                model.showArtist(UserDefaults.standard.string(forKey: "GLDebugArtist") ?? "Radiohead")
                try? await Task.sleep(for: .seconds(3))
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }), let screen = window.screen {
                    let frame = window.frame
                    let top = screen.frame.maxY - frame.maxY
                    try? "\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))".write(to: output.appendingPathComponent("WINDOW"), atomically: true, encoding: .utf8)
                }
                try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                return
            }
            // `-GLDebugTourHold covers` shows Albums at three cover sizes, writing WINDOW and SIZE-n files so a script
            // can capture each (screencapture -R), and reports the cover size menu items.
            if UserDefaults.standard.string(forKey: "GLDebugTourHold") == "covers" {
                try? await Task.sleep(for: .seconds(2))
                NSApp.activate()
                model.selection = .albums
                var lines: [String] = []
                @MainActor func items() -> String {
                    NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] }
                        .filter { $0.title.contains("Covers") || $0.title.contains("Cover Size") }
                        .map { "\($0.title) key '\($0.keyEquivalent)' enabled \($0.isEnabled)" }.joined(separator: "; ") ?? ""
                }
                try? await Task.sleep(for: .seconds(1))
                NSApp.mainMenu?.update()
                lines.append("on Albums: \(items())")
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }), let screen = window.screen {
                    let frame = window.frame
                    try? "\(Int(frame.minX)),\(Int(screen.frame.maxY - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
                        .write(to: output.appendingPathComponent("WINDOW"), atomically: true, encoding: .utf8)
                }
                for (index, size) in [110.0, 180, 380].enumerated() {
                    UserDefaults.standard.set(size, forKey: CoverSize.key)
                    try? await Task.sleep(for: .seconds(2.5))
                    try? "\(size)".write(to: output.appendingPathComponent("SIZE-\(index)"), atomically: true, encoding: .utf8)
                    try? await Task.sleep(for: .seconds(2))
                }
                CoverSize.change(by: -1)
                lines.append("Smaller from 380: \(UserDefaults.standard.double(forKey: CoverSize.key))")
                CoverSize.reset()
                lines.append("Default: \(UserDefaults.standard.object(forKey: CoverSize.key) == nil ? "standard" : "set")")
                model.selection = .artists
                try? await Task.sleep(for: .seconds(1))
                NSApp.mainMenu?.update()
                lines.append("on Artists: \(items())")
                try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("COVERS"), atomically: true, encoding: .utf8)
                try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                return
            }
            // `-GLDebugTourHold hover` opens an artist page (`-GLDebugArtist`; `-GLDebugArtistAlone YES` as opened from search,
            // `-GLDebugPage genres` for Genres; `-GLDebugWindowWidth` resizes) and stays up for 12 s, writing the toolbar's
            // screen rectangle to TOOLBAR and its song rows' screen points to POINTS, for a script that moves the real
            // pointer (the terminal needs Accessibility access) to check the page while hovering and scrolling.
            if UserDefaults.standard.string(forKey: "GLDebugTourHold") == "hover" {
                try? await Task.sleep(for: .seconds(2))
                NSApp.activate()
                let name = UserDefaults.standard.string(forKey: "GLDebugArtist") ?? "Radiohead"
                if UserDefaults.standard.string(forKey: "GLDebugPage") == "genres" {
                    model.selection = .genres
                } else if UserDefaults.standard.bool(forKey: "GLDebugArtistAlone") {
                    // The artist page by itself (as opened from search): one scroll view under the toolbar.
                    model.selection = .search
                    model.path = [.artist(name)]
                } else {
                    model.showArtist(name)
                }
                try? await Task.sleep(for: .seconds(3))
                guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }),
                      let screen = window.screen else { return }
                // `-GLDebugWindowWidth N` resizes the window first (keeping its top left corner).
                let wanted = UserDefaults.standard.double(forKey: "GLDebugWindowWidth")
                if wanted > 0 {
                    var frame = window.frame
                    frame.size.width = wanted
                    window.setFrame(frame, display: true)
                    try? await Task.sleep(for: .seconds(1.5))
                }
                let top = screen.frame.maxY - window.frame.maxY
                try? "\(Int(window.frame.minX)),\(Int(top)),\(Int(window.frame.width)),52".write(to: output.appendingPathComponent("TOOLBAR"), atomically: true, encoding: .utf8)
                let cells = DebugHitTargets.playCells.values.filter { $0.minY > 60 }.sorted { $0.minY < $1.minY }
                // Screen points (top-left) of each row's middle, for a script to move the pointer over.
                let points = cells.map { "\(Int(window.frame.minX + $0.maxX + 250)) \(Int(top + $0.midY))" }.joined(separator: " ")
                try? points.write(to: output.appendingPathComponent("POINTS"), atomically: true, encoding: .utf8)
                try? await Task.sleep(for: .seconds(12))
                try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                return
            }
            // `-GLDebugTourSearch YES` only tests the Search page: the sidebar link, results by category and the toolbar field.
            if UserDefaults.standard.bool(forKey: "GLDebugTourSearch") {
                await searchTest(model: model, output: output)
                try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                return
            }
            // `-GLDebugTourMiniPlayer YES` renders the menu bar panel (in a test window) while a song plays, and the menu bar note.
            if UserDefaults.standard.bool(forKey: "GLDebugTourMiniPlayer") {
                await miniPlayerTest(model: model, output: output)
                try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                return
            }
            // `-GLDebugTourCue YES` only tests albums from cue sheets: their songs, playback ranges and the move between them.
            if UserDefaults.standard.bool(forKey: "GLDebugTourCue") {
                await cueTest(model: model, output: output)
                try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                return
            }
            // `-GLDebugTourFiles YES` only tests Organize Library Files and Import (with undo). Point it at a scratch copy.
            if UserDefaults.standard.bool(forKey: "GLDebugTourFiles") {
                await filesTest(model: model, output: output)
                try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                return
            }
            // `-GLDebugTourBackup YES` only tests backup, restore, relinking and automatic backups.
            if UserDefaults.standard.bool(forKey: "GLDebugTourBackup") {
                await backupTest(model: model, output: output)
                try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                return
            }
            // `-GLDebugTourLibraryJob YES` only tests "Fetch Missing Info" over the whole library (needs network).
            if UserDefaults.standard.bool(forKey: "GLDebugTourLibraryJob") {
                await libraryJobTest(model: model, output: output)
                try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                return
            }
            // `-GLDebugTourCredits YES` only tests album credits and the Wikipedia background (needs network).
            if UserDefaults.standard.bool(forKey: "GLDebugTourCredits") {
                await creditsTest(model: model, output: output)
                try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                return
            }
            // `-GLDebugTourGetInfo YES` only tests the Get Info editor.
            if UserDefaults.standard.bool(forKey: "GLDebugTourGetInfo") {
                await getInfoTest(model: model, output: output)
                try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                return
            }
            // `-GLDebugTourLyricsPanel YES` only tests lyrics in the side panel and Now Playing scaling.
            if UserDefaults.standard.bool(forKey: "GLDebugTourLyricsPanel") {
                await lyricsPanelTest(model: model, output: output)
                try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                return
            }
            // `-GLDebugTourFullScreenNowPlaying YES` only tests opening and closing Now Playing in full screen.
            if UserDefaults.standard.bool(forKey: "GLDebugTourFullScreenNowPlaying") {
                await fullScreenNowPlayingTest(model: model, output: output)
                try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                return
            }
            // `-GLDebugTourQueueMenus YES` only tests Play Next / Add to Up Next on albums and playlists.
            if UserDefaults.standard.bool(forKey: "GLDebugTourQueueMenus") {
                await queueMenusTest(model: model, output: output)
                try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                return
            }
            // `-GLDebugTourCovers YES` only tests playlist covers and the Edit Playlist sheet.
            if UserDefaults.standard.bool(forKey: "GLDebugTourCovers") {
                await coversTest(model: model, output: output)
                try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                return
            }
            // `-GLDebugTourPlaylists YES` only tests All Playlists and Loved Songs.
            if UserDefaults.standard.bool(forKey: "GLDebugTourPlaylists") {
                await playlistsTest(model: model, output: output)
                try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                return
            }
            // `-GLDebugTourSmartPlaylist YES` only tests smart playlists.
            if UserDefaults.standard.bool(forKey: "GLDebugTourSmartPlaylist") {
                await smartPlaylistTest(model: model, output: output)
                try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                return
            }
            // `-GLDebugTourArtistLink YES` only clicks the artist name on an album page.
            if UserDefaults.standard.bool(forKey: "GLDebugTourArtistLink") {
                await artistLinkTest(model: model, output: output)
                try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
                return
            }
            // `-GLDebugTourOpenFirst equalizer|visualizer` reproduces runs where those windows were restored at launch.
            if let window = UserDefaults.standard.string(forKey: "GLDebugTourOpenFirst") { openWindow(id: window) }
            try? await Task.sleep(for: .seconds(1))
            // `-GLDebugWindowSize 960x600` resizes the main window first (e.g. to its minimum size).
            if let size = UserDefaults.standard.string(forKey: "GLDebugWindowSize")?.split(separator: "x").compactMap({ Double($0) }),
               size.count == 2, let window = NSApp.windows.first(where: { $0.title != "Equalizer" && $0.title != "Visualizer" && $0.isVisible }) {
                window.setContentSize(NSSize(width: size[0], height: size[1]))
            }
            try? await Task.sleep(for: .seconds(2))
            await snapshot("01-albums", output)

            if let album = try? await model.database.writer.read({ try LibraryKitQueries.firstAlbum($0) }) {
                let tracks = try? await model.database.writer.read { try LibraryKitQueries.tracks($0, albumKey: album) }
                model.play(tracks ?? [])
            }
            try? await Task.sleep(for: .seconds(2))
            await snapshot("02-albums-playing", output)

            if let album = try? await model.database.writer.read({ try LibraryDatabase.albums($0).first }) {
                model.albumPath = [album]
                try? await Task.sleep(for: .seconds(1.5))
                await snapshot("02b-album-detail", output)
                model.albumPath = []
            }
            // Quality fixtures: uniform Hi-Res, mixed formats, uniform lossy.
            let albums = (try? await model.database.writer.read { try LibraryDatabase.albums($0) }) ?? []
            for title in ["Hi-Res Sessions", "Mixed Bag", "Three Twenty"] {
                guard let album = albums.first(where: { $0.title == title }) else { continue }
                // Navigate like the UI does: back to the root, then open the album.
                model.albumPath = []
                try? await Task.sleep(for: .seconds(1))
                model.albumPath = [album]
                try? await Task.sleep(for: .seconds(2.5))
                await snapshot("02c-quality-\(title.replacingOccurrences(of: " ", with: "_"))", output)
            }
            model.albumPath = []
            await clickTest(model: model, albums: albums, output: output)
            if let hiRes = albums.first(where: { $0.title == "Hi-Res Sessions" }) {
                model.playAlbum(hiRes)
                try? await Task.sleep(for: .seconds(1))
            }

            model.selection = .songs
            try? await Task.sleep(for: .seconds(1.5))
            await snapshot("03-songs", output)

            model.selection = UserDefaults.standard.bool(forKey: "GLDebugTourSongsToAlbums") ? .albums : .artists
            try? await Task.sleep(for: .seconds(1.5))
            await snapshot("04-artists", output)

            model.selection = .shelf
            try? await Task.sleep(for: .seconds(2))
            await snapshot("05-shelf", output)
            await shelfSliderTest(model: model, output: output)
            model.selection = .albums
            try? await Task.sleep(for: .seconds(1))
            await snapshot("05d-albums-after-shelf", output)

            if !UserDefaults.standard.bool(forKey: "GLDebugTourSkipNowPlaying") {
            model.isShowingNowPlaying = true
            try? await Task.sleep(for: .seconds(2))
            await snapshot("06-now-playing", output)
            model.isShowingLyrics = true
            try? await Task.sleep(for: .seconds(1))
            await snapshot("06b-now-playing-lyrics", output)
            model.isShowingLyrics = false
            model.isShowingNowPlaying = false
            }

            model.isShowingQueue = true
            model.selection = .albums
            try? await Task.sleep(for: .seconds(1.5))
            await snapshot("07-queue", output)
            model.isShowingQueue = false

            openWindow(id: WindowID.equalizer)
            model.equalizer.isEnabled = true
            if let preset = model.equalizer.allPresets.first(where: { $0.name == "Loudness" }) { model.equalizer.select(preset) }
            try? await Task.sleep(for: .seconds(2))
            await snapshot("08-equalizer", output)

            for (index, style) in ["barsAndWaves", "lights", "ambience", "magnetosphere"].enumerated() {
                UserDefaults.standard.set(style, forKey: "visualizer.style")
                openWindow.visualizer()
                try? await Task.sleep(for: .seconds(3))
                await snapshot("09-visualizer-\(index)-\(style)", output)
            }
            if let visualizer = NSApp.windows.first(where: { $0.title == "Visualizer" }) {
                // Launched from a terminal the app is not frontmost; full screen needs it active.
                NSApp.activate(ignoringOtherApps: true)
                visualizer.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(0.5))
                visualizer.toggleFullScreen(nil)
                try? await Task.sleep(for: .seconds(2.5))
                let entered = visualizer.styleMask.contains(.fullScreen)
                let windows = NSApp.windows.map { "\($0.title)|\(type(of: $0))|visible=\($0.isVisible)|mask=\($0.styleMask.rawValue)|behavior=\($0.collectionBehavior.rawValue)" }
                let info = "fullscreen=\(entered) primary=\(visualizer.collectionBehavior.contains(.fullScreenPrimary)) active=\(NSApp.isActive)\n" + windows.joined(separator: "\n")
                try? info.write(to: output.appendingPathComponent("FULLSCREEN"), atomically: true, encoding: .utf8)
                await snapshot("10-visualizer-fullscreen", output)
                visualizer.toggleFullScreen(nil)
                try? await Task.sleep(for: .seconds(2.5))
                let exited = !visualizer.styleMask.contains(.fullScreen)
                try? "exited=\(exited)".write(to: output.appendingPathComponent("EXITED"), atomically: true, encoding: .utf8)
            }
            try? "done".write(to: output.appendingPathComponent("DONE"), atomically: true, encoding: .utf8)
        }
    }

    /// Clicks the play cells of an album page with real mouse events (through the window, so SwiftUI hit testing and
    /// gesture priorities are exercised) and records whether playback followed.
    private static func clickTest(model: AppModel, albums: [AlbumSummary], output: URL) async {
        func fail(_ reason: String) {
            try? "skipped: \(reason)".write(to: output.appendingPathComponent("CLICKS"), atomically: true, encoding: .utf8)
        }
        guard let album = albums.first(where: { $0.title == "Hi-Res Sessions" }),
              let tracks = try? await model.database.writer.read({ try LibraryDatabase.tracks($0, albumKey: album.albumKey) }),
              tracks.count >= 3 else { return fail("fixture album missing") }
        model.player.stop()
        model.albumPath = [album]
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && $0.frame.width > 600 && !["Equalizer", "Visualizer"].contains($0.title)
        }) else { return fail("main window not found") }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(0.5))
        await snapshot("11-click-test-page", output)

        var results: [String] = ["path=\(model.albumPath.map(\.title)) windowTitle=\(window.title)"]
        func click(trackIndex: Int, dx: CGFloat, dy: CGFloat, label: String) async {
            guard let id = tracks[trackIndex].id, let frame = DebugHitTargets.playCells[id],
                  let height = window.contentView?.bounds.height else {
                results.append("\(label): no frame")
                return
            }
            // SwiftUI global space is top-left; window coordinates are bottom-left.
            let point = NSPoint(x: frame.midX + dx, y: height - (frame.midY + dy))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
            try? await Task.sleep(for: .seconds(0.8))
            results.append("\(label): current=\(model.player.current?.title ?? "nil") state=\(model.player.state)")
        }
        // Offsets from the center of the play strip (full row height, padding + icon column).
        let halfWidth = (TrackRow.rowLeadingPadding + TrackRow.playCellWidth) / 2 - 2
        let halfHeight = (tracks[2].id.flatMap { DebugHitTargets.playCells[$0]?.height } ?? 40) / 2 - 2
        await click(trackIndex: 1, dx: 0, dy: 0, label: "center of track 2")
        await click(trackIndex: 2, dx: -halfWidth, dy: -halfHeight, label: "top-left corner of track 3")
        await click(trackIndex: 2, dx: halfWidth, dy: halfHeight, label: "bottom-right corner of track 3 (current, pauses)")
        try? results.joined(separator: "\n").write(to: output.appendingPathComponent("CLICKS"), atomically: true, encoding: .utf8)
        model.albumPath = []
    }

    /// Drags the Shelf slider with real mouse events, releases between two albums and records where it settles.
    private static func shelfSliderTest(model: AppModel, output: URL) async {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 && !["Equalizer", "Visualizer"].contains($0.title) }),
              let height = window.contentView?.bounds.height, DebugHitTargets.shelfSlider.width > 0 else {
            try? "skipped".write(to: output.appendingPathComponent("SHELF"), atomically: true, encoding: .utf8)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(0.5))
        let frame = DebugHitTargets.shelfSlider
        func send(_ type: NSEvent.EventType, fraction: CGFloat) {
            let point = NSPoint(x: frame.minX + 8 + (frame.width - 16) * fraction, y: height - frame.midY)
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
        var lines: [String] = []
        for target in [0.37, 0.71, 0.12] {
            send(.leftMouseDown, fraction: 0.0)
            for step in 1...12 {
                send(.leftMouseDragged, fraction: target * CGFloat(step) / 12)
                try? await Task.sleep(for: .milliseconds(16))
            }
            let atRelease = DebugHitTargets.shelfPosition
            send(.leftMouseUp, fraction: target)
            try? await Task.sleep(for: .seconds(1))
            let settled = DebugHitTargets.shelfPosition
            lines.append(String(format: "drag to %.2f: released at %.3f, settled at %.3f (on an album: %@)",
                                target, atRelease, settled, settled == settled.rounded() ? "yes" : "NO"))
        }
        // Back to the first album (the 16-track "Long Player" fixture), flip it, scroll its list, play a row.
        send(.leftMouseDown, fraction: 0)
        send(.leftMouseUp, fraction: 0)
        try? await Task.sleep(for: .seconds(1))
        let center = DebugHitTargets.shelfCenterCover
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: center.x, y: height - center.y), modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
        try? await Task.sleep(for: .seconds(1.5))
        await snapshot("05b-shelf-flipped", output)
        let tracks = (try? await model.database.writer.read { db in
            try Track.filter(sql: "album = 'Long Player'").order(sql: "trackNumber").fetchAll(db)
        }) ?? []
        if tracks.count == 16, let firstId = tracks[0].id, let before = DebugHitTargets.playCells[firstId] {
            // Real scroll wheel event over the card (CGEvent screen space is top-left based).
            let windowPoint = NSPoint(x: center.x, y: height - center.y)
            let screenPoint = window.convertPoint(toScreen: windowPoint)
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            var delivered = ""
            for _ in 0..<6 {
                if let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0) {
                    // A window-less event reports its screen location as `locationInWindow`, and `sendEvent` hit tests
                    // with that value, so place it where the window point would be read back.
                    _ = screenPoint
                    cgEvent.location = CGPoint(x: windowPoint.x, y: screenHeight - windowPoint.y)
                    if let event = NSEvent(cgEvent: cgEvent) {
                        delivered = "event.locationInWindow=\(event.locationInWindow) expected=\(windowPoint) window#=\(event.windowNumber)"
                        window.sendEvent(event)
                    }
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
            lines.append(delivered)
            try? await Task.sleep(for: .seconds(0.8))
            let after = DebugHitTargets.playCells[firstId] ?? before
            // Measured on the list's own scroll offset: the flip animation's non-interactive copy registers the same
            // rows, so row frames are not a reliable signal here.
            _ = after
            let offset = DebugHitTargets.shelfListOffset
            lines.append(String(format: "flipped list scroll: content offset %.0f pt (scrolled: %@), overlay settled: %@, shelf position %.2f",
                                offset, offset > 20 ? "yes" : "NO", DebugHitTargets.shelfBacksideSettled ? "yes" : "NO",
                                DebugHitTargets.shelfPosition))
            await snapshot("05c-shelf-flipped-scrolled", output)
            // Click the play strip of a row that is visible after scrolling.
            if let row = tracks.dropFirst(5).first(where: { track in
                track.id.flatMap { DebugHitTargets.playCells[$0] }.map { $0.minY > before.minY && $0.maxY < before.minY + 250 } ?? false
            }), let id = row.id, let frame = DebugHitTargets.playCells[id] {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: frame.midX, y: height - frame.midY), modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        window.sendEvent(event)
                    }
                    try? await Task.sleep(for: .milliseconds(60))
                }
                try? await Task.sleep(for: .seconds(0.8))
                lines.append("play strip click on '\(row.title)': now playing '\(model.player.current?.title ?? "nil")'")
            } else {
                lines.append("no visible row found after scrolling")
            }
        } else {
            lines.append("flip test skipped: tracks=\(tracks.count), frame known=\(tracks.first?.id.flatMap { DebugHitTargets.playCells[$0] } != nil)")
        }
        // Control: the same synthetic scroll over the album page of the same album (a plain ScrollView).
        if let album = (try? await model.database.writer.read { try LibraryDatabase.albums($0) })?.first(where: { $0.title == "Long Player" }),
           tracks.count == 16, let firstId = tracks[0].id {
            model.albumPath = [album]
            try? await Task.sleep(for: .seconds(2))
            if let before = DebugHitTargets.playCells[firstId] {
                let point = NSPoint(x: before.midX + 200, y: height - (before.midY + 100))
                for _ in 0..<6 {
                    if let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0) {
                        cgEvent.location = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
                        if let event = NSEvent(cgEvent: cgEvent) { window.sendEvent(event) }
                    }
                    try? await Task.sleep(for: .milliseconds(30))
                }
                try? await Task.sleep(for: .seconds(0.8))
                let after = DebugHitTargets.playCells[firstId] ?? before
                lines.append(String(format: "control (album page): row 1 moved %.0f pt", before.minY - after.minY))
            }
            model.albumPath = []
        }
        try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("SHELF"), atomically: true, encoding: .utf8)
    }

    /// Clicks a song's "⋯" button on an album page and in Songs, records the menu items, and in Songs picks "Go to Album".
    /// A clicked menu tracks in a nested event loop, so the items are read (and one picked) from the tracking notification.
    private static func trackMenuTest(model: AppModel, output: URL) async {
        var lines: [String] = []
        func save() { try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("TRACKMENU"), atomically: true, encoding: .utf8) }
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }),
              let height = window.contentView?.bounds.height else { return }
        let albums = (try? await model.database.writer.read { try LibraryDatabase.albums($0) }) ?? []

        func click(_ point: NSPoint) async {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
        }

        func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

        /// `rowPoint` (window coordinates) selects the row; `findPoint` then locates the button (it only shows on hover
        /// or selection, and synthetic clicks produce no hover).
        func openMenu(rowPoint: NSPoint?, findPoint: () -> NSPoint?, pick: String?, label: String) async {
            // Nil when the row is already selected.
            if let rowPoint {
                await click(rowPoint)
                try? await Task.sleep(for: .seconds(0.6))
            }
            guard let point = findPoint() else {
                lines.append("\(label): button not found")
                return
            }
            // The "⋯" menu is an NSPopUpButton; clicking it tracks the menu in a nested event loop inside sendEvent. The
            // main dispatch queue does not run there (this code is itself a main queue block), but run loop timers in the
            // common modes do: one reads the items, picks one and closes the menu.
            var hit = window.contentView?.superview?.hitTest(point)
            while let view = hit, !(view is NSPopUpButton) { hit = view.superview }
            guard let button = hit as? NSPopUpButton, let menu = button.menu else {
                lines.append("\(label): no pop-up button under the click point")
                return
            }
            nonisolated(unsafe) let trackedMenu = menu
            nonisolated(unsafe) var titles: [String] = []
            let timer = Timer(timeInterval: 0.8, repeats: false) { _ in
                MainActor.assumeIsolated {
                    titles = trackedMenu.items.map { $0.isSeparatorItem ? "|" : $0.title }
                    if let pick, let index = trackedMenu.items.firstIndex(where: { $0.title == pick }) {
                        trackedMenu.performActionForItem(at: index)
                    }
                    trackedMenu.cancelTracking()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            await click(point)
            try? await Task.sleep(for: .seconds(1.5))
            lines.append("\(label): menu = \(titles.joined(separator: ", "))")
            save()
        }

        // Album page: no "Go to Album".
        if let album = albums.first(where: { $0.title == "Hi-Res Sessions" }),
           let tracks = try? await model.database.writer.read({ try LibraryDatabase.tracks($0, albumKey: album.albumKey) }),
           let id = tracks.first?.id {
            model.albumPath = [album]
            try? await Task.sleep(for: .seconds(2))
            let frame = DebugHitTargets.menuButtons[id]
            await openMenu(rowPoint: frame.map { NSPoint(x: $0.midX - 220, y: height - $0.midY) },
                           findPoint: { frame.map { NSPoint(x: $0.midX, y: height - $0.midY) } },
                           pick: nil, label: "album page '\(album.title)'")
            await snapshot("40-album-page", output)
            model.albumPath = []
        }

        // Songs: pick "Go to Album" on the first song.
        DebugHitTargets.menuButtons = [:]
        model.selection = .songs
        try? await Task.sleep(for: .seconds(2))
        await snapshot("41-songs", output)
        // Table cells are hosted in their own views: find the table's first row and the pop-up button inside it.
        if let contentView = window.contentView?.superview,
           let table = descendants(of: contentView).compactMap({ $0 as? NSTableView }).first(where: { $0.numberOfRows > 10 }) {
            // Synthetic clicks do not select table rows; select it the way the table does, then let SwiftUI update.
            table.selectRowIndexes([0], byExtendingSelection: false)
            try? await Task.sleep(for: .seconds(1))
            await snapshot("41b-songs-selected", output)
            let titleCell = (0..<table.numberOfColumns).compactMap { table.view(atColumn: $0, row: 0, makeIfNecessary: false) }
            await openMenu(rowPoint: nil, findPoint: {
                for cell in titleCell {
                    if let button = descendants(of: cell).first(where: { $0 is NSPopUpButton }) {
                        return button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                    }
                }
                return nil
            }, pick: "Go to Album", label: "songs first row")
            try? await Task.sleep(for: .seconds(1.5))
            lines.append("after Go to Album: selection=\(String(describing: model.selection)) albumPath=\(model.albumPath.map(\.title))")
            await snapshot("42-went-to-album", output)
        }
        save()
    }

    /// Organizes the whole library (preview, apply, rescan, undo), then imports an inbox folder (`-GLDebugImportInbox`)
    /// with identification, tagging and naming, then undoes the import.
    private static func filesTest(model: AppModel, output: URL) async {
        var lines: [String] = []
        func save() { try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("FILES"), atomically: true, encoding: .utf8) }
        try? await Task.sleep(for: .seconds(3))
        let root = UserDefaults.standard.string(forKey: "GLDebugLibraryPath") ?? ""
        let before = (try? await model.database.writer.read { try LibraryDatabase.allTracks($0) }) ?? []
        let original = Dictionary(uniqueKeysWithValues: before.compactMap { track in track.id.map { ($0, track.path) } })

        // Organize.
        model.files.organize()
        try? await Task.sleep(for: .seconds(2))
        await snapshot("140-organize-preview", output)
        model.files.organizeRequest = nil
        let plan = await model.files.plan(for: nil)
        lines.append("organize plan: \(plan.filter { $0.status != .unchanged }.count) of \(plan.count) files move, \(plan.filter { $0.status == .renamedForConflict }.count) numbered")
        lines.append("examples: " + plan.prefix(3).map { String($0.destination.path.dropFirst(root.count + 1)) }.joined(separator: " | "))
        await model.files.apply(plan)
        let organized = (try? await model.database.writer.read { try LibraryDatabase.allTracks($0) }) ?? []
        lines.append("after organize: all files exist \(organized.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) }), undo title '\(model.files.undoTitle)'")
        await model.rescanAndWait()
        lines.append("rescan after organize: \(model.lastScanSummary.map { "added \($0.added), removed \($0.removed)" } ?? "-")")
        await model.files.undoLast()
        let restored = (try? await model.database.writer.read { try LibraryDatabase.allTracks($0) }) ?? []
        let exact = restored.allSatisfy { original[$0.id ?? -1] == $0.path && FileManager.default.fileExists(atPath: $0.url.path) }
        lines.append("after undo: every path restored exactly \(exact) (\(restored.count) songs)")
        save()

        // Import.
        guard let inbox = UserDefaults.standard.string(forKey: "GLDebugImportInbox") else { return save() }
        let session = ImportSession(urls: [URL(fileURLWithPath: inbox)], model: model, store: model.files)
        model.files.importSession = session
        await session.analyze()
        try? await Task.sleep(for: .seconds(1))
        lines.append("import review: \(session.groups.map { "\($0.title) by \($0.artist) [\($0.matchedRelease ?? "file tags")]: \($0.items.count) files" }), duplicates \(session.duplicateCount)")
        await snapshot("141-import-review", output)
        await session.run()
        let imported = model.files.undoable?.entries ?? []
        let cueSongs = ((try? await model.database.writer.read { try LibraryDatabase.allTracks($0) }) ?? []).filter(\.isCueTrack)
        let cueFolders: [String] = Set(cueSongs.map { $0.url.deletingLastPathComponent().path }).sorted().map { String($0.dropFirst(root.count + 1)) }
        lines.append("cue songs after import: \(cueSongs.count), in " + cueFolders.joined(separator: " | "))
        lines.append("imported: " + imported.map { String($0.to.dropFirst(root.count + 1)) }.joined(separator: " | "))
        if let first = imported.first, let tags = try? TagReader.read(URL(fileURLWithPath: first.to)) {
            lines.append("tags written: \(tags.title ?? "-") / \(tags.artist ?? "-") / \(tags.album ?? "-") / \(tags.year.map(String.init) ?? "-") / #\(tags.trackNumber.map(String.init) ?? "-"), artwork \(tags.artwork != nil)")
        }
        // The imported songs' credits, album and artist backgrounds and lyrics load in the background.
        for _ in 0..<240 where model.metadata.isFetchingLibraryInfo { try? await Task.sleep(for: .milliseconds(500)) }
        let importedTracks = ((try? await model.database.writer.read { try LibraryDatabase.allTracks($0) }) ?? [])
            .filter { track in imported.contains { $0.to == track.path || $0.to == track.audioPath } }
        for albumKey in Set(importedTracks.map(\.albumKey)).sorted() {
            let album = try? await model.database.writer.read { try LibraryDatabase.albumInfo($0, albumKey: albumKey) }
            let info = album.flatMap { try? JSONDecoder().decode(AlbumInfo.self, from: $0.data) }
            lines.append("after import, album '\(albumKey)': info \(info.map { $0.isEmpty ? "miss" : "found" } ?? "none"), about \(info?.about != nil), \(info?.creditEntries(albumKey: albumKey).count ?? 0) credits")
        }
        for name in Set(importedTracks.map(\.displayAlbumArtist)).sorted() {
            let artist = try? await model.database.writer.read { try LibraryDatabase.artistInfo($0, name: name) }
            let info = artist.flatMap { try? JSONDecoder().decode(ArtistInfo.self, from: $0.data) }
            lines.append("after import, artist '\(name)': info \(info.map { $0.isEmpty ? "miss" : "found" } ?? "none"), photo \(info?.imageHash != nil)")
        }
        let credited = (try? await model.database.writer.read { try LibraryDatabase.creditIndexCount($0) }) ?? 0
        lines.append("credit index rows \(credited); lyrics on \(importedTracks.filter { $0.fetchedLyrics?.isEmpty == false || $0.lyrics?.isEmpty == false }.count) of \(importedTracks.count) songs")
        let inboxLeft = (try? FileManager.default.contentsOfDirectory(atPath: inbox).filter { !$0.hasPrefix(".") }) ?? []
        lines.append("inbox after import (moved out): \(inboxLeft)")
        await snapshot("142-import-finished", output)
        model.files.importSession = nil
        let songsAfterImport = (try? await model.database.writer.read { try Track.fetchCount($0) }) ?? 0
        await model.files.undoLast()
        let songsAfterUndo = (try? await model.database.writer.read { try Track.fetchCount($0) }) ?? 0
        let inboxBack = (try? FileManager.default.contentsOfDirectory(atPath: inbox).filter { !$0.hasPrefix(".") }) ?? []
        lines.append("undo import: songs \(songsAfterImport) to \(songsAfterUndo), inbox has \(inboxBack.count) files again")
        save()
    }

    private static func syncTest(model: AppModel, phase: String, output: URL) async {
        var lines: [String] = []
        guard let given = UserDefaults.standard.string(forKey: "GLDebugSyncFolder") else { return }
        // As the library spells it (standardized: /private/tmp is /tmp).
        let root = URL(fileURLWithPath: given, isDirectory: true).standardizedFileURL
        let folder = root.path
        func tracks(under path: String) async -> [Track] {
            (try? await model.database.writer.read { db in
                try Track.filter(sql: "path >= ? AND path < ?", arguments: [path + "/", path + "0"]).fetchAll(db)
            }) ?? []
        }
        /// Waits up to 15 s for `condition`, returning how long it took.
        func wait(_ what: String, _ condition: () async -> Bool) async {
            let start = Date.now
            for _ in 0..<150 {
                if await condition() {
                    lines.append("\(what): after \(String(format: "%.1f", Date.now.timeIntervalSince(start))) s")
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            lines.append("\(what): NOT SEEN in 15 s")
        }
        if UserDefaults.standard.string(forKey: "GLDebugLibraryPath") != nil {
            // The folder added by the launch argument: wait for its first scan.
            await wait("first scan") { await !tracks(under: folder).isEmpty && model.scanProgress == nil }
        }
        try? await Task.sleep(for: .seconds(2))
        let fm = FileManager.default
        let source = root.appendingPathComponent("Source", isDirectory: true)

        if phase == "volume", let image = UserDefaults.standard.string(forKey: "GLDebugSyncImage") {
            // A library folder on a drive: unplugged (songs kept, folder unavailable), plugged back (checked, watched).
            func hdiutil(_ arguments: [String]) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                process.arguments = arguments
                try? process.run()
                process.waitUntilExit()
            }
            let mount = "/Volumes/GLSyncTest"
            hdiutil(["attach", image, "-nobrowse"])
            let music = URL(fileURLWithPath: mount + "/Music", isDirectory: true)
            model.addLibraryFolder(music)
            await wait("drive folder scanned") { await tracks(under: music.path).count == 4 }
            hdiutil(["detach", mount])
            await wait("unplugged: folder unavailable, songs kept") {
                let kept = await tracks(under: music.path).count
                return model.unavailableFolders.contains(music.path) && kept == 4
            }
            hdiutil(["attach", image, "-nobrowse"])
            await wait("plugged back: available again") { !model.unavailableFolders.contains(music.path) }
            // After its check, so only the watcher can find the next file.
            try? await Task.sleep(for: .seconds(3))
            try? fm.copyItem(at: music.appendingPathComponent("Source/01 Long Track 1.flac"), to: music.appendingPathComponent("New.flac"))
            await wait("and watched: a new file appears") { await tracks(under: music.path).count == 5 }
            if let id = (try? await model.database.writer.read { try LibraryDatabase.roots($0) })?.first(where: { $0.path == music.path })?.id {
                model.removeRoot(LibraryRoot(id: id, path: music.path, bookmark: Data()))
            }
            try? await Task.sleep(for: .seconds(1))
            hdiutil(["detach", mount])
        } else if phase == "live" {
            let album = root.appendingPathComponent("Live Artist/Live Album", isDirectory: true)
            try? fm.createDirectory(at: album.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: source, to: album)
            let count = (try? fm.contentsOfDirectory(atPath: source.path).filter { !$0.hasPrefix(".") && !$0.hasSuffix(".jpg") }.count) ?? 0
            await wait("copied album (\(count) files) appears") { await tracks(under: album.path).count == count }
            let ids = Set(await tracks(under: album.path).compactMap(\.id))
            try? await Task.sleep(for: .seconds(1))
            await snapshot("187-sync-note", output)

            let cover = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in NSColor.systemTeal.setFill(); rect.fill(); return true }
            let png = cover.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
            let before = Set(await tracks(under: album.path).compactMap(\.artworkHash))
            try? png?.write(to: album.appendingPathComponent("cover.png"))
            await wait("new cover.png picked up") {
                let hashes = Set(await tracks(under: album.path).compactMap(\.artworkHash))
                return !hashes.isEmpty && hashes != before
            }

            let renamed = root.appendingPathComponent("Live Artist/Renamed Album", isDirectory: true)
            try? fm.moveItem(at: album, to: renamed)
            await wait("renamed folder keeps song ids") { await Set(tracks(under: renamed.path).compactMap(\.id)) == ids }

            if let first = try? fm.contentsOfDirectory(at: renamed, includingPropertiesForKeys: nil).first(where: { $0.pathExtension != "png" && $0.pathExtension != "jpg" }) {
                try? fm.removeItem(at: first)
                await wait("deleted file removed") { await tracks(under: renamed.path).count == count - 1 }
            }
            // A burst while scanning: two albums copied right after each other are both picked up.
            let burstA = root.appendingPathComponent("Burst/A", isDirectory: true), burstB = root.appendingPathComponent("Burst/B", isDirectory: true)
            try? fm.createDirectory(at: burstA.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: source, to: burstA)
            try? await Task.sleep(for: .milliseconds(700))
            try? fm.copyItem(at: source, to: burstB)
            await wait("burst of two albums") {
                let a = await tracks(under: burstA.path).count, b = await tracks(under: burstB.path).count
                return a == count && b == count
            }
        } else {
            let offline = root.appendingPathComponent("Offline Artist/Offline Album", isDirectory: true)
            let count = (try? fm.contentsOfDirectory(atPath: offline.path).filter { !$0.hasPrefix(".") && !$0.hasSuffix(".jpg") }.count) ?? -1
            await wait("album added while closed (\(count) files)") { await tracks(under: offline.path).count == count }
            await wait("folder deleted while closed is gone") { await tracks(under: root.appendingPathComponent("Burst").path).isEmpty }
        }
        lines.append("")
        lines.append("activity:")
        lines += model.sync.activity
        try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("SYNC-\(phase)"), atomically: true, encoding: .utf8)
    }

    private static func shortcutsTest(model: AppModel, output: URL) async {
        try? await Task.sleep(for: .seconds(3))
        var lines: [String] = []
        func describe(_ item: NSMenuItem) -> String {
            let flags = item.keyEquivalentModifierMask
            var text = ""
            if flags.contains(.control) { text += "⌃" }
            if flags.contains(.option) { text += "⌥" }
            if flags.contains(.shift) { text += "⇧" }
            if flags.contains(.command) { text += "⌘" }
            let names: [Character: String] = ["\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→", " ": "Space"]
            return text + item.keyEquivalent.map { names[$0] ?? $0.uppercased() }.joined()
        }
        var seen: [String: String] = [:]
        func walk(_ menu: NSMenu, path: String) {
            for item in menu.items {
                if let submenu = item.submenu { walk(submenu, path: path + item.title + " > ") }
                guard !item.keyEquivalent.isEmpty else { continue }
                let key = describe(item)
                let title = path + item.title
                lines.append("\(key)\t\(title)")
                if let other = seen[key] { lines.append("  DUPLICATE with \(other)") }
                seen[key] = title
            }
        }
        if let menu = NSApp.mainMenu { walk(menu, path: "") }

        var keyCodes: [String: UInt16] = ["l": 37, "s": 1, "r": 15, "u": 32, "f": 3, "2": 19, "6": 22, "[": 33,
                                          "\u{F701}": 125, "\u{F703}": 124]
        func press(_ characters: String, _ flags: NSEvent.ModifierFlags) -> Bool {
            // Built from the virtual key, so the keyboard layout fills in the characters as real typing does.
            guard let code = keyCodes[characters], let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) else { return false }
            var cgFlags: CGEventFlags = []
            if flags.contains(.command) { cgFlags.insert(.maskCommand) }
            if flags.contains(.option) { cgFlags.insert(.maskAlternate) }
            if flags.contains(.shift) { cgFlags.insert(.maskShift) }
            if code >= 123 && code <= 126 { cgFlags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
            cgEvent.flags = cgFlags
            guard let event = NSEvent(cgEvent: cgEvent) else { return false }
            return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
        }
        lines.append("")
        _ = press("2", .command); try? await Task.sleep(for: .seconds(0.5))
        lines.append("⌘2: selection \(String(describing: model.selection))")
        let tracks: [Track] = (try? await model.database.writer.read { db in
            try LibraryKitQueries.firstAlbum(db).map { try LibraryKitQueries.tracks(db, albumKey: $0) } ?? []
        }) ?? []
        model.play(tracks)
        try? await Task.sleep(for: .seconds(1))
        _ = press("6", .command); try? await Task.sleep(for: .seconds(0.3))
        let loved = await model.currentTrack()?.isLoved
        _ = press("l", .command); try? await Task.sleep(for: .seconds(1))
        lines.append("loved before ⌘L \(String(describing: loved)), after \(String(describing: await model.currentTrack()?.isLoved))")
        lines.append("⌘6 then ⌘L: selection \(String(describing: model.selection)), pushed \(model.albumPath.map(\.title))")
        model.selection = .shelf
        model.goToCurrentSong(); try? await Task.sleep(for: .seconds(1.5))
        lines.append("direct goToCurrentSong: current \(model.player.current?.title ?? "-"), selection \(String(describing: model.selection)), pushed \(model.albumPath.map(\.title))")
        for code: UInt16 in [41, 33] {
            keyCodes["["] = code
            if model.path.isEmpty { model.path = [.artist("Radiohead")] }
            try? await Task.sleep(for: .seconds(0.3))
            _ = press("[", .command); try? await Task.sleep(for: .seconds(0.5))
            lines.append("⌘[ (key \(code)): pushed \(model.path.count)")
        }
        let volume = model.player.volume
        _ = press("\u{F701}", [.command, .option]); try? await Task.sleep(for: .seconds(0.2))
        let muted = model.player.volume
        _ = press("\u{F701}", [.command, .option]); try? await Task.sleep(for: .seconds(0.2))
        lines.append("⌥⌘↓ twice: \(volume) -> \(muted) -> \(model.player.volume)")
        let shiftLoved = await model.currentTrack()?.isLoved
        _ = press("l", [.command, .shift]); try? await Task.sleep(for: .seconds(0.5))
        lines.append("⇧⌘L: loved \(String(describing: shiftLoved)) -> \(String(describing: await model.currentTrack()?.isLoved))")
        _ = press("f", [.command, .shift]); try? await Task.sleep(for: .seconds(0.5))
        lines.append("⇧⌘F: now playing \(model.isShowingNowPlaying), selection \(String(describing: model.selection))")
        model.isShowingNowPlaying = false
        let title = model.player.current?.title
        let time = model.player.currentTime
        _ = press("\u{F703}", [.command, .option]); try? await Task.sleep(for: .seconds(0.5))
        lines.append("⌥⌘→: '\(title ?? "-")' \(String(format: "%.1f", time)) -> '\(model.player.current?.title ?? "-")' \(String(format: "%.1f", model.player.currentTime)) of \(String(format: "%.0f", model.player.duration))")
        _ = press("r", .command)
        lines.append("⌘R: repeat \(model.player.repeatMode)")
        _ = press("s", .command)
        lines.append("⌘S: shuffled \(model.player.isShuffled)")
        _ = press("s", .command); _ = press("r", .command); _ = press("r", .command)
        _ = press("l", [.command, .option]); try? await Task.sleep(for: .seconds(0.3))
        lines.append("⌥⌘L: side panel \(String(describing: model.sidePanel))")
        _ = press("u", [.command, .option]); try? await Task.sleep(for: .seconds(0.3))
        lines.append("⌥⌘U: side panel \(String(describing: model.sidePanel))")
        _ = press("f", .command); try? await Task.sleep(for: .seconds(0.3))
        lines.append("⌘F: selection \(String(describing: model.selection))")
        model.player.togglePlayPause()
        func mainWindows() -> [NSWindow] { NSApp.windows.filter { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible } }
        lines.append("main windows: \(mainWindows().count) (\(mainWindows().map { $0.identifier?.rawValue ?? "" }))")
        mainWindows().first?.performClose(nil)
        try? await Task.sleep(for: .seconds(1))
        lines.append("after closing: \(mainWindows().count)")
        keyCodes["0"] = 29
        _ = press("0", .command); try? await Task.sleep(for: .seconds(1.5))
        lines.append("⌘0: \(mainWindows().count)")
        _ = press("0", .command); try? await Task.sleep(for: .seconds(1))
        lines.append("⌘0 again: \(mainWindows().count)")
        // ⌘F with the app in front puts the cursor in the toolbar search field.
        NSApp.activate()
        mainWindows().first?.makeKeyAndOrderFront(nil)
        model.selection = .albums
        try? await Task.sleep(for: .seconds(1))
        keyCodes["f"] = 3
        _ = press("f", .command); try? await Task.sleep(for: .seconds(1))
        lines.append("⌘F in front: active \(NSApp.isActive), key window \(NSApp.keyWindow?.identifier?.rawValue ?? "none"), selection \(String(describing: model.selection)), main window first responder \(mainWindows().first?.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")

        // Remapping: the store refuses taken and reserved keys, the menus follow, and the change is saved.
        let store = model.shortcuts
        let cmdJ = ShortcutStore.Stored(key: "j", modifiers: Int(EventModifiers.command.rawValue))
        lines.append("⌘L for Shuffle: \(store.set(ShortcutStore.stored(ShortcutAction.goToCurrentSong.defaultShortcut), for: .shuffle) ?? "accepted")")
        lines.append("⌘Q for Shuffle: \(store.set(ShortcutStore.Stored(key: "q", modifiers: Int(EventModifiers.command.rawValue)), for: .shuffle) ?? "accepted")")

        // The recorder in Settings, fed queued key presses as the keyboard would.
        let window = NSWindow(contentRect: NSRect(x: 200, y: 100, width: 720, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Shortcuts"
        window.contentView = NSHostingView(rootView: ShortcutsSettings().environment(model).tint(.brand))
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(1))
        func post(_ code: UInt16, _ flags: CGEventFlags) {
            for down in [true, false] {
                guard let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { continue }
                cgEvent.flags = flags
                if let event = NSEvent(cgEvent: cgEvent) { NSApp.postEvent(event, atStart: false) }
            }
        }
        store.recording = .shuffle
        try? await Task.sleep(for: .seconds(0.5))
        post(37, .maskCommand)  // ⌘L: taken by Go to Current Song
        try? await Task.sleep(for: .seconds(0.5))
        lines.append("recorder ⌘L: shuffle \(store.shortcut(for: .shuffle).map(ShortcutStore.display) ?? "none"), still recording \(store.recording == .shuffle)")
        await snapshot("185-shortcuts-conflict", output)
        post(38, .maskCommand)  // ⌘J
        try? await Task.sleep(for: .seconds(0.5))
        lines.append("recorder ⌘J: shuffle \(store.shortcut(for: .shuffle).map(ShortcutStore.display) ?? "none"), recording \(String(describing: store.recording)), saved \(UserDefaults.standard.data(forKey: ShortcutStore.key).map { String(decoding: $0, as: UTF8.self) } ?? "-")")
        store.recording = .visualizer
        try? await Task.sleep(for: .seconds(0.3))
        post(51, [])  // Delete removes it
        try? await Task.sleep(for: .seconds(0.5))
        lines.append("recorder Delete: visualizer \(store.shortcut(for: .visualizer).map(ShortcutStore.display) ?? "none")")
        await snapshot("186-shortcuts-settings", output)
        window.orderOut(nil)

        try? await Task.sleep(for: .seconds(0.5))
        var shuffle = "", visualizer = ""
        if let menu = NSApp.mainMenu {
            func find(_ menu: NSMenu) {
                for item in menu.items {
                    if let sub = item.submenu { find(sub) }
                    if item.title == "Shuffle" { shuffle = describe(item) }
                    if item.title == "Show Visualizer" { visualizer = describe(item) }
                }
            }
            find(menu)
        }
        lines.append("menus: Shuffle '\(shuffle)', Show Visualizer '\(visualizer)'")
        let before = model.player.isShuffled
        keyCodes["j"] = 38
        _ = press("j", .command); try? await Task.sleep(for: .seconds(0.3))
        let afterJ = model.player.isShuffled
        _ = press("s", .command); try? await Task.sleep(for: .seconds(0.3))
        lines.append("shuffle \(before), after ⌘J \(afterJ), after ⌘S \(model.player.isShuffled)")
        _ = cmdJ
        store.resetAll()
        lines.append("after Restore Defaults: shuffle \(store.shortcut(for: .shuffle).map(ShortcutStore.display) ?? "none"), saved \(UserDefaults.standard.data(forKey: ShortcutStore.key) == nil ? "nothing" : "data")")
        try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("SHORTCUTS"), atomically: true, encoding: .utf8)
    }

    private static func searchTest(model: AppModel, output: URL) async {
        try? await Task.sleep(for: .seconds(3))
        var lines: [String] = []
        func responder() -> String { NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "none" }
        // An artist, and someone from the credits who is not a library artist.
        let artist = (try? await model.database.writer.read { try LibraryDatabase.artists($0) })?.first { $0.albumCount > 1 }?.name ?? "Radiohead"
        let personName = try? await model.database.writer.read { db in
            try String.fetchOne(db, sql: """
                SELECT name FROM creditIndex WHERE nameKey NOT IN (SELECT LOWER(COALESCE(NULLIF(albumArtist, ''), artist)) FROM track)
                GROUP BY nameKey ORDER BY COUNT(*) DESC LIMIT 1
                """)
        }

        model.showSearch()
        try? await Task.sleep(for: .seconds(1))
        lines.append("Search item: selection \(String(describing: model.selection)), first responder \(responder())")
        await snapshot("180-search-landing", output)

        for (index, query) in [artist, personName ?? "producer"].enumerated() {
            model.searchText = String(query.split(separator: " ").last ?? "")
            try? await Task.sleep(for: .seconds(1.5))
            let results = (try? await model.database.writer.read { [text = model.searchText] in try LibraryDatabase.search($0, query: text) })
            lines.append("'\(model.searchText)': artists \(results?.artists.prefix(3).map(\.name) ?? []), albums \(results?.albums.count ?? 0), songs \(results?.songs.count ?? 0), people \(results?.people.prefix(3).map { "\($0.person.name) (\($0.roles.prefix(2).joined(separator: ", ")))" } ?? [])")
            await snapshot("18\(index + 1)-search-results", output)
        }

        // Typing from another page switches to the results; opening a result remembers the search.
        model.selection = .albums
        lines.append("after leaving: searchText '\(model.searchText)'")
        model.searchText = String(artist.prefix(4))
        lines.append("typing on Albums: selection \(String(describing: model.selection))")
        model.path.append(.artist(artist))
        try? await Task.sleep(for: .seconds(1.5))
        await snapshot("183-search-artist-page", output)
        lines.append("recent searches: \(RecentSearches.list(UserDefaults.standard.string(forKey: RecentSearches.key) ?? ""))")
        model.path = []

        // With the sidebar collapsed the field stays in the toolbar.
        NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
        try? await Task.sleep(for: .seconds(1.5))
        await snapshot("184-search-sidebar-collapsed", output)
        model.showSearch()
        try? await Task.sleep(for: .seconds(0.5))
        lines.append("Command-F with the sidebar collapsed: first responder \(responder())")
        NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
        try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("SEARCH"), atomically: true, encoding: .utf8)
    }

    private static func miniPlayerTest(model: AppModel, output: URL) async {
        try? await Task.sleep(for: .seconds(3))
        if let image = NSImage(named: "MenuBarNote") {
            // The template note drawn large, black on white and white on black, as the menu bar tints it.
            for (name, background, tint) in [("light", NSColor.white, NSColor.black), ("dark", NSColor.black, NSColor.white)] {
                let drawn = NSImage(size: NSSize(width: 160, height: 160), flipped: false) { rect in
                    background.setFill(); rect.fill()
                    let scale = 140 / image.size.height
                    let size = NSSize(width: image.size.width * scale, height: 140)
                    let tinted = NSImage(size: size, flipped: false) { r in
                        image.draw(in: r); tint.set(); r.fill(using: .sourceAtop); return true }
                    tinted.draw(in: NSRect(x: (160 - size.width) / 2, y: 10, width: size.width, height: size.height))
                    return true
                }
                if let tiff = drawn.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: output.appendingPathComponent("160-menubar-note-\(name).png"))
                }
            }
            try? "menu bar image \(image.size), template \(image.isTemplate)".write(to: output.appendingPathComponent("MINI"), atomically: true, encoding: .utf8)
        }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 320, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "MiniPlayer"
        window.contentView = NSHostingView(rootView: MiniPlayerView().menuBarGlass().environment(model).tint(.brand))
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(1))
        await snapshot("161-mini-not-playing", output)
        let tracks: [Track] = (try? await model.database.writer.read { db in
            try LibraryKitQueries.firstAlbum(db).map { try LibraryKitQueries.tracks(db, albumKey: $0) } ?? []
        }) ?? []
        model.play(tracks)
        try? await Task.sleep(for: .seconds(4))
        window.setContentSize(window.contentView?.fittingSize ?? window.frame.size)
        await snapshot("162-mini-playing", output)

        // Lyrics and Up Next are toggles: click each twice (points from the snapshot's bottom row).
        let height = window.contentView?.bounds.height ?? 0
        func click(x: CGFloat) async -> String {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: height - 183), modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
            try? await Task.sleep(for: .milliseconds(400))
            window.makeKeyAndOrderFront(nil)
            if model.isShowingNowPlaying { return model.isShowingLyrics ? "now playing lyrics" : "now playing" }
            return model.sidePanel.map { "\($0)" } ?? "closed"
        }
        var states: [String] = []
        for x in [218.5, 218.5, 254.5, 254.5] as [CGFloat] { states.append(await click(x: x)) }
        let previous = (try? String(contentsOf: output.appendingPathComponent("MINI"), encoding: .utf8)) ?? ""
        try? (previous + "\nlyrics click, click, up next click, click: " + states.joined(separator: ", "))
            .write(to: output.appendingPathComponent("MINI"), atomically: true, encoding: .utf8)
        model.player.togglePlayPause()
    }

    /// Plays the second song of a cue album (a range of one file), then lets it run into the third.
    private static func cueTest(model: AppModel, output: URL) async {
        var lines: [String] = []
        func save() { try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("CUE"), atomically: true, encoding: .utf8) }
        try? await Task.sleep(for: .seconds(3))
        let songs = ((try? await model.database.writer.read { try LibraryDatabase.allTracks($0) }) ?? []).filter(\.isCueTrack).sorted { $0.path < $1.path }
        let described: [String] = songs.map { song in
            let range = formatDuration(song.startTime ?? 0) + "-" + (song.endTime.map(formatDuration) ?? "end")
            return "\(song.trackNumber ?? 0). \(song.title) [\(range)] \(formatDuration(song.duration))"
        }
        lines.append("cue songs: " + described.joined(separator: " | "))
        lines.append("files: " + Set(songs.map { $0.url.lastPathComponent }).sorted().joined(separator: ", ") + ", album key count \(Set(songs.map(\.albumKey)).count)")
        let albums: [AlbumSummary] = (try? await model.database.writer.read { db in try LibraryDatabase.albums(db) }) ?? []
        guard songs.count >= 3, let album = albums.first(where: { $0.albumKey == songs[0].albumKey }) else { return save() }
        model.selection = .albums
        model.path = [.album(album)]
        try? await Task.sleep(for: .seconds(2))
        await snapshot("150-cue-album", output)

        model.play(songs, startAt: 1)
        try? await Task.sleep(for: .seconds(3))
        let player = model.player
        lines.append("playing '\(player.current?.title ?? "-")': time \(String(format: "%.1f", player.currentTime)) of \(String(format: "%.1f", player.duration))")
        player.seek(to: player.duration - 3)
        try? await Task.sleep(for: .seconds(5))
        lines.append("after the end of song 2: '\(player.current?.title ?? "-")' at \(String(format: "%.1f", player.currentTime)) of \(String(format: "%.1f", player.duration))")
        player.previous()
        try? await Task.sleep(for: .seconds(2))
        lines.append("previous: '\(player.current?.title ?? "-")' at \(String(format: "%.1f", player.currentTime))")
        player.togglePlayPause()
        save()
    }

    /// Builds library-only data, backs up, damages it, restores, simulates a new Mac (folder to locate) and runs
    /// automatic backups with pruning.
    private static func backupTest(model: AppModel, output: URL) async {
        var lines: [String] = []
        func save() { try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("BACKUP"), atomically: true, encoding: .utf8) }
        func state() async -> String {
            let summary = try? await model.database.writer.read { db -> String in
                let loved = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE isLoved") ?? 0
                let plays = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(playCount), 0) FROM track") ?? 0
                let fixed = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE metadataOverrides IS NOT NULL") ?? 0
                let playlists = try LibraryDatabase.playlists(db).map { "\($0.name)\($0.coverStyle == nil ? "" : " (cover)")" }
                return "loved \(loved), plays \(plays), fixes \(fixed), playlists \(playlists)"
            }
            return "\(summary ?? "-"), EQ \(model.equalizer.isEnabled ? "on" : "off")"
        }
        try? await Task.sleep(for: .seconds(3))
        let tracks = (try? await model.database.writer.read { try LibraryDatabase.allTracks($0) }) ?? []
        for track in tracks.prefix(3) { model.toggleLoved(track) }
        if let id = tracks.first?.id {
            try? model.database.recordPlay(trackId: id)
            try? model.database.applyMetadata([id: TrackMetadata(title: "Fixed Title")], asOverrides: true)
        }
        model.createPlaylist(named: "Favorites", tracks: Array(tracks.prefix(5)))
        model.equalizer.isEnabled = true
        try? await Task.sleep(for: .seconds(1))
        lines.append("before backup: \(await state())")

        let url = output.appendingPathComponent("Test.\(LibraryBackup.fileExtension)")
        let ok = await model.backup.backUp(to: url, isAutomatic: false)
        let manifest = try? LibraryBackup.manifest(of: url)
        lines.append("backup ok=\(ok): \(manifest.map { "\($0.trackCount) songs, \($0.playlistCount) playlists, \($0.lovedCount) loved, \($0.artworkCount) artwork files" } ?? "-")")

        // Damage the library.
        for playlist in (try? await model.database.writer.read { try LibraryDatabase.playlists($0) }) ?? [] { model.deletePlaylist(playlist.id!) }
        for track in tracks.prefix(3) {
            if let id = track.id { try? model.database.setLoved(false, trackId: id) }
        }
        if let id = tracks.first?.id { try? model.database.applyMetadata([id: TrackMetadata(title: "")], asOverrides: false) }
        model.equalizer.isEnabled = false
        try? await Task.sleep(for: .seconds(1))
        lines.append("after damage: \(await state())")

        await model.backup.restore(from: url)
        try? await Task.sleep(for: .seconds(2))
        lines.append("after restore: \(await state()), folders to locate \(model.backup.foldersToLocate.count)")
        await snapshot("130-after-restore", output)

        // "Another Mac": folder access from the backup does not work there.
        if let root = try? await model.database.writer.read({ try LibraryDatabase.roots($0).first }), let id = root.id {
            _ = try? model.database.relocateRoot(id, to: "/Volumes/Old Mac/Music", bookmark: Data([0]))
            await model.reopenLibraryAfterRestore()
            try? await Task.sleep(for: .seconds(1.5))
            let kept = (try? await model.database.writer.read { try Track.fetchCount($0) }) ?? 0
            lines.append("new Mac: folders to locate \(model.backup.foldersToLocate.map(\.path)), songs kept \(kept)")
            await snapshot("131-locate-folders", output)
            model.backup.foldersToLocate = []
            // Locating it (what the panel does) brings the songs back to their files.
            if let bookmark = try? FolderAccess.makeBookmark(for: URL(fileURLWithPath: UserDefaults.standard.string(forKey: "GLDebugLibraryPath") ?? "")) {
                _ = try? model.database.relocateRoot(id, to: UserDefaults.standard.string(forKey: "GLDebugLibraryPath") ?? "", bookmark: bookmark)
                model.rescanAll()
                try? await Task.sleep(for: .seconds(3))
                lines.append("after locating: \(await state()), songs \((try? await model.database.writer.read { try Track.fetchCount($0) }) ?? 0)")
            }
        }

        // Automatic backups keep only the newest.
        UserDefaults.standard.set(2, forKey: BackupManager.Keys.keep)
        for _ in 0..<3 {
            await model.backup.backUpAutomatically()
            try? await Task.sleep(for: .seconds(61))   // file names have minute precision
        }
        let automatic = (try? FileManager.default.contentsOfDirectory(atPath: model.backup.defaultFolder.path)) ?? []
        lines.append("automatic backups kept: \(automatic.sorted())")
        save()
    }

    /// Tags the "Untagged" fixture files as OK Computer, runs the whole library job and records its steps and results.
    private static func libraryJobTest(model: AppModel, output: URL) async {
        var lines: [String] = []
        func save() { try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("LIBRARYJOB"), atomically: true, encoding: .utf8) }
        try? await Task.sleep(for: .seconds(2))
        let untagged = ((try? await model.database.writer.read { try LibraryDatabase.allTracks($0) }) ?? []).filter { $0.path.contains("/Untagged/") }
        var changes: [Int64: TrackMetadata] = [:]
        for track in untagged {
            guard let id = track.id else { continue }
            let guess = FileNameGuess(track.url.deletingPathExtension().lastPathComponent)
            changes[id] = TrackMetadata(title: guess.title, artist: "Radiohead", album: "OK Computer", albumArtist: "Radiohead", trackNumber: guess.trackNumber)
        }
        try? model.database.applyMetadata(changes, asOverrides: true)

        let start = Date.now
        model.metadata.fetchMissingInfo()
        var lastStep: MetadataStore.LibraryStep?
        var snapped = false
        while model.metadata.isFetchingLibraryInfo, Date.now.timeIntervalSince(start) < 420 {
            try? await Task.sleep(for: .seconds(1))
            if let job = model.metadata.libraryJob, job.step != lastStep {
                lastStep = job.step
                lines.append(String(format: "%4.0fs: %@ (%d items), then %@", Date.now.timeIntervalSince(start), job.step.rawValue, job.total,
                                    job.remaining.map(\.rawValue).description))
                save()
            }
            if !snapped, model.metadata.libraryJob?.done ?? 0 >= 2 {
                snapped = true
                await snapshot("120-library-job", output)
            }
        }
        lines.append(String(format: "finished after %.0fs (still running: %@)", Date.now.timeIntervalSince(start), model.metadata.isFetchingLibraryInfo ? "yes" : "no"))
        let summary = try? await model.database.writer.read { db -> String in
            let albumInfo = try LibraryDatabase.allAlbumInfo(db)
            let found = albumInfo.filter { (try? JSONDecoder().decode(AlbumInfo.self, from: $0.data))?.isEmpty == false }.map(\.albumKey)
            let artistsLeft = try LibraryDatabase.artistNamesWithoutInfo(db).count
            let lyricsLeft = try LibraryDatabase.trackIdsNeedingLyrics(db).count
            let okComputer = try LibraryDatabase.albums(db).first { $0.title == "OK Computer" }
            return "album info rows \(albumInfo.count) (with data: \(found.count)), artists without info \(artistsLeft), songs never checked for lyrics \(lyricsLeft), OK Computer cover \(okComputer?.artworkHash != nil)"
        }
        lines.append(summary ?? "-")
        save()
    }

    /// Tags the "Untagged" fixture files as OK Computer (library only, no MusicBrainz id, so the album is found by search),
    /// opens the album page, waits for credits and the Wikipedia summary, and opens Karma Police's credits.
    private static func creditsTest(model: AppModel, output: URL) async {
        var lines: [String] = []
        func save() { try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("CREDITS"), atomically: true, encoding: .utf8) }
        try? await Task.sleep(for: .seconds(2))
        let untagged = ((try? await model.database.writer.read { try LibraryDatabase.allTracks($0) }) ?? []).filter { $0.path.contains("/Untagged/") }
        guard untagged.count >= 4 else {
            lines.append("skipped: no Untagged fixture")
            return save()
        }
        var changes: [Int64: TrackMetadata] = [:]
        for track in untagged {
            guard let id = track.id else { continue }
            let guess = FileNameGuess(track.url.deletingPathExtension().lastPathComponent)
            changes[id] = TrackMetadata(title: guess.title, artist: "Radiohead", album: "OK Computer", albumArtist: "Radiohead",
                                        trackNumber: guess.trackNumber)
        }
        try? model.database.applyMetadata(changes, asOverrides: true)
        let albums = (try? await model.database.writer.read { try LibraryDatabase.albums($0) }) ?? []
        guard let album = albums.first(where: { $0.title == "OK Computer" }) else {
            lines.append("album not found after tagging")
            return save()
        }
        model.albumPath = [album]
        let start = Date.now
        var info: AlbumInfo?
        while Date.now.timeIntervalSince(start) < 45 {
            try? await Task.sleep(for: .seconds(1))
            if let stored = try? await model.database.writer.read({ try LibraryDatabase.albumInfo($0, albumKey: album.albumKey) }) {
                info = try? JSONDecoder().decode(AlbumInfo.self, from: stored.data)
                break
            }
        }
        try? await Task.sleep(for: .seconds(1.5))
        lines.append(String(format: "after %.0fs: release %@, sections %@, about %@", Date.now.timeIntervalSince(start),
                            info?.releaseTitle ?? "none", info?.sections.map { "\($0.kind.rawValue) (\($0.credits.count))" }.description ?? "-",
                            info?.about.map { String($0.summary.prefix(60)) } ?? "none"))
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) { window.setContentSize(NSSize(width: 1800, height: 1000)) }
        try? await Task.sleep(for: .seconds(1.5))
        await snapshot("110-album-header", output)
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }), let height = window.contentView?.bounds.height,
           DebugHitTargets.creditsButton != .zero {
            let frame = DebugHitTargets.creditsButton
            let point = NSPoint(x: frame.midX, y: height - frame.midY)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
            try? await Task.sleep(for: .seconds(1.5))
            lines.append("Credits button opened a sheet: \(NSApp.windows.contains { $0.isSheet && $0.isVisible })")
            await snapshot("110c-album-credits-sheet", output)
            // Click a name in the sheet: it closes and the person's page opens.
            if let sheet = NSApp.windows.first(where: { $0.isSheet && $0.isVisible }), let sheetHeight = sheet.contentView?.bounds.height,
               let nameFrame = DebugHitTargets.creditNames["Nigel Godrich"] {
                let namePoint = NSPoint(x: nameFrame.midX, y: sheetHeight - nameFrame.midY)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: namePoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: sheet.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        sheet.sendEvent(event)
                    }
                    try? await Task.sleep(for: .milliseconds(60))
                }
                try? await Task.sleep(for: .seconds(2))
                let top = model.path.last.map { route -> String in
                    if case let .person(person) = route { return "person \(person.name)" }
                    return "album"
                } ?? "none"
                lines.append("after clicking Nigel Godrich: sheet open=\(NSApp.windows.contains { $0.isSheet && $0.isVisible }), top page \(top)")
                if case let .person(person)? = model.path.last,
                   let credits = try? await model.database.writer.read({ try LibraryDatabase.credits($0, person: person) }) {
                    lines.append("person page: roles \(credits.roles.prefix(4)), albums \(credits.albums.map(\.album.title)), songs \(credits.tracks.map(\.track.title))")
                    await snapshot("110e-person-page", output)
                    model.createPlaylist(named: "With \(person.name)", tracks: credits.tracks.map(\.track))
                    try? await Task.sleep(for: .seconds(1))
                    let playlist = try? await model.database.writer.read { try LibraryDatabase.playlists($0).first { $0.name == "With \(person.name)" } }
                    let songs = (try? await model.database.writer.read { try LibraryDatabase.tracks($0, playlistId: playlist?.id ?? -1) }) ?? []
                    lines.append("playlist '\(playlist?.name ?? "-")': \(songs.map(\.title)), selection \(String(describing: model.selection))")
                    model.selection = .albums
                    try? await Task.sleep(for: .seconds(1))
                    model.albumPath = [album]
                    try? await Task.sleep(for: .seconds(1.5))
                }
            }
            NSApp.windows.first { $0.isSheet && $0.isVisible }.map { window.endSheet($0) }
            try? await Task.sleep(for: .seconds(1))
            // Narrower window: the About card moves under the header.
            window.setContentSize(NSSize(width: 1000, height: 760))
            try? await Task.sleep(for: .seconds(1.5))
            await snapshot("110d-album-header-narrow", output)
        } else {
            lines.append("Credits button not shown")
        }

        if let karma = untagged.first(where: { $0.title.localizedCaseInsensitiveContains("karma") }),
           let refreshed = try? await model.database.writer.read({ try Track.fetchOne($0, key: karma.id!) }) {
            model.creditsTrack = refreshed
            try? await Task.sleep(for: .seconds(1.5))
            let song = info?.sections(forTrack: refreshed) ?? []
            lines.append("Karma Police credits: \(song.map { "\($0.kind.rawValue): \($0.credits.prefix(3).map(\.name))" })")
            await snapshot("111-song-credits", output)
            model.creditsTrack = nil
        }

        // Artist page: the Wikipedia background, found through the album.
        try? await Task.sleep(for: .seconds(1))
        model.showArtist("Radiohead")
        let artistStart = Date.now
        var artistInfo: ArtistInfo?
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) { window.setContentSize(NSSize(width: 1800, height: 1000)) }
        while Date.now.timeIntervalSince(artistStart) < 30 {
            try? await Task.sleep(for: .seconds(1))
            if let stored = try? await model.database.writer.read({ try LibraryDatabase.artistInfo($0, name: "Radiohead") }) {
                artistInfo = try? JSONDecoder().decode(ArtistInfo.self, from: stored.data)
                break
            }
        }
        try? await Task.sleep(for: .seconds(1.5))
        lines.append("artist: id \(artistInfo?.artistId ?? "-"), about \(artistInfo?.about.map { String($0.summary.prefix(60)) } ?? "none"), photo \(artistInfo?.imageHash ?? "none") from \(artistInfo?.about?.imageURL?.lastPathComponent ?? "-")")
        await snapshot("112-artist-about", output)
        save()
    }

    /// Edits one untagged song and then a whole album through Get Info (fields filled as if typed, saved with Return) and
    /// checks the library.
    private static func getInfoTest(model: AppModel, output: URL) async {
        var lines: [String] = []
        func save() { try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("GETINFO"), atomically: true, encoding: .utf8) }
        func pressReturn() {
            if let sheet = NSApp.windows.first(where: { $0.isSheet && $0.isVisible }),
               let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                            isARepeat: false, keyCode: 36) {
                lines.append("Return handled=\(sheet.performKeyEquivalent(with: event))")
            }
        }
        try? await Task.sleep(for: .seconds(2))
        let all = (try? await model.database.writer.read { try LibraryDatabase.allTracks($0) }) ?? []
        guard let song = all.first(where: { $0.path.contains("/Untagged/") && $0.title.contains("Airbag") }), let songId = song.id else {
            lines.append("skipped: no Untagged fixture")
            return save()
        }

        DebugHitTargets.getInfoPrefill = [.title: "Airbag", .artist: "Radiohead", .album: "OK Computer", .year: "1997",
                                          .trackNumber: "1", .composer: "Radiohead"]
        DebugHitTargets.getInfoLyrics = "[00:10.00]In the next world war"
        model.getInfo([song])
        try? await Task.sleep(for: .seconds(1.5))
        await snapshot("100-get-info-single", output)
        pressReturn()
        try? await Task.sleep(for: .seconds(1.5))
        let edited = try? await model.database.writer.read { try Track.fetchOne($0, key: songId) }
        lines.append("single: \(edited?.title ?? "?") / \(edited?.artist ?? "-") / \(edited?.album ?? "-") / \(edited?.year.map(String.init) ?? "-") / #\(edited?.trackNumber.map(String.init) ?? "-") / composer \(edited?.composer ?? "-") / lyrics \(edited?.lyrics ?? "-") / override \(edited?.metadataOverrides != nil)")

        let albums = (try? await model.database.writer.read { try LibraryDatabase.albums($0) }) ?? []
        if let album = albums.first(where: { $0.title == "Long Player" }) {
            let tracks = await model.tracks(of: .album(album.albumKey))
            DebugHitTargets.getInfoPrefill = [.genre: "Ambient", .year: "2011"]
            DebugHitTargets.getInfoLyrics = nil
            model.getInfo(tracks)
            try? await Task.sleep(for: .seconds(1.5))
            lines.append("album: \(tracks.count) songs, \(DebugHitTargets.getInfoMixed) mixed fields")
            await snapshot("101-get-info-album", output)
            pressReturn()
            try? await Task.sleep(for: .seconds(1.5))
            let after = await model.tracks(of: .album(album.albumKey))
            lines.append("album after: genres \(Set(after.map { $0.genre ?? "-" })), years \(Set(after.map { $0.year ?? 0 })), titles kept \(after.map(\.title).sorted() == tracks.map(\.title).sorted())")
        }
        DebugHitTargets.getInfoPrefill = [:]
        save()
    }

    /// Plays Karma Police (synced lyrics from LRCLIB), opens the lyrics side panel, switches to Up Next and back, then
    /// enlarges the window and opens Now Playing with lyrics to check that it scales up.
    private static func lyricsPanelTest(model: AppModel, output: URL) async {
        var lines: [String] = []
        try? await Task.sleep(for: .seconds(2))
        let tracks = (try? await model.database.writer.read { try LibraryDatabase.allTracks($0) }) ?? []
        guard let index = tracks.firstIndex(where: { $0.title.localizedCaseInsensitiveContains("karma") }),
              let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) else {
            try? "skipped: no Karma Police fixture".write(to: output.appendingPathComponent("LYRICSPANEL"), atomically: true, encoding: .utf8)
            return
        }
        model.play(tracks, startAt: index)
        model.isShowingLyricsPanel = true
        try? await Task.sleep(for: .seconds(1))
        for _ in 0..<15 where !model.metadata.lyricsInFlight.isEmpty { try? await Task.sleep(for: .seconds(1)) }
        model.player.seek(to: 40)
        try? await Task.sleep(for: .seconds(3))
        lines.append("side panel: \(String(describing: model.sidePanel)), lyrics found: \(await model.currentTrack()?.displayLyrics?.isEmpty == false)")
        await snapshot("95-lyrics-side-panel", output)

        model.isShowingQueue = true
        try? await Task.sleep(for: .seconds(1))
        lines.append("after Up Next: \(String(describing: model.sidePanel))")
        // The panel must stay on pushed album pages too.
        if let album = try? await model.database.writer.read({ try LibraryDatabase.albums($0).first }) {
            model.albumPath = [album]
            try? await Task.sleep(for: .seconds(2))
            await snapshot("95b-side-panel-on-album-page", output)
            model.albumPath = []
            try? await Task.sleep(for: .seconds(1))
        }
        model.isShowingLyricsPanel.toggle()
        try? await Task.sleep(for: .seconds(1))
        lines.append("after Lyrics again: \(String(describing: model.sidePanel))")
        model.isShowingLyricsPanel.toggle()
        lines.append("after closing: \(String(describing: model.sidePanel))")

        window.setContentSize(NSSize(width: 2000, height: 1250))
        model.isShowingLyrics = true
        model.isShowingNowPlaying = true
        try? await Task.sleep(for: .seconds(3))
        await snapshot("96-now-playing-large", output)
        model.isShowingNowPlaying = false
        model.player.stop()
        try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("LYRICSPANEL"), atomically: true, encoding: .utf8)
    }

    /// Puts the main window in full screen, opens Now Playing with lyrics, records where the close button sits, closes it
    /// with a click and then with Esc, and leaves full screen.
    private static func fullScreenNowPlayingTest(model: AppModel, output: URL) async {
        var lines: [String] = []
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) else { return }
        window.toggleFullScreen(nil)
        try? await Task.sleep(for: .seconds(3))
        lines.append("full screen: \(window.styleMask.contains(.fullScreen))")
        if let album = try? await model.database.writer.read({ try LibraryDatabase.albums($0).first }) { model.playAlbum(album) }
        model.isShowingLyrics = true
        model.isShowingNowPlaying = true
        try? await Task.sleep(for: .seconds(2))
        let frame = DebugHitTargets.nowPlayingClose
        lines.append("close button top: \(Int(frame.minY)) pt from the top of the window (menu bar reveal strip is about 24 to 40 pt)")
        await snapshot("90-fullscreen-now-playing", output)

        if let height = window.contentView?.bounds.height {
            let point = NSPoint(x: frame.midX, y: height - frame.midY)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
            try? await Task.sleep(for: .seconds(1))
            lines.append("after clicking close: showing=\(model.isShowingNowPlaying)")
        }

        model.isShowingNowPlaying = true
        try? await Task.sleep(for: .seconds(1.5))
        if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                         isARepeat: false, keyCode: 53) {
            let handled = window.performKeyEquivalent(with: escape)
            try? await Task.sleep(for: .seconds(1))
            lines.append("Esc handled=\(handled): showing=\(model.isShowingNowPlaying), still full screen=\(window.styleMask.contains(.fullScreen))")
        }
        model.player.stop()
        window.toggleFullScreen(nil)
        try? await Task.sleep(for: .seconds(2))
        try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("FULLSCREEN-NP"), atomically: true, encoding: .utf8)
    }

    /// Plays an album, picks "Play Next" from another album page's "⋯" menu with a real click, then queues a playlist with
    /// "Add to Up Next", checking the queue order each time.
    private static func queueMenusTest(model: AppModel, output: URL) async {
        var lines: [String] = []
        try? await Task.sleep(for: .seconds(2))
        let albums = (try? await model.database.writer.read { try LibraryDatabase.albums($0) }) ?? []
        guard let playing = albums.first(where: { $0.title == "Hi-Res Sessions" }),
              let other = albums.first(where: { $0.title == "Three Twenty" }),
              let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }),
              let height = window.contentView?.bounds.height else { return }
        func queueTitles() -> String {
            let queue = model.player.queue
            return queue.items.enumerated().map { ($0.offset == queue.currentIndex ? "*" : "") + $0.element.title }.joined(separator: ", ")
        }
        model.playAlbum(playing)
        try? await Task.sleep(for: .seconds(1.5))
        lines.append("playing: \(queueTitles())")

        model.albumPath = [other]
        try? await Task.sleep(for: .seconds(2))
        final class Box: @unchecked Sendable { var menu: NSMenu?; var titles: [String] = [] }
        let box = Box()
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            guard let menu = note.object as? NSMenu, box.menu == nil else { return }
            box.menu = menu
            box.titles = menu.items.map { $0.isSeparatorItem ? "|" : $0.title }
        }
        RunLoop.main.add(Timer(timeInterval: 1.0, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let menu = box.menu else { return }
                if let index = menu.items.firstIndex(where: { $0.title == "Play Next" }) { menu.performActionForItem(at: index) }
                menu.cancelTracking()
            }
        }, forMode: .common)
        let frame = DebugHitTargets.albumMoreMenu
        let point = NSPoint(x: frame.midX, y: height - frame.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
        try? await Task.sleep(for: .seconds(2))
        NotificationCenter.default.removeObserver(observer)
        lines.append("album '⋯' menu: \(box.titles)")
        lines.append("after Play Next '\(other.title)': \(queueTitles())")

        if let playlist = try? model.database.createPlaylist(named: "Queue Test", trackIds: Array(
            ((try? await model.database.writer.read { try LibraryDatabase.allTracks($0) }) ?? []).suffix(2).compactMap(\.id))),
           let id = playlist.id {
            model.enqueue(.playlist(id), next: false)
            try? await Task.sleep(for: .seconds(1))
            lines.append("after Add to Up Next 'Queue Test': \(queueTitles())")
        }
        model.player.stop()
        try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("QUEUEMENUS"), atomically: true, encoding: .utf8)
    }

    /// Creates playlists with every kind of cover (with and without titles, light and dark), shows them, opens one, clicks
    /// its cover for the menu and opens the Edit Playlist sheet.
    private static func coversTest(model: AppModel, output: URL) async {
        var lines: [String] = []
        try? await Task.sleep(for: .seconds(2))
        let tracks = (try? await model.database.writer.read { try LibraryDatabase.allTracks($0) }) ?? []
        let some = Array(tracks.filter { $0.artworkHash != nil }.prefix(8).compactMap(\.id))

        // A custom image: light at the top left, dark at the bottom right.
        let image = NSImage(size: NSSize(width: 600, height: 600), flipped: false) { rect in
            NSGradient(colors: [NSColor(white: 0.95, alpha: 1), NSColor(red: 0.2, green: 0.25, blue: 0.5, alpha: 1)])?.draw(in: rect, angle: -45)
            return true
        }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let imageHash = model.artwork.store(png)

        model.newPlaylist()
        try? await Task.sleep(for: .seconds(0.5))
        let made: [(String, PlaylistCover?)] = [
            ("Morning Coffee", PlaylistCover(kind: .generated(palette: "cream", pattern: "vinyl"), showsTitle: true)),
            ("Late Night Drive", PlaylistCover(kind: .generated(palette: "midnight", pattern: "spectrum"), showsTitle: true)),
            ("Sunlit", imageHash.map { PlaylistCover(kind: .image(hash: $0), showsTitle: true) }),
            ("Album Art Mix", PlaylistCover(kind: .songCovers, showsTitle: true)),
            ("Glow Session", PlaylistCover(kind: .generated(palette: "grape", pattern: "glow"))),
            ("Waves", PlaylistCover(kind: .generated(palette: "teal", pattern: "waves"))),
        ]
        var ids: [String: Int64] = [:]
        for (name, cover) in made {
            if let playlist = try? model.database.createPlaylist(named: name, trackIds: some, cover: cover) { ids[name] = playlist.id }
        }
        if let hash = imageHash {
            lines.append("image title corner brightness \(String(format: "%.2f", await CoverContrast.titleCornerLuminance(hash: hash))) (dark text above 0.55)")
        }
        lines.append("cream title dark: \(CoverPalette.named("cream").titleCornerLuminance > 0.55), midnight title dark: \(CoverPalette.named("midnight").titleCornerLuminance > 0.55)")

        model.selection = .allPlaylists
        try? await Task.sleep(for: .seconds(2.5))
        await snapshot("80-all-playlists-covers", output)

        if let id = ids["Sunlit"] {
            model.selection = .playlist(id)
            try? await Task.sleep(for: .seconds(2))
            await snapshot("81-playlist-page", output)
            // Click the second song's cover (the playlist play target).
            let rows = (try? await model.database.writer.read { try LibraryDatabase.tracks($0, playlistId: id) }) ?? []
            if rows.count > 1, let trackId = rows[1].id, let frame = DebugHitTargets.playCells[trackId],
               let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }),
               let height = window.contentView?.bounds.height {
                let point = NSPoint(x: frame.maxX - 8, y: height - frame.midY)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        window.sendEvent(event)
                    }
                    try? await Task.sleep(for: .milliseconds(60))
                }
                try? await Task.sleep(for: .seconds(1.5))
                lines.append("cover strip click on '\(rows[1].title)' (strip \(Int(frame.width)) pt wide): now playing '\(model.player.current?.title ?? "nil")'")
                await snapshot("81b-playlist-playing", output)

                // Up Next: click the cover of a song further down the queue.
                model.isShowingQueue = true
                try? await Task.sleep(for: .seconds(1.5))
                if rows.count > 3, let nextId = rows[3].id, let rowFrame = DebugHitTargets.queueRows[nextId] {
                    // The cover is the first 36 pt of the row.
                    let coverPoint = NSPoint(x: rowFrame.minX + 18, y: height - rowFrame.midY)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(with: type, location: coverPoint, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                            window.sendEvent(event)
                        }
                        try? await Task.sleep(for: .milliseconds(60))
                    }
                    try? await Task.sleep(for: .seconds(1.5))
                    lines.append("Up Next cover click on '\(rows[3].title)' at \(coverPoint) (row \(rowFrame)): now playing '\(model.player.current?.title ?? "nil")'")
                    await snapshot("81c-up-next", output)
                } else {
                    lines.append("Up Next: row frame not found (rows seen: \(DebugHitTargets.queueRows.count))")
                    await snapshot("81c-up-next", output)
                }
                model.isShowingQueue = false
                model.player.stop()
            }
            // Click the cover: its menu tracks in a nested loop, so a common-modes timer reads and closes it.
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }),
               let height = window.contentView?.bounds.height {
                let frame = DebugHitTargets.playlistCover
                let point = NSPoint(x: frame.midX, y: height - frame.midY)
                // SwiftUI draws this menu's button itself (no NSPopUpButton): catch whichever menu starts tracking.
                final class Box: @unchecked Sendable { var menu: NSMenu?; var titles: [String] = [] }
                let box = Box()
                let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                    guard let menu = note.object as? NSMenu, box.menu == nil else { return }
                    box.menu = menu
                    box.titles = menu.items.map(\.title)
                }
                RunLoop.main.add(Timer(timeInterval: 1.0, repeats: false) { _ in
                    MainActor.assumeIsolated { box.menu?.cancelTracking() }
                }, forMode: .common)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        window.sendEvent(event)
                    }
                    try? await Task.sleep(for: .milliseconds(60))
                }
                try? await Task.sleep(for: .seconds(1.5))
                NotificationCenter.default.removeObserver(observer)
                lines.append("cover click menu: \(box.titles)")
            }
        }
        try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("COVERS"), atomically: true, encoding: .utf8)
    }

    /// Loves three songs, creates a playlist and a smart playlist, shows All Playlists, clicks the playlist's card, then
    /// opens Loved Songs.
    private static func playlistsTest(model: AppModel, output: URL) async {
        var lines: [String] = []
        try? await Task.sleep(for: .seconds(2))
        let tracks = (try? await model.database.writer.read { try LibraryDatabase.allTracks($0) }) ?? []
        for track in tracks.prefix(3) {
            model.toggleLoved(track)
            try? await Task.sleep(for: .milliseconds(200))
        }
        let mix = try? model.database.createPlaylist(named: "Road Trip", trackIds: tracks.dropFirst(5).prefix(6).compactMap(\.id))
        _ = try? model.database.createSmartPlaylist(named: "Jazz", rules: .init(rules: [SmartRule(field: .genre, op: .is, text: "Jazz")]))

        model.selection = .allPlaylists
        try? await Task.sleep(for: .seconds(2))
        await snapshot("70-all-playlists", output)
        lines.append("cards: \(DebugHitTargets.playlistCards.keys.sorted())")

        if let frame = DebugHitTargets.playlistCards["Road Trip"],
           let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }),
           let height = window.contentView?.bounds.height {
            // Click the card's title area (below the cover, away from the hover buttons).
            let point = NSPoint(x: frame.minX + 30, y: height - (frame.maxY - 8))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
            try? await Task.sleep(for: .seconds(1.5))
            lines.append("after clicking Road Trip: selection=\(String(describing: model.selection)) expected=\(String(describing: mix?.id))")
        }

        model.selection = .lovedSongs
        try? await Task.sleep(for: .seconds(2))
        let loved = (try? await model.database.writer.read { try LibraryDatabase.lovedTracks($0) }) ?? []
        lines.append("loved songs (newest first): \(loved.map(\.title))")
        await snapshot("71-loved-songs", output)
        try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("PLAYLISTS"), atomically: true, encoding: .utf8)
    }

    /// Opens the new smart playlist editor, creates "Loved" and "Lossless" smart playlists, opens one, edits it (saving
    /// with Return), then loves a song and checks the playlist follows.
    private static func smartPlaylistTest(model: AppModel, output: URL) async {
        var lines: [String] = []
        func save() { try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("SMART"), atomically: true, encoding: .utf8) }
        try? await Task.sleep(for: .seconds(2))

        model.newSmartPlaylist()
        try? await Task.sleep(for: .seconds(1.5))
        await snapshot("60-new-smart-playlist", output)
        model.smartPlaylistEditor = nil
        try? await Task.sleep(for: .seconds(1))

        func count(_ id: Int64) async -> Int {
            (try? await model.database.writer.read { try LibraryDatabase.tracks($0, playlistId: id) }.count) ?? -1
        }
        guard let loved = Optional(SmartPlaylistTemplate(name: "Loved", rules: .init(rules: [SmartRule(field: .loved, op: .isTrue)]))),
              let lossless = SmartPlaylistTemplate.all.first(where: { $0.name == "Lossless" }),
              let lovedList = try? model.database.createSmartPlaylist(named: loved.name, rules: loved.rules),
              var losslessRules = Optional(lossless.rules) else { return }
        losslessRules.limit = SmartLimit(count: 20, unit: .minutes, selectedBy: .mostRecentlyAdded)
        guard let losslessList = try? model.database.createSmartPlaylist(named: "Lossless, 20 min", rules: losslessRules),
              let lovedId = lovedList.id, let losslessId = losslessList.id else { return }
        lines.append("created: Loved=\(await count(lovedId)) songs, Lossless 20 min=\(await count(losslessId)) songs")

        model.selection = .playlist(losslessId)
        try? await Task.sleep(for: .seconds(2))
        await snapshot("61-smart-playlist-page", output)

        model.editSmartPlaylist(losslessList)
        try? await Task.sleep(for: .seconds(1.5))
        await snapshot("62-edit-smart-playlist", output)
        if let sheet = NSApp.windows.first(where: { $0.isSheet && $0.isVisible }),
           let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                       isARepeat: false, keyCode: 36) {
            lines.append("save via Return handled=\(sheet.performKeyEquivalent(with: down))")
        }
        try? await Task.sleep(for: .seconds(1))
        let reloaded = try? await model.database.writer.read { try Playlist.fetchOne($0, key: losslessId) }
        lines.append("after save: sheet open=\(NSApp.windows.contains { $0.isSheet && $0.isVisible }) rules kept=\(reloaded?.rules == losslessRules)")

        // Live update: love a song.
        model.selection = .playlist(lovedId)
        try? await Task.sleep(for: .seconds(1.5))
        if let track = try? await model.database.writer.read({ try LibraryDatabase.allTracks($0).first }) {
            model.toggleLoved(track)
            try? await Task.sleep(for: .seconds(1.5))
            lines.append("after loving '\(track.title)': Loved=\(await count(lovedId)) songs")
            await snapshot("63-loved-smart-playlist", output)
        }
        save()
    }

    /// Plays an album, opens Now Playing (with lyrics), clicks the album link, then reopens it and clicks the artist link.
    private static func nowPlayingLinksTest(model: AppModel, output: URL) async {
        var lines: [String] = []
        try? await Task.sleep(for: .seconds(2))
        let albums = (try? await model.database.writer.read { try LibraryDatabase.albums($0) }) ?? []
        guard let album = albums.first(where: { $0.title == "Hi-Res Sessions" }),
              let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }),
              let height = window.contentView?.bounds.height else { return }
        model.playAlbum(album)
        for link in ["album", "artist"] {
            model.isShowingLyrics = true
            model.isShowingNowPlaying = true
            try? await Task.sleep(for: .seconds(2))
            if link == "album" { await snapshot("50-now-playing", output) }
            guard let frame = DebugHitTargets.nowPlayingLinks[link] else {
                lines.append("\(link): no frame")
                continue
            }
            let point = NSPoint(x: frame.midX, y: height - frame.midY)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
            try? await Task.sleep(for: .seconds(1.5))
            lines.append("\(link) link: nowPlaying=\(model.isShowingNowPlaying) selection=\(String(describing: model.selection)) artist=\(model.selectedArtist ?? "nil") albumPath=\(model.albumPath.map(\.title))")
            await snapshot("51-after-\(link)-link", output)
        }
        model.player.stop()
        try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("NOWPLAYINGLINKS"), atomically: true, encoding: .utf8)
    }

    /// Opens an album late in the artist list, clicks its artist name and checks that the Artists page opens on it.
    private static func artistLinkTest(model: AppModel, output: URL) async {
        var lines: [String] = []
        try? await Task.sleep(for: .seconds(2))
        let albums = (try? await model.database.writer.read { try LibraryDatabase.albums($0) }) ?? []
        guard let album = albums.last(where: { $0.artist != "Various Artists" }),
              let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }),
              let height = window.contentView?.bounds.height else {
            try? "skipped".write(to: output.appendingPathComponent("ARTISTLINK"), atomically: true, encoding: .utf8)
            return
        }
        model.albumPath = [album]
        try? await Task.sleep(for: .seconds(2))
        await snapshot("30-album-page", output)
        let frame = DebugHitTargets.artistLink
        lines.append("album '\(album.title)' by \(album.artist), link frame \(frame)")
        let point = NSPoint(x: frame.midX, y: height - frame.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
        try? await Task.sleep(for: .seconds(2))
        lines.append("after click: selection=\(String(describing: model.selection)) artist=\(model.selectedArtist ?? "nil") albumPath=\(model.albumPath.count)")
        await snapshot("31-artist-page", output)
        try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("ARTISTLINK"), atomically: true, encoding: .utf8)
    }

    /// Opens Fix Metadata for the untagged fixture files, applies the proposed release with Return, checks the library,
    /// then plays a song and waits for its lyrics. Results go to `METADATA`.
    private static func metadataTest(model: AppModel, output: URL) async {
        var lines: [String] = []
        func save() { try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("METADATA"), atomically: true, encoding: .utf8) }
        func untagged() async -> [Track] {
            (try? await model.database.writer.read { db in
                try Track.fetchAll(db, sql: "SELECT * FROM track WHERE path LIKE ? ORDER BY path", arguments: ["%/Untagged/%"])
            }) ?? []
        }
        var tracks: [Track] = []
        for _ in 0..<20 {
            tracks = await untagged()
            if tracks.count >= 4 { break }
            try? await Task.sleep(for: .seconds(1))
        }
        lines.append("before: " + tracks.map { "\($0.trackNumber.map(String.init) ?? "-") \($0.title) [\($0.displayAlbum)]" }.joined(separator: "; "))
        save()

        model.metadata.review(tracks)
        let start = Date.now
        while Date.now.timeIntervalSince(start) < 60 {
            try? await Task.sleep(for: .seconds(1))
            let state = DebugHitTargets.metadataSheetState
            if state.hasPrefix("ready"), state.contains("loadingCover=false") { break }
            if state.hasPrefix("failed") || state.hasPrefix("noResults") { break }
        }
        lines.append(String(format: "sheet after %.0fs: %@", Date.now.timeIntervalSince(start), DebugHitTargets.metadataSheetState))
        await snapshot("20-fix-metadata", output)
        save()

        // Return triggers the default (Apply) button.
        if let sheet = NSApp.windows.first(where: { $0.isSheet && $0.isVisible }),
           let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                       isARepeat: false, keyCode: 36) {
            let handled = sheet.performKeyEquivalent(with: down)
            if !handled { sheet.sendEvent(down) }
            lines.append("apply via Return: performKeyEquivalent handled=\(handled)")
        } else {
            lines.append("no sheet window found")
        }
        for _ in 0..<20 {
            try? await Task.sleep(for: .seconds(1))
            if !NSApp.windows.contains(where: { $0.isSheet && $0.isVisible }) { break }
        }
        tracks = await untagged()
        lines.append("after: " + tracks.map {
            "\($0.trackNumber.map(String.init) ?? "-")/\($0.trackTotal.map(String.init) ?? "-") \($0.title) [\($0.displayAlbum) \($0.year.map(String.init) ?? "-") \($0.genre ?? "-")] art=\($0.artworkHash != nil) override=\($0.metadataOverrides != nil)"
        }.joined(separator: "; "))
        save()

        // Lyrics: play Karma Police and wait for the lookup started at playback.
        if let index = tracks.firstIndex(where: { $0.title.localizedCaseInsensitiveContains("karma") }) {
            model.play(tracks, startAt: index)
            model.isShowingLyrics = true
            model.isShowingNowPlaying = true
            try? await Task.sleep(for: .seconds(1))
            for _ in 0..<20 where !model.metadata.lyricsInFlight.isEmpty { try? await Task.sleep(for: .seconds(1)) }
            model.player.seek(to: 40)
            try? await Task.sleep(for: .seconds(3))
            let id = tracks[index].id ?? -1
            let karma = try? await model.database.writer.read { db in try Track.fetchOne(db, key: id) }
            let lyrics = karma?.displayLyrics ?? ""
            lines.append("lyrics: \(lyrics.count) chars, synced=\(lyrics.hasPrefix("[")), checked=\(karma?.lyricsCheckedAt != nil), position=\(Int(model.player.currentTime))s")
            await snapshot("21-lyrics", output)
            model.player.stop()
        }
        save()
    }

    private static func snapshot(_ name: String, _ output: URL) async {
        try? name.write(to: output.appendingPathComponent("STEP"), atomically: true, encoding: .utf8)
        if UserDefaults.standard.bool(forKey: "GLDebugTourNoSnapshots") { return }
        for (index, window) in NSApp.windows.enumerated() where window.isVisible && window.frame.width > 200 {
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            let bounds = view.bounds
            if let image = cachedImage(of: view, bounds: bounds),
               let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                let title = window.title.isEmpty ? "window\(index)" : window.title.replacingOccurrences(of: " ", with: "_")
                try? png.write(to: output.appendingPathComponent("\(name)-\(title).png"))
            }
        }
    }

    private static func cachedImage(of view: NSView, bounds: NSRect) -> CGImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return rep.cgImage
    }
}

/// Frames (SwiftUI global space) of on-screen play cells, keyed by track id, for the click test.
@MainActor
enum DebugHitTargets {
    static var playCells: [Int64: CGRect] = [:]
    static var shelfSlider: CGRect = .zero
    static var metadataSheetState = ""
    static var artistLink: CGRect = .zero
    static var menuButtons: [Int64: CGRect] = [:]
    static var nowPlayingLinks: [String: CGRect] = [:]
    static var playlistCards: [String: CGRect] = [:]
    static var playlistCover: CGRect = .zero
    static var queueRows: [Int64: CGRect] = [:]
    static var albumMoreMenu: CGRect = .zero
    static var nowPlayingClose: CGRect = .zero
    static var getInfoPrefill: [GetInfoSheet.Field: String] = [:]
    static var getInfoLyrics: String?
    static var getInfoMixed = 0
    static var creditsButton: CGRect = .zero
    static var creditNames: [String: CGRect] = [:]
    static var shelfPosition: Double = 0
    static var shelfCenterCover: CGPoint = .zero
    static var shelfListOffset: CGFloat = 0
    static var shelfBacksideSettled = false
}

enum LibraryKitQueries {
    static func firstAlbum(_ db: Database) throws -> String? {
        try LibraryDatabase.albums(db, sort: .artist).first?.albumKey
    }

    static func tracks(_ db: Database, albumKey: String) throws -> [Track] {
        try LibraryDatabase.tracks(db, albumKey: albumKey)
    }
}
#endif

