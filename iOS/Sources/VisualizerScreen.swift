import PlayerCore
import SwiftUI
import Visualizers

/// The Mac's visualizers full screen (Bars & Waves, Lights, Ambience, Magnetosphere), drawn from the music playing here.
/// The song's title shows when it changes; a tap shows the controls (style, play or pause, close) for a few seconds, and
/// a swipe sideways changes the style.
struct VisualizerScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("visualizer.style") private var style: VisualizerStyle = .barsAndWaves
    @State private var showsControls = true
    @State private var showsTitle = false
    @State private var hiding: Task<Void, Never>?

    var body: some View {
        ZStack {
            VisualizerView(style: style, analyzer: model.player.controller.analyzer)
                .ignoresSafeArea()
            if showsTitle, let item = model.nowPlaying {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.title.bold())
                    Text("\(item.artist) — \(item.album)").font(.title3).foregroundStyle(.white.opacity(0.75))
                }
                .foregroundStyle(.white)
                .shadow(radius: 10)
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .transition(.opacity)
                .allowsHitTesting(false)
            }
            if showsControls {
                controls
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(.black)
        .environment(\.colorScheme, .dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .contentShape(.rect)
        .onTapGesture { reveal() }
        .gesture(DragGesture(minimumDistance: 40).onEnded { value in
            if abs(value.translation.width) > abs(value.translation.height) { cycle(by: value.translation.width < 0 ? 1 : -1) }
        })
        .onAppear { reveal() }
        .onChange(of: model.nowPlaying?.id, initial: true) { flashTitle() }
    }

    private var controls: some View {
        HStack(spacing: 18) {
            Button { dismiss() } label: { Label("Close", systemImage: "xmark") }
            Menu {
                Picker("Style", selection: $style) {
                    ForEach(VisualizerStyle.allCases) { Text($0.displayName).tag($0) }
                }
            } label: {
                Label(style.displayName, systemImage: "sparkles").labelStyle(.titleAndIcon)
            }
            Button { model.togglePlayPause() } label: {
                Label(model.nowPlaying?.isPlaying == true ? "Pause" : "Play",
                      systemImage: model.nowPlaying?.isPlaying == true ? "pause.fill" : "play.fill")
            }
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func reveal() {
        withAnimation(.easeOut(duration: 0.25)) { showsControls = true }
        hiding?.cancel()
        hiding = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.4)) { showsControls = false }
        }
    }

    private func cycle(by step: Int) {
        let all = VisualizerStyle.allCases
        let index = all.firstIndex(of: style) ?? 0
        style = all[(index + step + all.count) % all.count]
        reveal()
    }

    private func flashTitle() {
        withAnimation(.easeOut(duration: 0.5)) { showsTitle = true }
        Task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation(.easeIn(duration: 0.8)) { showsTitle = false }
        }
    }
}
