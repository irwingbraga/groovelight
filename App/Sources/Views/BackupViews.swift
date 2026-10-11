import LibraryKit
import SwiftUI

/// After restoring on another Mac: the music folders have to be located again (a sandboxed app cannot carry folder
/// access between computers). Songs keep their history once their folder is found.
struct LocateFoldersSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

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
        .frame(width: 560)
    }
}

/// Settings tab: back up now, restore, automatic backups.
struct BackupSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(BackupManager.Keys.automatic) private var automatic = true
    @AppStorage(BackupManager.Keys.frequency) private var frequency = BackupManager.Frequency.weekly.rawValue
    @AppStorage(BackupManager.Keys.keep) private var keep = 5
    @AppStorage(BackupManager.Keys.folder) private var folderBookmark: Data?

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
                Text("Playlists and their covers, smart playlist rules, play counts, ratings, loved songs, metadata fixes, lyrics, artwork, credits, album and artist info, equalizer presets and settings. Your music files are not included.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Back up automatically", isOn: $automatic)
                Picker("Every", selection: $frequency) {
                    Text("Day").tag(BackupManager.Frequency.daily.rawValue)
                    Text("Week").tag(BackupManager.Frequency.weekly.rawValue)
                }
                .disabled(!automatic)
                Stepper("Keep the last \(keep) backups", value: $keep, in: 1...30)
                    .disabled(!automatic)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Folder")
                        Text(folderBookmark == nil ? "Inside Groovelight's data (choose another disk or iCloud Drive to survive losing this Mac)"
                                                   : (backup.automaticFolder?.path ?? "Folder unavailable"))
                            .font(.caption)
                            .foregroundStyle(folderBookmark == nil ? .orange : .secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Choose…") { backup.chooseAutomaticFolder() }
                }
                .disabled(!automatic)
            } header: {
                Text("Automatic Backups")
            }
        }
        .formStyle(.grouped)
    }
}
