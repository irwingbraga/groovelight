import CryptoKit
import Foundation
import SFBAudioEngine

/// Lossless conversion to FLAC, for players that cannot decode a song's format (ALAC, AIFF and WavPack on Android):
/// the same audio, sample rate and bit depth, with the tags and artwork copied over.
public enum FormatConverter {
    public enum ConversionError: LocalizedError {
        case failed(String, String)

        public var errorDescription: String? {
            switch self {
            case .failed(let name, let reason): "Could not convert “\(name)” to FLAC: \(reason)"
            }
        }
    }

    /// Converts `source` into `destination` (any name: the encoder works on a temporary .flac beside it).
    public static func convertToFLAC(_ source: URL, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try AudioConverter.convert(source, to: temporary)
        } catch {
            throw ConversionError.failed(source.lastPathComponent, error.localizedDescription)
        }
        try? AudioFile.copyMetadata(from: source, to: temporary)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporary, to: destination)
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
        let target = folder.appendingPathComponent(Self.key(fingerprint) + ".flac")
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
            where file.pathExtension == "flac" && !keys.contains(file.deletingPathExtension().lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    static func key(_ fingerprint: String) -> String {
        SHA256.hash(data: Data(fingerprint.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
