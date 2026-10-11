import Testing
@testable import LibraryKit

struct AudioSpecTests {
    @Test func classifiesTiers() {
        #expect(AudioSpec(formatName: "FLAC", sampleRate: 44_100, bitDepth: 16, bitrate: 900, channels: 2).tier == .lossless)
        #expect(AudioSpec(formatName: "FLAC", sampleRate: 96_000, bitDepth: 24, bitrate: 3000, channels: 2).tier == .hiResLossless)
        #expect(AudioSpec(formatName: "Apple Lossless", sampleRate: 48_000, bitDepth: 24, bitrate: nil, channels: 2).tier == .hiResLossless)
        #expect(AudioSpec(formatName: "WAVE", sampleRate: 48_000, bitDepth: 16, bitrate: nil, channels: 2).tier == .lossless)
        #expect(AudioSpec(formatName: "DSD Stream", sampleRate: 2_822_400, bitDepth: 1, bitrate: nil, channels: 2).tier == .dsd)
        #expect(AudioSpec(formatName: "MP3", sampleRate: 44_100, bitDepth: nil, bitrate: 320, channels: 2).tier == .highQuality)
        #expect(AudioSpec(formatName: "MPEG-1 Layer III", sampleRate: 44_100, bitDepth: nil, bitrate: 192, channels: 2).tier == .standard)
        #expect(AudioSpec(formatName: "Ogg Opus", sampleRate: 48_000, bitDepth: nil, bitrate: 160, channels: 2).tier == .highQuality)
        #expect(AudioSpec(formatName: "AAC", sampleRate: 44_100, bitDepth: nil, bitrate: 250, channels: 2).tier == .highQuality)
    }

    @Test func formatsSummaries() {
        let hiRes = AudioSpec(formatName: "FLAC", sampleRate: 96_000, bitDepth: 24, bitrate: 3000, channels: 2)
        #expect(hiRes.summary == "FLAC · 24-bit / 96 kHz")
        #expect(hiRes.compactText == "FLAC 24/96")
        let cd = AudioSpec(formatName: "Apple Lossless", sampleRate: 44_100, bitDepth: 16, bitrate: nil, channels: 2)
        #expect(cd.summary == "ALAC · 16-bit / 44.1 kHz")
        #expect(cd.compactText == "ALAC 16/44.1")
        let mp3 = AudioSpec(formatName: "MP3", sampleRate: 44_100, bitDepth: nil, bitrate: 320, channels: 2)
        #expect(mp3.summary == "MP3 · 320 kbps · 44.1 kHz")
        #expect(mp3.compactText == "MP3 320")
        let dsd = AudioSpec(formatName: "DSD Stream", sampleRate: 2_822_400, bitDepth: 1, bitrate: nil, channels: 2)
        #expect(dsd.summary == "DSF · DSD64 (2.8 MHz)")
        #expect(dsd.compactText == "DSD64")
    }

    @Test func detectsUniformAlbums() {
        let a = AudioSpec(formatName: "FLAC", sampleRate: 44_100, bitDepth: 16, bitrate: 870, channels: 2)
        let b = AudioSpec(formatName: "FLAC", sampleRate: 44_100, bitDepth: 16, bitrate: 1010, channels: 2)
        #expect(AudioSpec.uniform([a, b]) == a)

        // VBR MP3 averages snap to the same encoder setting.
        let v1 = AudioSpec(formatName: "MP3", sampleRate: 44_100, bitDepth: nil, bitrate: 245, channels: 2)
        let v2 = AudioSpec(formatName: "MP3", sampleRate: 44_100, bitDepth: nil, bitrate: 262, channels: 2)
        #expect(AudioSpec.uniform([v1, v2])?.bitrate == 256)

        let hiRes = AudioSpec(formatName: "FLAC", sampleRate: 96_000, bitDepth: 24, bitrate: 3000, channels: 2)
        #expect(AudioSpec.uniform([a, hiRes]) == nil)
        #expect(AudioSpec.uniform([]) == nil)
    }
}
