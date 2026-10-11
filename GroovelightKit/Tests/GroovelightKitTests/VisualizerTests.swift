import AppKit
import Metal
import Testing
@testable import PlayerCore
@testable import Visualizers

@MainActor
struct VisualizerTests {
    /// Fake music: a moving spectrum, a waveform and a beat every few frames.
    final class SyntheticSource: @unchecked Sendable {
        var tick = 0
        func next() -> SpectrumFrame {
            tick += 1
            let t = Float(tick) / 30
            let bands = (0..<SpectrumFrame.bandCount).map { i -> Float in
                let x = Float(i) / Float(SpectrumFrame.bandCount)
                return max(0, min(1, 0.85 - x * 0.6 + 0.15 * sin(t * 3 + x * 12)))
            }
            let wave = (0..<SpectrumFrame.waveformCount).map { sin(Float($0) / 18 + t * 6) * 0.6 }
            return SpectrumFrame(bands: bands, waveform: wave, bass: 0.8, mid: 0.5, treble: 0.3, level: 0.6,
                                 isBeat: tick % 15 == 0, beatCount: tick / 15)
        }
    }

    @Test func everyStyleRendersVisibleOutput() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let snapshotDir = ProcessInfo.processInfo.environment["GL_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
        for style in VisualizerStyle.allCases {
            let source = SyntheticSource()
            let renderer = try #require(VisualizerRenderer(device: device) { source.next() })
            renderer.style = style
            let image = try #require(renderer.renderOffscreen(width: 640, height: 400, frames: 90))

            // Count non-black pixels: every style must draw something.
            let rep = NSBitmapImageRep(cgImage: image)
            var lit = 0
            for y in stride(from: 0, to: 400, by: 8) {
                for x in stride(from: 0, to: 640, by: 8) {
                    if let color = rep.colorAt(x: x, y: y), color.brightnessComponent > 0.08 { lit += 1 }
                }
            }
            #expect(lit > 40, "\(style) drew almost nothing (\(lit) lit samples)")

            if let snapshotDir {
                try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
                try rep.representation(using: .png, properties: [:])?.write(to: snapshotDir.appendingPathComponent("\(style.rawValue).png"))
            }
        }
    }

    @Test func uniformLayoutMatchesMetal() {
        // float2 + 10 floats + 2 uints = 56 bytes; Particle = 24 bytes.
        #expect(MemoryLayout<Uniforms>.stride == 56)
        #expect(MemoryLayout<Particle>.stride == 24)
    }
}
