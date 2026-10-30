import CoreText
import ImageIO
import SwiftUI

/// The photographed surfaces the players are made of (ambientCG, CC0; see Resources/CREDITS.md), tiled at half their
/// pixel size so they stay sharp on a Retina screen.
enum SkinTexture: String, CaseIterable {
    case walnut = "Walnut"
    case aluminum = "Aluminum"
    case felt = "Felt"
    case blackPlastic = "BlackPlastic"
    /// A record's grooves, how much each point scatters the light (made for Groovelight, not tiled: drawn across the record).
    case vinyl = "Vinyl"
    /// A cassette's molded plastic: the fine matte grain of a spark-eroded mould (neutral gray, tiled).
    case grain = "Grain"
    /// Hot-stamped foil: faint streaks and a fine sparkle (light gray, tiled), colored gold or silver.
    case foil = "Foil"
    /// Paper's fibres (light gray, tiled): the labels and the VU meters' faces.
    case paper = "Paper"
    /// The PC Player's wallpaper: a green hill under a blue sky with clouds (made for Groovelight; drawn to fill, not tiled).
    case hill = "Hill"

    @MainActor private static var images: [SkinTexture: Image] = [:]

    @MainActor var image: Image {
        if let image = Self.images[self] { return image }
        var image = Image(decorative: Self.blank, scale: 1)
        if let url = Bundle.module.url(forResource: rawValue, withExtension: "jpg"),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            image = Image(decorative: picture, scale: 2)
        }
        Self.images[self] = image
        return image
    }

    private static let blank: CGImage = {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()!
    }()
}

/// A surface of `texture`, tiled, made lighter or darker (`brightness`) and colored (`tint`, multiplied).
struct Textured: View {
    var texture: SkinTexture
    var brightness: Double = 0
    var tint: Color = .white

    var body: some View {
        texture.image
            .resizable(resizingMode: .tile)
            .colorMultiply(tint)
            .brightness(brightness)
            .allowsHitTesting(false)
    }
}

/// Polished chrome: a mirror of the room, so a bright window, a dark floor and the sky, sharply, rather than a soft gray.
enum Chrome {
    private static let stops: [(Double, Double, Double, Double)] = [
        // location, red, green, blue: dark at the edges, the window's sharp highlight, the floor's band, the sky's.
        (0, 0.16, 0.17, 0.19), (0.1, 0.42, 0.43, 0.45), (0.2, 0.86, 0.87, 0.88), (0.25, 1, 1, 1), (0.31, 0.8, 0.8, 0.79),
        (0.44, 0.4, 0.4, 0.39), (0.54, 0.13, 0.13, 0.14), (0.66, 0.3, 0.31, 0.33), (0.79, 0.74, 0.77, 0.82), (0.9, 0.55, 0.57, 0.6),
        (1, 0.14, 0.14, 0.16),
    ]

    /// A rod's or a cylinder's chrome, across it from `start` to `end`.
    static func cylinder(_ start: UnitPoint = .leading, _ end: UnitPoint = .trailing) -> LinearGradient {
        LinearGradient(stops: stops.map { .init(color: Color(red: $0.1, green: $0.2, blue: $0.3), location: $0.0) }, startPoint: start, endPoint: end)
    }

    /// A dome's chrome (a pivot's cap, a screw head): the window's reflection near the top left.
    static func dome(_ radius: CGFloat) -> RadialGradient {
        RadialGradient(stops: [.init(color: .white, location: 0), .init(color: Color(white: 0.92), location: 0.12),
                               .init(color: Color(white: 0.45), location: 0.35), .init(color: Color(red: 0.12, green: 0.12, blue: 0.14), location: 0.62),
                               .init(color: Color(red: 0.55, green: 0.58, blue: 0.63), location: 0.86), .init(color: Color(white: 0.2), location: 1)],
                       center: .init(x: 0.36, y: 0.32), startRadius: 0, endRadius: radius * 1.3)
    }

    /// Turned (lathe-cut) metal seen from above: light and dark sectors where the fine rings catch the light.
    static var turned: AngularGradient {
        AngularGradient(colors: [Color(white: 0.97), Color(white: 0.62), Color(white: 0.35), Color(white: 0.7), Color(white: 0.98), Color(white: 0.6),
                                 Color(white: 0.3), Color(white: 0.68), Color(white: 0.97)], center: .center)
    }
}

/// Hot-stamped foil, gold or silver: a mirror of the room across it (bright and dark bands, sharply), its faint streaks
/// and sparkle. `.foil(_:)` prints a view's shape (lettering, a band, a ring) in it.
struct FoilFill: View {
    var finish: Finish
    /// Down each letter rather than along the whole: lettering catches the light on its tops and darkens below.
    var isLettering = false

    var body: some View {
        LinearGradient(stops: (isLettering ? Self.letteringStops(finish) : Self.stops(finish)).map { .init(color: Color(red: $0.1, green: $0.2, blue: $0.3), location: $0.0) },
                       startPoint: isLettering ? UnitPoint(x: 0.45, y: 0) : UnitPoint(x: 0, y: 0.15),
                       endPoint: isLettering ? UnitPoint(x: 0.55, y: 1) : UnitPoint(x: 1, y: 0.85))
            .overlay(Textured(texture: .foil).blendMode(.multiply))
            .allowsHitTesting(false)
    }

    /// Down a letter: lit at the top, a dark band below the middle, the floor's light at the foot.
    private static func letteringStops(_ finish: Finish) -> [(Double, Double, Double, Double)] {
        switch finish {
        case .gold:
            [(0, 1, 0.94, 0.66), (0.3, 0.95, 0.78, 0.36), (0.55, 0.7, 0.5, 0.17), (0.78, 0.88, 0.68, 0.28), (1, 0.98, 0.87, 0.52)]
        case .silver:
            [(0, 1, 1, 1), (0.3, 0.86, 0.88, 0.91), (0.55, 0.55, 0.57, 0.61), (0.78, 0.8, 0.82, 0.86), (1, 0.95, 0.96, 0.98)]
        }
    }

    private static func stops(_ finish: Finish) -> [(Double, Double, Double, Double)] {
        switch finish {
        case .gold:
            [(0, 0.42, 0.28, 0.08), (0.14, 0.78, 0.58, 0.2), (0.24, 1, 0.92, 0.6), (0.3, 0.86, 0.66, 0.24), (0.46, 0.5, 0.33, 0.09),
             (0.6, 0.82, 0.62, 0.24), (0.7, 1, 0.95, 0.7), (0.78, 0.9, 0.72, 0.3), (0.92, 0.56, 0.38, 0.12), (1, 0.74, 0.55, 0.2)]
        case .silver:
            [(0, 0.36, 0.37, 0.4), (0.14, 0.72, 0.74, 0.78), (0.24, 1, 1, 1), (0.3, 0.8, 0.82, 0.85), (0.46, 0.42, 0.43, 0.46),
             (0.6, 0.76, 0.78, 0.82), (0.7, 0.98, 0.99, 1), (0.78, 0.82, 0.84, 0.88), (0.92, 0.5, 0.51, 0.55), (1, 0.7, 0.72, 0.76)]
        }
    }
}

extension View {
    /// The view's shape printed in `finish` (pressed into the surface: a hairline shadow under it), or the view as it is
    /// without one.
    @ViewBuilder func foil(_ finish: Finish?, lettering: Bool = false) -> some View {
        if let finish {
            // Laid out as the view is: the foil only fills its shape.
            hidden()
                .overlay {
                    FoilFill(finish: finish, isLettering: lettering)
                        .mask(self)
                        .shadow(color: .black.opacity(0.45), radius: 0, x: 0, y: 0.6)
                }
        } else {
            self
        }
    }
}

/// The players' lettering: the segment displays' fonts (DSEG, OFL), and the engraved and printed captions.
enum SkinFont {
    private static let registered: Bool = {
        for name in ["DSEG7Classic-Bold", "DSEG14Classic-Bold", "Silkscreen-Regular", "Silkscreen-Bold"] {
            if let url = Bundle.module.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
        return true
    }()

    /// Seven segments: digits and the colon.
    static func digits(_ size: CGFloat) -> Font {
        _ = registered
        return .custom("DSEG7Classic-Bold", fixedSize: size)
    }

    /// Fourteen segments: capitals, digits and some punctuation.
    static func letters(_ size: CGFloat) -> Font {
        _ = registered
        return .custom("DSEG14Classic-Bold", fixedSize: size)
    }

    /// A computer's pixel lettering (Silkscreen, OFL): the PC Player's title bars, scrolling title and buttons.
    static func pixel(_ size: CGFloat, bold: Bool = false) -> Font {
        _ = registered
        return .custom(bold ? "Silkscreen-Bold" : "Silkscreen-Regular", fixedSize: size)
    }

    /// The captions on the panels, wide as on the hi-fi of the seventies.
    static func caption(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight).width(.expanded)
    }

    /// Text the 14-segment font can show: capitals without accents, the rest as spaces.
    static func segmentText(_ text: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -.,'!?/()&+:")
        return String(text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil).uppercased()
            .map { allowed.contains($0) ? $0 : " " })
    }
}

/// A caption cut into metal (dark, lit from above) or printed on a dark panel (light).
struct Engraved: View {
    var text: String
    var size: CGFloat
    var onDark = false

    init(_ text: String, size: CGFloat, onDark: Bool = false) {
        self.text = text
        self.size = size
        self.onDark = onDark
    }

    var body: some View {
        Text(text)
            .font(SkinFont.caption(size))
            .tracking(size * 0.14)
            .lineLimit(1)
            .foregroundStyle(onDark ? Color.white.opacity(0.78) : Color.black.opacity(0.62))
            .shadow(color: onDark ? .black.opacity(0.7) : .white.opacity(0.55), radius: 0, y: onDark ? -0.6 : 0.8)
            .fixedSize()
    }
}

/// A plate of `texture` fixed to the player: a lit top edge, a shadowed bottom one, and screws in its corners.
struct Plate: View {
    var texture: SkinTexture
    var brightness: Double = 0
    var tint: Color = .white
    var cornerRadius: CGFloat
    var screws: CGFloat? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Textured(texture: texture, brightness: brightness, tint: tint)
            .overlay(LinearGradient(colors: [.white.opacity(0.16), .clear, .black.opacity(0.18)], startPoint: .top, endPoint: .bottom))
            .clipShape(shape)
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.1), .black.opacity(0.35)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1.2))
            .overlay {
                if let screws {
                    GeometryReader { proxy in
                        let inset = screws * 1.4
                        ForEach(0..<4, id: \.self) { corner in
                            PanelScrew(angle: Double(corner) * 37 + 12)
                                .frame(width: screws, height: screws)
                                .position(x: corner % 2 == 0 ? inset : proxy.size.width - inset,
                                          y: corner < 2 ? inset : proxy.size.height - inset)
                        }
                    }
                }
            }
            .shadow(color: .black.opacity(0.55), radius: cornerRadius * 0.6, y: cornerRadius * 0.3)
    }
}

/// A hollow in the player (a well, a display's window): its edges in shadow at the top, lit at the bottom.
struct Recess<Fill: ShapeStyle>: View {
    var cornerRadius: CGFloat
    var fill: Fill
    var depth: CGFloat = 6

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(fill)
            .overlay(shape.fill(Color.black.opacity(0.001).shadow(.inner(color: .black.opacity(0.85), radius: depth, y: depth * 0.6))))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.black.opacity(0.6), .white.opacity(0.35)], startPoint: .top, endPoint: .bottom),
                                        lineWidth: 1))
    }
}

/// A slotted screw head, turned by `angle`.
struct PanelScrew: View {
    var angle: Double

    var body: some View {
        GeometryReader { proxy in
            let side = proxy.size.width
            ZStack {
                Circle().fill(RadialGradient(colors: [Color(white: 0.92), Color(white: 0.55), Color(white: 0.3)], center: .init(x: 0.35, y: 0.3),
                                             startRadius: 0, endRadius: side * 0.7))
                Capsule().fill(Color.black.opacity(0.6))
                    .frame(width: side * 0.75, height: side * 0.16)
                    .rotationEffect(.degrees(angle))
                Capsule().fill(Color.black.opacity(0.6))
                    .frame(width: side * 0.16, height: side * 0.75)
                    .rotationEffect(.degrees(angle))
            }
            .overlay(Circle().strokeBorder(.black.opacity(0.4), lineWidth: 0.6))
            .shadow(color: .black.opacity(0.5), radius: side * 0.1, y: side * 0.08)
        }
    }
}

/// A small lamp: lit, it glows in its color.
struct PilotLamp: View {
    var isOn: Bool
    var color: Color = Color(red: 1, green: 0.28, blue: 0.16)

    var body: some View {
        GeometryReader { proxy in
            let side = proxy.size.width
            Circle()
                .fill(RadialGradient(colors: isOn ? [.white, color, color.opacity(0.7)] : [Color(white: 0.45), Color(white: 0.18), Color(white: 0.1)],
                                     center: .init(x: 0.4, y: 0.35), startRadius: 0, endRadius: side * 0.6))
                .overlay(Circle().strokeBorder(.black.opacity(0.6), lineWidth: side * 0.12))
                .shadow(color: isOn ? color : .clear, radius: side * 0.7)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
