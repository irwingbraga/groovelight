import AVFAudio
import CoreAudio
import Foundation
import Observation
import SFBAudioEngine

public enum PlaybackState: Sendable {
    case stopped, playing, paused
}

/// Where the sound goes and whether it gets there untouched (bit-perfect).
public struct OutputStatus: Equatable, Sendable {
    public var deviceName: String?
    public var deviceRate: Double = 0
    public var deviceBitDepth: Int?
    public var fileRate: Double?
    public var fileBitDepth: Int?
    /// Bit-perfect mode is on and nothing changes the samples on the way: same rate, deep enough format, no processing.
    public var isBitPerfect = false
    /// Why the current song is not played bit-perfect (empty when it is, or when the mode is off).
    public var notes: [String] = []
}

/// How songs are leveled (Sound Check style), from their ReplayGain tags or measured loudness.
public enum VolumeNormalization: String, Codable, CaseIterable, Sendable {
    case off
    /// Every song at the same loudness.
    case track
    /// Albums keep their own dynamics (album gain), songs without one use their track gain.
    case album
}

/// Main-actor facade over SFBAudioEngine: queue, gapless transitions, crossfade, EQ, speed, loudness, volume and the
/// spectrum tap.
///
/// Two decks, each an SFBAudioEngine player with its own graph:
/// `source -> time pitch (speed) -> loudness gain -> AVAudioUnitEQ (15 bands) -> main mixer (FFT tap) -> output`.
/// One deck plays; a crossfade starts the next song on the other deck and fades between them, then that deck plays on.
@MainActor
@Observable
public final class PlaybackController {
    public private(set) var state: PlaybackState = .stopped
    public private(set) var queue = PlayQueue()
    /// Position in the song as heard: what the engine has rendered, less the delay of the processing chain and the
    /// output device (the speed node alone holds back about 90 ms, even at normal speed).
    public private(set) var currentTime: TimeInterval = 0 {
        didSet { currentTimeUpdatedAt = .now }
    }
    /// When `currentTime` was last set, for `estimatedTime(at:)`.
    @ObservationIgnored private var currentTimeUpdatedAt = Date.now
    public private(set) var duration: TimeInterval = 0
    public private(set) var lastError: String?

    public var volume: Float = 0.8 {
        didSet {
            if bitPerfect {
                // The samples stay untouched: the device's own volume changes instead (when it has one).
                if !isSyncingDeviceVolume { device?.setVolume(volume) }
            } else if fade == nil {
                deck.player.mainMixerNode.outputVolume = volume
            }
            onVolumeChanged?(volume)
        }
    }

    /// Bit-perfect playback: the output device follows each song's sample rate and nothing in the app changes the
    /// samples (EQ, speed, normalization and crossfade are bypassed; the volume slider moves the device's volume).
    public var bitPerfect = false {
        didSet {
            guard bitPerfect != oldValue else { return }
            applyBitPerfect(wasOn: oldValue)
        }
    }

    /// With bit-perfect playback, keeps the device for this app alone (other sounds cannot change its rate).
    public var exclusiveAccess = false {
        didSet { updateExclusiveAccess() }
    }

    /// The output device and how the current song reaches it.
    public private(set) var output = OutputStatus()
    @ObservationIgnored private var isSyncingDeviceVolume = false
    /// The device's rate before bit-perfect mode changed it, put back when the mode is turned off.
    @ObservationIgnored private var originalDeviceRate: Double?

    /// Seconds over which one song fades into the next (0: off, songs follow gaplessly).
    public var crossfadeDuration: TimeInterval = 0 {
        didSet { refreshEnqueuedNext(force: true) }
    }

    /// Songs that follow each other on the same album play gaplessly even with crossfade on (live albums, DJ mixes).
    public var crossfadeSkipsSameAlbum = true {
        didSet { refreshEnqueuedNext(force: true) }
    }

    /// Playback speed (0.5 to 2), keeping the pitch.
    public var rate: Float = 1 {
        didSet {
            // Out of range: clamp (this setter runs again once with the clamped value). With @Observable, assigning
            // unconditionally here would recurse forever.
            let clamped = min(max(rate, 0.5), 2)
            guard clamped == rate else { rate = clamped; return }
            for deck in decks { deck.setRate(bitPerfect ? 1 : rate) }
        }
    }

    /// Stops when the current song ends (sleep timer): the next song is selected but does not start.
    public var stopsAfterCurrentItem = false {
        didSet { refreshEnqueuedNext(force: true) }
    }
    /// Called when playback stopped because of `stopsAfterCurrentItem`.
    @ObservationIgnored public var onStoppedAfterItem: (() -> Void)?

    public var normalization: VolumeNormalization = .off {
        didSet { deck.setGain(gain(for: queue.current)) }
    }

    private var device: OutputDevice? { OutputDevice(id: deck.player.outputDeviceID) }

    /// Called when the volume changes (to remember it across launches).
    @ObservationIgnored public var onVolumeChanged: ((Float) -> Void)?
    /// Where a restored song starts when Play is pressed.
    @ObservationIgnored private var pendingStartTime: TimeInterval?

    public var equalizerPreset: EQPreset = .flat {
        didSet { applyEqualizer() }
    }

    public var equalizerEnabled = false {
        didSet { applyEqualizer() }
    }

    private func applyEqualizer() {
        for deck in decks { deck.equalizer.apply(equalizerPreset, enabled: equalizerEnabled && !bitPerfect) }
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
        deck.player.outputNode.outputFormat(forBus: 0).sampleRate
    }

    /// Name of the current output device ("MacBook Pro Speakers", a DAC, ...).
    public var outputDeviceName: String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deck.player.outputDeviceID, &address, 0, nil, &size, &name)
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

    /// The two players; `deck` is the one playing the current song.
    @ObservationIgnored private let decks: [Deck]
    @ObservationIgnored private var activeIndex = 0
    var deck: Deck { decks[activeIndex] }
    private var player: AudioPlayer { deck.player }
    /// The crossfade in progress: the deck fading out and the task moving the volumes.
    @ObservationIgnored private var fade: (outgoing: Deck, task: Task<Void, Never>)?
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
        decks = [Deck(index: 0, analyzer: analyzer), Deck(index: 1, analyzer: analyzer)]
        for deck in decks {
            deck.bridge = DelegateBridge(owner: self, deck: deck)
            deck.player.delegate = deck.bridge
            deck.player.mainMixerNode.outputVolume = 0
        }
        deck.player.mainMixerNode.outputVolume = volume
        deck.tapGate.isOpen = true
    }

    // MARK: - Transport

    public func play(_ items: [PlayableItem], startAt index: Int = 0, shuffle: Bool = false) {
        completeFade()
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
        completeFade()
        if player.pause() { state = .paused }
    }

    public func resume() {
        if player.resume() { state = .playing }
    }

    public func stop() {
        completeFade()
        finishCurrentForReporting()
        player.stop()
        state = .stopped
        currentTime = 0
        analyzer.reset()
    }

    public func next() {
        completeFade()
        finishCurrentForReporting()
        if queue.skipForward() != nil {
            startCurrent()
        } else {
            stop()
        }
    }

    /// iTunes behavior: restart the track if more than 3 s in, otherwise go to the previous one.
    public func previous() {
        completeFade()
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        finishCurrentForReporting()
        queue.skipBackward()
        startCurrent()
    }

    public func jump(toQueueIndex index: Int) {
        completeFade()
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
        completeFade()
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
            if bitPerfect { prepareDevice(for: decoder) }
            deck.setGain(gain(for: item))
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
            updateOutputStatus()
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
        // A crossfade starts the next song on the other deck instead.
        guard !stopsAfterCurrentItem, let next = queue.nextForAutoAdvance, !shouldCrossfade(to: next) else { return }
        do {
            let decoder = try Self.makeDecoder(for: next)
            // Bit-perfect: a song at another rate waits for the device to switch (a short gap), so it is not enqueued.
            if bitPerfect {
                if !decoder.isOpen { try decoder.open() }
                guard abs(decoder.processingFormat.sampleRate - (device?.sampleRate ?? 0)) < 1 else { return }
            }
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

    /// Queue order (or crossfade setting) changed: drop what the engine had pre-loaded and enqueue the new next item.
    private func refreshEnqueuedNext(force: Bool = false) {
        guard state != .stopped, force || queue.nextForAutoAdvance != enqueuedNext else { return }
        player.clearQueue()
        enqueuedNext = nil
        enqueuedDecoder = nil
        enqueueNextForGapless()
    }

    /// The position at `date`, moved on from the last update (every 250 ms) at the playing speed: for views that
    /// follow the song closely, such as synced lyrics.
    public func estimatedTime(at date: Date) -> TimeInterval {
        guard state == .playing, pendingStartTime == nil else { return currentTime }
        let elapsed = min(max(date.timeIntervalSince(currentTimeUpdatedAt), 0), 0.5)
        return min(currentTime + elapsed * Double(rate), max(duration, currentTime))
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
        if let rendered = player.currentTime {
            // The chain delay is in output time; at another speed it covers more (or less) of the song.
            let time = max(rendered - deck.latency * Double(deck.timePitch.bypass ? 1 : deck.timePitch.rate), 0)
            let delta = time - lastTickTime
            // Only count forward progress at roughly real-time speed (ignores seeks).
            if delta > 0, delta < 1 { listenedSeconds += delta }
            lastTickTime = time
            currentTime = time
        }
        if let total = player.totalTime, total > 0 { duration = total }
        startCrossfadeIfDue()
    }

    // MARK: - Crossfade

    /// Whether the move to `next` fades (rather than following gaplessly).
    private func shouldCrossfade(to next: PlayableItem) -> Bool {
        guard crossfadeDuration > 0, !bitPerfect, let current = queue.current, next != current else { return false }
        if crossfadeSkipsSameAlbum, let album = current.albumKey, album == next.albumKey { return false }
        return true
    }

    /// Near the end of a song, starts the next one on the other deck and fades over.
    private func startCrossfadeIfDue() {
        guard fade == nil, !stopsAfterCurrentItem, state == .playing, duration > 0, let next = queue.nextForAutoAdvance,
              shouldCrossfade(to: next) else { return }
        // Short songs fade over at most half their length.
        let length = min(crossfadeDuration, duration / 2)
        guard duration - currentTime <= length else { return }

        let outgoing = deck
        let incoming = decks[1 - activeIndex]
        let decoder: any PCMDecoding
        do {
            decoder = try Self.makeDecoder(for: next)
            incoming.player.mainMixerNode.outputVolume = 0
            incoming.setGain(gain(for: next))
            try incoming.player.play(decoder)
        } catch {
            // Unplayable: let the song end and the queue move on as usual.
            return
        }
        // The incoming deck is now the current one.
        finishCurrentForReporting()
        queue.advanceAfterEnd()
        queue.syncCurrent(to: next)
        activeIndex = incoming.index
        outgoing.tapGate.isOpen = false
        incoming.tapGate.isOpen = true
        currentDecoder = ObjectIdentifier(decoder)
        enqueuedNext = nil
        enqueuedDecoder = nil
        beginItem(next)
        enqueueNextForGapless()

        let realLength = length / Double(rate)
        let task = Task { [weak self] in
            let steps = max(Int(realLength / 0.05), 1)
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled else { return }
                // Equal-power curves: the sum stays as loud through the fade.
                let progress = Double(step) / Double(steps)
                incoming.player.mainMixerNode.outputVolume = self.volume * Float(sin(progress * .pi / 2))
                outgoing.player.mainMixerNode.outputVolume = self.volume * Float(cos(progress * .pi / 2))
            }
            self?.completeFade()
        }
        fade = (outgoing, task)
    }

    /// Ends a crossfade now (it finished, or the user acted): the outgoing deck stops, the current one is at full volume.
    private func completeFade() {
        guard let fade else { return }
        self.fade = nil
        fade.task.cancel()
        fade.outgoing.player.stop()
        fade.outgoing.player.mainMixerNode.outputVolume = 0
        deck.player.mainMixerNode.outputVolume = volume
    }

    // MARK: - Bit-perfect output

    private func applyBitPerfect(wasOn: Bool) {
        applyEqualizer()
        for deck in decks {
            deck.setRate(bitPerfect ? 1 : rate)
            deck.setGain(bitPerfect ? nil : gain(for: queue.current))
        }
        completeFade()
        if bitPerfect {
            originalDeviceRate = device?.sampleRate
            deck.player.mainMixerNode.outputVolume = 1
            // The slider now shows the device's volume.
            if let deviceVolume = device?.volume {
                isSyncingDeviceVolume = true
                volume = deviceVolume
                isSyncingDeviceVolume = false
            }
        } else {
            deck.player.mainMixerNode.outputVolume = volume
            if let original = originalDeviceRate { device?.switchTo(sampleRate: original) }
            originalDeviceRate = nil
        }
        updateExclusiveAccess()
        refreshEnqueuedNext(force: true)
        // A song playing now moves to its own rate (or back) right away.
        if state == .playing, bitPerfect, let decoderRate = currentFileRate, abs(decoderRate - (device?.sampleRate ?? 0)) >= 1 {
            restartCurrent()
        }
        updateOutputStatus()
    }

    /// The current song's sample rate, from the item or the device-independent decoder format.
    private var currentFileRate: Double? {
        guard let item = queue.current else { return nil }
        if let rate = item.sampleRate, rate > 0 { return rate }
        return (try? Self.makeDecoder(for: item)).flatMap { decoder in
            (try? decoder.open()).map { decoder.processingFormat.sampleRate }
        }
    }

    /// Switches the device to the decoder's rate, or the nearest rate above it the device supports.
    private func prepareDevice(for decoder: any PCMDecoding) {
        guard let device else { return }
        if !decoder.isOpen { try? decoder.open() }
        let rate = decoder.processingFormat.sampleRate
        guard rate > 0, abs(device.sampleRate - rate) >= 1 || device.bitDepth.map({ $0 < 24 }) == true else { return }
        let target = device.supports(sampleRate: rate) ? rate : Self.closestRate(to: rate, in: device.availableSampleRates)
        guard let target else { return }
        // Switching under a running engine would glitch: stop first (the song starts right after).
        player.stop()
        device.switchTo(sampleRate: target)
    }

    /// The lowest supported rate above `rate` (no information lost), else the highest one.
    static func closestRate(to rate: Double, in ranges: [ClosedRange<Double>]) -> Double? {
        let rates = ranges.map(\.lowerBound).sorted()
        return rates.first { $0 >= rate } ?? rates.last
    }

    /// Plays the current song again from where it was (after the device changed rate).
    private func restartCurrent() {
        let position = currentTime
        startCurrent()
        // The engine seeks once the decoder plays: retried from the ticker.
        if position > 0 { pendingStartTime = position }
    }

    private func updateExclusiveAccess() {
        device?.setExclusive(bitPerfect && exclusiveAccess)
    }

    /// Gives the device back (exclusive access) and its original rate, when the app quits.
    public func releaseOutputDevice() {
        device?.setExclusive(false)
        if bitPerfect, let original = originalDeviceRate { device?.switchTo(sampleRate: original) }
    }

    private func updateOutputStatus() {
        guard let device else {
            output = OutputStatus()
            return
        }
        var status = OutputStatus(deviceName: device.name, deviceRate: device.sampleRate, deviceBitDepth: device.bitDepth,
                                  fileRate: currentFileRate, fileBitDepth: queue.current?.bitDepth)
        if bitPerfect, queue.current != nil {
            if let file = status.fileRate, abs(file - status.deviceRate) >= 1 {
                status.notes.append(String(format: "%@ does not support %g kHz: resampled to %g kHz.",
                                           status.deviceName ?? "The device", file / 1_000, status.deviceRate / 1_000))
            }
            if let fileBits = status.fileBitDepth, let deviceBits = status.deviceBitDepth, deviceBits < fileBits {
                status.notes.append("The device takes \(deviceBits)-bit samples: the file's \(fileBits)-bit samples are reduced.")
            }
            if exclusiveAccess, device.hogOwner != ProcessInfo.processInfo.processIdentifier {
                status.notes.append("Another app holds the device: other sounds can mix in.")
            }
            status.isBitPerfect = status.notes.isEmpty
        }
        output = status
    }

    // MARK: - Loudness

    /// The gain normalization applies to `item` (dB), nil when off or unknown.
    private func gain(for item: PlayableItem?) -> Double? {
        guard let item, !bitPerfect else { return nil }
        switch normalization {
        case .off: return nil
        case .track: return item.trackGain
        case .album: return item.albumGain ?? item.trackGain
        }
    }

    // MARK: - Engine callbacks (hopped to the main actor)

    fileprivate func engineNowPlayingChanged(deck source: Deck, decoder: ObjectIdentifier?) {
        guard source === deck, let decoder, decoder != currentDecoder else { return }
        currentDecoder = decoder
        guard decoder == enqueuedDecoder, let current = queue.current else { return }
        // Gapless transition to the item we pre-enqueued (repeat one enqueues the same item again).
        finishCurrentForReporting()
        if queue.repeatMode == .one, enqueuedNext == current {
            beginItem(current)
        } else if let enqueued = enqueuedNext {
            queue.advanceAfterEnd()
            queue.syncCurrent(to: enqueued)
            deck.setGain(gain(for: enqueued))
            beginItem(enqueued)
        }
        updateOutputStatus()
        enqueuedNext = nil
        enqueuedDecoder = nil
        enqueueNextForGapless()
    }

    fileprivate func engineEndOfAudio(deck source: Deck) {
        // The deck that faded out reached its end: nothing to do, the other one plays on.
        guard source === deck else { return }
        finishCurrentForReporting()
        if stopsAfterCurrentItem {
            // Sleep timer: the next song is ready, but playback stops here.
            stopsAfterCurrentItem = false
            queue.advanceAfterEnd()
            state = .stopped
            currentTime = 0
            duration = queue.current?.duration ?? 0
            ticker?.cancel()
            analyzer.reset()
            onStoppedAfterItem?()
            return
        }
        if queue.advanceAfterEnd() != nil {
            startCurrent()
        } else {
            state = .stopped
            currentTime = 0
            ticker?.cancel()
            analyzer.reset()
        }
    }

    fileprivate func engineStateChanged(deck source: Deck, _ newState: AudioPlayer.PlaybackState) {
        guard source === deck else { return }
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

/// One player and its processing chain: `source -> time pitch -> loudness gain -> EQ -> mixer (FFT tap)`.
final class Deck: @unchecked Sendable {
    let index: Int
    let player = AudioPlayer()
    let equalizer = EqualizerNode()
    let timePitch = AVAudioUnitTimePitch()
    /// Volume normalization: an EQ without bands, used for its global gain.
    let gainNode = AVAudioUnitEQ(numberOfBands: 0)
    let tapGate = TapGate()
    var bridge: DelegateBridge?

    init(index: Int, analyzer: SpectrumAnalyzer) {
        self.index = index
        timePitch.bypass = true
        gainNode.bypass = true
        Self.installProcessing(on: player, chain: [timePitch, gainNode, equalizer.node], analyzer: analyzer, gate: tapGate)
    }

    func setRate(_ rate: Float) {
        timePitch.rate = rate
        // Not processing at normal speed keeps the sound untouched.
        timePitch.bypass = rate == 1
    }

    /// Loudness gain in dB (nil: none). Boosts are limited, as the songs' peaks are not known.
    func setGain(_ gain: Double?) {
        guard let gain else {
            gainNode.bypass = true
            return
        }
        gainNode.globalGain = Float(min(max(gain, -24), 6))
        gainNode.bypass = false
    }

    /// Connects the chain between the source and the mixer and taps the mixer for the analyzer.
    /// Nonisolated on purpose: these closures run on SFBAudioEngine / AVAudioEngine threads, and closures formed in a
    /// main-actor context would trap there under Swift 6 isolation checks.
    nonisolated private static func installProcessing(on player: AudioPlayer, chain: [AVAudioNode], analyzer: SpectrumAnalyzer, gate: TapGate) {
        let sourceNode = player.sourceNode
        player.modifyProcessingGraph { engine in
            let format = sourceNode.outputFormat(forBus: 0)
            for node in chain { engine.attach(node) }
            engine.disconnectNodeOutput(sourceNode)
            engine.connect(sourceNode, to: chain[0], format: format)
            Self.connect(chain, to: engine.mainMixerNode, in: engine, format: format)
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(SpectrumAnalyzer.fftSize), format: nil) { buffer, _ in
                // Only the deck playing the current song feeds the visualizer.
                if gate.isOpen { analyzer.process(buffer) }
            }
        }
    }

    nonisolated static func connect(_ chain: [AVAudioNode], to mixer: AVAudioNode, in engine: AVAudioEngine, format: AVAudioFormat) {
        for (node, nextNode) in zip(chain, chain.dropFirst() + [mixer]) {
            engine.connect(node, to: nextNode, format: format)
        }
    }

    var chain: [AVAudioNode] { [timePitch, gainNode, equalizer.node] }

    /// Seconds between the engine rendering a frame and it being heard: the processing nodes (bypassed or not, they
    /// keep their delay) and the output device with its buffers.
    var latency: TimeInterval {
        chain.reduce(0) { $0 + (($1 as? AVAudioUnit)?.latency ?? 0) } + player.outputNode.presentationLatency
    }
}

/// A flag read on the audio thread: whether a deck's tap feeds the analyzer.
final class TapGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false

    var isOpen: Bool {
        get { lock.withLock { open } }
        set { lock.withLock { open = newValue } }
    }
}

/// Receives SFBAudioEngine delegate callbacks on its internal threads and forwards them to the main actor.
final class DelegateBridge: NSObject, AudioPlayer.Delegate, @unchecked Sendable {
    weak var owner: PlaybackController?
    let deck: Deck

    @MainActor init(owner: PlaybackController, deck: Deck) {
        self.owner = owner
        self.deck = deck
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, reconfigureProcessingGraph engine: AVAudioEngine, with format: AVAudioFormat) -> AVAudioNode {
        let chain = deck.chain
        Deck.connect(chain, to: engine.mainMixerNode, in: engine, format: format)
        return chain[0]
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, nowPlayingChanged nowPlaying: (any PCMDecoding)?) {
        let decoder = nowPlaying.map { ObjectIdentifier($0) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.owner?.engineNowPlayingChanged(deck: self.deck, decoder: decoder)
        }
    }

    func audioPlayerEndOfAudio(_ audioPlayer: AudioPlayer) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.owner?.engineEndOfAudio(deck: self.deck)
        }
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, playbackStateChanged playbackState: AudioPlayer.PlaybackState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.owner?.engineStateChanged(deck: self.deck, playbackState)
        }
    }

    func audioPlayer(_ audioPlayer: AudioPlayer, encounteredError error: Error) {
        Task { @MainActor [weak self] in self?.owner?.engineError(error) }
    }
}
