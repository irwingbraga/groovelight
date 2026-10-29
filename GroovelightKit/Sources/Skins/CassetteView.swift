import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Where a cassette's own pictures are on disk (`CassetteStore.url(of:in:)`), and a number that changes with them.
public struct CassettePictures: Hashable, Sendable {
    public var shell: URL?
    public var label: URL?
    public var revision: Int

    public init(shell: URL? = nil, label: URL? = nil, revision: Int = 0) {
        self.shell = shell
        self.label = label
        self.revision = revision
    }
}

extension CassetteStore {
    public func pictures(of design: CassetteDesign) -> CassettePictures {
        CassettePictures(shell: url(of: .shell, in: design), label: url(of: .label, in: design), revision: revision)
    }
}

/// A cassette from the front, in a square: the reels turn as the tape goes from the left one to the right one over
/// the song (the right one turning slower as it fills, the tape moving at one speed), behind the design's shell and
/// label, or behind the user's picture of them.
struct CassetteView<Artwork: View>: View {
    var design: CassetteDesign
    var pictures: CassettePictures
    var playback: SkinPlayback
    var date: Date
    @ViewBuilder var artwork: () -> Artwork

    var body: some View {
        GeometryReader { geometry in
            let geometryOfDesign = design.resolvedGeometry
            let width = min(geometry.size.width, geometry.size.height * geometryOfDesign.aspectRatio)
            let height = width / geometryOfDesign.aspectRatio
            CassetteFace(design: design, pictures: pictures, playback: playback, date: date, artwork: artwork)
                .frame(width: width, height: height)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}

/// The cassette at its own size (the editor's preview draws it too).
public struct CassetteFace<Artwork: View>: View {
    var design: CassetteDesign
    var pictures: CassettePictures
    var playback: SkinPlayback
    var date: Date
    @ViewBuilder var artwork: () -> Artwork

    public init(design: CassetteDesign, pictures: CassettePictures, playback: SkinPlayback, date: Date,
                @ViewBuilder artwork: @escaping () -> Artwork) {
        self.design = design
        self.pictures = pictures
        self.playback = playback
        self.date = date
        self.artwork = artwork
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let layout = design.resolvedGeometry
            let reels = ReelState(layout: layout, width: size.width, playback: playback, date: date)
            let shellPicture = PictureLoader.image(pictures.shell, revision: pictures.revision)
            ZStack(alignment: .topLeading) {
                if let shellPicture {
                    // The user's shell: the reels show through its transparent parts.
                    ReelsLayer(design: design, layout: layout, size: size, reels: reels, showsTape: true)
                    shellPicture.resizable().frame(width: size.width, height: size.height)
                    LabelLayer(design: design, layout: layout, size: size, playback: playback, pictures: pictures, drawsBackground: pictures.label != nil,
                               artwork: artwork)
                } else {
                    DrawnShell(design: design, layout: layout, size: size, reels: reels, playback: playback, pictures: pictures, artwork: artwork)
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

/// Where the reels are in the song: how much tape each holds and how far each has turned.
struct ReelState {
    var leftRadius: CGFloat
    var rightRadius: CGFloat
    var leftAngle: Angle
    var rightAngle: Angle

    init(layout: CassetteGeometry, width: CGFloat, playback: SkinPlayback, date: Date) {
        let full = layout.reelRadius * width
        let hub = layout.hubRadius * width * 1.05
        let progress = playback.progress(at: date)
        let wound = (full * full - hub * hub)
        leftRadius = sqrt(full * full - wound * progress)
        rightRadius = sqrt(hub * hub + wound * progress)
        // The tape moves at one speed: a bare hub turns half a turn a second. The angle a reel has turned is then the
        // length of tape it gave or took over its radius, summed: 2 (r - r0) / k for a pack growing as r² = r0² + k s.
        let time = playback.time(date)
        if playback.duration > 0, wound > 0 {
            let speed = Double.pi * hub
            let k = wound / (playback.duration * speed)
            rightAngle = .radians(2 * (rightRadius - hub) / k)
            leftAngle = .radians(2 * (full - leftRadius) / k)
        } else {
            rightAngle = .radians(time * .pi)
            leftAngle = rightAngle
        }
    }
}

/// The two packs of tape and their hubs, and (through a clear shell) the tape running along the bottom.
struct ReelsLayer: View {
    var design: CassetteDesign
    var layout: CassetteGeometry
    var size: CGSize
    var reels: ReelState
    var showsTape: Bool

    var body: some View {
        let tape = Color(design.reels.tapeColor)
        let left = CGPoint(x: layout.leftReel.x * size.width, y: layout.leftReel.y * size.height)
        let right = CGPoint(x: layout.rightReel.x * size.width, y: layout.rightReel.y * size.height)
        let hub = layout.hubRadius * size.width
        ZStack(alignment: .topLeading) {
            if showsTape {
                Path { path in
                    let guideY = size.height * 0.86
                    path.move(to: CGPoint(x: left.x - reels.leftRadius, y: left.y))
                    path.addLine(to: CGPoint(x: size.width * 0.1, y: guideY))
                    path.addLine(to: CGPoint(x: size.width * 0.9, y: guideY))
                    path.addLine(to: CGPoint(x: right.x + reels.rightRadius, y: right.y))
                }
                .stroke(tape.opacity(0.9), lineWidth: max(1, size.width * 0.004))
            }
            pack(radius: reels.leftRadius, at: left, tape: tape)
            pack(radius: reels.rightRadius, at: right, tape: tape)
            Hub(color: Color(design.reels.hubColor), radius: hub).rotationEffect(reels.leftAngle).position(left)
            Hub(color: Color(design.reels.hubColor), radius: hub).rotationEffect(reels.rightAngle).position(right)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func pack(radius: CGFloat, at center: CGPoint, tape: Color) -> some View {
        Circle()
            .fill(RadialGradient(colors: [tape.opacity(0.75), tape, tape.opacity(0.85)], center: .center, startRadius: 0, endRadius: radius))
            .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
            .frame(width: radius * 2, height: radius * 2)
            .position(center)
    }
}

/// A reel's hub: a ring with six teeth inside, the spindle's hole in the middle.
struct Hub: View {
    var color: Color
    var radius: CGFloat

    var body: some View {
        Canvas { context, size in
            let middle = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = size.width / 2
            context.fill(Path(ellipseIn: CGRect(x: 0, y: 0, width: size.width, height: size.height)), with: .color(color))
            let hole = r * 0.62
            context.fill(Path(ellipseIn: CGRect(x: middle.x - hole, y: middle.y - hole, width: hole * 2, height: hole * 2)),
                         with: .color(.black.opacity(0.85)))
            for tooth in 0..<6 {
                var transform = CGAffineTransform(translationX: middle.x, y: middle.y).rotated(by: Double(tooth) / 6 * 2 * .pi)
                let rect = CGRect(x: -r * 0.09, y: -hole - 0.5, width: r * 0.18, height: r * 0.26)
                context.fill(Path(roundedRect: rect, cornerRadius: r * 0.03).applying(transform), with: .color(color))
                transform = .identity
            }
        }
        .frame(width: radius * 2, height: radius * 2)
    }
}

/// The shell drawn from the design: the plastic (clear or not) with the window and the hubs' holes, the label, the
/// head opening along the bottom, the screws.
private struct DrawnShell<Artwork: View>: View {
    var design: CassetteDesign
    var layout: CassetteGeometry
    var size: CGSize
    var reels: ReelState
    var playback: SkinPlayback
    var pictures: CassettePictures
    @ViewBuilder var artwork: () -> Artwork

    var body: some View {
        let shell = Color(design.shellColor)
        let detail = Color(design.detailColor)
        let corner = size.width * 0.035
        let clarity = design.shellClarity
        let window = rect(layout.window).insetBy(dx: 0, dy: 0)
        let hubHole = layout.hubRadius * size.width * 1.25
        let holes = [CGPoint(x: layout.leftReel.x * size.width, y: layout.leftReel.y * size.height),
                     CGPoint(x: layout.rightReel.x * size.width, y: layout.rightReel.y * size.height)]
        ZStack(alignment: .topLeading) {
            // The back of the shell, seen through the windows (and all over a clear one).
            RoundedRectangle(cornerRadius: corner).fill(shell.opacity(clarity > 0 ? 0.35 : 1))
                .overlay(RoundedRectangle(cornerRadius: corner).fill(.black.opacity(0.35)))
            ReelsLayer(design: design, layout: layout, size: size, reels: reels, showsTape: clarity > 0)
            // The front, with the window and the hubs' holes cut out.
            FrontPlate(window: window, holes: holes, holeRadius: hubHole, corner: corner)
                .fill(shell.opacity(1 - clarity), style: FillStyle(eoFill: true))
                .overlay {
                    // Light across the plastic.
                    FrontPlate(window: window, holes: holes, holeRadius: hubHole, corner: corner)
                        .fill(LinearGradient(colors: [.white.opacity(0.14), .clear, .black.opacity(0.12)], startPoint: .top, endPoint: .bottom),
                              style: FillStyle(eoFill: true))
                }
            LabelLayer(design: design, layout: layout, size: size, playback: playback, pictures: pictures, drawsBackground: true, artwork: artwork)
            // Printed rings around the hubs' holes.
            if let ring = design.reels.ringColor {
                ForEach(Array(holes.enumerated()), id: \.offset) { _, hole in
                    Circle().strokeBorder(Color(ring), lineWidth: size.width * 0.011)
                        .frame(width: (hubHole + size.width * 0.011) * 2, height: (hubHole + size.width * 0.011) * 2)
                        .position(hole)
                }
            }
            // The window's frame, and its clear plastic.
            RoundedRectangle(cornerRadius: window.height * 0.18)
                .fill(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: window.height * 0.18).strokeBorder(detail, lineWidth: size.width * 0.005))
                .frame(width: window.width, height: window.height)
                .position(x: window.midX, y: window.midY)
            // The head opening along the bottom: a raised trapezoid with its holes.
            HeadArea(size: size)
                .fill(shell.opacity(max(1 - clarity, 0.55)))
                .overlay(HeadArea(size: size).fill(.black.opacity(0.18)))
                .overlay(HeadArea(size: size).stroke(detail.opacity(0.8), lineWidth: size.width * 0.003))
            ForEach(Array(headHoles.enumerated()), id: \.offset) { _, hole in
                RoundedRectangle(cornerRadius: size.width * 0.004).fill(.black.opacity(0.75))
                    .frame(width: size.width * hole.width, height: size.height * 0.05)
                    .position(x: size.width * hole.x, y: size.height * 0.9)
            }
            ForEach(Array(screws.enumerated()), id: \.offset) { _, screw in
                Screw(color: detail, size: size.width * 0.028).position(x: size.width * screw.x, y: size.height * screw.y)
            }
            RoundedRectangle(cornerRadius: corner).strokeBorder(detail.opacity(0.7), lineWidth: size.width * 0.004)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private var headHoles: [(x: Double, width: Double)] { [(0.25, 0.04), (0.38, 0.05), (0.5, 0.04), (0.62, 0.05), (0.75, 0.04)] }
    private var screws: [(x: Double, y: Double)] { [(0.035, 0.055), (0.965, 0.055), (0.035, 0.945), (0.965, 0.945), (0.5, 0.8)] }

    private func rect(_ rect: CassetteGeometry.Rect) -> CGRect {
        CGRect(x: rect.x * size.width, y: rect.y * size.height, width: rect.width * size.width, height: rect.height * size.height)
    }
}

/// The shell's front with the window and the hubs' holes (filled even-odd).
private struct FrontPlate: Shape {
    var window: CGRect
    var holes: [CGPoint]
    var holeRadius: CGFloat
    var corner: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: corner)
        path.addRoundedRect(in: window, cornerSize: CGSize(width: window.height * 0.18, height: window.height * 0.18))
        for hole in holes {
            path.addEllipse(in: CGRect(x: hole.x - holeRadius, y: hole.y - holeRadius, width: holeRadius * 2, height: holeRadius * 2))
        }
        return path
    }
}

/// The raised part along the bottom, where the heads meet the tape.
private struct HeadArea: Shape {
    var size: CGSize

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: size.width * 0.17, y: size.height))
        path.addLine(to: CGPoint(x: size.width * 0.22, y: size.height * 0.79))
        path.addLine(to: CGPoint(x: size.width * 0.78, y: size.height * 0.79))
        path.addLine(to: CGPoint(x: size.width * 0.83, y: size.height))
        path.closeSubpath()
        return path
    }
}

private struct Screw: View {
    var color: Color
    var size: CGFloat

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(0.9), color.opacity(0.5)], center: .topLeading, startRadius: 0, endRadius: size))
            .overlay {
                Path { path in
                    path.move(to: CGPoint(x: size * 0.25, y: size * 0.5)); path.addLine(to: CGPoint(x: size * 0.75, y: size * 0.5))
                    path.move(to: CGPoint(x: size * 0.5, y: size * 0.25)); path.addLine(to: CGPoint(x: size * 0.5, y: size * 0.75))
                }
                .stroke(.black.opacity(0.5), lineWidth: max(0.5, size * 0.1))
            }
            .frame(width: size, height: size)
    }
}

/// The label: its color and bands (or the user's picture), the brand and the tape's type, the side, the song written
/// on it and the cover, around the window and the hubs' holes.
private struct LabelLayer<Artwork: View>: View {
    var design: CassetteDesign
    var layout: CassetteGeometry
    var size: CGSize
    var playback: SkinPlayback
    var pictures: CassettePictures
    /// False over a shell picture without a label picture: the picture has its label, only the text goes on it.
    var drawsBackground: Bool
    @ViewBuilder var artwork: () -> Artwork

    var body: some View {
        let label = CGRect(x: layout.label.x * size.width, y: layout.label.y * size.height,
                           width: layout.label.width * size.width, height: layout.label.height * size.height)
        let window = CGRect(x: layout.window.x * size.width, y: layout.window.y * size.height,
                            width: layout.window.width * size.width, height: layout.window.height * size.height)
        let hubHole = layout.hubRadius * size.width * 1.25
        let holes = [CGPoint(x: layout.leftReel.x * size.width, y: layout.leftReel.y * size.height),
                     CGPoint(x: layout.rightReel.x * size.width, y: layout.rightReel.y * size.height)]
        let cutout = LabelCutout(window: window, holes: holes, holeRadius: hubHole, corner: label.height * 0.04)
        let text = Color(design.label.textColor)
        let ink = design.label.writing.map { Color($0.textColor) } ?? text
        let labelPicture = PictureLoader.image(pictures.label, revision: pictures.revision)
        // The writing goes above the window.
        let writing = CGRect(x: label.minX, y: label.minY, width: label.width, height: window.minY - label.minY)
        // The strip to write on, under the brand's line and above the window.
        let strip = CGRect(x: label.minX + label.width * 0.035, y: label.minY + size.height * 0.07, width: label.width * 0.93,
                           height: max(window.minY - label.minY - size.height * 0.095, 0))
        ZStack(alignment: .topLeading) {
            if drawsBackground {
                Group {
                    if let labelPicture {
                        labelPicture.resizable().scaledToFill()
                    } else {
                        LabelBackground(design: design)
                    }
                }
                .frame(width: label.width, height: label.height)
                .clipped()
                .mask(cutout.offset(x: -label.minX, y: -label.minY).fill(style: FillStyle(eoFill: true)))
                .position(x: label.midX, y: label.midY)
                if labelPicture == nil, let paper = design.label.writing {
                    RoundedRectangle(cornerRadius: size.width * 0.006)
                        .fill(Color(paper.background))
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Color(paper.textColor).opacity(0.15)).frame(height: 0.7).padding(.horizontal, strip.width * 0.03)
                                .padding(.bottom, strip.height * 0.28)
                        }
                        .frame(width: strip.width, height: strip.height)
                        .position(x: strip.midX, y: strip.midY)
                }
                if labelPicture == nil {
                    // Brand and type across the top, the side in the band below the window.
                    HStack {
                        Text(design.brand).font(.system(size: size.width * 0.026, weight: .heavy)).tracking(size.width * 0.002)
                        Spacer()
                        Text(design.tapeType).font(.system(size: size.width * 0.02, weight: .semibold))
                    }
                    .foregroundStyle(text.opacity(0.85))
                    .padding(.horizontal, label.width * 0.035)
                    .frame(width: label.width)
                    .position(x: label.midX, y: label.minY + size.height * 0.035)
                    // Left of the left reel, above the bands.
                    Text(design.side)
                        .font(.system(size: size.width * 0.05, weight: .black))
                        .foregroundStyle(text.opacity(0.85))
                        .position(x: label.minX + label.width * 0.055, y: window.minY + window.height * 0.12)
                }
            }
            HStack(alignment: .center, spacing: size.width * 0.02) {
                if design.label.showsArtwork {
                    artwork()
                        .frame(width: writing.height * 0.58, height: writing.height * 0.58)
                        .clipShape(.rect(cornerRadius: size.width * 0.006))
                }
                if design.label.showsText {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(playback.title)
                            .font(font(size.width * 0.042))
                        Text(playback.artist)
                            .font(font(size.width * 0.03))
                            .opacity(0.8)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(labelPicture == nil ? ink : text)
                    // Written, not printed: a little askew.
                    .rotationEffect(.degrees(design.label.handwritten ? -1.2 : 0))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, label.width * 0.05)
            .padding(.top, size.height * 0.05)
            .frame(width: writing.width, height: writing.height)
            .position(x: writing.midX, y: writing.midY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func font(_ size: CGFloat) -> Font {
        design.label.handwritten ? .custom("Marker Felt", size: size) : .system(size: size, weight: .semibold, design: .rounded)
    }
}

/// The label's color with its bands across the lower part, as on the classic tapes.
private struct LabelBackground: View {
    var design: CassetteDesign

    var body: some View {
        GeometryReader { geometry in
            let stripes = design.label.stripes
            ZStack(alignment: .topLeading) {
                Color(design.label.background)
                if !stripes.isEmpty {
                    let band = geometry.size.height * 0.3 / CGFloat(stripes.count)
                    VStack(spacing: 0) {
                        ForEach(Array(stripes.enumerated()), id: \.offset) { _, stripe in Color(stripe).frame(height: band) }
                    }
                    .offset(y: geometry.size.height * 0.62)
                }
                ForEach(Array(design.label.bands.enumerated()), id: \.offset) { _, band in
                    Color(band.color)
                        .frame(height: geometry.size.height * band.height)
                        .offset(y: geometry.size.height * band.y)
                }
                // Lines to write on, above the window.
                VStack(spacing: geometry.size.height * 0.09) {
                    ForEach(0..<2, id: \.self) { _ in Rectangle().fill(Color(design.label.textColor).opacity(0.12)).frame(height: 0.7) }
                }
                .padding(.horizontal, geometry.size.width * 0.05)
                .offset(y: geometry.size.height * 0.15)
            }
        }
    }
}

/// The label with the window and the hubs' holes cut out.
private struct LabelCutout: Shape {
    var window: CGRect
    var holes: [CGPoint]
    var holeRadius: CGFloat
    var corner: CGFloat
    var dx: CGFloat = 0
    var dy: CGFloat = 0

    func offset(x: CGFloat, y: CGFloat) -> LabelCutout {
        var shape = self
        shape.dx = x
        shape.dy = y
        return shape
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: corner)
        let window = self.window.offsetBy(dx: dx, dy: dy)
        path.addRoundedRect(in: window, cornerSize: CGSize(width: window.height * 0.18, height: window.height * 0.18))
        for hole in holes {
            path.addEllipse(in: CGRect(x: hole.x + dx - holeRadius, y: hole.y + dy - holeRadius, width: holeRadius * 2, height: holeRadius * 2))
        }
        return path
    }
}

extension Color {
    public init(_ hex: HexColor) {
        self.init(.sRGB, red: hex.red, green: hex.green, blue: hex.blue, opacity: hex.alpha)
    }
}

/// The user's pictures, decoded once per file and revision.
enum PictureLoader {
    @MainActor private static var cache: [String: Image] = [:]

    @MainActor static func image(_ url: URL?, revision: Int) -> Image? {
        guard let url else { return nil }
        let key = "\(url.path)#\(revision)"
        if let image = cache[key] { return image }
        #if os(macOS)
        guard let platform = NSImage(contentsOf: url) else { return nil }
        let image = Image(nsImage: platform)
        #else
        guard let platform = UIImage(contentsOfFile: url.path) else { return nil }
        let image = Image(uiImage: platform)
        #endif
        cache[key] = image
        return image
    }
}
