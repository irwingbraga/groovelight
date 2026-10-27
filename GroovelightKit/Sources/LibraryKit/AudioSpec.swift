import Foundation

/// Quality class of a file, from best to worst, used for badges.
public enum QualityTier: Int, Comparable, Sendable, CaseIterable {
    case standard
    case highQuality
    case lossless
    case hiResLossless
    case dsd

    public static func < (lhs: QualityTier, rhs: QualityTier) -> Bool { lhs.rawValue < rhs.rawValue }

    public var displayName: String {
        switch self {
        case .standard: "Standard"
        case .highQuality: "High Quality"
        case .lossless: "Lossless"
        case .hiResLossless: "Hi-Res Lossless"
        case .dsd: "DSD"
        }
    }

    public var isLossless: Bool { self >= .lossless }
}

/// Technical description of an audio file: codec, resolution and bitrate.
public struct AudioSpec: Hashable, Sendable {
    public enum Codec: String, Sendable {
        case flac, alac, wav, aiff, wavPack, monkeysAudio, trueAudio, shorten, oggFLAC
        case dsf, dsdiff
        case mp3, aac, vorbis, opus, musepack, speex, mp1, mp2
        case module
        case unknown

        public init(formatName: String?) {
            let name = (formatName ?? "").lowercased()
            switch name {
            case "flac": self = .flac
            case "apple lossless": self = .alac
            case "wave": self = .wav
            case "aiff": self = .aiff
            case "wavpack": self = .wavPack
            case "monkey's audio": self = .monkeysAudio
            case "true audio": self = .trueAudio
            case "shorten": self = .shorten
            case "ogg flac": self = .oggFLAC
            case "dsd stream": self = .dsf
            case "dsd interchange": self = .dsdiff
            case "mp3": self = .mp3
            case "aac": self = .aac
            case "ogg vorbis": self = .vorbis
            case "ogg opus": self = .opus
            case "musepack": self = .musepack
            case "ogg speex": self = .speex
            default:
                if name.hasSuffix("layer iii") { self = .mp3 }
                else if name.hasSuffix("layer ii") { self = .mp2 }
                else if name.hasSuffix("layer i") { self = .mp1 }
                else if name.hasSuffix("module") { self = .module }
                else { self = .unknown }
            }
        }

        /// Short, familiar name ("ALAC" rather than "Apple Lossless").
        public var shortName: String {
            switch self {
            case .flac: "FLAC"
            case .alac: "ALAC"
            case .wav: "WAV"
            case .aiff: "AIFF"
            case .wavPack: "WavPack"
            case .monkeysAudio: "APE"
            case .trueAudio: "TTA"
            case .shorten: "SHN"
            case .oggFLAC: "Ogg FLAC"
            case .dsf: "DSF"
            case .dsdiff: "DFF"
            case .mp3: "MP3"
            case .aac: "AAC"
            case .vorbis: "Vorbis"
            case .opus: "Opus"
            case .musepack: "MPC"
            case .speex: "Speex"
            case .mp1: "MP1"
            case .mp2: "MP2"
            case .module: "Module"
            case .unknown: "Audio"
            }
        }

        public var isLossless: Bool {
            switch self {
            case .flac, .alac, .wav, .aiff, .wavPack, .monkeysAudio, .trueAudio, .shorten, .oggFLAC, .dsf, .dsdiff: true
            default: false
            }
        }

        public var isDSD: Bool { self == .dsf || self == .dsdiff }
    }

    public var codec: Codec
    /// Original format name as reported by the decoder (e.g. "Apple Lossless", "MPEG-1 Layer III").
    public var formatName: String?
    public var sampleRate: Double?
    public var bitDepth: Int?
    /// Average bitrate in kbps.
    public var bitrate: Double?
    public var channels: Int?

    public init(formatName: String?, sampleRate: Double?, bitDepth: Int?, bitrate: Double?, channels: Int?) {
        codec = Codec(formatName: formatName)
        self.formatName = formatName
        self.sampleRate = sampleRate.flatMap { $0 > 0 ? $0 : nil }
        self.bitDepth = bitDepth.flatMap { $0 > 0 ? $0 : nil }
        self.bitrate = bitrate.flatMap { $0 > 0 ? $0 : nil }
        self.channels = channels.flatMap { $0 > 0 ? $0 : nil }
    }

    public var tier: QualityTier {
        if codec.isDSD { return .dsd }
        if codec.isLossless {
            // Hi-Res Audio (JAS): better than CD, i.e. more than 16-bit or above 48 kHz.
            let deep = (bitDepth ?? 16) > 16
            let fast = (sampleRate ?? 44_100) > 48_000
            return deep || fast ? .hiResLossless : .lossless
        }
        guard let bitrate else { return .standard }
        let threshold: Double = codec == .opus ? 160 : 256
        return bitrate >= threshold * 0.97 ? .highQuality : .standard
    }

    // MARK: - Formatting

    /// "44.1 kHz", "96 kHz", or for DSD "DSD64 (2.8 MHz)".
    public var sampleRateText: String? {
        guard let sampleRate else { return nil }
        if codec.isDSD {
            let multiple = Int((sampleRate / 44_100).rounded())
            return String(format: "DSD%d (%.1f MHz)", multiple, sampleRate / 1_000_000)
        }
        let khz = sampleRate / 1_000
        return khz.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f kHz", khz) : String(format: "%.1f kHz", khz)
    }

    public var bitrateText: String? {
        bitrate.map { String(format: "%.0f kbps", $0) }
    }

    /// Resolution: "24-bit / 96 kHz" for PCM lossless, "DSD64 (2.8 MHz)" for DSD, "320 kbps" for lossy.
    public var resolutionText: String {
        if codec.isDSD { return sampleRateText ?? "DSD" }
        if codec.isLossless {
            let parts = [bitDepth.map { "\($0)-bit" }, sampleRateText].compactMap { $0 }
            return parts.joined(separator: " / ")
        }
        return [bitrateText, sampleRateText].compactMap { $0 }.joined(separator: " · ")
    }

    /// One line summary: "FLAC · 24-bit / 96 kHz", "MP3 · 320 kbps · 44.1 kHz".
    public var summary: String {
        let resolution = resolutionText
        return resolution.isEmpty ? codec.shortName : "\(codec.shortName) · \(resolution)"
    }

    /// Very short form for list rows: "FLAC 24/96", "ALAC 16/44.1", "MP3 320", "DSD64".
    public var compactText: String {
        if codec.isDSD, let sampleRate { return "DSD\(Int((sampleRate / 44_100).rounded()))" }
        if codec.isLossless {
            guard let sampleRate else { return codec.shortName }
            let khz = sampleRate / 1_000
            let rate = khz.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", khz) : String(format: "%.1f", khz)
            return "\(codec.shortName) \(bitDepth.map { "\($0)/" } ?? "")\(rate)"
        }
        return bitrate.map { "\(codec.shortName) \(Int($0.rounded()))" } ?? codec.shortName
    }

    public var channelsText: String? {
        switch channels {
        case nil: nil
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        case let count?: "\(count) channels"
        }
    }

    // MARK: - Grouping

    /// Key used to decide whether every track of an album shares the same configuration. Lossless bitrates vary
    /// with content, so they are ignored; lossy bitrates are snapped to the usual encoder settings (VBR averages wobble).
    public var uniformityKey: AudioSpec {
        var key = self
        key.formatName = nil
        if codec.isLossless {
            key.bitrate = nil
        } else if let bitrate {
            let standard: [Double] = [64, 96, 128, 160, 192, 224, 256, 320]
            key.bitrate = standard.min { abs($0 - bitrate) < abs($1 - bitrate) }
        }
        return key
    }

    /// The shared spec when all `specs` have the same configuration, otherwise nil.
    public static func uniform(_ specs: [AudioSpec]) -> AudioSpec? {
        guard let first = specs.first else { return nil }
        let key = first.uniformityKey
        guard specs.allSatisfy({ $0.uniformityKey == key }) else { return nil }
        // Show the snapped bitrate for lossy albums so VBR averages read as one value.
        return key.codec.isLossless ? first : AudioSpec(formatName: first.formatName, sampleRate: key.sampleRate,
                                                       bitDepth: key.bitDepth, bitrate: key.bitrate, channels: key.channels)
    }
}

extension Track {
    public var audioSpec: AudioSpec {
        AudioSpec(formatName: format, sampleRate: sampleRate, bitDepth: bitDepth, bitrate: bitrate, channels: channels)
    }
}

extension DeviceCatalog.Song {
    /// The song's format as the Mac's list gives it (codec, sample rate and bit depth; no bitrate, so a lossy song gets
    /// no high quality mark).
    public var audioSpec: AudioSpec {
        AudioSpec(formatName: AudioSpec.Codec(rawValue: codec)?.formatName, sampleRate: sampleRate.map(Double.init), bitDepth: bitDepth,
                  bitrate: nil, channels: nil)
    }
}
