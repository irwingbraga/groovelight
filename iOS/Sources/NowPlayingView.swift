import MediaPlayer
import PlayerCore
import SwiftUI
import Visualizers

/// Now Playing, as on the Mac: the cover's colors drifting behind, the cover (or a visualizer) with the song, "artist —
/// album" (each opening its page) and its quality, the transport and the volume; the Mac's round glass buttons at the
/// top (visualizer, lyrics, options, close), and this device's own under the controls (love, AirPlay, Play On, Up
/// Next). The lyrics or Up Next take the cover's place where the window is tall, and sit beside it where it is wide. On
/// iOS 27.1 an arrangement view keeps each on one side of the iPhone Duo's fold.
struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    let item: NowPlayingItem
    let close: () -> Void
    @State private var panel: NowPlayingPanel? = Self.debugPanel
    @State private var isWide = false
    @State private var isShowingEqualizer = false
    @State private var isShowingVisualizerScreen = false
    /// The visualizer in the cover's place, as on the Mac (`-GLDebugOpenVisualizer YES` at launch).
    @State private var showsVisualizer = UserDefaults.standard.bool(forKey: "GLDebugOpenVisualizer")
    /// How far it is pulled down: past a point, or flicked, it closes (a full-screen cover has no swipe of its own).
    /// (`-GLDebugNowPlayingPull <points>` opens it pulled that far, for layout checks.)
    @State private var pull = CGFloat(UserDefaults.standard.double(forKey: "GLDebugNowPlayingPull"))
    /// How far the cover is swiped sideways: past a point, or flicked, the next song (left) or the previous one (right).
    @State private var swipe: CGFloat = 0
    /// Where the cover is, to tell a swipe on it from a pull.
    @State private var coverFrame = CGRect.zero
    /// Which way the drag went first: sideways on the cover swipes it, otherwise it pulls Now Playing down.
    @State private var dragAxis: Axis?
    @State private var skips = 0

    /// `-GLDebugNowPlayingPanel lyrics|upNext` opens Now Playing on that panel, for layout checks.
    private static var debugPanel: NowPlayingPanel? {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "GLDebugNowPlayingPanel") {
        case "lyrics": return .lyrics
        case "upNext": return .upNext
        default: return nil
        }
        #else
        return nil
        #endif
    }

    var body: some View {
        content
            .padding(.horizontal, 24)
            .padding(.top, 64)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height && $0.size.width >= 640 } action: { isWide = $0 }
            .environment(\.coverSwipe, swipe)
            .onPreferenceChange(CoverFrameKey.self) { coverFrame = $0 }
            .background { AnimatedArtworkBackdrop(hash: item.artworkHash) }
            .overlay(alignment: .topTrailing) {
                NowPlayingTopButtons(panel: $panel, showsVisualizer: $showsVisualizer, isShowingEqualizer: $isShowingEqualizer,
                                     isShowingVisualizerScreen: $isShowingVisualizerScreen, close: close)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            .offset(y: pull)
            // Below what it covers: the page shows behind it as it is pulled down.
            .presentationBackground(.clear)
            // Lower than the scrubber, the volume and the lists' scrolling, which keep their drags.
            .gesture(DragGesture(minimumDistance: 20, coordinateSpace: .global)
                .onChanged { drag in
                    if dragAxis == nil {
                        let sideways = abs(drag.translation.width) > abs(drag.translation.height)
                        dragAxis = sideways && pull == 0 && coverFrame.contains(drag.startLocation) ? .horizontal : .vertical
                    }
                    if dragAxis == .horizontal { swipe = drag.translation.width; return }
                    guard drag.translation.height > 0 || pull > 0 else { return }
                    guard pull > 0 || drag.translation.height > abs(drag.translation.width) else { return }
                    pull = max(0, drag.translation.height)
                }
                .onEnded { drag in
                    defer { dragAxis = nil }
                    if dragAxis == .horizontal { return endSwipe(drag) }
                    if pull > 0, drag.translation.height > 160 || drag.predictedEndTranslation.height > 500 {
                        close()
                    } else {
                        withAnimation(.spring(duration: 0.3)) { pull = 0 }
                    }
                })
            .sensoryFeedback(.impact(weight: .light), trigger: skips)
            .fullScreenCover(isPresented: $isShowingVisualizerScreen) { VisualizerScreen() }
            .sheet(isPresented: $isShowingEqualizer) {
                NavigationStack {
                    EqualizerScreen()
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { isShowingEqualizer = false } } }
                }
            }
            // Playing elsewhere: no analyzer to draw from here.
            .onChange(of: model.isRemote) { _, remote in if remote { showsVisualizer = false } }
    }

    /// Far enough or flicked: the cover goes off that side, the song changes (as the buttons: right restarts a song
    /// more than 3 s in) and its cover comes in from the other side. Otherwise it springs back.
    private func endSwipe(_ drag: DragGesture.Value) {
        let width = drag.translation.width
        let flung = drag.predictedEndTranslation.width
        guard abs(width) > 100 || (abs(flung) > 300 && (flung < 0) == (width < 0)) else {
            withAnimation(.spring(duration: 0.3)) { swipe = 0 }
            return
        }
        let forward = width < 0
        let away = (coverFrame.width + 48) * (forward ? -1 : 1)
        withAnimation(.easeIn(duration: 0.15)) { swipe = away } completion: {
            forward ? model.next() : model.previous()
            skips += 1
            swipe = -away
            // A frame later, so the jump to the other side is not animated with the way back.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(16))
                withAnimation(.spring(duration: 0.35, bounce: 0.15)) { swipe = 0 }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if isWide {
            wide
        } else if let panel {
            // A phone: the panel takes the cover's place, under the song.
            VStack(spacing: 16) {
                SongHeader(item: item)
                Group {
                    switch panel {
                    case .lyrics: LyricsPanel(item: item, fontSize: 24)
                    case .upNext: UpNextPanel()
                    }
                }
                .frame(maxHeight: .infinity)
                Controls(item: item, panel: $panel)
            }
            .frame(maxWidth: 640)
            .transition(.opacity)
        } else {
            CoverAndControls(item: item, panel: $panel, showsVisualizer: showsVisualizer)
                .transition(.opacity)
        }
    }

    /// Side by side. On iOS 27.1 an arrangement view keeps each on one side of the iPhone Duo's fold.
    @ViewBuilder private var wide: some View {
        let side = Group {
            switch panel ?? .lyrics {
            case .lyrics: LyricsPanel(item: item)
            case .upNext: UpNextPanel()
            }
        }
        if #available(iOS 27.1, *) {
            ArrangementView {
                CoverAndControls(item: item, panel: $panel, showsVisualizer: showsVisualizer)
            } secondary: {
                side
            }
            .arrangementViewStyle(.split.axes(.horizontal))
        } else {
            HStack(spacing: 48) {
                CoverAndControls(item: item, panel: $panel, showsVisualizer: showsVisualizer).frame(minWidth: 320)
                side.frame(minWidth: 280)
            }
        }
    }
}

/// The Mac's buttons over Now Playing, round and clear glass: the visualizer (in the cover's place, with its style
/// beside while on), the lyrics, this device's options, and close.
private struct NowPlayingTopButtons: View {
    @Environment(AppModel.self) private var model
    @Binding var panel: NowPlayingPanel?
    @Binding var showsVisualizer: Bool
    @Binding var isShowingEqualizer: Bool
    @Binding var isShowingVisualizerScreen: Bool
    let close: () -> Void
    @AppStorage("visualizer.style") private var style: VisualizerStyle = .barsAndWaves

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if showsVisualizer {
                    Menu {
                        Picker("Style", selection: $style) {
                            ForEach(VisualizerStyle.allCases) { Text($0.displayName).tag($0) }
                        }
                    } label: {
                        Label(style.displayName, systemImage: "sparkles")
                    }
                    .transition(.opacity)
                }
                Button {
                    withAnimation(.smooth) { showsVisualizer.toggle() }
                } label: {
                    Label("Visualizer", systemImage: "waveform")
                }
                .disabled(model.isRemote)
                Button {
                    withAnimation(.smooth) { panel = panel == .lyrics ? nil : .lyrics }
                } label: {
                    Label("Lyrics", systemImage: panel == .lyrics ? "quote.bubble.fill" : "quote.bubble")
                }
                .accessibilityAddTraits(panel == .lyrics ? .isSelected : [])
                PlaybackOptionsMenu(isShowingEqualizer: $isShowingEqualizer, isShowingVisualizer: $isShowingVisualizerScreen)
                Button(action: close) { Label("Close", systemImage: "chevron.down") }
            }
            .labelStyle(GlassCircleLabelStyle())
            .buttonStyle(.plain)
        }
    }
}

/// An icon in a circle of glass, the same for buttons and menus (a menu does not take the glass button style).
private struct GlassCircleLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.icon
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 44, height: 44)
            .contentShape(.circle)
            .glassEffect(.regular.interactive(), in: .circle)
    }
}

/// The Mac's backdrop: the cover, large and blurred, slowly drifting and turning on black, as Apple Music's animated
/// backgrounds.
struct AnimatedArtworkBackdrop: View {
    var hash: String?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Color.black
                Cover(hash: hash, corner: 0)
                    .scaleEffect(2.2)
                    .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 360) * 4))
                    .offset(x: sin(t / 7) * 120, y: cos(t / 9) * 80)
                    .blur(radius: 90)
                    .opacity(0.9)
                Cover(hash: hash, corner: 0)
                    .scaleEffect(1.6)
                    .rotationEffect(.degrees(-t.truncatingRemainder(dividingBy: 360) * 3))
                    .offset(x: cos(t / 6) * 160, y: sin(t / 8) * 100)
                    .blur(radius: 70)
                    .opacity(0.6)
                    .blendMode(.plusLighter)
                Color.black.opacity(0.35)
            }
        }
        .drawingGroup()
        .ignoresSafeArea()
    }
}

/// Speed, the sleep timer and the equalizer, for the music playing here.
struct PlaybackOptionsMenu: View {
    @Environment(AppModel.self) private var model
    @Binding var isShowingEqualizer: Bool
    @Binding var isShowingVisualizer: Bool

    var body: some View {
        let player = model.player
        Menu {
            Picker(selection: Binding(get: { player.speed }, set: { player.speed = $0 })) {
                ForEach(PlayerStore.speeds, id: \.self) { Text(PlayerStore.speedLabel($0)).tag($0) }
            } label: {
                Label("Speed: \(PlayerStore.speedLabel(player.speed))", systemImage: "gauge.with.dots.needle.33percent")
            }
            .pickerStyle(.menu)
            Picker(selection: Binding(get: { player.sleepTimer.mode }, set: { mode in
                if let mode { player.sleepTimer.start(mode) } else { player.sleepTimer.cancel() }
            })) {
                Text("Off").tag(SleepTimer.Mode?.none)
                ForEach(SleepTimer.choices, id: \.self) { Text("\($0) Minutes").tag(SleepTimer.Mode?.some(.minutes($0))) }
                Text("End of This Song").tag(SleepTimer.Mode?.some(.endOfSong))
            } label: {
                Label(player.sleepTimer.summary ?? "Sleep Timer", systemImage: "moon.zzz")
            }
            .pickerStyle(.menu)
            Button("Equalizer", systemImage: "slider.vertical.3") { isShowingEqualizer = true }
            Button("Visualizer", systemImage: "sparkles") { isShowingVisualizer = true }
        } label: {
            Label("Options", systemImage: player.sleepTimer.isActive ? "moon.zzz.fill" : "ellipsis")
        }
        // These are this device's: the Mac and other devices keep their own.
        .disabled(model.isRemote)
    }
}

/// The cover (or the visualizer), the song, and the controls (kept clear of the fold). The cover shrinks a little while
/// paused, as on the Mac.
struct CoverAndControls: View {
    @Environment(AppModel.self) private var model
    let item: NowPlayingItem
    @Binding var panel: NowPlayingPanel?
    var showsVisualizer = false
    @AppStorage("visualizer.style") private var style: VisualizerStyle = .barsAndWaves
    @Environment(\.coverSwipe) private var swipe

    var body: some View {
        VStack(spacing: 24) {
            Group {
                if showsVisualizer {
                    VisualizerView(style: style, analyzer: model.player.controller.analyzer)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 14))
                } else {
                    Cover(hash: item.artworkHash, corner: 14, large: true)
                        .scaleEffect(item.isPlaying ? 1 : 0.92)
                        .animation(.spring(duration: 0.5, bounce: 0.25), value: item.isPlaying)
                }
            }
            .frame(maxWidth: 460)
            .shadow(color: .black.opacity(0.45), radius: 30, y: 18)
            .background { if !showsVisualizer { GeometryReader { Color.clear.preference(key: CoverFrameKey.self, value: $0.frame(in: .global)) } } }
            .offset(x: swipe)
            .opacity(1 - min(abs(swipe) / 600, 0.6))
            SongTitle(item: item)
            Controls(item: item, panel: $panel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The title, "artist — album" (each opening its page), its quality, and where it plays when not here.
struct SongTitle: View {
    @Environment(AppModel.self) private var model
    let item: NowPlayingItem

    var body: some View {
        VStack(spacing: 4) {
            Text(item.title).font(.title2.bold()).lineLimit(1)
            SongLinks(item: item)
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7))
            if let spec = item.spec { QualityLabel(spec: spec).padding(.top, 4) }
            if model.isRemote {
                Label("Playing on \(model.targetName)", systemImage: "hifispeaker.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
                    .padding(.top, 4)
                if model.remote.skipped > 0 {
                    Text(model.remote.skipped == 1 ? "1 song is not on \(model.targetName): skipped"
                         : "\(model.remote.skipped) songs are not on \(model.targetName): skipped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// "Artist — Album", each part opening its page (here, or on the Mac) and closing Now Playing, as on the Mac.
struct SongLinks: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window
    let item: NowPlayingItem
    var alignment: HorizontalAlignment = .center
    /// Kept on one line, shortened (the player bar, the mini player).
    var oneLine = false

    var body: some View {
        let artist = model.artistRoute(of: item)
        let album = model.albumRoute(of: item)
        let line = HStack(spacing: 4) {
            link(item.artist, route: artist)
            Text("—")
            link(item.album, route: album)
        }
        if oneLine {
            line
        } else {
            ViewThatFits(in: .horizontal) {
                line
                // Too long for one line: one under the other.
                VStack(alignment: alignment, spacing: 2) {
                    link(item.artist, route: artist)
                    link(item.album, route: album)
                }
            }
        }
    }

    @ViewBuilder private func link(_ text: String, route: LibraryRoute?) -> some View {
        if let route {
            Button(text) { window.show(route) }
                .buttonStyle(.plain)
                .lineLimit(1)
                .accessibilityHint("Opens its page")
        } else {
            Text(text).lineLimit(1)
        }
    }
}

/// A small cover beside the song, above a panel that took the cover's place.
struct SongHeader: View {
    @Environment(AppModel.self) private var model
    let item: NowPlayingItem

    var body: some View {
        HStack(spacing: 12) {
            Cover(hash: item.artworkHash, size: 60, corner: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.headline).lineLimit(1)
                SongLinks(item: item, alignment: .leading).font(.subheadline).foregroundStyle(.white.opacity(0.7))
                if model.isRemote {
                    Label("Playing on \(model.targetName)", systemImage: "hifispeaker.fill").font(.caption).foregroundStyle(.tint)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Where the song is, the transport, the Mac's volume when it plays there, and the buttons under them.
struct Controls: View {
    @Environment(AppModel.self) private var model
    let item: NowPlayingItem
    @Binding var panel: NowPlayingPanel?

    var body: some View {
        VStack(spacing: 20) {
            Scrubber()
            TransportControls(isPlaying: item.isPlaying)
            // The Mac's level while it plays (a phone's own buttons set its level), this device's otherwise.
            if model.target == .mac { RemoteVolume() } else if model.target == .thisDevice { SystemVolume() }
            NowPlayingButtons(panel: $panel)
        }
        .frame(maxWidth: 460)
    }
}

/// Where the song is, dragged to seek: the Mac's thin bar, thicker while dragged, with the times under it.
struct Scrubber: View {
    @Environment(AppModel.self) private var model
    @State private var dragging: Double?

    var body: some View {
        let duration = max(model.duration, 1)
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let time = min(dragging ?? model.time(at: context.date), duration)
            VStack(spacing: 6) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2))
                        Capsule().fill(.white.opacity(0.8)).frame(width: geometry.size.width * time / duration)
                    }
                    .frame(height: dragging == nil ? 5 : 9)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { drag in dragging = min(max(drag.location.x / geometry.size.width, 0), 1) * duration }
                        .onEnded { drag in
                            model.seek(to: min(max(drag.location.x / geometry.size.width, 0), 1) * duration)
                            dragging = nil
                        })
                    .animation(.snappy(duration: 0.15), value: dragging == nil)
                }
                .frame(height: 24)
                HStack {
                    Text(Self.format(time))
                    Spacer()
                    Text("-" + Self.format(max(duration - time, 0)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            }
            .accessibilityElement()
            .accessibilityLabel("Position")
            .accessibilityValue("\(Self.format(time)) of \(Self.format(duration))")
            .accessibilityAdjustableAction { direction in
                model.seek(to: min(max(time + (direction == .increment ? 10 : -10), 0), duration))
            }
        }
    }

    static func format(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}

/// Shuffle, Previous, Play or Pause, Next and Repeat, as on the Mac (the space bar plays and pauses, from a keyboard).
/// When a fold crosses the row (iPhone Duo partly folded in landscape), the buttons part on either side of it instead
/// of one landing in it.
struct TransportControls: View {
    @Environment(AppModel.self) private var model
    let isPlaying: Bool

    var body: some View {
        FoldAwareRow {
            ModeButton(title: model.isShuffled ? "Shuffle On" : "Shuffle Off", systemImage: "shuffle", isOn: model.isShuffled) {
                model.toggleShuffle()
            }
            Button { model.previous() } label: { Label("Previous", systemImage: "backward.fill") }
            Button { model.togglePlayPause() } label: {
                Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            .font(.system(size: 44))
            Button { model.next() } label: { Label("Next", systemImage: "forward.fill") }
            ModeButton(title: model.repeatMode == .off ? "Repeat Off" : model.repeatMode == .one ? "Repeat One" : "Repeat All",
                       systemImage: model.repeatMode == .one ? "repeat.1" : "repeat", isOn: model.repeatMode != .off) {
                model.cycleRepeat()
            }
        }
        .padding(.horizontal, 24)
        .labelStyle(.iconOnly)
        .font(.system(size: 28))
        .buttonStyle(.plain)
    }
}

/// Shuffle or Repeat beside the transport: bright on a light circle while on, dimmed while off.
private struct ModeButton: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(isOn ? .white : .white.opacity(0.55))
                .frame(width: 36, height: 36)
                .background(Circle().fill(.white.opacity(isOn ? 0.2 : 0)))
                .contentShape(.circle)
        }
    }
}

/// The Mac's volume, while music plays there (a phone's own buttons set its level, as this device's do here).
struct RemoteVolume: View {
    @Environment(AppModel.self) private var model
    @State private var dragging: Double?
    @State private var lastSent = Date.distantPast

    var body: some View {
        let volume = dragging ?? model.remote.state?.volume ?? 1
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
            Slider(value: Binding(get: { volume }, set: { value in
                dragging = value
                // Followed as it is dragged, a few times a second.
                if Date.now.timeIntervalSince(lastSent) > 0.15 {
                    lastSent = .now
                    model.remote.send(.volume(value))
                }
            }), in: 0...1) { editing in
                if !editing, let dragging {
                    model.remote.send(.volume(dragging))
                    self.dragging = nil
                }
            }
            .accessibilityLabel("Volume on \(model.targetName)")
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.7))
        .tint(.white)
    }
}

/// This device's volume, as the Mac's Now Playing has its own: the system's slider (the buttons on the side move it
/// too).
struct SystemVolume: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
            VolumeSlider().frame(height: 34)
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.7))
    }
}

private struct VolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.tintColor = .white
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {}
}

/// Where Now Playing's cover is on screen, for its swipe; zero while it is not shown.
private struct CoverFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

extension EnvironmentValues {
    /// How far Now Playing's cover is swiped sideways.
    @Entry var coverSwipe: CGFloat = 0
}
