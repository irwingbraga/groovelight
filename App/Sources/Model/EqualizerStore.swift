import Foundation
import Observation
import PlayerCore

/// Persists equalizer state (current curve, on/off, user presets) and pushes changes to the player.
@MainActor
@Observable
final class EqualizerStore {
    var preset: EQPreset {
        didSet {
            player.equalizerPreset = preset
            save(preset, key: Keys.current)
        }
    }

    var isEnabled: Bool {
        didSet {
            player.equalizerEnabled = isEnabled
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
        }
    }

    var autoPreamp: Bool {
        didSet {
            UserDefaults.standard.set(autoPreamp, forKey: Keys.autoPreamp)
            if autoPreamp { applyAutoPreamp() }
        }
    }

    private(set) var userPresets: [EQPreset] {
        didSet { save(userPresets, key: Keys.userPresets) }
    }

    var allPresets: [EQPreset] { EQPreset.builtIns + userPresets }

    @ObservationIgnored private let player: PlaybackController

    private enum Keys {
        static let current = "eq.current"
        static let enabled = "eq.enabled"
        static let autoPreamp = "eq.autoPreamp"
        static let userPresets = "eq.userPresets"
    }

    init(player: PlaybackController) {
        self.player = player
        let defaults = UserDefaults.standard
        preset = Self.load(EQPreset.self, key: Keys.current) ?? .flat
        isEnabled = defaults.bool(forKey: Keys.enabled)
        autoPreamp = defaults.object(forKey: Keys.autoPreamp) as? Bool ?? true
        userPresets = Self.load([EQPreset].self, key: Keys.userPresets) ?? []
        player.equalizerPreset = preset
        player.equalizerEnabled = isEnabled
    }

    /// Picks up equalizer settings written to the preferences (after restoring a backup).
    func reloadFromDefaults() {
        preset = Self.load(EQPreset.self, key: Keys.current) ?? .flat
        isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled)
        autoPreamp = UserDefaults.standard.object(forKey: Keys.autoPreamp) as? Bool ?? true
        userPresets = Self.load([EQPreset].self, key: Keys.userPresets) ?? []
    }

    func select(_ newPreset: EQPreset) {
        preset = newPreset
        if autoPreamp { applyAutoPreamp() }
    }

    func updateBand(_ index: Int, _ change: (inout EQBand) -> Void) {
        guard preset.bands.indices.contains(index) else { return }
        var updated = preset
        change(&updated.bands[index])
        // Text fields and sliders write back on focus/layout; ignore no-op writes so the preset keeps its name.
        guard updated.bands[index] != preset.bands[index] else { return }
        if autoPreamp { updated.preamp = EQMath.autoPreamp(for: updated.bands) }
        updated.name = isBuiltInName(updated.name) || updated.name.isEmpty ? "Custom" : updated.name
        preset = updated
    }

    func setPreamp(_ value: Double) {
        autoPreamp = false
        preset.preamp = value
    }

    func reset() {
        select(.flat)
    }

    func saveCurrent(as name: String) {
        var saved = preset
        saved.name = name
        userPresets.removeAll { $0.name == name }
        userPresets.append(saved)
        preset = saved
    }

    func deleteUserPreset(_ target: EQPreset) {
        userPresets.removeAll { $0.name == target.name }
    }

    func importParametricEQ(from url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let name = url.deletingPathExtension().lastPathComponent
        guard let imported = ParametricEQFile.parse(text, name: name) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        autoPreamp = false
        userPresets.removeAll { $0.name == imported.name }
        userPresets.append(imported)
        preset = imported
        isEnabled = true
    }

    func exportParametricEQ(to url: URL) throws {
        try ParametricEQFile.export(preset).write(to: url, atomically: true, encoding: .utf8)
    }

    private func applyAutoPreamp() {
        let value = EQMath.autoPreamp(for: preset.bands)
        if abs(value - preset.preamp) > 0.01 { preset.preamp = value }
    }

    private func isBuiltInName(_ name: String) -> Bool {
        EQPreset.builtIns.contains { $0.name == name }
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
