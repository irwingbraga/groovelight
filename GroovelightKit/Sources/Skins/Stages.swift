import SwiftUI

// MARK: - Turntable

/// The turntable from above, in the largest square that fits: the platter in its felt mat, the record turning at 33⅓
/// with the cover as its label, and the tonearm going in from the first groove to the last as the song plays (on its
/// rest until it starts). The arm's headshell can be dragged across the record to go to another part of the song.
struct TurntableStage<Artwork: View>: View {
    var playback: SkinPlayback
    var seek: (TimeInterval) -> Void
    @ViewBuilder var artwork: () -> Artwork
    @State private var dragAngle: Double?

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: side * 0.43, y: side * 0.5)
            let record = side * 0.38
            let range = Tonearm.range(side: side, center: center, record: record)
            ZStack(alignment: .topLeading) {
                Platter(side: side).position(center)
                TimelineView(.animation(paused: !playback.isPlaying)) { context in
                    let time = playback.time(context.date)
                    let started = playback.isPlaying || time > 0.5
                    let angle = dragAngle ?? (started ? range.outer + (range.inner - range.outer) * playback.progress(at: context.date) : Tonearm.rest)
                    ZStack(alignment: .topLeading) {
                        VinylRecord(artwork: artwork)
                            .frame(width: record * 2, height: record * 2)
                            .rotationEffect(.degrees(time * 200))
                            // The light on the record stays where it is while the record turns under it.
                            .overlay {
                                Circle().fill(AngularGradient(colors: [.clear, .white.opacity(0.16), .clear, .clear, .white.opacity(0.11), .clear],
                                                              center: .center))
                                    .allowsHitTesting(false)
                            }
                            .position(center)
                        // The spindle.
                        Circle().fill(RadialGradient(colors: [.white, Color(white: 0.55)], center: .init(x: 0.35, y: 0.3), startRadius: 0,
                                                     endRadius: side * 0.012))
                            .frame(width: side * 0.02, height: side * 0.02)
                            .shadow(radius: 1)
                            .position(center)
                        Tonearm(side: side, angle: angle)
                            .animation(dragAngle == nil ? .easeInOut(duration: 0.9) : nil, value: started)
                        // The headshell's handle.
                        let stylus = Tonearm.stylus(side: side, angle: angle)
                        Circle().fill(Color.white.opacity(0.001))
                            .frame(width: side * 0.16, height: side * 0.16)
                            .position(stylus)
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("turntable"))
                                .onChanged { drag in
                                    let pivot = Tonearm.pivot(side: side)
                                    let degrees = atan2(pivot.x - drag.location.x, drag.location.y - pivot.y) * 180 / .pi
                                    dragAngle = min(max(degrees, Tonearm.rest), range.inner + 2)
                                }
                                .onEnded { _ in
                                    if let dragAngle, playback.duration > 0 {
                                        let progress = (dragAngle - range.outer) / (range.inner - range.outer)
                                        seek(min(max(progress, 0), 0.995) * playback.duration)
                                    }
                                    dragAngle = nil
                                })
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(width: side, height: side)
            .coordinateSpace(.named("turntable"))
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}

/// The platter: a polished aluminum rim with its strobe dots, the felt mat on it.
private struct Platter: View {
    var side: CGFloat

    var body: some View {
        let diameter = side * 0.84
        ZStack {
            Circle().fill(AngularGradient(colors: [Color(white: 0.92), Color(white: 0.5), Color(white: 0.85), Color(white: 0.42), Color(white: 0.92)],
                                          center: .center))
            Canvas { context, size in
                let middle = CGPoint(x: size.width / 2, y: size.height / 2)
                for index in 0..<90 {
                    let angle = Double(index) / 90 * 2 * .pi
                    let point = CGPoint(x: middle.x + cos(angle) * size.width * 0.488, y: middle.y + sin(angle) * size.width * 0.488)
                    let dot = size.width * 0.006
                    context.fill(Path(roundedRect: CGRect(x: point.x - dot, y: point.y - dot, width: dot * 2, height: dot * 2), cornerRadius: dot * 0.3),
                                 with: .color(.black.opacity(0.4)))
                }
            }
            Textured(texture: .felt, tint: Color(white: 0.28))
                .clipShape(Circle())
                .padding(diameter * 0.035)
                .overlay(Circle().strokeBorder(.black.opacity(0.5), lineWidth: 1).padding(diameter * 0.035))
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: .black.opacity(0.6), radius: side * 0.025, y: side * 0.015)
    }
}

/// The record: its grooves, the gaps between songs a little lighter, and the label (the cover, round).
private struct VinylRecord<Artwork: View>: View {
    @ViewBuilder var artwork: () -> Artwork

    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.05))
            Canvas { context, size in
                let middle = CGPoint(x: size.width / 2, y: size.height / 2)
                let outer = size.width / 2
                var radius = outer * 0.97
                var index = 0
                while radius > outer * 0.36 {
                    let gap = index % 23 == 22
                    let path = Path(ellipseIn: CGRect(x: middle.x - radius, y: middle.y - radius, width: radius * 2, height: radius * 2))
                    context.stroke(path, with: .color(.white.opacity(gap ? 0.1 : (index.isMultiple(of: 2) ? 0.035 : 0.015))), lineWidth: gap ? 1.4 : 0.6)
                    radius -= outer * 0.0085
                    index += 1
                }
            }
            GeometryReader { geometry in
                let label = geometry.size.width * 0.34
                artwork()
                    .frame(width: label, height: label)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1))
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
    }
}

/// The arm: its base, the counterweight behind the pivot, the chrome tube and the headshell at the stylus.
struct Tonearm: View {
    var side: CGFloat
    /// Degrees from resting straight down beside the record; toward the record is positive.
    var angle: Double

    static let rest = -3.0
    static func pivot(side: CGFloat) -> CGPoint { CGPoint(x: side * 0.88, y: side * 0.14) }
    static func length(side: CGFloat) -> CGFloat { side * 0.66 }

    static func stylus(side: CGFloat, angle: Double) -> CGPoint {
        let pivot = pivot(side: side), length = length(side: side) * 0.97
        let radians = angle * .pi / 180
        return CGPoint(x: pivot.x - sin(radians) * length, y: pivot.y + cos(radians) * length)
    }

    /// The angles putting the stylus in the first groove and the last.
    static func range(side: CGFloat, center: CGPoint, record: CGFloat) -> (outer: Double, inner: Double) {
        let pivot = pivot(side: side), length = length(side: side)
        // The angle at which the stylus is `radius` from the record's center (found by halving: it moves in steadily).
        func angle(at radius: CGFloat) -> Double {
            var low = 0.0, high = 60.0
            for _ in 0..<30 {
                let middle = (low + high) / 2
                let radians = middle * .pi / 180
                let stylus = CGPoint(x: pivot.x - sin(radians) * length, y: pivot.y + cos(radians) * length)
                if hypot(stylus.x - center.x, stylus.y - center.y) > radius { low = middle } else { high = middle }
            }
            return (low + high) / 2
        }
        return (angle(at: record * 0.95), angle(at: record * 0.4))
    }

    /// The angle putting the stylus at `progress` through the record, or on its rest.
    static func angle(side: CGFloat, center: CGPoint, record: CGFloat, progress: Double, onRecord: Bool) -> Double {
        guard onRecord else { return rest }
        let range = range(side: side, center: center, record: record)
        return range.outer + (range.inner - range.outer) * progress
    }

    var body: some View {
        let pivot = Self.pivot(side: side), length = Self.length(side: side)
        ZStack(alignment: .topLeading) {
            // The rest the arm sits on, and the arm's base: a turned aluminum disc.
            RoundedRectangle(cornerRadius: side * 0.006)
                .fill(Color(white: 0.12))
                .frame(width: side * 0.03, height: side * 0.05)
                .position(x: pivot.x + side * 0.035, y: pivot.y + length * 0.72)
            Circle()
                .fill(AngularGradient(colors: [Color(white: 0.95), Color(white: 0.5), Color(white: 0.88), Color(white: 0.45), Color(white: 0.95)],
                                      center: .center))
                .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
                .frame(width: side * 0.13, height: side * 0.13)
                .shadow(color: .black.opacity(0.55), radius: side * 0.012, y: side * 0.008)
                .position(pivot)
            ZStack(alignment: .top) {
                // The counterweight, knurled, behind the pivot.
                RoundedRectangle(cornerRadius: side * 0.006)
                    .fill(LinearGradient(colors: [Color(white: 0.25), Color(white: 0.7), Color(white: 0.2)], startPoint: .leading, endPoint: .trailing))
                    .overlay {
                        VStack(spacing: side * 0.004) {
                            ForEach(0..<6, id: \.self) { _ in Rectangle().fill(.black.opacity(0.35)).frame(height: max(0.5, side * 0.002)) }
                        }
                    }
                    .frame(width: side * 0.055, height: side * 0.07)
                    .offset(y: -side * 0.095)
                // The tube.
                Capsule()
                    .fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 1), Color(white: 0.7), Color(white: 0.45)], startPoint: .leading,
                                         endPoint: .trailing))
                    .frame(width: side * 0.017, height: length)
                // The headshell, its finger lift, and the cartridge.
                RoundedRectangle(cornerRadius: side * 0.006)
                    .fill(LinearGradient(colors: [Color(white: 0.3), Color(white: 0.12)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: side * 0.045, height: side * 0.08)
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: side * 0.003).fill(Color(red: 0.75, green: 0.1, blue: 0.08))
                            .frame(width: side * 0.03, height: side * 0.025).offset(y: side * 0.04)
                    }
                    .overlay(alignment: .trailing) {
                        Capsule().fill(Color(white: 0.8)).frame(width: side * 0.03, height: side * 0.006).offset(x: side * 0.025, y: -side * 0.02)
                    }
                    .offset(y: length - side * 0.06)
            }
            .frame(width: side * 0.06, height: length, alignment: .top)
            .compositingGroup()
            .shadow(color: .black.opacity(0.5), radius: side * 0.012, x: side * 0.01, y: side * 0.016)
            .rotationEffect(.degrees(angle), anchor: .top)
            .position(x: pivot.x, y: pivot.y + length / 2)
            // The pivot's cap.
            Circle().fill(RadialGradient(colors: [Color(white: 0.4), Color(white: 0.08)], center: .init(x: 0.4, y: 0.35), startRadius: 0,
                                         endRadius: side * 0.025))
                .frame(width: side * 0.04, height: side * 0.04)
                .position(pivot)
        }
    }
}

// MARK: - Cassette

/// The deck's cassette well: a door of black plastic, the cassette behind its smoked window, the reels turning.
struct CassetteStage<Artwork: View>: View {
    var design: CassetteDesign
    var pictures: CassettePictures
    var playback: SkinPlayback
    @ViewBuilder var artwork: () -> Artwork

    var body: some View {
        GeometryReader { geometry in
            let aspect = design.resolvedGeometry.aspectRatio
            // The door is a little larger than the cassette, around it.
            let width = min(geometry.size.width, geometry.size.height * aspect * 0.9 / 0.82)
            let door = CGSize(width: width, height: width / aspect * 0.82 / 0.9 * 1.04)
            let cassette = CGSize(width: door.width * 0.86, height: door.width * 0.86 / aspect)
            let corner = door.width * 0.03
            ZStack {
                Textured(texture: .blackPlastic, brightness: -0.05)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom),
                                      lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.6), radius: corner, y: corner * 0.5)
                // The window, the cassette behind it.
                ZStack {
                    Color.black
                    TimelineView(.animation(paused: !playback.isPlaying)) { context in
                        CassetteFace(design: design, pictures: pictures, playback: playback, date: context.date, artwork: artwork)
                            .frame(width: cassette.width, height: cassette.height)
                    }
                    // Smoked plexiglass: darker, and the light across it.
                    Color.black.opacity(0.24)
                    LinearGradient(stops: [.init(color: .white.opacity(0.16), location: 0), .init(color: .white.opacity(0.03), location: 0.38),
                                           .init(color: .clear, location: 0.4), .init(color: .clear, location: 1)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                .frame(width: cassette.width + door.width * 0.04, height: cassette.height + door.width * 0.04)
                .clipShape(RoundedRectangle(cornerRadius: corner * 0.6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: corner * 0.6, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.7)], startPoint: .top, endPoint: .bottom), lineWidth: 2))
                .offset(y: -door.height * 0.03)
                Engraved("◀ TAPE ▶", size: door.width * 0.022, onDark: true)
                    .opacity(0.6)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, door.height * 0.035)
            }
            .frame(width: door.width, height: door.height)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}

// MARK: - CD

/// A top-loading CD player's well: the disc, printed with the cover, turning under a smoked lid.
struct DiscStage<Artwork: View>: View {
    var playback: SkinPlayback
    @ViewBuilder var artwork: () -> Artwork

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                // The lid's polished ring and the well under it.
                Circle().fill(AngularGradient(colors: [Color(white: 0.85), Color(white: 0.3), Color(white: 0.75), Color(white: 0.25), Color(white: 0.85)],
                                              center: .center))
                    .shadow(color: .black.opacity(0.7), radius: side * 0.03, y: side * 0.015)
                Textured(texture: .blackPlastic, brightness: -0.08)
                    .clipShape(Circle())
                    .overlay(Circle().fill(Color.black.opacity(0.001).shadow(.inner(color: .black, radius: side * 0.03, y: side * 0.015))))
                    .padding(side * 0.025)
                TimelineView(.animation(paused: !playback.isPlaying)) { context in
                    CompactDisc(artwork: artwork)
                        .frame(width: side * 0.86, height: side * 0.86)
                        .rotationEffect(.degrees(playback.time(context.date) * 300))
                }
                // The rainbow the light makes on the disc stays with the light.
                Circle().fill(AngularGradient(colors: [.clear, .cyan.opacity(0.2), .purple.opacity(0.15), .clear, .yellow.opacity(0.15),
                                                       .pink.opacity(0.13), .clear], center: .center))
                    .frame(width: side * 0.86, height: side * 0.86)
                    .mask(DiscShape(hole: 0.075).fill(style: FillStyle(eoFill: true)).frame(width: side * 0.86, height: side * 0.86))
                    .blendMode(.screen)
                // The clamp holding the disc.
                Circle().fill(AngularGradient(colors: [Color(white: 0.95), Color(white: 0.45), Color(white: 0.9), Color(white: 0.4), Color(white: 0.95)],
                                              center: .center))
                    .overlay(Circle().fill(Color(white: 0.15)).padding(side * 0.03))
                    .frame(width: side * 0.12, height: side * 0.12)
                    .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
                // The smoked lid over it all.
                Circle()
                    .fill(LinearGradient(stops: [.init(color: .white.opacity(0.2), location: 0), .init(color: .white.opacity(0.04), location: 0.42),
                                                 .init(color: .clear, location: 0.45), .init(color: .black.opacity(0.18), location: 1)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .padding(side * 0.025)
                    .allowsHitTesting(false)
            }
            .frame(width: side, height: side)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}

/// The disc: silver, printed with the cover between the clear hub and the rim, a hole in the middle.
private struct CompactDisc<Artwork: View>: View {
    @ViewBuilder var artwork: () -> Artwork

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size.width
            ZStack {
                Circle().fill(AngularGradient(colors: [Color(white: 0.85), Color(white: 0.6), Color(white: 0.92), Color(white: 0.55), Color(white: 0.85)],
                                              center: .center))
                artwork()
                    .frame(width: size, height: size)
                    .mask(DiscShape(hole: 0.24, inset: size * 0.012).fill(style: FillStyle(eoFill: true)))
                Circle().strokeBorder(.white.opacity(0.5), lineWidth: size * 0.004).frame(width: size * 0.34, height: size * 0.34)
                Circle().strokeBorder(.black.opacity(0.15), lineWidth: size * 0.002).frame(width: size * 0.24, height: size * 0.24)
                Circle().strokeBorder(.white.opacity(0.4), lineWidth: size * 0.004)
            }
            .mask(DiscShape(hole: 0.075).fill(style: FillStyle(eoFill: true)))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// A disc with a hole (filled even-odd): `hole` is the hole's radius relative to the whole, `inset` takes in the rim.
struct DiscShape: Shape {
    var hole: Double
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: rect.insetBy(dx: inset, dy: inset))
        let radius = rect.width * hole
        path.addEllipse(in: CGRect(x: rect.midX - radius, y: rect.midY - radius, width: radius * 2, height: radius * 2))
        return path
    }
}
