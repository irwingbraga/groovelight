import Foundation
import Testing
@testable import PlayerCore

struct PlayQueueTests {
    static func items(_ count: Int) -> [PlayableItem] {
        (1...count).map {
            PlayableItem(id: Int64($0), url: URL(fileURLWithPath: "/m/\($0).flac"), title: "T\($0)", artist: "A", album: "B", duration: 100)
        }
    }

    @Test func advancesAndStopsAtEnd() {
        var queue = PlayQueue()
        queue.set(Self.items(3), startAt: 1)
        #expect(queue.current?.id == 2)
        #expect(queue.nextForAutoAdvance?.id == 3)
        #expect(queue.advanceAfterEnd()?.id == 3)
        #expect(queue.nextForAutoAdvance == nil)
        #expect(queue.advanceAfterEnd() == nil)
        #expect(queue.current == nil)
    }

    @Test func repeatModes() {
        var queue = PlayQueue()
        queue.set(Self.items(2), startAt: 1)
        queue.repeatMode = .all
        #expect(queue.nextForAutoAdvance?.id == 1)
        #expect(queue.advanceAfterEnd()?.id == 1)
        queue.repeatMode = .one
        #expect(queue.nextForAutoAdvance?.id == 1)
        #expect(queue.advanceAfterEnd()?.id == 1)
        // Next button escapes repeat-one.
        #expect(queue.skipForward()?.id == 2)
    }

    @Test func shuffleKeepsStartFirstAndRestoresOrder() {
        var queue = PlayQueue()
        var generator = SeededGenerator(seed: 42)
        queue.set(Self.items(10), startAt: 4, shuffle: true, using: &generator)
        #expect(queue.current?.id == 5)
        #expect(Set(queue.items.map(\.id)) == Set(1...10))
        queue.setShuffle(false)
        #expect(queue.items.map(\.id) == Array(1...10))
        #expect(queue.current?.id == 5)
    }

    @Test func playNextAndLater() {
        var queue = PlayQueue()
        queue.set(Self.items(3), startAt: 0)
        let extra = PlayableItem(id: 99, url: URL(fileURLWithPath: "/m/99.mp3"), title: "X", artist: "A", album: "B", duration: 1)
        queue.playNext([extra])
        #expect(queue.upcoming.first?.id == 99)
        var extra2 = extra
        extra2.id = 100
        queue.playLater([extra2])
        #expect(queue.items.last?.id == 100)
    }

    @Test func removingBeforeCurrentKeepsCurrent() {
        var queue = PlayQueue()
        queue.set(Self.items(4), startAt: 2)
        queue.remove(at: 0)
        #expect(queue.current?.id == 3)
        queue.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(queue.current?.id == 3)
        #expect(queue.items.first?.id == 4)
    }
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

extension PlayQueueTests {
    @Test func snapshotRestoresTheQueue() throws {
        var queue = PlayQueue()
        var generator = SeededGenerator(seed: 7)
        queue.set(Self.items(6), startAt: 2, shuffle: true, using: &generator)
        queue.repeatMode = .all
        queue.playNext([Self.items(9)[8]])
        let saved = try JSONDecoder().decode(PlayQueue.Snapshot.self, from: JSONEncoder().encode(queue.snapshot))

        var restored = PlayQueue()
        let all = Dictionary(uniqueKeysWithValues: Self.items(9).map { ($0.id, $0) })
        restored.restore(saved, items: all)
        #expect(restored.items == queue.items && restored.current == queue.current)
        #expect(restored.isShuffled && restored.repeatMode == .all)
        // Turning shuffle off goes back to the original order, as before the restart.
        restored.setShuffle(false)
        queue.setShuffle(false)
        #expect(restored.items == queue.items)
    }

    @Test func snapshotSkipsRemovedSongs() {
        var queue = PlayQueue()
        queue.set(Self.items(5), startAt: 2)
        var available = Dictionary(uniqueKeysWithValues: Self.items(5).map { ($0.id, $0) })
        available[1] = nil
        available[3] = nil   // the current song is gone: the next remaining one becomes current
        var restored = PlayQueue()
        restored.restore(queue.snapshot, items: available)
        #expect(restored.items.map(\.id) == [2, 4, 5])
        #expect(restored.current?.id == 4)

        restored.restore(queue.snapshot, items: [:])
        #expect(restored.items.isEmpty && restored.current == nil)
    }
}
