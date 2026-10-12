import CoreServices
import Foundation

/// One file system change reported by `FolderWatcher`.
public struct FolderEvent: Sendable, Equatable {
    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        /// Changes under `path` were coalesced: everything below it must be checked.
        public static let mustScanSubDirs = Flags(rawValue: UInt32(kFSEventStreamEventFlagMustScanSubDirs))
        /// Events were lost (by the app or the system): the whole library must be checked.
        public static let userDropped = Flags(rawValue: UInt32(kFSEventStreamEventFlagUserDropped))
        public static let kernelDropped = Flags(rawValue: UInt32(kFSEventStreamEventFlagKernelDropped))
        public static let eventIdsWrapped = Flags(rawValue: UInt32(kFSEventStreamEventFlagEventIdsWrapped))
        /// The replay of past events is over; live events follow.
        public static let historyDone = Flags(rawValue: UInt32(kFSEventStreamEventFlagHistoryDone))
        /// A watched folder itself was moved, renamed or deleted.
        public static let rootChanged = Flags(rawValue: UInt32(kFSEventStreamEventFlagRootChanged))
        public static let mount = Flags(rawValue: UInt32(kFSEventStreamEventFlagMount))
        public static let unmount = Flags(rawValue: UInt32(kFSEventStreamEventFlagUnmount))
        public static let isFile = Flags(rawValue: UInt32(kFSEventStreamEventFlagItemIsFile))
        public static let isDirectory = Flags(rawValue: UInt32(kFSEventStreamEventFlagItemIsDir))
    }

    public var path: String
    public var flags: Flags
    public var id: UInt64

    public init(path: String, flags: Flags, id: UInt64) {
        self.path = path
        self.flags = flags
        self.id = id
    }
}

/// Watches folders recursively with FSEvents and reports their changes in batches (every `latency` seconds). Started
/// from an event id, it first replays what changed since then (even while the app was not running).
public final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "groovelight.folder-watcher")
    private let onChange: @Sendable ([FolderEvent]) -> Void

    public init(onChange: @escaping @Sendable ([FolderEvent]) -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    /// Watches `paths`, replaying the changes after event `since` first (nil: only changes from now on).
    public func watch(_ paths: [String], since: UInt64? = nil, latency: TimeInterval = 1.5) {
        stop()
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let events = (0..<min(count, array.count)).map { index in
                FolderEvent(path: array[index], flags: FolderEvent.Flags(rawValue: flags[index]), id: ids[index])
            }
            watcher.onChange(events)
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagWatchRoot)
        let start = since.map { FSEventStreamEventId($0) } ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray, start, latency, flags) else { return }
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

    /// The newest event id on this Mac: what a folder's changes are complete up to after a full scan started now.
    public static var currentEventId: UInt64 { UInt64(FSEventsGetCurrentEventId()) }

    /// The id of the event history of the volume holding `path`; it changes when that history is reset.
    public static func historyId(for path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0, let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// Whether the volume holding `path` is local; network shares do not report changes, so they are checked on a timer.
    public static func isLocalVolume(_ path: String) -> Bool {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeIsLocalKey])
        return values?.volumeIsLocal ?? true
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
