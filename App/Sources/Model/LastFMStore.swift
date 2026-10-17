import AppKit
import LibraryKit
import Observation
import PlayerCore
import Scrobbler

/// Last.fm for the app: connecting the account (desktop authorization in the browser), "now playing" updates, scrobbles
/// by Last.fm's rules and loves, all through a queue in the library database so nothing is lost while offline.
@MainActor @Observable
final class LastFMStore {
    enum Keys {
        static let apiKey = "lastfm.apiKey"
        static let username = "lastfm.username"
        static let scrobble = "lastfm.scrobble"
        static let nowPlaying = "lastfm.nowPlaying"
        static let syncLoves = "lastfm.syncLoves"
        static let lastSentAt = "lastfm.lastSentAt"
    }

    /// The user's name on Last.fm while connected.
    private(set) var username: String?
    private(set) var isConnecting = false
    private(set) var isSending = false
    /// Waiting scrobbles, loves and unloves.
    private(set) var pendingCount = 0
    /// What went wrong last (nil after a successful send).
    private(set) var problem: String?
    private(set) var lastSentAt: Date?

    /// The app's Last.fm API account (key in the preferences, secret in the keychain).
    var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey.trimmingCharacters(in: .whitespaces), forKey: Keys.apiKey) }
    }
    var secret = "" {
        didSet { if keychainLoaded { Keychain.set(secret.trimmingCharacters(in: .whitespaces), for: "secret") } }
    }

    var isConnected: Bool { sessionKey != nil }
    var hasCredentials: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty && !secret.trimmingCharacters(in: .whitespaces).isEmpty }

    @ObservationIgnored private var sessionKey: String?
    @ObservationIgnored private var keychainLoaded = false
    @ObservationIgnored private let database: LibraryDatabase
    @ObservationIgnored private let sender: LastFMSender
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    /// The song playing now: when it started and its library record (album artist, track number).
    @ObservationIgnored private var current: (id: Int64, startedAt: Date, track: Track?)?

    init(database: LibraryDatabase) {
        self.database = database
        sender = LastFMSender(database: database)
        apiKey = UserDefaults.standard.string(forKey: Keys.apiKey) ?? ""
        lastSentAt = UserDefaults.standard.object(forKey: Keys.lastSentAt) as? Date
        UserDefaults.standard.register(defaults: [Keys.scrobble: true, Keys.nowPlaying: true, Keys.syncLoves: true])
        // After launch, so macOS can ask to allow keychain access (items saved by a build with another signature).
        // During `App.init` that prompt is cancelled, and the sign-in would look lost.
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.loadKeychain() }
        }
        Task { [weak self, database] in
            do {
                for try await count in database.observe({ try LibraryDatabase.lastFMQueueCount($0) }) { self?.pendingCount = count }
            } catch {}
        }
        // Retries what is waiting every few minutes (offline, Last.fm down), and right away at launch.
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                self?.sendSoon(after: 0)
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    private func loadKeychain() {
        secret = Keychain.string("secret") ?? ""
        sessionKey = Keychain.string("session")
        username = sessionKey == nil ? nil : UserDefaults.standard.string(forKey: Keys.username)
        keychainLoaded = true
    }

    private func client() -> LastFMClient? {
        guard hasCredentials else { return nil }
        let credentials = LastFMCredentials(apiKey: apiKey.trimmingCharacters(in: .whitespaces), secret: secret.trimmingCharacters(in: .whitespaces))
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return LastFMClient(credentials: credentials, sessionKey: sessionKey, identity: .init(version: version))
    }

    // MARK: - Account

    /// Opens Last.fm in the browser to allow Groovelight, then waits (up to 5 minutes) for the user to do it.
    func connect() {
        guard let client = client() else {
            problem = "Enter the API key and secret of your Last.fm API account first."
            return
        }
        connectTask?.cancel()
        isConnecting = true
        problem = nil
        connectTask = Task {
            defer { isConnecting = false }
            do {
                let token = try await client.getToken()
                NSWorkspace.shared.open(client.authorizationURL(token: token))
                for _ in 0..<100 {
                    try await Task.sleep(for: .seconds(3))
                    do {
                        let session = try await client.getSession(token: token)
                        sessionKey = session.key
                        Keychain.set(session.key, for: "session")
                        username = session.name
                        UserDefaults.standard.set(session.name, forKey: Keys.username)
                        sendSoon(after: 0)
                        return
                    } catch let error as LastFMError where error.isUnauthorizedToken {
                        continue
                    }
                }
                problem = "Last.fm was not allowed in time. Try connecting again."
            } catch is CancellationError {
            } catch let error as LastFMError {
                problem = LastFMSender.describe(error)
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    func cancelConnecting() {
        connectTask?.cancel()
        isConnecting = false
    }

    func disconnect() {
        sessionKey = nil
        username = nil
        Keychain.set(nil, for: "session")
        UserDefaults.standard.removeObject(forKey: Keys.username)
    }

    var profileURL: URL? {
        username.flatMap { URL(string: "https://www.last.fm/user/\($0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0)") }
    }

    // MARK: - Listening

    /// A song started: tells Last.fm it is playing now, and remembers when it started (the scrobble's time).
    func started(_ item: PlayableItem) {
        current = (item.id, .now, nil)
        Task {
            let track = try? await database.writer.read { try Track.fetchOne($0, key: item.id) }
            guard current?.id == item.id else { return }
            current?.track = track
            guard isConnected, UserDefaults.standard.bool(forKey: Keys.nowPlaying), let client = client(),
                  let song = Self.lastFMTrack(item, track) else { return }
            try? await client.updateNowPlaying(song)
        }
    }

    /// A song ended (finished, skipped or stopped): queues a scrobble when it was played long enough.
    func finished(_ item: PlayableItem, listened: TimeInterval) {
        defer { if current?.id == item.id { current = nil } }
        guard UserDefaults.standard.bool(forKey: Keys.scrobble), isConnected,
              ScrobbleRules.isEligible(duration: item.duration, listened: listened) else { return }
        let started = current?.id == item.id ? current!.startedAt : Date.now.addingTimeInterval(-listened)
        let track = current?.id == item.id ? current?.track : nil
        guard let song = Self.lastFMTrack(item, track) else { return }
        try? database.enqueueLastFM(LastFMQueueItem(kind: .scrobble, artist: song.artist, track: song.track, album: song.album,
                                                    albumArtist: song.albumArtist, duration: song.duration,
                                                    trackNumber: song.trackNumber, timestamp: started))
        sendSoon()
    }

    /// Songs were loved or unloved in the library: the same on Last.fm.
    func lovedChanged(trackIds: [Int64], loved: Bool) {
        guard isConnected, UserDefaults.standard.bool(forKey: Keys.syncLoves) else { return }
        Task {
            let tracks = (try? await database.writer.read { db in try Track.fetchAll(db, keys: trackIds) }) ?? []
            for track in tracks {
                let artist = track.artist?.nonEmptyTrimmed ?? track.albumArtist?.nonEmptyTrimmed
                guard let artist else { continue }
                try? database.enqueueLastFM(LastFMQueueItem(kind: loved ? .love : .unlove, artist: artist, track: track.title,
                                                            timestamp: .now))
            }
            sendSoon()
        }
    }

    /// Sends what is waiting now (Settings, Send Now).
    func sendNow() { sendSoon(after: 0) }

    /// Sends the queue after a moment (so a burst of loves goes out together); one send at a time.
    private func sendSoon(after delay: Double = 2) {
        guard sendTask == nil, isConnected, let client = client() else { return }
        sendTask = Task {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            isSending = true
            let outcome = await sender.send(with: client)
            isSending = false
            switch outcome {
            case .sent(let scrobbles, let loves, _):
                problem = nil
                if scrobbles + loves > 0 {
                    lastSentAt = .now
                    UserDefaults.standard.set(lastSentAt, forKey: Keys.lastSentAt)
                }
            case .postponed(let reason):
                problem = reason + ". Waiting items are sent later."
            case .needsReconnect(let reason):
                problem = reason + ". Connect to Last.fm again."
                disconnect()
            }
            sendTask = nil
        }
    }

    /// The song as Last.fm names it (nil without an artist: Last.fm would refuse it).
    private static func lastFMTrack(_ item: PlayableItem, _ track: Track?) -> LastFMTrack? {
        let artist = track?.artist?.nonEmptyTrimmed ?? item.artist.nonEmptyTrimmed ?? track?.albumArtist?.nonEmptyTrimmed
        guard let artist, artist != "Unknown Artist", let title = (track?.title ?? item.title).nonEmptyTrimmed else { return nil }
        let album = track?.album?.nonEmptyTrimmed ?? item.album.nonEmptyTrimmed
        return LastFMTrack(artist: artist, track: title, album: album == "Unknown Album" ? nil : album,
                           albumArtist: track?.albumArtist?.nonEmptyTrimmed, duration: item.duration > 0 ? item.duration : nil,
                           trackNumber: track?.trackNumber)
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
