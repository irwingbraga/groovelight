import Foundation
import Metal
import MetalKit
import PlayerCore
import simd

public enum VisualizerStyle: String, CaseIterable, Identifiable, Sendable {
    case barsAndWaves
    case lights
    case ambience
    case magnetosphere

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .barsAndWaves: "Bars & Waves"
        case .lights: "Lights"
        case .ambience: "Ambience"
        case .magnetosphere: "Magnetosphere"
        }
    }

    /// Feedback parameters: zoom per frame, rotation per frame (radians), decay. Nil = no trails.
    var feedback: (zoom: Float, rotation: Float, decay: Float)? {
        switch self {
        case .barsAndWaves: nil
        case .lights: (1.006, 0.002, 0.90)
        case .ambience: (1.03, 0.012, 0.92)
        case .magnetosphere: (1.0, 0.0, 0.8)
        }
    }
}

struct Uniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var bass: Float
    var mid: Float
    var treble: Float
    var level: Float
    var beat: Float
    var zoom: Float
    var rotation: Float
    var decay: Float
    var hue: Float
    var bandCount: UInt32
    var waveCount: UInt32
}

struct Particle {
    var position: SIMD2<Float>
    var velocity: SIMD2<Float>
    var life: Float
    var hue: Float
}

/// Draws the selected visualizer into an `MTKView`, pulling the latest spectrum each frame.
@MainActor
public final class VisualizerRenderer: NSObject, MTKViewDelegate {
    public var style: VisualizerStyle = .barsAndWaves

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let frameSource: @Sendable () -> SpectrumFrame

    private let presentPipeline: MTLRenderPipelineState
    private let feedbackPipeline: MTLRenderPipelineState
    private let barsPipeline: MTLRenderPipelineState
    private let lightsPipeline: MTLRenderPipelineState
    private let ambiencePipeline: MTLRenderPipelineState
    private let particlesRenderPipeline: MTLRenderPipelineState
    private let particlesComputePipeline: MTLComputePipelineState
    private let particleBuffer: MTLBuffer
    private let particleCount = 24_000

    private var textures: [MTLTexture] = []
    private var current = 0
    private var needsClear = true
    private let startTime = CACurrentMediaTime()

    private var bands = [Float](repeating: 0, count: SpectrumFrame.bandCount)
    private var peaks = [Float](repeating: 0, count: SpectrumFrame.bandCount)
    private var peakHold = [Int](repeating: 0, count: SpectrumFrame.bandCount)
    private var beat: Float = 0
    private var lastBeatCount = 0
    private var hue: Float = 0.55
    private var smoothed = (bass: Float(0), mid: Float(0), treble: Float(0), level: Float(0))

    static let accumulationFormat: MTLPixelFormat = .rgba16Float

    public init?(device: MTLDevice, frameSource: @escaping @Sendable () -> SpectrumFrame) {
        guard let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: ShaderSource.all, options: nil),
              let vertex = library.makeFunction(name: "fullscreen_vertex")
        else { return nil }
        self.device = device
        commandQueue = queue
        self.frameSource = frameSource

        func pipeline(_ fragmentName: String, vertex: MTLFunction, format: MTLPixelFormat, additive: Bool) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = library.makeFunction(name: fragmentName)
            descriptor.colorAttachments[0].pixelFormat = format
            if additive {
                let attachment = descriptor.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .one
                attachment.alphaBlendOperation = .add
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .zero
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        do {
            let accum = Self.accumulationFormat
            presentPipeline = try pipeline("present_fragment", vertex: vertex, format: .bgra8Unorm, additive: false)
            feedbackPipeline = try pipeline("feedback_fragment", vertex: vertex, format: accum, additive: false)
            barsPipeline = try pipeline("bars_fragment", vertex: vertex, format: accum, additive: false)
            lightsPipeline = try pipeline("lights_fragment", vertex: vertex, format: accum, additive: true)
            ambiencePipeline = try pipeline("ambience_fragment", vertex: vertex, format: accum, additive: true)
            guard let particleVertex = library.makeFunction(name: "particles_vertex"),
                  let update = library.makeFunction(name: "particles_update") else { return nil }
            particlesRenderPipeline = try pipeline("particles_fragment", vertex: particleVertex, format: accum, additive: true)
            particlesComputePipeline = try device.makeComputePipelineState(function: update)
        } catch {
            return nil
        }

        var particles = (0..<particleCount).map { _ in
            Particle(position: SIMD2(Float.random(in: -1...1), Float.random(in: -1...1)), velocity: .zero,
                     life: Float.random(in: 0...1), hue: Float.random(in: 0...1))
        }
        guard let buffer = device.makeBuffer(bytes: &particles, length: MemoryLayout<Particle>.stride * particleCount,
                                             options: .storageModeShared) else { return nil }
        particleBuffer = buffer
        super.init()
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        textures = []
    }

    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let present = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let size = view.drawableSize
        guard size.width > 0, size.height > 0 else { return }
        encodeFrame(commandBuffer, width: Int(size.width), height: Int(size.height), present: present)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Renders `frames` frames offscreen and returns the last one (used by tests and debug snapshots).
    public func renderOffscreen(width: Int, height: Int, frames: Int) -> CGImage? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let output = device.makeTexture(descriptor: descriptor) else { return nil }
        for _ in 0..<max(frames, 1) {
            guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
            let present = MTLRenderPassDescriptor()
            present.colorAttachments[0].texture = output
            present.colorAttachments[0].loadAction = .clear
            present.colorAttachments[0].storeAction = .store
            encodeFrame(commandBuffer, width: width, height: height, present: present)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        output.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    private func encodeFrame(_ commandBuffer: MTLCommandBuffer, width: Int, height: Int, present: MTLRenderPassDescriptor) {
        ensureTextures(width: width, height: height)
        var uniforms = updateUniforms(resolution: SIMD2(Float(width), Float(height)))
        let previous = textures[current]
        let target = textures[1 - current]
        if needsClear {
            // Private textures start with undefined contents; clear the one feedback reads first.
            let clear = MTLRenderPassDescriptor()
            clear.colorAttachments[0].texture = previous
            clear.colorAttachments[0].loadAction = .clear
            clear.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            clear.colorAttachments[0].storeAction = .store
            commandBuffer.makeRenderCommandEncoder(descriptor: clear)?.endEncoding()
            needsClear = false
        }

        if style == .magnetosphere, let compute = commandBuffer.makeComputeCommandEncoder() {
            compute.setComputePipelineState(particlesComputePipeline)
            compute.setBuffer(particleBuffer, offset: 0, index: 0)
            compute.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            let width = particlesComputePipeline.threadExecutionWidth
            compute.dispatchThreads(MTLSize(width: particleCount, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
            compute.endEncoding()
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            if style.feedback != nil {
                encoder.setRenderPipelineState(feedbackPipeline)
                encoder.setFragmentTexture(previous, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            switch style {
            case .barsAndWaves:
                encoder.setRenderPipelineState(barsPipeline)
                setSpectrumBuffers(encoder, uniforms: &uniforms)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            case .lights:
                encoder.setRenderPipelineState(lightsPipeline)
                setSpectrumBuffers(encoder, uniforms: &uniforms)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            case .ambience:
                encoder.setRenderPipelineState(ambiencePipeline)
                setSpectrumBuffers(encoder, uniforms: &uniforms)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            case .magnetosphere:
                encoder.setRenderPipelineState(particlesRenderPipeline)
                encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
            }
            encoder.endEncoding()
        }

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: present) {
            encoder.setRenderPipelineState(presentPipeline)
            encoder.setFragmentTexture(target, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        current = 1 - current
    }

    private func setSpectrumBuffers(_ encoder: MTLRenderCommandEncoder, uniforms: inout Uniforms) {
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        bands.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        peaks.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
        latestWaveform.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 3) }
    }

    private var latestWaveform = [Float](repeating: 0, count: SpectrumFrame.waveformCount)

    private func updateUniforms(resolution: SIMD2<Float>) -> Uniforms {
        let frame = frameSource()
        for i in 0..<min(bands.count, frame.bands.count) {
            let target = frame.bands[i]
            // Fast attack, slow release, like a VU meter.
            bands[i] = target > bands[i] ? bands[i] + (target - bands[i]) * 0.6 : max(target, bands[i] - 0.025)
            if bands[i] >= peaks[i] {
                peaks[i] = bands[i]
                peakHold[i] = 20
            } else if peakHold[i] > 0 {
                peakHold[i] -= 1
            } else {
                peaks[i] = max(bands[i], peaks[i] - 0.008)
            }
        }
        if frame.waveform.count == latestWaveform.count {
            latestWaveform = frame.waveform
        }
        if frame.beatCount != lastBeatCount {
            lastBeatCount = frame.beatCount
            beat = 1
            hue = (hue + 0.07).truncatingRemainder(dividingBy: 1)
        } else {
            beat *= 0.88
        }
        hue = (hue + 0.0008).truncatingRemainder(dividingBy: 1)
        func smooth(_ old: Float, _ new: Float) -> Float { old + (new - old) * 0.25 }
        smoothed = (smooth(smoothed.bass, frame.bass), smooth(smoothed.mid, frame.mid),
                    smooth(smoothed.treble, frame.treble), smooth(smoothed.level, frame.level))

        let feedback = style.feedback ?? (1, 0, 0)
        return Uniforms(
            resolution: resolution,
            time: Float(CACurrentMediaTime() - startTime),
            bass: smoothed.bass, mid: smoothed.mid, treble: smoothed.treble, level: smoothed.level,
            beat: beat, zoom: feedback.zoom, rotation: feedback.rotation * (1 + smoothed.mid * 2), decay: feedback.decay,
            hue: hue, bandCount: UInt32(bands.count), waveCount: UInt32(latestWaveform.count)
        )
    }

    private func ensureTextures(width: Int, height: Int) {
        if let first = textures.first, first.width == width, first.height == height { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.accumulationFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        textures = (0..<2).compactMap { _ in device.makeTexture(descriptor: descriptor) }
        current = 0
        needsClear = true
    }
}
