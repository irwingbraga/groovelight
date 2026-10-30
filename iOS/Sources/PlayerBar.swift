import AVKit
import SwiftUI

/// The Mac's floating player bar, over the page beside the sidebar: a glass capsule with the transport (shuffle,
/// previous, play, next, repeat) on the leading side, the song in the middle (cover, title, artist and album, where it
/// is), and the tools on the trailing side (lyrics, Play On, AirPlay). Controls drop out as the page narrows, as on the
/// Mac; "Not Playing" when nothing plays.
struct PlayerBar: View {
    enum Density { case full, medium, compact }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(.full)
            row(.medium)
            row(.compact)
        }
        .frame(maxWidth: 980)
        .frame(height: 64)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func row(_ density: Density) -> some View {
        HStack(spacing: density == .compact ? 10 : 16) {
            if density != .compact {
                BarTransport(density: density)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            BarNowPlaying(density: density)
                .frame(minWidth: density == .compact ? 160 : 240, idealWidth: density == .full ? 340 : 260, maxWidth: 520)
                .layoutPriority(1)
            BarTools(density: density)
                .fixedSize()
                .frame(maxWidth: density == .compact ? nil : .infinity, alignment: .trailing)
        }
        .padding(.leading, density == .compact ? 10 : 20)
        .padding(.trailing, 16)
    }
}

/// A bar button: a symbol, tinted when its mode is on (shuffle, repeat), as on the Mac.
private struct BarButton: View {
    let title: String
    let systemImage: String
    var size: CGFloat = 17
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(isOn ? Color.accentColor : .primary)
                .frame(minWidth: 28, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct BarTransport: View {
    @Environment(AppModel.self) private var model
    let density: PlayerBar.Density

    var body: some View {
        let playing = model.nowPlaying?.isPlaying == true
        HStack(spacing: density == .full ? 16 : 10) {
            if density == .full {
                BarButton(title: "Shuffle", systemImage: "shuffle", size: 15, isOn: model.isShuffled) { model.toggleShuffle() }
            }
            BarButton(title: "Previous", systemImage: "backward.fill") { model.previous() }
            BarButton(title: playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill", size: 24) { model.togglePlayPause() }
            BarButton(title: "Next", systemImage: "forward.fill") { model.next() }
            if density == .full {
                BarButton(title: "Repeat", systemImage: model.repeatMode == .one ? "repeat.1" : "repeat", size: 15,
                          isOn: model.repeatMode != .off) { model.cycleRepeat() }
            }
        }
        .disabled(model.nowPlaying == nil)
    }
}

/// The cover (opens Now Playing), the title, "artist — album" and where the song is.
private struct BarNowPlaying: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window
    let density: PlayerBar.Density

    var body: some View {
        let item = model.nowPlaying
        HStack(spacing: 12) {
            Button { window.isShowingNowPlaying = true } label: {
                Cover(hash: item?.artworkHash, size: 44, corner: 6)
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            .disabled(item == nil)
            .accessibilityLabel("Show Now Playing")
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Text(item?.title ?? "Not Playing")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(item == nil ? .secondary : .primary)
                        .lineLimit(1)
                    if density != .compact, let tier = item?.spec?.tier { QualityBadge(tier: tier, isMini: true) }
                }
                if let item {
                    Group {
                        if model.isRemote {
                            Text("\(Image(systemName: "hifispeaker.fill")) \(model.targetName) — \(item.artist)")
                        } else {
                            // Each part opens its page, as on the Mac's bar.
                            SongLinks(item: item, oneLine: true)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    BarProgress()
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            .onTapGesture { if item != nil { window.isShowingNowPlaying = true } }
            if density == .compact, let item {
                BarButton(title: item.isPlaying ? "Pause" : "Play", systemImage: item.isPlaying ? "pause.fill" : "play.fill", size: 20) {
                    model.togglePlayPause()
                }
                BarButton(title: "Next", systemImage: "forward.fill", size: 15) { model.next() }
            }
        }
    }
}

/// A thin line for where the song is, with the elapsed and remaining time at its ends, as on the Mac.
private struct BarProgress: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let duration = model.duration.isFinite ? max(model.duration, 1) : 1
            // Before a song starts, and for a player elsewhere (its time is estimated with this device's clock), the time
            // can fall outside the song.
            let raw = model.time(at: context.date)
            let time = raw.isFinite ? min(max(raw, 0), duration) : 0
            HStack(spacing: 6) {
                Text(Scrubber.format(time))
                ProgressView(value: time, total: duration)
                    .progressViewStyle(.linear)
                    .tint(.secondary)
                Text("-" + Scrubber.format(max(duration - time, 0)))
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

/// Lyrics (in Now Playing), Play On and AirPlay.
private struct BarTools: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowModel.self) private var window
    let density: PlayerBar.Density

    var body: some View {
        HStack(spacing: density == .full ? 14 : 8) {
            if density != .compact {
                BarButton(title: "Lyrics", systemImage: "quote.bubble", size: 16) { window.isShowingNowPlaying = true }
                    .disabled(model.nowPlaying == nil)
            }
            PlaybackTargetButton()
                .buttonStyle(.plain)
                .labelStyle(.iconOnly)
                .font(.system(size: 16, weight: .medium))
            AirPlayButton()
                .frame(width: 28, height: 28)
        }
    }
}

/// The system's AirPlay route picker.
struct AirPlayButton: UIViewRepresentable {
    /// The icon's color (the label color, or a player's ink over its aluminum caps).
    var tint: UIColor = .label

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = tint
        picker.activeTintColor = .tintColor
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
