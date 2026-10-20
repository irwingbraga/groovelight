import AudioToolbox
import AVFAudio
import CryptoKit
import Foundation
import SFBAudioEngine

/// A lossy format lossless songs can be sent in, to fit more music on a device: each at the bitrate where it is about
/// as transparent as the others (Opus at 160 kbps, AAC at 192 kbps, MP3 at 320 kbps).
public enum LossyEncoding: String, Codable, CaseIterable, Sendable, Identifiable {
    case opus160, aac192, mp3_320

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .opus160: "Opus 160 kbps"
        case .aac192: "AAC 192 kbps"
        case .mp3_320: "MP3 320 kbps"
        }
    }

    public var fileExtension: String {
        switch self {
        case .opus160: "opus"
        case .aac192: "m4a"
        case .mp3_320: "mp3"
        }
    }

    /// The `AudioSpec.Codec` raw value of the files it makes.
    public var codec: String {
        switch self {
        case .opus160: "opus"
        case .aac192: "aac"
        case .mp3_320: "mp3"
        }
    }

    public var kbps: Int {
        switch self {
        case .opus160: 160
        case .aac192: 192
        case .mp3_320: 320
        }
    }

    /// The sample rate a song of `rate` is encoded at: Opus always works at 48 kHz; AAC and MP3 go up to 48 kHz, so
    /// hi-res songs come down to 44.1 or 48 kHz (whichever divides their rate).
    public func outputRate(for rate: Double) -> Double {
        switch self {
        case .opus160: 48_000
        case .aac192, .mp3_320: rate <= 48_000 ? rate : (Int(rate) % 44_100 == 0 ? 44_100 : 48_000)
        }
    }

    /// Codecs of the songs it applies to: lossless ones (lossy songs are never encoded again).
    public static func applies(to codec: AudioSpec.Codec) -> Bool {
        switch codec {
        case .flac, .alac, .wav, .aiff, .wavPack, .monkeysAudio, .trueAudio, .shorten, .oggFLAC: true
        default: false
        }
    }
}

/// Lossless conversion to FLAC, for players that cannot decode a song's format (ALAC, AIFF and WavPack on Android):
/// the same audio, sample rate and bit depth, with the tags and artwork copied over. Or lossy encoding (`LossyEncoding`)
/// for devices set to it.
public enum FormatConverter {
    public enum ConversionError: LocalizedError {
        case failed(String, String, String = "FLAC")

        public var errorDescription: String? {
            switch self {
            case .failed(let name, let reason, let format): "Could not convert “\(name)” to \(format): \(reason)"
            }
        }
    }

    /// What to convert: a whole file, or one song of a CUE album (its region of the album's file, with its own tags,
    /// since the file's tags describe the whole album).
    public struct Source: Hashable, Sendable {
        public var url: URL
        /// Seconds into the file; nil for the whole file.
        public var startTime: Double?
        /// Where the region ends (nil: the end of the file).
        public var endTime: Double?
        /// Written into the converted file, over the tags copied from the source.
        public var tags: TrackMetadata?
        /// What it becomes: FLAC (nil), or a lossy format.
        public var encoding: LossyEncoding?

        public init(url: URL, startTime: Double? = nil, endTime: Double? = nil, tags: TrackMetadata? = nil, encoding: LossyEncoding? = nil) {
            self.url = url
            self.startTime = startTime
            self.endTime = endTime
            self.tags = tags
            self.encoding = encoding
        }

        public var fileExtension: String { encoding?.fileExtension ?? "flac" }

        /// The song of a CUE album, as a file of its own (FLAC, or `encoding`).
        public static func cueTrack(_ track: Track, encoding: LossyEncoding? = nil) -> Source {
            Source(url: track.url, startTime: track.startTime ?? 0, endTime: track.endTime, tags: TrackMetadata(
                title: track.title, artist: track.artist.nonEmpty, album: track.album, albumArtist: track.albumArtist,
                genre: track.genre, year: track.year, trackNumber: track.trackNumber, trackTotal: track.trackTotal,
                discNumber: track.discNumber, discTotal: track.discTotal, isCompilation: track.isCompilation), encoding: encoding)
        }
    }

    /// Converts `source` into `destination` (any name: the encoder works on a temporary .flac beside it).
    public static func convertToFLAC(_ source: URL, to destination: URL) throws {
        try convertToFLAC(Source(url: source), to: destination)
    }

    /// Converts `source` into `destination`: to FLAC, or to its lossy encoding.
    public static func convert(_ source: Source, to destination: URL) throws {
        try convertToFLAC(source, to: destination)
    }

    public static func convertToFLAC(_ source: Source, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).\(source.fileExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            if let encoding = source.encoding {
                try encode(source, as: encoding, to: temporary)
            } else if let start = source.startTime {
                // Sample accurate, as the Mac plays CUE tracks: consecutive songs join without a gap or an overlap.
                let rate = try AudioFile(readingPropertiesAndMetadataFrom: source.url).properties.sampleRate ?? 0
                guard rate > 0 else { throw ConversionError.failed(source.url.lastPathComponent, "the sample rate is unknown") }
                let startFrame = AVAudioFramePosition((start * rate).rounded())
                let length = source.endTime.map { AVAudioFramePosition((($0 - start) * rate).rounded()) } ?? -1
                try AudioConverter.convert(try AudioRegionDecoder(url: source.url, startFrame: startFrame, frameLength: length), to: temporary)
            } else {
                try AudioConverter.convert(source.url, to: temporary)
            }
        } catch let error as ConversionError {
            throw error
        } catch {
            throw ConversionError.failed(source.url.lastPathComponent, error.localizedDescription, source.encoding?.displayName ?? "FLAC")
        }
        try? AudioFile.copyMetadata(from: source.url, to: temporary)
        if let tags = source.tags { _ = try? TagWriter.write(tags, to: temporary) }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}

extension FormatConverter {
    /// Encodes the song (or its region of a CUE album's file) with an encoder set to the format's bitrate, through a
    /// float intermediate at the format's sample rate (the converter resamples hi-res songs for AAC and MP3).
    static func encode(_ source: Source, as encoding: LossyEncoding, to url: URL) throws {
        let decoder: any PCMDecoding
        if let start = source.startTime {
            let rate = try AudioFile(readingPropertiesAndMetadataFrom: source.url).properties.sampleRate ?? 0
            guard rate > 0 else { throw ConversionError.failed(source.url.lastPathComponent, "the sample rate is unknown", encoding.displayName) }
            let startFrame = AVAudioFramePosition((start * rate).rounded())
            let length = source.endTime.map { AVAudioFramePosition((($0 - start) * rate).rounded()) } ?? -1
            decoder = try AudioRegionDecoder(url: source.url, startFrame: startFrame, frameLength: length)
        } else {
            decoder = try AudioDecoder(url: source.url)
        }
        let encoder: AudioEncoder
        switch encoding {
        case .opus160:
            encoder = try AudioEncoder(url: url, encoderName: .oggOpus)
            encoder.settings = [.opusBitrate: 160, .opusBitrateMode: OpusBitrateMode.VBR,
                                .opusSignalType: OpusSignalType.music, .opusComplexity: 10]
        case .aac192:
            encoder = try AudioEncoder(url: url, encoderName: .coreAudio)
            encoder.settings = [.coreAudioFileTypeID: kAudioFileM4AType, .coreAudioFormatID: kAudioFormatMPEG4AAC,
                                .coreAudioAudioConverterPropertySettings: [kAudioConverterEncodeBitRate: 192_000,
                                                                           kAudioConverterCodecQuality: kAudioConverterQuality_Max]]
        case .mp3_320:
            encoder = try AudioEncoder(url: url, encoderName: .MP3)
            encoder.settings = [.mp3ConstantBitrate: 320, .mp3Quality: 2, .mp3StereoMode: MP3StereoMode.jointStereo]
        }
        let converter = try AudioConverter(decoder: decoder, encoder: encoder) { format in
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: encoding.outputRate(for: format.sampleRate),
                          channels: format.channelCount, interleaved: false)!
        }
        // Closed (and the file finished) when the converter goes away.
        try converter.convert()
    }
}

/// FLAC conversions kept in a folder by the song's fingerprint (path, size, date), so a device syncing again, or a
/// download that resumes, does not convert again. One conversion at a time.
public final class ConversionCache: @unchecked Sendable {
    public let folder: URL
    private let lock = NSLock()

    public init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// The FLAC for `source` with this `fingerprint`, converted now if it is not there yet.
    public func flac(for source: URL, fingerprint: String) throws -> URL {
        try flac(for: FormatConverter.Source(url: source), fingerprint: fingerprint)
    }

    public func flac(for source: FormatConverter.Source, fingerprint: String) throws -> URL {
        let target = folder.appendingPathComponent(Self.key(fingerprint) + "." + source.fileExtension)
        return try lock.withLock {
            if FileManager.default.fileExists(atPath: target.path) { return target }
            try FormatConverter.convertToFLAC(source, to: target)
            return target
        }
    }

    /// Removes conversions no fingerprint in `keeping` refers to (songs that changed or left every device).
    public func prune(keeping fingerprints: Set<String>) {
        let keys = Set(fingerprints.map(Self.key))
        lock.withLock {
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where !file.lastPathComponent.hasPrefix(".") && !keys.contains(file.deletingPathExtension().lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    static func key(_ fingerprint: String) -> String {
        SHA256.hash(data: Data(fingerprint.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
