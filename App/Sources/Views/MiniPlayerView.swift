import AppKit
import LibraryKit
import PlayerCore
import SwiftUI

/// Menu bar extra: the floating player bar's controls in a compact panel. Artwork, title and love; the scrubber with
/// elapsed and remaining time; the same transport row; volume, lyrics (in Now Playing), Up Next and the visualizer.
struct MiniPlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var scrubValue: Double?
    @State private var isHoveringScrubber = false
    @State private var track: Track?

    var body: some View {
        let player = model.player
        let item = player.current
        let time = scrubValue ?? player.currentTime
        VStack(spacing: 14) {
            header(item)

            VStack(spacing: 3) {
                ScrubBar(value: time, duration: max(player.duration, 1), isActive: isHoveringScrubber && item != nil) { value, done in
                    if done {
                        player.seek(to: value)
                        scrubValue = nil
                    } else {
                        scrubValue = value
                    }
                }
                .frame(height: 10)
                .onHover { isHoveringScrubber = $0 }
                .disabled(item == nil)
                HStack {
                    Text(item == nil ? "--:--" : formatDuration(time))
                    Spacer()
                    Text(item == nil ? "--:--" : "-" + formatDuration(max(0, player.duration - time)))
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            }

            TransportControls(density: .full)

            HStack(spacing: 10) {
                VolumeControl()
                Spacer(minLength: 0)
                // Lyrics open full size in Now Playing; a second click closes it. Up Next toggles the side panel.
                let isShowingLyrics = model.isShowingNowPlaying && model.isShowingLyrics
                BarButton(systemImage: "quote.bubble", help: "Lyrics", isOn: isShowingLyrics) {
                    if isShowingLyrics {
                        withAnimation(.smooth) { model.isShowingNowPlaying = false }
                    } else {
                        showMainWindow()
                        withAnimation(.smooth) {
                            model.isShowingLyrics = true
                            model.isShowingNowPlaying = true
                        }
                    }
                }
                BarButton(systemImage: "list.bullet", help: "Up Next", isOn: model.isShowingQueue) {
                    if !model.isShowingQueue { showMainWindow() }
                    model.isShowingQueue.toggle()
                }
                BarButton(systemImage: "waveform", help: "Visualizer") {
                    NSApp.activate()
                    openWindow.visualizer()
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .observing(model.database, id: item?.id, { [id = item?.id] db in
            guard let id else { return nil }
            return try Track.fetchOne(db, key: id)
        }) { track = $0 }
    }

    private func header(_ item: PlayableItem?) -> some View {
        HStack(spacing: 12) {
            Button {
                showMainWindow()
                withAnimation(.smooth) { model.isShowingNowPlaying = true }
            } label: {
                ArtworkImage(hash: item?.artworkHash, size: .small, cornerRadius: 8)
                    .frame(width: 60, height: 60)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            }
            .buttonStyle(.plain)
            .disabled(item == nil)
            .help("Show Now Playing")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item?.title ?? "Not Playing")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item == nil ? .secondary : .primary)
                    if let track, track.id == item?.id, track.audioSpec.tier.hasBadge {
                        AudioQualityButton(track: track, showsText: false, isMini: true)
                    }
                }
                if let item {
                    Text(item.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(item.album)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            BarButton(systemImage: track?.isLoved == true ? "heart.fill" : "heart", help: "Love",
                      isOn: track?.isLoved == true, onColor: .pink) {
                if let track { model.toggleLoved(track) }
            }
            .disabled(track == nil)
        }
    }

    private func showMainWindow() { openWindow.mainWindow() }
}

extension View {
    /// Liquid Glass for the menu bar panel: the content gets a glass background and the panel window's own opaque
    /// material is removed, so the desktop shows through the glass.
    func menuBarGlass() -> some View {
        background(TransparentWindow())
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

/// Clears the hosting window: transparent background, and the window's material views hidden (or, when one wraps the
/// SwiftUI content, replaced by the content itself).
private struct TransparentWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Configurator() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Configurator: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.configure() }
        }

        private func configure() {
            guard let window, let frame = window.contentView?.superview ?? window.contentView else { return }
            // The outermost SwiftUI hosting view holding this panel's content.
            var host: NSView?
            var view = superview
            while let current = view {
                if String(describing: type(of: current)).contains("HostingView") { host = current }
                view = current.superview
            }
            guard let host else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            // AppKit's window materials: NSVisualEffectView, or the private BackdropView of titled windows.
            let materials = Self.descendants(of: frame).filter { view in
                view is NSVisualEffectView || String(describing: type(of: view)).contains("Backdrop")
            }
            for effect in materials where !effect.isDescendant(of: host) {
                if host.isDescendant(of: effect), window.contentView === effect {
                    host.removeFromSuperview()
                    window.contentView = host
                } else {
                    effect.isHidden = true
                }
            }
            window.invalidateShadow()
        }

        private static func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
    }
}
