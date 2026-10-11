import AppKit

/// The app's appearance, chosen in Settings: follow the system, or always light or dark. Applied to every window
/// (the Shelf stays dark either way).
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance.theme"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    static var current: AppTheme {
        UserDefaults.standard.string(forKey: key).flatMap(AppTheme.init) ?? .system
    }

    @MainActor
    func apply() {
        NSApp.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
