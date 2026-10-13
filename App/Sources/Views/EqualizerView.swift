import PlayerCore
import SwiftUI
import UniformTypeIdentifiers

/// 15-band parametric equalizer: a draggable response curve over the live spectrum, plus per-band controls.
struct EqualizerView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedBand = 7
    @State private var isNamingPreset = false
    @State private var presetName = ""
    @State private var isImporting = false
    @State private var isExporting = false

    var body: some View {
        let store = model.equalizer
        @Bindable var bindable = store
        VStack(spacing: 14) {
            if model.player.bitPerfect {
                Label("Paused while Bit-perfect playback is on (Controls, Bit-Perfect Playback).", systemImage: "checkmark.seal")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                Toggle("Equalizer", isOn: $bindable.isEnabled)
                    .toggleStyle(.switch)
                    .font(.headline)
                Spacer()
                Picker("Preset", selection: Binding(get: { store.preset.name }, set: { name in
                    if let preset = store.allPresets.first(where: { $0.name == name }) { store.select(preset) }
                })) {
                    if !store.allPresets.contains(where: { $0.name == store.preset.name }) {
                        Text(store.preset.name).tag(store.preset.name)
                        Divider()
                    }
                    ForEach(EQPreset.builtIns) { Text($0.name).tag($0.name) }
                    if !store.userPresets.isEmpty {
                        Divider()
                        ForEach(store.userPresets) { Text($0.name).tag($0.name) }
                    }
                }
                .frame(width: 220)
                Menu {
                    Button("Save Preset…") {
                        presetName = store.preset.name == "Custom" ? "" : store.preset.name
                        isNamingPreset = true
                    }
                    if store.userPresets.contains(where: { $0.name == store.preset.name }) {
                        Button("Delete Preset", role: .destructive) { store.deleteUserPreset(store.preset) }
                    }
                    Divider()
                    Button("Import AutoEq / Equalizer APO…") { isImporting = true }
                    Button("Export as ParametricEQ.txt…") { isExporting = true }
                    Divider()
                    Button("Reset to Flat") { store.reset() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            EQCurveEditor(selectedBand: $selectedBand)
                .frame(height: 260)
                .opacity(store.isEnabled ? 1 : 0.5)

            BandStrip(selectedBand: $selectedBand)

            HStack(spacing: 24) {
                BandInspector(index: selectedBand)
                Divider().frame(height: 60)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Auto preamp", isOn: $bindable.autoPreamp)
                        .help("Lowers the preamp by the largest boost so the EQ never clips.")
                    HStack {
                        Text("Preamp")
                        Slider(value: Binding(get: { store.preset.preamp }, set: { store.setPreamp($0) }), in: -24...12)
                            .frame(width: 160)
                        Text(String(format: "%+.1f dB", store.preset.preamp))
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 860)
        .alert("Save Preset", isPresented: $isNamingPreset) {
            TextField("Name", text: $presetName)
            Button("Save") {
                let name = presetName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { store.saveCurrent(as: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.plainText, .text]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                try store.importParametricEQ(from: url)
            } catch {
                model.errorMessage = "Could not read \(url.lastPathComponent) as a ParametricEQ file."
            }
        }
        .fileExporter(isPresented: $isExporting, document: ParametricEQDocument(text: ParametricEQFile.export(store.preset)),
                      contentType: .plainText, defaultFilename: "\(store.preset.name) ParametricEQ.txt") { _ in }
    }
}

/// Log-frequency graph: live spectrum behind, combined response curve, one draggable node per band.
struct EQCurveEditor: View {
    @Binding var selectedBand: Int
    @Environment(AppModel.self) private var model

    private let dbRange: ClosedRange<Double> = -24...24

    var body: some View {
        let store = model.equalizer
        TimelineView(.animation(minimumInterval: 1 / 30, paused: model.player.state != .playing)) { _ in
            Canvas { context, size in
                drawGrid(context, size: size)
                drawSpectrum(context, size: size, frame: model.player.analyzer.latestFrame)
                drawCurve(context, size: size, preset: store.preset)
            }
        }
        .overlay {
            GeometryReader { geometry in
                ForEach(Array(store.preset.bands.enumerated()), id: \.offset) { index, band in
                    BandHandle(index: index, isSelected: index == selectedBand, isEnabled: band.isEnabled)
                        .position(point(frequency: band.frequency, db: band.type.usesGain ? band.gain : 0, size: geometry.size))
                        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                            selectedBand = index
                            let (frequency, gain) = value(at: drag.location, size: geometry.size)
                            store.updateBand(index) { band in
                                band.frequency = (frequency * 10).rounded() / 10
                                if band.type.usesGain { band.gain = (gain * 10).rounded() / 10 }
                                band.isEnabled = true
                            }
                        })
                        .onTapGesture(count: 2) { store.updateBand(index) { $0.gain = 0 } }
                }
            }
        }
        .onScrollQ(selectedBand: selectedBand)
        .background(Color.black.opacity(0.85), in: .rect(cornerRadius: 14))
        .clipShape(.rect(cornerRadius: 14))
    }

    private func x(for frequency: Double, width: Double) -> Double {
        let lo = log10(EQMath.frequencyRange.lowerBound), hi = log10(EQMath.frequencyRange.upperBound)
        return (log10(frequency) - lo) / (hi - lo) * width
    }

    private func y(for db: Double, height: Double) -> Double {
        (1 - (db - dbRange.lowerBound) / (dbRange.upperBound - dbRange.lowerBound)) * height
    }

    private func point(frequency: Double, db: Double, size: CGSize) -> CGPoint {
        CGPoint(x: x(for: frequency, width: size.width), y: y(for: min(max(db, dbRange.lowerBound), dbRange.upperBound), height: size.height))
    }

    private func value(at location: CGPoint, size: CGSize) -> (Double, Double) {
        let lo = log10(EQMath.frequencyRange.lowerBound), hi = log10(EQMath.frequencyRange.upperBound)
        let fraction = min(max(location.x / size.width, 0), 1)
        let frequency = pow(10, lo + fraction * (hi - lo))
        let db = dbRange.upperBound - min(max(location.y / size.height, 0), 1) * (dbRange.upperBound - dbRange.lowerBound)
        return (frequency, db)
    }

    private func drawGrid(_ context: GraphicsContext, size: CGSize) {
        let lineColor = Color.white.opacity(0.08)
        for frequency in [31.5, 63, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000] {
            let px = x(for: frequency, width: size.width)
            context.stroke(Path { $0.move(to: CGPoint(x: px, y: 0)); $0.addLine(to: CGPoint(x: px, y: size.height)) }, with: .color(lineColor))
            let label = frequency >= 1_000 ? "\(Int(frequency / 1_000))k" : "\(Int(frequency))"
            context.draw(Text(label).font(.system(size: 9)).foregroundStyle(.white.opacity(0.4)),
                         at: CGPoint(x: px + 2, y: size.height - 8), anchor: .leading)
        }
        for db in stride(from: -18.0, through: 18, by: 6) {
            let py = y(for: db, height: size.height)
            context.stroke(Path { $0.move(to: CGPoint(x: 0, y: py)); $0.addLine(to: CGPoint(x: size.width, y: py)) },
                           with: .color(db == 0 ? Color.white.opacity(0.25) : lineColor))
            context.draw(Text(String(format: "%+.0f", db)).font(.system(size: 9)).foregroundStyle(.white.opacity(0.4)),
                         at: CGPoint(x: 4, y: py - 6), anchor: .leading)
        }
    }

    private func drawSpectrum(_ context: GraphicsContext, size: CGSize, frame: SpectrumFrame) {
        guard !frame.bands.isEmpty else { return }
        let count = frame.bands.count
        let lo = log10(30.0), hi = log10(16_000.0)
        var path = Path()
        path.move(to: CGPoint(x: x(for: 30, width: size.width), y: size.height))
        for (index, magnitude) in frame.bands.enumerated() {
            let frequency = pow(10, lo + (hi - lo) * (Double(index) + 0.5) / Double(count))
            path.addLine(to: CGPoint(x: x(for: frequency, width: size.width), y: size.height * (1 - Double(magnitude) * 0.9)))
        }
        path.addLine(to: CGPoint(x: x(for: 16_000, width: size.width), y: size.height))
        path.closeSubpath()
        context.fill(path, with: .linearGradient(Gradient(colors: [Color.cyan.opacity(0.35), Color.blue.opacity(0.05)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
    }

    private func drawCurve(_ context: GraphicsContext, size: CGSize, preset: EQPreset) {
        // Bands only: the preamp is shown separately so the handles sit on the curve.
        let preset = EQPreset(name: preset.name, preamp: 0, bands: preset.bands)
        let frequencies = EQMath.logSpacedFrequencies(count: Int(size.width / 2))
        var path = Path()
        for (index, frequency) in frequencies.enumerated() {
            let p = point(frequency: frequency, db: EQMath.response(of: preset, at: frequency), size: size)
            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        var fill = path
        fill.addLine(to: CGPoint(x: size.width, y: y(for: 0, height: size.height)))
        fill.addLine(to: CGPoint(x: 0, y: y(for: 0, height: size.height)))
        fill.closeSubpath()
        context.fill(fill, with: .color(.orange.opacity(0.12)))
        context.stroke(path, with: .color(.orange), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
    }
}

struct BandHandle: View {
    var index: Int
    var isSelected: Bool
    var isEnabled: Bool

    var body: some View {
        Text("\(index + 1)")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(isSelected ? .black : .white)
            .frame(width: 20, height: 20)
            .background(isSelected ? Color.orange : Color.white.opacity(isEnabled ? 0.3 : 0.1), in: .circle)
            .overlay(Circle().stroke(Color.orange.opacity(isEnabled ? 1 : 0.3), lineWidth: 1.5))
            .contentShape(.circle.inset(by: -6))
    }
}

/// Classic vertical sliders, one per band (gain), for quick graphic-EQ style tweaks.
struct BandStrip: View {
    @Binding var selectedBand: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.equalizer
        HStack(spacing: 0) {
            ForEach(Array(store.preset.bands.enumerated()), id: \.offset) { index, band in
                VStack(spacing: 4) {
                    Text(String(format: "%+.1f", band.gain))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(get: { band.gain }, set: { value in
                        selectedBand = index
                        store.updateBand(index) { $0.gain = (value * 2).rounded() / 2 }
                    }), in: EQMath.gainRange)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 90, height: 24)
                    .frame(width: 30, height: 90)
                    .disabled(!band.type.usesGain)
                    Text(Self.label(band.frequency))
                        .font(.system(size: 10, weight: index == selectedBand ? .bold : .regular).monospacedDigit())
                        .foregroundStyle(index == selectedBand ? Color.orange : .secondary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(.rect)
                .onTapGesture { selectedBand = index }
            }
        }
    }

    static func label(_ frequency: Double) -> String {
        frequency >= 1_000 ? String(format: frequency >= 10_000 ? "%.0fk" : "%.1fk", frequency / 1_000) : String(format: "%.0f", frequency)
    }
}

/// Exact values for the selected band: type, frequency, gain, Q.
struct BandInspector: View {
    var index: Int
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.equalizer
        if store.preset.bands.indices.contains(index) {
            let band = store.preset.bands[index]
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Band \(index + 1)").font(.headline)
                    Toggle("On", isOn: Binding(get: { band.isEnabled }, set: { value in store.updateBand(index) { $0.isEnabled = value } }))
                    Picker("Type", selection: Binding(get: { band.type }, set: { value in store.updateBand(index) { $0.type = value } })) {
                        ForEach(EQFilterType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                GridRow {
                    Text("Freq")
                    TextField("Hz", value: Binding(get: { band.frequency }, set: { value in
                        store.updateBand(index) { $0.frequency = min(max(value, EQMath.frequencyRange.lowerBound), EQMath.frequencyRange.upperBound) }
                    }), format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 70)
                    Text("Hz").foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Gain")
                    TextField("dB", value: Binding(get: { band.gain }, set: { value in
                        store.updateBand(index) { $0.gain = min(max(value, EQMath.gainRange.lowerBound), EQMath.gainRange.upperBound) }
                    }), format: .number.precision(.fractionLength(1)))
                    .frame(width: 70)
                    .disabled(!band.type.usesGain)
                    Text("dB").foregroundStyle(.secondary)
                }
                GridRow {
                    Text("Q")
                    TextField("Q", value: Binding(get: { band.q }, set: { value in
                        store.updateBand(index) { $0.q = min(max(value, EQMath.qRange.lowerBound), EQMath.qRange.upperBound) }
                    }), format: .number.precision(.fractionLength(2)))
                    .frame(width: 70)
                    Text(String(format: "%.2f oct", EQMath.bandwidth(fromQ: band.q))).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }
}

extension View {
    /// Scroll over the curve to widen or narrow the selected band (changes Q), like pro EQ plug-ins.
    func onScrollQ(selectedBand: Int) -> some View {
        modifier(ScrollQModifier(selectedBand: selectedBand))
    }
}

private struct ScrollQModifier: ViewModifier {
    var selectedBand: Int
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.overlay(ScrollWheelCatcher { delta, ended in
            guard !ended, delta != 0 else { return }
            model.equalizer.updateBand(selectedBand) { band in
                band.q = min(max(band.q * (1 + Double(delta) * 0.01), EQMath.qRange.lowerBound), EQMath.qRange.upperBound)
            }
        })
    }
}

struct ParametricEQDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
