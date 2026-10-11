import LibraryKit
import MetadataKit
import PlayerCore
import SwiftUI

struct AlbumsGridView: View {
    enum Mode { case all, recentlyAdded }

    var mode: Mode
    var artist: String? = nil
    @Environment(AppModel.self) private var model
    @State private var albums: [AlbumSummary]?
    @AppStorage("albums.sort") private var sort: AlbumSort = .artist

    var body: some View {
        Group {
            if let albums, albums.isEmpty, artist == nil {
                EmptyLibraryView()
            } else {
                ScrollView {
                    AlbumGrid(albums: albums ?? [])
                        .padding(24)
                }
            }
        }
        .navigationTitle(artist ?? (mode == .recentlyAdded ? "Recently Added" : "Albums"))
        .toolbar {
            if mode == .all, artist == nil {
                ToolbarItem(placement: .automatic) {
                    Picker("Sort", selection: $sort) {
                        Text("Artist").tag(AlbumSort.artist)
                        Text("Title").tag(AlbumSort.title)
                        Text("Year").tag(AlbumSort.year)
                        Text("Recently Added").tag(AlbumSort.recentlyAdded)
                    }
                    .pickerStyle(.menu)
                }
            }
        }
        .observing(model.database, id: "\(mode)-\(sort)-\(artist ?? "")", { [mode, sort, artist] db in
            switch mode {
            case .all: try LibraryDatabase.albums(db, sort: sort, artist: artist)
            case .recentlyAdded: try LibraryDatabase.recentlyAddedAlbums(db)
            }
        }) { albums = $0 }
    }
}

struct AlbumGrid: View {
    var albums: [AlbumSummary]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 22)], alignment: .leading, spacing: 26) {
            ForEach(albums) { album in
                NavigationLink(value: AppModel.Route.album(album)) {
                    AlbumCard(album: album)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct AlbumCard: View {
    var album: AlbumSummary
    @Environment(AppModel.self) private var model
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkImage(hash: album.artworkHash, size: .small, cornerRadius: 10)
                .shadow(color: .black.opacity(0.25), radius: isHovering ? 10 : 4, y: isHovering ? 6 : 2)
                .overlay(alignment: .bottomLeading) {
                    if isHovering {
                        HStack {
                            Button { model.playAlbum(album) } label: {
                                Image(systemName: "play.fill").frame(width: 18, height: 18)
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            Spacer()
                            Button { model.playAlbum(album, shuffle: true) } label: {
                                Image(systemName: "shuffle").frame(width: 18, height: 18)
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                        }
                        .padding(8)
                        .transition(.opacity)
                    }
                }
            Text(album.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Text(album.artist)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(.rect)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering } }
        .contextMenu {
            Button("Play") { model.playAlbum(album) }
            Button("Shuffle") { model.playAlbum(album, shuffle: true) }
            QueueMenuItems(source: .album(album.albumKey))
            Divider()
            Button("Get Info…") { model.getInfo(albumKey: album.albumKey) }
            Button("Fix Metadata…") {
                Task {
                    let tracks = (try? await model.database.writer.read { db in try LibraryDatabase.tracks(db, albumKey: album.albumKey) }) ?? []
                    model.metadata.review(tracks)
                }
            }
        }
    }
}

struct AlbumDetailView: View {
    var album: AlbumSummary
    @Environment(AppModel.self) private var model
    @State private var tracks: [Track] = []
    @State private var info: AlbumInfo?
    @State private var artistNames: Set<String> = []
    @State private var isShowingCredits = false

    var body: some View {
        let isLoadingInfo = model.metadata.albumInfoInFlight.contains(album.albumKey) && (info?.isEmpty ?? true)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Side by side when there is room, stacked in narrow windows.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: 28) {
                        artwork
                        headerInfo
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        artwork
                        headerInfo
                    }
                }
                // Per-row specs only when the album mixes formats; otherwise the header already says it all.
                TrackList(tracks: tracks, style: .album, showsQuality: AudioSpec.uniform(tracks.map(\.audioSpec)) == nil,
                          albumKey: album.albumKey)
                Text("\(tracks.count) songs, \(formatLongDuration(tracks.reduce(0) { $0 + $1.duration }))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
        }
        .coverWash { ArtworkImage(hash: album.artworkHash, size: .small, cornerRadius: 0) }
        .navigationTitle(album.title)
        .sheet(isPresented: $isShowingCredits) {
            CreditsSheet(title: album.title, subtitle: album.artist, artworkHash: album.artworkHash,
                         sections: info?.sections ?? [], releaseId: info?.releaseId, isLoading: isLoadingInfo,
                         artistNames: artistNames)
        }
        .observing(model.database, id: album.albumKey, { [key = album.albumKey] db in
            try LibraryDatabase.tracks(db, albumKey: key)
        }) { tracks = $0 }
        .observing(model.database, id: "info-\(album.albumKey)", { [key = album.albumKey] db in
            (try LibraryDatabase.albumInfo(db, albumKey: key)?.data, try LibraryDatabase.artists(db).map(\.name))
        }) { value in
            info = value.0.flatMap { try? JSONDecoder().decode(AlbumInfo.self, from: $0) }
            artistNames = Set(value.1.map { $0.lowercased() })
        }
        .task(id: album.albumKey) { await model.metadata.loadAlbumInfo(albumKey: album.albumKey) }
    }

    private var artwork: some View {
        ArtworkImage(hash: album.artworkHash, size: .large, cornerRadius: 12)
            .frame(width: 260, height: 260)
            .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
    }

    private var headerInfo: some View {
        AlbumHeaderInfo(album: album, tracks: tracks, about: info?.about, producers: info?.producers ?? [],
                        hasCredits: !(info?.sections.isEmpty ?? true),
                        isLoadingInfo: model.metadata.albumInfoInFlight.contains(album.albumKey) && (info?.isEmpty ?? true)) {
            isShowingCredits = true
        }
    }
}

private struct AlbumHeaderInfo: View {
    var album: AlbumSummary
    var tracks: [Track]
    var about: AlbumAbout?
    var producers: [String]
    var hasCredits: Bool
    var isLoadingInfo: Bool
    var showCredits: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(album.title)
                .font(.system(size: 30, weight: .bold))
                .lineLimit(2)
            ArtistLink(name: album.artist)
                .font(.system(size: 22))
            Text([album.genre, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · ").uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if let about {
                AboutExcerpt(about: about)
                    .padding(.vertical, 4)
            } else if isLoadingInfo {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Looking up album info…")
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
            if !producers.isEmpty {
                // The headline credit, a click away from the rest.
                LinkText(text: "Produced by \(ListFormatter.localizedString(byJoining: producers))", help: "Show all credits",
                         action: showCredits)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            AlbumQualitySummary(tracks: tracks)
                .padding(.top, 2)
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button { model.play(tracks) } label: {
                        Label("Play", systemImage: "play.fill").frame(width: 90)
                    }
                    .buttonStyle(.glassProminent)
                    Button { model.play(tracks, shuffle: true) } label: {
                        Label("Shuffle", systemImage: "shuffle").frame(width: 90)
                    }
                    .buttonStyle(.glass)
                    if hasCredits {
                        Button(action: showCredits) {
                            Label("Credits", systemImage: "person.2")
                        }
                        .buttonStyle(.glass)
                        .help("Musicians, songwriters and production")
                        #if DEBUG
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { DebugHitTargets.creditsButton = $0 }
                        #endif
                    }
                    Menu {
                        QueueMenuItems(source: .album(album.albumKey))
                        Divider()
                        Button("Get Info…", systemImage: "info.circle") { model.getInfo(tracks) }
                        Button("Reload Credits & Info", systemImage: "arrow.clockwise") {
                            Task { await model.metadata.loadAlbumInfo(albumKey: album.albumKey, force: true) }
                        }
                        Button("Fix Metadata…", systemImage: "wand.and.sparkles") { model.metadata.review(tracks) }
                        Button("Organize Files…", systemImage: "folder.badge.gearshape") { model.files.organize(tracks) }
                        Button("Show in Finder", systemImage: "folder") { model.showInFinder(Array(tracks.prefix(1))) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .help("More")
                    #if DEBUG
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { DebugHitTargets.albumMoreMenu = $0 }
                    #endif
                }
                .controlSize(.large)
            }
            .padding(.top, 10)
        }
    }
}

/// Album-level quality line: the shared spec when every track matches, otherwise "Mixed formats" with the codecs.
private struct AlbumQualitySummary: View {
    var tracks: [Track]

    var body: some View {
        let specs = tracks.map(\.audioSpec)
        if let spec = AudioSpec.uniform(specs) {
            HStack(spacing: 6) {
                QualityBadge(tier: spec.tier)
                Text(spec.summary)
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .help(spec.tier == .standard ? spec.summary : "\(spec.tier.displayName) · \(spec.summary)")
        } else if let best = specs.map(\.tier).max() {
            let codecs = Array(Set(specs.map(\.codec.shortName))).sorted()
            HStack(spacing: 6) {
                QualityBadge(tier: best)
                Text("Mixed formats · \(codecs.joined(separator: ", "))")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .help("Tracks differ in format or resolution; each song shows its own details.")
        }
    }
}

/// Artist name that opens the artist's page. Compilations ("Various Artists") have no artist page, so stay plain text.
struct ArtistLink: View {
    var name: String
    @Environment(AppModel.self) private var model

    var body: some View {
        LinkText(text: name, help: "Go to \(name)", action: name == "Various Artists" ? nil : { model.showArtist(name) })
            .foregroundStyle(Color.brand)
            #if DEBUG
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { DebugHitTargets.artistLink = $0 }
            #endif
    }
}

/// Text that acts as a link: underlined with a hand cursor on hover. Plain text when `action` is nil.
struct LinkText: View {
    var text: String
    var help: String? = nil
    var action: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        if let action {
            Button(action: action) {
                Text(text).underline(isHovering)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .pointerStyle(.link)
            .help(help ?? text)
        } else {
            Text(text)
        }
    }
}

extension View {
    /// Soft color wash from a cover behind a page's header, like Apple Music: the cover blurred and stretched over the
    /// full page width (the cover itself is square).
    func coverWash<Cover: View>(@ViewBuilder _ cover: @escaping () -> Cover) -> some View {
        background {
            GeometryReader { geometry in
                cover()
                    .frame(width: geometry.size.width, height: geometry.size.width)
                    .blur(radius: 80)
                    .opacity(0.35)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .clipped()
            }
            .ignoresSafeArea()
        }
    }
}
