import AppKit
import LibraryKit
import PlayerCore
import SwiftUI

/// Loads cached artwork thumbnails off the main thread and keeps decoded images in memory.
final class ArtworkLoader: @unchecked Sendable {
    static let shared = ArtworkLoader()

    var cache: ArtworkCache?
    private let images = NSCache<NSString, NSImage>()

    init() {
        images.countLimit = 600
    }

    func cached(hash: String, size: ArtworkCache.Size) -> NSImage? {
        images.object(forKey: "\(hash)_\(size.rawValue)" as NSString)
    }

    func image(hash: String, size: ArtworkCache.Size) async -> NSImage? {
        let key = "\(hash)_\(size.rawValue)" as NSString
        if let image = images.object(forKey: key) { return image }
        guard let url = cache?.url(for: hash, size: size) else { return nil }
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let image = NSImage(contentsOf: url) else { return nil }
            // Force decode now instead of during the first draw on the main thread.
            _ = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            return image
        }.value
        if let image { images.setObject(image, forKey: key) }
        return image
    }
}

/// Album artwork with a gradient placeholder.
struct ArtworkImage: View {
    var hash: String?
    var size: ArtworkCache.Size = .small
    var cornerRadius: CGFloat = 8

    @State private var image: NSImage?

    init(hash: String?, size: ArtworkCache.Size = .small, cornerRadius: CGFloat = 8) {
        self.hash = hash
        self.size = size
        self.cornerRadius = cornerRadius
        // Already-decoded images show on the first frame (no placeholder flash while scrolling).
        _image = State(initialValue: hash.flatMap { ArtworkLoader.shared.cached(hash: $0, size: size) })
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                PlaceholderArtwork(seed: hash ?? "")
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .task(id: hash) {
            guard let hash else {
                image = nil
                return
            }
            if let cached = ArtworkLoader.shared.cached(hash: hash, size: size) {
                image = cached
            } else {
                image = await ArtworkLoader.shared.image(hash: hash, size: size)
            }
        }
    }
}

struct PlaceholderArtwork: View {
    var seed: String

    var body: some View {
        let hue = Double(seed.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360
        LinearGradient(colors: [Color(hue: hue, saturation: 0.35, brightness: 0.45), Color(hue: hue, saturation: 0.5, brightness: 0.2)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.white.opacity(0.5))
            }
    }
}

extension PlayableItem {
    /// Artwork hash recovered from the cached thumbnail file name (`<hash>_<size>.jpg`).
    var artworkHash: String? {
        artworkURL.flatMap { $0.deletingPathExtension().lastPathComponent.split(separator: "_").first.map(String.init) }
    }
}
