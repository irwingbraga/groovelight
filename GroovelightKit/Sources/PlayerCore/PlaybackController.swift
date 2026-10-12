import AVFAudio
import CoreAudio
import Foundation
import Observation
import SFBAudioEngine

public enum PlaybackState: Sendable {
    case stopped, playing, paused
}

/// Main-actor facade over SFBAudioEngine: queue, gapless transitions, EQ, volume and the spectrum tap.
///
/// Audio graph: `source -> AVAudioUnitEQ (15 bands) -> main mixer (FFT tap) -> output`.
@MainActor
@Observable
public final class PlaybackController {
    public private(set) var state: PlaybackState = .stopped
    public private(set) var queue = PlayQueue()
    public private(set) var currentTime: TimeInterval = 0
    public private(set) var duration: TimeInterval = 0
    public private(set) var lastError: String?

    public var volume: Float = 0.8 {
        didSet {
            player.mainMixerNode.outputVolume = volume
            onVolumeChanged?(volume)
        }
    }

    /// Called when the volume changes (to remember it across launches).
    @ObservationIgnored public var onVolumeChanged: ((Float) -> Void)?
    /// Where a restored song starts when Play is pressed.
    @ObservationIgnored private var pendingStartTime: TimeInterval?

    public var equalizerPreset: EQPreset = .flat {
        didSet { equalizer.apply(equalizerPreset, enabled: equalizerEnabled) }
    }

    public var equalizerEnabled = false {
        didSet { equalizer.apply(equalizerPreset, enabled: equalizerEnabled) }
    }

    public var repeatMode: RepeatMode {
        get { queue.repeatMode }
        set {
            queue.repeatMode = newValue
            refreshEnqueuedNext()
        }
    }

    public var isShuffled: Bool { queue.isShuffled }

    public var current: PlayableItem? { queue.current }

    /// Sample rate the engine renders at (the output device's rate). Files at other rates are resampled.
    public var outputSampleRate: Double {
        player.outputNode.outputFormat(forBus: 0).sampleRate
    }

    /// Name of the current output device ("MacBook Pro Speakers", a DAC, ...).
    public var outputDeviceName: String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(player.outputDeviceID, &address, 0, nil, &size, &name)
        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    /// Called when an item starts playing (manual start or gapless transition).
    @ObservationIgnored public var onItemStarted: ((PlayableItem) -> Void)?
    /// Called when an item stops being current, with the seconds actually listened to.
    @ObservationIgnored public var onItemFinished: ((PlayableItem, TimeInterval) -> Void)?
    /// A song could not be opened (and was skipped).
    @ObservationIgnored public var onItemFailed: ((PlayableItem) -> Void)?

    public let analyzer = SpectrumAnalyzer()

    @ObservationIgnored private let player = AudioPlayer()
    @ObservationIgnored private let equalizer = EqualizerNode()
    @ObservationIgnored private var bridge: DelegateBridge?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// The item we already handed to the engine for gapless playback.
    @ObservationIgnored private var enqueuedNext: PlayableItem?
    /// Decoders of the current and enqueued items. The engine reports transitions by decoder: tracks of one CUE sheet
    /// share a file, so URLs cannot tell them apart.
    @ObservationIgnored private var currentDecoder: ObjectIdentifier?
    @ObservationIgnored private var enqueuedDecoder: ObjectIdentifier?
    @ObservationIgnored private var listenedSeconds: TimeInterval = 0
    @ObservationIgnored private var lastTickTime: TimeInterval = 0

    public init() {
        let bridge = DelegateBridge(owner: self, equalizer: equalizer)
        self.bridge = bridge
        player.delegate = bridge

        Self.installProcessing(on: player, equalizer: equalizer.node, analyzer: analyzer)
        player.mainMixerNode.outputVolume = volume
    }

    /// Inserts the EQ between the source and the mixer and taps the mixer for the analyzer.
    /// Nonisolated on purpose: these closures run on SFBAudioEngine / AVAudioEngine threads, and closures formed in a
    /// main-actor context would trap there under Swift 6 isolation checks.
    nonisolated private static func installProcessing(on player: AudioPlayer, equalizer eqNode: AVAudioUnitEQ, analyzer: SpectrumAnalyzer) {
        let sourceNode = player.sourceNode
        player.modifyProcessingGraph { engine in
            let format = sourceNode.outputFormat(forBus: 0)
            engine.attach(eqNode)
            engine.disconnectNodeOutput(sourceNode)
            engine.connect(sourceNode, to: eqNode, format: format)
            engine.connect(eqNode, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(SpectrumAnalyzer.fftSize), format: nil) { buffer, _ in
                analyzer.process(buffer)
            }
        }
    }

    // MARK: - Transport

    public func play(_ items: [PlayableItem], startAt index: Int = 0, shuffle: Bool = false) {
        finishCurrentForReporting()
        queue.set(items, startAt: index, shuffle: shuffle)
        startCurrent()
    }

    /// Puts back a saved queue without playing: the current song shows at `position` and starts there on Play.
    public func restore(_ snapshot: PlayQueue.Snapshot, items: [Int64: PlayableItem], position: TimeInterval) {
        guard state == .stopped, queue.current == nil else { return }
        queue.restore(snapshot, items: items)
        guard let item = queue.current else { return }
        duration = item.duration
        let start = position > 0 && position < item.duration - 1 ? position : 0
        pendingStartTime = start
        currentTime = start
    }

    public func togglePlayPause() {
        switch state {
        case .playing: pause()
        case .paused: resume()
        case .stopped: startCurrent()
        }
    }

    public func pause() {
        if player.pause() { state = .paused }
    }

    public func resume() {
        if player.resume() { state = .playing }
    }

    public func stop() {
        finishCurrentForReporting()
        player.stop()
        state = .stopped
        currentTime = 0
        analyzer.reset()
    }

    public func next() {
        finishCurrentForReporting()
        if queue.skipForward() != nil {
            startCurrent()
        } else {
            stop()
        }
    }

    /// iTunes behavior: restart the track if more than 3 s in, otherwise go to the previous one.
    public func previous() {
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        finishCurrentForReporting()
        queue.skipBackward()
        startCurrent()
    }

    public func jump(toQueueIndex index: Int) {
        finishCurrentForReporting()
        if queue.jump(to: index) != nil { startCurrent() }
    }

    public func seek(to time: TimeInterval) {
        // A restored song not started yet: it will start there.
        if state == .stopped, queue.current != nil {
            pendingStartTime = time
            currentTime = time
            return
        }
        if player.seek(time: time) {
            currentTime = time
            lastTickTime = time
        }
    }

    public func playNext(_ items: [PlayableItem]) {
        let wasEmpty = queue.current == nil
        queue.playNext(items)
        if wasEmpty { startCurrent() } else { refreshEnqueuedNext() }
    }

    public func playLater(_ items: [PlayableItem]) {
        let wasEmpty = queue.current == nil
        queue.playLater(items)
        if wasEmpty { startCurrent() } else { refreshEnqueuedNext() }
    }

    public func removeFromQueue(at index: Int) {
        queue.remove(at: index)
        refreshEnqueuedNext()
    }

    public func moveInQueue(fromOffsets source: IndexSet, toOffset destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
        refreshEnqueuedNext()
    }

    public func setShuffle(_ enabled: Bool) {
        queue.setShuffle(enabled)
        refreshEnqueuedNext()
    }

    // MARK: - Internals

    private func startCurrent() {
        guard let item = queue.current else {
            stop()
            return
        }
        do {
            let decoder = try Self.makeDecoder(for: item)
            try player.play(decoder)
            currentDecoder = ObjectIdentifier(decoder)
            enqueuedNext = nil
            enqueuedDecoder = nil
            state = .playing
            lastError = nil
            beginItem(item)
            enqueueNextForGapless()
            startTicker()
            applyPendingStart()
        } catch {
            lastError = "\(item.title): \(error.localizedDescription)"
            onItemFailed?(item)
            // Skip unplayable files instead of stopping the whole queue.
            if queue.skipForward() != nil, queue.current != item { startCurrent() } else { stop() }
        }
    }

    private func beginItem(_ item: PlayableItem) {
        currentTime = 0
        lastTickTime = 0
        listenedSeconds = 0
        duration = item.duration
        onItemStarted?(item)
    }

    private func finishCurrentForReporting() {
        // Another song was picked: a restored position no longer applies.
        pendingStartTime = nil
        guard let item = queue.current, state != .stopped else { return }
        onItemFinished?(item, listenedSeconds)
        listenedSeconds = 0
    }

    private func enqueueNextForGapless() {
        guard let next = queue.nextForAutoAdvance else { return }
        do {
            let decoder = try Self.makeDecoder(for: next)
            try player.enqueue(decoder)
            enqueuedNext = next
            enqueuedDecoder = ObjectIdentifier(decoder)
        } catch {
            enqueuedNext = nil
            enqueuedDecoder = nil
        }
    }

    /// A decoder for the whole file, or for a CUE track only its region (sample accurate, so consecutive tracks of one
    /// file play gaplessly; the engine then reports time and duration relative to the track).
    static func makeDecoder(for item: PlayableItem) throws -> any PCMDecoding {
        if let start = item.startTime, let rate = item.sampleRate, rate > 0 {
            let startFrame = AVAudioFramePosition((start * rate).rounded())
            let length = item.endTime.map { AVAudioFramePosition((($0 - start) * rate).rounded()) } ?? -1
            return try AudioRegionDecoder(url: item.url, startFrame: startFrame, frameLength: length)
        }
        return try AudioDecoder(url: item.url)
    }

    /// Queue order changed: drop what the engine had pre-loaded and enqueue the new next item.
    private func refreshEnqueuedNext() {
        guard state != .stopped, queue.nextForAutoAdvance != enqueuedNext else { return }
        player.clearQueue()
        enqueuedNext = nil
        enqueuedDecoder = nil
        enqueueNextForGapless()
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.tick()
            }
        }
    }

    /// Moves a restored song to its saved position. The engine only seeks once the decoder is playing, so this is
    /// retried from the ticker until it succeeds.
    private func applyPendingStart() {
        guard let start = pendingStartTime, state == .playing else { return }
        if start <= 0 || player.seek(time: start) {
            pendingStartTime = nil
            currentTime = max(start, 0)
            lastTickTime = currentTime
        }
    }

    private func tick() {
        guard state == .playing else { return }
        if pendingStartTime != nil {
            applyPendingStart()
            return
        }
        if let time = player.currentTime {
            let delta = time - lastTickTime
            // Only count forward progress at roughly real-time speed (ignores seeks).
            if delta > 0, delta < 1 { listenedSeconds += delta }
            lastTickTime = time
            currentTime = time
        }
        if let total = player.totalTime, total > 0 { duration = total }
    }

    // MARK: - Engine callbacks (hopped to the main actor)

    fileprivate func engineNowPlayingChanged(decoder: ObjectIdentifier?) {
        guard let decoder, decoder != currentDecoder else { return }
        currentDecoder = decoder
        guard decoder == enqueuedDecoder, let current = queue.current else { return }
        // Gapless transition to the item we pre-enqueued (repeat one enqueues the same item again).
        finishCurrentForReporting()
        if queue.repeatMode == .one, enqueuedNext == current {
            beginItem(current)
        } else if let enqueued = enqueuedNext {
            queue.advanceAfterEnd()
            queue.syncCurrent(to: enqueued)
            beginItem(enqueued)
        }
        enqueuedNext = nil
        enqueuedDecoder = nil
        enqueueNextForGapless()
    }

    fileprivate func engineEndOfAudio() {
        finishCurrentForReporting()
        if queue.advanceAfterEnd() != nil {
            startCurrent()
        } else {
            state = .stopped
            currentTime = 0
            ticker?.cancel()
            analyzer.reset()
        }
    }

    fileprivate func engineStateChanged(_ newState: AudioPlayer.PlaybackState) {
        switch newState {
        case .playing: state = .playing
        case .paused: state = .paused
        case .stopped: if queue.current == nil { state = .stopped }
        @unknown default: break
        }
    }

    fileprivate func engineError(_ error: Error) {
        lastError = error.localizedDescription
    }
}

/// Receives SFBAudioEngine delegate callbacks on its internal threads and forwards them to the main actor.
private final class DelegateBridge: NSObject, AudioPlayer.Delegate, @unchecked Sendable {
    weak var owner: PlaybackController?
    let equalizer: EqualizerNode

    @MainActor init(owner: PlaybackController, equalizer: EqualizerNode) {
        self.owner = owner
        self.equalizer = equalizer
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, reconfigureProcessingGraph engine: AVAudioEngine, with format: AVAudioFormat) -> AVAudioNode {
        engine.connect(equalizer.node, to: engine.mainMixerNode, format: format)
        return equalizer.node
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, nowPlayingChanged nowPlaying: (any PCMDecoding)?) {
        let decoder = nowPlaying.map { ObjectIdentifier($0) }
        Task { @MainActor [weak self] in self?.owner?.engineNowPlayingChanged(decoder: decoder) }
    }

    func audioPlayerEndOfAudio(_ audioPlayer: AudioPlayer) {
        Task { @MainActor [weak self] in self?.owner?.engineEndOfAudio() }
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, playbackStateChanged playbackState: AudioPlayer.PlaybackState) {
        Task { @MainActor [weak self] in self?.owner?.engineStateChanged(playbackState) }
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, encounteredError error: Error) {
        Task { @MainActor [weak self] in self?.owner?.engineError(error) }
    }
}
