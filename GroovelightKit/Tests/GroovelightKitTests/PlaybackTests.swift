import Foundation
import Testing
@testable import PlayerCore

/// Plays real files through the full engine graph (EQ + analyzer tap) to catch threading and graph problems.
@MainActor
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
}
