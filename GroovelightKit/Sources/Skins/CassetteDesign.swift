import Foundation

/// A cassette for Now Playing's cassette skin: the shell, the label and the reels, as colors and text, and optionally
/// the user's own pictures of the shell and the label. Saved as `cassette.json` in a folder with its pictures
/// (`CassetteStore`), the same file on the Mac, the iPhone and Android, so a design can be shared as that folder.
///
/// Every size and place is relative to the cassette (0 to 1 across its width and its height), on the template's
/// geometry (`CassetteGeometry.standard`): a shell picture drawn on the template fits without any numbers, and one
/// drawn otherwise says where its reels and label are in `geometry`.
public struct CassetteDesign: Codable, Hashable, Identifiable, Sendable {
    /// The file format; designs from a later version with a larger number are still read, ignoring what is new.
    public static let formatVersion = 1

    public var format: Int = CassetteDesign.formatVersion
    public var id: UUID
    public var name: String
    /// Who made it, shown in the list (optional).
    public var author: String?

    /// The plastic: its color, and how clear it is (0 solid, up to 0.8 the smoked clear shells).
    public var shellColor: HexColor
    public var shellClarity: Double
    /// The screws, the window's frame and the edges.
    public var detailColor: HexColor

    public var label: Label
    public var reels: Reels

    /// The printed brand and the tape's type, at the top of the label ("TYPE II", "CrO2").
    public var brand: String
    public var tapeType: String
    /// The side shown on the label ("A").
    public var side: String

    /// The user's picture of the whole shell, drawn over the reels: a PNG with the windows (and anything else the
    /// reels show through) transparent. Relative to the design's folder.
    public var shellImage: String?
    /// The user's picture for the label, in place of the drawn one (the song's text is still written over it when
    /// `label.showsText`). Relative to the design's folder.
    public var labelImage: String?
    /// Where the reels, the window and the label are; the template's places when not set.
    public var geometry: CassetteGeometry?

    public struct Label: Codable, Hashable, Sendable {
        public var background: HexColor
        /// Bands across the label, top to bottom, as on the classic tapes (none for a plain label).
        public var stripes: [HexColor]
        public var textColor: HexColor
        /// The song's title and artist written on the label, as if by hand.
        public var showsText: Bool
        /// The album's cover on the label's left side.
        public var showsArtwork: Bool
        public var handwritten: Bool
        /// Bands placed anywhere on the label (over its color, under its text), as the printed blocks and pinstripes
        /// of the classic tapes. Optional.
        public var bands: [Band]
        /// A strip to write on, above the window, in its own color (the song is written on it in its own ink).
        /// Optional: without it the song is written on the label.
        public var writing: Writing?
        /// The printed lettering (the brand, the tape's type, the side) in foil instead of `textColor`. Optional.
        public var textFinish: Finish?
        /// The whole label in foil (the metal tapes' gold labels) instead of `background`. Optional.
        public var backgroundFinish: Finish?

        /// A band across the label: `y` and `height` relative to the label's height.
        public struct Band: Codable, Hashable, Sendable {
            public var color: HexColor
            public var y: Double
            public var height: Double
            /// In foil instead of `color`. Optional.
            public var finish: Finish?

            public init(color: HexColor, y: Double, height: Double, finish: Finish? = nil) {
                self.color = color
                self.y = y
                self.height = height
                self.finish = finish
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                color = try c.decode(HexColor.self, forKey: .color)
                y = try c.decode(Double.self, forKey: .y)
                height = try c.decode(Double.self, forKey: .height)
                finish = try? c.decodeIfPresent(Finish.self, forKey: .finish)
            }

            private enum CodingKeys: String, CodingKey { case color, y, height, finish }
        }

        public struct Writing: Codable, Hashable, Sendable {
            public var background: HexColor
            public var textColor: HexColor

            public init(background: HexColor, textColor: HexColor) {
                self.background = background
                self.textColor = textColor
            }
        }

        public init(background: HexColor, stripes: [HexColor] = [], textColor: HexColor, showsText: Bool = true,
                    showsArtwork: Bool = false, handwritten: Bool = true, bands: [Band] = [], writing: Writing? = nil,
                    textFinish: Finish? = nil, backgroundFinish: Finish? = nil) {
            self.background = background
            self.stripes = stripes
            self.textColor = textColor
            self.showsText = showsText
            self.showsArtwork = showsArtwork
            self.handwritten = handwritten
            self.bands = bands
            self.writing = writing
            self.textFinish = textFinish
            self.backgroundFinish = backgroundFinish
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            background = try c.decodeIfPresent(HexColor.self, forKey: .background) ?? HexColor("#F2EBDD")
            stripes = try c.decodeIfPresent([HexColor].self, forKey: .stripes) ?? []
            textColor = try c.decodeIfPresent(HexColor.self, forKey: .textColor) ?? HexColor("#1C2A6B")
            showsText = try c.decodeIfPresent(Bool.self, forKey: .showsText) ?? true
            showsArtwork = try c.decodeIfPresent(Bool.self, forKey: .showsArtwork) ?? false
            handwritten = try c.decodeIfPresent(Bool.self, forKey: .handwritten) ?? true
            bands = (try? c.decodeIfPresent([Band].self, forKey: .bands)) ?? []
            writing = try? c.decodeIfPresent(Writing.self, forKey: .writing)
            textFinish = try? c.decodeIfPresent(Finish.self, forKey: .textFinish)
            backgroundFinish = try? c.decodeIfPresent(Finish.self, forKey: .backgroundFinish)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(background, forKey: .background)
            try c.encode(stripes, forKey: .stripes)
            try c.encode(textColor, forKey: .textColor)
            try c.encode(showsText, forKey: .showsText)
            try c.encode(showsArtwork, forKey: .showsArtwork)
            try c.encode(handwritten, forKey: .handwritten)
            // Only when used, so plain designs read as before.
            if !bands.isEmpty { try c.encode(bands, forKey: .bands) }
            try c.encodeIfPresent(writing, forKey: .writing)
            try c.encodeIfPresent(textFinish, forKey: .textFinish)
            try c.encodeIfPresent(backgroundFinish, forKey: .backgroundFinish)
        }

        private enum CodingKeys: String, CodingKey {
            case background, stripes, textColor, showsText, showsArtwork, handwritten, bands, writing, textFinish, backgroundFinish
        }
    }

    public struct Reels: Codable, Hashable, Sendable {
        /// The hubs' plastic and the tape wound on them.
        public var hubColor: HexColor
        public var tapeColor: HexColor
        /// A printed ring around each hub's hole (the gold rings of the premium tapes). Optional.
        public var ringColor: HexColor?
        /// The rings in foil instead of `ringColor` (with `ringColor` set, so readers without finishes still draw them).
        public var ringFinish: Finish?

        public init(hubColor: HexColor, tapeColor: HexColor, ringColor: HexColor? = nil, ringFinish: Finish? = nil) {
            self.hubColor = hubColor
            self.tapeColor = tapeColor
            self.ringColor = ringColor
            self.ringFinish = ringFinish
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            hubColor = try c.decode(HexColor.self, forKey: .hubColor)
            tapeColor = try c.decode(HexColor.self, forKey: .tapeColor)
            ringColor = try c.decodeIfPresent(HexColor.self, forKey: .ringColor)
            ringFinish = try? c.decodeIfPresent(Finish.self, forKey: .ringFinish)
        }

        private enum CodingKeys: String, CodingKey { case hubColor, tapeColor, ringColor, ringFinish }
    }

    public init(id: UUID = UUID(), name: String, author: String? = nil, shellColor: HexColor, shellClarity: Double = 0,
                detailColor: HexColor, label: Label, reels: Reels, brand: String = "", tapeType: String = "",
                side: String = "A", shellImage: String? = nil, labelImage: String? = nil, geometry: CassetteGeometry? = nil) {
        self.id = id
        self.name = name
        self.author = author
        self.shellColor = shellColor
        self.shellClarity = shellClarity
        self.detailColor = detailColor
        self.label = label
        self.reels = reels
        self.brand = brand
        self.tapeType = tapeType
        self.side = side
        self.shellImage = shellImage
        self.labelImage = labelImage
        self.geometry = geometry
    }

    /// The places to draw at: the design's own, or the template's.
    public var resolvedGeometry: CassetteGeometry { geometry ?? .standard }

    // Lenient decoding: a design written by hand (or by a later version) with fields left out still opens.
    private enum CodingKeys: String, CodingKey {
        case format, id, name, author, shellColor, shellClarity, detailColor, label, reels, brand, tapeType, side,
             shellImage, labelImage, geometry
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = CassetteDesign.classic
        format = try c.decodeIfPresent(Int.self, forKey: .format) ?? CassetteDesign.formatVersion
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Cassette"
        author = try c.decodeIfPresent(String.self, forKey: .author)
        shellColor = try c.decodeIfPresent(HexColor.self, forKey: .shellColor) ?? fallback.shellColor
        shellClarity = min(max(try c.decodeIfPresent(Double.self, forKey: .shellClarity) ?? 0, 0), 0.8)
        detailColor = try c.decodeIfPresent(HexColor.self, forKey: .detailColor) ?? fallback.detailColor
        label = try c.decodeIfPresent(Label.self, forKey: .label) ?? fallback.label
        reels = try c.decodeIfPresent(Reels.self, forKey: .reels) ?? fallback.reels
        brand = try c.decodeIfPresent(String.self, forKey: .brand) ?? ""
        tapeType = try c.decodeIfPresent(String.self, forKey: .tapeType) ?? ""
        side = try c.decodeIfPresent(String.self, forKey: .side) ?? "A"
        shellImage = try c.decodeIfPresent(String.self, forKey: .shellImage)
        labelImage = try c.decodeIfPresent(String.self, forKey: .labelImage)
        geometry = try c.decodeIfPresent(CassetteGeometry.self, forKey: .geometry)
    }
}

/// Where the parts of a cassette are, relative to the whole (x across the width, y down the height).
public struct CassetteGeometry: Codable, Hashable, Sendable {
    /// Width over height of the cassette (and of a shell picture).
    public var aspectRatio: Double
    /// The reels' centers.
    public var leftReel: Point
    public var rightReel: Point
    /// The radius of a full reel of tape, and of the bare hub, relative to the cassette's width.
    public var reelRadius: Double
    public var hubRadius: Double
    /// The window the reels show through (drawn shells only: a picture has its own).
    public var window: Rect
    /// The label (where the song's text goes on a picture).
    public var label: Rect

    public struct Point: Codable, Hashable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    public struct Rect: Codable, Hashable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
    }

    /// These places with another window.
    public func with(window: Rect) -> CassetteGeometry {
        var geometry = self
        geometry.window = window
        return geometry
    }

    public init(aspectRatio: Double, leftReel: Point, rightReel: Point, reelRadius: Double, hubRadius: Double, window: Rect, label: Rect) {
        self.aspectRatio = aspectRatio
        self.leftReel = leftReel
        self.rightReel = rightReel
        self.reelRadius = reelRadius
        self.hubRadius = hubRadius
        self.window = window
        self.label = label
    }

    /// A compact cassette (100.4 x 63.8 mm), its reels 42.5 mm apart: the template's places, at 1000 x 635 pixels.
    public static let standard = CassetteGeometry(
        aspectRatio: 100.4 / 63.8,
        leftReel: Point(x: 0.288, y: 0.47),
        rightReel: Point(x: 0.712, y: 0.47),
        reelRadius: 0.165,
        hubRadius: 0.06,
        window: Rect(x: 0.33, y: 0.38, width: 0.34, height: 0.18),
        label: Rect(x: 0.075, y: 0.09, width: 0.85, height: 0.6)
    )
}

/// Print in metal foil, as the premium tapes' lettering, bands and rings: "gold" or "silver" in the design file (any
/// other value reads as plain ink, so a later finish does not stop a design from opening).
public enum Finish: String, Codable, Hashable, Sendable, CaseIterable {
    case gold, silver

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let finish = Finish(rawValue: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a finish: \(value)"))
        }
        self = finish
    }
}

/// A color as "#RRGGBB" or "#RRGGBBAA", as in the design file.
public struct HexColor: Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    /// Black for text that is not a color.
    public init(_ text: String) {
        self = HexColor.parse(text) ?? HexColor(red: 0, green: 0, blue: 0)
    }

    public init(stringLiteral value: String) { self.init(value) }

    public static func parse(_ text: String) -> HexColor? {
        var hex = text.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let full = hex.count == 6 ? value << 8 | 0xFF : value
        return HexColor(red: Double(full >> 24 & 0xFF) / 255, green: Double(full >> 16 & 0xFF) / 255,
                        blue: Double(full >> 8 & 0xFF) / 255, alpha: Double(full & 0xFF) / 255)
    }

    public var hex: String {
        let parts = [red, green, blue] + (alpha < 1 ? [alpha] : [])
        return "#" + parts.map { String(format: "%02X", Int(($0 * 255).rounded()).clamped(to: 0...255)) }.joined()
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let color = HexColor.parse(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a color: \(text)"))
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

// MARK: - Built-in designs

extension CassetteDesign {
    /// The designs that come with the app (they cannot be changed, only copied).
    public static let builtIn: [CassetteDesign] = [classic, chrome, clear, metal, mixtape, blackGold, iceChrome, midnightPro, redBand, smokedLavender, graphiteWindow, greenPinstripe, bronzeClear, charcoalB]

    /// Black shell, cream label with the red and orange bands of the 1980s.
    public static let classic = CassetteDesign(
        id: UUID(uuidString: "6B1C1C8E-0001-4C55-9C11-000000000001")!, name: "Classic",
        shellColor: "#1E1E21", detailColor: "#4A4A50",
        label: Label(background: "#F2EBDD", stripes: ["#D8432E", "#EE8A2C", "#F3C340"], textColor: "#1C2A6B"),
        reels: Reels(hubColor: "#F4F4F2", tapeColor: "#3A2618"),
        brand: "GROOVELIGHT", tapeType: "TYPE I · NORMAL")

    /// White shell and a blue label: the chrome tapes.
    public static let chrome = CassetteDesign(
        id: UUID(uuidString: "6B1C1C8E-0001-4C55-9C11-000000000002")!, name: "Chrome",
        shellColor: "#ECECEA", detailColor: "#A9AAB0",
        label: Label(background: "#1F4E9C", stripes: ["#E9EEF7"], textColor: "#FFFFFF", handwritten: false),
        reels: Reels(hubColor: "#FFFFFF", tapeColor: "#2B2018"),
        brand: "GROOVELIGHT", tapeType: "TYPE II · CrO2")

    /// Smoked clear plastic: the whole reels show.
    public static let clear = CassetteDesign(
        id: UUID(uuidString: "6B1C1C8E-0001-4C55-9C11-000000000003")!, name: "Clear",
        shellColor: "#9FB4C2", shellClarity: 0.65, detailColor: "#D0D8DE",
        label: Label(background: "#FFFFFF", stripes: [], textColor: "#202020", showsArtwork: true, handwritten: false),
        reels: Reels(hubColor: "#F7F7F7", tapeColor: "#4B3423"),
        brand: "GROOVELIGHT", tapeType: "TYPE II · HIGH BIAS")

    /// Dark metal tape with a gold label.
    public static let metal = CassetteDesign(
        id: UUID(uuidString: "6B1C1C8E-0001-4C55-9C11-000000000004")!, name: "Metal",
        shellColor: "#2B2D31", detailColor: "#8D8F94",
        label: Label(background: "#C9A750", stripes: ["#1A1A1A"], textColor: "#1A1A1A", handwritten: false, backgroundFinish: .gold),
        reels: Reels(hubColor: "#C9C9C9", tapeColor: "#1F1A16"),
        brand: "GROOVELIGHT", tapeType: "TYPE IV · METAL")

    /// A home-made mixtape: a bright shell, the cover on the label and handwriting.
    public static let mixtape = CassetteDesign(
        id: UUID(uuidString: "6B1C1C8E-0001-4C55-9C11-000000000005")!, name: "Mixtape",
        shellColor: "#E4497A", detailColor: "#F7A6C0",
        label: Label(background: "#FFF6D8", stripes: ["#47B5C9"], textColor: "#2A2A2A", showsArtwork: true),
        reels: Reels(hubColor: "#FFFFFF", tapeColor: "#3A2618"),
        brand: "MIX", tapeType: "90 MIN")

    // After the classic tapes of the 1980s and 1990s: their colors, bands and rings, under Groovelight's own name.

    /// Black with gold print and gold rings around the hubs: the limited editions of the high bias tapes.
    public static let blackGold = CassetteDesign(
        id: UUID(uuidString: "6B1C1C8E-0001-4C55-9C11-000000000006")!, name: "Black Gold",
        shellColor: "#161618", detailColor: "#3C3C40",
        label: Label(background: "#00000000", textColor: "#D6AE5C", handwritten: false, bands: [.init(color: "#D6AE5C", y: 0.43, height: 0.012, finish: .gold), .init(color: "#232120", y: 0.46, height: 0.34), .init(color: "#D6AE5C", y: 0.8, height: 0.012, finish: .gold)], textFinish: .gold),
        reels: Reels(hubColor: "#E8E6E0", tapeColor: "#2A1D14", ringColor: "#C9A04A", ringFinish: .gold),
        brand: "GROOVELIGHT GX 60", tapeType: "HIGH POSITION · TYPE II", side: "B")

    /// Clear blue plastic, the whole reels showing: the chrome tapes of the late 1980s.
    public static let iceChrome = CassetteDesign(
        id: UUID(uuidString: "6B1C1C8E-0001-4C55-9C11-000000000007")!, name: "Ice Chrome",
        shellColor: "#B9CCDD", shellClarity: 0.7, detailColor: "#E3EBF2",
        label: Label(background: "#FFFFFF14", textColor: "#23356E", handwritten: false, bands: [.init(color: "#3D5FA8", y: 0.88, height: 0.06)]),
        reels: Reels(hubColor: "#F5F7FA", tapeColor: "#3A2A20"),
        brand: "GROOVELIGHT CR 90", tapeType: "CHROME · TYPE II")

    /// Midnight blue with silver print and silver rings: the professional high bias tapes.
    public static let midnightPro = CassetteDesign(
        id: UUID(uuidString: "6B1C1C8E-0001-4C55-9C11-000000000008")!, name: "Midnight Pro",
        shellColor: "#1A1F30", detailColor: "#59607A",
        label: Label(background: "#00000000", textColor: "#D5D9E2", handwritten: false, bands: [.init(color: "#262C42", y: 0.46, height: 0.34), .init(color: "#AEB3BF", y: 0.82, height: 0.01, finish: .silver)], textFinish: .silver),
        reels: Reels(hubColor: "#E9EBEF", tapeColor: "#241A14", ringColor: "#BFC4CE", ringFinish: .silver),
        brand: "GROOVELIGHT PRO 90", tapeType: "SUPER ENERGY · TYPE II")

    /// Black with a white strip to write on and a red band across the window.
    public static let redBand = CassetteDesign(
        id: UUID(uuidString: "6B1C1C8E-0001-4C55-9C11-000000000009")!, name: "Red Band",
        shellColor: "#121214", detailColor: "#3A3A3E",
        label: Label(background: "#00000000", textColor: "#F1EEE6", handwritten: true, bands: [.init(color: "#B5302A", y: 0.44, height: 0.38), .init(color: "#F1EEE6", y: 0.86, height: 0.1)], writing: .init(background: "#F1EEE6", textColor: "#1E2A5A")),
        reels: Reels(hubColor: "#EDEDED", tapeColor: "#2B1E16"),
        brand: "GROOVELIGHT S 60", tapeType: "TYPE II · HIGH BIAS")

    /// Smoked plastic, a gray strip to write on and lavender print.
    public static let smokedLavender = CassetteDesign(
        id: UUID(uuidString: "6B1C1C8E-0001-4C55-9C11-00000000000A")!, name: "Smoked Lavender",
        shellColor: "#33353B", shellClarity: 0.5, detailColor: "#6E7078",
        label: Label(background: "#00000000", textColor: "#B7A2E8", handwritten: true, writing: .init(background: "#CFCFCB", textColor: "#26262A")),
        reels: Reels(hubColor: "#F0F0F0", tapeColor: "#2A1E16"),
        brand: "GROOVELIGHT LX", tapeType: "100 MINUTES")

    /// Graphite with a wide clear window and red rings around the hubs.
    public static let graphiteWindow = CassetteDesign(
        id: UUID(uuidString: "6B1C1C8E-0001-4C55-9C11-00000000000B")!, name: "Graphite Window",
        shellColor: "#3B3C40", shellClarity: 0.3, detailColor: "#6A6B70",
        label: Label(background: "#00000000", textColor: "#E0E0DE", handwritten: true, writing: .init(background: "#ECEBE6", textColor: "#222222")),
        reels: Reels(hubColor: "#F2F2F2", tapeColor: "#2B1E16", ringColor: "#C23B32"),
        brand: "GROOVELIGHT F 90", tapeType: "IEC II · HIGH POSITION",
        geometry: CassetteGeometry.standard.with(window: .init(x: 0.2, y: 0.35, width: 0.6, height: 0.24)))

    /// Deep green with a cream strip to write on and gold pinstripes.
    public static let greenPinstripe = CassetteDesign(
        id: UUID(uuidString: "6B1C1C8E-0001-4C55-9C11-00000000000C")!, name: "Green Pinstripe",
        shellColor: "#1C2520", detailColor: "#4A564F",
        label: Label(background: "#00000000", textColor: "#E9E4D0", handwritten: true, bands: [.init(color: "#C8A55A", y: 0.8, height: 0.018, finish: .gold), .init(color: "#EDE8D8", y: 0.835, height: 0.012), .init(color: "#C8A55A", y: 0.86, height: 0.018, finish: .gold)], writing: .init(background: "#F2F0E6", textColor: "#1D2A22")),
        reels: Reels(hubColor: "#F0F0EC", tapeColor: "#2A1D14"),
        brand: "GROOVELIGHT X 90", tapeType: "HIGH BIAS · 70µs EQ")

    /// Smoked clear plastic, a white strip to write on and a bronze band.
    public static let bronzeClear = CassetteDesign(
        id: UUID(uuidString: "6B1C1C8E-0001-4C55-9C11-00000000000D")!, name: "Bronze Clear",
        shellColor: "#5E5A57", shellClarity: 0.55, detailColor: "#B9B2AA",
        label: Label(background: "#00000000", textColor: "#F4F2EE", handwritten: false, bands: [.init(color: "#B06A33", y: 0.84, height: 0.1)], writing: .init(background: "#F4F2EE", textColor: "#333333")),
        reels: Reels(hubColor: "#F2F2F2", tapeColor: "#3A2A20"),
        brand: "GROOVELIGHT", tapeType: "CHROME II · 100")

    /// Charcoal with a black band and white print, on side B.
    public static let charcoalB = CassetteDesign(
        id: UUID(uuidString: "6B1C1C8E-0001-4C55-9C11-00000000000E")!, name: "Charcoal",
        shellColor: "#2D2E30", detailColor: "#4D4E52",
        label: Label(background: "#00000000", textColor: "#E6E6E6", handwritten: false, bands: [.init(color: "#111111", y: 0.78, height: 0.1), .init(color: "#E6E6E6", y: 0.8, height: 0.006, finish: .silver)], textFinish: .silver),
        reels: Reels(hubColor: "#E8E8E8", tapeColor: "#2A1D14"),
        brand: "GROOVELIGHT TX 90", tapeType: "HIGH BIAS · 70µs EQ", side: "B")

    public var isBuiltIn: Bool { CassetteDesign.builtIn.contains { $0.id == id } }
}
