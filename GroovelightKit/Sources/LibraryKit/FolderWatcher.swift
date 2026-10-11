import CoreServices
import Foundation

/// Watches folders recursively with FSEvents and reports (debounced) that something changed.
public final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "groovelight.folder-watcher")
    private let onChange: @Sendable ([String]) -> Void

    public init(onChange: @escaping @Sendable ([String]) -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    public func watch(_ paths: [String], latency: TimeInterval = 3) {
        stop()
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            watcher.onChange(Array(array.prefix(count)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

/// Security-scoped bookmark helpers for library folders chosen with an open panel.
public enum FolderAccess {
    public static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves the bookmark and starts security-scoped access. Returns the URL and a refreshed bookmark if it was stale.
    public static func startAccessing(_ bookmark: Data) throws -> (url: URL, refreshedBookmark: Data?) {
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
        _ = url.startAccessingSecurityScopedResource()
        return (url, isStale ? try? makeBookmark(for: url) : nil)
    }
}
