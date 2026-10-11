import PlayerCore
import SwiftUI

struct QueueView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let queue = model.player.queue
        let currentIndex = queue.currentIndex ?? -1
        // Headings are plain rows, not section headers: macOS pins section headers to the top of a scrolling list, and in
        // the inspector the pinned "Now Playing" sat in the toolbar area with a gap above its song.
        List {
            if let current = queue.current {
                QueueHeading(title: "Now Playing")
                QueueRow(item: current, isCurrent: true) { model.player.togglePlayPause() }
            }
            QueueHeading(title: "Up Next") {
                Button(model.player.isShuffled ? "Unshuffle" : "Shuffle") { model.player.setShuffle(!model.player.isShuffled) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            ForEach(Array(queue.items.enumerated()).filter { $0.offset > currentIndex }, id: \.offset) { offset, item in
                QueueRow(item: item, isCurrent: false) { model.player.jump(toQueueIndex: offset) }
                    .contentShape(.rect)
                    .onTapGesture(count: 2) { model.player.jump(toQueueIndex: offset) }
                    .contextMenu {
                        Button("Play") { model.player.jump(toQueueIndex: offset) }
                        Button("Remove from Up Next") { model.player.removeFromQueue(at: offset) }
                    }
            }
            .onMove { source, destination in
                let shift = currentIndex + 1
                model.player.moveInQueue(fromOffsets: IndexSet(source.map { $0 + shift }), toOffset: destination + shift)
            }
        }
        .overlay {
            if queue.items.isEmpty {
                ContentUnavailableView("Nothing Queued", systemImage: "list.bullet",
                                       description: Text("Play an album or use Play Next on a song."))
            }
        }
    }
}

/// Section title of the queue, as a regular (non-pinned) list row.
private struct QueueHeading<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .bold))
            Spacer()
            trailing()
        }
        .padding(.top, 8)
        .listRowSeparator(.hidden)
        .moveDisabled(true)
    }
}

extension QueueHeading where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

struct QueueRow: View {
    var item: PlayableItem
    var isCurrent: Bool
    /// Clicking the cover: jump to this song, or play / pause the current one.
    var onPlay: () -> Void
    @Environment(AppModel.self) private var model
    @State private var isHovering = false
    @State private var isHoveringCover = false

    var body: some View {
        let isPlaying = model.player.state == .playing
        // The cover has its own hover tracking; while the pointer is on it the row's reports false.
        let isRowHovered = isHovering || isHoveringCover
        HStack(spacing: 10) {
            // A real button: list rows (an NSTableView underneath) route a first click to buttons reliably, while a tap
            // gesture there could lose it to the table's own row tracking.
            Button(action: onPlay) {
                ArtworkImage(hash: item.artworkHash, size: .small, cornerRadius: 4)
                    .frame(width: 36, height: 36)
                    .overlay {
                        CoverPlayOverlay(isRowHovered: isRowHovered, isTargetHovered: isHoveringCover,
                                         isCurrent: isCurrent, isPlaying: isPlaying)
                    }
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { isHoveringCover = $0 }
            .help(isCurrent && isPlaying ? "Pause" : "Play")
            .accessibilityLabel(isCurrent && isPlaying ? "Pause" : "Play \(item.title)")
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                Text(item.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(formatDuration(item.duration))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            if !isCurrent { DebugHitTargets.queueRows[item.id] = frame }
        }
        #endif
    }
}
