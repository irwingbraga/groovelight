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

/// The players' lettering: the segment displays' fonts (DSEG, OFL), and the engraved and printed captions.
enum SkinFont {
    private static let registered: Bool = {
        for name in ["DSEG7Classic-Bold", "DSEG14Classic-Bold"] {
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
