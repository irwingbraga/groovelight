import AppKit
import Observation
import Sparkle

/// Updates through Sparkle: the appcast published with each GitHub release (Info.plist `SUFeedURL`), checked for
/// automatically when the user allows it (Sparkle asks on the second launch), and verified with the EdDSA key.
@MainActor
@Observable
final class Updates {
    static let shared = Updates()

    @ObservationIgnored private let controller: SPUStandardUpdaterController?

    /// Off in debug builds, so tours and development never see update prompts.
    var isAvailable: Bool { controller != nil }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    private init() {
        #if DEBUG
        controller = nil
        #else
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    static let repository = URL(string: "https://github.com/irwingbraga/groovelight")!

    /// The licenses of the software Groovelight includes (THIRD_PARTY_NOTICES.md, bundled).
    static func showAcknowledgements() {
        if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(repository.appendingPathComponent("blob/main/THIRD_PARTY_NOTICES.md"))
        }
    }
}
