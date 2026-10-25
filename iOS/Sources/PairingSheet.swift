import SwiftUI
import WirelessSyncClient

/// Pairing with Groovelight on the Mac: the Macs found on the network (or an address typed in), then the code to compare
/// with the one the Mac shows, until the Mac allows this device.
struct PairingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var flow: PairingFlow?
    @State private var macs: [FoundMac] = []
    @State private var address = ""

    var body: some View {
        NavigationStack {
            Group {
                if let flow, flow.step != .idle {
                    PairingProgress(flow: flow) { dismiss() }
                } else {
                    chooser
                }
            }
            .navigationTitle("Pair with Your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { flow?.cancel(); dismiss() } label: { Label("Cancel", systemImage: "xmark") }
                }
            }
        }
        .task {
            for await found in MacBrowser.macs() { macs = found }
        }
        .onAppear { if flow == nil { flow = PairingFlow(sync: model.sync) } }
    }

    private var chooser: some View {
        Form {
            Section {
                if macs.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Looking for Groovelight on this network…").foregroundStyle(.secondary)
                    }
                }
                ForEach(macs) { mac in
                    Button { flow?.start(host: mac.host, port: mac.port, name: mac.name) } label: {
                        Label(mac.name, systemImage: "desktopcomputer")
                    }
                }
            } header: {
                Text("Macs")
            } footer: {
                Text("Open Groovelight on your Mac and turn on wireless sync in Settings, Devices. This device needs to be on the same Wi-Fi.")
            }
            Section("Or type its address") {
                TextField("192.168.1.20:52300", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit(connectToAddress)
                Button("Connect", action: connectToAddress)
                    .disabled(Self.parse(address) == nil)
            }
        }
    }

    private func connectToAddress() {
        guard let (host, port) = Self.parse(address) else { return }
        flow?.start(host: host, port: port, name: host)
    }

    /// "host:port" (the Mac's Settings show both).
    static func parse(_ text: String) -> (String, Int)? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]), port > 0, port < 65536 else { return nil }
        let host = String(text[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host.isEmpty ? nil : (host, port)
    }
}

/// The code to check on both screens, and what happens next.
struct PairingProgress: View {
    let flow: PairingFlow
    let close: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            switch flow.step {
            case .idle:
                EmptyView()
            case .connecting(let name):
                ProgressView()
                Text("Connecting to \(name)…").foregroundStyle(.secondary)
            case let .confirm(code, macName):
                Text("Check that \(macName) shows this code, then allow this device there.")
                    .multilineTextAlignment(.center)
                Text(code.prefix(3) + " " + code.suffix(3))
                    .font(.system(size: 52, weight: .semibold, design: .rounded).monospacedDigit())
                    .accessibilityLabel(code.map(String.init).joined(separator: " "))
                ProgressView()
            case .done(let name):
                Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
                Text("Paired with \(name). The first sync has started.").multilineTextAlignment(.center)
                Button("Done", action: close).buttonStyle(.glassProminent)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 48)).foregroundStyle(.orange)
                Text(message).multilineTextAlignment(.center)
                Button("Try Again") { flow.cancel() }.buttonStyle(.glass)
            }
        }
        .padding(32)
        .frame(maxWidth: 480, maxHeight: .infinity)
    }
}
