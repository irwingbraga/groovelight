import Foundation

/// When an automatic backup is due. At night, a daily backup runs once in the window (02:00 to 06:00 by default), a
/// little earlier each day being fine so it does not drift out of it; a window missed because the computer was off or
/// asleep is made up for once the backup is half a day late. Any time: once the interval has passed.
public struct BackupSchedule: Sendable, Equatable {
    public enum Window: String, Sendable, CaseIterable, Identifiable {
        case night, anyTime
        public var id: Self { self }
    }

    public var interval: TimeInterval
    public var window: Window
    public var nightStart: Int
    public var nightEnd: Int

    /// How early a backup in the night window may run (so a daily one stays in the window).
    public static let earlyBy: TimeInterval = 6 * 3600
    /// How late a backup waits for the window before running anyway.
    public static let catchUpAfter: TimeInterval = 12 * 3600

    public init(interval: TimeInterval, window: Window, nightStart: Int = 2, nightEnd: Int = 6) {
        self.interval = interval
        self.window = window
        self.nightStart = nightStart
        self.nightEnd = nightEnd
    }

    public func isDue(lastBackup: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let lastBackup else { return true }
        let since = now.timeIntervalSince(lastBackup)
        switch window {
        case .anyTime:
            return since >= interval
        case .night:
            return (isInWindow(now, calendar: calendar) && since >= interval - Self.earlyBy) || since >= interval + Self.catchUpAfter
        }
    }

    /// When the next backup after `lastBackup` runs, if the computer is on then.
    public func nextRun(after lastBackup: Date, calendar: Calendar = .current) -> Date {
        switch window {
        case .anyTime:
            return lastBackup.addingTimeInterval(interval)
        case .night:
            let earliest = lastBackup.addingTimeInterval(interval - Self.earlyBy)
            if isInWindow(earliest, calendar: calendar) { return earliest }
            guard var start = calendar.date(bySettingHour: nightStart, minute: 0, second: 0, of: earliest) else { return earliest }
            if start < earliest, let next = calendar.date(byAdding: .day, value: 1, to: start) { start = next }
            return start
        }
    }

    public func isInWindow(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return nightStart <= nightEnd ? (nightStart..<nightEnd).contains(hour) : (hour >= nightStart || hour < nightEnd)
    }
}

/// A folder chosen for automatic backups (a NAS share, another disk, iCloud Drive). Data backups go in its `Data`
/// folder; the music mirror will go beside it in `Music`. Backups are written under a hidden temporary name and renamed
/// when whole, so a backup cut short (the share gone, the computer asleep) never counts as one.
public struct BackupDestination: Sendable {
    public static let dataFolderName = "Data"
    static let prefix = "Groovelight Backup "
    static let partialSuffix = ".partial"

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var dataFolder: URL { url.appendingPathComponent(Self.dataFolderName, isDirectory: true) }
    /// The covers shared by the backups in `Data` (each backup lists the ones it uses).
    public var sharedArtwork: URL { LibraryBackup.sharedArtwork(in: dataFolder) }

    /// Creates the `Data` folder, moves backups made before it existed (at the top of the folder) into it, and removes
    /// backups left half-written.
    public func prepare() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        for old in Self.backups(in: url) {
            let target = dataFolder.appendingPathComponent(old.lastPathComponent)
            if !fileManager.fileExists(atPath: target.path) { try? fileManager.moveItem(at: old, to: target) }
        }
        for item in (try? fileManager.contentsOfDirectory(at: dataFolder, includingPropertiesForKeys: nil)) ?? []
        where item.lastPathComponent.hasPrefix(".") && item.lastPathComponent.hasSuffix(Self.partialSuffix) {
            try? fileManager.removeItem(at: item)
        }
    }

    /// Writes a backup with `write` (given where to write it) into the `Data` folder, then keeps the newest `keep`.
    /// Returns where it is.
    @discardableResult
    public func backUp(date: Date = .now, keep: Int, write: (URL) throws -> Void) throws -> URL {
        try prepare()
        let name = Self.fileName(for: date)
        let partial = dataFolder.appendingPathComponent(".\(name)\(Self.partialSuffix)")
        let final = dataFolder.appendingPathComponent(name)
        let fileManager = FileManager.default
        do {
            try write(partial)
            if fileManager.fileExists(atPath: final.path) { try fileManager.removeItem(at: final) }
            try fileManager.moveItem(at: partial, to: final)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
        Self.prune(dataFolder, keeping: keep)
        let artwork = sharedArtwork
        if FileManager.default.fileExists(atPath: artwork.path) {
            LibraryBackup.pruneSharedArtwork(artwork, keepingFor: Self.backups(in: dataFolder))
        }
        return final
    }

    /// The space left where the backups go (nil when the volume does not say).
    public var availableCapacity: Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).flatMap { $0 }.map(Int64.init)
    }

    /// Whether the folder is there and can be written to (a share that is not mounted, or read only, is not).
    public var isWritable: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: url.path)
    }

    /// The newest backup in the `Data` folder, or at the top of the folder for one not prepared yet.
    public var newestBackup: URL? {
        (Self.backups(in: dataFolder) + Self.backups(in: url)).max { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// "Groovelight Backup 2026-11-11 03.00.groovelightbackup" (names sort by date).
    public static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "\(prefix)\(formatter.string(from: date)).\(LibraryBackup.fileExtension)"
    }

    /// Backups in `folder`, oldest first.
    public static func backups(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == LibraryBackup.fileExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Removes all but the newest `keep` backups in `folder`.
    public static func prune(_ folder: URL, keeping keep: Int) {
        for old in backups(in: folder).dropLast(max(1, keep)) { try? FileManager.default.removeItem(at: old) }
    }
}
