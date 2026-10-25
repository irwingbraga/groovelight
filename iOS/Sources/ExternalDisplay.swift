import PlayerCore
import SwiftUI
import UIKit
import Visualizers

// The visualizer on an external display, as the Mac shows it full screen: a display connected without Stage Manager
// (the app's screen no longer mirrored) gets the visualizer of the music playing, with the song's title, while the
// iPad keeps the library and its controls.

/// Holds the app's model, so the external display's scene (made by UIKit, outside SwiftUI's scenes) shows the same music.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The one delegate: UIKit's `UIApplication.shared.delegate` is SwiftUI's own, not this one.
    @MainActor static private(set) var current: AppDelegate?
    @MainActor let model = AppModel()

    @MainActor override init() {
        super.init()
        Self.current = self
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        if session.role == .windowExternalDisplayNonInteractive {
            configuration.delegateClass = ExternalDisplayScene.self
        }
        return configuration
    }
}

/// The external display's window.
final class ExternalDisplayScene: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    @MainActor func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene, let model = AppDelegate.current?.model else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ExternalVisualizer().environment(model))
        window.isHidden = false
        self.window = window
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
    }
}

/// The visualizer in the style chosen on the iPad, with the song playing; for music playing elsewhere (no sound here
/// to draw from), its cover's drifting backdrop.
struct ExternalVisualizer: View {
    @Environment(AppModel.self) private var model
    @AppStorage("visualizer.style") private var style: VisualizerStyle = .barsAndWaves

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if model.isRemote {
                AnimatedArtworkBackdrop(hash: model.nowPlaying?.artworkHash)
            } else {
                VisualizerView(style: style, analyzer: model.player.controller.analyzer)
            }
            if let item = model.nowPlaying {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.largeTitle.bold())
                    Text("\(item.artist) — \(item.album)").font(.title2).foregroundStyle(.white.opacity(0.75))
                }
                .foregroundStyle(.white)
                .shadow(radius: 12)
                .padding(48)
                .id(item.id)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: model.nowPlaying?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}
