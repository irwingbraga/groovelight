import Accelerate
import AVFAudio
import Foundation
import Synchronization

/// One snapshot of the audio being played, ready for visualizers.
public struct SpectrumFrame: Sendable {
    /// Log-spaced band magnitudes in 0...1, low to high frequency.
    public var bands: [Float]
    /// Mono waveform samples in -1...1.
    public var waveform: [Float]
    public var bass: Float
    public var mid: Float
    public var treble: Float
    /// Overall loudness in 0...1.
    public var level: Float
    /// True on the frame where an onset (beat) was detected.
    public var isBeat: Bool
    /// Increments on every detected beat, so readers polling at a different rate never miss one.
    public var beatCount: Int
    /// Each channel's RMS (linear, 0...1, full scale 1) over the last buffer, for level meters. A mono song has the
    /// same level in both.
    public var leftLevel: Float = 0
    public var rightLevel: Float = 0

    public static let bandCount = 64
    public static let waveformCount = 512

    public static let silent = SpectrumFrame(bands: Array(repeating: 0, count: bandCount),
                                             waveform: Array(repeating: 0, count: waveformCount),
                                             bass: 0, mid: 0, treble: 0, level: 0, isBeat: false, beatCount: 0)
}

/// Runs an FFT over audio buffers coming from an engine tap and publishes the latest `SpectrumFrame`.
///
/// `process(_:)` runs on the audio tap thread; `latestFrame` can be read from any thread (the render loop).
public final class SpectrumAnalyzer: Sendable {
    public static let fftSize = 1024

    private struct State {
        var frame = SpectrumFrame.silent
        var previousMagnitudes = [Float](repeating: 0, count: SpectrumAnalyzer.fftSize / 2)
        var fluxHistory = [Float](repeating: 0, count: 43)
        var fluxIndex = 0
        var framesSinceBeat = 0
        var beatCount = 0
        var sampleRate: Double = 44_100
    }

    private let state = Mutex(State())
    private let fft = FFTHolder(size: SpectrumAnalyzer.fftSize)

    public init() {}

    public var latestFrame: SpectrumFrame {
        state.withLock { $0.frame }
    }

    public func reset() {
        state.withLock { $0 = State() }
    }

    public func process(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let n = SpectrumAnalyzer.fftSize
        let available = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        // Mix down to mono, taking the most recent `n` samples (zero padded if the buffer is short).
        var mono = [Float](repeating: 0, count: n)
        let count = min(n, available)
        let offset = available - count
        for channel in 0..<channelCount {
            let source = channels[channel] + offset
            mono.withUnsafeMutableBufferPointer { dst in
                vDSP_vadd(dst.baseAddress!, 1, source, 1, dst.baseAddress!, 1, vDSP_Length(count))
            }
        }
        // Each channel's RMS over the whole buffer, before the mix down.
        var channelLevels = [Float](repeating: 0, count: max(channelCount, 1))
        for channel in 0..<channelCount {
            vDSP_rmsqv(channels[channel], 1, &channelLevels[channel], vDSP_Length(available))
        }
        var scale = 1 / Float(max(channelCount, 1))
        vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(n))

        let waveform = Self.downsample(mono, to: SpectrumFrame.waveformCount)
        let magnitudes = fft.magnitudes(of: mono)
        let sampleRate = buffer.format.sampleRate

        state.withLock { state in
            state.sampleRate = sampleRate
            let bands = Self.logBands(magnitudes, sampleRate: sampleRate, count: SpectrumFrame.bandCount)

            // Spectral flux onset detection against a ~1 s moving average.
            var flux: Float = 0
            for i in 0..<min(magnitudes.count, 128) {
                let diff = magnitudes[i] - state.previousMagnitudes[i]
                if diff > 0 { flux += diff }
            }
            state.previousMagnitudes = magnitudes
            let average = state.fluxHistory.reduce(0, +) / Float(state.fluxHistory.count)
            state.fluxHistory[state.fluxIndex] = flux
            state.fluxIndex = (state.fluxIndex + 1) % state.fluxHistory.count
            state.framesSinceBeat += 1
            let isBeat = flux > average * 1.5 && flux > 0.05 && state.framesSinceBeat > 8
            if isBeat {
                state.framesSinceBeat = 0
                state.beatCount += 1
            }

            let third = bands.count / 3
            func mean(_ slice: ArraySlice<Float>) -> Float { slice.isEmpty ? 0 : slice.reduce(0, +) / Float(slice.count) }
            var rms: Float = 0
            vDSP_rmsqv(mono, 1, &rms, vDSP_Length(n))

            state.frame = SpectrumFrame(
                bands: bands,
                waveform: waveform,
                bass: mean(bands[0..<third]),
                mid: mean(bands[third..<(2 * third)]),
                treble: mean(bands[(2 * third)...]),
                level: min(1, rms * 2.5),
                isBeat: isBeat,
                beatCount: state.beatCount,
                leftLevel: channelLevels[0],
                rightLevel: channelLevels[min(1, channelLevels.count - 1)]
            )
        }
    }

    static func downsample(_ samples: [Float], to count: Int) -> [Float] {
        guard samples.count > count else { return samples }
        let stride = samples.count / count
        return (0..<count).map { samples[$0 * stride] }
    }

    /// Groups linear FFT bins into log-spaced bands between 30 Hz and 16 kHz, normalized to 0...1.
    static func logBands(_ magnitudes: [Float], sampleRate: Double, count: Int) -> [Float] {
        let binWidth = sampleRate / Double(fftSize)
        let lo = log10(30.0), hi = log10(min(16_000, sampleRate / 2))
        return (0..<count).map { band in
            let f0 = pow(10, lo + (hi - lo) * Double(band) / Double(count))
            let f1 = pow(10, lo + (hi - lo) * Double(band + 1) / Double(count))
            let start = max(1, Int(f0 / binWidth))
            let end = max(start + 1, min(magnitudes.count, Int(ceil(f1 / binWidth))))
            var peak: Float = 0
            for bin in start..<end { peak = max(peak, magnitudes[bin]) }
            // Magnitude to dB, mapped from a -70...0 dB window into 0...1.
            let db = 20 * log10(max(peak, 1e-7))
            return min(1, max(0, (db + 70) / 70))
        }
    }
}

/// FFT with a Hann window. Only ever called from the single audio tap thread, hence `@unchecked Sendable`.
private final class FFTHolder: @unchecked Sendable {
    let size: Int
    let window: [Float]
    let dft: vDSP.DiscreteFourierTransform<Float>

    init(size: Int) {
        self.size = size
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        dft = try! vDSP.DiscreteFourierTransform(count: size, direction: .forward, transformType: .complexComplex, ofType: Float.self)
    }

    func magnitudes(of samples: [Float]) -> [Float] {
        let windowed = vDSP.multiply(samples, window)
        let imaginary = [Float](repeating: 0, count: size)
        let output = dft.transform(real: windowed, imaginary: imaginary)
        let half = size / 2
        var magnitudes = [Float](repeating: 0, count: half)
        let norm = 2 / Float(size)
        for i in 0..<half {
            let re = output.real[i], im = output.imaginary[i]
            magnitudes[i] = sqrt(re * re + im * im) * norm
        }
        return magnitudes
    }
}
