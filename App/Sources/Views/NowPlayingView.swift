import AppKit
import LibraryKit
import MetadataKit
import PlayerCore
import Skins
import SwiftUI
import Visualizers

/// Full-window player: blurred artwork backdrop, big cover (or a visualizer), controls and lyrics.
struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @State private var track: Track?
    @State private var showVisualizer = false
    @AppStorage("visualizer.style") private var visualizerStyle: VisualizerStyle = .barsAndWaves
    @State private var window: NSWindow?
    @State private var isFullScreen = false
    @AppStorage(NowPlayingSkin.storageKey) private var skin: NowPlayingSkin = .cover

    var body: some View {
        let player = model.player
        let hash = player.current?.artworkHash
        Group {
            if skin != .cover {
                // The whole window is the turntable, the cassette deck or the CD player.
                NowPlayingDeck(chromeInset: isFullScreen ? 96 : 60)
            } else {
                cover(player: player, hash: hash)
            }
        }
        .overlay(alignment: .topTrailing) {
            GlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    if showVisualizer && skin == .cover {
                        Picker("Style", selection: $visualizerStyle) {
                            ForEach(VisualizerStyle.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                    SkinMenu(isDeck: skin != .cover)
                        .buttonBorderShape(.circle)
                    if skin == .cover {
                        Button {
                            withAnimation(.smooth) { showVisualizer.toggle() }
                        } label: {
                            Image(systemName: "waveform").frame(width: 20, height: 20)
                        }
                        .buttonBorderShape(.circle)
                        .help("Visualizer" + model.shortcuts.hint(.visualizer))
                    }
                    Button {
                        withAnimation(.smooth) { model.isShowingLyrics.toggle() }
                    } label: {
                        Image(systemName: "quote.bubble").frame(width: 20, height: 20)
                    }
                    .buttonBorderShape(.circle)
                    .help("Lyrics" + model.shortcuts.hint(.lyrics))
                    Button {
                        withAnimation(.smooth) { model.isShowingNowPlaying = false }
                    } label: {
                        Image(systemName: "chevron.down").frame(width: 20, height: 20)
                    }
                    .buttonBorderShape(.circle)
                    .keyboardShortcut(.escape, modifiers: [])
                    .help("Close (Esc)")
                    #if DEBUG
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { DebugHitTargets.nowPlayingClose = $0 }
                    #endif
                }
                .modifier(NowPlayingButtonsStyle(isDeck: skin != .cover))
            }
            // In full screen the top of the screen reveals the menu bar and title bar when the pointer gets close, and
            // that overlay covered these buttons, so they could not be clicked: keep them below it.
            .padding(.top, isFullScreen ? 52 : 12)
            .padding(.trailing, 16)
        }
        .background(WindowReader(window: $window))
        .onChange(of: window, initial: true) { _, window in
            isFullScreen = window?.styleMask.contains(.fullScreen) ?? false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            if (note.object as? NSWindow) === window { isFullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if (note.object as? NSWindow) === window { isFullScreen = false }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        // Song details for the quality line and the artist / album links (lyrics load in `CurrentLyrics`).
        .task(id: player.current?.id) { track = await model.currentTrack() }
    }

    /// The cover (or a visualizer) on the cover's colors, the song, the transport and the lyrics beside.
    private func cover(player: PlaybackController, hash: String?) -> some View {
        GeometryReader { geometry in
            // Grows with big windows and full screen (1 at a 1100 x 760 window, up to 1.9x), so the cover, text and
            // controls do not sit small in the middle of a large display.
            let scale = min(max(min(geometry.size.width / 1100, geometry.size.height / 760), 1), 1.9)
            // Leave room for title, transport and volume under the cover.
            let side = max(200, min(460 * scale, geometry.size.height - 315 * scale,
                                    geometry.size.width - (model.isShowingLyrics ? 480 * scale : 80)))
            ZStack {
                AnimatedArtworkBackdrop(hash: hash)

                HStack(spacing: 48 * scale) {
                    VStack(spacing: 24 * scale) {
                        Group {
                            if showVisualizer {
                                VisualizerView(style: visualizerStyle, analyzer: player.analyzer)
                                    .clipShape(.rect(cornerRadius: 14))
                                    .shadow(color: .black.opacity(0.45), radius: 30, y: 18)
                            } else {
                                // The cover (a player chosen in its place takes the whole window).
                                NowPlayingArtwork()
                            }
                        }
                        .frame(width: side, height: side)

                        VStack(spacing: 4) {
                            Text(player.current?.title ?? "Not Playing")
                                .font(.system(size: 22 * scale, weight: .bold))
                            NowPlayingSubtitle(item: player.current, track: track?.id == player.current?.id ? track : nil)
                                .font(.system(size: 16 * scale))
                                .foregroundStyle(.white.opacity(0.7))
                            // Summarized quality: badge + resolution, click for full technical details.
                            if let track, track.id == player.current?.id {
                                AudioQualityButton(track: track)
                                    .font(.system(size: 12 * scale, weight: .medium).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.6))
                                    .padding(.top, 4)
                            }
                        }
                        .lineLimit(1)
                        .frame(width: max(side, 360 * scale))

                        BigTransport(scale: scale)
                            .frame(width: max(side, 360 * scale))
                    }

                    if model.isShowingLyrics {
                        // Same height as the cover + transport column so both read as one centered unit.
                        CurrentLyrics(fontSize: 24 * scale)
                            .frame(width: 380 * scale, height: side + 190 * scale)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 40)
                .padding(.top, 50)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// "Artist — Album" under the title; each part opens its page (closing Now Playing).
private struct NowPlayingSubtitle: View {
    var item: PlayableItem?
    /// The library track of `item`, once loaded; links need its album key and artist page.
    var track: Track?
    @Environment(AppModel.self) private var model

    var body: some View {
        if let item {
            HStack(spacing: 6) {
                LinkText(text: item.artist, help: "Go to \(item.artist)", action: track?.artistPageName.map { name in
                    { close { model.showArtist(name) } }
                })
                #if DEBUG
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { DebugHitTargets.nowPlayingLinks["artist"] = $0 }
                #endif
                Text("—")
                LinkText(text: item.album, help: "Go to \(item.album)", action: track.map { track in
                    { close { model.showAlbum(albumKey: track.albumKey) } }
                })
                #if DEBUG
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { DebugHitTargets.nowPlayingLinks["album"] = $0 }
                #endif
            }
        }
    }

    private func close(then navigate: @escaping () -> Void) {
        withAnimation(.smooth) { model.isShowingNowPlaying = false }
        navigate()
    }
}

/// Large blurred artwork that slowly drifts, like Apple Music's animated backgrounds.
struct AnimatedArtworkBackdrop: View {
    var hash: String?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Color.black
                ArtworkImage(hash: hash, size: .small, cornerRadius: 0)
                    .scaleEffect(2.2)
                    .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 360) * 4))
                    .offset(x: sin(t / 7) * 120, y: cos(t / 9) * 80)
                    .blur(radius: 90)
                    .opacity(0.9)
                ArtworkImage(hash: hash, size: .small, cornerRadius: 0)
                    .scaleEffect(1.6)
                    .rotationEffect(.degrees(-t.truncatingRemainder(dividingBy: 360) * 3))
                    .offset(x: cos(t / 6) * 160, y: sin(t / 8) * 100)
                    .blur(radius: 70)
                    .opacity(0.6)
                    .blendMode(.plusLighter)
                Color.black.opacity(0.35)
            }
        }
        .ignoresSafeArea()
        .drawingGroup()
    }
}

/// Shuffle or Repeat beside Now Playing's transport, as in the player bar: bright on a light circle while on, dimmed
/// while off.
private struct NowPlayingModeButton: View {
    var systemImage: String
    var help: String
    var isOn: Bool
    var scale: CGFloat
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17 * scale, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.white.opacity(isOn ? 1 : 0.55))
                .frame(width: 34 * scale, height: 34 * scale)
                .background(Circle().fill(.white.opacity(isOn ? 0.2 : 0)))
                .contentShape(.circle)
        }
        .help(help)
    }
}

struct BigTransport: View {
    var scale: CGFloat = 1
    @Environment(AppModel.self) private var model
    @State private var scrubValue: Double?

    var body: some View {
        @Bindable var player = model.player
        VStack(spacing: 16 * scale) {
            VStack(spacing: 4) {
                ScrubBar(value: scrubValue ?? player.currentTime, duration: max(player.duration, 1), isActive: true) { value, done in
                    if done {
                        player.seek(to: value)
                        scrubValue = nil
                    } else {
                        scrubValue = value
                    }
                }
                .frame(height: 14 * scale)
                HStack {
                    Text(formatDuration(scrubValue ?? player.currentTime))
                    Spacer()
                    Text("-" + formatDuration(max(0, player.duration - (scrubValue ?? player.currentTime))))
                }
                .font(.system(size: 11 * scale).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            }

            HStack(spacing: 36 * scale) {
                NowPlayingModeButton(systemImage: "shuffle", help: "Shuffle" + model.shortcuts.hint(.shuffle), isOn: player.isShuffled,
                                     scale: scale) {
                    player.setShuffle(!player.isShuffled)
                }
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 40 * scale))
                        .contentTransition(.symbolEffect(.replace))
                }
                Button { player.next() } label: { Image(systemName: "forward.fill") }
                NowPlayingModeButton(systemImage: player.repeatMode == .one ? "repeat.1" : "repeat",
                                     help: "Repeat" + model.shortcuts.hint(.cycleRepeat), isOn: player.repeatMode != .off, scale: scale) {
                    player.repeatMode = switch player.repeatMode {
                    case .off: .all
                    case .all: .one
                    case .one: .off
                    }
                }
            }
            .font(.system(size: 28 * scale))
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").font(.caption)
                Slider(value: $player.volume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill").font(.caption)
            }
            .foregroundStyle(.white.opacity(0.7))
            .tint(.white)
        }
    }
}

