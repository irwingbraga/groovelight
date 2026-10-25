import LibraryKit
import SwiftUI
import UIKit

/// Downloaded: only this device's music in the Library (on), or the Mac's too (off), as on Android. Shown once paired.
struct DownloadedToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var catalog = model.catalog
        if model.sync.isPaired {
            // The download symbol, highlighted while only this device's music shows (as on Android).
            Toggle(isOn: $catalog.downloadedOnly) {
                Label("Downloaded Only", systemImage: catalog.downloadedOnly ? "arrow.down.circle.fill" : "arrow.down.circle")
            }
            .toggleStyle(.button)
            .help("Downloaded Only")
            .accessibilityHint(catalog.downloadedOnly ? "Showing only music on this device" : "Showing your Mac's music too")
        }
    }
}

/// Over the Library with the Mac's music: the Mac away, or requests waiting for it.
struct CatalogNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let catalog = model.catalog
        let waiting = catalog.pending.count
        let requests = waiting == 1 ? "1 request" : "\(waiting) requests"
        let empty = catalog.catalog == nil
        let text: String? = if let error = catalog.error, !empty {
            error
        } else if catalog.reachable == false, !empty {
            "\(model.sync.mac?.name ?? "The Mac") is not reachable: this is its library as of the last time." + (waiting > 0 ? " \(requests) will be sent when it is." : "")
        } else if waiting > 0, catalog.isLoading {
            "Sending \(requests) to the Mac…"
        } else if waiting > 0 {
            "\(requests) waiting for the Mac."
        } else {
            nil
        }
        if let text {
            Text(text)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
                .padding(.horizontal)
                .padding(.bottom, 6)
        }
    }
}

/// The Library's Recently Added, Albums, Artists or Songs with the Mac's music: what is here plays, what is not opens
/// its page on the Mac (to bring it here).
struct MergedLibrarySection: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem

    var body: some View {
        let catalog = model.catalog
        Group {
            if catalog.catalog == nil && model.library.isEmpty {
                MacLibraryUnavailable()
            } else {
                switch item {
                case .recentlyAdded: MergedAlbumGrid(albums: catalog.albums(recentFirst: true))
                case .artists: MergedArtistList()
                case .songs: MergedSongList(songs: catalog.songs, showsCover: true)
                case .genres: MergedGenreList()
                default: MergedAlbumGrid(albums: catalog.albums())
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { CatalogNotice() }
        .refreshable { await model.catalog.refresh() }
        // Now, and again when the Mac comes back.
        .task(id: model.sync.mac?.id) { await model.catalog.refresh() }
    }
}

/// The Mac's library not read yet: reading it, or why it could not be.
struct MacLibraryUnavailable: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let catalog = model.catalog
        if catalog.isLoading {
            ProgressView("Reading \(model.sync.mac?.name ?? "the Mac")'s library…")
        } else {
            ContentUnavailableView {
                Label("Your Mac's Library", systemImage: "desktopcomputer")
            } description: {
                Text(catalog.error ?? "Open Groovelight on your Mac, on the same Wi-Fi, to see everything there.")
            } actions: {
                Button("Try Again") { Task { await catalog.refresh() } }.buttonStyle(.glassProminent)
            }
        }
    }
}

/// Albums as covers (pinching changes their size, as in the device's grid): one here opens its page, one only on the
/// Mac its page there. A mark shows where each stands.
struct MergedAlbumGrid: View {
    @Environment(AppModel.self) private var model
    let albums: [DeviceCatalog.Album]
    /// False inside a page that scrolls already (an artist's).
    var scrolls = true
    @AppStorage("albums.coverSize") private var coverSize: Double = 160
    @State private var pinchStart: Double?

    var body: some View {
        Group {
            if scrolls {
                ScrollView { grid }
            } else {
                grid
            }
        }
        .simultaneousGesture(MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? coverSize
                pinchStart = start
                coverSize = min(max(start * value.magnification, 100), 300)
            }
            .onEnded { _ in pinchStart = nil })
    }

    private var grid: some View {
        let catalog = model.catalog
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: coverSize, maximum: coverSize * 1.4), spacing: 16)], spacing: 20) {
            ForEach(albums, id: \.key) { album in
                NavigationLink(value: catalog.isHere(album: album.key) ? LibraryRoute.album(album.key) : LibraryRoute.macAlbum(album.key)) {
                    VStack(alignment: .leading, spacing: 4) {
                        CatalogCover(hash: album.artworkHash, corner: 8)
                            .overlay(alignment: .bottomTrailing) {
                                AvailabilityMark(availability: catalog.availability(album: album)).padding(6)
                            }
                            .hoverEffect(.lift)
                        Text(album.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
    }
}

/// Album artists, the Mac's and this device's: one with music here opens their page here, one only on the Mac their
/// page there.
struct MergedArtistList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let catalog = model.catalog
        let compilations = catalog.compilations
        List {
            // First, as on the Mac: albums by various artists, here and on the Mac.
            if !compilations.isEmpty {
                NavigationLink(value: LibraryRoute.macArtist(ArtistSummary.compilations)) {
                    HStack(spacing: 12) {
                        CatalogCover(hash: compilations.first?.artworkHash, size: 44, corner: 22)
                        VStack(alignment: .leading) {
                            Text("Compilations")
                            Text(compilations.count == 1 ? "1 album" : "\(compilations.count) albums").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            ForEach(catalog.artists, id: \.name) { artist in
            NavigationLink(value: catalog.isHere(artist: artist.name) ? LibraryRoute.artist(artist.name) : LibraryRoute.macArtist(artist.name)) {
                HStack(spacing: 12) {
                    CatalogCover(hash: artist.artworkHash, size: 44, corner: 22)
                    VStack(alignment: .leading) {
                        Text(artist.name)
                        Text(artist.albums == 1 ? "1 album" : "\(artist.albums) albums").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if catalog.isWaiting(artist: artist.name) {
                        AvailabilityMark(availability: .waiting)
                    } else if catalog.isHere(artist: artist.name) {
                        AvailabilityMark(availability: .onDevice)
                    }
                }
            }
            }
        }
        .listStyle(.plain)
    }
}

/// Genres, the Mac's and this device's, each opening its songs.
struct MergedGenreList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let genres = model.catalog.genres
        List(genres, id: \.self) { genre in
            NavigationLink(value: LibraryRoute.genre(genre)) { Label(genre, systemImage: "guitars") }
        }
        .listStyle(.plain)
        .overlay {
            if genres.isEmpty { ContentUnavailableView("No Genres", systemImage: "guitars") }
        }
    }
}

/// Songs of the Mac's library: one here plays (with the rest of its album that is here) and has its menu; one that is
/// not has a button to bring it here.
struct MergedSongList: View {
    @Environment(AppModel.self) private var model
    let songs: [DeviceCatalog.Song]
    var showsCover = false

    var body: some View {
        List(songs, id: \.id) { song in
            MergedSongRow(song: song, showsCover: showsCover)
        }
        .listStyle(.plain)
    }
}

struct MergedSongRow: View {
    @Environment(AppModel.self) private var model
    let song: DeviceCatalog.Song
    let showsCover: Bool

    var body: some View {
        let catalog = model.catalog
        let availability = catalog.availability(song: song)
        let local = catalog.isHere(song: song.id) ? model.library.contents.songs.first { $0.id == song.id } : nil
        HStack(spacing: 12) {
            if showsCover {
                CatalogCover(hash: song.artworkHash ?? catalog.album(song.albumKey)?.artworkHash, size: 40, corner: 6)
            } else {
                Text(song.trackNumber.map(String.init) ?? "").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 24, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).lineLimit(1).foregroundStyle(model.currentSongId == song.id ? Color.accentColor : .primary)
                let details = [showsCover ? song.artist : nil, showsCover ? catalog.album(song.albumKey)?.title : nil,
                               availability == .onMac || availability == .onDevice ? nil : availability.text].compactMap(\.self)
                if !details.isEmpty {
                    Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !showsCover {
                Text(Duration.seconds(song.duration).formatted(.time(pattern: .minuteSecond))).font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if availability == .onMac || availability == .leaving {
                Button { catalog.request(.add, .song, key: String(song.id)) } label: {
                    Label("Bring \(song.title) Here", systemImage: "arrow.down.circle")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            } else {
                AvailabilityMark(availability: availability)
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            guard let local else { return }
            // Played from this device's copy, with the rest of its album that is here.
            let album = model.library.read { try LibraryDatabase.tracks($0, albumKey: local.albumKey) } ?? [local]
            model.play(album, startAt: album.firstIndex { $0.id == local.id } ?? 0)
        }
        .contextMenu {
            if let local { SongMenu(track: local) }
            if catalog.canRemove(song: song) {
                Button("Remove from This Device", systemImage: "minus.circle", role: .destructive) {
                    catalog.request(.remove, .song, key: String(song.id))
                }
            }
        }
    }
}

/// An album of the Mac's library: bring it here (in this device's format or another), keep it, or let it go; open it
/// when it is here; its songs, each to bring on its own.
struct MacAlbumView: View {
    @Environment(AppModel.self) private var model
    let albumKey: String
    @State private var showsArtist = false

    var body: some View {
        let catalog = model.catalog
        let album = catalog.album(albumKey)
        let songs = catalog.songs(album: albumKey)
        let here = songs.filter { catalog.isHere(song: $0.id) }.count
        List {
            Section {
                VStack(spacing: 12) {
                    CatalogCover(hash: album?.artworkHash, corner: 12)
                        .frame(maxWidth: 260)
                        .shadow(radius: 12, y: 6)
                    VStack(spacing: 2) {
                        Text(album?.title ?? "").font(.title2.bold()).multilineTextAlignment(.center)
                        if let album, !album.isCompilation {
                            // A button (a link in a list row takes the whole row).
                            Button { showsArtist = true } label: { Text(album.artist).font(.title3) }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                        }
                        Text(Self.summary(album, songs)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let album {
                        let availability = catalog.availability(album: album)
                        HStack(spacing: 6) {
                            AvailabilityMark(availability: availability)
                            Text(availability == .onDevice && here > 0 && here < songs.count ? "\(here) of \(songs.count) songs on this device" : availability.text)
                                .font(.subheadline.weight(.medium))
                        }
                        AlbumTransferButtons(album: album, availability: availability)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }
            ForEach(songs, id: \.id) { song in
                MergedSongRow(song: song, showsCover: false)
            }
        }
        .listStyle(.plain)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { CatalogNotice() }
        .navigationDestination(isPresented: $showsArtist) {
            if let artist = album?.artist {
                ArtistDestination(name: artist, onMac: !catalog.isHere(artist: artist))
            }
        }
    }

    /// "1969 · 10 songs · FLAC 24-bit/96 kHz".
    static func summary(_ album: DeviceCatalog.Album?, _ songs: [DeviceCatalog.Song]) -> String {
        var parts: [String] = []
        if let year = album?.year { parts.append(String(year)) }
        parts.append(songs.count == 1 ? "1 song" : "\(songs.count) songs")
        if let song = songs.first {
            let codec = AudioSpec.Codec(rawValue: song.codec)?.shortName ?? song.codec.uppercased()
            if let bits = song.bitDepth, let rate = song.sampleRate {
                parts.append("\(codec) \(bits)-bit/\((Double(rate) / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz")
            } else {
                parts.append(codec)
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// Add to This Device (holding for another format) or Keep on This Device; when it is here or coming, Open, Remove (or
/// Cancel), and its format, which can be changed (the next sync makes its songs again).
private struct AlbumTransferButtons: View {
    @Environment(AppModel.self) private var model
    let album: DeviceCatalog.Album
    let availability: CatalogAvailability
    @State private var isOpening = false

    var body: some View {
        let catalog = model.catalog
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                switch availability {
                case .onMac, .leaving:
                    Menu {
                        FormatChoices(title: "Add As") { catalog.request(.add, .album, key: album.key, encoding: $0) }
                    } label: {
                        Label(availability == .leaving ? "Keep on This Device" : "Add to This Device", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    } primaryAction: {
                        catalog.request(.add, .album, key: album.key)
                    }
                    .buttonStyle(.glassProminent)
                default:
                    if catalog.isHere(album: album.key) {
                        Button { isOpening = true } label: {
                            Label("Open", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }
                    if catalog.canRemove(album: album) {
                        Button(role: .destructive) { catalog.request(.remove, .album, key: album.key) } label: {
                            Text(availability == .onDevice ? "Remove" : "Cancel").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            .controlSize(.large)
            .frame(maxWidth: 420)
            if availability == .onMac {
                Text("Hold to choose the format").font(.caption).foregroundStyle(.secondary)
            } else {
                let chosen = catalog.encoding(of: album)
                Menu {
                    FormatChoices(title: "Change Format", current: chosen) { catalog.request(.add, .album, key: album.key, encoding: $0) }
                } label: {
                    Text("Format: \(FormatChoices.label(chosen ?? catalog.deviceEncoding))\(chosen == nil ? " (this device's)" : "")")
                        .font(.footnote)
                }
            }
            // Here, but not as an album or artist chosen here: a playlist or genre on the Mac brings it.
            if availability == .onDevice, !catalog.canRemove(album: album), !catalog.holdsEverything {
                Text("It is here through a playlist or genre chosen on the Mac.").font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        // A button (a link in a list row takes the whole row).
        .navigationDestination(isPresented: $isOpening) { AlbumDetail(albumKey: album.key) }
    }
}

/// The formats music can come in: as it is, or Opus, AAC or MP3.
struct FormatChoices: View {
    var title: String
    var current: String?
    let pick: (String) -> Void

    var body: some View {
        Section(title) {
            Button { pick("original") } label: {
                if current == "original" { Label(Self.label("original"), systemImage: "checkmark") } else { Text(Self.label("original")) }
            }
            ForEach(LossyEncoding.allCases) { encoding in
                Button { pick(encoding.rawValue) } label: {
                    if current == encoding.rawValue { Label(encoding.displayName, systemImage: "checkmark") } else { Text(encoding.displayName) }
                }
            }
        }
    }

    /// "As It Is (Lossless)", "Opus 160 kbps"...
    static func label(_ encoding: String?) -> String {
        guard let encoding, encoding != "original" else { return "As It Is (Lossless)" }
        return LossyEncoding(rawValue: encoding)?.displayName ?? encoding
    }
}

/// An artist of the Mac's library: all their albums to this device at once (with the ones added on the Mac later), or
/// album by album.
struct MacArtistView: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        let catalog = model.catalog
        let albums = catalog.albums(artist: name)
        let waiting = catalog.isWaiting(artist: name)
        // The compilations entry: albums by various artists, added album by album.
        let isCompilations = name == ArtistSummary.compilations
        ScrollView {
            VStack(spacing: 16) {
                CatalogCover(hash: (isCompilations ? nil : catalog.photo(of: name)) ?? albums.first?.artworkHash, size: 160, corner: 80)
                VStack(spacing: 2) {
                    Text(ArtistSummary.displayName(name)).font(.title.bold())
                    Text(albums.count == 1 ? "1 album" : "\(albums.count) albums").font(.subheadline).foregroundStyle(.secondary)
                }
                if !catalog.holdsEverything, !isCompilations {
                    Group {
                        if catalog.isChosen(artist: name) {
                            Button(role: .destructive) { catalog.request(.remove, .artist, key: name) } label: {
                                Text(waiting ? "Cancel" : "Remove Artist from This Device").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                        } else {
                            Menu {
                                FormatChoices(title: "Add As") { catalog.request(.add, .artist, key: name, encoding: $0) }
                            } label: {
                                Label("Add Artist to This Device", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
                            } primaryAction: {
                                catalog.request(.add, .artist, key: name)
                            }
                            .buttonStyle(.glassProminent)
                        }
                    }
                    .controlSize(.large)
                    .frame(maxWidth: 360)
                }
                if waiting {
                    Text("Waiting for the Mac").font(.subheadline.weight(.medium)).foregroundStyle(Color.accentColor)
                }
                MergedAlbumGrid(albums: albums, scrolls: false)
            }
            .padding(.top)
        }
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { CatalogNotice() }
    }
}

extension CatalogAvailability {
    var text: String {
        switch self {
        case .onDevice: "On this device"
        case .arriving: "Arrives at the next sync"
        case .waiting: "Waiting for the Mac"
        case .leaving: "Leaves at the next sync"
        case .onMac: "On the Mac"
        }
    }
}

/// Where an album or song stands: here (a check), coming (an arrow), waiting for the Mac (a clock), leaving (a minus),
/// or nothing (only on the Mac).
struct AvailabilityMark: View {
    let availability: CatalogAvailability

    var body: some View {
        switch availability {
        case .onDevice: mark("checkmark.circle.fill", .green)
        case .arriving: mark("arrow.down.circle.fill", .blue)
        case .waiting: mark("clock.circle.fill", .orange)
        case .leaving: mark("minus.circle.fill", .red)
        case .onMac: EmptyView()
        }
    }

    private func mark(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, color)
            .font(.body)
            .accessibilityLabel(availability.text)
    }
}

/// A cover of the Mac's library: this device's copy, or the Mac's, fetched once.
struct CatalogCover: View {
    @Environment(AppModel.self) private var model
    let hash: String?
    var size: CGFloat? = nil
    var corner: CGFloat = 10
    @State private var image: UIImage?

    init(hash: String?, size: CGFloat? = nil, corner: CGFloat = 10) {
        self.hash = hash
        self.size = size
        self.corner = corner
        _image = State(initialValue: ImageCache.image(hash))
    }

    var body: some View {
        RoundedRectangle(cornerRadius: corner)
            .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.30, blue: 0.63), Color(red: 0.56, green: 0.35, blue: 0.54)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note").font(.system(size: (size ?? 120) * 0.35)).foregroundStyle(.white.opacity(0.85))
                }
            }
            .clipShape(.rect(cornerRadius: corner))
            .frame(width: size, height: size)
            .aspectRatio(1, contentMode: .fit)
            .task(id: hash) {
                if let cached = ImageCache.image(hash) { image = cached; return }
                guard let url = await model.catalog.coverURL(hash) else { return }
                image = await ImageCache.load(url, hash: hash)
            }
    }
}
