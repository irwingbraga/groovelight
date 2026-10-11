import LibraryKit
import MetadataKit
import SwiftUI

/// A musician, producer, songwriter or studio from the credits: what they did in the library, with their albums and
/// songs, ready to play or turn into a playlist.
struct PersonView: View {
    var person: CreditPerson
    @Environment(AppModel.self) private var model
    @State private var credits: PersonCredits?
    @State private var coverage: (known: Int, total: Int) = (0, 0)
    @State private var isLibraryArtist = false
    @State private var photo: String?

    var body: some View {
        let tracks = credits?.tracks.map(\.track) ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header(tracks: tracks)
                if let credits, !credits.albums.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Albums").font(.title3.weight(.bold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 22)], alignment: .leading, spacing: 26) {
                            ForEach(credits.albums, id: \.album.albumKey) { item in
                                NavigationLink(value: AppModel.Route.album(item.album)) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        AlbumCard(album: item.album)
                                        Text(item.roles.joined(separator: ", "))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(2)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                if !tracks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Songs").font(.title3.weight(.bold))
                        TrackList(tracks: tracks, style: .playlist)
                    }
                }
                coverageNote
            }
            .padding(28)
        }
        .navigationTitle(person.name)
        .observing(model.database, id: person, { [person] db in
            (try LibraryDatabase.credits(db, person: person), try LibraryDatabase.creditCoverage(db),
             try LibraryDatabase.artists(db).contains { $0.name.caseInsensitiveCompare(person.name) == .orderedSame })
        }) { value in
            credits = value.0
            coverage = value.1
            isLibraryArtist = value.2
        }
        .observing(model.database, id: "photo-\(person.name)", { [name = person.name] db in
            try LibraryDatabase.artistInfo(db, name: name)?.data
        }) { data in
            photo = data.flatMap { try? JSONDecoder().decode(ArtistInfo.self, from: $0) }?.imageHash
        }
    }

    private func header(tracks: [Track]) -> some View {
        HStack(alignment: .center, spacing: 24) {
            Group {
                if let photo {
                    ArtworkImage(hash: photo, size: .large, cornerRadius: 0).clipShape(.circle)
                } else {
                    PersonAvatar(name: person.name)
                }
            }
            .frame(width: 140, height: 140)
            VStack(alignment: .leading, spacing: 6) {
                Text(person.name)
                    .font(.system(size: 30, weight: .bold))
                if let roles = credits?.roles, !roles.isEmpty {
                    Text(roles.prefix(6).joined(separator: ", ").capitalizingFirstLetter)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        Button { model.play(tracks) } label: { Label("Play", systemImage: "play.fill").frame(width: 90) }
                            .buttonStyle(.glassProminent)
                        Button { model.play(tracks, shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle").frame(width: 90) }
                            .buttonStyle(.glass)
                        Button { model.createPlaylist(named: "With \(person.name)", tracks: tracks) } label: {
                            Label("Create Playlist", systemImage: "text.badge.plus")
                        }
                        .buttonStyle(.glass)
                        .help("A playlist of every song \(person.name) is credited on")
                        if isLibraryArtist {
                            Button { model.showArtist(person.name) } label: { Label("Artist Page", systemImage: "music.microphone") }
                                .buttonStyle(.glass)
                        }
                    }
                    .controlSize(.large)
                    .disabled(tracks.isEmpty)
                }
                .padding(.top, 8)
            }
        }
    }

    private var summary: String {
        let albums = credits?.albums.count ?? 0
        let songs = credits?.tracks.count ?? 0
        return "\(albums == 1 ? "1 album" : "\(albums) albums") · \(songs == 1 ? "1 song" : "\(songs) songs") in your library"
    }

    /// Credits are only known for albums looked up so far: offer to look up the rest.
    @ViewBuilder
    private var coverageNote: some View {
        if coverage.known < coverage.total {
            HStack(spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                if model.metadata.isFetchingLibraryInfo {
                    Text("Fetching missing library info in the background (see the sidebar).")
                } else {
                    Text("Credits are known for \(coverage.known) of \(coverage.total) albums, so \(person.name) may appear on more.")
                    Button("Look Up the Rest") { model.metadata.fetchMissingInfo(steps: [.albums]) }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}

/// Initials on a color picked from the name (credits have no photos).
struct PersonAvatar: View {
    var name: String

    var body: some View {
        let hue = Double(name.unicodeScalars.reduce(5) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        Circle()
            .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.75), Color(hue: hue, saturation: 0.6, brightness: 0.35)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                GeometryReader { geometry in
                    Text(initials)
                        .font(.system(size: geometry.size.width * 0.36, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
    }
}

extension String {
    var capitalizingFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
