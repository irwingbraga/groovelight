import PlayerCore
import SwiftUI
import UniformTypeIdentifiers

/// The Mac's 15-band parametric equalizer: on or off, a preset, its curve, and each band's gain (a tap on a band for its
/// type, frequency and width). Presets saved here, and AutoEq or Equalizer APO files (ParametricEQ.txt) imported.
struct EqualizerScreen: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Int?
    @State private var isNaming = false
    @State private var name = ""
    @State private var isImporting = false
    @State private var importFailed = false

    var body: some View {
        let store = model.player.equalizer
        @Bindable var bindable = store
        List {
            Section {
                Toggle("Equalizer", isOn: $bindable.isEnabled)
                Picker("Preset", selection: Binding(get: { store.preset.name }, set: { name in
                    if let preset = store.allPresets.first(where: { $0.name == name }) { store.select(preset) }
                })) {
                    if !store.allPresets.contains(where: { $0.name == store.preset.name }) {
                        Text(store.preset.name).tag(store.preset.name)
                    }
                    Section("Built In") { ForEach(EQPreset.builtIns) { Text($0.name).tag($0.name) } }
                    if !store.userPresets.isEmpty {
                        Section("Yours") { ForEach(store.userPresets) { Text($0.name).tag($0.name) } }
                    }
                }
            }
            Section {
                EQCurve(preset: store.preset)
                    .frame(height: 160)
                    .opacity(store.isEnabled ? 1 : 0.45)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            }
            Section {
                ForEach(Array(store.preset.bands.enumerated()), id: \.offset) { index, band in
                    BandRow(index: index, band: band) { editing = index }
                }
            } header: {
                Text("Bands")
            } footer: {
                Text("Tap a band's frequency for its type and width.")
            }
            Section {
                Toggle("Auto Preamp", isOn: $bindable.autoPreamp)
                HStack {
                    Text("Preamp")
                    Slider(value: Binding(get: { store.preset.preamp }, set: { store.setPreamp($0) }), in: -24...12)
                    Text(String(format: "%+.1f dB", store.preset.preamp)).monospacedDigit().foregroundStyle(.secondary)
                }
            } footer: {
                Text("Auto Preamp lowers the level by the largest boost, so the equalizer never clips.")
            }
        }
        .navigationTitle("Equalizer")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Save Preset…", systemImage: "square.and.arrow.down") {
                        name = store.preset.name == "Custom" ? "" : store.preset.name
                        isNaming = true
                    }
                    if store.userPresets.contains(where: { $0.name == store.preset.name }) {
                        Button("Delete Preset", systemImage: "trash", role: .destructive) { store.deleteUserPreset(store.preset) }
                    }
                    Button("Import AutoEq File…", systemImage: "square.and.arrow.up.on.square") { isImporting = true }
                    Button("Reset to Flat", systemImage: "arrow.counterclockwise") { store.reset() }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .sheet(item: Binding(get: { editing.map(EditedBand.init) }, set: { editing = $0?.id })) { edited in
            BandEditor(index: edited.id)
                .presentationDetents([.medium])
        }
        .alert("Save Preset", isPresented: $isNaming) {
            TextField("Name", text: $name)
            Button("Save") {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { store.saveCurrent(as: trimmed) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.plainText]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do { try store.importParametricEQ(from: url) } catch { importFailed = true }
        }
        .alert("Not a ParametricEQ File", isPresented: $importFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Groovelight reads the ParametricEQ.txt files AutoEq and Equalizer APO make.")
        }
    }

    private struct EditedBand: Identifiable {
        let id: Int
    }
}

/// A band: its frequency (a tap edits it), its gain as a slider, and the gain.
private struct BandRow: View {
    @Environment(AppModel.self) private var model
    let index: Int
    let band: EQBand
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: edit) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(EQCurve.frequencyText(band.frequency)).monospacedDigit()
                    if band.type != .peak || !band.isEnabled {
                        Text(band.isEnabled ? band.type.displayName : "Off").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 64, alignment: .leading)
            }
            .buttonStyle(.borderless)
            Slider(value: Binding(get: { band.gain }, set: { gain in model.player.equalizer.updateBand(index) { $0.gain = gain.rounded(toPlaces: 1) } }),
                   in: EQMath.gainRange)
                .disabled(!band.isEnabled || !band.type.usesGain)
            Text(String(format: "%+.1f", band.gain)).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(EQCurve.frequencyText(band.frequency)) band")
    }
}

/// One band in full: on or off, its type, frequency, gain and width (Q).
private struct BandEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let index: Int

    var body: some View {
        let store = model.player.equalizer
        let band = store.preset.bands[index]
        NavigationStack {
            Form {
                Toggle("On", isOn: Binding(get: { band.isEnabled }, set: { on in store.updateBand(index) { $0.isEnabled = on } }))
                Picker("Type", selection: Binding(get: { band.type }, set: { type in store.updateBand(index) { $0.type = type } })) {
                    ForEach(EQFilterType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                LabeledContent("Frequency") {
                    // Moved on a log scale, as the ear hears it.
                    Slider(value: Binding(get: { log10(band.frequency) }, set: { value in
                        store.updateBand(index) { $0.frequency = Self.round(pow(10, value)) }
                    }), in: log10(EQMath.frequencyRange.lowerBound)...log10(EQMath.frequencyRange.upperBound))
                    Text(EQCurve.frequencyText(band.frequency)).monospacedDigit().frame(width: 72, alignment: .trailing)
                }
                if band.type.usesGain {
                    LabeledContent("Gain") {
                        Slider(value: Binding(get: { band.gain }, set: { gain in store.updateBand(index) { $0.gain = gain.rounded(toPlaces: 1) } }),
                               in: EQMath.gainRange)
                        Text(String(format: "%+.1f dB", band.gain)).monospacedDigit().frame(width: 72, alignment: .trailing)
                    }
                }
                LabeledContent("Width (Q)") {
                    Slider(value: Binding(get: { log10(band.q) }, set: { value in store.updateBand(index) { $0.q = pow(10, value).rounded(toPlaces: 2) } }),
                           in: log10(EQMath.qRange.lowerBound)...log10(EQMath.qRange.upperBound))
                    Text(String(format: "%.2f", band.q)).monospacedDigit().frame(width: 72, alignment: .trailing)
                }
            }
            .navigationTitle("\(EQCurve.frequencyText(band.frequency)) Band")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    /// Whole hertz below 1 kHz, tens above.
    static func round(_ frequency: Double) -> Double {
        frequency < 1000 ? frequency.rounded() : (frequency / 10).rounded() * 10
    }
}

/// The preset's response, on a log frequency scale from 20 Hz to 20 kHz, with the 0 dB line.
struct EQCurve: View {
    let preset: EQPreset

    var body: some View {
        Canvas { context, size in
            let range = 18.0
            func y(_ db: Double) -> CGFloat { size.height / 2 - CGFloat(max(min(db, range), -range) / range) * (size.height / 2 - 4) }
            let low = log10(EQMath.frequencyRange.lowerBound), high = log10(EQMath.frequencyRange.upperBound)
            func x(_ frequency: Double) -> CGFloat { CGFloat((log10(frequency) - low) / (high - low)) * size.width }
            for frequency in [100.0, 1000, 10_000] {
                context.stroke(Path { $0.move(to: CGPoint(x: x(frequency), y: 0)); $0.addLine(to: CGPoint(x: x(frequency), y: size.height)) },
                               with: .color(.secondary.opacity(0.25)))
            }
            context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y(0))); $0.addLine(to: CGPoint(x: size.width, y: y(0))) },
                           with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            var curve = Path()
            for (step, frequency) in EQMath.logSpacedFrequencies(count: 160).enumerated() {
                let point = CGPoint(x: x(frequency), y: y(EQMath.response(of: preset, at: frequency)))
                step == 0 ? curve.move(to: point) : curve.addLine(to: point)
            }
            context.stroke(curve, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
            for band in preset.bands where band.isEnabled {
                let point = CGPoint(x: x(band.frequency), y: y(EQMath.response(of: preset, at: band.frequency)))
                context.fill(Path(ellipseIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)), with: .color(.accentColor))
            }
        }
        .accessibilityLabel("Equalizer curve")
    }

    /// "63 Hz", "1.6 kHz".
    static func frequencyText(_ frequency: Double) -> String {
        frequency >= 1000 ? "\((frequency / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz" : "\(Int(frequency.rounded())) Hz"
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
