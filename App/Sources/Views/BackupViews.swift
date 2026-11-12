import LibraryKit
import SwiftUI

/// After restoring on another Mac: the music folders have to be located again (a sandboxed app cannot carry folder
/// access between computers). Songs keep their history once their folder is found.
struct LocateFoldersSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Folders with a copy on the NAS (the music backup), by their old path.
    @State private var mirrored: [String: BackupManager.MirroredFolder] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Locate Your Music Folders", systemImage: "folder.badge.questionmark")
                .font(.headline)
            Text("The backup was restored. Groovelight needs permission to open these folders on this Mac: point it at each one (it can have a different name or location). Play counts, playlists and fixes reconnect to the songs.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(model.backup.foldersToLocate, id: \.id) { root in
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(URL(fileURLWithPath: root.path).lastPathComponent).font(.system(size: 13, weight: .medium))
                            Text(root.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if let copy = mirrored[root.path] {
                            Button("Use NAS Copy") { Task { await model.backup.useMirror(copy) } }
                                .help("Play this folder from its copy in the music backup (\(copy.files.formatted()) files)")
                        }
                        Button("Locate…") { model.backup.locate(root) }
                    }
                    .padding(.vertical, 8)
                    Divider()
                }
            }
            HStack {
                Text("Folders left out keep their songs' history until they are located (Settings, Library).")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Later") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        .task {
            guard model.backup.hasChosenFolder else { return }
            mirrored = Dictionary(await model.backup.mirroredFolders().map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }
}

/// Settings tab: back up now, restore, automatic backups (where, how often, when, and how the last one went), the NAS
/// login, and the music backup.
struct BackupSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(BackupManager.Keys.automatic) private var automatic = true
    @AppStorage(BackupManager.Keys.frequency) private var frequency = BackupManager.Frequency.weekly.rawValue
    @AppStorage(BackupManager.Keys.keep) private var keep = 5
    @AppStorage(BackupManager.Keys.window) private var window = BackupSchedule.Window.night.rawValue
    @AppStorage(BackupManager.Keys.onlyOnPower) private var onlyOnPower = false
    @AppStorage(BackupManager.Keys.mirror) private var mirrorMusic = false
    @AppStorage(BackupManager.Keys.keepRemovedDays) private var keepRemovedDays = 30
    @State private var isShowingRestore = false

    var body: some View {
        let backup = model.backup!
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Library Backup")
                        Text(backup.lastBackup.map { "Last backup \($0.formatted(.relative(presentation: .named)))" } ?? "Never backed up")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if backup.isWorking { ProgressView().controlSize(.small) }
                    Button("Back Up…") { backup.chooseAndBackUp() }
                    Button("Restore…") { backup.chooseAndRestore() }
                }
                .disabled(backup.isWorking)
            } footer: {
                Text("Playlists and their covers, smart playlist rules, play counts, ratings, loved songs, metadata fixes, lyrics, artwork, credits, album and artist info, equalizer presets and settings. Your music files are not included (see Music below).")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Back up automatically", isOn: $automatic)
                Group {
                    Picker("Every", selection: $frequency) {
                        Text("Day").tag(BackupManager.Frequency.daily.rawValue)
                        Text("Week").tag(BackupManager.Frequency.weekly.rawValue)
                    }
                    Picker("When", selection: $window) {
                        Text("At night, \(Self.hour(2)) to \(Self.hour(6))").tag(BackupSchedule.Window.night.rawValue)
                        Text("Any time").tag(BackupSchedule.Window.anyTime.rawValue)
                    }
                    Toggle("Only when this Mac is plugged in", isOn: $onlyOnPower)
                    whenClosedRow(backup)
                    Stepper("Keep the last \(keep) backups", value: $keep, in: 1...30)
                    folderRow(backup)
                    if backup.hasChosenFolder, backup.server != nil || !backup.loginUser.isEmpty {
                        NASLoginRow()
                    }
                    statusRow(backup)
                }
                .disabled(!automatic)
            } header: {
                Text("Automatic Backups")
            } footer: {
                Text(window == BackupSchedule.Window.night.rawValue
                     ? "A night missed (this Mac off or asleep) is made up for later in the day. On a NAS, choose a folder on its shared folder: Groovelight connects to it when needed (with its own login, or the password saved in the Keychain), and the NAS's drives sleep the rest of the day."
                     : "On a NAS, choose a folder on its shared folder: Groovelight connects to it when needed, with its own login or the password saved in the Keychain.")
                    .foregroundStyle(.secondary)
            }

            if backup.hasChosenFolder {
                musicSection(backup)
            }
        }
        .formStyle(.grouped)
        .task {
            backup.refreshWhenClosed()
            await backup.checkDestination()
        }
        .sheet(isPresented: $isShowingRestore) { MusicRestoreSheet() }
    }

    // MARK: - Automatic backups

    private func whenClosedRow(_ backup: BackupManager) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Also when Groovelight is closed", isOn: Binding(get: { backup.runsWhenClosed }, set: { backup.setRunsWhenClosed($0) }))
            if backup.whenClosedNeedsApproval {
                HStack(spacing: 6) {
                    Text("Allow Groovelight in System Settings, General, Login Items.")
                        .foregroundStyle(.orange)
                    Button("Open") { backup.openLoginItems() }
                        .controlSize(.small)
                }
                .font(.caption)
            } else if backup.runsWhenClosed {
                Text("Groovelight opens hidden at night for a backup that is due, then quits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func folderRow(_ backup: BackupManager) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Folder")
                Group {
                    switch backup.destinationStatus {
                    case .notChosen:
                        Text("Inside Groovelight's data (choose a NAS, another disk or iCloud Drive to survive losing this Mac)")
                            .foregroundStyle(.orange)
                    case .checking:
                        Text("Connecting…").foregroundStyle(.secondary)
                    case .ready(let path, let available):
                        Text(available.map { "\(path), \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)) free" } ?? path)
                            .foregroundStyle(.secondary)
                    case .unavailable(let reason):
                        Text(reason).foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
            }
            Spacer()
            if case .ready = backup.destinationStatus {
                Button("Show") { backup.showDestination() }
            } else if case .unavailable = backup.destinationStatus {
                Button("Try Again") { Task { await backup.checkDestination() } }
            }
            Button("Choose…") { backup.chooseAutomaticFolder() }
            if backup.hasChosenFolder {
                Button("Use Groovelight's Data") { backup.forgetAutomaticFolder() }
                    .help("Back up inside Groovelight's own data instead (does not survive losing this Mac)")
            }
        }
    }

    private func statusRow(_ backup: BackupManager) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Next backup")
                if let progress = backup.dataProgress {
                    Text(progress.total == 0 ? "Backing up the data…" : "Copying the data to the backup folder, \(progress.done.formatted()) of \(progress.total.formatted()) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if progress.total > 0 {
                        ProgressView(value: Double(progress.done), total: Double(progress.total)).frame(maxWidth: 260)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Text(nextBackup(backup))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = backup.lastError {
                    Text("Last try \(backup.lastAttempt?.formatted(.relative(presentation: .named)) ?? "") failed: \(error)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("Back Up Now") { Task { await backup.backUpAutomatically() } }
                .disabled(backup.isWorking)
        }
    }

    private func nextBackup(_ backup: BackupManager) -> String {
        guard let next = backup.nextBackup else { return backup.lastBackup == nil ? "Soon (none made yet)" : "Off" }
        guard next > .now else { return "Soon" }
        let time = next.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(next) { return "Today at \(time)" }
        if calendar.isDateInTomorrow(next) { return "Tomorrow at \(time)" }
        return "\(next.formatted(.dateTime.weekday(.wide))) at \(time)"
    }

    /// "2 AM" or "02:00", as this Mac shows hours.
    private static func hour(_ hour: Int) -> String {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)?.formatted(date: .omitted, time: .shortened) ?? "\(hour):00"
    }

    // MARK: - Music

    private func musicSection(_ backup: BackupManager) -> some View {
        Section {
            Toggle("Back up the music library", isOn: $mirrorMusic)
            if mirrorMusic {
                MirroredFoldersRow()
                Picker("Keep removed songs", selection: $keepRemovedDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("Forever").tag(0)
                }
                .help("Songs gone from the library are set aside in the backup's Music/.Removed folder, then deleted after this long")
                mirrorStatusRow(backup)
            }
        } header: {
            Text("Music")
        } footer: {
            Text("Copies your library folders to the backup folder's Music folder, as they are, with each backup: only new and changed files, and renamed files are moved, not copied again. Songs you remove are set aside, never deleted at once, and a folder that is offline or lost many files is left alone. On a NAS, turn on its snapshots of the shared folder to keep older versions too.")
                .foregroundStyle(.secondary)
        }
    }

    private func mirrorStatusRow(_ backup: BackupManager) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    if let activity = backup.mirrorActivity {
                        Text(activity)
                        if let fraction = backup.mirrorFraction {
                            ProgressView(value: fraction).frame(maxWidth: 260)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    } else if let report = backup.mirrorReport {
                        Text("Last music backup \(report.date.formatted(.relative(presentation: .named)))")
                        Text(Self.describe(report))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(report.skipped.sorted(by: { $0.key < $1.key }), id: \.key) { folder, why in
                            Text("Skipped \(URL(fileURLWithPath: folder).lastPathComponent): \(why)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if !report.errors.isEmpty {
                            Text("\(report.errors.count) file\(report.errors.count == 1 ? "" : "s") not copied: \(report.errors[0])")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .lineLimit(2)
                                .help(report.errors.joined(separator: "\n"))
                        }
                    } else {
                        Text("Not backed up yet")
                        Text("The first copy can take hours (1 TB is about 3 hours on a wired network) and goes on over several nights if it has to.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if backup.mirrorActivity != nil {
                    Button("Stop") { backup.stopMirror() }
                } else {
                    Button("Restore…") { isShowingRestore = true }
                        .disabled(backup.isWorking || backup.mirrorReport == nil)
                }
            }
            if let drops = backup.mirrorReport?.needsConfirmation, !drops.isEmpty, backup.mirrorActivity == nil {
                HStack {
                    Text(drops.map { "\(URL(fileURLWithPath: $0.folder).lastPathComponent) has \($0.now.formatted()) files, \($0.before.formatted()) last time. Was that on purpose?" }
                        .joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Back Up Anyway") { backup.confirmMirror() }
                        .help("Removed files are set aside in the backup, not deleted")
                }
            }
        }
    }

    private static func describe(_ report: LibraryMirror.Report) -> String {
        var parts = ["\(report.totalFiles.formatted()) files, \(ByteCountFormatter.string(fromByteCount: report.totalBytes, countStyle: .file))"]
        if report.copied > 0 { parts.append("\(report.copied.formatted()) copied") }
        if report.moved > 0 { parts.append("\(report.moved.formatted()) moved") }
        if report.removed > 0 { parts.append("\(report.removed.formatted()) set aside") }
        if report.repaired > 0 { parts.append("\(report.repaired.formatted()) damaged copies replaced") }
        if !report.hasChanges { parts.append("nothing new") }
        return parts.joined(separator: ", ")
    }
}

/// Groovelight's own login to the NAS's shared folder (the password in the Keychain).
private struct NASLoginRow: View {
    @Environment(AppModel.self) private var model
    @State private var server = ""
    @State private var user = ""
    @State private var password = ""
    @State private var hasPassword = false

    var body: some View {
        let backup = model.backup!
        VStack(alignment: .leading, spacing: 6) {
            Text("Connect to the NAS as")
            HStack {
                TextField("Shared folder", text: $server, prompt: Text("nas.local/Backups"))
                    .frame(minWidth: 160)
                TextField("User", text: $user, prompt: Text("User"))
                    .frame(width: 110)
                SecureField("Password", text: $password, prompt: Text(hasPassword ? "Saved" : "Password"))
                    .frame(width: 110)
                Button(hasPassword && password.isEmpty ? "Connect" : "Save") {
                    Task {
                        await backup.saveLogin(server: server, user: user, password: password)
                        password = ""
                        load(backup)
                    }
                }
                .disabled(server.isEmpty || user.isEmpty || (password.isEmpty && !hasPassword))
                if hasPassword {
                    Button("Forget") {
                        backup.forgetLogin()
                        user = ""
                        load(backup)
                    }
                }
            }
            .labelsHidden()
            Text(hasPassword
                 ? "Groovelight connects with this login when the shared folder is not connected, with no dialog. The password is in your Keychain."
                 : "Optional: a NAS user for backups only (with access to this shared folder only). Without one, Groovelight uses the password the Finder saved in the Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { load(backup) }
    }

    private func load(_ backup: BackupManager) {
        server = backup.server.map { ($0.host() ?? "") + $0.path(percentEncoded: false) } ?? server
        user = backup.loginUser
        hasPassword = backup.hasLogin
    }
}

/// The library folders in the music backup, each one on or off.
private struct MirroredFoldersRow: View {
    @Environment(AppModel.self) private var model
    @State private var folders: [LibraryRoot] = []
    @State private var revision = 0

    var body: some View {
        let backup = model.backup!
        VStack(alignment: .leading, spacing: 4) {
            Text("Library folders")
            ForEach(folders, id: \.path) { root in
                Toggle(isOn: Binding(get: { _ = revision; return backup.isMirrored(root.path) },
                                     set: { backup.setMirrored(root.path, $0); revision += 1 })) {
                    Text(root.path).lineLimit(1).truncationMode(.middle)
                }
                .toggleStyle(.checkbox)
                .font(.caption)
            }
            if folders.isEmpty {
                Text("Add a library folder first (Settings, Library).").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { folders = await backup.libraryFolders() }
    }
}

/// Getting music back from the backup: a whole library folder (played from the NAS, or copied to a new drive), or
/// songs removed from the library.
struct MusicRestoreSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [BackupManager.MirroredFolder] = []
    @State private var removed: [LibraryMirror.RemovedFile] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var message: String?

    /// Removed files by day and album folder.
    private var groups: [(id: String, day: String, folder: String, files: [LibraryMirror.RemovedFile])] {
        Dictionary(grouping: removed) { "\($0.day)|\(($0.key as NSString).deletingLastPathComponent)" }
            .map { key, files in
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                return (key, parts[0], parts.count > 1 ? parts[1] : "", files.sorted { $0.key < $1.key })
            }
            .sorted { $0.day == $1.day ? $0.folder < $1.folder : $0.day > $1.day }
    }

    var body: some View {
        let backup = model.backup!
        VStack(alignment: .leading, spacing: 14) {
            Label("Restore Music from the Backup", systemImage: "arrow.counterclockwise.circle")
                .font(.headline)
            if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Text("Library folders").font(.subheadline.weight(.semibold))
                if folders.isEmpty {
                    Text("Nothing in the music backup yet.").foregroundStyle(.secondary)
                }
                ForEach(folders) { folder in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(folder.name).font(.system(size: 13, weight: .medium))
                            Text("\(folder.files.formatted()) files, \(ByteCountFormatter.string(fromByteCount: folder.bytes, countStyle: .file)), from \(folder.path)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Play from NAS") { Task { await backup.useMirror(folder); dismiss() } }
                            .help("Point this library folder's songs at the copy on the NAS (its drive lost or away). Choose its folder again in Settings, Library when the drive is back.")
                        Button("Copy Back…") { Task { await backup.copyBack(folder) } }
                            .help("Copy the whole folder to a new drive and point the library at it")
                    }
                }
                Divider()
                Text("Removed songs").font(.subheadline.weight(.semibold))
                if groups.isEmpty {
                    Text("None set aside.").foregroundStyle(.secondary)
                } else {
                    List(groups, id: \.id) { group in
                        Toggle(isOn: Binding(get: { selected.contains(group.id) },
                                             set: { on in if on { selected.insert(group.id) } else { selected.remove(group.id) } })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(group.folder).lineLimit(1).truncationMode(.middle)
                                Text("\(group.files.count) file\(group.files.count == 1 ? "" : "s"), removed \(group.day)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    .frame(minHeight: 160, maxHeight: 260)
                }
            }
            if let activity = backup.mirrorActivity {
                HStack {
                    Text(activity).font(.caption)
                    if let fraction = backup.mirrorFraction { ProgressView(value: fraction) }
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Put Back") {
                    let files = groups.filter { selected.contains($0.id) }.flatMap(\.files)
                    Task {
                        message = await backup.putBack(files)
                        selected = []
                    }
                }
                .disabled(selected.isEmpty || backup.isWorking)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .task {
            folders = await backup.mirroredFolders()
            removed = await backup.removedFiles()
            isLoading = false
        }
    }
}
