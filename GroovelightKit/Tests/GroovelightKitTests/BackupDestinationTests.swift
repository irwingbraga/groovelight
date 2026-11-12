import Foundation
import Testing
@testable import LibraryKit

/// Automatic backups: when they are due (at night or any time), and the backup folder (a NAS share): the `Data`
/// folder, backups cut short, keeping the newest.
struct BackupDestinationTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private let day: TimeInterval = 24 * 3600

    @Test func nightlyBackupsRunInTheWindowEachNight() {
        let schedule = BackupSchedule(interval: day, window: .night)
        // Last night at 03:10: not again during the day, then in tonight's window, even a little earlier than 03:10.
        let last = date(10, 3, 10)
        #expect(!schedule.isDue(lastBackup: last, now: date(10, 14), calendar: calendar))
        #expect(!schedule.isDue(lastBackup: last, now: date(10, 23, 30), calendar: calendar))
        #expect(schedule.isDue(lastBackup: last, now: date(11, 2, 5), calendar: calendar))
        // Not twice in the same window.
        #expect(!schedule.isDue(lastBackup: date(11, 2, 5), now: date(11, 4), calendar: calendar))
    }

    @Test func aMissedWindowIsMadeUpForHalfADayLate() {
        let schedule = BackupSchedule(interval: day, window: .night)
        // The computer was off all night: the backup waits for the window, then runs anyway once 12 hours late.
        let last = date(10, 3)
        #expect(!schedule.isDue(lastBackup: last, now: date(11, 9), calendar: calendar))
        #expect(schedule.isDue(lastBackup: last, now: date(11, 15, 1), calendar: calendar))
    }

    @Test func weeklyAndAnyTimeSchedules() {
        let weekly = BackupSchedule(interval: 7 * day, window: .night)
        #expect(!weekly.isDue(lastBackup: date(10, 3), now: date(11, 3), calendar: calendar))
        #expect(weekly.isDue(lastBackup: date(3, 3), now: date(10, 2, 30), calendar: calendar))
        let anyTime = BackupSchedule(interval: day, window: .anyTime)
        #expect(!anyTime.isDue(lastBackup: date(10, 12), now: date(11, 11), calendar: calendar))
        #expect(anyTime.isDue(lastBackup: date(10, 12), now: date(11, 12), calendar: calendar))
        // Never backed up: now.
        #expect(weekly.isDue(lastBackup: nil, now: date(10, 12), calendar: calendar))
    }

    @Test func theNextRun() {
        let nightly = BackupSchedule(interval: day, window: .night)
        #expect(nightly.nextRun(after: date(10, 3, 10), calendar: calendar) == date(11, 2))
        // Made late in the day (a missed night): the next one is still the night after.
        #expect(nightly.nextRun(after: date(10, 15), calendar: calendar) == date(12, 2))
        #expect(BackupSchedule(interval: day, window: .anyTime).nextRun(after: date(10, 15), calendar: calendar) == date(11, 15))
    }

    @Test func windowsAcrossMidnight() {
        let schedule = BackupSchedule(interval: day, window: .night, nightStart: 23, nightEnd: 5)
        #expect(schedule.isInWindow(date(10, 23, 30), calendar: calendar))
        #expect(schedule.isInWindow(date(11, 4), calendar: calendar))
        #expect(!schedule.isInWindow(date(11, 5), calendar: calendar))
        #expect(!schedule.isInWindow(date(11, 12), calendar: calendar))
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("backup-destination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writePackage(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: url.appendingPathComponent("Library.sqlite"))
    }

    @Test func backupsGoInTheDataFolderAndOlderOnesMoveThere() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A backup made before the Data folder existed, at the top of the chosen folder, and other files of the user's.
        let old = folder.appendingPathComponent(BackupDestination.fileName(for: date(1, 3)))
        try writePackage(old)
        try Data("mine".utf8).write(to: folder.appendingPathComponent("notes.txt"))

        let destination = BackupDestination(url: folder)
        let made = try destination.backUp(date: date(2, 3), keep: 5) { try writePackage($0) }
        #expect(made.deletingLastPathComponent().lastPathComponent == "Data")
        #expect(BackupDestination.backups(in: destination.dataFolder).map(\.lastPathComponent)
                == [BackupDestination.fileName(for: date(1, 3)), BackupDestination.fileName(for: date(2, 3))])
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes.txt").path))
        #expect(destination.newestBackup?.lastPathComponent == BackupDestination.fileName(for: date(2, 3)))
    }

    @Test func aBackupCutShortLeavesNothing() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = BackupDestination(url: folder)
        struct Gone: Error {}
        #expect(throws: Gone.self) {
            try destination.backUp(date: date(2, 3), keep: 5) { url in
                try writePackage(url)
                throw Gone()
            }
        }
        #expect(BackupDestination.backups(in: destination.dataFolder).isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: destination.dataFolder.path)) ?? []).isEmpty)

        // One left by a crash (the app ended mid-copy) is removed next time.
        let leftover = destination.dataFolder.appendingPathComponent(".\(BackupDestination.fileName(for: date(3, 3))).partial")
        try writePackage(leftover)
        try destination.prepare()
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    @Test func keepsTheNewest() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = BackupDestination(url: folder)
        for night in 1...4 { try destination.backUp(date: date(night, 3), keep: 2) { try writePackage($0) } }
        #expect(BackupDestination.backups(in: destination.dataFolder).map(\.lastPathComponent)
                == [BackupDestination.fileName(for: date(3, 3)), BackupDestination.fileName(for: date(4, 3))])
        #expect(destination.isWritable)
        #expect(destination.availableCapacity ?? 0 > 0)
    }
}
