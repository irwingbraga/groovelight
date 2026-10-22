import LibraryKit
import SwiftUI
import WirelessSync

/// Settings, Devices: the layout on every device, wireless sync with the Groovelight app on Android, and the
/// paired devices.
struct DevicesSettings: View {
    @Environment(AppModel.self) private var model
    @State private var layout = DeviceProfile()
    @State private var loaded = false

    var body: some View {
        @Bindable var wireless = model.wireless
        Form {
            DeviceLayoutSection(profile: $layout)
            Section {
                Toggle("Sync with Android devices over Wi-Fi", isOn: $wireless.isEnabled)
                if wireless.isEnabled {
                    LabeledContent("This Mac") {
                        Text(wireless.port == nil ? "Starting…" : WirelessSyncService.macName)
                            .foregroundStyle(.secondary)
                    }
                    if let port = wireless.port {
                        LabeledContent("Address") {
                            let addresses = WirelessSyncService.addresses
                            Text(addresses.isEmpty ? "Not on a network" : addresses.map { "\($0) port \(port)" }.joined(separator: ", "))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            } header: {
                Text("Wireless Sync")
            } footer: {
                Text("Install Groovelight for Android (attached to each release) on an Android 12 or later player or phone on the same Wi-Fi, open it and choose this Mac (or type the address above when it is not listed). Both screens show the same code: check it and allow the device here. Paired devices appear under Devices, with the same choices as memory cards, and sync whenever their app checks in.")
                    .foregroundStyle(.secondary)
            }
            if !wireless.paired.isEmpty {
                Section("Paired Devices") {
                    ForEach(wireless.paired) { device in
                        HStack {
                            Image(systemName: "smartphone")
                            VStack(alignment: .leading) {
                                Text(device.name)
                                Text(Self.detail(device, online: wireless.isOnline(device)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { wireless.unpair(device.id) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            layout = model.devices.layout
            loaded = true
        }
        .onChange(of: layout) { if loaded { model.devices.layout = layout } }
    }

    static func detail(_ device: WirelessSyncService.PairedDevice, online: Bool) -> String {
        var parts = [device.model, online ? "Online" : device.lastSeen.map { "Last seen " + $0.formatted(.relative(presentation: .named)) }]
        if let synced = device.lastSyncAt { parts.append("Synced " + synced.formatted(.relative(presentation: .named))) }
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

/// A device asks to pair: its name and the code, which must match the one on its screen.
struct PairingSheet: View {
    var prompt: WirelessSyncService.PairingPrompt
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "smartphone.radiowaves.left.and.right")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Pair with “\(prompt.request.name)”?")
                .font(.title2.bold())
            if let model = prompt.request.model {
                Text(model).foregroundStyle(.secondary)
            }
            Text(String(prompt.code.prefix(3)) + " " + String(prompt.code.suffix(3)))
                .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                .padding(.vertical, 6)
            Text("Allow it only if the device shows the same code. It will be able to download the music you choose for it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Don't Allow") { model.wireless.answerPairing(prompt, allow: false) }
                    .keyboardShortcut(.cancelAction)
                Button("Allow") { model.wireless.answerPairing(prompt, allow: true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 380)
    }
}
