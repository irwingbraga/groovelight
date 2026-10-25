import SwiftUI

/// Groovelight on iPhone, iPad and iPhone Duo: the Mac's library in your pocket. One layout that follows its window
/// (size classes and the container's size, never the screen or the device), so the same screens fit the iPhone Duo's
/// outer and inner displays in every pose, iPad multitasking, and an iPhone.
@main
struct GroovelightMobileApp: App {
    /// The delegate holds the model, which the external display's visualizer shares (`ExternalDisplay.swift`).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var model: AppModel { delegate.model }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
        }
        .commands { PlayerCommands(model: model) }
        // Woken because the songs of a sync finished downloading while the app was away.
        .backgroundTask(.urlSession(SyncStore.downloadsIdentifier)) {
            await model.sync.handleBackgroundEvents()
        }
    }
}
