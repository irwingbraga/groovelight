import LibraryKit
import PlayerCore
import SwiftUI

/// Apple Music style floating player: a Liquid Glass capsule above the bottom of the content.
///
/// Three columns: transport (leading), now playing (centered), tools (trailing). The side columns share the leftover
/// width equally, so the now-playing column stays centered in the bar whatever the window width. `ViewThatFits` drops
/// controls as the content column narrows.
///
/// The bar sits inside a fixed-height `GeometryReader`, whose size never depends on its content. Without that, the bar's
/// content-driven minimum width fed back into the split view while the Up Next inspector opened in a small window,
/// and AppKit aborted after endless constraint update passes.
struct FloatingPlayerBar: View {
    @State private var isHovering = false

    enum Density { case full, medium, compact }

    static let maxWidth: CGFloat = 980
    /// The bar with its bottom margin: the room a page keeps for it.
    static let height: CGFloat = 76

    var body: some View {
        GeometryReader { geometry in
            ViewThatFits(in: .horizontal) {
                row(.full)
                row(.medium)
                row(.compact)
            }
            // Grows with the window up to a comfortable width, then stays centered (a maximized window would stretch it).
            .frame(width: min(max(geometry.size.width - 32, 0), Self.maxWidth), height: 64)
            .clipped()
            .playerBarBackground()
            .onHover { isHovering = $0 }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 64)
        .padding(.bottom, 12)
    }

    private func row(_ density: Density) -> some View {
        HStack(spacing: density == .compact ? 10 : 16) {
            if density != .compact {
                TransportControls(density: density)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            NowPlayingSummary(isHovering: isHovering, density: density)
                .frame(minWidth: density == .compact ? 120 : 240,
                       idealWidth: density == .full ? 340 : 240,
                       maxWidth: 520)
                .layoutPriority(1)

            PlayerTools(density: density)
                .fixedSize()
                .frame(maxWidth: density == .compact ? nil : .infinity, alignment: .trailing)
        }
        .padding(.leading, density == .compact ? 10 : 18)
        .padding(.trailing, 14)
    }
}

struct TransportControls: View {
    var density: FloatingPlayerBar.Density
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        HStack(spacing: density == .full ? 18 : 12) {
            if density == .full {
                BarButton(systemImage: "shuffle", help: "Shuffle" + model.shortcuts.hint(.shuffle), isOn: player.isShuffled) {
                    player.setShuffle(!player.isShuffled)
                }
            }
            BarButton(systemImage: "backward.fill", help: "Previous" + model.shortcuts.hint(.previous), size: 17) { player.previous() }
            BarButton(systemImage: player.state == .playing ? "pause.fill" : "play.fill",
                      help: player.state == .playing ? "Pause" : "Play", size: 24) {
                player.togglePlayPause()
            }
            .frame(width: 28)
            BarButton(systemImage: "forward.fill", help: "Next" + model.shortcuts.hint(.next), size: 17) { player.next() }
            if density == .full {
                BarButton(systemImage: player.repeatMode == .one ? "repeat.1" : "repeat", help: "Repeat" + model.shortcuts.hint(.cycleRepeat), isOn: player.repeatMode != .off) {
                    player.repeatMode = switch player.repeatMode {
                    case .off: .all
                    case .all: .one
                    case .one: .off
                    }
                }
            }
        }
    }
}

/// Artwork, centered title and subtitle, and a scrubber with elapsed / remaining time. A love button on the right
/// balances the artwork on the left so the text is centered in the column.
private struct NowPlayingSummary: View {
    var isHovering: Bool
    var density: FloatingPlayerBar.Density
    @Environment(AppModel.self) private var model
    @State private var scrubValue: Double?
    @State private var track: Track?

    var body: some View {
        let player = model.player
        let item = player.current
        let time = scrubValue ?? player.currentTime
        HStack(spacing: 12) {
            Button {
                withAnimation(.smooth) { model.isShowingNowPlaying = true }
            } label: {
                ArtworkImage(hash: item?.artworkHash, size: .small, cornerRadius: 6)
                        .frame(width: 44, height: 44)
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .disabled(item == nil)
            .help("Show Now Playing" + model.shortcuts.hint(.nowPlaying))

            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Text(item?.title ?? "Not Playing")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item == nil ? .secondary : .primary)
                    if density != .compact, let track, track.id == item?.id, track.audioSpec.tier.hasBadge {
                        AudioQualityButton(track: track, showsText: false, isMini: true)
                    }
                }
                // Artist and album link to their pages, like in Now Playing (once the library track is loaded).
                HStack(spacing: 4) {
                    if let item {
                        let current = track?.id == item.id ? track : nil
                        LinkText(text: item.artist, help: "Go to \(item.artist)", action: current?.artistPageName.map { name in
                            { model.showArtist(name) }
                        })
                        .layoutPriority(1)
                        Text("—")
                        LinkText(text: item.album, help: "Go to \(item.album)", action: current.map { track in
                            { model.showAlbum(albumKey: track.albumKey) }
                        })
                    } else {
                        Text(" ")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if density != .compact {
                        Text(item == nil ? "" : formatDuration(time))
                            .frame(width: 38, alignment: .trailing)
                    }
                    ScrubBar(value: time, duration: max(player.duration, 1), isActive: isHovering && item != nil) { value, done in
                        if done {
                            player.seek(to: value)
                            scrubValue = nil
                        } else {
                            scrubValue = value
                        }
                    }
                    .frame(height: 10)
                    .disabled(item == nil)
                    if density != .compact {
                        Text(item == nil ? "" : "-" + formatDuration(max(0, player.duration - time)))
                            .frame(width: 38, alignment: .leading)
                    }
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity)

            if density != .compact {
                BarButton(systemImage: track?.isLoved == true ? "heart.fill" : "heart", help: "Love" + model.shortcuts.hint(.love),
                          isOn: track?.isLoved == true, onColor: .pink) {
                    if let track { model.toggleLoved(track) }
                }
                .frame(width: 44)
                .disabled(track == nil)
            }
        }
        .observing(model.database, id: item?.id, { [id = item?.id] db in
            guard let id else { return nil }
            return try Track.fetchOne(db, key: id)
        }) { track = $0 }
    }
}

private struct PlayerTools: View {
    var density: FloatingPlayerBar.Density
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        HStack(spacing: density == .full ? 16 : 10) {
            switch density {
            case .full:
                VolumeControl()
            case .medium:
                VolumePopoverButton()
            case .compact:
                VolumePopoverButton()
                BarButton(systemImage: player.state == .playing ? "pause.fill" : "play.fill",
                          help: player.state == .playing ? "Pause" : "Play", size: 20) {
                    player.togglePlayPause()
                }
                BarButton(systemImage: "forward.fill", help: "Next" + model.shortcuts.hint(.next), size: 15) { player.next() }
            }
            PlaybackExtras()
            // Lyrics open in the side panel, like Up Next (Now Playing keeps its own lyrics button). The compact bar has
            // room for one of the two: the button of the panel that is open, so it can still be closed from here.
            if density != .compact || model.isShowingLyricsPanel {
                BarButton(systemImage: "quote.bubble", help: "Lyrics" + model.shortcuts.hint(.lyrics), isOn: model.isShowingLyricsPanel) {
                    model.isShowingLyricsPanel.toggle()
                }
            }
            if density != .compact || !model.isShowingLyricsPanel {
                BarButton(systemImage: "list.bullet", help: "Up Next" + model.shortcuts.hint(.upNext), isOn: model.isShowingQueue) {
                    model.isShowingQueue.toggle()
                }
            }
        }
    }
}

/// Shown in the bar only while active: the playback speed when it is not normal, and the sleep timer. Each opens a menu.
private struct PlaybackExtras: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        if player.rate != 1, !player.bitPerfect {
            Menu {
                ForEach(PlaybackPrefs.speeds, id: \.self) { speed in
                    Button(PlaybackPrefs.speedLabel(speed)) { model.setRate(speed) }
                }
            } label: {
                Text(PlaybackPrefs.speedLabel(player.rate))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.brand)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Playback speed")
        }
        if let timer = model.sleepTimer, timer.isActive {
            Menu {
                Text(timer.summary ?? "")
                Button("Turn Off Sleep Timer") { timer.cancel() }
            } label: {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.brand)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sleep timer: " + (timer.summary ?? ""))
        }
    }
}

/// Borderless icon button used inside the glass bar, with a hover highlight and an "on" tint for toggles.
struct BarButton: View {
    var systemImage: String
    var help: String
    var size: CGFloat = 14
    var isOn = false
    var onColor: Color = .brand
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(isOn ? onColor : .primary)
                .frame(minWidth: 26, minHeight: 26)
                .background(Circle().fill(.primary.opacity(isHovering ? 0.08 : 0)))
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
    }
}

extension View {
    /// Floats the player bar over the bottom of a page; scroll views run underneath the glass.
    /// Applied per page (root and every pushed destination): on macOS a pushed `NavigationStack` page is drawn over
    /// an inset attached to the stack itself, which hid the bar on album pages.
    /// The page fills the column first, so the bar stays at the bottom of the window even when the page is smaller
    /// (before macOS 26 a `ContentUnavailableView` is only as tall as its text).
    func playerBarInset() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PageBottomBar()
            }
    }

    /// The list column of Artists and Genres: it reports where it is, and keeps room at its bottom for the bar that
    /// spans it and the page.
    func playerBarListColumn() -> some View {
        modifier(ListColumnBarSpace())
    }

    /// Liquid Glass capsule that follows the system appearance; falls back to an opaque, outlined capsule when
    /// Reduce Transparency is on, and adds a stronger outline with Increase Contrast.
    func playerBarBackground() -> some View {
        modifier(PlayerBarBackground())
    }
}

private struct PlayerBarBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var reduceTransparency: Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "GLDebugReduceTransparency") { return true }
        #endif
        return systemReduceTransparency
    }

    func body(content: Content) -> some View {
        Group {
            if reduceTransparency {
                content
                    .background(Color(nsColor: .windowBackgroundColor), in: .capsule)
                    .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            } else {
                content
                    .glassBackground(in: .capsule)
            }
        }
        .overlay {
            if contrast == .increased {
                Capsule().strokeBorder(.primary.opacity(0.5), lineWidth: 1)
            }
        }
    }
}

extension AppModel {
    /// Artists and Genres show a list column between the sidebar and the page.
    var hasListColumn: Bool { selection == .artists || selection == .genres }
}

/// Where the bar goes on pages with a list column (Artists, Genres): across the list and the page, centered on both.
/// The columns are separate AppKit views, so the bar floats above the split view (`SpanningPlayerBar`) instead of
/// inside the page, where it would be clipped and lose clicks over the list.
@MainActor @Observable
final class PlayerBarSpan {
    /// Frames in the window, set by the list column and the page.
    var listFrame: CGRect?
    var pageFrame: CGRect?
}

/// The bar at the bottom of a page, or, next to a list column, the room the spanning bar takes.
private struct PageBottomBar: View {
    @Environment(PlayerBarSpan.self) private var span: PlayerBarSpan?
    @Environment(AppModel.self) private var model

    var body: some View {
        if let span, model.hasListColumn {
            Color.clear
                .frame(height: FloatingPlayerBar.height)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { span.pageFrame = $0 }
        } else {
            FloatingPlayerBar()
        }
    }
}

private struct ListColumnBarSpace: ViewModifier {
    @Environment(PlayerBarSpan.self) private var span: PlayerBarSpan?

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: FloatingPlayerBar.height)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { span?.listFrame = $0 }
    }
}

/// The bar across the list column and the page, laid over the whole split view.
struct SpanningPlayerBar: View {
    @Environment(PlayerBarSpan.self) private var span
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.hasListColumn, let list = span.listFrame, let page = span.pageFrame, page.maxX > list.minX {
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                FloatingPlayerBar()
                    .frame(width: page.maxX - list.minX)
                    .offset(x: list.minX - origin.x, y: page.maxY - origin.y - FloatingPlayerBar.height)
            }
        }
    }
}
