import LibraryKit
import PlayerCore
import SwiftUI

/// Vertical track list used by album, playlist and artist pages.
struct TrackList: View {
    enum Style { case album, playlist }

    var tracks: [Track]
    var style: Style
    /// Show each row's format and resolution (used when an album mixes configurations).
    var showsQuality = false
    /// Tighter rows for small surfaces (the Shelf's flipped cover).
    var isCompact = false
    /// Album the list belongs to (album page, flipped Shelf cover): its songs' menus skip "Go to Album".
    var albumKey: String? = nil
    @Environment(AppModel.self) private var model
    @State private var selection: Set<Int64> = []

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(track: track, index: index, style: style, isSelected: selection.contains(track.id ?? -1),
                         showsQuality: showsQuality, isCompact: isCompact,
                         menuTracks: { selectedTracks(including: track) }, contextAlbumKey: albumKey) {
                    model.play(tracks, startAt: index)
                }
                    .contentShape(.rect)
                    .onTapGesture(count: 2) { model.play(tracks, startAt: index) }
                    .simultaneousGesture(TapGesture().onEnded {
                        if let id = track.id { selection = [id] }
                    })
                    .contextMenu { TrackContextMenu(tracks: selectedTracks(including: track), contextAlbumKey: albumKey) }
                    .draggable(TrackTransfer(id: track.id ?? 0))
                if index < tracks.count - 1 {
                    // Aligned with the title in both styles (padding + number column or cover + spacing).
                    Divider().padding(.leading, 56)
                }
            }
        }
    }

    private func selectedTracks(including track: Track) -> [Track] {
        guard let id = track.id, selection.contains(id), selection.count > 1 else { return [track] }
        return tracks.filter { selection.contains($0.id ?? -1) }
    }
}

struct TrackRow: View {
    var track: Track
    var index: Int
    var style: TrackList.Style
    var isSelected: Bool
    var showsQuality = false
    var isCompact = false
    /// Songs the "⋯" menu acts on: the multi-selection when this row is part of it, otherwise this song.
    var menuTracks: () -> [Track] = { [] }
    var contextAlbumKey: String? = nil
    /// Starts playback at this row (queueing the rest of the list).
    var onPlay: () -> Void
    @Environment(AppModel.self) private var model
    @State private var isHovering = false
    @State private var isHoveringPlayCell = false

    static let playCellWidth: CGFloat = 34
    static let rowLeadingPadding: CGFloat = 10

    private func playOrToggle(isCurrent: Bool) {
        if isCurrent { model.player.togglePlayPause() } else { onPlay() }
    }

    /// The play strip is an overlay with its own hover tracking; while the pointer is on it the row's own hover reports
    /// false, so the row counts as hovered when either one is.
    private var isRowHovered: Bool { isHovering || isHoveringPlayCell }

    /// Width of the leading play target: padding plus the number column (albums) or the song's cover (playlists).
    private var playTargetWidth: CGFloat {
        Self.rowLeadingPadding + (style == .album ? Self.playCellWidth : Self.artworkSize)
    }

    static let artworkSize: CGFloat = 34

    var body: some View {
        let isCurrent = model.player.current?.id == track.id
        let isPlaying = model.player.state == .playing
        HStack(spacing: 12) {
            // Icons only; the click target is the full-height leading strip overlaid on the row (see below).
            if style == .album {
                ZStack {
                    if isRowHovered {
                        Image(systemName: isCurrent && isPlaying ? "pause.fill" : "play.fill")
                            .foregroundStyle(isCurrent ? Color.brand : .primary)
                    } else if isCurrent {
                        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                            .foregroundStyle(Color.brand)
                            .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                    } else {
                        Text(track.trackNumber.map(String.init) ?? "")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12).monospacedDigit())
                .frame(width: Self.playCellWidth, height: 22)
                .background {
                    Circle()
                        .fill(.primary.opacity(isHoveringPlayCell ? 0.1 : 0))
                        .frame(width: 26, height: 26)
                }
            } else {
                // Playlists: play / pause (on hover) and the playing speaker sit on the song's cover.
                ArtworkImage(hash: track.artworkHash, size: .small, cornerRadius: 4)
                    .frame(width: Self.artworkSize, height: Self.artworkSize)
                    .overlay {
                        CoverPlayOverlay(isRowHovered: isRowHovered, isTargetHovered: isHoveringPlayCell,
                                         isCurrent: isCurrent, isPlaying: isPlaying)
                    }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: isCompact ? 12 : 13, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                if style == .playlist || (track.artist != nil && track.artist != track.albumArtist && track.albumArtist != nil) {
                    Text(style == .playlist ? "\(track.displayArtist) — \(track.displayAlbum)" : track.displayArtist)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if showsQuality {
                AudioQualityButton(track: track, isMini: true, isCompactText: true)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if track.isLoved {
                Image(systemName: "heart.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.pink)
            }
            Text(formatDuration(track.duration))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
            // Shown on hover like Apple Music; the space is always reserved so the duration does not shift.
            TrackMenuButton(tracks: menuTracks, contextAlbumKey: contextAlbumKey)
                .opacity(isRowHovered || isSelected ? 1 : 0)
        }
        .padding(.horizontal, Self.rowLeadingPadding)
        .padding(.vertical, isCompact ? 5 : (style == .album ? 9 : 6))
        .background(isSelected ? Color.brand.opacity(0.18) : (isRowHovered ? Color.primary.opacity(0.05) : .clear), in: .rect(cornerRadius: 6))
        .onHover { isHovering = $0 }
        // Play target: the row's whole leading strip (padding + icon column or cover, full row height). A real view rather
        // than an enlarged contentShape, which SwiftUI does not hit test outside the view's own frame. High priority
        // so it wins over the row's double-click, selection and drag gestures, and it works before hover registers.
        .overlay(alignment: .leading) {
            Color.clear
                .frame(width: playTargetWidth)
                .contentShape(.rect)
                .onHover { isHoveringPlayCell = $0 }
                .highPriorityGesture(TapGesture().onEnded { playOrToggle(isCurrent: isCurrent) })
                .help(isCurrent && isPlaying ? "Pause" : "Play")
                .accessibilityElement()
                .accessibilityLabel(isCurrent && isPlaying ? "Pause" : "Play \(track.title)")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { playOrToggle(isCurrent: isCurrent) }
                #if DEBUG
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    if let id = track.id { DebugHitTargets.playCells[id] = frame }
                }
                #endif
        }
    }
}

/// Play / pause and the playing speaker drawn over a song's cover (playlist rows, Up Next): play or pause while the row
/// is hovered, the animated speaker on the current song otherwise.
struct CoverPlayOverlay: View {
    var isRowHovered: Bool
    /// The pointer is on the play target itself: the scrim darkens a little.
    var isTargetHovered: Bool
    var isCurrent: Bool
    var isPlaying: Bool
    var cornerRadius: CGFloat = 4

    var body: some View {
        if isRowHovered || isCurrent {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.black.opacity(isTargetHovered ? 0.55 : 0.4))
                Group {
                    if isRowHovered {
                        Image(systemName: isCurrent && isPlaying ? "pause.fill" : "play.fill")
                    } else {
                        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                            .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            }
            .allowsHitTesting(false)
        }
    }
}

/// "⋯" button opening the same menu as a right click.
struct TrackMenuButton: View {
    var tracks: () -> [Track]
    var contextAlbumKey: String? = nil

    var body: some View {
        Menu {
            TrackContextMenu(tracks: tracks(), contextAlbumKey: contextAlbumKey)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            if let id = tracks().first?.id { DebugHitTargets.menuButtons[id] = frame }
        }
        #endif
    }
}

struct TrackContextMenu: View {
    var tracks: [Track]
    /// Album page the menu is shown on, if any: "Go to Album" is left out there.
    var contextAlbumKey: String? = nil
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Play") { model.play(tracks) }
        Button("Play Next") { model.playNext(tracks) }
        Button("Add to Up Next") { model.addToUpNext(tracks) }
        Divider()
        if tracks.count == 1, let track = tracks.first {
            Button(track.isLoved ? "Undo Love" : "Love") { model.toggleLoved(track) }
        }
        Menu("Add to Playlist") {
            Button("New Playlist") { model.newPlaylist(with: tracks) }
            Divider()
            ForEach(model.playlists.filter { !$0.isSmart }) { playlist in
                Button(playlist.name) { model.add(tracks, to: playlist) }
            }
        }
        Divider()
        // Only when every song shares the artist or album.
        if let artist = Set(tracks.map(\.artistPageName)).onlyElement, let artist {
            Button("Go to Artist") { model.showArtist(artist) }
        }
        if let albumKey = Set(tracks.map(\.albumKey)).onlyElement, albumKey != contextAlbumKey {
            Button("Go to Album") { model.showAlbum(albumKey: albumKey) }
        }
        Divider()
        Button("Get Info…") { model.getInfo(tracks) }
        if tracks.count == 1, let track = tracks.first {
            Button("Credits…") { model.creditsTrack = track }
        }
        Button("Fix Metadata…") { model.metadata.review(tracks) }
        Button("Show in Finder") { model.showInFinder(tracks) }
        SendToMenu(source: .tracks(tracks))
    }
}

extension Track {
    /// Name of the song's page under Artists (album artist first, as the Artists list groups them). Nil for
    /// compilations, which are not listed under an artist.
    var artistPageName: String? {
        guard !isCompilation else { return nil }
        for name in [albumArtist, artist] {
            if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        }
        return "Unknown Artist"
    }
}

extension Set {
    /// The element when the set has exactly one.
    var onlyElement: Element? { count == 1 ? first : nil }
}

/// "Play Next" and "Add to Up Next" for an album or playlist menu.
struct QueueMenuItems: View {
    var source: AppModel.SongSource
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { model.enqueue(source, next: true) }
        Button("Add to Up Next", systemImage: "text.line.last.and.arrowtriangle.forward") { model.enqueue(source, next: false) }
        SendToMenu(source: source.sendSource)
    }
}
