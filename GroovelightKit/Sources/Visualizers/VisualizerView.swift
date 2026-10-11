import MetalKit
import PlayerCore
import SwiftUI

/// SwiftUI host for the Metal visualizers.
public struct VisualizerView: NSViewRepresentable {
    public var style: VisualizerStyle
    public var analyzer: SpectrumAnalyzer
    public var isPaused: Bool

    public init(style: VisualizerStyle, analyzer: SpectrumAnalyzer, isPaused: Bool = false) {
        self.style = style
        self.analyzer = analyzer
        self.isPaused = isPaused
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 120
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let device = view.device {
            let analyzer = self.analyzer
            context.coordinator.renderer = VisualizerRenderer(device: device) { analyzer.latestFrame }
        }
        view.delegate = context.coordinator.renderer
        update(view, context: context)
        return view
    }

    public func updateNSView(_ view: MTKView, context: Context) {
        update(view, context: context)
    }

    private func update(_ view: MTKView, context: Context) {
        context.coordinator.renderer?.style = style
        view.isPaused = isPaused
    }

    @MainActor
    public final class Coordinator {
        var renderer: VisualizerRenderer?
    }
}
