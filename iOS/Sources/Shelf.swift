import LibraryKit
import SwiftUI

/// The Shelf: the Mac's Cover Flow, as on the first iPhone's iPod app. Tilted covers on a glossy black floor; drag
/// (or the scrubber) to move along them, tap a side cover to bring it to the middle, tap the middle one to flip it over
/// to its songs, pinch to change the size of the covers.
struct ShelfContent: View {
    @Environment(AppModel.self) private var model
    /// The fractional index of the cover in the middle, animated through `CoverFlowEffect` so covers turn continuously.
    @State private var position: Double = 0
    @State private var dragStart: Double?
    @State private var flippedKey: String?
    @AppStorage("shelf.coverSize") private var chosenSize: Double = 260
    @State private var pinchStart: Double?
    @State private var size = CGSize.zero
    /// The player bar floating over the page's bottom (iPad): the scrubber sits above it.
    @Environment(\.playerBarInset) private var barInset
    /// The height the shelf has, above the bar.
    private var height: CGFloat { size.height - barInset }
    private let visibleRadius = 7

    var body: some View {
        let albums = model.library.contents.albums
        let center = Int(position.rounded()).clamped(0, max(albums.count - 1, 0))
        ZStack {
            LinearGradient(colors: [.black, Color(white: 0.06), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            if albums.isEmpty {
                Text("No albums yet").foregroundStyle(.white.opacity(0.6))
            } else {
                ZStack {
                    ForEach(visible(center, count: albums.count), id: \.self) { index in
                        let album = albums[index]
                        CoverFlowItem(album: album, size: coverSize, isFlipped: flippedKey == album.albumKey) { flipBack() }
                            .modifier(CoverFlowEffect(position: position, index: Double(index), coverSize: coverSize,
                                                      spread: flippedKey == nil ? 0 : 1))
                            .zIndex(-abs(Double(index) - position))
                            .onTapGesture { if flippedKey != album.albumKey { tapped(index, albums: albums) } }
                    }
                }
                .frame(width: size.width, height: coverSize * 1.6)
                .position(x: size.width / 2, y: height * 0.42)

                VStack(spacing: 4) {
                    Text(albums[center].title).font(.headline)
                    Text(albums[center].artist).font(.subheadline).foregroundStyle(.white.opacity(0.65))
                }
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: size.width * 0.8)
                .position(x: size.width / 2, y: height * 0.42 + coverSize * 0.62 + 28)

                // Scrubs while dragged, then springs to the nearest album, so the shelf never rests between two covers.
                Slider(value: Binding(get: { position }, set: { flippedKey = nil; position = $0 }),
                       in: 0...Double(max(albums.count - 1, 1))) { editing in
                    if !editing { DispatchQueue.main.async { snap(count: albums.count) } }
                }
                .tint(.white.opacity(0.7))
                .frame(width: min(size.width * 0.7, 520))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
                .position(x: size.width / 2, y: height - 44)
            }
        }
        .contentShape(.rect)
        .gesture(drag(count: albums.count), including: flippedKey == nil ? .all : .subviews)
        .simultaneousGesture(MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? chosenSize
                pinchStart = start
                chosenSize = min(max(start * value.magnification, 140), 420)
            }
            .onEnded { _ in pinchStart = nil })
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(by: -1, count: albums.count); return .handled }
        .onKeyPress(.rightArrow) { move(by: 1, count: albums.count); return .handled }
        .onKeyPress(.escape) {
            guard flippedKey != nil else { return .ignored }
            flipBack()
            return .handled
        }
        .onChange(of: albums.count) { position = min(position, Double(max(albums.count - 1, 0))) }
        .toolbarBackground(.hidden, for: .navigationBar)
        .environment(\.colorScheme, .dark)
        .navigationTitle("Shelf")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The chosen size, smaller when the window is too short (or narrow) for it.
    private var coverSize: CGFloat {
        guard height > 0 else { return chosenSize }
        let fitting = min((height * 0.58 - 110) / 0.62, size.width * 0.62)
        return min(chosenSize, max(fitting, 120))
    }

    private func visible(_ center: Int, count: Int) -> [Int] {
        guard count > 0 else { return [] }
        return Array(max(0, center - visibleRadius)...min(count - 1, center + visibleRadius))
    }

    private func flipBack() {
        withAnimation(.spring(duration: 0.6, bounce: 0.15)) { flippedKey = nil }
    }

    private func snap(count: Int) {
        guard count > 0 else { return }
        withAnimation(.spring(duration: 0.4, bounce: 0.1)) { position = Double(Int(position.rounded()).clamped(0, count - 1)) }
    }

    private func tapped(_ index: Int, albums: [AlbumSummary]) {
        if position != position.rounded() || index != Int(position.rounded()) {
            flippedKey = nil
            withAnimation(.spring(duration: 0.5, bounce: 0.1)) { position = Double(index) }
            return
        }
        withAnimation(.spring(duration: 0.6, bounce: 0.15)) { flippedKey = albums[index].albumKey }
    }

    private func move(by delta: Int, count: Int) {
        guard count > 0 else { return }
        flippedKey = nil
        withAnimation(.spring(duration: 0.35, bounce: 0.05)) {
            position = Double((Int(position.rounded()) + delta).clamped(0, count - 1))
        }
    }

    private func drag(count: Int) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = position
                    flippedKey = nil
                }
                let spacing = Double(coverSize) * 0.28
                position = ((dragStart ?? 0) - value.translation.width / spacing).clamped(-0.4, Double(count) - 0.6)
            }
            .onEnded { value in
                let spacing = Double(coverSize) * 0.28
                let projected = (dragStart ?? 0) - value.predictedEndTranslation.width / spacing
                dragStart = nil
                withAnimation(.spring(duration: 0.55, bounce: 0.1)) {
                    position = Double(Int(projected.rounded()).clamped(0, max(count - 1, 0)))
                }
            }
    }
}

/// Places a cover by its distance from the (animated) middle: flat in the middle, turned 60 degrees on the sides.
struct CoverFlowEffect: ViewModifier, Animatable {
    var position: Double
    var index: Double
    var coverSize: CGFloat
    /// 0 normally, 1 while the middle cover is flipped: its neighbors slide out to give the songs room.
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
        return content
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), anchor: .center, perspective: 0.45)
            .scaleEffect(1 - min(distance, 1) * 0.12)
            .offset(x: x)
            .brightness(-min(distance, 4) * 0.06)
    }
}

/// One cover with its reflection; turned over, its songs. The front turns away to 90 degrees, then the back turns in,
/// so at rest the songs have no 3D transform and take taps and scrolling.
struct CoverFlowItem: View {
    let album: AlbumSummary
    let size: CGFloat
    let isFlipped: Bool
    let flipBack: () -> Void
    @State private var frontAngle: Double = 0
    @State private var backAngle: Double = -90
    @State private var showsBack = false

    var body: some View {
        ZStack {
            Cover(hash: album.artworkHash, size: size, corner: 2, large: true)
                .rotation3DEffect(.degrees(frontAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .opacity(frontAngle < 90 ? 1 : 0)
            if showsBack {
                AlbumBackside(album: album, flipBack: flipBack)
                    .allowsHitTesting(backAngle == 0)
                    .rotation3DEffect(.degrees(backAngle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                    .opacity(backAngle > -90 ? 1 : 0)
            }
        }
        .frame(width: size, height: size)
        .background(alignment: .top) {
            // The reflection on the floor, outside the layout so it does not move the cover.
            Cover(hash: album.artworkHash, size: size, corner: 2)
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
                    withAnimation(.spring(duration: 0.35, bounce: 0.2)) { backAngle = 0 }
                }
            } else {
                withAnimation(.easeIn(duration: 0.16)) { backAngle = -90 } completion: {
                    showsBack = false
                    withAnimation(.spring(duration: 0.35, bounce: 0.2)) { frontAngle = 0 }
                }
            }
        }
    }
}

/// The back of a flipped cover: the album's songs (a tap plays from there), Play, and back to the cover.
struct AlbumBackside: View {
    @Environment(AppModel.self) private var model
    let album: AlbumSummary
    let flipBack: () -> Void

    var body: some View {
        let tracks = model.library.read { try LibraryDatabase.tracks($0, albumKey: album.albumKey) } ?? []
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading) {
                    Text(album.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { model.play(tracks) } label: { Label("Play Album", systemImage: "play.fill") }
                Button(action: flipBack) { Label("Show Cover", systemImage: "arrow.uturn.backward") }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .padding(10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        Button { model.play(tracks, startAt: index) } label: {
                            SongRow(track: track, showsNumber: true, isCurrent: model.currentSongId == track.id)
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        // Opaque: the neighboring covers must not show through.
        .background(Color(white: 0.11))
        .clipShape(.rect(cornerRadius: 4))
    }
}

extension Comparable {
    func clamped(_ low: Self, _ high: Self) -> Self { min(max(self, low), high) }
}
