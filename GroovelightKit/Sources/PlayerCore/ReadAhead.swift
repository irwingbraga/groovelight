import Foundation
import SFBAudioEngine
import UniformTypeIdentifiers

/// Songs read whole into memory before they play, so the decoder never waits on the disk mid-song.
///
/// The engine keeps only 16384 decoded frames ready (85 ms of a 192 kHz file): a disk that pauses longer than that (an
/// external drive busy with a backup, a slow file system) is heard as a hiccup. The next song is read in the background
/// while the current one plays; only the songs playing and next stay in memory. Files too big to hold, and songs
/// started before they could be read (the first of a new queue), play from the disk as before. Off until the app turns
/// it on (Settings, Playback).
public final class ReadAhead: @unchecked Sendable {
    public static let shared = ReadAhead()

    /// On the Mac only: phones read their own fast storage, and memory is tighter there.
    #if os(macOS)
    public static let isSupported = true
    #else
    public static let isSupported = false
    #endif

    private var enabled = false

    /// Whether songs are read ahead; turning it off frees what is in memory.
    public var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set {
            lock.withLock {
                enabled = newValue && Self.isSupported
                if !enabled { states = [:] }
            }
        }
    }

    /// Larger files play from the disk (a long hi-res recording can be over a gigabyte).
    static let maximumFileSize = 400 << 20

    private enum State {
        case loading(id: UUID, waiting: [@MainActor @Sendable () -> Void])
        case loaded(Data)
        /// Played from the disk: too big, not a local file, or it could not be read.
        case fromDisk
    }

    private let lock = NSLock()
    private var states: [URL: State] = [:]
    private let queue = DispatchQueue(label: "dev.irwingbraga.groovelight.read-ahead", qos: .userInitiated)

    /// The file's contents, when read.
    public func data(for url: URL) -> Data? {
        lock.withLock {
            if case .loaded(let data) = states[url] { data } else { nil }
        }
    }

    /// Whether the song can be handed to the engine now: read, or known to play from the disk.
    func isReady(_ url: URL) -> Bool {
        guard isEnabled else { return true }
        return lock.withLock {
            switch states[url] {
            case .loaded, .fromDisk: true
            case .loading, nil: false
            }
        }
    }

    /// Starts reading `url` (once); `ready` runs on the main actor when it can be played, at once when it already can.
    func load(_ url: URL, ready: (@MainActor @Sendable () -> Void)? = nil) {
        guard isEnabled else {
            if let ready { DispatchQueue.main.async { MainActor.assumeIsolated { ready() } } }
            return
        }
        let id = UUID()
        let start: Bool = lock.withLock {
            switch states[url] {
            case .loaded, .fromDisk:
                if let ready { DispatchQueue.main.async { MainActor.assumeIsolated { ready() } } }
                return false
            case .loading(let current, let waiting):
                states[url] = .loading(id: current, waiting: waiting + (ready.map { [$0] } ?? []))
                return false
            case nil:
                states[url] = .loading(id: id, waiting: ready.map { [$0] } ?? [])
                return true
            }
        }
        guard start else { return }
        queue.async { [self] in
            let result = Self.read(url)
            let waiting: [@MainActor @Sendable () -> Void] = lock.withLock {
                // Dropped while it was read (no longer current or next): forget it.
                guard case .loading(let current, let waiting) = states[url], current == id else { return [] }
                states[url] = result.map(State.loaded) ?? .fromDisk
                return waiting
            }
            if !waiting.isEmpty { DispatchQueue.main.async { MainActor.assumeIsolated { waiting.forEach { $0() } } } }
        }
    }

    /// Keeps only these files in memory (the songs playing and next); the others are dropped.
    func keep(_ urls: Set<URL>) {
        lock.withLock { states = states.filter { urls.contains($0.key) } }
    }

    private static func read(_ url: URL) -> Data? {
        guard url.isFileURL,
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maximumFileSize else { return nil }
        // Uncached: the file is read once into memory, so the system's file cache need not keep a second copy.
        return try? Data(contentsOf: url, options: [.uncached])
    }

    /// A decoder reading the song from memory, or nil when it is not read.
    func decoder(for url: URL) throws -> AudioDecoder? {
        guard let data = data(for: url) else { return nil }
        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
        return try AudioDecoder(inputSource: InputSource(data: data), detectContentType: true, mimeTypeHint: mimeType)
    }
}
