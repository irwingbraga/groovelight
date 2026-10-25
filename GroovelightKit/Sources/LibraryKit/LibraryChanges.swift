#if os(macOS)
import Foundation

/// Library folder changes waiting to be scanned, gathered from file system events. Nothing is dropped: events that come
/// in while a scan runs wait here for the next one.
public struct LibraryChanges: Sendable {
    /// The library folders (id and path) events are matched against.
    public var roots: [(id: Int64, path: String)] {
        didSet { updateRealPaths() }
    }
    /// Each folder's real path (symbolic links resolved, as file system events report it), when it differs.
    private var realPaths: [(real: String, path: String)] = []
    private var full = Set<Int64>()
    private var folders: [Int64: Set<String>] = [:]
    private var artworkFolders: [Int64: Set<String>] = [:]
    /// Newest event id taken in (processed once `take` hands its work out and the scans finish).
    public private(set) var latestEventId: UInt64?

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "heic", "tif", "tiff", "bmp"]

    public init(roots: [(id: Int64, path: String)]) {
        self.roots = roots
        updateRealPaths()
    }

    private mutating func updateRealPaths() {
        let trimmed = roots.map { (id: $0.id, path: Self.trimmed($0.path)) }
        if trimmed.map(\.path) != roots.map(\.path) { roots = trimmed }
        realPaths = roots.compactMap { root in
            let real = Self.trimmed(Self.realPath(root.path))
            return real == root.path ? nil : (real, root.path)
        }
    }

    public var isEmpty: Bool { full.isEmpty && folders.isEmpty }

    /// Adds file system events.
    public mutating func add(_ events: [FolderEvent], audioExtensions: Set<String>) {
        for event in events {
            if event.id > 0 { latestEventId = max(latestEventId ?? 0, event.id) }
            let flags = event.flags
            if !flags.intersection([.userDropped, .kernelDropped, .eventIdsWrapped]).isEmpty {
                full.formUnion(roots.map(\.id))
                continue
            }
            if flags.contains(.historyDone) { continue }
            let path = libraryPath(Self.trimmed(event.path))
            if flags.contains(.rootChanged) || flags.contains(.mount) || flags.contains(.unmount) {
                // The library folder itself (or its drive) changed: check all of it.
                for root in roots where root.path == path || root.path.hasPrefix(path + "/") || path.hasPrefix(root.path + "/") {
                    full.insert(root.id)
                }
                continue
            }
            guard let root = root(containing: path) else { continue }
            let name = (path as NSString).lastPathComponent
            if flags.contains(.mustScanSubDirs) || (!flags.contains(.isFile) && !flags.contains(.isDirectory)) {
                addFolder(path, root: root)
            } else if flags.contains(.isDirectory) {
                // A folder created, removed or renamed: what is in it (or was).
                if !name.hasPrefix(".") { addFolder(path, root: root) }
            } else {
                guard !name.hasPrefix(".") else { continue }
                let ext = (name as NSString).pathExtension.lowercased()
                let folder = (path as NSString).deletingLastPathComponent
                if ext == "cue" || audioExtensions.contains(ext) {
                    addFolder(folder, root: root)
                } else if Self.imageExtensions.contains(ext) {
                    addFolder(folder, root: root)
                    artworkFolders[root.id, default: []].insert(folder)
                }
            }
        }
    }

    /// Checks a folder (a song that would not play because its file is gone).
    public mutating func addFolder(_ path: String) {
        let path = libraryPath(Self.trimmed(path))
        if let root = root(containing: path) { addFolder(path, root: root) }
    }

    /// Checks every file of a library folder.
    public mutating func addFull(rootId: Int64) {
        full.insert(rootId)
    }

    /// Hands out the waiting work, one scope per library folder, and starts over empty.
    public mutating func take() -> [(rootId: Int64, scope: ScanScope)] {
        var work: [(Int64, ScanScope)] = []
        for root in roots {
            if full.contains(root.id) {
                work.append((root.id, .full))
            } else if let set = folders[root.id], !set.isEmpty {
                work.append((root.id, .folders(Self.outermost(set), artworkFolders: artworkFolders[root.id] ?? [])))
            }
        }
        full = []
        folders = [:]
        artworkFolders = [:]
        return work
    }

    /// An event's path as the library spells it (through the folder's symbolic links, like /var for /private/var).
    private func libraryPath(_ path: String) -> String {
        for (real, library) in realPaths where path == real || path.hasPrefix(real + "/") {
            return library + path.dropFirst(real.count)
        }
        return path
    }

    private func root(containing path: String) -> (id: Int64, path: String)? {
        roots.filter { path == $0.path || path.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
    }

    private mutating func addFolder(_ path: String, root: (id: Int64, path: String)) {
        if path == root.path || !path.hasPrefix(root.path + "/") {
            full.insert(root.id)
        } else {
            folders[root.id, default: []].insert(path)
        }
    }

    /// Folders not inside another one of the set (scanning a folder covers what is below it).
    static func outermost(_ folders: Set<String>) -> Set<String> {
        let sorted = folders.sorted()
        var result: [String] = []
        for folder in sorted where !result.contains(where: { folder == $0 || folder.hasPrefix($0 + "/") }) {
            result.append(folder)
        }
        return Set(result)
    }

    /// The path with every symbolic link resolved, as the kernel reports it. (Foundation's `resolvingSymlinksInPath`
    /// gives /tmp back for /private/tmp, which is not what file system events contain.)
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
#endif
