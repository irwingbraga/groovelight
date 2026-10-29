import SwiftUI

/// What the player's keys and knobs do: the app's transport, its seek, its volume (none where the device's own buttons
/// set it), shuffle and repeat.
public struct DeckControls {
    public enum Repeat: Sendable { case off, all, one }

    public var playPause: () -> Void
    public var previous: () -> Void
    public var next: () -> Void
    public var seek: (TimeInterval) -> Void
    public var volume: Binding<Double>?
    public var isShuffled: Bool
    public var toggleShuffle: () -> Void
    public var repeatMode: Repeat
    public var cycleRepeat: () -> Void

    public init(playPause: @escaping () -> Void, previous: @escaping () -> Void, next: @escaping () -> Void,
                seek: @escaping (TimeInterval) -> Void, volume: Binding<Double>?, isShuffled: Bool, toggleShuffle: @escaping () -> Void,
                repeatMode: Repeat, cycleRepeat: @escaping () -> Void) {
        self.playPause = playPause
        self.previous = previous
        self.next = next
        self.seek = seek
        self.volume = volume
        self.isShuffled = isShuffled
        self.toggleShuffle = toggleShuffle
        self.repeatMode = repeatMode
        self.cycleRepeat = cycleRepeat
    }

    /// Keys doing nothing, for previews and snapshots.
    @MainActor public static var inert: DeckControls { DeckControls(playPause: {}, previous: {}, next: {}, seek: { _ in }, volume: .constant(0.7), isShuffled: false,
                                           toggleShuffle: {}, repeatMode: .all, cycleRepeat: {}) }

    /// Held, the rewind and fast forward keys move through the song this far at each step (of 0.15 s, 33 times as fast).
    static let scanStep: TimeInterval = 5
}

/// Something pressed like a real key: down while touched, its action on release, a tap felt. With `hold`, held past
/// a moment it does that over and over instead (rewind and fast forward scanning through the song).
struct DeckPress<Label: View>: View {
    var title: String
    var tap: () -> Void
    var hold: (() -> Void)? = nil
    @ViewBuilder var label: (_ isPressed: Bool) -> Label
    @State private var isPressed = false
    @State private var didHold = false
    @State private var holding: Task<Void, Never>?

    var body: some View {
        label(isPressed)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressed else { return }
                    isPressed = true
                    didHold = false
                    guard let hold else { return }
                    holding = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        while !Task.isCancelled {
                            didHold = true
                            hold()
                            try? await Task.sleep(for: .milliseconds(150))
                        }
                    }
                }
                .onEnded { _ in
                    holding?.cancel()
                    holding = nil
                    isPressed = false
                    if !didHold { tap() }
                })
            .sensoryFeedback(.impact(weight: .medium, intensity: 0.8), trigger: isPressed) { _, pressed in pressed }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { tap() }
    }
}

// MARK: - Keys

/// The turntable's square aluminum key, its symbol engraved, a lamp above it when it has one.
struct MetalKey: View {
    var title: String
    var symbol: String
    var size: CGSize
    var lamp: Bool? = nil
    var tap: () -> Void
    var hold: (() -> Void)? = nil

    var body: some View {
        DeckPress(title: title, tap: tap, hold: hold) { pressed in
            let corner = min(size.width, size.height) * 0.12
            let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
            ZStack {
                // The hole it sits in.
                shape.fill(Color.black.opacity(0.75)).padding(-size.height * 0.04)
                Textured(texture: .aluminum, brightness: pressed ? 0.02 : 0.12)
                    .overlay(LinearGradient(colors: [.white.opacity(pressed ? 0.05 : 0.3), .clear, .black.opacity(0.25)],
                                            startPoint: .top, endPoint: .bottom))
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.8), .black.opacity(0.4)], startPoint: .top,
                                                               endPoint: .bottom), lineWidth: 1))
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: size.height * 0.3, weight: .heavy))
                            .foregroundStyle(Color.black.opacity(0.6))
                            .shadow(color: .white.opacity(0.6), radius: 0, y: 0.8)
                    }
                    .shadow(color: .black.opacity(pressed ? 0.2 : 0.6), radius: pressed ? 1 : size.height * 0.08, y: pressed ? 0.5 : size.height * 0.06)
                    .offset(y: pressed ? size.height * 0.03 : 0)
            }
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .topTrailing) {
                if let lamp {
                    PilotLamp(isOn: lamp).frame(width: size.height * 0.14).offset(x: -size.height * 0.1, y: size.height * 0.1)
                }
            }
        }
    }
}

/// A cassette deck's piano key: long, its face catching the light, latched down while what it does goes on (Play
/// while playing, Pause while paused).
struct PianoKey: View {
    var title: String
    var symbol: String
    var size: CGSize
    var isLatched = false
    var accent: Color? = nil
    var tap: () -> Void
    var hold: (() -> Void)? = nil

    var body: some View {
        DeckPress(title: title, tap: tap, hold: hold) { pressed in
            let down = pressed || isLatched
            let travel = size.height * (pressed ? 0.14 : isLatched ? 0.1 : 0)
            let corner = size.width * 0.1
            ZStack(alignment: .top) {
                // The slot.
                RoundedRectangle(cornerRadius: corner).fill(Color.black.opacity(0.85))
                    .frame(height: size.height)
                VStack(spacing: 0) {
                    // The top of the key, seen as it comes out of the deck.
                    UnevenRoundedRectangle(topLeadingRadius: corner, topTrailingRadius: corner)
                        .fill(LinearGradient(colors: [Color(white: down ? 0.35 : 0.55), Color(white: down ? 0.22 : 0.4)], startPoint: .top,
                                             endPoint: .bottom))
                        .frame(height: size.height * 0.32 - travel * 0.6)
                    // Its face: aluminum, a band of the deck's color at the bottom.
                    ZStack(alignment: .bottom) {
                        Textured(texture: .aluminum, brightness: down ? 0.0 : 0.16)
                            .overlay(LinearGradient(colors: [.white.opacity(down ? 0.1 : 0.45), .white.opacity(0.05), .black.opacity(0.3)],
                                                    startPoint: .top, endPoint: .bottom))
                        if let accent {
                            Rectangle().fill(accent.opacity(down ? 0.7 : 0.9)).frame(height: size.height * 0.06)
                        }
                    }
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: size.width * 0.28, weight: .heavy))
                            .foregroundStyle(Color.black.opacity(0.62))
                            .shadow(color: .white.opacity(0.5), radius: 0, y: 0.8)
                    }
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: corner, bottomTrailingRadius: corner))
                }
                .padding(.horizontal, size.width * 0.04)
                .offset(y: travel)
                .frame(height: size.height, alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: corner))
                .shadow(color: .black.opacity(0.5), radius: 2, y: 2)
            }
            .frame(width: size.width, height: size.height)
            .animation(.spring(duration: 0.18), value: down)
        }
    }
}

/// A CD player's round key: black rubber in a polished ring, its symbol printed white.
struct RoundKey: View {
    var title: String
    var symbol: String
    var diameter: CGFloat
    var tap: () -> Void
    var hold: (() -> Void)? = nil

    var body: some View {
        DeckPress(title: title, tap: tap, hold: hold) { pressed in
            ZStack {
                Circle().fill(AngularGradient(colors: [Color(white: 0.85), Color(white: 0.35), Color(white: 0.9), Color(white: 0.3), Color(white: 0.85)],
                                              center: .center))
                Circle()
                    .fill(RadialGradient(colors: [Color(white: pressed ? 0.1 : 0.26), Color(white: 0.06)], center: .init(x: 0.4, y: 0.3),
                                         startRadius: 0, endRadius: diameter * 0.5))
                    .padding(diameter * 0.07)
                    .overlay {
                        Image(systemName: symbol)
                            .font(.system(size: diameter * 0.28, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .scaleEffect(pressed ? 0.96 : 1)
            }
            .frame(width: diameter, height: diameter)
            .shadow(color: .black.opacity(0.7), radius: pressed ? 1 : diameter * 0.06, y: pressed ? 0.5 : diameter * 0.04)
        }
    }
}

// MARK: - Knob and switches

/// A knurled aluminum knob, turned by dragging up or down (or across), its line on the printed scale around it.
struct Knob: View {
    var title: String
    @Binding var value: Double
    var diameter: CGFloat
    var onDark = false
    @State private var start: Double?

    var body: some View {
        let angle = -135 + value * 270
        ZStack {
            // The scale: 0 to 10.
            Canvas { context, size in
                let middle = CGPoint(x: size.width / 2, y: size.height / 2)
                for step in 0...10 {
                    let radians = (-135 + Double(step) * 27 - 90) * .pi / 180
                    let inner = size.width * 0.43, outer = size.width * (step.isMultiple(of: 5) ? 0.5 : 0.47)
                    var tick = Path()
                    tick.move(to: CGPoint(x: middle.x + cos(radians) * inner, y: middle.y + sin(radians) * inner))
                    tick.addLine(to: CGPoint(x: middle.x + cos(radians) * outer, y: middle.y + sin(radians) * outer))
                    context.stroke(tick, with: .color(onDark ? .white.opacity(0.7) : .black.opacity(0.6)), lineWidth: max(1, size.width * 0.012))
                }
            }
            ZStack {
                // The knurled skirt.
                Circle().fill(Color(white: 0.2))
                Canvas { context, size in
                    let middle = CGPoint(x: size.width / 2, y: size.height / 2)
                    for index in 0..<72 {
                        let radians = Double(index) / 72 * 2 * .pi
                        var line = Path()
                        line.move(to: CGPoint(x: middle.x + cos(radians) * size.width * 0.4, y: middle.y + sin(radians) * size.width * 0.4))
                        line.addLine(to: CGPoint(x: middle.x + cos(radians) * size.width * 0.5, y: middle.y + sin(radians) * size.width * 0.5))
                        context.stroke(line, with: .color(.white.opacity(index.isMultiple(of: 2) ? 0.55 : 0.15)), lineWidth: 1)
                    }
                }
                // The cap: spun aluminum, the light in a cross on it.
                Circle()
                    .fill(AngularGradient(colors: [Color(white: 0.95), Color(white: 0.55), Color(white: 0.9), Color(white: 0.5), Color(white: 0.95)],
                                          center: .center))
                    .overlay(Circle().fill(RadialGradient(colors: [.white.opacity(0.25), .clear], center: .center, startRadius: 0,
                                                          endRadius: diameter * 0.3)))
                    .overlay(Circle().strokeBorder(.black.opacity(0.3), lineWidth: 1))
                    .padding(diameter * 0.06)
                Capsule().fill(Color.black.opacity(0.75))
                    .frame(width: max(2, diameter * 0.03), height: diameter * 0.2)
                    .offset(y: -diameter * 0.2)
                    .rotationEffect(.degrees(angle))
            }
            .padding(diameter * 0.14)
            .shadow(color: .black.opacity(0.6), radius: diameter * 0.06, y: diameter * 0.05)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(.circle)
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { drag in
                let base = start ?? value
                if start == nil { start = value }
                value = min(max(base + (drag.translation.width - drag.translation.height) / (diameter * 3), 0), 1)
            }
            .onEnded { _ in start = nil })
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            value = min(max(value + (direction == .increment ? 0.1 : -0.1), 0), 1)
        }
    }
}

/// A bat-handle toggle on its nut: up for on, down for off; with three positions, down, middle (towards you) and up.
struct ToggleSwitch: View {
    var title: String
    var positions: Int = 2
    var position: Int
    var value: String
    var size: CGFloat
    var tap: () -> Void

    var body: some View {
        DeckPress(title: title, tap: tap) { _ in
            let lever = position == 0 ? 1.0 : (positions == 3 && position == 1 ? 0 : -1.0)
            ZStack {
                // The nut.
                Circle().fill(RadialGradient(colors: [Color(white: 0.9), Color(white: 0.45)], center: .init(x: 0.35, y: 0.3), startRadius: 0,
                                             endRadius: size * 0.3))
                    .frame(width: size * 0.42, height: size * 0.42)
                    .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1.5)
                // The lever, foreshortened as it leans up or down; in the middle only its round end shows.
                Capsule()
                    .fill(LinearGradient(colors: [Color(white: 0.98), Color(white: 0.55), Color(white: 0.8)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: size * 0.17, height: size * (0.1 + abs(lever) * 0.34))
                    .offset(y: -lever * size * 0.18)
                    .shadow(color: .black.opacity(0.55), radius: 2, y: lever > 0 ? 3 : 1)
                Circle().fill(RadialGradient(colors: [.white, Color(white: 0.6)], center: .init(x: 0.4, y: 0.35), startRadius: 0, endRadius: size * 0.1))
                    .frame(width: size * 0.2, height: size * 0.2)
                    .offset(y: -lever * size * 0.36)
            }
            .frame(width: size, height: size)
            .animation(.spring(duration: 0.15), value: position)
        }
        .accessibilityValue(value)
    }
}

// MARK: - Meters and counters

/// A VU meter: the needle over a backlit amber scale, red past 0 dB, following the level of its channel as a real VU
/// meter does (taking about 300 ms to settle), and falling back while paused.
struct VUMeter: View {
    var channel: Int
    var playback: SkinPlayback
    @State private var needle = VUNeedle()

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                // The bezel and its glass.
                RoundedRectangle(cornerRadius: size.height * 0.08).fill(Color(white: 0.08))
                ZStack {
                    LinearGradient(colors: [Color(red: 1, green: 0.9, blue: 0.62), Color(red: 0.95, green: 0.72, blue: 0.35)], startPoint: .top,
                                   endPoint: .bottom)
                    VUScale().stroke(Color.black.opacity(0.75), lineWidth: max(1, size.height * 0.012))
                    VUScale(red: true).stroke(Color(red: 0.8, green: 0.08, blue: 0.05), lineWidth: max(1.5, size.height * 0.04))
                    Text("VU").font(.system(size: size.height * 0.16, weight: .black, design: .serif)).foregroundStyle(.black.opacity(0.7))
                        .offset(y: size.height * 0.12)
                    Text(channel == 0 ? "L" : "R").font(.system(size: size.height * 0.1, weight: .bold)).foregroundStyle(.black.opacity(0.55))
                        .position(x: size.width * 0.1, y: size.height * 0.75)
                    TimelineView(.animation(paused: !playback.isPlaying)) { context in
                        let level = playback.isPlaying ? needle.position(toward: target(at: context.date), at: context.date) : 0
                        Needle(level: level)
                            .stroke(Color.black.opacity(0.85), style: StrokeStyle(lineWidth: max(1, size.height * 0.018), lineCap: .round))
                            .animation(.spring(duration: 0.5), value: playback.isPlaying)
                    }
                    // The pivot's cover, at the bottom.
                    Rectangle().fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
                        .frame(height: size.height * 0.16)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .clipShape(RoundedRectangle(cornerRadius: size.height * 0.05))
                .overlay(RoundedRectangle(cornerRadius: size.height * 0.05)
                    .fill(LinearGradient(colors: [.white.opacity(0.35), .clear, .clear], startPoint: .topLeading, endPoint: .bottomTrailing)))
                .padding(size.height * 0.06)
            }
            .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
        }
        .accessibilityHidden(true)
    }

    /// Where the needle is going: the channel's level heard now, or where it is not heard here, a made-up one.
    private func target(at date: Date) -> Double {
        guard let levels = playback.levels?(date) else {
            return Self.level(channel: channel, time: playback.time(date), isPlaying: playback.isPlaying)
        }
        return Self.position(rms: channel == 0 ? levels.left : levels.right)
    }

    /// The scale's place (0 at -20 VU, 0.78 at 0, 1 at +3) for an RMS level, 0 VU at -12 dBFS: a mastered song's
    /// loud parts reach the red, as a recording level does.
    static func position(rms: Float) -> Double {
        let vu = 20 * log10(Double(max(rms, 1e-6))) + 12
        let marks: [(vu: Double, at: Double)] = [(-20, 0), (-10, 0.25), (-7, 0.38), (-5, 0.47), (-3, 0.58), (-2, 0.65), (-1, 0.71),
                                                 (0, 0.78), (1, 0.85), (2, 0.92), (3, 1)]
        guard vu > marks[0].vu else { return 0 }
        guard vu < marks[marks.count - 1].vu else { return min(1.04, 1 + (vu - 3) * 0.01) }
        let upper = marks.firstIndex { $0.vu >= vu }!
        let low = marks[upper - 1], high = marks[upper]
        return low.at + (high.at - low.at) * (vu - low.vu) / (high.vu - low.vu)
    }

    /// A made-up level, of a few slow and quick swings like a song's, different for each channel: for music played
    /// on another device, whose sound does not pass through this one.
    static func level(channel: Int, time: TimeInterval, isPlaying: Bool) -> Double {
        guard isPlaying else { return 0 }
        let shift = Double(channel) * 1.7
        let beat = pow(max(sin(time * 2 * .pi * 2.05 + shift), 0), 6) * 0.14
        let swing = sin(time * 1.3 + shift) * 0.08 + sin(time * 4.7 + shift * 2) * 0.06 + sin(time * 11.3 + shift) * 0.04
        return min(max(0.62 + swing + beat, 0.05), 1)
    }
}

/// The needle's movement: it moves toward where the level puts it at a VU meter's pace (99% of the way in 300 ms),
/// starting from rest after a pause.
final class VUNeedle {
    private var value = 0.0
    private var last: Date?

    func position(toward target: Double, at date: Date) -> Double {
        let elapsed = last.map { date.timeIntervalSince($0) } ?? .infinity
        last = date
        if elapsed > 0.25 { value = 0 }
        let step = min(max(elapsed, 0), 0.25)
        value += (target - value) * (1 - exp(-step / 0.065))
        return value
    }
}

/// The VU meter's arc and ticks (or only the red part, past 0 dB).
private struct VUScale: Shape {
    var red = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let pivot = CGPoint(x: rect.midX, y: rect.maxY * 1.12)
        let radius = rect.height * 0.86
        let from = red ? 0.78 : 0.0, to = red ? 1.0 : 0.78
        let start = Self.angle(from), end = Self.angle(to)
        path.addArc(center: pivot, radius: radius, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
        if !red {
            // -20, -10, -7, -5, -3, -2, -1, 0, +1, +2, +3.
            for mark in [0.0, 0.25, 0.38, 0.47, 0.58, 0.65, 0.71, 0.78, 0.85, 0.92, 1.0] {
                let angle = Self.angle(mark)
                let long = mark == 0.78 || mark == 0 || mark == 1
                path.move(to: CGPoint(x: pivot.x + cos(angle) * radius, y: pivot.y + sin(angle) * radius))
                let outer = radius + rect.height * (long ? 0.12 : 0.07)
                path.addLine(to: CGPoint(x: pivot.x + cos(angle) * outer, y: pivot.y + sin(angle) * outer))
            }
        }
        return path
    }

    /// Radians of a level across the scale (from 45° left of upright to 45° right).
    static func angle(_ level: Double) -> Double { (-135 + level * 90) * .pi / 180 }
}

private struct Needle: Shape {
    var level: Double
    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let pivot = CGPoint(x: rect.midX, y: rect.maxY * 1.12)
        let angle = VUScale.angle(level)
        path.move(to: pivot)
        path.addLine(to: CGPoint(x: pivot.x + cos(angle) * rect.height * 1.02, y: pivot.y + sin(angle) * rect.height * 1.02))
        return path
    }
}

/// A tape counter: minutes and seconds on drums that roll on as the tape goes, each turning over as the one after it
/// passes 9 (or 59 seconds), as a mechanical counter does.
struct TapeCounter: View {
    var playback: SkinPlayback

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let drum = size.width / 4.6
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !playback.isPlaying)) { context in
                let seconds = max(playback.time(context.date), 0)
                HStack(spacing: drum * 0.08) {
                    CounterDrum(value: Self.wheel(seconds, unit: 600, radix: 10), size: CGSize(width: drum, height: size.height))
                    CounterDrum(value: Self.wheel(seconds, unit: 60, radix: 10), size: CGSize(width: drum, height: size.height))
                    Text(":").font(.system(size: size.height * 0.5, weight: .bold)).foregroundStyle(.black.opacity(0.6))
                    CounterDrum(value: Self.wheel(seconds, unit: 10, radix: 6), size: CGSize(width: drum, height: size.height))
                    CounterDrum(value: Self.wheel(seconds, unit: 1, radix: 10), size: CGSize(width: drum, height: size.height))
                }
                .frame(width: size.width, height: size.height)
            }
        }
        .accessibilityHidden(true)
    }

    /// A drum's place: its digit, and in the last second before it turns over, how far it has turned.
    static func wheel(_ seconds: Double, unit: Double, radix: Double) -> Double {
        let whole = floor(seconds / unit).truncatingRemainder(dividingBy: radix)
        // The drums turn over in the last second, as the seconds' drum does (it turns all the time).
        let carry = unit == 1 ? seconds - floor(seconds) : max(0, seconds.truncatingRemainder(dividingBy: unit) - (unit - 1))
        return whole + carry
    }
}

/// One drum: white digits on black, the one above and below curving away.
private struct CounterDrum: View {
    var value: Double
    var size: CGSize

    var body: some View {
        let digit = Int(floor(value)) % 10
        let turn = value - floor(value)
        let step = size.height * 0.72
        ZStack {
            Color(white: 0.06)
            ForEach(-1...2, id: \.self) { offset in
                Text("\((digit + offset + 10) % 10)")
                    .font(.system(size: size.height * 0.6, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(white: 0.92))
                    .offset(y: (Double(offset) - turn) * step)
            }
            LinearGradient(stops: [.init(color: .black.opacity(0.85), location: 0), .init(color: .clear, location: 0.3),
                                   .init(color: .clear, location: 0.7), .init(color: .black.opacity(0.85), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: size.width * 0.12))
        .overlay(RoundedRectangle(cornerRadius: size.width * 0.12).strokeBorder(.black, lineWidth: 1))
    }
}

// MARK: - Fluorescent display

/// The color of a vacuum fluorescent display's lit segments.
let vfdColor = Color(red: 0.45, green: 1, blue: 0.9)

/// Text lit on a vacuum fluorescent display, the unlit segments faintly behind it.
struct VFDText: View {
    var text: String
    var ghost: String
    var font: Font
    var color: Color = vfdColor

    var body: some View {
        ZStack(alignment: .leading) {
            Text(ghost).foregroundStyle(color.opacity(0.07))
            Text(text).foregroundStyle(color)
                .shadow(color: color.opacity(0.8), radius: 4)
        }
        .font(font)
        .lineLimit(1)
        .fixedSize()
    }
}

/// A line of the display's 14-segment characters, `count` wide; longer text steps through, a character at a time.
struct VFDMarquee: View {
    var text: String
    var count: Int
    var size: CGFloat
    var isMoving: Bool

    var body: some View {
        let letters = Array(SkinFont.segmentText(text))
        TimelineView(.periodic(from: .now, by: 0.35)) { context in
            let shown: String = {
                guard letters.count > count, isMoving else { return String(letters.prefix(count)) }
                let loop = letters + Array(repeating: " ", count: 4)
                let start = Int(context.date.timeIntervalSinceReferenceDate / 0.35) % loop.count
                return String((0..<count).map { loop[(start + $0) % loop.count] })
            }()
            // DSEG's space is narrow: its blank as wide as a character is "!".
            VFDText(text: shown.padding(toLength: count, withPad: " ", startingAt: 0).replacingOccurrences(of: " ", with: "!"),
                    ghost: String(repeating: "~", count: count), font: SkinFont.letters(size))
        }
    }
}

/// The display's position bar: segments lit up to where the song is; dragged or clicked, it seeks.
struct VFDBar: View {
    var playback: SkinPlayback
    var seek: (TimeInterval) -> Void
    var segments = 40
    @State private var dragging: Double?

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let progress = dragging ?? playback.progress(at: context.date)
                let lit = Int((progress * Double(segments)).rounded(.up))
                HStack(spacing: proxy.size.width * 0.006) {
                    ForEach(0..<segments, id: \.self) { index in
                        Rectangle().fill(index < lit ? vfdColor : vfdColor.opacity(0.07))
                            .shadow(color: index < lit ? vfdColor.opacity(0.7) : .clear, radius: 3)
                    }
                }
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in dragging = min(max(drag.location.x / proxy.size.width, 0), 1) }
                .onEnded { drag in
                    seek(min(max(drag.location.x / proxy.size.width, 0), 1) * playback.duration)
                    dragging = nil
                })
        }
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityAdjustableAction { direction in
            seek(min(max(playback.time(.now) + (direction == .increment ? 10 : -10), 0), playback.duration))
        }
    }
}

/// Minutes and seconds, as the displays and counters show them.
func clockText(_ seconds: TimeInterval) -> String {
    let whole = Int(max(seconds, 0))
    return String(format: "%02d:%02d", whole / 60 % 100, whole % 60)
}
