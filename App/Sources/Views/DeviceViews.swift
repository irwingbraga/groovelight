import LibraryKit
import SwiftUI
import WirelessSync

/// A portable player or memory card: how full it is, what to sync to it, and how the music is laid out on it.
struct DeviceView: View {
    var deviceId: String
    @Environment(AppModel.self) private var model
    @State private var selection = DeviceSelection()
    @State private var loadedId: String?

    var body: some View {
        let store = model.devices!
        if let device = store.device(deviceId) {
            Form {
                Section {
                    DeviceHeader(device: device)
                }
                if !store.accessible.contains(device.id) {
                    Section {
                        HStack {
                            Label("Groovelight needs your permission to put music on this drive.", systemImage: "lock")
                            Spacer()
                            Button("Allow Access…") { store.access(device, asking: true) }
                        }
                    }
                }
                DeviceSelectionSection(selection: $selection)
                DeviceFormatSection(deviceId: deviceId, isPlayer: device.isPlayer)
                Section {
                    HStack {
                        Text("Folders, covers, lyrics and playlists on devices are set in Settings, Devices.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        SettingsLink { Text("Layout Settings…") }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(device.name)
            .toolbar {
                ToolbarItemGroup {
                    if device.isWireless {
                        Button("Remove Device", systemImage: "minus.circle") {
                            model.wireless.unpair(String(device.id.dropFirst("wifi:".count)))
                        }
                        .help("Unpair \(device.name): it can no longer sync until it pairs again")
                    } else {
                        Button("Eject", systemImage: "eject") { store.eject(device) }
                            .help("Eject \(device.name)")
                            .disabled(store.job?.isRunning == true && store.job?.deviceId == device.id)
                    }
                    Button("Sync", systemImage: "arrow.triangle.2.circlepath") { store.sync(device) }
                        .help("Make \(device.name) hold the chosen music")
                        .disabled(store.job?.isRunning == true || selection.isEmpty)
                }
            }
            .task(id: deviceId) {
                selection = store.selection(deviceId)
                loadedId = deviceId
            }
            .onChange(of: selection) { if loadedId == deviceId { store.setSelection(selection, for: deviceId) } }
            // Changed elsewhere (the Android app asked for an album): shown here at once.
            .onChange(of: store.selectionRevision) {
                let saved = store.selection(deviceId)
                if saved != selection { selection = saved }
            }
        } else {
            ContentUnavailableView("Device Not Connected", systemImage: "sdcard")
        }
    }
}

/// Name, format, a capacity bar (Groovelight's music, other files, free space), what a sync would change, and the
/// progress of a sync.
private struct DeviceHeader: View {
    var device: DeviceStore.Device
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.devices!
        let preview = store.previews[device.id]
        let used = max(device.capacity - device.available, 0)
        let music = min(preview?.musicBytes ?? 0, used)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: device.isWireless ? "smartphone" : "sdcard.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.title2.bold())
                    Text([device.format, device.capacity > 0 ? Self.bytes(device.capacity) : "",
                          device.isWireless ? (device.isOnline ? "Online" : "Offline") : ""]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if device.isPlayer {
                Label("Groovelight plays the music on this device. Covers, lyrics and playlists come with the library, and songs in formats it cannot play are converted to FLAC as they sync.",
                      systemImage: "music.note")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            CapacityBar(capacity: device.capacity, music: music, other: used - music,
                        afterSync: preview.map { max(min(used + $0.netBytes, device.capacity), 0) })
            if device.volumes.count > 1 || device.volumes.contains(where: \.removable) {
                // Where the music is on a device with an SD card: the bar above is that storage.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(device.volumes, id: \.self) { volume in
                        HStack(spacing: 6) {
                            Image(systemName: volume.removable ? "sdcard" : "internaldrive")
                                .frame(width: 16)
                            Text(volume.name)
                            Text("\(Self.bytes(volume.free)) free of \(Self.bytes(volume.total))").foregroundStyle(.secondary)
                            if volume.music {
                                Text("Music folder").font(.caption.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.2), in: .capsule)
                            }
                        }
                    }
                }
                .font(.callout)
            }
            HStack(spacing: 16) {
                Legend(color: .accentColor, label: "Music", value: Self.bytes(music))
                Legend(color: .gray.opacity(0.6), label: "Other", value: Self.bytes(used - music))
                Legend(color: .secondary.opacity(0.2), label: "Free", value: Self.bytes(device.available))
            }
            .font(.callout)
            if let job = store.job, job.deviceId == device.id {
                JobRow(job: job)
            } else if device.isWireless, preview == nil {
                HStack {
                    Text("What a sync will change shows here after the device's first sync.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Sync") { store.sync(device) }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.job?.isRunning == true || store.selection(device.id).isEmpty)
                }
            } else if let preview {
                HStack {
                    Text(Self.describe(preview, available: device.available))
                        .font(.callout)
                        .foregroundStyle(preview.netBytes > device.available ? Color.red : .secondary)
                    Spacer()
                    Button("Sync") { store.sync(device) }
                        .buttonStyle(.borderedProminent)
                        .disabled(preview.filesToWrite == 0 && preview.filesToRemove == 0 || store.job?.isRunning == true)
                }
                ForEach(preview.skipped.prefix(3), id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }

    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: max(value, 0), countStyle: .file) }

    static func describe(_ preview: DeviceStore.Preview, available: Int64) -> String {
        if preview.filesToWrite == 0, preview.filesToRemove == 0 {
            return preview.songs == 0 ? "Choose music below to sync." : "\(preview.songs) songs, up to date."
        }
        var parts = ["\(preview.songs) songs"]
        if preview.filesToWrite > 0 { parts.append("Sync copies \(preview.filesToWrite) files (\(bytes(preview.bytesToWrite)))") }
        if preview.filesToRemove > 0 { parts.append("removes \(preview.filesToRemove)") }
        let after = available - preview.netBytes
        parts.append(after >= 0 ? "\(bytes(after)) free after" : "\(bytes(-after)) more than fits")
        return parts.joined(separator: ", ") + "."
    }
}

private struct CapacityBar: View {
    var capacity: Int64
    var music: Int64
    var other: Int64
    /// Used space once the sync is done (marked on the bar).
    var afterSync: Int64?

    var body: some View {
        GeometryReader { geometry in
            let total = Double(max(capacity, 1))
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.2))
                HStack(spacing: 0) {
                    Rectangle().fill(Color.accentColor).frame(width: width * Double(max(music, 0)) / total)
                    Rectangle().fill(.gray.opacity(0.6)).frame(width: width * Double(max(other, 0)) / total)
                }
                .clipShape(Capsule())
                if let afterSync {
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2, height: 18)
                        .offset(x: min(width * Double(afterSync) / total, width - 2))
                        .help("Used after the sync")
                }
            }
        }
        .frame(height: 12)
    }
}

private struct Legend: View {
    var color: Color
    var label: String
    var value: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label)
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// A sync, send or export: progress with Cancel, then how it went.
struct JobRow: View {
    var job: DeviceStore.Job
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            switch job.phase {
            case .waiting:
                ProgressView().controlSize(.small)
                Text("Waiting for the device: open Groovelight on it, or wait for its next automatic sync.")
                Spacer()
                Button("Cancel") { model.devices.cancel() }
            case .planning:
                ProgressView().controlSize(.small)
                Text("\(job.title): getting ready…")
                Spacer()
            case .copying(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("\(done) of \(total)").monospacedDigit().foregroundStyle(.secondary)
                Button("Cancel") { model.devices.cancel() }
            case .finished(let summary):
                Label(summary, systemImage: "checkmark.circle").foregroundStyle(.green)
                Spacer()
                Button("OK") { model.devices.dismissJob() }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Spacer()
                Button("OK") { model.devices.dismissJob() }
            }
        }
        .font(.callout)
    }
}

/// What the device holds: everything, or chosen playlists, artists, albums and genres.
private struct DeviceSelectionSection: View {
    @Binding var selection: DeviceSelection
    @Environment(AppModel.self) private var model
    @State private var kind = Kind.playlists
    @State private var filter = ""
    @State private var artists: [String] = []
    @State private var albums: [AlbumSummary] = []
    @State private var genres: [String] = []

    enum Kind: String, CaseIterable, Identifiable {
        case playlists = "Playlists", artists = "Artists", albums = "Albums", genres = "Genres"
        var id: String { rawValue }
    }

    var body: some View {
        Section {
            Toggle("All music", isOn: $selection.everything)
            if !selection.everything {
                Toggle("Loved Songs", isOn: $selection.lovedSongs)
                Picker("Choose by", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField("Filter", text: $filter, prompt: Text("Filter \(kind.rawValue.lowercased())"))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        rows
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 240)
            }
        } header: {
            Text("Music to Sync")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(summary)
                    .foregroundStyle(.secondary)
                if !selection.excludedTrackIds.isEmpty {
                    Button("Bring Back Removed Songs") { selection.excludedTrackIds = [] }
                        .help("Songs removed on the device come back at its next sync")
                }
            }
        }
        .observing(model.database, id: "device-lists", { db in
            (try LibraryDatabase.artists(db).map(\.name), try LibraryDatabase.albums(db, sort: .artist), try LibraryDatabase.genres(db))
        }) { value in
            artists = value.0
            albums = value.1
            genres = value.2
        }
    }

    @ViewBuilder private var rows: some View {
        switch kind {
        case .playlists:
            ForEach(model.playlists.filter(matches(\.name))) { playlist in
                if let id = playlist.id {
                    Toggle(playlist.name, isOn: member(id, \.playlistIds))
                }
            }
        case .artists:
            ForEach(artists.filter { matches($0) }, id: \.self) { name in
                Toggle(name, isOn: member(name, \.artists))
            }
        case .albums:
            ForEach(albums.filter { matches($0.title) || matches($0.artist) }) { album in
                Toggle(isOn: member(album.albumKey, \.albumKeys)) {
                    Text("\(album.title)  \(Text(album.artist).foregroundStyle(.secondary))")
                }
            }
        case .genres:
            ForEach(genres.filter { matches($0) }, id: \.self) { genre in
                Toggle(genre, isOn: member(genre, \.genres))
            }
        }
    }

    private func matches(_ text: String) -> Bool {
        filter.isEmpty || text.localizedStandardContains(filter)
    }

    private func matches<T>(_ path: KeyPath<T, String>) -> (T) -> Bool {
        { matches($0[keyPath: path]) }
    }

    private func member<T: Hashable>(_ value: T, _ path: WritableKeyPath<DeviceSelection, Set<T>>) -> Binding<Bool> {
        Binding(get: { selection[keyPath: path].contains(value) }, set: { isOn in
            if isOn { selection[keyPath: path].insert(value) } else { selection[keyPath: path].remove(value) }
        })
    }

    private var summary: String {
        let removed = selection.excludedTrackIds.count
        let removedNote = removed == 0 ? "" : " \(removed) song\(removed == 1 ? " was" : "s were") removed from the device there, and stay off it."
        if selection.everything { return "Every song in the library. Songs removed from the library are removed from the device at the next sync." + removedNote }
        var parts: [String] = []
        if selection.lovedSongs { parts.append("Loved Songs") }
        func count(_ number: Int, _ noun: String) { if number > 0 { parts.append("\(number) \(noun)\(number == 1 ? "" : "s")") } }
        count(selection.playlistIds.count, "playlist")
        count(selection.artists.count, "artist")
        count(selection.albumKeys.count, "album")
        count(selection.genres.count, "genre")
        count(selection.trackIds.count, "song")
        return (parts.isEmpty
            ? "Nothing chosen yet. Songs added with Send To stay on the device; a sync only removes songs it put there."
            : "Syncing " + ListFormatter.localizedString(byJoining: parts) + ". A sync only removes songs it put there; other files on the drive are left alone.") + removedNote
    }
}

/// Where songs, covers, lyrics and playlists go on devices (Settings, Devices).
struct DeviceLayoutSection: View {
    @Binding var profile: DeviceProfile

    private var isCustom: Bool { !OrganizeOptions.presets.contains { $0.template == profile.template } }

    var body: some View {
        Section {
            TextField("Music folder", text: $profile.musicFolder, prompt: Text("Root of the drive"))
            Picker("Folders and names", selection: Binding(get: { isCustom ? "custom" : profile.template }, set: { value in
                if value != "custom" { profile.template = value }
            })) {
                ForEach(OrganizeOptions.presets, id: \.template) { Text($0.name).tag($0.template) }
                Text("Custom").tag("custom")
            }
            if isCustom {
                TextField("Template", text: $profile.template)
                    .font(.system(.body, design: .monospaced))
            }
            LabeledContent("Example") {
                Text(example).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
            }
            Toggle("Playlists (M3U8)", isOn: $profile.writesPlaylists)
            if profile.writesPlaylists {
                TextField("Playlists folder", text: $profile.playlistFolder, prompt: Text("Root of the drive"))
            }
            Toggle("Cover image in each album folder (cover.jpg)", isOn: $profile.writesCovers)
            if profile.writesCovers {
                Picker("Cover size", selection: $profile.coverSize) {
                    ForEach(DeviceProfile.coverSizes, id: \.self) { size in
                        Text(size == 0 ? "Original" : "\(size) × \(size)").tag(size)
                    }
                }
            }
            Toggle("Synced lyrics (.lrc files)", isOn: $profile.writesLyrics)
        } header: {
            Text("Layout on Devices")
        } footer: {
            Text("For memory cards, players and Android devices. The music folder applies to cards and players; on Android, songs go in the folder chosen in the Groovelight app. Names are made safe for any file system, and FAT32 cards leave out files over 4 GB. Many players read cover.jpg and .lrc files; smaller covers load faster on players with little memory. Changes apply at the next sync.")
                .foregroundStyle(.secondary)
        }
    }

    private var example: String {
        let fields = NamingFields(title: "Paranoid Android", artist: "Radiohead", album: "OK Computer", albumArtist: "Radiohead",
                                  genre: "Alternative", year: 1997, trackNumber: 2, discNumber: 1, discTotal: 1, isCompilation: false)
        let path = FileNaming.relativePath(for: fields, fileExtension: "flac",
                                           options: OrganizeOptions(template: profile.template, portableNames: true))
        let folder = profile.musicFolder.split(separator: "/").joined(separator: "/")
        return "/" + (folder.isEmpty ? path : "\(folder)/\(path)")
    }
}

/// The format a device gets lossless songs in: as they are, or a lossy format that fits more music.
private struct DeviceFormatSection: View {
    var deviceId: String
    var isPlayer: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            Picker("Lossless songs", selection: Binding(get: { model.devices.encoding(deviceId) }, set: { model.devices.setEncoding($0, for: deviceId) })) {
                Text(isPlayer ? "As they are (FLAC when needed)" : "As they are").tag(LossyEncoding?.none)
                ForEach(LossyEncoding.allCases) { Text($0.displayName).tag(Optional($0)) }
            }
        } header: {
            Text("Format")
        } footer: {
            Text("FLAC, ALAC, WAV, AIFF and other lossless songs can go to this device in a lossy format, about a fifth of their size or less: Opus at 160 kbps, AAC at 192 kbps and MP3 at 320 kbps are each close to transparent. Songs that are already lossy are copied as they are. Hi-res songs are brought down to 44.1 or 48 kHz. Encoded songs are made at the next sync, once each, and kept until they change.")
                .foregroundStyle(.secondary)
        }
    }
}

/// "Send to" in song, album and playlist menus: each connected device, and a folder.
struct SendToMenu: View {
    var source: SendSource
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu("Send to") {
            ForEach(model.devices.devices) { device in
                Button(device.name, systemImage: device.isWireless ? "smartphone" : "sdcard") { model.devices.send(source, to: device) }
            }
            if !model.devices.devices.isEmpty { Divider() }
            Button("Folder…", systemImage: "folder") { model.devices.export(source) }
        }
        .disabled(model.devices.job?.isRunning == true)
    }
}
