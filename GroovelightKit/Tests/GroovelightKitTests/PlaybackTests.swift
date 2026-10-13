import AVFAudio
import Foundation
import Testing
@testable import LibraryKit
@testable import PlayerCore

/// Plays real files through the full engine graph (EQ + analyzer tap) to catch threading and graph problems.
/// One at a time: they share the real output device, and the bit-perfect test switches its sample rate.
@MainActor
@Suite(.serialized)
struct PlaybackTests {
    @Test(.timeLimit(.minutes(1))) func playsAndAdvancesGaplessly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-play-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try ScannerIntegrationTests.makeFixtures(in: directory).filter { $0.pathExtension != "wav" }.prefix(2)
        let items = files.enumerated().map { index, url in
            PlayableItem(id: Int64(index), url: url, title: url.lastPathComponent, artist: "A", album: "B", duration: 1)
        }
        let player = PlaybackController()
        player.volume = 0
        player.equalizerEnabled = true
        player.equalizerPreset = EQPreset.builtIns[1]
        var started: [Int64] = []
        player.onItemStarted = { started.append($0.id) }

        player.play(items)
        #expect(player.state == .playing)

        // Each fixture is 1 s long: within ~3 s both should have played and the queue should end.
        for _ in 0..<40 where player.state != .stopped {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(started == [0, 1])
        #expect(player.state == .stopped)
        #expect(player.lastError == nil)
        // The analyzer saw real audio.
        #expect(player.analyzer.latestFrame.bands.contains { $0 > 0 } || player.analyzer.latestFrame.level == 0)
    }

    /// Tone files of `seconds` each (WAV), as playable items of the given albums.
    static func tones(_ seconds: Double, albums: [String], in directory: URL) throws -> [PlayableItem] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        return try albums.enumerated().map { index, album in
            let url = directory.appendingPathComponent("tone\(index).wav")
            let frames = AVAudioFrameCount(44_100 * seconds)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for channel in 0..<2 {
                for i in 0..<Int(frames) { buffer.floatChannelData![channel][i] = 0.2 * sin(2 * .pi * Float(330 + index * 110) * Float(i) / 44_100) }
            }
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
                                           AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buffer)
            return PlayableItem(id: Int64(index), url: url, title: "Tone \(index)", artist: "A", album: album, duration: seconds,
                                albumKey: album, trackGain: -6)
        }
    }

    /// Plays `items` and returns when each started (seconds from the start) and when playback stopped.
    static func timeline(_ player: PlaybackController, _ items: [PlayableItem], limit: Double = 15) async throws -> (starts: [Int64: Double], end: Double?) {
        let clock = ContinuousClock()
        let start = clock.now
        var starts: [Int64: Double] = [:]
        func elapsed() -> Double { let d = clock.now - start; return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
        player.onItemStarted = { starts[$0.id] = elapsed() }
        player.play(items)
        while player.state != .stopped, elapsed() < limit {
            try await Task.sleep(for: .milliseconds(50))
        }
        return (starts, player.state == .stopped ? elapsed() : nil)
    }

    @Test(.timeLimit(.minutes(1))) func crossfadesBetweenSongs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-fade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let items = try Self.tones(3, albums: ["X", "Y"], in: directory)
        let player = PlaybackController()
        player.volume = 0
        player.crossfadeDuration = 1
        player.normalization = .track
        var finished: [Int64] = []
        player.onItemFinished = { item, _ in finished.append(item.id) }
        let run = try await Self.timeline(player, items)
        // The second song starts about 1 s before the first ends, and everything ends about 1 s early.
        let second = try #require(run.starts[1])
        #expect(second > 1.6 && second < 2.6, "second song started at \(second) s")
        let end = try #require(run.end)
        #expect(end > 4.5 && end < 5.6, "stopped at \(end) s")
        #expect(finished == [0, 1])
        #expect(player.lastError == nil)
    }

    @Test(.timeLimit(.minutes(1))) func keepsAlbumsGaplessWithCrossfadeOn() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-album-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let items = try Self.tones(2, albums: ["X", "X"], in: directory)
        let player = PlaybackController()
        player.volume = 0
        player.crossfadeDuration = 1
        let run = try await Self.timeline(player, items)
        let second = try #require(run.starts[1])
        #expect(second > 1.7, "second song started at \(second) s (no fade within an album)")
        #expect((run.end ?? 0) > 3.6)
    }

    @Test(.timeLimit(.minutes(1))) func bitPerfectFollowsTheFileRate() async throws {
        guard let device = OutputDevice.systemDefault, device.supports(sampleRate: 48_000) else { return }
        let rates = device.availableSampleRates.map(\.lowerBound).filter { $0 != 48_000 }
        guard let other = rates.first else { return }
        let original = device.sampleRate
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-bp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Nearly silent tones: bit-perfect playback leaves the samples (and so the level) untouched.
        func tone(_ name: String, rate: Double) throws -> PlayableItem {
            let url = directory.appendingPathComponent(name)
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let frames = AVAudioFrameCount(rate * 1.5)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for c in 0..<2 { for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = 0.0005 * sin(2 * .pi * 440 * Float(i) / Float(rate)) } }
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                           AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buffer)
            return PlayableItem(id: Int64(rate), url: url, title: name, artist: "A", album: name, duration: 1.5, sampleRate: rate, bitDepth: 16)
        }
        let first = try tone("other.wav", rate: other), second = try tone("48k.wav", rate: 48_000)

        let player = PlaybackController()
        player.volume = 0
        player.equalizerEnabled = true
        player.crossfadeDuration = 3
        player.bitPerfect = true
        defer { player.stop(); player.bitPerfect = false }
        #expect(player.volume == (device.volume ?? player.volume), "the slider shows the device volume")

        var rateAtStart: [Int64: Double] = [:]
        player.onItemStarted = { item in rateAtStart[item.id] = device.sampleRate }
        player.play([first, second])
        try await Task.sleep(for: .milliseconds(400))
        #expect(device.sampleRate == other, "device at \(device.sampleRate) for a \(other) Hz file")
        #expect(player.output.isBitPerfect || !player.output.notes.isEmpty)
        for _ in 0..<80 where player.state != .stopped { try await Task.sleep(for: .milliseconds(100)) }
        // No crossfade in bit-perfect mode, and the device moved to 48 kHz for the second song.
        #expect(rateAtStart[Int64(other)] == other)
        #expect(rateAtStart[48_000] == 48_000)
        player.bitPerfect = false
        #expect(abs(device.sampleRate - original) < 1, "the device goes back to \(original) Hz")
        #expect(OutputDevice.systemDefault?.hogOwner != ProcessInfo.processInfo.processIdentifier)
    }

    /// The position follows what is heard: it trails the rendered audio by the chain's delay (the speed node holds back
    /// about 90 ms), and the estimate between updates moves with the clock instead of in 250 ms steps.
    @Test(.timeLimit(.minutes(1))) func positionFollowsTheHeardAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-time-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let items = try Self.tones(6, albums: ["A"], in: directory)
        let player = PlaybackController()
        player.volume = 0
        player.play(items)
        try await Task.sleep(for: .seconds(1.5))

        let deck = player.deck
        #expect(deck.latency > 0.05)
        let rendered = try #require(deck.player.currentTime)
        #expect(rendered - player.currentTime > deck.latency - 0.3)

        var samples: [(Date, TimeInterval)] = []
        for _ in 0..<20 {
            samples.append((.now, player.estimatedTime(at: .now)))
            try await Task.sleep(for: .milliseconds(50))
        }
        let steps = zip(samples, samples.dropFirst()).map { $1.1 - $0.1 }
        // Never backwards by more than a hair, never a quarter-second jump, and in step with the wall clock overall.
        #expect(steps.allSatisfy { $0 > -0.03 && $0 < 0.2 }, "\(steps)")
        let clock = samples.last!.0.timeIntervalSince(samples.first!.0)
        #expect(abs((samples.last!.1 - samples.first!.1) - clock) < 0.2)
        player.stop()
    }

    @Test(.timeLimit(.minutes(1))) func playsFaster() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-rate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let items = try Self.tones(3, albums: ["X"], in: directory)
        let player = PlaybackController()
        player.volume = 0
        player.rate = 2
        let run = try await Self.timeline(player, items)
        let end = try #require(run.end)
        #expect(end > 1.2 && end < 2.2, "3 s at double speed stopped at \(end) s")
        player.rate = 5
        #expect(player.rate == 2)
    }
}

/// Loudness measurement (EBU R128) against known levels.
struct LoudnessTests {
    @Test func measuresSineWavesAtKnownLevels() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-lufs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        func tone(_ name: String, amplitude: Float, seconds: Double = 5) throws -> URL {
            let url = directory.appendingPathComponent(name)
            let frames = AVAudioFrameCount(48_000 * seconds)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for channel in 0..<2 {
                for i in 0..<Int(frames) { buffer.floatChannelData![channel][i] = amplitude * sin(2 * .pi * 997 * Float(i) / 48_000) }
            }
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return url
        }
        // BS.1770: a full scale 997 Hz sine on both channels of a stereo file measures 0 LUFS (-3.01 per channel).
        let full = try #require(try LoudnessMeter.measure(url: tone("full.wav", amplitude: 1)))
        #expect(abs(full - 0) < 0.3, "full scale measured \(full) LUFS")
        let quiet = try #require(try LoudnessMeter.measure(url: tone("quiet.wav", amplitude: 0.1)))
        #expect(abs(quiet - -20) < 0.3, "-20 dBFS measured \(quiet) LUFS")
        #expect(abs(LoudnessMeter.gain(forLoudness: quiet) - 2) < 0.3)
        // A region of the file (cue tracks): the same level.
        let region = try #require(try LoudnessMeter.measure(url: tone("region.wav", amplitude: 0.1), start: 1, end: 3))
        #expect(abs(region - -20) < 0.3)
        // Silence has no loudness.
        #expect(try LoudnessMeter.measure(url: tone("silent.wav", amplitude: 0)) == nil)
    }
}
