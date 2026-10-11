import LibraryKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Library", systemImage: "folder") { LibrarySettings() }
            Tab("Metadata", systemImage: "wand.and.sparkles") { MetadataSettings() }
            Tab("Files", systemImage: "doc.text") { FilesSettings() }
            Tab("Backup", systemImage: "externaldrive.badge.timemachine") { BackupSettings() }
        }
        .frame(width: 720, height: 480)
    }
}

struct GeneralSettings: View {
    @AppStorage(AppTheme.key) private var theme = AppTheme.system

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
        }
        .formStyle(.grouped)
        .onChange(of: theme) { _, theme in theme.apply() }
    }
}

struct LibrarySettings: View {
    @Environment(AppModel.self) private var model
    @State private var roots: [LibraryRoot] = []
    @State private var selection: Int64?

    var body: some View {
        Form {
            Section {
                List(roots, selection: $selection) { root in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(URL(fileURLWithPath: root.path).lastPathComponent, systemImage: "folder.fill")
                        Text(root.path)
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
                        } else if let date = root.lastScanAt {
                            Text("Last scanned \(date.formatted(.relative(presentation: .named)))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .tag(root.id)
                }
                .frame(minHeight: 160)
                HStack {
                    Button("Add Folder…") { model.chooseLibraryFolder() }
                    Button("Remove") {
                        if let root = roots.first(where: { $0.id == selection }) { model.removeRoot(root) }
                    }
                    .disabled(selection == nil)
                    Spacer()
                    Button("Rescan Now") { model.rescanAll() }
                        .disabled(model.scanProgress != nil)
                }
            } header: {
                Text("Music Folders")
            } footer: {
                if let summary = model.lastScanSummary {
                    Text("Last scan: \(summary.added) added, \(summary.updated) updated, \(summary.removed) removed, \(summary.failed.count) unreadable.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .observing(model.database, id: 0, { try LibraryDatabase.roots($0) }) { roots = $0 }
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
