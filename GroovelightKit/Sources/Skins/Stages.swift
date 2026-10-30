import SwiftUI

// MARK: - Motors

/// A motor's turning: its angle (degrees) at any moment, from the clock rather than the song's time (which jumps a little
/// each time the player reports it). A change of speed takes `spinUp` seconds from rest to full speed (or `spinDown` from
/// full speed to rest), easing in and out as a real platter or disc does.
struct SpinMotion {
    var speed: Double
    var spinUp: Double
    var spinDown: Double
    private var angle = 0.0, velocity = 0.0, target = 0.0, duration = 0.0
    private var since = Date.distantPast

    init(speed: Double, spinUp: Double, spinDown: Double, isOn: Bool) {
        self.speed = speed
        self.spinUp = spinUp
        self.spinDown = spinDown
        velocity = isOn ? speed : 0
        target = velocity
    }

    /// Where it is, and how fast it turns, at `date`.
    func state(at date: Date) -> (angle: Double, velocity: Double) {
        let elapsed = max(date.timeIntervalSince(since), 0)
        guard duration > 0 else { return (angle + velocity * elapsed, velocity) }
        // The speed follows smoothstep (3u² - 2u³) from `velocity` to `target`; the angle is its integral.
        let u = min(elapsed / duration, 1), change = target - velocity
        let turned = velocity * duration * u + change * duration * (u * u * u - u * u * u * u / 2)
        let velocityNow = velocity + change * (3 * u * u - 2 * u * u * u)
        return (angle + turned + target * max(elapsed - duration, 0), velocityNow)
    }

    /// Starts the motor (`isOn`) or stops it, at `date`.
    mutating func turn(_ isOn: Bool, at date: Date) {
        let now = state(at: date)
        angle = now.angle.truncatingRemainder(dividingBy: 360)
        velocity = now.velocity
        target = isOn ? speed : 0
        since = date
        duration = abs(target - velocity) / speed * (isOn ? spinUp : spinDown)
    }

    /// Whether it still turns at `date`.
    func isTurning(at date: Date) -> Bool { state(at: date).velocity > 0.001 || target > 0 }
}

/// A view turned by a motor that runs while `isOn`: it speeds up when it starts and coasts to a stop. Only the rotation
/// changes each frame: the view itself (a record's grooves, a disc's print) is drawn once, not again at every frame.
struct Spinning: ViewModifier {
    var isOn: Bool
    var speed: Double
    var spinUp: Double
    var spinDown: Double
    @State private var motion: SpinMotion?
    @State private var coasting = false

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: !isOn && !coasting)) { context in
            content
                .rotationEffect(.degrees(motion?.state(at: context.date).angle ?? 0))
        }
        .onAppear { motion = motion ?? SpinMotion(speed: speed, spinUp: spinUp, spinDown: spinDown, isOn: isOn) }
        .onChange(of: isOn) { _, isOn in
            motion?.turn(isOn, at: .now)
            coasting = !isOn
        }
        .task(id: isOn) {
            guard !isOn else { return }
            try? await Task.sleep(for: .seconds(spinDown))
            if !Task.isCancelled { coasting = false }
        }
    }
}

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
                // 33⅓ turns a minute; a direct-drive motor is up to speed in a second, the platter coasts to a stop.
                VinylRecord(artwork: artwork)
                    .frame(width: record * 2, height: record * 2)
                    .modifier(Spinning(isOn: playback.isPlaying, speed: 200, spinUp: 1, spinDown: 2.6))
                    // The light on the record stays where it is while the record turns under it.
                    .overlay { VinylSheen() }
                    .position(center)
                // The spindle.
                Circle().fill(RadialGradient(colors: [.white, Color(white: 0.55)], center: .init(x: 0.35, y: 0.3), startRadius: 0,
                                             endRadius: side * 0.012))
                    .frame(width: side * 0.02, height: side * 0.02)
                    .shadow(radius: 1)
                    .position(center)
                // The arm crosses the record over the whole song, a fraction of a degree a second: ten steps a second look smooth.
                TimelineView(.animation(minimumInterval: 0.1, paused: !playback.isPlaying)) { context in
                    let time = playback.time(context.date)
                    let started = playback.isPlaying || time > 0.5
                    let angle = dragAngle ?? (started ? range.outer + (range.inner - range.outer) * playback.progress(at: context.date) : Tonearm.rest)
                    ZStack(alignment: .topLeading) {
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
            // Black vinyl, its grooves faintly seen in the room's light.
            Circle().fill(Color(white: 0.035))
            SkinTexture.vinyl.image
                .resizable()
                .opacity(0.17)
            GeometryReader { geometry in
                let label = geometry.size.width * 0.34
                artwork()
                    .frame(width: label, height: label)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1))
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
        .clipShape(Circle())
        .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
    }
}

/// The lamp's light on a record: two bright wedges across from each other, where the grooves face the light, each made of
/// the grooves' fine lines (the record's own grooves are its mask), still while the record turns under them.
private struct VinylSheen: View {
    var body: some View {
        AngularGradient(stops: [
            .init(color: .clear, location: 0), .init(color: .white.opacity(0.18), location: 0.06), .init(color: .white.opacity(0.75), location: 0.11),
            .init(color: .white.opacity(0.18), location: 0.16), .init(color: .clear, location: 0.24), .init(color: .clear, location: 0.53),
            .init(color: .white.opacity(0.12), location: 0.57), .init(color: .white.opacity(0.5), location: 0.61),
            .init(color: .white.opacity(0.12), location: 0.65), .init(color: .clear, location: 0.72), .init(color: .clear, location: 1),
        ], center: .center, angle: .degrees(-20))
        .mask(SkinTexture.vinyl.image.resizable().luminanceToAlpha())
        .blendMode(.screen)
        .allowsHitTesting(false)
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
            // The rest the arm sits on: a black rubber cradle on a chrome post.
            Circle().fill(Chrome.dome(side * 0.012))
                .frame(width: side * 0.024, height: side * 0.024)
                .shadow(color: .black.opacity(0.5), radius: side * 0.004, y: side * 0.003)
                .position(x: pivot.x + side * 0.035, y: pivot.y + length * 0.72 + side * 0.012)
            RoundedRectangle(cornerRadius: side * 0.006)
                .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.06)], startPoint: .leading, endPoint: .trailing))
                .frame(width: side * 0.03, height: side * 0.04)
                .position(x: pivot.x + side * 0.035, y: pivot.y + length * 0.72 - side * 0.01)
            // The arm's base: a disc of turned aluminum, its lathe rings.
            Circle()
                .fill(Chrome.turned)
                .overlay {
                    Canvas { context, size in
                        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
                        var radius = size.width / 2 - 1
                        var ring = 0
                        while radius > size.width * 0.1 {
                            let path = Path(ellipseIn: CGRect(x: middle.x - radius, y: middle.y - radius, width: radius * 2, height: radius * 2))
                            context.stroke(path, with: .color(ring.isMultiple(of: 3) ? .white.opacity(0.2) : .black.opacity(0.07)), lineWidth: 0.5)
                            radius -= max(0.8, size.width * 0.012)
                            ring += 1
                        }
                    }
                }
                .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.85), .black.opacity(0.5)], startPoint: .topLeading,
                                                              endPoint: .bottomTrailing), lineWidth: 1.2))
                .frame(width: side * 0.13, height: side * 0.13)
                .shadow(color: .black.opacity(0.55), radius: side * 0.012, y: side * 0.008)
                .position(pivot)
            ZStack(alignment: .top) {
                // The counterweight behind the pivot: a chrome cylinder, knurled, a black ring at its end.
                RoundedRectangle(cornerRadius: side * 0.005)
                    .fill(Chrome.cylinder())
                    .overlay {
                        VStack(spacing: side * 0.0035) {
                            ForEach(0..<7, id: \.self) { _ in Rectangle().fill(.black.opacity(0.28)).frame(height: max(0.5, side * 0.0018)) }
                        }
                        .padding(.vertical, side * 0.012)
                    }
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: side * 0.004)
                            .fill(LinearGradient(colors: [Color(white: 0.05), Color(white: 0.3), Color(white: 0.04)], startPoint: .leading, endPoint: .trailing))
                            .frame(height: side * 0.012)
                    }
                    .overlay(RoundedRectangle(cornerRadius: side * 0.005).strokeBorder(.black.opacity(0.35), lineWidth: 0.6))
                    .frame(width: side * 0.055, height: side * 0.07)
                    .offset(y: -side * 0.095)
                // The tube, polished chrome.
                Capsule()
                    .fill(Chrome.cylinder())
                    .overlay(Capsule().strokeBorder(.black.opacity(0.3), lineWidth: 0.5))
                    .frame(width: side * 0.017, height: length)
                // The headshell (brushed aluminum, a chrome edge), the cartridge under it, and the chrome finger lift.
                Textured(texture: .aluminum, brightness: 0.05)
                    .overlay(Chrome.cylinder().opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: side * 0.006))
                    .overlay(RoundedRectangle(cornerRadius: side * 0.006).strokeBorder(Chrome.cylinder(.top, .bottom), lineWidth: side * 0.003))
                    .overlay {
                        // Its two screws.
                        HStack(spacing: side * 0.016) {
                            ForEach(0..<2, id: \.self) { _ in
                                Circle().fill(Chrome.dome(side * 0.004)).frame(width: side * 0.008, height: side * 0.008)
                                    .overlay(Circle().strokeBorder(.black.opacity(0.5), lineWidth: 0.5))
                            }
                        }
                        .offset(y: -side * 0.012)
                    }
                    .frame(width: side * 0.045, height: side * 0.08)
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: side * 0.003)
                            .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.06, blue: 0.05), Color(red: 0.85, green: 0.15, blue: 0.1),
                                                          Color(red: 0.5, green: 0.05, blue: 0.04)], startPoint: .leading, endPoint: .trailing))
                            .frame(width: side * 0.03, height: side * 0.025).offset(y: side * 0.045)
                    }
                    .overlay(alignment: .trailing) {
                        Capsule().fill(Chrome.cylinder(.top, .bottom)).frame(width: side * 0.03, height: side * 0.007).offset(x: side * 0.025, y: -side * 0.02)
                    }
                    .offset(y: length - side * 0.06)
            }
            .frame(width: side * 0.06, height: length, alignment: .top)
            .compositingGroup()
            .shadow(color: .black.opacity(0.5), radius: side * 0.012, x: side * 0.01, y: side * 0.016)
            .rotationEffect(.degrees(angle), anchor: .top)
            .position(x: pivot.x, y: pivot.y + length / 2)
            // The pivot's chrome cap.
            Circle().fill(Chrome.dome(side * 0.02))
                .overlay(Circle().strokeBorder(.black.opacity(0.45), lineWidth: 0.8))
                .frame(width: side * 0.04, height: side * 0.04)
                .shadow(color: .black.opacity(0.5), radius: side * 0.004, y: side * 0.003)
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
                // The spindle motor spins the disc up in a second and a half, and brakes it in two.
                CompactDisc(artwork: artwork)
                    .frame(width: side * 0.86, height: side * 0.86)
                    .modifier(Spinning(isOn: playback.isPlaying, speed: 300, spinUp: 1.5, spinDown: 2))
                // The rainbow the light makes on the disc stays with the light.
                Circle().fill(AngularGradient(colors: [.clear, .cyan.opacity(0.2), .purple.opacity(0.15), .clear, .yellow.opacity(0.15),
                                                       .pink.opacity(0.13), .clear], center: .center))
                    .frame(width: side * 0.86, height: side * 0.86)
                    .mask(DiscShape(hole: DiscRadii.mirror).fill(style: FillStyle(eoFill: true)).frame(width: side * 0.86, height: side * 0.86))
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

/// The disc as a real one is (120 mm across): the 15 mm hole, the clear hub out to 41 mm, the mirror's edge, and the
/// cover printed from 44 mm to the rim.
struct CompactDisc<Artwork: View>: View {
    @ViewBuilder var artwork: () -> Artwork

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size.width
            ZStack {
                // The clear polycarbonate hub: the well shows through it, a little lighter.
                Circle().fill(RadialGradient(colors: [.white.opacity(0.22), .white.opacity(0.38)], center: .center, startRadius: 0,
                                             endRadius: size * DiscRadii.mirror))
                    .overlay(Circle().fill(AngularGradient(colors: [.clear, .white.opacity(0.3), .clear, .clear, .white.opacity(0.22), .clear],
                                                           center: .center)))
                    .frame(width: size * DiscRadii.mirror * 2, height: size * DiscRadii.mirror * 2)
                Circle().strokeBorder(.white.opacity(0.28), lineWidth: size * 0.004)
                    .frame(width: size * DiscRadii.stackingRing * 2, height: size * DiscRadii.stackingRing * 2)
                Circle().strokeBorder(.white.opacity(0.35), lineWidth: size * 0.002)
                    .frame(width: size * DiscRadii.hole * 2 + size * 0.004, height: size * DiscRadii.hole * 2 + size * 0.004)
                // The mirror, then the print.
                DiscShape(hole: DiscRadii.mirror).fill(AngularGradient(colors: [Color(white: 0.85), Color(white: 0.6), Color(white: 0.92), Color(white: 0.55),
                                                                           Color(white: 0.85)], center: .center), style: FillStyle(eoFill: true))
                artwork()
                    .frame(width: size, height: size)
                    .mask(DiscShape(hole: DiscRadii.print, inset: size * 0.008).fill(style: FillStyle(eoFill: true)))
                // The mirror's dark inner edge, the print's edge, and the rim.
                Circle().strokeBorder(Color(white: 0.2).opacity(0.7), lineWidth: size * 0.005)
                    .frame(width: size * DiscRadii.mirror * 2, height: size * DiscRadii.mirror * 2)
                Circle().strokeBorder(.black.opacity(0.15), lineWidth: size * 0.002)
                    .frame(width: size * DiscRadii.print * 2, height: size * DiscRadii.print * 2)
                Circle().strokeBorder(.white.opacity(0.4), lineWidth: size * 0.004)
            }
            .frame(width: size, height: size)
            .mask(DiscShape(hole: DiscRadii.hole).fill(style: FillStyle(eoFill: true)))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// A compact disc's radii over its width: the hole, the hub's stacking ring, the mirror's start, the print's start.
enum DiscRadii {
    static let hole = 0.0625
    static let stackingRing = 0.115
    static let mirror = 0.17
    static let print = 0.183
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
