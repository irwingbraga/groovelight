import CryptoKit
import Foundation
import LibraryKit
import Network
import Observation
import OSLog
import Security
import UIKit
import WirelessSyncClient

/// The Mac this device syncs with: pairing, the key (in the keychain), and syncs, which bring the songs and the library.
@MainActor
@Observable
final class SyncStore {
    enum Phase: Equatable {
        case idle
        case syncing(done: Int, total: Int, current: String)
        case failed(String)
    }

    private(set) var mac: PairedMac?
    private(set) var phase = Phase.idle
    private(set) var lastResult: String?
    private(set) var lastSync: Date?
    /// This device, as the Mac knows it.
    let deviceId: String
    /// The Mac was last reached away from home, at its Tailscale address.
    private(set) var isAway = false
    /// Away from home, songs come down over mobile data only when allowed (Settings).
    var syncsOverMobileData: Bool {
        didSet { defaults.set(syncsOverMobileData, forKey: "sync.mobileData") }
    }
    /// On mobile data, or another connection the system counts as expensive (a phone's hotspot).
    private(set) var isOnMobileData = false

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let defaults = UserDefaults.standard
    /// The songs come down through the system, so they keep coming while the app is in the background.
    @ObservationIgnored let downloads: FileDownloads
    @ObservationIgnored private var backgroundTime = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private var eventsDelivered: [CheckedContinuation<Void, Never>] = []
    /// The system delivered them before anyone waited.
    @ObservationIgnored private var eventsArrived = false
    @ObservationIgnored private let network = NWPathMonitor()

    static let downloadsIdentifier = "dev.irwingbraga.groovelight.downloads"

    init(library: LibraryStore) {
        self.library = library
        if let id = defaults.string(forKey: "sync.deviceId") {
            deviceId = id
        } else {
            deviceId = UUID().uuidString
            defaults.set(deviceId, forKey: "sync.deviceId")
        }
        mac = defaults.data(forKey: "sync.mac").flatMap { try? JSONDecoder().decode(PairedMac.self, from: $0) }
        lastResult = defaults.string(forKey: "sync.lastResult")
        lastSync = defaults.object(forKey: "sync.lastSync") as? Date
        syncsOverMobileData = defaults.bool(forKey: "sync.mobileData")
        downloads = .background(identifier: Self.downloadsIdentifier, musicFolder: library.musicFolder)
        // Paired once but the key is gone (the keychain was reset): pair again.
        if let mac, PairingKeychain.key(macId: mac.id) == nil { forget() }
        // Songs of an earlier sync that the system delivers now still need the Mac's certificate.
        downloads.pin(mac?.certificate)
        downloads.onFinishedEvents { [weak self] in
            Task { @MainActor in self?.backgroundEventsDelivered() }
        }
        network.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive
            Task { @MainActor in self?.isOnMobileData = expensive }
        }
        network.start(queue: DispatchQueue(label: "dev.irwingbraga.groovelight.network"))
    }

    var isPaired: Bool { mac != nil }
    var isSyncing: Bool { if case .syncing = phase { true } else { false } }

    /// Debug: `-GLDebugMacAddress host:port` pairs with that Mac (the Mac's `wireless` debug tour allows it at once)
    /// and `-GLDebugSync YES` syncs at launch.
    func start(model: AppModel) async {
        #if DEBUG
        if mac == nil, let address = defaults.string(forKey: "GLDebugMacAddress"), let colon = address.lastIndex(of: ":"),
           let port = Int(address[address.index(after: colon)...]) {
            let flow = PairingFlow(sync: self)
            await flow.pair(host: String(address[..<colon]), port: port, name: "Mac")
        }
        // `-GLDebugAway YES`: as away from home, the Mac's address at home unreachable and the Mac not found on the
        // network, so only its Tailscale address answers.
        if defaults.bool(forKey: "GLDebugAway"), var away = mac {
            MacBrowser.debugFindsNothing = true
            away.host = "192.0.2.1"
            remember(away)
        }
        if defaults.bool(forKey: "GLDebugSync") { syncNow() }
        #endif
        // The app was ended during a sync: finish it (songs that arrived meanwhile are already in place).
        if defaults.bool(forKey: "sync.unfinished"), !isSyncing { syncNow() }
    }

    /// The system woke the app for its downloads: waits until it has delivered them and the sync waiting for them has
    /// put the library together (or about 25 seconds, the time the system gives).
    func handleBackgroundEvents() async {
        if eventsArrived {
            eventsArrived = false
        } else {
            await withCheckedContinuation { eventsDelivered.append($0) }
        }
        let deadline = Date.now.addingTimeInterval(25)
        while isSyncing, Date.now < deadline { try? await Task.sleep(for: .milliseconds(250)) }
    }

    private func backgroundEventsDelivered() {
        let waiting = eventsDelivered
        eventsDelivered = []
        eventsArrived = waiting.isEmpty
        for continuation in waiting { continuation.resume() }
    }

    // MARK: - Pairing

    /// Keeps a pairing the user allowed on the Mac.
    func paired(_ mac: PairedMac, key: SymmetricKey) {
        PairingKeychain.save(key, macId: mac.id)
        remember(mac)
    }

    /// Forgets the Mac (the songs and library stay until another Mac's first sync).
    func forget() {
        task?.cancel()
        defaults.set(false, forKey: "sync.unfinished")
        if let mac { PairingKeychain.remove(macId: mac.id) }
        mac = nil
        defaults.removeObject(forKey: "sync.mac")
        phase = .idle
    }

    private func remember(_ mac: PairedMac) {
        self.mac = mac
        defaults.set(try? JSONEncoder().encode(mac), forKey: "sync.mac")
    }

    // MARK: - Syncing

    func syncNow() {
        guard !isSyncing, let mac, let key = PairingKeychain.key(macId: mac.id) else { return }
        phase = .syncing(done: 0, total: 0, current: "Looking for \(mac.name)…")
        defaults.set(true, forKey: "sync.unfinished")
        holdBackgroundTime()
        let library = library
        let downloads = downloads
        let deviceId = deviceId
        let name = UIDevice.current.name, model = Self.modelName
        task = Task { [weak self] in
            do {
                let (client, connected) = try await mac.connect(deviceId: deviceId, key: key)
                self?.remember(connected)
                self?.isAway = client.isAway
                if client.isAway, self?.isOnMobileData == true, self?.syncsOverMobileData == false {
                    throw MacError("Away from home, syncing waits for Wi-Fi. To sync over mobile data, turn it on below.")
                }
                downloads.pin(connected.certificate)
                let sync = CompanionSync(client: client, musicFolder: library.musicFolder, library: library.database, artwork: library.artwork,
                                         deviceName: name, model: model, downloads: downloads, journal: library.journal)
                let outcome = try await sync.run { progress in
                    Task { @MainActor in self?.phase = .syncing(done: progress.done, total: progress.total, current: progress.current) }
                }
                Self.log.info("Sync finished: \(outcome.summary, privacy: .public) (\(outcome.songs) songs)")
                self?.finish(outcome.summary)
            } catch is CancellationError {
                self?.phase = .idle
                self?.defaults.set(false, forKey: "sync.unfinished")
            } catch {
                Self.log.error("Sync failed: \(String(describing: error), privacy: .public)")
                self?.phase = .failed(error.localizedDescription)
                self?.defaults.set(false, forKey: "sync.unfinished")
            }
            self?.releaseBackgroundTime()
        }
    }

    /// Keeps the app running for a while after it leaves the screen, so the sync can hand its songs to the system and,
    /// if they come quickly, finish. When the time is up the app is suspended: the downloads go on, and the system
    /// wakes the app when they are done (`handleBackgroundEvents`).
    private func holdBackgroundTime() {
        releaseBackgroundTime()
        backgroundTime = UIApplication.shared.beginBackgroundTask(withName: "Sync") { [weak self] in
            self?.releaseBackgroundTime()
        }
    }

    private func releaseBackgroundTime() {
        guard backgroundTime != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTime)
        backgroundTime = .invalid
    }

    /// Sends the plays, loves and edits made here to the Mac now (at launch, and when the app leaves the screen), so the
    /// Mac and Last.fm have them without waiting for a sync. Quietly does nothing when the Mac is away.
    func sendHistory() {
        guard isPaired, !isSyncing, !library.journal.pending.isEmpty else { return }
        let time = UIApplication.shared.beginBackgroundTask(withName: "History")
        Task {
            do {
                let sent = try await library.journal.send(with: client())
                Self.log.info("Sent \(sent) history events")
            } catch {
                Self.log.info("History waits for the Mac: \(String(describing: error), privacy: .public)")
            }
            UIApplication.shared.endBackgroundTask(time)
        }
    }

    /// A connection to the Mac (pinned HTTPS), for things other than syncing (playing on the Mac).
    func client() async throws -> MacClient {
        guard let mac, let key = PairingKeychain.key(macId: mac.id) else { throw MacError("Not paired with a Mac") }
        let (client, connected) = try await mac.connect(deviceId: deviceId, key: key)
        remember(connected)
        isAway = client.isAway
        return client
    }

    func cancelSync() {
        task?.cancel()
    }

    private func finish(_ summary: String) {
        phase = .idle
        defaults.set(false, forKey: "sync.unfinished")
        lastResult = summary
        lastSync = .now
        defaults.set(summary, forKey: "sync.lastResult")
        defaults.set(lastSync, forKey: "sync.lastSync")
    }

    static let log = Logger(subsystem: "dev.irwingbraga.groovelight", category: "sync")

    /// "iPhone (iPhone19,1)": the kind of device and its model identifier, shown on the Mac's device page.
    static var modelName: String {
        var info = utsname()
        uname(&info)
        let hardware: String = withUnsafeBytes(of: info.machine) { bytes in String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
        let machine: String = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? hardware
        return "\(UIDevice.current.model) (\(machine))"
    }
}

/// Pairing with one Mac: the request, the code to compare on both screens, and the wait for the user to allow it there.
@MainActor
@Observable
final class PairingFlow {
    enum Step: Equatable {
        case idle
        case connecting(String)
        case confirm(code: String, macName: String)
        case done(String)
        case failed(String)
    }

    private(set) var step = Step.idle
    @ObservationIgnored private let sync: SyncStore
    @ObservationIgnored private var task: Task<Void, Never>?

    init(sync: SyncStore) {
        self.sync = sync
    }

    func start(host: String, port: Int, name: String) {
        task?.cancel()
        task = Task { await pair(host: host, port: port, name: name) }
    }

    func pair(host: String, port: Int, name: String) async {
        step = .connecting(name)
        let client = MacClient(host: host, port: port, deviceId: sync.deviceId, key: nil)
        do {
            let info = try await client.info()
            let result = try await DevicePairing().start(with: client, name: UIDevice.current.name, model: SyncStore.modelName)
            step = .confirm(code: result.code, macName: info.name)
            guard try await DevicePairing.waitForApproval(client) else {
                step = .failed("\(info.name) did not allow this \(UIDevice.current.model).")
                return
            }
            sync.paired(PairedMac(id: result.macId, name: result.macName, host: host, port: port), key: result.key)
            step = .done(result.macName)
            sync.syncNow()
        } catch is CancellationError {
            step = .idle
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        task?.cancel()
        step = .idle
    }
}

/// The key shared with the paired Mac, in this device's keychain (only while unlocked once since boot, never synced
/// to other devices).
enum PairingKeychain {
    private static let service = "dev.irwingbraga.groovelight.pairing"

    static func save(_ key: SymmetricKey, macId: String) {
        remove(macId: macId)
        let data = key.withUnsafeBytes { Data($0) }
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: macId, kSecValueData as String: data,
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func key(macId: String) -> SymmetricKey? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: macId, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    static func remove(macId: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: macId]
        SecItemDelete(query as CFDictionary)
    }
}
