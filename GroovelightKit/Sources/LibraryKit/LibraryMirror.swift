import CryptoKit
import Foundation

/// A copy of the music library on a NAS (or another disk): `Music/<library folder>/` beside the data backups, same
/// relative paths and formats. What was copied is kept in a manifest (on this computer and a copy on the destination),
/// so a run plans its work from the library alone and only touches the destination to copy, move and remove files.
///
/// Files gone from the library are never deleted outright: they move to `Music/.Removed/<date>/` and are purged after a
/// number of days. A library folder that is offline (an unplugged drive) is skipped, never treated as empty, and one
/// that lost more than a quarter of its files waits for the user to confirm.
public enum LibraryMirror {
    public static let folderName = "Music"
    public static let removedFolderName = ".Removed"
    public static let manifestName = ".groovelight-mirror.json"
    static let partialSuffix = ".partial"
    /// A folder losing more than this share of its files since the last run asks first.
    public static let dropThreshold = 0.25
    /// Folders this small never ask (a few albums removed is not a lost drive).
    static let dropMinimum = 20

    // MARK: - Manifest

    public struct Entry: Codable, Hashable, Sendable {
        public var size: Int64
        /// The library file's modification date (seconds since 1970, to the millisecond).
        public var modified: Double
        public var sha256: String?
        /// When the copy was last read back and compared.
        public var verified: Date?

        public init(size: Int64, modified: Double, sha256: String? = nil, verified: Date? = nil) {
            self.size = size
            self.modified = modified
            self.sha256 = sha256
            self.verified = verified
        }
    }

    public struct Manifest: Codable, Sendable, Equatable {
        public var formatVersion = 1
        /// Library folder path to its folder's name in `Music`.
        public var roots: [String: String] = [:]
        /// "<folder name>/<relative path>" to what was copied.
        public var files: [String: Entry] = [:]
        public var lastRun: Date?
        public var lastSample: Date?

        public init() {}

        /// The folder name in `Music` for a library folder (its own name, numbered when two share it).
        public mutating func name(for rootPath: String) -> String {
            if let name = roots[rootPath] { return name }
            let base = URL(fileURLWithPath: rootPath).lastPathComponent
            var name = base.isEmpty ? "Music" : base
            var number = 2
            let taken = Set(roots.values)
            while taken.contains(name) {
                name = "\(base) \(number)"
                number += 1
            }
            roots[rootPath] = name
            return name
        }

        public func fileCount(in name: String) -> Int {
            files.keys.reduce(0) { $0 + ($1.hasPrefix(name + "/") ? 1 : 0) }
        }

        public static func load(from url: URL) -> Manifest? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(Manifest.self, from: data)
        }

        public func save(to url: URL) throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(self).write(to: url, options: .atomic)
        }
    }

    // MARK: - The library side

    public struct FileInfo: Hashable, Sendable {
        public var size: Int64
        public var modified: Double

        public init(size: Int64, modified: Double) {
            self.size = size
            self.modified = modified
        }

        func matches(_ entry: Entry) -> Bool { entry.size == size && entry.modified == modified }
    }

    /// Every file under `folder` (hidden ones left out), by relative path. Local and cheap: it never reads the NAS.
    public static func scan(_ folder: URL) throws -> [String: FileInfo] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw MirrorError.unreadable(folder.path)
        }
        let base = folder.standardizedFileURL.path
        var files: [String: FileInfo] = [:]
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            files[String(path.dropFirst(base.count + 1))] = FileInfo(size: Int64(values.fileSize ?? 0), modified: Self.seconds(values.contentModificationDate))
        }
        return files
    }

    static func seconds(_ date: Date?) -> Double {
        ((date ?? .distantPast).timeIntervalSince1970 * 1000).rounded() / 1000
    }

    // MARK: - Planning

    public struct Source: Sendable, Hashable {
        /// The library folder's path (its key in the manifest).
        public var path: String
        /// Its files, or nil when it is offline.
        public var files: [String: FileInfo]?

        public init(path: String, files: [String: FileInfo]?) {
            self.path = path
            self.files = files
        }
    }

    public struct Plan: Sendable, Equatable {
        /// Manifest keys to copy (new or changed), with the library file's info.
        public var copies: [String: FileInfo] = [:]
        /// A file renamed or moved in the library (same size and date): moved on the destination when its content is
        /// the same, else copied.
        public var moves: [Move] = []
        /// Manifest keys of files gone from the library.
        public var removals: [String] = []
        /// Library folders left out this time, and why.
        public var skipped: [String: String] = [:]
        /// Library folders that lost too many files: the user confirms first.
        public var needsConfirmation: [Drop] = []

        public var bytesToCopy: Int64 { copies.values.reduce(0) { $0 + $1.size } }
        public var isEmpty: Bool { copies.isEmpty && moves.isEmpty && removals.isEmpty }
    }

    public struct Move: Sendable, Hashable {
        public var from: String
        public var to: String
        public var info: FileInfo
    }

    public struct Drop: Codable, Sendable, Hashable {
        public var folder: String
        public var before: Int
        public var now: Int
    }

    /// What a run does, from the manifest and the library alone. `confirmed` are library folders the user said to
    /// mirror even though they lost many files.
    public static func plan(manifest: inout Manifest, sources: [Source], confirmed: Set<String> = []) -> Plan {
        var plan = Plan()
        // Gone from the library, by size and date, to recognize the same file under a new name.
        var gone: [FileInfo: [String]] = [:]
        var arrived: [(key: String, info: FileInfo)] = []
        for source in sources {
            let name = manifest.name(for: source.path)
            guard let files = source.files else {
                plan.skipped[source.path] = "offline"
                continue
            }
            let before = manifest.fileCount(in: name)
            if before >= dropMinimum, Double(files.count) < Double(before) * (1 - dropThreshold), !confirmed.contains(source.path) {
                plan.needsConfirmation.append(Drop(folder: source.path, before: before, now: files.count))
                plan.skipped[source.path] = "lost \(before - files.count) of \(before) files"
                continue
            }
            let prefix = name + "/"
            for (relative, info) in files {
                let key = prefix + relative
                if let entry = manifest.files[key], info.matches(entry) { continue }
                arrived.append((key, info))
            }
            for (key, entry) in manifest.files where key.hasPrefix(prefix) && files[String(key.dropFirst(prefix.count))] == nil {
                gone[FileInfo(size: entry.size, modified: entry.modified), default: []].append(key)
            }
        }
        for (key, info) in arrived.sorted(by: { $0.key < $1.key }) {
            if manifest.files[key] == nil, var keys = gone[info], !keys.isEmpty {
                keys.sort()
                let from = keys.removeFirst()
                gone[info] = keys
                plan.moves.append(Move(from: from, to: key, info: info))
            } else {
                plan.copies[key] = info
            }
        }
        plan.removals = gone.values.flatMap { $0 }.sorted()
        return plan
    }

    // MARK: - Running

    public struct Options: Sendable {
        /// Days files gone from the library stay in `.Removed` (nil: forever).
        public var keepRemovedDays: Int?
        /// Library folders to mirror even though they lost many files.
        public var confirmed: Set<String>
        /// Reads each new copy back and compares it.
        public var verifyNewCopies: Bool
        /// How often a sample of the copies is read back (and the share of them).
        public var sampleInterval: TimeInterval
        public var sampleFraction: Double
        /// Files copied at a time.
        public var concurrency: Int

        public init(keepRemovedDays: Int? = 30, confirmed: Set<String> = [], verifyNewCopies: Bool = true,
                    sampleInterval: TimeInterval = 30 * 24 * 3600, sampleFraction: Double = 0.01, concurrency: Int = 2) {
            self.keepRemovedDays = keepRemovedDays
            self.confirmed = confirmed
            self.verifyNewCopies = verifyNewCopies
            self.sampleInterval = sampleInterval
            self.sampleFraction = sampleFraction
            self.concurrency = concurrency
        }
    }

    public struct Report: Codable, Sendable, Hashable {
        public var date: Date
        public var copied = 0
        public var moved = 0
        public var removed = 0
        public var purged = 0
        public var verified = 0
        /// Copies found damaged or missing by the check, and copied again.
        public var repaired = 0
        public var bytesCopied: Int64 = 0
        public var totalFiles = 0
        public var totalBytes: Int64 = 0
        public var skipped: [String: String] = [:]
        public var needsConfirmation: [Drop] = []
        public var errors: [String] = []
        public var finished = false

        public init(date: Date = .now) {
            self.date = date
        }

        public var hasChanges: Bool { copied + moved + removed + repaired > 0 }
    }

    public enum Phase: Sendable {
        case planning
        case moving(done: Int, total: Int)
        case copying(done: Int, total: Int, bytes: Int64, totalBytes: Int64)
        case checking(done: Int, total: Int)
        case cleaning
    }

    public enum MirrorError: LocalizedError, Equatable {
        case unreadable(String)
        case notEnoughSpace(needed: Int64, available: Int64)
        case destinationGone
        case damagedCopy(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let path): "Could not read \(path)."
            case .notEnoughSpace(let needed, let available):
                "Not enough space on the backup folder: \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) to copy, \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) free."
            case .destinationGone: "The backup folder went away during the copy."
            case .damagedCopy(let path): "The copy of \(path) did not match the original after two tries."
            }
        }
    }

    /// Mirrors `sources` (library folder path to its folder on this computer) into `destination`'s `Music` folder.
    /// `state` is where this computer keeps its manifest. Returns what was done; throws only when the run could not
    /// start or the destination went away (what was copied until then is kept, and the next run resumes).
    public static func run(sources: [String: URL?], destination: URL, state: URL, options: Options = Options(),
                           now: Date = .now, progress: @Sendable (Phase) -> Void = { _ in }) async throws -> Report {
        let fileManager = FileManager.default
        let music = destination.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: music, withIntermediateDirectories: true)
        let remoteManifest = music.appendingPathComponent(manifestName)
        // This computer's manifest; on a new computer (or after losing it), the one on the destination.
        var manifest = Manifest.load(from: state) ?? Manifest.load(from: remoteManifest) ?? Manifest()
        var report = Report(date: now)

        progress(.planning)
        let destinationVolume = try? destination.resourceValues(forKeys: [.volumeURLKey]).volume
        var scanned: [Source] = []
        for (path, url) in sources.sorted(by: { $0.key < $1.key }) {
            guard let url, fileManager.fileExists(atPath: url.path) else {
                scanned.append(Source(path: path, files: nil))
                continue
            }
            // A library folder on the destination itself (music played from the NAS) is not copied onto itself.
            if let destinationVolume, let volume = try? url.resourceValues(forKeys: [.volumeURLKey]).volume,
               volume.standardizedFileURL == destinationVolume.standardizedFileURL, !(destinationVolume.path == "/") {
                report.skipped[path] = "on the backup folder's own disk"
                continue
            }
            scanned.append(Source(path: path, files: try? await Task.detached(priority: .utility) { try scan(url) }.value))
        }
        var plan = plan(manifest: &manifest, sources: scanned, confirmed: options.confirmed)
        report.skipped.merge(plan.skipped) { $1 }
        report.needsConfirmation = plan.needsConfirmation
        let local: [String: URL] = Dictionary(uniqueKeysWithValues: sources.compactMap { path, url in
            url.flatMap { url in manifest.roots[path].map { ($0, url) } }
        })
        func localURL(_ key: String) -> URL? {
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let root = local[parts[0]] else { return nil }
            return root.appendingPathComponent(parts[1])
        }
        func remoteURL(_ key: String) -> URL { music.appendingPathComponent(key) }
        var touchedFolders: Set<URL> = []

        // Space for what is to be copied (the moved files are already there).
        if let available = try? destination.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
           Int64(available) < plan.bytesToCopy + plan.bytesToCopy / 100 {
            throw MirrorError.notEnoughSpace(needed: plan.bytesToCopy, available: Int64(available))
        }

        // Moves: renamed or moved in the library, the same content.
        for (index, move) in plan.moves.enumerated() {
            try Task.checkCancellation()
            progress(.moving(done: index, total: plan.moves.count))
            guard var entry = manifest.files[move.from], let source = localURL(move.to) else { continue }
            let from = remoteURL(move.from)
            let to = remoteURL(move.to)
            let current = entry.sha256 == nil ? nil : try? await hash(source)
            let sameContent = current != nil && current == entry.sha256
            guard sameContent, fileManager.fileExists(atPath: from.path) else {
                plan.copies[move.to] = move.info
                plan.removals.append(move.from)
                continue
            }
            do {
                try fileManager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: to.path) { try fileManager.removeItem(at: to) }
                try fileManager.moveItem(at: from, to: to)
                touchedFolders.insert(from.deletingLastPathComponent())
                manifest.files[move.from] = nil
                entry.size = move.info.size
                entry.modified = move.info.modified
                manifest.files[move.to] = entry
                report.moved += 1
            } catch {
                plan.copies[move.to] = move.info
                plan.removals.append(move.from)
            }
        }

        // Removals: kept in .Removed/<date>/ for a while.
        let day = dayFormatter.string(from: now)
        for key in plan.removals.sorted() {
            try Task.checkCancellation()
            let file = remoteURL(key)
            if fileManager.fileExists(atPath: file.path) {
                let kept = music.appendingPathComponent(removedFolderName).appendingPathComponent(day).appendingPathComponent(key)
                do {
                    try fileManager.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fileManager.fileExists(atPath: kept.path) { try fileManager.removeItem(at: kept) }
                    try fileManager.moveItem(at: file, to: kept)
                    touchedFolders.insert(file.deletingLastPathComponent())
                } catch {
                    report.errors.append("Could not set aside \(key): \(error.localizedDescription)")
                    continue
                }
            }
            manifest.files[key] = nil
            report.removed += 1
        }
        try? manifest.save(to: state)

        // Copies, a few at a time, saving the manifest as they go (a run cut short resumes where it stopped).
        let copies = plan.copies.sorted { $0.key < $1.key }
        let totalBytes = copies.reduce(Int64(0)) { $0 + $1.value.size }
        var lastSave = Date()
        var done = 0
        var pending = copies.makeIterator()
        progress(.copying(done: 0, total: copies.count, bytes: 0, totalBytes: totalBytes))
        try await withThrowingTaskGroup(of: CopyResult.self) { group in
            func addNext() -> Bool {
                guard let (key, info) = pending.next() else { return false }
                guard let source = localURL(key) else { return addNext() }
                let target = remoteURL(key)
                let isNew = manifest.files[key] == nil
                let verify = options.verifyNewCopies && isNew
                group.addTask {
                    try Task.checkCancellation()
                    return copyOne(key: key, info: info, from: source, to: target, verify: verify, adopt: isNew)
                }
                return true
            }
            for _ in 0..<max(1, options.concurrency) where addNext() {}
            while let result = try await group.next() {
                done += 1
                switch result.outcome {
                case .copied(let sha, let verified, let adopted):
                    manifest.files[result.key] = Entry(size: result.info.size, modified: result.info.modified, sha256: sha, verified: verified ? now : nil)
                    report.copied += adopted ? 0 : 1
                    report.bytesCopied += adopted ? 0 : result.info.size
                case .failed(let message, let destinationGone):
                    if destinationGone {
                        group.cancelAll()
                        try? manifest.save(to: state)
                        throw MirrorError.destinationGone
                    }
                    if report.errors.count < 50 { report.errors.append(message) }
                }
                progress(.copying(done: done, total: copies.count, bytes: report.bytesCopied, totalBytes: totalBytes))
                if Date().timeIntervalSince(lastSave) > 30 {
                    try? manifest.save(to: state)
                    lastSave = Date()
                }
                if !Task.isCancelled { _ = addNext() }
            }
        }

        // Now and then, a sample of the copies is read back: one damaged on the NAS (or gone) is copied again.
        if manifest.lastSample.map({ now.timeIntervalSince($0) >= options.sampleInterval }) ?? !manifest.files.isEmpty {
            let candidates = manifest.files.keys.filter { key in
                guard let entry = manifest.files[key], entry.sha256 != nil else { return false }
                return entry.verified.map { now.timeIntervalSince($0) >= options.sampleInterval } ?? true
            }.sorted()
            let count = min(candidates.count, max(1, min(500, Int((Double(manifest.files.count) * options.sampleFraction).rounded(.up)))))
            var generator = SystemRandomNumberGenerator()
            let sample = candidates.shuffled(using: &generator).prefix(count)
            for (index, key) in sample.enumerated() {
                try Task.checkCancellation()
                progress(.checking(done: index, total: sample.count))
                guard var entry = manifest.files[key], let source = localURL(key) else { continue }
                // Only a library file that did not change since it was copied tells anything about the copy.
                guard let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      Int64(values.fileSize ?? -1) == entry.size, seconds(values.contentModificationDate) == entry.modified else { continue }
                let target = remoteURL(key)
                if let copy = try? await hash(target), copy == entry.sha256 {
                    entry.verified = now
                    manifest.files[key] = entry
                    report.verified += 1
                    continue
                }
                let info = FileInfo(size: entry.size, modified: entry.modified)
                switch copyOne(key: key, info: info, from: source, to: target, verify: true, adopt: false).outcome {
                case .copied(let sha, _, _):
                    manifest.files[key] = Entry(size: info.size, modified: info.modified, sha256: sha, verified: now)
                    report.repaired += 1
                    report.verified += 1
                case .failed(let message, let gone):
                    if gone { throw MirrorError.destinationGone }
                    report.errors.append(message)
                }
            }
            manifest.lastSample = now
        }

        // Cleaning up: folders left empty by moves and removals, and what stayed in .Removed long enough.
        progress(.cleaning)
        for folder in touchedFolders { removeEmptyFolders(from: folder, upTo: music) }
        if let days = options.keepRemovedDays { report.purged = purgeRemoved(in: music, olderThan: days, now: now) }

        manifest.lastRun = now
        try manifest.save(to: state)
        try? manifest.save(to: remoteManifest)
        report.totalFiles = manifest.files.count
        report.totalBytes = manifest.files.values.reduce(0) { $0 + $1.size }
        report.finished = true
        return report
    }

    // MARK: - Copying

    struct CopyResult: Sendable {
        enum Outcome: Sendable {
            case copied(sha256: String, verified: Bool, adopted: Bool)
            case failed(String, destinationGone: Bool)
        }
        var key: String
        var info: FileInfo
        var outcome: Outcome
    }

    /// Copies one file through `<name>.partial` (renamed when whole), keeping its date, and its hash on the way.
    /// `adopt`: a file already there with the same size and date (a run cut short before saving) is kept, not copied.
    static func copyOne(key: String, info: FileInfo, from source: URL, to target: URL, verify: Bool, adopt: Bool) -> CopyResult {
        let fileManager = FileManager.default
        let folder = target.deletingLastPathComponent()
        if adopt, let values = try? target.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
           Int64(values.fileSize ?? -1) == info.size, abs(seconds(values.contentModificationDate) - info.modified) < 2,
           let sha = try? hashSync(source) {
            return CopyResult(key: key, info: info, outcome: .copied(sha256: sha, verified: false, adopted: true))
        }
        var lastError: (any Error)?
        for _ in 0..<2 {
            let partial = folder.appendingPathComponent(".\(target.lastPathComponent)\(partialSuffix)")
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                let sha = try copyHashing(from: source, to: partial)
                try fileManager.setAttributes([.modificationDate: Date(timeIntervalSince1970: info.modified)], ofItemAtPath: partial.path)
                if verify, try hashSync(partial) != sha {
                    try? fileManager.removeItem(at: partial)
                    lastError = MirrorError.damagedCopy(key)
                    continue
                }
                if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
                try fileManager.moveItem(at: partial, to: target)
                return CopyResult(key: key, info: info, outcome: .copied(sha256: sha, verified: verify, adopted: false))
            } catch {
                try? fileManager.removeItem(at: partial)
                lastError = error
                if isGone(error) { break }
            }
        }
        let message = "\(key): \(lastError?.localizedDescription ?? "not copied")"
        return CopyResult(key: key, info: info, outcome: .failed(message, destinationGone: lastError.map(isGone) ?? false))
    }

    /// Whether an error means the destination went away (the share unmounted, the network down).
    static func isGone(_ error: any Error) -> Bool {
        let nsError = error as NSError
        let posix = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
            ?? (nsError.domain == NSPOSIXErrorDomain ? nsError.code : nil)
        guard let posix else { return false }
        return [Int(ENXIO), Int(ENETDOWN), Int(ENETUNREACH), Int(EHOSTDOWN), Int(EHOSTUNREACH), Int(ETIMEDOUT), Int(ENOTCONN), Int(EIO)].contains(posix)
    }

    static let chunkSize = 4 << 20

    static func copyHashing(from source: URL, to target: URL) throws -> String {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        guard fileManager.createFile(atPath: target.path, contents: nil) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path]) }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: target)
        var hasher = SHA256()
        do {
            while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
            try output.close()
        } catch {
            try? output.close()
            throw error
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func hashSync(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func hash(_ url: URL) async throws -> String {
        try await Task.detached(priority: .utility) { try hashSync(url) }.value
    }

    // MARK: - Cleaning up

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func removeEmptyFolders(from folder: URL, upTo top: URL) {
        let fileManager = FileManager.default
        var current = folder.standardizedFileURL
        let stop = top.standardizedFileURL.path
        while current.path.hasPrefix(stop + "/") {
            let contents = (try? fileManager.contentsOfDirectory(atPath: current.path)) ?? ["?"]
            // Finder's and the NAS's own litter does not keep a folder.
            guard contents.allSatisfy({ $0 == ".DS_Store" || $0.hasPrefix("._") }) else { return }
            guard (try? fileManager.removeItem(at: current)) != nil else { return }
            current = current.deletingLastPathComponent()
        }
    }

    /// Removes days in `.Removed` older than `days`. Returns how many files went.
    static func purgeRemoved(in music: URL, olderThan days: Int, now: Date) -> Int {
        let fileManager = FileManager.default
        let removed = music.appendingPathComponent(removedFolderName)
        var purged = 0
        for folder in (try? fileManager.contentsOfDirectory(at: removed, includingPropertiesForKeys: nil)) ?? [] {
            guard let date = dayFormatter.date(from: folder.lastPathComponent),
                  now.timeIntervalSince(date) > Double(days) * 24 * 3600 else { continue }
            let files = (fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL]) ?? []
            purged += files.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.count
            try? fileManager.removeItem(at: folder)
        }
        return purged
    }

    // MARK: - Restoring

    /// A file set aside in `.Removed`, to put back.
    public struct RemovedFile: Sendable, Hashable, Identifiable {
        public var id: String { url.path }
        /// The day it was set aside.
        public var day: String
        /// "<folder name>/<relative path>".
        public var key: String
        public var url: URL
        public var size: Int64
    }

    /// Files in `.Removed`, newest day first.
    public static func removedFiles(in destination: URL) -> [RemovedFile] {
        let removed = destination.appendingPathComponent(folderName).appendingPathComponent(removedFolderName)
        let fileManager = FileManager.default
        var files: [RemovedFile] = []
        for day in ((try? fileManager.contentsOfDirectory(at: removed, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard dayFormatter.date(from: day.lastPathComponent) != nil else { continue }
            let base = day.standardizedFileURL.path
            let enumerator = fileManager.enumerator(at: day, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])
            while let url = enumerator?.nextObject() as? URL {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(base + "/") else { continue }
                files.append(RemovedFile(day: day.lastPathComponent, key: String(path.dropFirst(base.count + 1)), url: url, size: Int64(values.fileSize ?? 0)))
            }
        }
        return files
    }

    /// Copies files from the mirror (or `.Removed`) back to the library: `files` maps a mirror file to where it goes.
    /// Existing files are left alone. Returns how many were copied, and the errors.
    public static func copyBack(_ files: [(from: URL, to: URL)], progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> (copied: Int, errors: [String]) {
        await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            var copied = 0
            var errors: [String] = []
            for (index, file) in files.enumerated() {
                if Task.isCancelled { break }
                progress(index, files.count)
                guard !fileManager.fileExists(atPath: file.to.path) else { continue }
                do {
                    try fileManager.createDirectory(at: file.to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let partial = file.to.deletingLastPathComponent().appendingPathComponent(".\(file.to.lastPathComponent)\(partialSuffix)")
                    _ = try copyHashing(from: file.from, to: partial)
                    if let date = try? file.from.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                        try? fileManager.setAttributes([.modificationDate: date], ofItemAtPath: partial.path)
                    }
                    try fileManager.moveItem(at: partial, to: file.to)
                    copied += 1
                } catch {
                    errors.append("\(file.from.lastPathComponent): \(error.localizedDescription)")
                }
            }
            progress(files.count, files.count)
            return (copied, errors)
        }.value
    }

    /// Every file of a mirrored library folder (from the manifest), mapped onto `folder`: what Copy Back copies.
    public static func files(of name: String, in destination: URL, manifest: Manifest, onto folder: URL) -> [(from: URL, to: URL)] {
        let music = destination.appendingPathComponent(folderName)
        let prefix = name + "/"
        return manifest.files.keys.filter { $0.hasPrefix(prefix) }.sorted().map { key in
            (music.appendingPathComponent(key), folder.appendingPathComponent(String(key.dropFirst(prefix.count))))
        }
    }
}
