import AppKit
import LibraryKit
import SwiftUI
import UniformTypeIdentifiers

/// Edits a playlist's name and cover: generated colors and patterns, the songs' covers or a custom image (chosen or
/// dropped on the preview), and whether the name is drawn on the cover.
struct EditPlaylistSheet: View {
    var playlist: Playlist
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind: PlaylistCover.Kind = .songCovers
    @State private var showsTitle = false
    @State private var songHashes: [String] = []
    @State private var isDropTargeted = false
    @State private var didLoad = false

    private var cover: PlaylistCover { PlaylistCover(kind: kind, showsTitle: showsTitle) }

    /// Palette and pattern of the current generated cover (or the defaults when another kind is selected).
    private var generated: (palette: String, pattern: String) {
        if case let .generated(palette, pattern) = kind { return (palette, pattern) }
        return (CoverPalette.forSeed(playlist.id ?? 0).id, CoverPattern.none.rawValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Edit Playlist").font(.headline)
            HStack(alignment: .top, spacing: 24) {
                preview
                controls
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 640)
        .onAppear(perform: load)
        .task {
            let id = playlist.id ?? -1
            let tracks = (try? await model.database.writer.read { try LibraryDatabase.tracks($0, playlistId: id) }) ?? []
            var seen = Set<String>()
            songHashes = tracks.compactMap(\.artworkHash).filter { seen.insert($0).inserted }.prefix(4).map { $0 }
        }
    }

    private var preview: some View {
        VStack(spacing: 10) {
            PlaylistCoverView(name: name, cover: cover, songHashes: songHashes, seed: playlist.id ?? 0, cornerRadius: 12)
                .frame(width: 230, height: 230)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.brand, lineWidth: 3)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    return useImage(at: url)
                } isTargeted: { isDropTargeted = $0 }
            Text("Drop an image on the cover to use it")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
            Toggle("Show name on cover", isOn: $showsTitle)

            VStack(alignment: .leading, spacing: 8) {
                Text("Colors").font(.subheadline.weight(.semibold))
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 10), count: 6), alignment: .leading, spacing: 10) {
                    ForEach(CoverPalette.all) { palette in
                        let selected = isGenerated && generated.palette == palette.id
                        Button { kind = .generated(palette: palette.id, pattern: generated.pattern) } label: {
                            Circle()
                                .fill(palette.gradient)
                                .frame(width: 28, height: 28)
                                .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1))
                                .padding(3)
                                .overlay(Circle().strokeBorder(selected ? Color.brand : .clear, lineWidth: 2.5))
                        }
                        .buttonStyle(.plain)
                        .help(palette.name)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Style").font(.subheadline.weight(.semibold))
                HStack(spacing: 10) {
                    ForEach(CoverPattern.allCases) { pattern in
                        let selected = isGenerated && generated.pattern == pattern.rawValue
                        Button { kind = .generated(palette: generated.palette, pattern: pattern.rawValue) } label: {
                            VStack(spacing: 4) {
                                PlaylistCoverView(name: "", cover: PlaylistCover(kind: .generated(palette: generated.palette, pattern: pattern.rawValue)),
                                                  songHashes: [], seed: 0, cornerRadius: 6)
                                    .frame(width: 52, height: 52)
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.brand : .clear, lineWidth: 2.5)
                                        .padding(-3))
                                Text(pattern.name).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Other").font(.subheadline.weight(.semibold))
                HStack(spacing: 10) {
                    OptionTile(title: "Song Covers", isSelected: isSongCovers) {
                        if songHashes.isEmpty {
                            Image(systemName: "square.grid.2x2").font(.title3).foregroundStyle(.tertiary)
                        } else {
                            SongCoversMosaic(hashes: songHashes)
                        }
                    } action: {
                        kind = .songCovers
                    }
                    .disabled(songHashes.isEmpty)
                    .help(songHashes.isEmpty ? "The playlist's songs have no artwork yet" : "Use the covers of the playlist's songs")

                    OptionTile(title: imageHash == nil ? "Image…" : "Image", isSelected: imageHash != nil) {
                        if let imageHash {
                            ArtworkImage(hash: imageHash, size: .small, cornerRadius: 0)
                        } else {
                            Image(systemName: "photo.badge.plus").font(.title3).foregroundStyle(.secondary)
                        }
                    } action: {
                        chooseImage()
                    }
                    .help("Choose an image file (or drop one on the cover)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isSongCovers: Bool {
        if case .songCovers = kind { return true }
        return false
    }

    private var imageHash: String? {
        if case let .image(hash) = kind { return hash }
        return nil
    }

    private var isGenerated: Bool {
        if case .generated = kind { return true }
        return false
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        name = playlist.name
        if let saved = playlist.coverStyle {
            kind = saved.kind
            showsTitle = saved.showsTitle
        } else {
            kind = .songCovers
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image for the playlist cover."
        panel.prompt = "Use Image"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = useImage(at: url)
    }

    /// Copies the image into the artwork cache and selects it.
    @discardableResult
    private func useImage(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let hash = model.artwork.store(data) else {
            model.errorMessage = "\(url.lastPathComponent) is not an image Groovelight can read."
            return false
        }
        kind = .image(hash: hash)
        return true
    }

    private func save() {
        guard let id = playlist.id else { return }
        do {
            try model.database.updatePlaylist(id, name: name.trimmingCharacters(in: .whitespaces), cover: cover)
            dismiss()
        } catch {
            model.errorMessage = "Could not save the playlist: \(error.localizedDescription)"
        }
    }
}

/// A 52 pt selectable tile with a caption, matching the Style thumbnails.
private struct OptionTile<Content: View>: View {
    var title: String
    var isSelected: Bool
    @ViewBuilder var content: () -> Content
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                content()
                    .frame(width: 52, height: 52)
                    .background(.quaternary)
                    .clipShape(.rect(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.brand : .clear, lineWidth: 2.5)
                        .padding(-3))
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}
