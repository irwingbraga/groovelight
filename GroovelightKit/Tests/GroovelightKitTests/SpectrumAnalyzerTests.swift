import AVFAudio
import Testing
@testable import PlayerCore

struct SpectrumAnalyzerTests {
    @Test func sineLightsUpTheMatchingBand() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        for channel in 0..<2 {
            for i in 0..<1024 {
                buffer.floatChannelData![channel][i] = 0.5 * sin(2 * .pi * 1_000 * Float(i) / 44_100)
            }
        }
        let analyzer = SpectrumAnalyzer()
        analyzer.process(buffer)
        let frame = analyzer.latestFrame
        let loudest = frame.bands.indices.max { frame.bands[$0] < frame.bands[$1] }!
        // Band centers are log spaced from 30 Hz to 16 kHz; 1 kHz sits a bit past the middle.
        let expected = Int(log10(1_000 / 30.0) / log10(16_000 / 30.0) * Double(SpectrumFrame.bandCount))
        #expect(abs(loudest - expected) <= 1)
        #expect(frame.level > 0.3)
        #expect(frame.waveform.count == SpectrumFrame.waveformCount)
    }
}
