import SwiftUI
import UIKit
import WirelessSync

/// Where music plays: this device, the paired Mac, or another phone with Groovelight open. A button (a speaker, filled
/// while music plays elsewhere) opening a small list; choosing another one takes what plays along.
struct PlaybackTargetButton: View {
    @Environment(AppModel.self) private var model
    @State private var choosing = false

    var body: some View {
        if model.sync.isPaired {
            Button { choosing = true } label: {
                Label(model.isRemote ? "Playing on \(model.targetName)" : "Play On",
                      systemImage: model.isRemote ? "hifispeaker.fill" : "hifispeaker")
            }
            .popover(isPresented: $choosing) {
                PlaybackTargetList { choosing = false }
                    .frame(idealWidth: 320)
                    .presentationCompactAdaptation(.popover)
            }
            #if DEBUG
            // `-GLDebugOpenPicker YES` opens it once the button is on screen, for screenshots.
            .task {
                guard UserDefaults.standard.bool(forKey: "GLDebugOpenPicker") else { return }
                try? await Task.sleep(for: .seconds(1.5))
                choosing = true
            }
            #endif
        }
    }
}

/// This device, the Mac and the other devices there, with why they cannot be chosen when they cannot.
struct PlaybackTargetList: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void
    @State private var moving = false

    var body: some View {
        let remote = model.remote
        VStack(alignment: .leading, spacing: 0) {
            Text("Play On").font(.headline).padding([.horizontal, .top]).padding(.bottom, 8)
            row(UIDevice.current.model == "iPad" ? "This iPad" : "This iPhone",
                systemImage: UIDevice.current.model == "iPad" ? "ipad" : "iphone", target: .thisDevice, enabled: true)
            Divider().padding(.leading, 52)
            row(remote.macName ?? "Mac", systemImage: "desktopcomputer", target: .mac, enabled: remote.availability == .available)
            ForEach(otherDevices, id: \.id) { device in
                Divider().padding(.leading, 52)
                row(device.name, systemImage: Self.symbol(for: device.name), target: .device(device), enabled: true)
            }
            Group {
                switch remote.availability {
                case .checking, .unknown:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for \(remote.macName ?? "the Mac")…")
                    }
                case .notAllowed:
                    Text("Turn on “Let \(UIDevice.current.name) play music on this Mac and your other devices” on this device's page under Devices on the Mac.")
                case .unreachable:
                    Text("Open Groovelight on the Mac, on the same Wi-Fi as this device.")
                case .available:
                    EmptyView()
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .disabled(moving)
        .task { await model.remote.check() }
    }

    /// The devices there now, and the one music plays on even if it has just gone.
    private var otherDevices: [WirelessProtocol.RemoteDevice] {
        var devices = model.remote.devices
        if case .device(let current) = model.target, !devices.contains(where: { $0.id == current.id }) { devices.append(current) }
        return devices
    }

    /// An iPad, an iPhone, or (Android) a phone, from what the device calls itself.
    static func symbol(for name: String) -> String {
        name.localizedCaseInsensitiveContains("ipad") ? "ipad" : name.localizedCaseInsensitiveContains("iphone") ? "iphone" : "smartphone"
    }

    private func row(_ name: String, systemImage: String, target: AppModel.Target, enabled: Bool) -> some View {
        Button {
            moving = true
            Task {
                await model.choose(target)
                moving = false
                close()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage).font(.title3).frame(width: 28)
                Text(name)
                Spacer()
                if moving, model.target != target, enabled {
                    ProgressView().controlSize(.small)
                } else if model.target == target {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}
