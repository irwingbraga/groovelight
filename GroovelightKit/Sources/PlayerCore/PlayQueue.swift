import Foundation

/// Something the player can play. Kept independent of the library database.
public struct PlayableItem: Hashable, Sendable, Identifiable {
    public var id: Int64
    public var url: URL
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval
    public var artworkURL: URL?
    /// For a track of a CUE sheet: where it starts and ends in `url` (nil end: the end of the file), and the file's
    /// sample rate to turn times into frames.
    public var startTime: TimeInterval?
    public var endTime: TimeInterval?
    public var sampleRate: Double?

    public init(id: Int64, url: URL, title: String, artist: String, album: String, duration: TimeInterval, artworkURL: URL? = nil,
                startTime: TimeInterval? = nil, endTime: TimeInterval? = nil, sampleRate: Double? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkURL = artworkURL
        self.startTime = startTime
        self.endTime = endTime
        self.sampleRate = sampleRate
    }
}

public enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off, all, one
}

/// Ordered play queue with shuffle and repeat, plus an "Up Next" area for Play Next / Play Later.
public struct PlayQueue: Sendable {
    /// Items in play order (already shuffled when shuffle is on).
    public private(set) var items: [PlayableItem] = []
    /// Original (unshuffled) order, used to restore when shuffle is turned off.
    private var originalOrder: [PlayableItem] = []
    public private(set) var currentIndex: Int?
    public var repeatMode: RepeatMode = .off
    public private(set) var isShuffled = false

    public init() {}

    public var current: PlayableItem? {
        currentIndex.map { items[$0] }
    }

    /// Items after the current one, in order.
    public var upcoming: ArraySlice<PlayableItem> {
        guard let index = currentIndex else { return items[...] }
        return items[(index + 1)...]
    }

    public var history: ArraySlice<PlayableItem> {
        guard let index = currentIndex else { return [] }
        return items[..<index]
    }

    /// Replaces the queue and starts at `startIndex`.
    public mutating func set<G: RandomNumberGenerator>(_ newItems: [PlayableItem], startAt startIndex: Int, shuffle: Bool, using generator: inout G) {
        originalOrder = newItems
        isShuffled = shuffle
        guard !newItems.isEmpty else {
            items = []
            currentIndex = nil
            return
        }
        let start = min(max(startIndex, 0), newItems.count - 1)
        if shuffle {
            var rest = newItems
            let first = rest.remove(at: start)
            rest.shuffle(using: &generator)
            items = [first] + rest
            currentIndex = 0
        } else {
            items = newItems
            currentIndex = start
        }
    }

    public mutating func set(_ newItems: [PlayableItem], startAt startIndex: Int = 0, shuffle: Bool = false) {
        var generator = SystemRandomNumberGenerator()
        set(newItems, startAt: startIndex, shuffle: shuffle, using: &generator)
    }

    /// The item that should follow the current one when it ends naturally (used for gapless pre-enqueueing).
    public var nextForAutoAdvance: PlayableItem? {
        guard let index = currentIndex else { return nil }
        switch repeatMode {
        case .one: return items[index]
        case .all: return items.isEmpty ? nil : items[(index + 1) % items.count]
        case .off: return index + 1 < items.count ? items[index + 1] : nil
        }
    }

    /// Advances after the current item ended on its own.
    @discardableResult
    public mutating func advanceAfterEnd() -> PlayableItem? {
        guard let index = currentIndex else { return nil }
        switch repeatMode {
        case .one:
            return items[index]
        case .all:
            currentIndex = (index + 1) % items.count
        case .off:
            guard index + 1 < items.count else {
                currentIndex = nil
                return nil
            }
            currentIndex = index + 1
        }
        return current
    }

    /// User pressed Next: repeat-one does not trap the user on the same track.
    @discardableResult
    public mutating func skipForward() -> PlayableItem? {
        guard let index = currentIndex else { return nil }
        if index + 1 < items.count {
            currentIndex = index + 1
        } else if repeatMode == .off {
            return nil
        } else {
            currentIndex = 0
        }
        return current
    }

    @discardableResult
    public mutating func skipBackward() -> PlayableItem? {
        guard let index = currentIndex else { return nil }
        if index > 0 {
            currentIndex = index - 1
        } else if repeatMode == .all, !items.isEmpty {
            currentIndex = items.count - 1
        }
        return current
    }

    public mutating func jump(to itemIndex: Int) -> PlayableItem? {
        guard items.indices.contains(itemIndex) else { return nil }
        currentIndex = itemIndex
        return current
    }

    /// Marks `item` as current if it is in the queue (used when the engine reports a gapless transition).
    public mutating func syncCurrent(to item: PlayableItem) {
        if let index = currentIndex, items[index] == item { return }
        if let index = currentIndex, index + 1 < items.count, items[index + 1] == item {
            currentIndex = index + 1
        } else if let index = items.firstIndex(of: item) {
            currentIndex = index
        }
    }

    public mutating func playNext(_ newItems: [PlayableItem]) {
        let insertAt = (currentIndex ?? -1) + 1
        items.insert(contentsOf: newItems, at: insertAt)
        originalOrder.append(contentsOf: newItems)
        if currentIndex == nil, !items.isEmpty { currentIndex = 0 }
    }

    public mutating func playLater(_ newItems: [PlayableItem]) {
        items.append(contentsOf: newItems)
        originalOrder.append(contentsOf: newItems)
        if currentIndex == nil, !items.isEmpty { currentIndex = 0 }
    }

    public mutating func remove(at itemIndex: Int) {
        guard items.indices.contains(itemIndex), itemIndex != currentIndex else { return }
        let removed = items.remove(at: itemIndex)
        if let original = originalOrder.firstIndex(of: removed) { originalOrder.remove(at: original) }
        if let index = currentIndex, itemIndex < index { currentIndex = index - 1 }
    }

    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let current = self.current
        items.move(fromOffsets: source, toOffset: destination)
        if let current { currentIndex = items.firstIndex(of: current) }
    }

    public mutating func setShuffle<G: RandomNumberGenerator>(_ enabled: Bool, using generator: inout G) {
        guard enabled != isShuffled else { return }
        isShuffled = enabled
        let current = self.current
        if enabled {
            var rest = upcoming.map { $0 }
            rest.shuffle(using: &generator)
            items = history.map { $0 } + (current.map { [$0] } ?? []) + rest
        } else {
            items = originalOrder
            if let current { currentIndex = items.firstIndex(of: current) }
        }
    }

    public mutating func setShuffle(_ enabled: Bool) {
        var generator = SystemRandomNumberGenerator()
        setShuffle(enabled, using: &generator)
    }

    /// The queue by item ids, to save across launches.
    public struct Snapshot: Codable, Equatable, Sendable {
        public var itemIds: [Int64]
        /// Unshuffled order (restored when shuffle is turned off).
        public var originalIds: [Int64]
        public var currentIndex: Int?
        public var isShuffled: Bool
        public var repeatMode: RepeatMode
    }

    public var snapshot: Snapshot {
        Snapshot(itemIds: items.map(\.id), originalIds: originalOrder.map(\.id), currentIndex: currentIndex,
                 isShuffled: isShuffled, repeatMode: repeatMode)
    }

    /// Rebuilds a saved queue from the items still available (songs removed since are dropped; when the current one
    /// is gone, the next remaining one becomes current).
    public mutating func restore(_ snapshot: Snapshot, items available: [Int64: PlayableItem]) {
        var current: Int?
        var restored: [PlayableItem] = []
        for (index, id) in snapshot.itemIds.enumerated() {
            guard let item = available[id] else { continue }
            if current == nil, let saved = snapshot.currentIndex, index >= saved { current = restored.count }
            restored.append(item)
        }
        items = restored
        originalOrder = snapshot.originalIds.compactMap { available[$0] }
        currentIndex = restored.isEmpty ? nil : min(current ?? 0, restored.count - 1)
        isShuffled = snapshot.isShuffled
        repeatMode = snapshot.repeatMode
    }

    public mutating func clear() {
        items = []
        originalOrder = []
        currentIndex = nil
    }
}

extension Array {
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { self[$0] }
        let adjustedDestination = destination - source.filter { $0 < destination }.count
        for index in source.sorted(by: >) { remove(at: index) }
        insert(contentsOf: moving, at: Swift.min(Swift.max(adjustedDestination, 0), count))
    }
}
