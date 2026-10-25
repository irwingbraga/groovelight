import LibraryKit
import SwiftUI

// MARK: - Palettes and patterns

/// Diagonal two-color gradients for generated playlist covers, in the style of the app's placeholder artwork.
struct CoverPalette: Identifiable, Hashable {
    var id: String
    var name: String
    /// Top-left and bottom-right colors (sRGB).
    var top: (Double, Double, Double)
    var bottom: (Double, Double, Double)

    static func == (lhs: CoverPalette, rhs: CoverPalette) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var gradient: LinearGradient {
        LinearGradient(colors: [Color(red: top.0, green: top.1, blue: top.2), Color(red: bottom.0, green: bottom.1, blue: bottom.2)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Brightness of the top-left color, where the title is drawn.
    var titleCornerLuminance: Double { luma(top.0, top.1, top.2) }

    static let all: [CoverPalette] = [
        .init(id: "sunset", name: "Sunset", top: (0.98, 0.58, 0.28), bottom: (0.52, 0.09, 0.24)),
        .init(id: "rose", name: "Rose", top: (1.00, 0.45, 0.60), bottom: (0.50, 0.07, 0.25)),
        .init(id: "grape", name: "Grape", top: (0.76, 0.46, 0.96), bottom: (0.18, 0.05, 0.34)),
        .init(id: "ocean", name: "Ocean", top: (0.26, 0.56, 0.98), bottom: (0.04, 0.09, 0.33)),
        .init(id: "teal", name: "Teal", top: (0.36, 0.90, 0.84), bottom: (0.04, 0.19, 0.29)),
        .init(id: "forest", name: "Forest", top: (0.46, 0.86, 0.55), bottom: (0.04, 0.24, 0.14)),
        .init(id: "gold", name: "Gold", top: (0.96, 0.80, 0.34), bottom: (0.38, 0.23, 0.04)),
        .init(id: "ember", name: "Ember", top: (0.95, 0.35, 0.20), bottom: (0.20, 0.03, 0.03)),
        .init(id: "slate", name: "Slate", top: (0.74, 0.79, 0.88), bottom: (0.19, 0.24, 0.34)),
        .init(id: "midnight", name: "Midnight", top: (0.32, 0.32, 0.48), bottom: (0.03, 0.03, 0.08)),
        .init(id: "mint", name: "Mint", top: (0.86, 0.98, 0.84), bottom: (0.48, 0.80, 0.62)),
        .init(id: "cream", name: "Cream", top: (0.99, 0.96, 0.88), bottom: (0.84, 0.77, 0.66)),
    ]

    static func named(_ id: String) -> CoverPalette { all.first { $0.id == id } ?? all[0] }

    /// A stable palette for a seed (playlists created before covers existed).
    static func forSeed(_ seed: Int64) -> CoverPalette { all[Int(UInt64(bitPattern: seed &* 2_654_435_761) % UInt64(all.count))] }
}

/// Decorations drawn over a palette, in the spirit of the app: records, the spectrum visualizer, light and sound waves.
enum CoverPattern: String, CaseIterable, Identifiable {
    case none, vinyl, spectrum, glow, waves

    var id: String { rawValue }
    var name: String {
        switch self {
        case .none: "Gradient"
        case .vinyl: "Vinyl"
        case .spectrum: "Spectrum"
        case .glow: "Glow"
        case .waves: "Waves"
        }
    }
}

struct CoverPatternView: View {
    var pattern: CoverPattern

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            switch pattern {
            case .none:
                break
            case .vinyl:
                // A record peeking from the bottom right corner: grooves and a label.
                let center = CGPoint(x: size.width * 0.82, y: size.height * 0.82)
                for index in 0..<16 {
                    let radius = side * (0.16 + Double(index) * 0.045)
                    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                    context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(index.isMultiple(of: 4) ? 0.16 : 0.08)), lineWidth: side * 0.006)
                }
                let label = side * 0.12
                context.fill(Path(ellipseIn: CGRect(x: center.x - label, y: center.y - label, width: label * 2, height: label * 2)),
                             with: .color(.white.opacity(0.22)))
            case .spectrum:
                // Visualizer bars along the bottom.
                let count = 14
                let gap = side * 0.012
                let width = (size.width - gap * Double(count + 1)) / Double(count)
                for index in 0..<count {
                    let level = 0.25 + 0.55 * abs(sin(Double(index) * 1.7 + 0.6)) * (1 - Double(index) / Double(count) * 0.4)
                    let height = size.height * 0.45 * level
                    let rect = CGRect(x: gap + Double(index) * (width + gap), y: size.height - height - gap, width: width, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: width * 0.25), with: .color(.white.opacity(0.22)))
                }
            case .glow:
                // Soft light from the bottom right, like the old visualizers.
                let center = CGPoint(x: size.width * 0.78, y: size.height * 0.8)
                context.fill(Path(CGRect(origin: .zero, size: size)),
                             with: .radialGradient(Gradient(colors: [.white.opacity(0.45), .white.opacity(0)]), center: center,
                                                   startRadius: 0, endRadius: side * 0.65))
            case .waves:
                for index in 0..<6 {
                    var path = Path()
                    let baseline = size.height * (0.55 + Double(index) * 0.075)
                    let amplitude = side * (0.05 + Double(index) * 0.006)
                    path.move(to: CGPoint(x: 0, y: baseline))
                    for x in stride(from: 0.0, through: size.width, by: 2) {
                        path.addLine(to: CGPoint(x: x, y: baseline + sin(x / size.width * .pi * 3 + Double(index) * 0.5) * amplitude))
                    }
                    context.stroke(path, with: .color(.white.opacity(0.18)), lineWidth: side * 0.008)
                }
            }
        }
    }
}

/// Perceived brightness (Rec. 709 luma on the sRGB values, 0 to 1), to choose black or white text.
func luma(_ r: Double, _ g: Double, _ b: Double) -> Double {
    0.2126 * r + 0.7152 * g + 0.0722 * b
}

// MARK: - Cover view

/// A playlist's cover as made on the Mac (a generated design, an image, or its songs' covers), with its name in the top
/// left corner unless an image cover was set without it.
struct PlaylistCoverView: View {
    let name: String
    let cover: PlaylistCover?
    /// Covers of the playlist's songs, for `songCovers` (and when no cover was chosen).
    let songHashes: [String]
    /// Picks a stable palette for playlists without a cover and songs.
    let seed: Int64
    var isSmart = false
    var cornerRadius: CGFloat = 10
    /// Small covers (list rows) leave the name out: it is beside them.
    var hidesTitle = false

    var body: some View {
        let kind = cover?.kind ?? (songHashes.isEmpty ? .generated(palette: CoverPalette.forSeed(seed).id, pattern: "none") : .songCovers)
        let showsTitle: Bool = {
            guard !hidesTitle else { return false }
            guard let cover, case .image = cover.kind else { return true }
            return cover.showsTitle
        }()
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack(alignment: .topLeading) {
                switch kind {
                case let .generated(paletteId, patternId):
                    let palette = CoverPalette.named(paletteId)
                    Rectangle().fill(palette.gradient)
                    CoverPatternView(pattern: CoverPattern(rawValue: patternId) ?? .none)
                    if showsTitle { CoverTitle(name: name, side: side, isDark: palette.titleCornerLuminance > 0.55) }
                case let .image(hash):
                    Cover(hash: hash, corner: 0, large: true)
                    if showsTitle { CoverTitle(name: name, side: side, isDark: false) }
                case .songCovers:
                    SongCoversMosaic(hashes: songHashes)
                    if showsTitle { CoverTitle(name: name, side: side, isDark: false) }
                }
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay(alignment: .topTrailing) {
            if isSmart, !showsTitle {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.45), in: .circle)
                    .padding(4)
            }
        }
    }
}

/// Up to four covers of a playlist's songs (one when there are fewer than four).
struct SongCoversMosaic: View {
    let hashes: [String]

    var body: some View {
        if hashes.count >= 4 {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    Cover(hash: hashes[0], corner: 0)
                    Cover(hash: hashes[1], corner: 0)
                }
                GridRow {
                    Cover(hash: hashes[2], corner: 0)
                    Cover(hash: hashes[3], corner: 0)
                }
            }
        } else {
            Cover(hash: hashes.first, corner: 0, large: true)
        }
    }
}

/// The playlist name in the top left corner, sized to the cover: dark on light corners, light on dark ones, with a faint
/// shadow of the other tone so it stays legible on images.
private struct CoverTitle: View {
    let name: String
    let side: CGFloat
    let isDark: Bool

    var body: some View {
        Text(name)
            .font(.system(size: max(9, side * 0.105), weight: .heavy))
            .tracking(-0.3)
            .lineLimit(3)
            .minimumScaleFactor(0.6)
            .multilineTextAlignment(.leading)
            .foregroundStyle(isDark ? Color.black.opacity(0.82) : .white)
            .shadow(color: (isDark ? Color.white : Color.black).opacity(0.35), radius: side * 0.02)
            .padding(side * 0.075)
            .frame(maxWidth: side * 0.92, alignment: .topLeading)
            .allowsHitTesting(false)
    }
}

extension PlaylistSummary {
    /// Its cover as the Mac made it.
    func coverView(hidesTitle: Bool = false, cornerRadius: CGFloat = 10) -> PlaylistCoverView {
        PlaylistCoverView(name: playlist.name, cover: playlist.coverStyle, songHashes: artworkHashes, seed: id, isSmart: playlist.isSmart,
                          cornerRadius: cornerRadius, hidesTitle: hidesTitle)
    }
}
