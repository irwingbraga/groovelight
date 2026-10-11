import LibraryKit
import PlayerCore
import SwiftUI

/// Window toolbar: playback lives in the floating bar at the bottom, so only app-level tools stay here.
struct LibraryToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu("More", systemImage: "ellipsis") {
                Button("Visualizer", systemImage: "waveform") { openWindow.visualizer() }
                Button("Equalizer", systemImage: "slider.vertical.3") { openWindow(id: WindowID.equalizer) }
                Divider()
                Button("Add Music Folder…", systemImage: "folder.badge.plus") { model.chooseLibraryFolder() }
                Button("Rescan Library", systemImage: "arrow.clockwise") { model.rescanAll() }
            }
        }
    }
}

/// Thin progress bar that grows when hovered and can be dragged to seek.
struct ScrubBar: View {
    var value: Double
    var duration: Double
    var isActive: Bool
    var onChange: (Double, Bool) -> Void

    var body: some View {
        GeometryReader { geometry in
            let fraction = min(max(value / duration, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.15))
                Capsule().fill(.primary.opacity(0.7))
                    .frame(width: geometry.size.width * fraction)
            }
            .frame(height: isActive ? 5 : 3)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                onChange(min(max(drag.location.x / geometry.size.width, 0), 1) * duration, false)
            }.onEnded { drag in
                onChange(min(max(drag.location.x / geometry.size.width, 0), 1) * duration, true)
            })
            .animation(.snappy(duration: 0.15), value: isActive)
        }
    }
}

struct VolumeControl: View {
    @Environment(AppModel.self) private var model
    @State private var volumeBeforeMute: Float = 0.8

    var body: some View {
        @Bindable var player = model.player
        HStack(spacing: 6) {
            Button {
                if player.volume > 0 {
                    volumeBeforeMute = player.volume
                    player.volume = 0
                } else {
                    player.volume = max(volumeBeforeMute, 0.1)
                }
            } label: {
                Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.1.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(player.volume == 0 ? "Unmute" : "Mute")
            Slider(value: $player.volume, in: 0...1)
                .controlSize(.mini)
                .frame(width: 80)
        }
    }
}

/// Speaker button that opens a volume slider in a popover; used when the bar is too narrow for an inline slider.
struct VolumePopoverButton: View {
    @Environment(AppModel.self) private var model
    @State private var isShowingSlider = false

    var body: some View {
        @Bindable var player = model.player
        BarButton(systemImage: Self.symbol(for: player.volume), help: "Volume", isOn: isShowingSlider) {
            isShowingSlider.toggle()
        }
        .popover(isPresented: $isShowingSlider, arrowEdge: .top) {
            HStack(spacing: 10) {
                Button {
                    player.volume = player.volume == 0 ? 0.8 : 0
                } label: {
                    Image(systemName: Self.symbol(for: player.volume))
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .help(player.volume == 0 ? "Unmute" : "Mute")
                Slider(value: $player.volume, in: 0...1)
                    .frame(width: 160)
                Text("\(Int((player.volume * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            .padding(12)
        }
    }

    static func symbol(for volume: Float) -> String {
        switch volume {
        case 0: "speaker.slash.fill"
        case ..<0.34: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }
}
