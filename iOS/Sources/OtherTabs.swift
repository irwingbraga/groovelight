import LibraryKit
import SwiftUI

/// The Shelf tab (Cover Flow) on a phone.
struct ShelfView: View {
    var body: some View {
        NavigationStack {
            ShelfContent()
        }
    }
}

/// Search across artists, albums and songs (the iPhone's Search tab).
struct SearchView: View {
    var body: some View {
        NavigationStack {
            SearchResults()
                .libraryDestinations()
        }
    }
}

/// The search field and what it finds, in a navigation stack.
struct SearchResults: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        results
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Artists, albums and songs")
    }

    @ViewBuilder private var results: some View {
        let text = query.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            ContentUnavailableView("Search Your Library", systemImage: "magnifyingglass",
                                   description: Text("Artists, albums and songs on this device."))
        } else {
            // The Mac's search: every word starts a word of the name, case and accents ignored, best matches first.
            let found = model.library.read { try LibraryDatabase.search($0, query: text, limit: 50) } ?? LibrarySearchResults()
            let artists = found.artists.prefix(10)
            let albums = found.albums.prefix(20)
            let songs = found.songs
            if artists.isEmpty && albums.isEmpty && songs.isEmpty {
                ContentUnavailableView.search(text: text)
            } else {
                List {
                    if !artists.isEmpty {
                        Section("Artists") {
                            ForEach(Array(artists)) { artist in
                                NavigationLink(value: LibraryRoute.artist(artist.name)) { ArtistRow(artist: artist) }
                            }
                        }
                    }
                    if !albums.isEmpty {
                        Section("Albums") {
                            ForEach(Array(albums)) { album in
                                NavigationLink(value: LibraryRoute.album(album.albumKey)) {
                                    HStack(spacing: 12) {
                                        Cover(hash: album.artworkHash, size: 44, corner: 6)
                                        VStack(alignment: .leading) {
                                            Text(album.title).lineLimit(1)
                                            Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if !songs.isEmpty {
                        Section("Songs") {
                            ForEach(Array(songs.enumerated()), id: \.element.id) { index, track in
                                Button { model.play(songs, startAt: index) } label: { SongRow(track: track, showsArtwork: true) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Settings: the Mac and syncing, and sound. A tab on the iPhone, a sheet beside the sidebar (`isSheet`).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var isSheet = false
    /// `-GLDebugOpenEqualizer YES` (with `-GLDebugOpenSettings YES` where Settings is a sheet) opens the equalizer.
    @State private var showsEqualizer = UserDefaults.standard.bool(forKey: "GLDebugOpenEqualizer")

    var body: some View {
        @Bindable var player = model.player
        @Bindable var relay = model.relay
        NavigationStack {
            Form {
                SyncSection()
                Section {
                    NavigationLink {
                        EqualizerScreen()
                    } label: {
                        LabeledContent("Equalizer", value: player.equalizer.isEnabled ? player.equalizer.preset.name : "Off")
                    }
                    Toggle("Sound Check", isOn: $player.soundCheck)
                } header: {
                    Text("Sound")
                } footer: {
                    Text("Sound Check plays songs at the same loudness, from their ReplayGain tags or the Mac's measurement. Albums keep their own dynamics.")
                }
                Section {
                    Picker("Crossfade", selection: $player.crossfade) {
                        Text("Off").tag(0.0)
                        ForEach([1.0, 2, 3, 4, 5, 6, 8, 10, 12], id: \.self) { seconds in
                            Text("\(Int(seconds)) s").tag(seconds)
                        }
                    }
                    if player.crossfade > 0 {
                        Toggle("Albums Without Gaps", isOn: $player.crossfadeSkipsAlbum)
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text(player.crossfade > 0 ? "Songs fade into each other, except songs of one album played in order when Albums Without Gaps is on (live albums, DJ mixes)."
                         : "Songs follow each other without a gap.")
                }
                if model.sync.isPaired {
                    Section {
                        Toggle("Let Other Devices Play Here", isOn: $relay.isEnabled)
                    } header: {
                        Text("Play On")
                    } footer: {
                        Text("While Groovelight is open here, your other phones and iPads paired with \(model.sync.mac?.name ?? "your Mac") can choose this device under Play On and play its songs here. The Mac needs Groovelight open, and lets each device do this on its page under Devices.")
                    }
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    LabeledContent("Songs", value: "\(model.library.contents.songs.count)")
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(isPresented: $showsEqualizer) { EqualizerScreen() }
            .toolbar {
                if isSheet {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
    }
}

/// The paired Mac, the last sync, and Sync Now.
struct SyncSection: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window
    @State private var confirmingForget = false

    var body: some View {
        let sync = model.sync
        Section {
            if let mac = sync.mac {
                LabeledContent("Paired with", value: mac.name)
                if sync.isAway {
                    Label("Connected away from home, through Tailscale", systemImage: "globe")
                        .foregroundStyle(.secondary)
                }
                switch sync.phase {
                case let .syncing(done, total, current):
                    VStack(alignment: .leading, spacing: 6) {
                        if total > 0 {
                            ProgressView(value: Double(min(done, total)), total: Double(total))
                            Text("\(done) of \(total): \(current)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            ProgressView()
                            Text(current).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Stop Syncing", role: .cancel) { sync.cancelSync() }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("Sync Now") { sync.syncNow() }
                case .idle:
                    if let result = sync.lastResult, let date = sync.lastSync {
                        LabeledContent("Last sync") {
                            VStack(alignment: .trailing) {
                                Text(result)
                                Text(date, style: .relative).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Sync Now") { sync.syncNow() }
                }
                Toggle(isOn: Binding(get: { sync.syncsAutomatically }, set: { sync.syncsAutomatically = $0 })) {
                    Text("Sync Automatically on Wi-Fi")
                    Text("Checks the Mac now and then, as iOS allows, and syncs when there is something new.")
                }
                if sync.syncsAutomatically {
                    Toggle("Only While Charging", isOn: Binding(get: { sync.syncsOnlyWhileCharging }, set: { sync.syncsOnlyWhileCharging = $0 }))
                }
                if mac.awayHosts?.isEmpty == false {
                    Toggle("Sync over Mobile Data", isOn: Binding(get: { sync.syncsOverMobileData }, set: { sync.syncsOverMobileData = $0 }))
                }
                Button("Forget This Mac", role: .destructive) { confirmingForget = true }
                    .confirmationDialog("Forget \(mac.name)?", isPresented: $confirmingForget) {
                        Button("Forget", role: .destructive) { sync.forget() }
                    } message: {
                        Text("Your music stays on this device. Pair again to sync.")
                    }
            } else {
                Button("Pair with Your Mac") { window.isPairing = true }
            }
        } header: {
            Text("Mac")
        } footer: {
            Text("What this device gets is chosen on the Mac, on its page under Devices. Away from home, this device reaches the Mac through Tailscale when it is on here and on the Mac, and the Mac allows it on that page.")
        }
    }
}
