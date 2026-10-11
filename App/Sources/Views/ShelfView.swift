import AppKit
import LibraryKit
import SwiftUI

/// Cover Flow, as on the first iPhone iPod app and iTunes 7: tilted covers on a glossy black floor.
/// Click the center cover to flip it over and see its tracks.
struct ShelfView: View {
    @Environment(AppModel.self) private var model
    @State private var albums: [AlbumSummary] = []
    /// Fractional index of the cover in the center. Animated through `CoverFlowEffect` so covers rotate continuously.
    @State private var position: Double = 0
    @State private var dragStart: Double?
    @State private var flippedKey: String?
    /// True once the flip animation has settled: the interactive track list is then shown in an untransformed overlay.
    @State private var isBacksideSettled = false
    @State private var scrollAccumulator: Double = 0
    @FocusState private var isFocused: Bool

    private let coverSize: CGFloat = 300
    private let visibleRadius = 9

    var body: some View {
        GeometryReader { geometry in
            let centerIndex = Int(position.rounded()).clamped(0, max(albums.count - 1, 0))
            ZStack {
                LinearGradient(colors: [.black, Color(white: 0.06), .black], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                if albums.isEmpty {
                    Text("No albums yet")
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    ZStack {
                        ForEach(visibleIndices(centerIndex), id: \.self) { index in
                            let album = albums[index]
                            let isFlipped = flippedKey == album.albumKey
                            CoverFlowItem(album: album, size: coverSize, isFlipped: isFlipped, onFlipBack: flipBack,
                                          onBackSettled: { settled in
                                              isBacksideSettled = settled
                                              #if DEBUG
                                              DebugHitTargets.shelfBacksideSettled = settled
                                              #endif
                                          })
                                .modifier(CoverFlowEffect(position: position, index: Double(index), coverSize: coverSize,
                                                          spread: flippedKey == nil ? 0 : 1))
                                .zIndex(-abs(Double(index) - position))
                                // A flipped cover is a track list: clicks there belong to its rows, not to the shelf.
                                .onTapGesture { if !isFlipped { tapped(index) } }
                        }
                    }
                    .frame(width: geometry.size.width, height: coverSize * 1.6)
                    .position(x: geometry.size.width / 2, y: geometry.size.height * 0.45)

                    // The interactive back of the flipped cover lives here, outside the Cover Flow transforms (3D
                    // rotation, scale, offset): AppKit routes scroll wheel events to the list's NSScrollView by its
                    // own hit testing, which does not see through those transforms, so the list could not scroll.
                    if isBacksideSettled, let key = flippedKey, let album = albums.first(where: { $0.albumKey == key }) {
                        AlbumBackside(album: album, onFlipBack: flipBack)
                            .frame(width: coverSize, height: coverSize)
                            .position(x: geometry.size.width / 2, y: geometry.size.height * 0.45)
                            .zIndex(1)
                    }

                    VStack(spacing: 4) {
                        Text(albums[centerIndex].title)
                            .font(.system(size: 17, weight: .semibold))
                        Text(albums[centerIndex].artist)
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: geometry.size.width * 0.6)
                    .position(x: geometry.size.width / 2, y: geometry.size.height * 0.45 + coverSize * 0.62 + 30)

                    // Scrubs continuously while dragging, then springs to the nearest album on release, so the
                    // shelf never rests between two covers.
                    Slider(value: Binding(get: { position }, set: { newValue in
                        flippedKey = nil
                        position = newValue
                    }), in: 0...Double(max(albums.count - 1, 1))) { isEditing in
                        if !isEditing {
                            // Next turn of the run loop: the final drag value can land after the editing-ended callback.
                            DispatchQueue.main.async { snapToNearestAlbum() }
                        }
                    }
                    .controlSize(.small)
                    .tint(.white.opacity(0.7))
                    #if DEBUG
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { DebugHitTargets.shelfSlider = $0 }
                    #endif
                    .frame(width: min(geometry.size.width * 0.5, 520))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .position(x: geometry.size.width / 2, y: geometry.size.height - 40)
                }
            }
            .contentShape(.rect)
            // While a cover is flipped, scrolling and dragging go to its track list instead of moving the shelf.
            .gesture(drag(width: geometry.size.width), including: flippedKey == nil ? .all : .subviews)
            .overlay {
                if flippedKey == nil {
                    ScrollWheelCatcher { delta, ended in scrolled(delta, ended: ended) }
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.escape) {
            guard flippedKey != nil else { return .ignored }
            flipBack()
            return .handled
        }
        .onKeyPress(.leftArrow) { move(by: -1); return .handled }
        .onKeyPress(.rightArrow) { move(by: 1); return .handled }
        .onKeyPress(.return) {
            if let album = albums[safe: Int(position.rounded())] { model.playAlbum(album) }
            return .handled
        }
        .onAppear { isFocused = true }
        .navigationTitle("Shelf")
        #if DEBUG
        .onChange(of: position, initial: true) { DebugHitTargets.shelfPosition = position }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            // Center cover position, matching `.position(x: width / 2, y: height * 0.45)` above.
            DebugHitTargets.shelfCenterCover = CGPoint(x: frame.midX, y: frame.minY + frame.height * 0.45)
        }
        #endif
        .observing(model.database, id: 0, { try LibraryDatabase.albums($0, sort: .artist) }) { value in
            albums = value
            position = min(position, Double(max(value.count - 1, 0)))
        }
    }

    private func visibleIndices(_ center: Int) -> [Int] {
        guard !albums.isEmpty else { return [] }
        return Array(max(0, center - visibleRadius)...min(albums.count - 1, center + visibleRadius))
    }

    private func flipBack() {
        withAnimation(.spring(duration: 0.6, bounce: 0.15)) { flippedKey = nil }
    }

    private func snapToNearestAlbum() {
        guard !albums.isEmpty else { return }
        let target = Double(Int(position.rounded()).clamped(0, albums.count - 1))
        guard target != position else { return }
        withAnimation(.spring(duration: 0.4, bounce: 0.1)) { position = target }
    }

    private func tapped(_ index: Int) {
        let album = albums[index]
        // Still between two covers (mid-animation or interrupted scrub): settle first, flip on the next click.
        if position != position.rounded() {
            flippedKey = nil
            withAnimation(.spring(duration: 0.4, bounce: 0.1)) { position = Double(index) }
            return
        }
        if index == Int(position.rounded()) {
            withAnimation(.spring(duration: 0.6, bounce: 0.15)) {
                flippedKey = flippedKey == album.albumKey ? nil : album.albumKey
            }
        } else {
            flippedKey = nil
            withAnimation(.spring(duration: 0.5, bounce: 0.1)) { position = Double(index) }
        }
    }

    private func move(by delta: Int) {
        guard !albums.isEmpty else { return }
        flippedKey = nil
        let target = (Int(position.rounded()) + delta).clamped(0, albums.count - 1)
        withAnimation(.spring(duration: 0.35, bounce: 0.05)) { position = Double(target) }
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = position
                    flippedKey = nil
                }
                let spacing = Double(coverSize) * 0.28
                position = ((dragStart ?? 0) - value.translation.width / spacing).clamped(-0.4, Double(albums.count) - 0.6)
            }
            .onEnded { value in
                let spacing = Double(coverSize) * 0.28
                let projected = (dragStart ?? 0) - value.predictedEndTranslation.width / spacing
                dragStart = nil
                let target = Int(projected.rounded()).clamped(0, max(albums.count - 1, 0))
                withAnimation(.spring(duration: 0.55, bounce: 0.1)) { position = Double(target) }
            }
    }

    private func scrolled(_ delta: CGFloat, ended: Bool) {
        guard !albums.isEmpty else { return }
        if ended {
            let target = Int(position.rounded()).clamped(0, albums.count - 1)
            withAnimation(.spring(duration: 0.4, bounce: 0.1)) { position = Double(target) }
            return
        }
        flippedKey = nil
        position = (position - Double(delta) / 60).clamped(-0.4, Double(albums.count) - 0.6)
    }
}

/// Places a cover by its distance from the (animated) center position: flat in the middle, tilted 60 degrees on the sides.
struct CoverFlowEffect: ViewModifier, Animatable {
    var position: Double
    var index: Double
    var coverSize: CGFloat
    /// 0 normally, 1 while the center cover is flipped: neighbors slide out to give the track list room.
    var spread: Double = 0

    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(position, spread) }
        set {
            position = newValue.first
            spread = newValue.second
        }
    }

    func body(content: Content) -> some View {
        let offset = index - position
        let distance = abs(offset)
        let side: Double = offset < 0 ? -1 : 1
        let centerGap = Double(coverSize) * (0.62 + 0.3 * spread)
        let sideSpacing = Double(coverSize) * 0.28
        let x: Double = distance < 1 ? offset * centerGap : side * (centerGap + (distance - 1) * sideSpacing)
        let angle: Double = distance < 1 ? -offset * 60 : -side * 60
        let scale = 1 - min(distance, 1) * 0.12

        return content
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), anchor: .center, perspective: 0.45)
            .scaleEffect(scale)
            .offset(x: x)
            .brightness(-min(distance, 4) * 0.06)
    }
}

/// One cover with its mirrored reflection. Flips to the track list when selected.
///
/// The flip runs in two phases: the front turns away to 90 degrees, then the back turns in from -90 to 0. At rest the
/// track list therefore has no 3D transform at all; a back face resting at 180 + 180 degrees drew correctly but did not
/// receive clicks or scrolling.
struct CoverFlowItem: View {
    var album: AlbumSummary
    var size: CGFloat
    var isFlipped: Bool
    var onFlipBack: () -> Void
    /// Reports when the back face has finished turning in (true) or starts turning away (false).
    var onBackSettled: (Bool) -> Void
    @State private var frontAngle: Double = 0
    @State private var backAngle: Double = -90
    @State private var showsBack = false

    var body: some View {
        ZStack {
            ArtworkImage(hash: album.artworkHash, size: .large, cornerRadius: 2)
                .rotation3DEffect(.degrees(frontAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .opacity(frontAngle < 90 ? 1 : 0)
            // Built only while flipped, so the covers around the center do not each load a track list.
            if showsBack {
                // Animation only; the interactive copy is overlaid by ShelfView once the flip settles.
                AlbumBackside(album: album, onFlipBack: onFlipBack)
                    .allowsHitTesting(false)
                    .rotation3DEffect(.degrees(backAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                    .opacity(backAngle > -90 ? 1 : 0)
            }
        }
        .frame(width: size, height: size)
        .background(alignment: .top) {
            // Reflection on the glossy floor, outside the layout bounds so it does not shift the cover.
            ArtworkImage(hash: album.artworkHash, size: .small, cornerRadius: 2)
                .frame(width: size, height: size)
                .scaleEffect(x: 1, y: -1)
                .mask(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.45)))
                .offset(y: size + 2)
                .opacity(showsBack ? 0 : 1)
                .allowsHitTesting(false)
        }
        .onChange(of: isFlipped) { _, flipped in
            if flipped {
                showsBack = true
                withAnimation(.easeIn(duration: 0.16)) { frontAngle = 90 } completion: {
                    withAnimation(.spring(duration: 0.35, bounce: 0.2)) { backAngle = 0 } completion: {
                        if isFlipped { onBackSettled(true) }
                    }
                }
            } else {
                onBackSettled(false)
                withAnimation(.easeIn(duration: 0.16)) { backAngle = -90 } completion: {
                    showsBack = false
                    withAnimation(.spring(duration: 0.35, bounce: 0.2)) { frontAngle = 0 }
                }
            }
        }
    }
}

/// Back of the flipped cover: the album's tracks with the same rows (hover play strip, double-click, context menu,
/// drag to playlist) as the album page, in a compact density.
struct AlbumBackside: View {
    var album: AlbumSummary
    var onFlipBack: () -> Void
    @Environment(AppModel.self) private var model
    @State private var tracks: [Track] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading) {
                    Text(album.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(album.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { model.play(tracks) } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("Play Album")
                Button(action: onFlipBack) { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("Show Cover (Esc)")
            }
            .padding(10)
            Divider()
            ScrollView {
                TrackList(tracks: tracks, style: .album, isCompact: true, albumKey: album.albumKey)
                    .padding(.vertical, 4)
            }
            #if DEBUG
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                DebugHitTargets.shelfListOffset = offset
            }
            #endif
            .scrollIndicators(.automatic)
        }
        // Opaque: the neighboring covers must not show through the list.
        .background(Color(white: 0.11))
        .clipShape(.rect(cornerRadius: 4))
        .environment(\.colorScheme, .dark)
        .task(id: album.albumKey) {
            tracks = (try? await model.database.writer.read { [key = album.albumKey] in try LibraryDatabase.tracks($0, albumKey: key) }) ?? []
        }
    }
}

/// Captures trackpad / mouse wheel scrolling, which SwiftUI does not expose on macOS.
struct ScrollWheelCatcher: NSViewRepresentable {
    var onScroll: (CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat, Bool) -> Void)?

        override func scrollWheel(with event: NSEvent) {
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : -event.scrollingDeltaY
            let ended = event.phase == .ended || event.momentumPhase == .ended
            if event.momentumPhase == .changed || event.phase == .changed || (event.phase == [] && event.momentumPhase == []) {
                onScroll?(event.hasPreciseScrollingDeltas ? delta : delta * 12, false)
                if event.phase == [] && event.momentumPhase == [] { onScroll?(0, true) }
            } else if ended && (event.momentumPhase == .ended || event.momentumPhase == []) {
                onScroll?(0, true)
            }
        }

        // Let clicks fall through to the SwiftUI covers underneath.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, event.type == .scrollWheel else { return nil }
            return super.hitTest(point)
        }
    }
}

extension Comparable {
    func clamped(_ lower: Self, _ upper: Self) -> Self { min(max(self, lower), upper) }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
