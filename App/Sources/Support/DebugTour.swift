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

