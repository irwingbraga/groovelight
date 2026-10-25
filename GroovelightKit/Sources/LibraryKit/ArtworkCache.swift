import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Content-addressed artwork store: `<hash>.img` (original) plus JPEG thumbnails `<hash>_<size>.jpg`.
public final class ArtworkCache: Sendable {
    public enum Size: Int, Sendable, CaseIterable {
        case small = 256
        case large = 800
    }

    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func url(for hash: String, size: Size?) -> URL {
        if let size {
            return directory.appendingPathComponent("\(hash)_\(size.rawValue).jpg")
        }
        return directory.appendingPathComponent("\(hash).img")
    }

    /// Stores `data` (any ImageIO-readable format) and returns its hash, or nil if it is not a valid image.
    @discardableResult
    public func store(_ data: Data) -> String? {
        let hash = SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
        let original = url(for: hash, size: nil)
        if FileManager.default.fileExists(atPath: original.path) { return hash }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        do {
            try data.write(to: original, options: .atomic)
            for size in Size.allCases {
                try writeThumbnail(from: source, size: size.rawValue, to: url(for: hash, size: size))
            }
            return hash
        } catch {
            try? FileManager.default.removeItem(at: original)
            return nil
        }
    }

    /// Stores an image under a hash given elsewhere (a cover from the Mac keeps the Mac's hash, which the snapshot names,
    /// though the copy sent is smaller). False when it is not a valid image.
    @discardableResult
    public func store(_ data: Data, as hash: String) -> Bool {
        let original = url(for: hash, size: nil)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return false }
        do {
            try data.write(to: original, options: .atomic)
            for size in Size.allCases {
                try writeThumbnail(from: source, size: size.rawValue, to: url(for: hash, size: size))
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: original)
            return false
        }
    }

    public func has(_ hash: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: hash, size: .small).path)
    }

    /// Removes every image but `hashes` (covers of songs no longer on a device).
    public func prune(keeping hashes: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files {
            let hash = String(file.prefix { $0 != "." && $0 != "_" })
            if !hashes.contains(hash) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(file)) }
        }
    }

    private func writeThumbnail(from source: CGImageSource, size: Int, to destinationURL: URL) throws {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Looks for a cover image next to the audio files (cover.jpg, folder.png, front.jpeg, ...).
    public static func folderImage(in directory: URL) -> URL? {
        let names = ["cover", "folder", "front", "albumart", "album", "artwork"]
        let extensions = ["jpg", "jpeg", "png", "webp", "heic"]
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        let candidates = contents.filter { extensions.contains($0.pathExtension.lowercased()) }
        for name in names {
            if let match = candidates.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == name }) {
                return match
            }
        }
        return nil
    }
}
