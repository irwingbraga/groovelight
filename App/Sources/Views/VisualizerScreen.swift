import AppKit
import PlayerCore
import SwiftUI
import Visualizers

/// Standalone visualizer window (Cmd+T), meant to go full screen like the iTunes visualizer.
///
/// Controls live in the same floating glass pill as the main window's player bar and fade out after a few seconds
/// without mouse movement (the cursor hides too while in full screen).
struct VisualizerScreen: View {
    @Environment(AppModel.self) private var model
    @AppStorage("visualizer.style") private var style: VisualizerStyle = .barsAndWaves
    @State private var showControls = true
    @State private var isHoveringControls = false
    @State private var showTitle = false
    @State private var hideTask: Task<Void, Never>?
    @State private var window: NSWindow?
    @State private var isFullScreen = false

    var body: some View {
        ZStack {
            VisualizerView(style: style, analyzer: model.player.analyzer)
                .ignoresSafeArea()

            // Track title fades in on every song change (top left, clear of the controls).
            if showTitle, let item = model.player.current {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.system(size: 28, weight: .bold))
                    Text("\(item.artist) — \(item.album)").font(.system(size: 18)).foregroundStyle(.white.opacity(0.75))
                }
                .foregroundStyle(.white)
                .shadow(radius: 10)
                .padding(.horizontal, 40)
                .padding(.top, isFullScreen ? 40 : 56)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .transition(.opacity)
                .allowsHitTesting(false)
            }

            if showControls {
                VisualizerControls(style: $style, isFullScreen: isFullScreen, toggleFullScreen: toggleFullScreen)
                    .onHover { hovering in
                        isHoveringControls = hovering
                        if !hovering { scheduleHide() }
                    }
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(.black)
        .background(WindowReader(window: $window))
        .environment(\.colorScheme, .dark)
        .onContinuousHover { _ in revealControls() }
        .onAppear { revealControls() }
        .onChange(of: style) { revealControls() }
        .onChange(of: model.player.current?.id, initial: true) { flashTitle() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            if (note.object as? NSWindow) === window { isFullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if (note.object as? NSWindow) === window { isFullScreen = false }
        }
        .onKeyPress(.space) {
            model.player.togglePlayPause()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            cycleStyle(by: 1)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            cycleStyle(by: -1)
            return .handled
        }
        .onKeyPress("f") {
            toggleFullScreen()
            return .handled
        }
        .onKeyPress(.escape) {
            guard isFullScreen else { return .ignored }
            toggleFullScreen()
            return .handled
        }
        .focusable()
        .focusEffectDisabled()
    }

    private func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    private func cycleStyle(by offset: Int) {
        let all = VisualizerStyle.allCases
        let index = all.firstIndex(of: style) ?? 0
        style = all[(index + offset + all.count) % all.count]
    }

    private func revealControls() {
        if !showControls {
            withAnimation(.smooth(duration: 0.25)) { showControls = true }
        }
        NSCursor.unhide()
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, !isHoveringControls else { return }
            withAnimation(.smooth(duration: 0.6)) { showControls = false }
            if isFullScreen { NSCursor.setHiddenUntilMouseMoves(true) }
        }
    }

    private func flashTitle() {
        withAnimation(.easeOut(duration: 0.8)) { showTitle = true }
        Task {
            try? await Task.sleep(for: .seconds(5))
            withAnimation(.easeIn(duration: 1.2)) { showTitle = false }
        }
    }
}

/// The floating glass pill: style picker, transport, current track, volume and full screen.
private struct VisualizerControls: View {
    @Binding var style: VisualizerStyle
    var isFullScreen: Bool
    var toggleFullScreen: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        HStack(spacing: 16) {
            Menu {
                Picker("Visualizer", selection: $style) {
                    ForEach(VisualizerStyle.allCases) { candidate in
                        Label(candidate.displayName, systemImage: candidate.symbol).tag(candidate)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(style.displayName, systemImage: style.symbol)
                    .font(.system(size: 13, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help("Visualizer style (← →)")

            Divider().frame(height: 26)

            HStack(spacing: 14) {
                BarButton(systemImage: "backward.fill", help: "Previous", size: 15) { player.previous() }
                BarButton(systemImage: player.state == .playing ? "pause.fill" : "play.fill",
                          help: player.state == .playing ? "Pause" : "Play", size: 20) {
                    player.togglePlayPause()
                }
                .frame(width: 26)
                BarButton(systemImage: "forward.fill", help: "Next", size: 15) { player.next() }
            }

            if let item = player.current {
                HStack(spacing: 10) {
                    ArtworkImage(hash: item.artworkHash, size: .small, cornerRadius: 5)
                        .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.system(size: 12, weight: .semibold))
                        Text(item.artist)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: 200, alignment: .leading)
                }
            }

            Divider().frame(height: 26)

            HStack(spacing: 10) {
                VolumePopoverButton()
                BarButton(systemImage: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                          help: isFullScreen ? "Exit Full Screen (F)" : "Full Screen (F)") {
                    toggleFullScreen()
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .fixedSize(horizontal: true, vertical: false)
        .playerBarBackground()
    }
}

extension VisualizerStyle {
    var symbol: String {
        switch self {
        case .barsAndWaves: "chart.bar.fill"
        case .lights: "light.max"
        case .ambience: "hurricane"
        case .magnetosphere: "atom"
        }
    }
}

/// Hands the hosting `NSWindow` to SwiftUI.
struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = { window = $0 }
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
