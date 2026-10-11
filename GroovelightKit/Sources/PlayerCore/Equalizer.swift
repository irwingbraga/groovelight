import AVFAudio
import Foundation

/// Filter shape of a single equalizer band.
public enum EQFilterType: String, Codable, CaseIterable, Sendable {
    case peak
    case lowShelf
    case highShelf
    case lowPass
    case highPass
    case bandPass
    case notch

    public var displayName: String {
        switch self {
        case .peak: "Peak"
        case .lowShelf: "Low Shelf"
        case .highShelf: "High Shelf"
        case .lowPass: "Low Pass"
        case .highPass: "High Pass"
        case .bandPass: "Band Pass"
        case .notch: "Notch"
        }
    }

    /// Whether the gain parameter has any audible effect for this filter type.
    public var usesGain: Bool {
        switch self {
        case .peak, .lowShelf, .highShelf: true
        case .lowPass, .highPass, .bandPass, .notch: false
        }
    }

    var avType: AVAudioUnitEQFilterType {
        switch self {
        case .peak: .parametric
        case .lowShelf: .resonantLowShelf
        case .highShelf: .resonantHighShelf
        case .lowPass: .resonantLowPass
        case .highPass: .resonantHighPass
        case .bandPass: .bandPass
        case .notch: .bandStop
        }
    }
}

public struct EQBand: Codable, Hashable, Sendable {
    public var isEnabled: Bool
    public var type: EQFilterType
    /// Center or corner frequency in Hz.
    public var frequency: Double
    /// Gain in dB, only used by peak and shelf filters.
    public var gain: Double
    /// Quality factor.
    public var q: Double

    public init(isEnabled: Bool = true, type: EQFilterType = .peak, frequency: Double, gain: Double = 0, q: Double = EQMath.defaultQ) {
        self.isEnabled = isEnabled
        self.type = type
        self.frequency = frequency
        self.gain = gain
        self.q = q
    }
}

public struct EQPreset: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var preamp: Double
    public var bands: [EQBand]

    public init(name: String, preamp: Double = 0, bands: [EQBand]) {
        self.name = name
        self.preamp = preamp
        self.bands = bands
    }
}

public enum EQMath {
    public static let bandCount = 15
    /// ISO 2/3-octave center frequencies.
    public static let isoFrequencies: [Double] = [25, 40, 63, 100, 160, 250, 400, 630, 1_000, 1_600, 2_500, 4_000, 6_300, 10_000, 16_000]
    /// Q of a 2/3-octave wide band.
    public static let defaultQ: Double = qFromBandwidth(2.0 / 3.0)

    public static let frequencyRange: ClosedRange<Double> = 20...20_000
    public static let gainRange: ClosedRange<Double> = -24...24
    public static let qRange: ClosedRange<Double> = 0.1...18

    /// Converts a Q factor to a bandwidth in octaves (the unit AVAudioUnitEQ uses).
    public static func bandwidth(fromQ q: Double) -> Double {
        2 / log(2) * asinh(1 / (2 * q))
    }

    public static func qFromBandwidth(_ octaves: Double) -> Double {
        1 / (2 * sinh(log(2) / 2 * octaves))
    }

    /// Magnitude response in dB of a single band at `frequency`, using the RBJ audio EQ cookbook biquads.
    public static func response(of band: EQBand, at frequency: Double, sampleRate: Double = 48_000) -> Double {
        guard band.isEnabled else { return 0 }
        let c = coefficients(for: band, sampleRate: sampleRate)
        let w = 2 * Double.pi * frequency / sampleRate
        let cos1 = cos(w), sin1 = sin(w), cos2 = cos(2 * w), sin2 = sin(2 * w)
        let numRe = c.b0 + c.b1 * cos1 + c.b2 * cos2
        let numIm = -(c.b1 * sin1 + c.b2 * sin2)
        let denRe = c.a0 + c.a1 * cos1 + c.a2 * cos2
        let denIm = -(c.a1 * sin1 + c.a2 * sin2)
        let magnitude = sqrt((numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm))
        return 20 * log10(max(magnitude, 1e-9))
    }

    /// Combined response in dB of all bands plus preamp at `frequency`.
    public static func response(of preset: EQPreset, at frequency: Double, sampleRate: Double = 48_000) -> Double {
        preset.bands.reduce(preset.preamp) { $0 + response(of: $1, at: frequency, sampleRate: sampleRate) }
    }

    /// Preamp that keeps the loudest boost of the curve at or below 0 dB.
    public static func autoPreamp(for bands: [EQBand], sampleRate: Double = 48_000) -> Double {
        let flat = EQPreset(name: "", preamp: 0, bands: bands)
        let peak = logSpacedFrequencies(count: 256).map { response(of: flat, at: $0, sampleRate: sampleRate) }.max() ?? 0
        return min(0, -peak)
    }

    public static func logSpacedFrequencies(count: Int, in range: ClosedRange<Double> = frequencyRange) -> [Double] {
        guard count > 1 else { return [range.lowerBound] }
        let lo = log10(range.lowerBound), hi = log10(range.upperBound)
        return (0..<count).map { pow(10, lo + (hi - lo) * Double($0) / Double(count - 1)) }
    }

    struct Biquad { var b0, b1, b2, a0, a1, a2: Double }

    static func coefficients(for band: EQBand, sampleRate: Double) -> Biquad {
        let f = min(band.frequency, sampleRate / 2 * 0.999)
        let w0 = 2 * Double.pi * f / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let q = max(band.q, 0.01)
        let alpha = sinw / (2 * q)
        let a = pow(10, band.gain / 40)
        switch band.type {
        case .peak:
            return Biquad(b0: 1 + alpha * a, b1: -2 * cosw, b2: 1 - alpha * a,
                          a0: 1 + alpha / a, a1: -2 * cosw, a2: 1 - alpha / a)
        case .lowShelf:
            let s = 2 * sqrt(a) * alpha
            return Biquad(b0: a * ((a + 1) - (a - 1) * cosw + s),
                          b1: 2 * a * ((a - 1) - (a + 1) * cosw),
                          b2: a * ((a + 1) - (a - 1) * cosw - s),
                          a0: (a + 1) + (a - 1) * cosw + s,
                          a1: -2 * ((a - 1) + (a + 1) * cosw),
                          a2: (a + 1) + (a - 1) * cosw - s)
        case .highShelf:
            let s = 2 * sqrt(a) * alpha
            return Biquad(b0: a * ((a + 1) + (a - 1) * cosw + s),
                          b1: -2 * a * ((a - 1) + (a + 1) * cosw),
                          b2: a * ((a + 1) + (a - 1) * cosw - s),
                          a0: (a + 1) - (a - 1) * cosw + s,
                          a1: 2 * ((a - 1) - (a + 1) * cosw),
                          a2: (a + 1) - (a - 1) * cosw - s)
        case .lowPass:
            return Biquad(b0: (1 - cosw) / 2, b1: 1 - cosw, b2: (1 - cosw) / 2,
                          a0: 1 + alpha, a1: -2 * cosw, a2: 1 - alpha)
        case .highPass:
            return Biquad(b0: (1 + cosw) / 2, b1: -(1 + cosw), b2: (1 + cosw) / 2,
                          a0: 1 + alpha, a1: -2 * cosw, a2: 1 - alpha)
        case .bandPass:
            return Biquad(b0: alpha, b1: 0, b2: -alpha, a0: 1 + alpha, a1: -2 * cosw, a2: 1 - alpha)
        case .notch:
            return Biquad(b0: 1, b1: -2 * cosw, b2: 1, a0: 1 + alpha, a1: -2 * cosw, a2: 1 - alpha)
        }
    }
}

extension EQPreset {
    public static var flat: EQPreset {
        EQPreset(name: "Flat", bands: EQMath.isoFrequencies.map { EQBand(frequency: $0) })
    }

    /// Builds a preset from 15 gains applied to the ISO bands.
    public static func iso(_ name: String, gains: [Double]) -> EQPreset {
        let bands = zip(EQMath.isoFrequencies, gains).map { EQBand(frequency: $0, gain: $1) }
        return EQPreset(name: name, preamp: EQMath.autoPreamp(for: bands), bands: bands)
    }

    public static let builtIns: [EQPreset] = [
        .flat,
        .iso("Bass Booster", gains: [6, 5.5, 5, 4, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0]),
        .iso("Bass Reducer", gains: [-6, -5.5, -5, -4, -3, -2, -1, 0, 0, 0, 0, 0, 0, 0, 0]),
        .iso("Treble Booster", gains: [0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 5.5, 6]),
        .iso("Vocal Booster", gains: [-2, -2, -1.5, -1, 0, 1.5, 3, 3.5, 3.5, 3, 2, 1, 0, -1, -1.5]),
        .iso("Loudness", gains: [6, 5, 4, 2.5, 1, 0, -1, -1.5, -1, 0, 1, 2.5, 3.5, 4, 4]),
        .iso("Acoustic", gains: [4.5, 4.5, 4, 3, 1.5, 1, 1.5, 2, 2.5, 3, 3, 3.5, 3, 2.5, 2]),
        .iso("Electronic", gains: [4.5, 4, 3.5, 1.5, 0, -1.5, -1, 0, 1, 1.5, 0.5, 1.5, 3.5, 4, 4.5]),
        .iso("Rock", gains: [5, 4.5, 4, 3, 1.5, -0.5, -1, -0.5, 0.5, 1.5, 2.5, 3, 3.5, 3.5, 3.5]),
        .iso("Jazz", gains: [4, 3.5, 3, 2, 1.5, -1, -1.5, -1.5, 0, 1, 1.5, 2, 2.5, 3, 3]),
        .iso("Classical", gains: [4.5, 4, 3.5, 3, 2.5, 1, -1, -1.5, -1.5, -1, 0, 1, 2, 3, 3.5]),
        .iso("Small Speakers", gains: [5.5, 5, 4.5, 3.5, 2.5, 1.5, 0.5, 0, -0.5, -1, -1.5, -2, -2.5, -3, -3.5]),
    ]
}

/// Parses and writes the Equalizer APO / AutoEq `ParametricEQ.txt` format.
///
/// Example lines:
/// ```
/// Preamp: -6.2 dB
/// Filter 1: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70
/// Filter 2: ON PK Fc 160 Hz Gain -2.1 dB Q 0.83
/// ```
public enum ParametricEQFile {
    public static func parse(_ text: String, name: String) -> EQPreset? {
        var preamp = 0.0
        var bands: [EQBand] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let tokens = line.split(separator: " ").map(String.init)
            if line.lowercased().hasPrefix("preamp:"), tokens.count >= 2, let value = Double(tokens[1]) {
                preamp = value
                continue
            }
            guard line.lowercased().hasPrefix("filter"), let onIndex = tokens.firstIndex(where: { $0 == "ON" || $0 == "OFF" }),
                  onIndex + 1 < tokens.count else { continue }
            let type: EQFilterType
            switch tokens[onIndex + 1].uppercased() {
            case "PK", "PEQ": type = .peak
            case "LSC", "LS", "LSQ": type = .lowShelf
            case "HSC", "HS", "HSQ": type = .highShelf
            case "LP", "LPQ": type = .lowPass
            case "HP", "HPQ": type = .highPass
            case "BP": type = .bandPass
            case "NO": type = .notch
            default: continue
            }
            func value(after key: String) -> Double? {
                guard let i = tokens.firstIndex(of: key), i + 1 < tokens.count else { return nil }
                return Double(tokens[i + 1])
            }
            guard let frequency = value(after: "Fc") else { continue }
            bands.append(EQBand(isEnabled: tokens[onIndex] == "ON", type: type, frequency: frequency,
                                gain: value(after: "Gain") ?? 0, q: value(after: "Q") ?? (type == .peak ? EQMath.defaultQ : 0.707)))
        }
        guard !bands.isEmpty else { return nil }
        // Keep exactly 15 bands: drop extras, pad with neutral peaks.
        bands = Array(bands.prefix(EQMath.bandCount))
        while bands.count < EQMath.bandCount {
            bands.append(EQBand(isEnabled: false, frequency: EQMath.isoFrequencies[bands.count]))
        }
        return EQPreset(name: name, preamp: preamp, bands: bands)
    }

    public static func export(_ preset: EQPreset) -> String {
        var lines = [String(format: "Preamp: %.1f dB", preset.preamp)]
        for (index, band) in preset.bands.enumerated() {
            let code = switch band.type {
            case .peak: "PK"
            case .lowShelf: "LSC"
            case .highShelf: "HSC"
            case .lowPass: "LPQ"
            case .highPass: "HPQ"
            case .bandPass: "BP"
            case .notch: "NO"
            }
            lines.append(String(format: "Filter %d: %@ %@ Fc %.0f Hz Gain %.1f dB Q %.2f",
                                index + 1, band.isEnabled ? "ON" : "OFF", code, band.frequency, band.gain, band.q))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Owns the AVAudioUnitEQ node and keeps it in sync with an `EQPreset`.
public final class EqualizerNode: @unchecked Sendable {
    public let node = AVAudioUnitEQ(numberOfBands: EQMath.bandCount)

    public init() {
        apply(.flat, enabled: false)
    }

    public func apply(_ preset: EQPreset, enabled: Bool) {
        node.bypass = !enabled
        node.globalGain = Float(preset.preamp.clamped(to: -96...24))
        for (index, band) in node.bands.enumerated() {
            guard index < preset.bands.count else {
                band.bypass = true
                continue
            }
            let source = preset.bands[index]
            band.filterType = source.type.avType
            band.frequency = Float(source.frequency.clamped(to: EQMath.frequencyRange))
            band.gain = Float(source.gain.clamped(to: EQMath.gainRange))
            band.bandwidth = Float(EQMath.bandwidth(fromQ: source.q.clamped(to: EQMath.qRange)).clamped(to: 0.05...5))
            band.bypass = !source.isEnabled
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
