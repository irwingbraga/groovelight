import AppKit
import CryptoKit
import LibraryKit
import Observation
import WirelessSync

/// Wireless sync with the Groovelight Sync app on Android (players and phones): the Mac serves on the local network,
/// devices pair once (a code shown on both screens) and then pull their music. Paired devices appear under Devices
/// with the same page as memory cards.
@MainActor
@Observable
final class WirelessSyncService {
    /// A paired device, saved under "devices.wireless.paired" (its key is in the keychain).
    struct PairedDevice: Codable, Identifiable, Hashable {
        var id: String
        var name: String
        var model: String?
        var pairedAt: Date
        var lastSeen: Date?
        var capacity: Int64 = 0
        var available: Int64 = 0
        var lastSyncAt: Date?
        var lastResult: String?
        /// Internal memory and SD cards, as of the last sync.
        var volumes: [WirelessProtocol.Volume]?
    }

    /// A device asking to pair, shown in a sheet with its code.
    struct PairingPrompt: Identifiable {
        var id: String { request.deviceId }
        var request: WirelessProtocol.PairRequest
        var code: String
    }

    /// A "Send to" waiting for the device to connect.
    struct PendingSend: Codable, Hashable {
        var trackIds: [Int64] = []
        var albumKey: String?
        var playlistId: Int64?
        var lovedSongs = false
    }

    static let enabledKey = "devices.wireless.enabled"

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? start() : stop()
            model.devices?.refresh()
        }
    }
    private(set) var paired: [PairedDevice] = []
    private(set) var port: UInt16?
    var pairingPrompt: PairingPrompt?
    /// The Sync button was pressed: the device starts a sync when it next checks in.
    private(set) var syncRequested: Set<String> = []
    /// Files served in the current sync of a device (done, total), for progress.
    private(set) var progress: [String: (Int, Int)] = [:]

    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private var server: WirelessSyncServer?
    @ObservationIgnored private var pairings: [String: (request: WirelessProtocol.PairRequest, pairing: WirelessProtocol.Pairing, status: String)] = [:]
    /// What each device reported at its last sync, for the device page's preview.
    @ObservationIgnored private(set) var lastRequests: [String: WirelessProtocol.SyncRequest] = [:]
    @ObservationIgnored private var keys: [String: SymmetricKey] = [:]

    /// This Mac's id for devices (stable across launches).
    let macId: String

    init(model: AppModel) {
        self.model = model
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "devices.wireless.macId") {
            macId = id
        } else {
            macId = UUID().uuidString
            defaults.set(macId, forKey: "devices.wireless.macId")
        }
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        paired = defaults.data(forKey: "devices.wireless.paired").flatMap { try? JSONDecoder().decode([PairedDevice].self, from: $0) } ?? []
        for device in paired {
            if let key = Keychain.string(device.id, service: Keychain.wirelessService), let data = Data(base64Encoded: key) {
                keys[device.id] = SymmetricKey(data: data)
            }
        }
        if isEnabled { start() }
    }

    static var macName: String { Host.current().localizedName ?? "Mac" }

    /// This Mac's local network addresses (IPv4, Wi-Fi and Ethernet), for typing into the app when discovery is blocked.
    static var addresses: [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
        }
        return result
    }

    /// Whether a device checked in lately (an open app checks every few seconds; a background sync every 15 minutes).
    func isOnline(_ device: PairedDevice) -> Bool {
        guard let seen = device.lastSeen else { return false }
        return Date.now.timeIntervalSince(seen) < 120
    }

    // MARK: - Server

    private func start() {
        guard server == nil else { return }
        let server = WirelessSyncServer(backend: backend())
        self.server = server
        // A fixed port is easier to allow through firewalls; another one when it is taken.
        server.start(name: "Groovelight on \(Self.macName)", port: 52_300) { [weak self] port in
            Task { @MainActor in
                guard let self else { return }
                if port == nil, self.server === server {
                    server.stop()
                    let retry = WirelessSyncServer(backend: self.backend())
                    self.server = retry
                    retry.start(name: "Groovelight on \(Self.macName)") { port in Task { @MainActor in self.port = port } }
                } else {
                    self.port = port
                }
            }
        }
    }

    private func stop() {
        server?.stop()
        server = nil
        port = nil
    }

    private func backend() -> WirelessSyncServer.Backend {
        let macId = macId, name = Self.macName
        return WirelessSyncServer.Backend(
            info: { WirelessProtocol.Info(id: macId, name: name) },
            pairRequested: { [weak self] request, pairing in await self?.pairRequested(request, pairing) },
            pairStatus: { [weak self] id in await self?.pairStatus(id) ?? "rejected" },
            key: { [weak self] id in await self?.key(for: id) },
            plan: { [weak self] id, request in
                guard let self else { throw CocoaError(.userCancelled) }
                return try await self.plan(for: id, request: request)
            },
            cover: { [artwork = model.artwork] hash, size in artwork.jpeg(for: hash, maxPixels: size) },
            finished: { [weak self] id, result in await self?.finished(id, result) },
            status: { [weak self] id in await self?.status(id) ?? WirelessProtocol.Status(syncRequested: false, pendingSends: 0) },
            fileServed: { [weak self] id, index, total in
                Task { @MainActor in
                    self?.progress[id] = (index + 1, total)
                    self?.model.devices.wirelessProgress(DeviceStore.wirelessId(id), done: index + 1, total: total)
                }
            })
    }

    // MARK: - Pairing

    private func pairRequested(_ request: WirelessProtocol.PairRequest, _ pairing: WirelessProtocol.Pairing) {
        pairings[request.deviceId] = (request, pairing, "pending")
        let prompt = PairingPrompt(request: request, code: pairing.code)
        #if DEBUG
        // `-GLDebugAutoPair YES` (tours): allows the device and gives it the first albums to sync.
        if UserDefaults.standard.bool(forKey: "GLDebugAutoPair") {
            answerPairing(prompt, allow: true)
            try? "\(pairing.code)".write(toFile: NSTemporaryDirectory() + "groovelight-pair-code", atomically: true, encoding: .utf8)
            Task {
                let albums = (try? await model.database.writer.read { try LibraryDatabase.albums($0, sort: .artist) }) ?? []
                var selection = DeviceSelection()
                selection.albumKeys = Set(albums.prefix(3).map(\.albumKey))
                model.devices.setSelection(selection, for: DeviceStore.wirelessId(request.deviceId))
            }
            return
        }
        #endif
        pairingPrompt = prompt
        NSApp.requestUserAttention(.criticalRequest)
    }

    private func pairStatus(_ id: String) -> String {
        pairings[id]?.status ?? (keys[id] != nil ? "accepted" : "rejected")
    }

    func answerPairing(_ prompt: PairingPrompt, allow: Bool) {
        pairingPrompt = nil
        guard var pending = pairings[prompt.request.deviceId] else { return }
        pending.status = allow ? "accepted" : "rejected"
        pairings[prompt.request.deviceId] = pending
        guard allow else { return }
        let id = prompt.request.deviceId
        let keyData = pending.pairing.key.withUnsafeBytes { Data($0) }
        Keychain.set(keyData.base64EncodedString(), for: id, service: Keychain.wirelessService)
        keys[id] = pending.pairing.key
        paired.removeAll { $0.id == id }
        paired.append(PairedDevice(id: id, name: prompt.request.name, model: prompt.request.model, pairedAt: .now, lastSeen: .now))
        save()
        model.devices.refresh()
    }

    func unpair(_ id: String) {
        paired.removeAll { $0.id == id }
        keys[id] = nil
        Keychain.set(nil, for: id, service: Keychain.wirelessService)
        UserDefaults.standard.removeObject(forKey: "devices.wireless.\(id).sends")
        save()
        model.devices.refresh()
    }

    private func key(for id: String) -> SymmetricKey? {
        guard let key = keys[id] else { return nil }
        touch(id)
        return key
    }

    private func touch(_ id: String) {
        guard let index = paired.firstIndex(where: { $0.id == id }) else { return }
        let wasOnline = isOnline(paired[index])
        paired[index].lastSeen = .now
        if !wasOnline {
            save()
            model.devices.refresh()
        }
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(paired), forKey: "devices.wireless.paired")
    }

    // MARK: - Sync

    func requestSync(_ id: String) { syncRequested.insert(id) }

    func cancelRequest(_ id: String) { syncRequested.remove(id) }

    func send(_ source: SendSource, to id: String) {
        var send = PendingSend()
        switch source {
        case .tracks(let tracks): send.trackIds = tracks.compactMap(\.id)
        case .album(let key): send.albumKey = key
        case .playlist(let playlistId): send.playlistId = playlistId
        case .lovedSongs: send.lovedSongs = true
        }
        var sends = pendingSends(id)
        sends.append(send)
        UserDefaults.standard.set(try? JSONEncoder().encode(sends), forKey: "devices.wireless.\(id).sends")
    }

    func pendingSends(_ id: String) -> [PendingSend] {
        UserDefaults.standard.data(forKey: "devices.wireless.\(id).sends").flatMap { try? JSONDecoder().decode([PendingSend].self, from: $0) } ?? []
    }

    private func status(_ id: String) -> WirelessProtocol.Status {
        WirelessProtocol.Status(syncRequested: syncRequested.contains(id), pendingSends: pendingSends(id).count)
    }

    private func plan(for id: String, request: WirelessProtocol.SyncRequest) async throws -> (DeviceSyncPlan, DeviceProfile) {
        lastRequests[id] = request
        if let index = paired.firstIndex(where: { $0.id == id }) {
            paired[index].capacity = request.capacity
            paired[index].available = request.available
            if let volumes = request.volumes { paired[index].volumes = volumes }
            save()
        }
        syncRequested.remove(id)
        progress[id] = (0, 0)
        let deviceId = DeviceStore.wirelessId(id)
        let selection = model.devices.selection(deviceId), profile = model.devices.profile(deviceId)
        let sends = pendingSends(id)
        let contents = try await model.database.writer.read { db in
            (try LibraryDatabase.deviceContents(db, selection), try Self.contents(db, sends))
        }
        let files = Set(request.files.map { $0.lowercased() })
        let manifest = request.manifest ?? DeviceManifest()
        let plan = await Task.detached(priority: .userInitiated) {
            let root = URL(fileURLWithPath: "/device")
            let existing: (String) -> Bool = { files.contains($0.lowercased()) }
            // Nothing chosen to sync: only what was sent, and nothing is removed.
            if selection.isEmpty {
                return DeviceSync.plan(tracks: contents.1.tracks, playlists: contents.1.playlists, profile: profile, manifest: manifest,
                                       mode: .send, root: root, existing: existing)
            }
            return DeviceSync.plan(syncing: contents.0, sending: contents.1, profile: profile, manifest: manifest, root: root,
                                   existing: existing)
        }.value
        // Sent songs are in this plan now.
        UserDefaults.standard.removeObject(forKey: "devices.wireless.\(id).sends")
        model.devices.wirelessSyncStarted(deviceId, files: plan.writes.count)
        return (plan, profile)
    }

    nonisolated private static func contents(_ db: Database, _ sends: [PendingSend]) throws -> (tracks: [Track], playlists: [DevicePlaylist]) {
        var tracks: [Track] = []
        var playlists: [DevicePlaylist] = []
        for send in sends {
            let source: SendSource
            if let key = send.albumKey { source = .album(key) }
            else if let playlistId = send.playlistId { source = .playlist(playlistId) }
            else if send.lovedSongs { source = .lovedSongs }
            else { source = .tracks(try Track.fetchAll(db, keys: send.trackIds)) }
            let (more, lists) = try source.contents(db)
            tracks += more
            playlists += lists
        }
        return (tracks, playlists)
    }

    private func finished(_ id: String, _ result: WirelessProtocol.SyncResult) {
        progress[id] = nil
        var summary = result.written == 0 && result.deleted == 0 ? "Already up to date." : "Copied \(result.written), removed \(result.deleted)."
        if !result.failed.isEmpty { summary += " \(result.failed.count) could not be written." }
        if let index = paired.firstIndex(where: { $0.id == id }) {
            paired[index].lastSyncAt = .now
            paired[index].lastResult = summary
            if let available = result.available { paired[index].available = available }
            save()
        }
        model.devices.wirelessSyncFinished(DeviceStore.wirelessId(id), summary: summary, failed: result.failed)
    }
}
