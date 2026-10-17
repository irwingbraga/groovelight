import LibraryKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Library", systemImage: "folder") { LibrarySettings() }
            Tab("Playback", systemImage: "play.circle") { PlaybackSettings() }
            Tab("Metadata", systemImage: "wand.and.sparkles") { MetadataSettings() }
            Tab("Files", systemImage: "doc.text") { FilesSettings() }
            Tab("Backup", systemImage: "externaldrive.badge.timemachine") { BackupSettings() }
            Tab("Last.fm", systemImage: "dot.radiowaves.left.and.right") { LastFMSettings() }
            Tab("Devices", systemImage: "smartphone") { DevicesSettings() }
            Tab("Shortcuts", systemImage: "keyboard") { ShortcutsSettings() }
        }
        .frame(width: 720, height: 480)
    }
}

struct GeneralSettings: View {
    @AppStorage(AppTheme.key) private var theme = AppTheme.system
    @State private var checksForUpdates = Updates.shared.automaticallyChecks

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $theme) {
                    ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("System follows the macOS setting. The Shelf is always dark.")
                    .foregroundStyle(.secondary)
            }
            if Updates.shared.isAvailable {
                Section {
                    Toggle("Check for updates automatically", isOn: $checksForUpdates)
                        .onChange(of: checksForUpdates) { Updates.shared.automaticallyChecks = checksForUpdates }
                    Button("Check Now") { Updates.shared.checkForUpdates() }
                } header: {
                    Text("Updates")
                } footer: {
                    Text("New versions come from Groovelight's releases on GitHub and are verified before they are installed.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: theme) { _, theme in theme.apply() }
    }
}

struct LibrarySettings: View {
    @Environment(AppModel.self) private var model
    @State private var roots: [LibraryRoot] = []
    @State private var songCounts: [Int64: Int] = [:]
    /// The folder waiting for the remove confirmation.
    @State private var removing: LibraryRoot?

    var body: some View {
        Form {
            Section {
                // Each row has its own remove button: a List's selection does not work inside a grouped Form.
                ForEach(roots) { root in
                    HStack(alignment: .top, spacing: 10) {
                        FolderRow(root: root, songs: root.id.flatMap { songCounts[$0] } ?? 0)
                        Spacer(minLength: 8)
                        Button {
                            removing = root
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove from the library")
                    }
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root.path)]) }
                        Divider()
                        Button("Remove from Library…", role: .destructive) { removing = root }
                    }
                }
                if roots.isEmpty {
                    Text("No music folders yet.").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Add Folder…") { model.chooseLibraryFolder() }
                    Spacer()
                    Button("Rescan Now") { model.rescanAll() }
                        .disabled(model.scanProgress != nil)
                }
            } header: {
                Text("Music Folders")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Changes are picked up as they happen, including those made while Groovelight was closed, and drives are checked when they are plugged in. Every file is also checked once a day and after waking from sleep.")
                    if let summary = model.lastScanSummary {
                        Text("Last full check: \(summary.added) added, \(summary.updated) updated, \(summary.removed) removed, \(summary.failed.count) unreadable.")
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(removing.map { "Remove “\(URL(fileURLWithPath: $0.path).lastPathComponent)” from the library?" } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { root in
            Button("Remove", role: .destructive) { model.removeRoot(root) }
        } message: { root in
            let songs = root.id.flatMap { songCounts[$0] } ?? 0
            Text("\(songs == 1 ? "Its song leaves" : "Its \(songs) songs leave") Groovelight, with their play counts and loves, and leave your playlists. The files stay where they are.")
        }
        .observing(model.database, id: 0, { try LibraryDatabase.roots($0) }) { roots = $0 }
        .observing(model.database, id: "counts", { try LibraryDatabase.trackCountsByRoot($0) }) { songCounts = $0 }
    }
}

/// A library folder: its name, path, song count, and how it is kept up to date.
private struct FolderRow: View {
    var root: LibraryRoot
    var songs: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(URL(fileURLWithPath: root.path).lastPathComponent, systemImage: "folder.fill")
            Text("\(root.path) · \(songs == 1 ? "1 song" : "\(songs) songs")")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.unavailableFolders.contains(root.path) {
                HStack(spacing: 8) {
                    Label("Not available: unplugged or moved. Its songs keep their history.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Button("Locate…") { model.backup.locate(root) }
                        .controlSize(.small)
                }
            } else {
                FolderSyncStatus(root: root, isNetwork: model.sync.networkFolders.contains(root.path))
            }
        }
    }
}

/// How a library folder is kept up to date, and when it was last checked.
private struct FolderSyncStatus: View {
    var root: LibraryRoot
    var isNetwork: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if isNetwork {
                Label("Network folder: checked every \(Int(LibrarySync.networkInterval / 60)) minutes", systemImage: "network")
            } else {
                Label("Watching for changes", systemImage: "eye")
            }
            if let date = root.lastScanAt {
                let full = root.lastFullScanAt.map { " · every file checked \($0.formatted(.relative(presentation: .named)))" } ?? ""
                Text("Last updated \(date.formatted(.relative(presentation: .named)))" + full)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

struct MetadataSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(MetadataStore.Keys.fetchLyrics) private var fetchLyrics = true
    @AppStorage(MetadataStore.Keys.writeTags) private var writeTags = false
    @AppStorage(MetadataStore.Keys.contact) private var contact = ""
    @AppStorage(MetadataStore.Keys.fetchAlbumInfo) private var fetchAlbumInfo = true

    var body: some View {
        Form {
            Section {
                Toggle("Find lyrics online for songs without lyrics", isOn: $fetchLyrics)
                Toggle("Show album credits and album and artist backgrounds (MusicBrainz, Wikipedia)", isOn: $fetchAlbumInfo)
                Toggle("Write fixes into the files", isOn: $writeTags)
            } footer: {
                Text(writeTags
                     ? "Fix Metadata saves tags and covers into the audio files."
                     : "Fixes are kept in Groovelight's library and survive rescans; your files are not modified.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fetch Missing Info")
                        Text(model.metadata.libraryJob.map { "\($0.step.rawValue): \($0.done) of \($0.total)" }
                             ?? "Album credits and info, artist info, missing artwork and lyrics, one request at a time.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.metadata.isFetchingLibraryInfo {
                        Button("Stop") { model.metadata.stopFetchingMissingInfo() }
                    } else {
                        Button("Missing Artwork Only") { model.metadata.fetchMissingInfo(steps: [.artwork]) }
                        Button("Fetch All") { model.metadata.fetchMissingInfo() }
                    }
                }
            } header: {
                Text("Library")
            } footer: {
                Text("Also in the Library menu. MusicBrainz allows one request per second, so a large library takes a while; it runs in the background.")
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Contact (optional)", text: $contact, prompt: Text("Email or website"))
            } header: {
                Text("MusicBrainz")
            } footer: {
                Text("Sent with MusicBrainz requests so its operators can reach you about heavy use. Metadata and credits come from MusicBrainz, covers from the Cover Art Archive and Apple Music, lyrics from LRCLIB, album backgrounds from Wikipedia.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
