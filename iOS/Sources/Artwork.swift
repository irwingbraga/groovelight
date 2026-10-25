import LibraryKit
import SwiftUI
import UIKit

/// An album cover (or artist photo) from the artwork store, or Groovelight's gradient until there is one.
struct Cover: View {
    @Environment(AppModel.self) private var model
    var hash: String? = nil
    var size: CGFloat? = nil
    var corner: CGFloat = 10
    /// The larger copy (800 pixels) for Now Playing; the small one (256) everywhere else.
    var large = false
    var symbol = "music.note"

    @State private var image: UIImage?

    init(hash: String? = nil, size: CGFloat? = nil, corner: CGFloat = 10, large: Bool = false, symbol: String = "music.note") {
        self.hash = hash
        self.size = size
        self.corner = corner
        self.large = large
        self.symbol = symbol
        // Seen already: shown at once, not after a frame of the gradient.
        _image = State(initialValue: ImageCache.image(hash, large: large))
    }

    var body: some View {
        RoundedRectangle(cornerRadius: corner)
            .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.30, blue: 0.63), Color(red: 0.56, green: 0.35, blue: 0.54)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: symbol).font(.system(size: (size ?? 120) * 0.35)).foregroundStyle(.white.opacity(0.85))
                }
            }
            .clipShape(.rect(cornerRadius: corner))
            .frame(width: size, height: size)
            .aspectRatio(1, contentMode: .fit)
            .task(id: hash) { image = await load() }
    }

    private func load() async -> UIImage? {
        if let cached = ImageCache.image(hash, large: large) { return cached }
        if let url = model.library.artworkURL(hash, size: large ? .large : .small) { return await ImageCache.load(url, hash: hash, large: large) }
        // Not here (a song of the Mac's library playing there): its cover as the Mac's pages show it.
        if let cached = ImageCache.image(hash) { return cached }
        guard let url = await model.catalog.coverURL(hash) else { return nil }
        return await ImageCache.load(url, hash: hash)
    }
}

/// Decoded covers by hash, so scrolling back (or opening a page again) shows them at once.
enum ImageCache {
    nonisolated(unsafe) private static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 600
        return cache
    }()

    static func image(_ hash: String?, large: Bool = false) -> UIImage? {
        hash.flatMap { shared.object(forKey: key($0, large)) }
    }

    /// Decodes the file away from the main thread, and keeps it.
    static func load(_ url: URL, hash: String?, large: Bool = false) async -> UIImage? {
        let image = await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: url.path)?.preparingForDisplay() }.value
        if let image, let hash { shared.setObject(image, forKey: key(hash, large)) }
        return image
    }

    private static func key(_ hash: String, _ large: Bool) -> NSString { "\(hash)\(large ? "@l" : "")" as NSString }
}
