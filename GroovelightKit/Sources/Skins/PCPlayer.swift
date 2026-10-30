import SwiftUI

// MARK: - PC Player

/// Now Playing as a desktop music player of the late 1990s, after the classic two-window skin: the main window (the
/// title bar, the green display with the time and a spectrum, the scrolling title, the bit rate and sample rate, mono
/// and stereo, the volume and balance sliders, EQ and PL, the position bar and the transport keys) docked over the
/// playlist window (the queue in green, the song playing in white). Each is drawn on the original's pixel grid (the
/// main window 275 by 116) and scaled up to the screen, so every part sits where it does in the original.
///
/// The windows are one above the other, centered (as wide as the screen allows while leaving the playlist room),
/// and on either side of a fold that divides the screen. `overlay` (the lyrics, Up Next) takes the playlist's place
/// inside its window; `accessory` (the app's own buttons) goes under it.
struct PCPlayer<Accessory: View>: View {
    var size: CGSize
    var top: CGFloat
    var fold: CGRect?
    var playback: SkinPlayback
    var controls: DeckControls
    var playlist: SkinPlaylist?
    var overlay: AnyView?
    var theme: PCTheme = .classic
    var artwork: AnyView = AnyView(Color.clear)
    @ViewBuilder var accessory: () -> Accessory
    @State private var showsPlaylist = true

    var body: some View {
        if theme == .corona {
            CoronaPlayer(size: size, top: top, fold: fold, playback: playback, controls: controls, playlist: playlist, overlay: overlay,
                         artwork: artwork, showsPlaylist: $showsPlaylist)
        } else {
            classic
        }
    }

    private var classic: some View {
        let layout = PCLayout(size: size, top: top, fold: fold, accessoryHeight: Accessory.self == EmptyView.self ? 0 : PCLayout.accessoryHeight)
        return ZStack(alignment: .topLeading) {
            PCMainWindow(scale: layout.scale, playback: playback, controls: controls, showsPlaylist: $showsPlaylist)
                .frame(width: layout.main.width, height: layout.main.height)
                .offset(x: layout.main.minX, y: layout.main.minY)
            if showsPlaylist {
                PCPlaylistWindow(scale: layout.scale, size: layout.playlist.size, playback: playback, controls: controls, playlist: playlist,
                                 overlay: overlay)
                    .frame(width: layout.playlist.width, height: layout.playlist.height)
                    .offset(x: layout.playlist.minX, y: layout.playlist.minY)
                    .transition(.opacity)
            }
            accessory()
                .foregroundStyle(.white)
                .tint(.white)
                .frame(width: layout.accessory.width, height: layout.accessory.height)
                .offset(x: layout.accessory.minX, y: layout.accessory.minY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.2), value: showsPlaylist)
    }
}

/// Where the PC Player's windows go, and the scale they are drawn at (screen points per pixel of the original).
struct PCLayout {
    var main: CGRect
    var playlist: CGRect
    var accessory: CGRect
    var scale: CGFloat

    static let mainSize = CGSize(width: 275, height: 116)
    static let accessoryHeight: CGFloat = 52

    init(size: CGSize, top: CGFloat, fold: CGRect?, accessoryHeight: CGFloat = PCLayout.accessoryHeight) {
        let margin = max(8, min(size.width, size.height) * 0.02)
        let area = CGRect(x: margin, y: top, width: max(size.width - margin * 2, 1), height: max(size.height - top - margin, 1))
        let aspect = Self.mainSize.width / Self.mainSize.height
        if let fold, fold.height >= size.height * 0.5, fold.minX > area.minX + 120, fold.maxX < area.maxX - 120 {
            // Left and right of an upright fold: the main window on the left, the playlist on the right.
            let left = CGRect(x: area.minX, y: area.minY, width: fold.minX - margin - area.minX, height: area.height)
            let width = min(left.width, left.height * 0.6 * aspect, Self.mainSize.width * 3)
            scale = width / Self.mainSize.width
            main = CGRect(x: left.midX - width / 2, y: left.minY, width: width, height: width / aspect)
            accessory = CGRect(x: left.minX, y: main.maxY + margin, width: left.width, height: accessoryHeight)
            playlist = CGRect(x: fold.maxX + margin, y: area.minY, width: area.maxX - fold.maxX - margin, height: area.height)
        } else if let fold, fold.width >= size.width * 0.5, fold.minY > area.minY + 120, fold.maxY < area.maxY - 120 {
            // Above and below a level fold.
            let upper = fold.minY - margin - area.minY
            let width = min(area.width, upper * aspect, Self.mainSize.width * 3)
            scale = width / Self.mainSize.width
            main = CGRect(x: area.midX - width / 2, y: area.minY, width: width, height: width / aspect)
            playlist = CGRect(x: area.midX - width / 2, y: fold.maxY + margin, width: width,
                              height: area.maxY - fold.maxY - margin - accessoryHeight)
            accessory = CGRect(x: area.minX, y: playlist.maxY, width: area.width, height: accessoryHeight)
        } else {
            // Docked, the playlist under the main window: as wide as the screen while the playlist keeps half the height.
            let width = min(area.width, (area.height - accessoryHeight) * 0.45 * aspect, Self.mainSize.width * 3)
            scale = width / Self.mainSize.width
            main = CGRect(x: area.midX - width / 2, y: area.minY, width: width, height: width / aspect)
            playlist = CGRect(x: main.minX, y: main.maxY, width: width, height: max(area.maxY - main.maxY - accessoryHeight, 60))
            accessory = CGRect(x: area.minX, y: playlist.maxY, width: area.width, height: accessoryHeight)
        }
    }
}


/// The classic base skin's colors, as its bitmaps have them.
enum PCColors {
    static let digits = Color(hex: 0x00F800)
    static let text = Color(hex: 0x00E200)
    static let listText = Color(hex: 0x00FF00)
    static let dots = Color(hex: 0x182129)
    static let label = Color(hex: 0x9C9CB4)
    static let keyFace = Color(hex: 0xBDCED6)
    static let keyLight = Color(hex: 0xEFFFFF)
    static let keyEdge = Color(hex: 0xADB5C6)
    static let keyShade = Color(hex: 0x7B8494)
    static let keyDark = Color(hex: 0x4A5A6B)
    static let glyph = Color(hex: 0x97A8B9)
    static let ink = Color(hex: 0x2F374D)
    static let frameLight = Color(hex: 0x73738A)
    static let frameDark = Color(hex: 0x0F0F17)
    static let goldLight = Color(hex: 0xECCE7A)
    static let goldDim = Color(hex: 0xA3946A)
    static let goldDark = Color(hex: 0x45413C)
    /// The spectrum's colors, from the top of a bar to its foot (VISCOLOR's 2 to 17), and its peaks.
    static let spectrum: [Color] = [0xEF3110, 0xCE2910, 0xD65A00, 0xD66600, 0xD67300, 0xC67B08, 0xDEA518, 0xD6B521, 0xBDDE29, 0x94DE21,
                                    0x29CE10, 0x32BE10, 0x39B510, 0x319C08, 0x299400, 0x188408].map { Color(hex: $0) }
    static let peak = Color(hex: 0x969696)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension View {
    /// Placed at (`x`, `y`), `width` by `height` on the original's pixel grid, drawn at `scale`.
    func pc(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ scale: CGFloat) -> some View {
        frame(width: width * scale, height: height * scale).position(x: (x + width / 2) * scale, y: (y + height / 2) * scale)
    }
}

/// Drawing on the original's pixel grid: rectangles of whole pixels at `u` points each.
fileprivate struct Pixels {
    var context: GraphicsContext
    var u: CGFloat

    func fill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color) {
        guard w > 0, h > 0 else { return }
        context.fill(Path(CGRect(x: x * u, y: y * u, width: w * u, height: h * u)), with: .color(color))
    }

    /// An engraved line around a rectangle: shaded above and on the left, lit below and on the right (the base
    /// skin's grooves, a display's edge).
    func groove(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, dark: Color = Color(hex: 0x101019), light: Color = PCColors.frameLight) {
        fill(x, y, w, 1, dark)
        fill(x, y, 1, h, dark)
        fill(x, y + h - 1, w, 1, light)
        fill(x + w - 1, y, 1, h, light)
    }
}

/// A window's face as the base skin paints it: nearly black at its left edge, lightening to a slate violet a little
/// right of the middle and darkening again to the right, with a darker band low across it (`band`, as a fraction of
/// the height, nil for none).
struct PCWindowFace: View {
    var band: ClosedRange<Double>? = nil

    var body: some View {
        ZStack {
            LinearGradient(stops: [0x0D0D14, 0x1A1927, 0x202033, 0x27283E, 0x2E2D48, 0x343351, 0x383758, 0x39395A, 0x383757, 0x343351,
                                   0x2E2D47, 0x26263B].enumerated().map { .init(color: Color(hex: $0.element), location: Double($0.offset) / 11) },
                           startPoint: .leading, endPoint: .trailing)
            if let band {
                LinearGradient(stops: [.init(color: .clear, location: band.lowerBound - 0.08), .init(color: .black.opacity(0.13), location: band.lowerBound),
                                       .init(color: .black.opacity(0.13), location: band.upperBound), .init(color: .clear, location: band.upperBound + 0.08)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

/// A window's title bar: the dark bar, the gold double rails on either side of the name in white, the menu's gold
/// squiggle on the left (the main window's), and the minimize, shade and close buttons on the right (for the look:
/// the app's own buttons do those things).
struct PCTitleBar: View {
    var title: String
    var scale: CGFloat
    /// The bar's height in original pixels (the main window's is 14, the playlist's 20).
    var height: CGFloat = 14
    var isPlaylist = false

    var body: some View {
        GeometryReader { proxy in
            let u = scale
            let width = proxy.size.width / u
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    let px = Pixels(context: context, u: u)
                    // The rails: two gold lines with a dark one between, a light edge on the upper and a shadow under.
                    let top: CGFloat = isPlaylist ? 5 : 4
                    let textWidth = CGFloat(title.count) * (isPlaylist ? 6.4 : 7.2) + 10
                    let left = isPlaylist ? 7.0 : 20.0
                    let right = width - (isPlaylist ? 20 : 34)
                    for (from, to) in [(left, width / 2 - textWidth / 2), (width / 2 + textWidth / 2, right)] where to - from > 4 {
                        px.fill(from, top, to - from, 7, Color(hex: 0x1E1F25))
                        px.fill(from + 1, top + 1, to - from - 2, 1, PCColors.goldLight)
                        px.fill(from + 1, top + 2, to - from - 2, 1, .white)
                        px.fill(from + 1, top + 3, to - from - 2, 1, PCColors.goldDark)
                        px.fill(from + 1, top + 4, to - from - 2, 1, PCColors.goldDim)
                        px.fill(from + 1, top + 5, to - from - 2, 1, PCColors.goldLight)
                        px.fill(from + 1, top + 6, to - from - 2, 1, Color(hex: 0x25262C))
                        // Rounded ends.
                        for x in [from + 1, to - 2] {
                            px.fill(x, top + 1, 1, 1, PCColors.goldDim)
                            px.fill(x, top + 5, 1, 1, Color(hex: 0x736C52))
                        }
                    }
                    if !isPlaylist {
                        // The menu's squiggle.
                        for (x, y) in [(8, 7), (9, 6), (9, 5), (10, 4), (11, 5), (11, 6), (12, 7), (13, 8), (13, 9), (14, 10), (15, 9), (15, 8), (16, 7)] {
                            px.fill(CGFloat(x), CGFloat(y), 1, 1, Color(hex: 0xEFBE66))
                        }
                    }
                    // Minimize and shade: little domes, silver over olive; close: a gold cross in a dark ring.
                    let buttons: [CGFloat] = isPlaylist ? [width - 20, width - 11] : [width - 31, width - 21, width - 11]
                    let y: CGFloat = isPlaylist ? 4 : 3
                    for (index, x) in buttons.enumerated() {
                        if index < buttons.count - 1 {
                            px.fill(x + 2, y, 5, 1, Color(hex: 0xB3B6B8))
                            px.fill(x + 1, y + 1, 7, 1, Color(hex: 0xCEE2D1))
                            px.fill(x, y + 2, 9, 4, Color(hex: 0x6B5D43))
                            px.fill(x, y + 5, 9, 2, Color(hex: 0x5A573A))
                            px.fill(x + 1, y + 7, 7, 1, PCColors.goldDark)
                        } else {
                            px.fill(x + 2, y, 5, 1, Color(hex: 0x352D10))
                            px.fill(x, y + 2, 1, 5, Color(hex: 0x352D10))
                            px.fill(x + 8, y + 2, 1, 5, Color(hex: 0x352D10))
                            px.fill(x + 2, y + 8, 5, 1, Color(hex: 0x352D10))
                            for step in 0..<7 {
                                px.fill(x + 1 + CGFloat(step), y + 1 + CGFloat(step), 1, 1, Color(hex: 0xB69C54))
                                px.fill(x + 7 - CGFloat(step), y + 1 + CGFloat(step), 1, 1, Color(hex: 0xB69C54))
                            }
                            px.fill(x + 4, y + 4, 1, 1, .white)
                        }
                    }
                }
                Text(title)
                    .font(.system(size: (isPlaylist ? 7 : 8.5) * u, weight: .black))
                    .tracking(0.4 * u)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 0, x: u * 0.5, y: u * 0.5)
                    .fixedSize()
                    .position(x: proxy.size.width / 2, y: (isPlaylist ? 8.5 : 7.5) * u)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A key's face as the base skin draws it: pale blue-gray, a white inner highlight and a gray edge above and on the
/// left, two shades below and on the right; held, it sinks dark and black-edged.
private struct PCKeyFace: View {
    var pressed: Bool
    var scale: CGFloat

    var body: some View {
        Canvas { context, size in
            let px = Pixels(context: context, u: scale)
            let w = size.width / scale, h = size.height / scale
            if pressed {
                px.fill(0, 0, w, h, Color(hex: 0x080810))
                px.fill(1, 1, w - 2, h - 2, Color(hex: 0x7B8C9C))
                px.fill(2, 2, w - 4, 1, Color(hex: 0xADBDC6))
                px.fill(2, 2, 1, h - 4, Color(hex: 0xADBDC6))
            } else {
                px.fill(0, 0, w, h, PCColors.keyFace)
                px.fill(0, 0, w, 1, PCColors.keyEdge)
                px.fill(0, 0, 1, h, PCColors.keyEdge)
                px.fill(1, 1, w - 2, 1, PCColors.keyLight)
                px.fill(1, 1, 1, h - 2, PCColors.keyLight)
                px.fill(2, h - 3, w - 4, 1, PCColors.keyEdge)
                px.fill(w - 3, 2, 1, h - 4, PCColors.keyEdge)
                px.fill(1, h - 2, w - 2, 1, PCColors.keyShade)
                px.fill(w - 2, 1, 1, h - 2, PCColors.keyShade)
                px.fill(0, h - 1, w, 1, PCColors.keyDark)
                px.fill(w - 1, 0, 1, h, PCColors.keyDark)
            }
        }
    }
}

/// A key of the player: tapped (or held, `hold`, repeating) it does its job.
private struct PCKey<Label: View>: View {
    var title: String
    var scale: CGFloat
    var isEnabled = true
    var tap: () -> Void
    var hold: (() -> Void)? = nil
    @ViewBuilder var label: () -> Label

    var body: some View {
        DeckPress(title: title, tap: isEnabled ? tap : {}, hold: isEnabled ? hold : nil) { pressed in
            ZStack {
                PCKeyFace(pressed: pressed, scale: scale)
                label()
                    .offset(x: pressed ? scale : 0, y: pressed ? scale : 0)
                    .opacity(isEnabled ? 1 : 0.45)
            }
        }
    }
}

/// The transport keys' glyphs, as on the base skin.
struct PCGlyph: Shape {
    enum Kind { case previous, play, pause, stop, next, eject }
    var kind: Kind

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        func triangle(_ x: CGFloat, pointingRight: Bool, width: CGFloat) {
            path.move(to: CGPoint(x: rect.minX + x + (pointingRight ? 0 : width), y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + x + (pointingRight ? width : 0), y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX + x + (pointingRight ? 0 : width), y: rect.maxY))
            path.closeSubpath()
        }
        switch kind {
        case .previous:
            path.addRect(CGRect(x: rect.minX, y: rect.minY, width: w * 0.25, height: h))
            triangle(w * 0.35, pointingRight: false, width: w * 0.65)
        case .play:
            triangle(w * 0.15, pointingRight: true, width: w * 0.75)
        case .pause:
            path.addRect(CGRect(x: rect.minX + w * 0.1, y: rect.minY, width: w * 0.3, height: h))
            path.addRect(CGRect(x: rect.minX + w * 0.6, y: rect.minY, width: w * 0.3, height: h))
        case .stop:
            path.addRect(CGRect(x: rect.minX + w * 0.05, y: rect.minY, width: w * 0.9, height: h))
        case .next:
            triangle(0, pointingRight: true, width: w * 0.65)
            path.addRect(CGRect(x: rect.minX + w * 0.75, y: rect.minY, width: w * 0.25, height: h))
        case .eject:
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.58))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.58))
            path.closeSubpath()
            path.addRect(CGRect(x: rect.minX, y: rect.minY + h * 0.75, width: w, height: h * 0.25))
        }
        return path
    }
}

/// A glyph engraved in a key: shaded on its upper and left edges, lit on its lower and right ones, gray within.
private struct PCGlyphLabel: View {
    var kind: PCGlyph.Kind
    var scale: CGFloat
    var width: CGFloat
    var height: CGFloat

    var body: some View {
        Canvas { context, size in
            let shape = PCGlyph(kind: kind).path(in: CGRect(origin: .zero, size: CGSize(width: size.width - scale, height: size.height - scale)))
            let shifted = shape.offsetBy(dx: scale, dy: scale)
            context.fill(shifted, with: .color(PCColors.keyLight))
            context.fill(shape, with: .color(PCColors.keyDark))
            var inner = context
            inner.clip(to: shifted)
            inner.fill(shape, with: .color(PCColors.glyph))
        }
        .frame(width: (width + 1) * scale, height: (height + 1) * scale)
    }
}

/// A key's small light: green when on, its edge shaded above and lit below.
private struct PCLed: View {
    var isOn: Bool
    var scale: CGFloat

    var body: some View {
        Canvas { context, _ in
            let px = Pixels(context: context, u: scale)
            px.fill(0, 0, 5, 1, PCColors.keyDark)
            px.fill(0, 0, 1, 4, PCColors.keyDark)
            px.fill(1, 1, 3, 2, isOn ? Color(hex: 0x00D600) : Color(hex: 0x8C9AA8))
            px.fill(1, 3, 4, 1, Color(hex: 0xD5DEF2))
            px.fill(4, 1, 1, 3, Color(hex: 0xD5DEF2))
        }
        .frame(width: 5 * scale, height: 4 * scale)
        .shadow(color: isOn ? Color(hex: 0x00D600).opacity(0.6) : .clear, radius: scale)
    }
}

/// Lettering on a key, in the skin's dark ink.
private func keyText(_ text: String, _ scale: CGFloat) -> some View {
    Text(text).font(SkinFont.pixel(6 * scale, bold: true)).foregroundStyle(PCColors.ink).fixedSize()
}

// MARK: Main window

private struct PCMainWindow: View {
    var scale: CGFloat
    var playback: SkinPlayback
    var controls: DeckControls
    @Binding var showsPlaylist: Bool
    @State private var showsRemaining = false

    var body: some View {
        let s = scale
        ZStack(alignment: .topLeading) {
            // The window: its face, its edges and the groove within them; the display's black panel, the title's,
            // the bit rate's and sample rate's, and the position bar's groove.
            PCWindowFace(band: 0.57...0.73)
            Canvas { context, size in
                let px = Pixels(context: context, u: s)
                px.fill(0, 0, 275, 1, Color(hex: 0x26263B))
                px.fill(0, 0, 1, 116, PCColors.frameDark)
                px.fill(1, 1, 273, 1, PCColors.frameLight)
                px.fill(1, 1, 1, 114, Color(hex: 0x5C5C63))
                px.fill(0, 115, 275, 1, Color(hex: 0x28273E))
                px.fill(274, 0, 1, 116, Color(hex: 0x1E1E2F))
                px.fill(4, 12, 267, 2, Color(hex: 0x101019))
                px.fill(4, 12, 2, 100, Color(hex: 0x101019))
                px.fill(6, 14, 263, 1, PCColors.frameLight)
                px.fill(6, 14, 1, 98, Color(hex: 0x5F5F68))
                px.fill(4, 110, 267, 2, Color(hex: 0x101019))
                px.fill(4, 112, 267, 1, PCColors.frameLight)
                px.fill(267, 12, 2, 100, Color(hex: 0x101019))
                px.fill(269, 12, 1, 101, PCColors.frameLight)
                // The display, with its grid of faint dots and the spectrum's dotted axes.
                px.fill(11, 22, 93, 43, .black)
                for y in stride(from: 24, to: 64, by: 2) {
                    for x in stride(from: 24, to: 102, by: 2) { px.fill(CGFloat(x), CGFloat(y), 1, 1, PCColors.dots) }
                }
                for y in stride(from: 43, to: 61, by: 2) { px.fill(23, CGFloat(y), 1, 1, Color(hex: 0x3E6AB2)) }
                for x in stride(from: 24, to: 101, by: 2) { px.fill(CGFloat(x), 61, 1, 1, Color(hex: 0x3E6AB2)) }
                px.groove(10, 21, 95, 45, light: Color(hex: 0x5F5F68))
                for (x, y, w, h) in [(111.0, 24.0, 154.0, 12.0), (111, 43, 15, 8), (156, 43, 10, 8)] {
                    px.fill(x, y, w, h, .black)
                    px.groove(x - 1, y - 1, w + 2, h + 2, light: Color(hex: 0x5F5F68))
                }
                px.fill(16, 72, 248, 12, Color(hex: 0x1C1B2B))
                px.fill(16, 72, 248, 2, Color(hex: 0x11111B))
                px.fill(16, 72, 2, 12, Color(hex: 0x11111B))
                px.fill(16, 83, 248, 1, Color(hex: 0x656572))
                px.fill(263, 72, 1, 12, Color(hex: 0x656572))
            }
            PCTitleBar(title: "GROOVELIGHT", scale: s).pc(0, 0, 275, 14, s)
            VStack(spacing: 1.4 * s) {
                ForEach(["O", "A", "I", "D", "V"], id: \.self) { letter in
                    Text(letter).font(SkinFont.pixel(6 * s)).foregroundStyle(Color(hex: 0x6A6A80))
                }
            }
            .pc(11, 23, 8, 40, s)
            PlayState(playback: playback, scale: s).pc(25, 28, 9, 9, s)
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let time = playback.time(context.date)
                let shown = showsRemaining ? max(playback.duration - time, 0) : time
                HStack(spacing: 0) {
                    Text(showsRemaining ? "-" : " ").font(SkinFont.pixel(10 * s, bold: true))
                    Text(clockText(shown)).font(SkinFont.digits(13 * s))
                }
                .foregroundStyle(PCColors.digits)
                // Paused, the time blinks as on the classic player.
                .opacity(!playback.isPlaying && time > 0.5 && Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0 ? 0.1 : 1)
            }
            .pc(34, 25, 68, 15, s)
            .contentShape(.rect)
            .onTapGesture { showsRemaining.toggle() }
            .accessibilityLabel(showsRemaining ? "Time remaining" : "Time")
            PCSpectrum(playback: playback, scale: s).pc(24, 43, 76, 16, s)
            PCMarquee(text: marqueeText, scale: s).pc(111, 24, 154, 12, s)
            infoText(playback.format?.kbps.map(String.init) ?? "", at: 111, width: 15)
            label("kbps", at: 128, width: 22)
            infoText(playback.format?.kHz.map(String.init) ?? "", at: 156, width: 10)
            label("kHz", at: 168, width: 18)
            let channels = playback.format?.channels
            Text("mono").font(SkinFont.pixel(6 * s, bold: true))
                .foregroundStyle(channels == 1 ? PCColors.text : Color(hex: 0x4C4C66)).fixedSize().pc(212, 42, 26, 10, s)
            Text("stereo").font(SkinFont.pixel(6 * s, bold: true))
                .foregroundStyle(channels.map { $0 >= 2 } ?? true ? PCColors.text : Color(hex: 0x4C4C66)).fixedSize().pc(238, 42, 32, 10, s)
            // Volume, balance, EQ and PL.
            PCSlider(value: controls.volume ?? .constant(1), scale: s, kind: .volume, title: "Volume")
                .disabled(controls.volume == nil)
                .pc(107, 57, 68, 13, s)
            PCSlider(value: .constant(0.5), scale: s, kind: .balance, title: "Balance").pc(177, 57, 38, 13, s)
                .allowsHitTesting(false).accessibilityHidden(true)
            toggleKey("EQ", isOn: controls.equalizer?.wrappedValue ?? false, isEnabled: controls.equalizer != nil) {
                controls.equalizer?.wrappedValue.toggle()
            }
            .pc(219, 58, 23, 12, s)
            toggleKey("PL", isOn: showsPlaylist) { showsPlaylist.toggle() }
                .pc(242, 58, 23, 12, s)
            PCPositionBar(playback: playback, seek: controls.seek, scale: s).pc(16, 72, 248, 10, s)
            // The transport keys, eject, shuffle, repeat and love.
            PCKey(title: "Previous", scale: s, tap: controls.previous, hold: scan(-1)) {
                PCGlyphLabel(kind: .previous, scale: s, width: 9, height: 8)
            }
            .pc(16, 88, 23, 18, s)
            PCKey(title: "Play", scale: s, tap: { playback.isPlaying ? controls.seek(0) : controls.playPause() }) {
                PCGlyphLabel(kind: .play, scale: s, width: 8, height: 9)
            }
            .pc(39, 88, 23, 18, s)
            PCKey(title: "Pause", scale: s, tap: { if playback.isPlaying || playback.time(.now) > 0.5 { controls.playPause() } }) {
                PCGlyphLabel(kind: .pause, scale: s, width: 8, height: 9)
            }
            .pc(62, 88, 23, 18, s)
            PCKey(title: "Stop", scale: s, tap: {
                if playback.isPlaying { controls.playPause() }
                controls.seek(0)
            }) {
                PCGlyphLabel(kind: .stop, scale: s, width: 9, height: 9)
            }
            .pc(85, 88, 23, 18, s)
            PCKey(title: "Next", scale: s, tap: controls.next, hold: scan(1)) {
                PCGlyphLabel(kind: .next, scale: s, width: 9, height: 8)
            }
            .pc(108, 88, 22, 18, s)
            PCKey(title: "Close Now Playing", scale: s, isEnabled: controls.eject != nil, tap: { controls.eject?() }) {
                PCGlyphLabel(kind: .eject, scale: s, width: 10, height: 8)
            }
            .pc(136, 89, 22, 16, s)
            PCKey(title: "Shuffle", scale: s, tap: controls.toggleShuffle) {
                HStack(spacing: 2.5 * s) {
                    PCLed(isOn: controls.isShuffled, scale: s)
                    keyText("SHUFFLE", s)
                }
            }
            .accessibilityValue(controls.isShuffled ? "On" : "Off")
            .pc(164, 89, 46, 15, s)
            PCKey(title: "Repeat", scale: s, tap: controls.cycleRepeat) {
                HStack(spacing: 2 * s) {
                    PCLed(isOn: controls.repeatMode != .off, scale: s)
                    Image(systemName: controls.repeatMode == .one ? "repeat.1" : "repeat")
                        .font(.system(size: 7 * s, weight: .heavy)).foregroundStyle(PCColors.ink)
                }
            }
            .accessibilityValue(controls.repeatMode == .off ? "Off" : controls.repeatMode == .one ? "One" : "All")
            .pc(210, 89, 28, 15, s)
            PCKey(title: controls.love?.wrappedValue == true ? "Unlove" : "Love", scale: s, isEnabled: controls.love != nil,
                  tap: { controls.love?.wrappedValue.toggle() }) {
                Image(systemName: controls.love?.wrappedValue == true ? "heart.fill" : "heart")
                    .font(.system(size: 7.5 * s, weight: .black))
                    .foregroundStyle(controls.love?.wrappedValue == true ? Color(hex: 0xD81830) : PCColors.ink)
            }
            .pc(239, 89, 15, 15, s)
            PCLogo(scale: s).pc(252, 89, 16, 17, s)
        }
        .frame(width: 275 * s, height: 116 * s, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    /// "ARTIST - TITLE (3:45)", as the classic player scrolls it.
    private var marqueeText: String {
        let name = [playback.artist, playback.title].filter { !$0.isEmpty }.joined(separator: " - ")
        return "\(name) (\(clockText(playback.duration).trimmingPrefix("0")))".uppercased()
    }

    private func infoText(_ text: String, at x: CGFloat, width: CGFloat) -> some View {
        Text(text).font(SkinFont.pixel(6 * scale)).foregroundStyle(PCColors.text).fixedSize().pc(x, 43, width, 8, scale)
    }

    private func label(_ text: String, at x: CGFloat, width: CGFloat) -> some View {
        Text(text).font(SkinFont.pixel(6 * scale, bold: true)).foregroundStyle(.white).fixedSize().pc(x, 42, width, 10, scale)
    }

    private func toggleKey(_ title: String, isOn: Bool, isEnabled: Bool = true, tap: @escaping () -> Void) -> some View {
        PCKey(title: title, scale: scale, isEnabled: isEnabled, tap: tap) {
            HStack(spacing: 2 * scale) {
                PCLed(isOn: isOn, scale: scale)
                keyText(title, scale)
            }
        }
        .accessibilityValue(isOn ? "On" : "Off")
    }

    private func scan(_ direction: Double) -> () -> Void {
        { controls.seek(min(max(playback.time(.now) + direction * DeckControls.scanStep, 0), max(playback.duration - 1, 0))) }
    }
}

/// Playing, paused or stopped: a green arrow, two bars or a square.
private struct PlayState: View {
    var playback: SkinPlayback
    var scale: CGFloat

    var body: some View {
        let paused = !playback.isPlaying && playback.time(.now) > 0.5
        let green = Color(hex: 0x00E800)
        ZStack {
            if playback.isPlaying {
                PCGlyph(kind: .play).fill(green).padding(.horizontal, scale)
            } else if paused {
                PCGlyph(kind: .pause).fill(green).padding(scale)
            } else {
                PCGlyph(kind: .stop).fill(green).padding(1.5 * scale)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Text going by from right to left in a display, in the pixel lettering; still while it fits.
private struct PCMarquee: View {
    var text: String
    var scale: CGFloat
    @State private var textWidth: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let gap = "  ***  "
            let fits = textWidth <= proxy.size.width - 4 * scale
            TimelineView(.animation(minimumInterval: 1 / 30, paused: fits)) { context in
                let loop = textWidth + gapWidth
                // 24 original pixels a second, a pixel at a time, as the classic display steps.
                let pixels = (context.date.timeIntervalSinceReferenceDate * 24).rounded(.down) * scale
                let offset = fits || loop <= 0 ? 0 : -pixels.truncatingRemainder(dividingBy: loop)
                HStack(spacing: 0) {
                    line(text)
                    if !fits {
                        line(gap)
                        line(text)
                    }
                }
                .offset(x: offset + 2 * scale)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            }
            .clipped()
        }
        .accessibilityLabel(text)
    }

    private var gapWidth: CGFloat { 7 * 5.2 * scale }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(SkinFont.pixel(7.5 * scale))
            .foregroundStyle(PCColors.text)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                if text == self.text { textWidth = width }
            }
    }
}

/// The display's spectrum: nineteen bars in the skin's colors (green at the foot to red at the top), each with a
/// gray peak that falls slowly.
struct PCSpectrum: View {
    var playback: SkinPlayback
    var scale: CGFloat
    @State private var state = PCSpectrumState()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playback.isPlaying && state.isQuiet)) { context in
            let target = playback.isPlaying ? Self.target(playback: playback, at: context.date) : Array(repeating: 0, count: PCSpectrumState.bars)
            let (bars, peaks) = state.update(toward: target, at: context.date)
            Canvas { canvas, size in
                let px = Pixels(context: canvas, u: scale)
                let rows = 16
                for index in 0..<PCSpectrumState.bars {
                    let x = CGFloat(index * 4)
                    let height = Int((Double(rows) * bars[index]).rounded())
                    for row in 0..<height {
                        // Each row its color: a bar's foot green, its top as far up the colors as it reaches.
                        let color = PCColors.spectrum[max(0, PCColors.spectrum.count - 1 - row)]
                        px.fill(x, CGFloat(rows - 1 - row), 3, 1, color)
                    }
                    let peak = Int((Double(rows) * peaks[index]).rounded())
                    if peak > 0 { px.fill(x, CGFloat(rows - peak), 3, 1, PCColors.peak) }
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Each bar's level: the analyzer's bands gathered into nineteen, or (not heard here) a made-up dance.
    static func target(playback: SkinPlayback, at date: Date) -> [Double] {
        let count = PCSpectrumState.bars
        if let bands = playback.spectrum?(date), !bands.isEmpty {
            return (0..<count).map { index in
                let from = index * bands.count / count, to = max((index + 1) * bands.count / count, from + 1)
                let slice = bands[from..<min(to, bands.count)]
                return min(Double(slice.max() ?? 0) * 2.2, 1)
            }
        }
        let time = playback.time(date)
        return (0..<count).map { index in
            let i = Double(index)
            let tilt = 1 - i / Double(count) * 0.55
            let swing = 0.5 + 0.25 * sin(time * (3.1 + i * 0.37) + i) + 0.2 * sin(time * (7.3 + i * 0.21) + i * 2.1)
            let beat = pow(max(sin(time * 2 * .pi * 2.05), 0), 8) * 0.3 * tilt
            return min(max(swing * tilt + beat, 0.02), 1)
        }
    }
}

/// The spectrum's bars falling at their pace and their peaks held a moment, then falling.
final class PCSpectrumState {
    static let bars = 19
    private var levels = Array(repeating: 0.0, count: bars)
    private var peaks = Array(repeating: 0.0, count: bars)
    private var held = Array(repeating: 0.0, count: bars)
    private var last: Date?

    var isQuiet: Bool { levels.allSatisfy { $0 < 0.01 } && peaks.allSatisfy { $0 < 0.01 } }

    func update(toward target: [Double], at date: Date) -> ([Double], [Double]) {
        let elapsed = min(max(date.timeIntervalSince(last ?? date), 0), 0.25)
        last = date
        for index in 0..<Self.bars {
            let goal = index < target.count ? target[index] : 0
            // Up at once, down at two heights a second.
            levels[index] = goal > levels[index] ? goal : max(goal, levels[index] - elapsed * 2)
            if levels[index] >= peaks[index] {
                peaks[index] = levels[index]
                held[index] = 0.4
            } else if held[index] > 0 {
                held[index] -= elapsed
            } else {
                peaks[index] = max(levels[index], peaks[index] - elapsed * 0.8)
            }
        }
        return (levels, peaks)
    }
}

/// The volume or balance slider: a slim groove colored by its level (green when low, through yellow and orange, to red;
/// the balance green in the middle), and the silver thumb with its three grip lines.
private struct PCSlider: View {
    enum Kind { case volume, balance }
    @Binding var value: Double
    var scale: CGFloat
    var kind: Kind
    var title: String

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width / scale
            let level = min(max(value, 0), 1)
            let travel = w - 14
            Canvas { context, _ in
                let px = Pixels(context: context, u: scale)
                let color = Self.color(kind == .volume ? level : abs(level - 0.5) * 2)
                px.fill(0, 3, w, 1, Color(hex: 0x161623))
                px.fill(0, 4, w, 1, color.mix(with: .black, by: 0.25))
                px.fill(0, 5, w, 1, color.mix(with: .black, by: 0.12))
                px.fill(0, 6, w, 1, color)
                px.fill(0, 7, w, 1, color.mix(with: .white, by: 0.08))
                px.fill(0, 8, w, 1, Color(hex: 0x7D7C90))
                px.fill(0, 3, 1, 6, Color(hex: 0x1F1F31))
                // The thumb.
                let x = (travel * level).rounded()
                px.fill(x, 0, 14, 11, Color(hex: 0x0B0F16))
                px.fill(x + 1, 1, 12, 1, Color(hex: 0xDAE7EA))
                px.fill(x + 1, 1, 1, 8, Color(hex: 0xDAE7EA))
                px.fill(x + 2, 2, 9, 6, Color(hex: 0xADBCC4))
                px.fill(x + 11, 2, 1, 7, PCColors.keyShade)
                px.fill(x + 2, 8, 10, 1, PCColors.keyShade)
                px.fill(x + 1, 9, 12, 1, PCColors.keyDark)
                px.fill(x + 12, 2, 1, 8, PCColors.keyDark)
                for grip in [4.0, 6, 8] { px.fill(x + grip, 3, 1, 4, Color(hex: 0x0B0F16)) }
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in value = min(max((drag.location.x / scale - 7) / max(travel, 1), 0), 1) })
        }
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            value = min(max(value + (direction == .increment ? 0.1 : -0.1), 0), 1)
        }
    }

    /// The base skin's volume colors, from its quietest to its loudest.
    static func color(_ level: Double) -> Color {
        let stops: [(Double, UInt32)] = [(0, 0x18920B), (0.15, 0x7ADA30), (0.33, 0xBDE238), (0.52, 0xE0DA30), (0.67, 0xE0B228), (0.85, 0xE0721E),
                                         (1, 0xE00E15)]
        let upper = stops.firstIndex { $0.0 >= level } ?? stops.count - 1
        guard upper > 0 else { return Color(hex: stops[0].1) }
        let (a, b) = (stops[upper - 1], stops[upper])
        return Color(hex: a.1).mix(with: Color(hex: b.1), by: (level - a.0) / (b.0 - a.0))
    }
}

/// The position bar's gold thumb, as the base skin draws it: cream ridges along it, a dark edge below and on the right.
private struct PCGoldThumb: View {
    var scale: CGFloat
    /// Upright (the playlist's scroll thumb) rather than along the bar.
    var upright = false

    var body: some View {
        Canvas { context, size in
            var context = context
            if upright {
                context.translateBy(x: size.width, y: 0)
                context.rotate(by: .degrees(90))
            }
            let px = Pixels(context: context, u: scale)
            let w = (upright ? size.height : size.width) / scale, h = (upright ? size.width : size.height) / scale
            let rows: [UInt32] = [0xDBCB9E, 0x836930, 0xF4EAC7, 0xF5F5F5, 0x755B22, 0xAF9861, 0xF4EAC7, 0xAF9861, 0x8D753A, 0x090202]
            for (index, color) in rows.enumerated() {
                let y = CGFloat(index) * h / CGFloat(rows.count)
                px.fill(0, y, w, h / CGFloat(rows.count) + 0.05, Color(hex: color))
            }
            px.fill(0, 0, 1, h - 1, Color(hex: 0xDBCB9E))
            px.fill(1, 1, 1, h - 2, Color(hex: 0x836930))
            px.fill(w - 2, 1, 1, h - 1, Color(hex: 0x8D753A))
            px.fill(w - 1, 0, 1, h, Color(hex: 0x090202))
        }
    }
}

/// The position bar: the groove and the gold thumb at the song's place, dragged to go elsewhere in it.
private struct PCPositionBar: View {
    var playback: SkinPlayback
    var seek: (TimeInterval) -> Void
    var scale: CGFloat
    @State private var dragging: Double?

    var body: some View {
        GeometryReader { proxy in
            let thumb = 29 * scale
            let travel = proxy.size.width - thumb
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let progress = dragging ?? playback.progress(at: context.date)
                PCGoldThumb(scale: scale)
                    .frame(width: thumb, height: proxy.size.height)
                    .offset(x: ((travel * progress) / scale).rounded() * scale)
                    .opacity(playback.duration > 0 ? 1 : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in dragging = min(max((drag.location.x - thumb / 2) / max(travel, 1), 0), 1) }
                .onEnded { _ in
                    if let dragging, playback.duration > 0 { seek(min(dragging, 0.995) * playback.duration) }
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

/// Groovelight's mark in the corner, as the classic skin frames its own: a tilted tile with a silver edge, filled with
/// the app icon's blue, and the icon's two beamed notes in gold standing in front of it.
private struct PCLogo: View {
    var scale: CGFloat

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let tile = CGRect(x: (size.width - side * 0.7) / 2, y: (size.height - side * 0.7) / 2, width: side * 0.7, height: side * 0.7)
            var tilted = context
            tilted.translateBy(x: size.width / 2, y: size.height / 2)
            tilted.rotate(by: .degrees(45))
            tilted.translateBy(x: -size.width / 2, y: -size.height / 2)
            tilted.fill(Path(roundedRect: tile.offsetBy(dx: scale * 0.7, dy: 0), cornerRadius: side * 0.12), with: .color(.black.opacity(0.5)))
            tilted.fill(Path(roundedRect: tile, cornerRadius: side * 0.12), with: .color(Color(hex: 0x484848)))
            tilted.fill(Path(roundedRect: tile.insetBy(dx: scale * 0.8, dy: scale * 0.8), cornerRadius: side * 0.1),
                        with: .linearGradient(Gradient(colors: [Color(hex: 0xE4E6EA), Color(hex: 0x8F9196)]), startPoint: tile.origin,
                                              endPoint: CGPoint(x: tile.maxX, y: tile.maxY)))
            let face = tile.insetBy(dx: scale * 1.8, dy: scale * 1.8)
            tilted.fill(Path(roundedRect: face, cornerRadius: side * 0.07),
                        with: .linearGradient(Gradient(colors: [Color(hex: 0x2A4CA0), Color(hex: 0x09143B)]), startPoint: face.origin,
                                              endPoint: CGPoint(x: face.maxX, y: face.maxY)))
            // The notes, upright and inside the tile.
            let notes = PCLogoNotes.path(in: CGRect(x: size.width * 0.3, y: size.height * 0.29, width: size.width * 0.42, height: size.height * 0.42))
            context.fill(notes.offsetBy(dx: scale * 0.5, dy: scale * 0.5), with: .color(.black.opacity(0.6)))
            context.fill(notes, with: .linearGradient(Gradient(colors: [Color(hex: 0xFFE9A0), Color(hex: 0xE0B44A), Color(hex: 0xB07A22)]),
                                                     startPoint: CGPoint(x: size.width * 0.3, y: size.height * 0.29),
                                                     endPoint: CGPoint(x: size.width * 0.72, y: size.height * 0.71)))
        }
        .accessibilityHidden(true)
    }
}

/// The app icon's notes, for the themes' logos (plain geometry, off the main actor that views' members are on).
enum PCLogoNotes {
    /// The icon's notes (its 1024-point drawing) fitted in `rect`.
    static func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addPath(Path(ellipseIn: CGRect(x: 258, y: 610, width: 224, height: 160)).applying(rotation(-20, around: CGPoint(x: 370, y: 690))))
        path.addPath(Path(ellipseIn: CGRect(x: 578, y: 530, width: 224, height: 160)).applying(rotation(-20, around: CGPoint(x: 690, y: 610))))
        path.addRect(CGRect(x: 441, y: 161, width: 34, height: 509))
        path.addRect(CGRect(x: 778, y: 81, width: 34, height: 509))
        for (a, b) in [(151.0, 223.0), (261, 333)] {
            path.move(to: CGPoint(x: 441, y: a)); path.addLine(to: CGPoint(x: 812, y: a - 80))
            path.addLine(to: CGPoint(x: 812, y: b - 80)); path.addLine(to: CGPoint(x: 441, y: b)); path.closeSubpath()
        }
        // The drawing's notes span x 258 to 812 and y 71 to 770 (before its shift): fit that box.
        let box = CGRect(x: 250, y: 66, width: 570, height: 710)
        let fit = min(rect.width / box.width, rect.height / box.height)
        return path.applying(CGAffineTransform(translationX: -box.minX, y: -box.minY)
            .concatenating(CGAffineTransform(scaleX: fit, y: fit))
            .concatenating(CGAffineTransform(translationX: rect.midX - box.width * fit / 2, y: rect.midY - box.height * fit / 2)))
    }

    private static func rotation(_ degrees: CGFloat, around point: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: point.x, y: point.y).rotated(by: degrees * .pi / 180).translatedBy(x: -point.x, y: -point.y)
    }
}

// MARK: Playlist window

private struct PCPlaylistWindow: View {
    var scale: CGFloat
    var size: CGSize
    var playback: SkinPlayback
    var controls: DeckControls
    var playlist: SkinPlaylist?
    var overlay: AnyView?
    @State private var scrolled: CGFloat = 0

    var body: some View {
        let s = scale
        let width = (size.width / s).rounded(.down), height = (size.height / s).rounded(.down)
        let entries = playlist?.entries ?? [SkinPlaylist.Entry(title: playback.title, artist: playback.artist, duration: playback.duration)]
        let current = playlist == nil ? 0 : playlist?.current
        let listHeight = height - 58
        ZStack(alignment: .topLeading) {
            PCWindowFace()
            Canvas { context, _ in
                let px = Pixels(context: context, u: s)
                // The frame's edges and its engraved inner lines, down the sides and across the foot.
                px.fill(0, 0, width, 1, Color(hex: 0x1D1D2D))
                px.fill(0, 0, 1, height, Color(hex: 0x1D1D2D))
                px.fill(1, 1, width - 2, 1, Color(hex: 0x6A6A7A))
                px.fill(1, 1, 1, height - 2, Color(hex: 0x6A6A7A))
                px.fill(0, height - 1, width, 1, Color(hex: 0x0E0E16))
                px.fill(width - 1, 0, 1, height, Color(hex: 0x0E0E16))
                px.fill(4, 12, width - 8, 2, Color(hex: 0x1D1D2D))
                px.fill(6, 14, width - 12, 1, Color(hex: 0x6B6B7C))
                px.fill(4, 12, 2, height - 16, Color(hex: 0x1D1D2D))
                px.fill(6, 14, 1, height - 18, Color(hex: 0x6A6A7A))
                px.fill(width - 6, 12, 2, height - 16, Color(hex: 0x1D1D2D))
                px.fill(width - 7, 14, 1, height - 18, Color(hex: 0x6A6A7A))
                px.fill(4, height - 4, width - 8, 1, Color(hex: 0x6A6A7A))
                // The list's black, the scroll bar's groove, the bottom bar's displays.
                px.fill(11, 20, width - 31, listHeight, .black)
                px.groove(10, 19, width - 29, listHeight + 2, dark: Color(hex: 0x1D1D2D), light: Color(hex: 0x6A6A7A))
                px.fill(width - 16, 20, 8, listHeight, Color(hex: 0x14141F))
                px.fill(width - 145, height - 29, 94, 10, .black)
                px.groove(width - 146, height - 30, 96, 12, dark: Color(hex: 0x1D1D2D), light: Color(hex: 0x6A6A7A))
                px.fill(width - 86, height - 16, 34, 8, .black)
                px.groove(width - 87, height - 17, 36, 10, dark: Color(hex: 0x1D1D2D), light: Color(hex: 0x6A6A7A))
                // The resize grip's diagonal lines.
                for step in 0..<4 {
                    let offset = CGFloat(step) * 3
                    for d in 0..<Int(10 - offset) {
                        px.fill(width - 6 - CGFloat(d), height - 15 + offset + CGFloat(d), 1, 1, Color(hex: 0x6A6A7A))
                    }
                }
            }
            PCTitleBar(title: "GROOVELIGHT PLAYLIST", scale: s, height: 20, isPlaylist: true).pc(0, 0, width, 20, s)
            // The list: green on black, the song playing in white; or the lyrics or Up Next in its place.
            Group {
                if let overlay {
                    overlay
                        .foregroundStyle(.white)
                        .environment(\.colorScheme, .dark)
                        .padding(8 * s)
                } else {
                    list(entries: entries, current: current)
                }
            }
            .pc(11, 20, width - 31, listHeight, s)
            PCGoldThumb(scale: s, upright: true)
                .frame(width: 8 * s, height: 18 * s)
                .offset(x: (width - 16) * s, y: (20 + (scrolled * max(listHeight - 18, 0)).rounded()) * s)
                .accessibilityHidden(true)
            // The bottom bar: the list's keys, the lengths, the small transport keys and the time, List Opts.
            ForEach(Array(["ADD", "REM", "SEL", "MISC"].enumerated()), id: \.offset) { index, title in
                ZStack {
                    PCKeyFace(pressed: false, scale: s)
                    Text(title).font(SkinFont.pixel(5.5 * s, bold: true)).foregroundStyle(PCColors.ink).fixedSize()
                }
                .pc(11 + CGFloat(index) * 29, height - 30, 25, 18, s)
                .accessibilityHidden(true)
            }
            let total = entries.reduce(0) { $0 + $1.duration }
            let selected = current.flatMap { entries.indices.contains($0) ? entries[$0].duration : nil } ?? playback.duration
            Text("\(shortClock(selected))/\(shortClock(total))")
                .font(SkinFont.pixel(5.5 * s)).foregroundStyle(PCColors.text).fixedSize()
                .pc(width - 145, height - 29, 94, 10, s)
            HStack(spacing: 0) {
                miniKey(.previous, "Previous", controls.previous)
                miniKey(.play, "Play") { if !playback.isPlaying { controls.playPause() } }
                miniKey(.pause, "Pause") { if playback.isPlaying { controls.playPause() } }
                miniKey(.stop, "Stop") {
                    if playback.isPlaying { controls.playPause() }
                    controls.seek(0)
                }
                miniKey(.next, "Next", controls.next)
                miniKey(.eject, "Close Now Playing") { controls.eject?() }
            }
            .pc(width - 146, height - 17, 56, 10, s)
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Text(clockText(playback.time(context.date)))
                    .font(SkinFont.pixel(5.5 * s)).foregroundStyle(PCColors.text).fixedSize()
            }
            .pc(width - 86, height - 16, 34, 8, s)
            .accessibilityHidden(true)
            ZStack {
                PCKeyFace(pressed: false, scale: s)
                VStack(spacing: 0.5 * s) {
                    Text("LIST").font(SkinFont.pixel(5.5 * s, bold: true))
                    Text("OPTS").font(SkinFont.pixel(5.5 * s, bold: true))
                }
                .foregroundStyle(PCColors.ink)
                .fixedSize()
            }
            .pc(width - 47, height - 30, 25, 18, s)
            .accessibilityHidden(true)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    private func list(entries: [SkinPlaylist.Entry], current: Int?) -> some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        let isCurrent = index == current
                        Button {
                            playlist?.play?(index)
                        } label: {
                            HStack(spacing: 4 * scale) {
                                Text("\(index + 1). \([entry.artist, entry.title].filter { !$0.isEmpty }.joined(separator: " - "))")
                                    .lineLimit(1)
                                Spacer(minLength: 4 * scale)
                                Text(clockText(entry.duration).trimmingPrefix("0"))
                                    .monospacedDigit()
                            }
                            .font(.system(size: 9.5 * scale))
                            .foregroundStyle(isCurrent ? Color.white : PCColors.listText)
                            .padding(.horizontal, 3 * scale)
                            .frame(height: 12.5 * scale)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(playlist?.play == nil)
                        .accessibilityAddTraits(isCurrent ? .isSelected : [])
                        .id(index)
                    }
                }
                .padding(.vertical, 2 * scale)
            }
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                let range = geometry.contentSize.height - geometry.containerSize.height
                return range > 0 ? min(max(geometry.contentOffset.y / range, 0), 1) : 0
            } action: { _, fraction in
                scrolled = fraction
            }
            .onAppear { if let current { reader.scrollTo(current, anchor: .center) } }
            .onChange(of: current) { _, current in
                if let current { withAnimation { reader.scrollTo(current, anchor: .center) } }
            }
        }
    }

    /// One of the bottom bar's small transport keys: its glyph in gold.
    private func miniKey(_ kind: PCGlyph.Kind, _ title: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            PCGlyph(kind: kind).fill(Color(hex: 0xE0C070))
                .frame(width: 5 * scale, height: 5 * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func shortClock(_ seconds: TimeInterval) -> String {
        let whole = Int(max(seconds, 0))
        return whole >= 3600 ? "\(whole / 3600):" + String(format: "%02d:%02d", whole / 60 % 60, whole % 60)
            : "\(whole / 60):" + String(format: "%02d", whole % 60)
    }
}
