import CoreGraphics
import CryptoKit
import Foundation
import GRDB
import ImageIO
import Network
import Testing
import UniformTypeIdentifiers
@testable import LibraryKit
import WirelessSync
@testable import WirelessSyncClient

/// Groovelight for iOS's side of wireless sync, against the Mac's server in the same process: pairing, pinning the
/// certificate, a player sync into a folder, the snapshot in the device's database, and a second sync with nothing to do.
struct CompanionSyncTests {
    @Test(.timeLimit(.minutes(1))) func pairsPinsAndSyncsAPlayer() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-companion-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let macFiles = folder.appendingPathComponent("mac"), deviceMusic = folder.appendingPathComponent("device/Music")
        try FileManager.default.createDirectory(at: macFiles, withIntermediateDirectories: true)

        // The Mac's library: two songs of one album, one loved, in a playlist; a cover and an artist photo.
        let mac = try LibraryDatabase.inMemory()
        let root = try mac.addRoot(path: macFiles.path, bookmark: Data())
        let ids: [Int64] = try await mac.writer.write { db in
            var ids: [Int64] = []
            for (number, title) in ["One", "Two"].enumerated() {
                let url = macFiles.appendingPathComponent("\(title).flac")
                try Data(repeating: UInt8(number + 1), count: 80_000 + number).write(to: url)
                var track = LibraryDatabaseTests.makeTrack(rootId: root.id!, title, artist: "Band", album: "LP", number: number + 1)
                track.path = url.path
                track.artworkHash = "cover1"
                track.lyrics = "[00:01.00]Hello"
                try track.insert(db)
                ids.append(track.id!)
            }
            try db.execute(sql: "UPDATE track SET isLoved = 1, rating = 4 WHERE id = ?", arguments: [ids[1]])
            try db.execute(sql: "INSERT INTO artistInfo (artistKey, data, fetchedAt) VALUES ('band', ?, ?)",
                           arguments: [Data("{\"imageHash\":\"photo1\"}".utf8), Date.now])
            return ids
        }
        let playlist = try mac.createPlaylist(named: "Mix", trackIds: [ids[1], ids[0]])
        let image = try Self.png()

        // The server, as the Mac app sets it up.
        let label = "dev.irwingbraga.groovelight.test-\(UUID().uuidString)"
        defer { TLSIdentity.remove(label: label) }
        let tls = try TestKeychain.identity(label: label)
        final class State: @unchecked Sendable {
            var key: SymmetricKey?
            var code: String?
            var results: [WirelessProtocol.SyncResult] = []
            var selection = DeviceSelection()
        }
        let state = State()
        let backend = WirelessSyncServer.Backend(
            info: { WirelessProtocol.Info(id: "mac-1", name: "Test Mac") },
            pairRequested: { _, pairing in
                state.key = pairing.key
                state.code = pairing.code
            },
            pairStatus: { _ in state.key == nil ? "pending" : "accepted" },
            key: { $0 == "phone-1" ? state.key : nil },
            plan: { _, request in
                // As the Mac app plans for a player: the songs only, against the files the device has.
                let tracks = try await mac.writer.read { try LibraryDatabase.allTracks($0) }
                var profile = DeviceProfile()
                profile.writesCovers = false
                profile.writesLyrics = false
                profile.writesPlaylists = false
                let files = Set(request.files.map { $0.lowercased() })
                let plan = DeviceSync.plan(tracks: tracks, playlists: [], profile: profile, manifest: request.manifest ?? DeviceManifest(),
                                           mode: .sync, root: URL(fileURLWithPath: "/device"),
                                           player: DeviceSync.Player(decodes: Set(request.decodes ?? [])),
                                           existing: { files.contains($0.lowercased()) })
                return (plan, profile)
            },
            cover: { hash, _ in ["cover1", "photo1"].contains(hash) ? image : nil },
            finished: { _, result in state.results.append(result) },
            status: { _ in WirelessProtocol.Status(syncRequested: false, pendingSends: 0) },
            snapshot: { _, paths, codecs in
                let snapshot = try await mac.writer.read { try DeviceSnapshot.build($0, paths: paths, codecs: codecs) }
                return try WirelessProtocol.encoder.encode(snapshot)
            },
            catalog: { _ in
                let catalog = try await mac.writer.read { try DeviceCatalog.build($0, selection: state.selection) }
                return try WirelessProtocol.encoder.encode(catalog)
            },
            requests: { _, requests in
                state.selection = state.selection.applying(requests)
                return DeviceCatalog.Chosen(state.selection)
            },
            history: { id, events in try mac.applyDeviceHistory(events, deviceId: id) })
        let server = WirelessSyncServer(backend: backend)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            server.start(name: "Groovelight Companion Test \(UUID().uuidString.prefix(4))", tls: (tls.identity, tls.fingerprint)) { port in
                if let port { continuation.resume(returning: port) } else { continuation.resume(throwing: CocoaError(.featureUnsupported)) }
            }
        }
        defer { server.stop() }

        // Pairing: both sides show the same code.
        let open = MacClient(host: "127.0.0.1", port: Int(port), deviceId: "phone-1", key: nil)
        #expect(try await open.info().tlsPort != nil)
        let pairing = try await DevicePairing().start(with: open, name: "Test iPhone", model: "iPhone")
        #expect(pairing.code == state.code)
        #expect(pairing.macId == "mac-1")
        #expect(try await DevicePairing.waitForApproval(open))

        // Connecting pins the Mac's certificate (with its proof) and goes over HTTPS.
        let paired = PairedMac(id: pairing.macId, name: pairing.macName, host: "127.0.0.1", port: Int(port))
        let (client, connected) = try await paired.connect(deviceId: "phone-1", key: pairing.key)
        #expect(connected.certificate == tls.fingerprint)
        #expect(client.isSecure)

        // Another certificate is refused.
        let impostor = MacClient(host: "127.0.0.1", port: Int(port), deviceId: "phone-1", key: pairing.key,
                                 tls: .init(port: client.tls!.port, fingerprint: String(repeating: "0", count: 64)))
        await #expect(throws: MacError.self) { try await impostor.status() }

        // First sync: both songs, the library with the Mac's ids, loves, lyrics, the playlist, cover and photo.
        let device = try LibraryDatabase.inMemory()
        let artwork = try ArtworkCache(directory: folder.appendingPathComponent("device/Artwork"))
        let sync = CompanionSync(client: client, musicFolder: deviceMusic, library: device, artwork: artwork, deviceName: "Test iPhone",
                                 model: "iPhone")
        let first = try await sync.run()
        #expect(first.written == 2)
        #expect(first.failed.isEmpty)
        #expect(first.songs == 2)
        #expect(first.missingCovers == 0)
        let songs = try await device.writer.read { try LibraryDatabase.allTracks($0) }
        #expect(Set(songs.compactMap(\.id)) == Set(ids))
        for song in songs {
            #expect(FileManager.default.fileExists(atPath: song.path))
            #expect(song.path.hasPrefix(deviceMusic.path + "/"))
            #expect(song.lyrics == "[00:01.00]Hello")
            #expect(song.format == "FLAC")
        }
        #expect(songs.first { $0.id == ids[1] }?.isLoved == true)
        #expect(songs.first { $0.id == ids[1] }?.rating == 4)
        let albums = try await device.writer.read { try LibraryDatabase.albums($0) }
        #expect(albums.map(\.title) == ["LP"])
        #expect(albums.first?.artist == "Band")
        let items = try await device.writer.read { try LibraryDatabase.tracks($0, playlistId: playlist.id!) }
        #expect(items.compactMap(\.id) == [ids[1], ids[0]])
        #expect(artwork.has("cover1"))
        #expect(artwork.has("photo1"))
        #expect(try await device.writer.read { try LibraryDatabase.artistPhotos($0, names: ["Band"]) } == ["Band": "photo1"])
        #expect(DeviceManifest.read(from: deviceMusic).entries.count == 2)

        // Second sync: nothing to do, and the library stays.
        let second = try await sync.run()
        #expect(second.written == 0 && second.deleted == 0)
        #expect(second.summary == "Up to date")
        #expect(try await device.writer.read { try LibraryDatabase.allTracks($0) }.count == 2)
        #expect(state.results.count == 2)

        // Played and unloved on the device: the next sync takes them to the Mac first, so its snapshot has them, and they
        // are forgotten here. Sent again (an answer lost), the Mac does not count the play twice.
        let journal = HistoryJournal(url: folder.appendingPathComponent("device/History.json"))
        let playedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [DeviceHistoryEvent(id: HistoryJournal.newId(), trackId: ids[0], kind: .play, value: 200, atMs: 1_800_000_000_000),
                      DeviceHistoryEvent(id: HistoryJournal.newId(), trackId: ids[1], kind: .love, value: 0, atMs: 1_800_000_100_000)]
        events.forEach(journal.record)
        #expect(HistoryJournal(url: folder.appendingPathComponent("device/History.json")).pending == events)
        var journaled = sync
        journaled.journal = journal
        _ = try await journaled.run()
        #expect(journal.pending.isEmpty)
        let played = try #require(try await mac.writer.read { try Track.fetchOne($0, key: ids[0]) })
        #expect(played.playCount == 1)
        #expect(played.lastPlayedAt == playedAt)
        #expect(try await mac.writer.read { try Track.fetchOne($0, key: ids[1]) }?.isLoved == false)
        #expect(try await device.writer.read { try Track.fetchOne($0, key: ids[1]) }?.isLoved == false)
        try await client.history(events)
        #expect(try await mac.writer.read { try Track.fetchOne($0, key: ids[0]) }?.playCount == 1)

        // The Mac's whole library, then not again while it has not changed; an album asked for (in Opus), and its cover.
        let (catalog, tag) = try #require(try await client.catalog(tag: nil))
        #expect(Set(catalog.songs.map(\.id)) == Set(ids))
        #expect(catalog.albums.map(\.title) == ["LP"])
        #expect(try await client.catalog(tag: tag) == nil)
        let chosen = try await client.requests([TransferRequest(id: "r1", action: .add, kind: .album, key: catalog.albums[0].key, encoding: "opus160")])
        #expect(chosen.albumKeys == [catalog.albums[0].key])
        #expect(chosen.encodings["album:\(catalog.albums[0].key)"] == "opus160")
        #expect(try await client.catalog(tag: tag)?.catalog.chosen.albumKeys == [catalog.albums[0].key])
        #expect(try await client.catalogArtwork("cover1") == image)
        #expect(try await client.catalogArtwork("nothing") == nil)

        // A sync cut short between putting a song in place and recording it: the next one replaces it, not writes the
        // song again beside it.
        var manifest = DeviceManifest.read(from: deviceMusic)
        let cut = try #require(manifest.entries.keys.sorted().first)
        manifest.entries[cut] = nil
        try manifest.write(to: deviceMusic)
        let third = try await sync.run()
        #expect(third.written == 1)
        #expect(third.failed.isEmpty)
        #expect(CompanionSync.files(in: deviceMusic).count == 2)
        #expect(DeviceManifest.read(from: deviceMusic).entries[cut] != nil)
    }

    @Test func followsTheMusicFolderWhenItMoves() throws {
        let database = try LibraryDatabase.inMemory()
        let snapshot = DeviceSnapshot(createdAt: .now, songs: [
            DeviceSnapshot.Song(id: 7, path: "Band/LP/01 One.flac", title: "One", artist: "Band", albumKey: "band\u{1F}lp", discNumber: 1,
                                trackNumber: 1, genre: nil, year: 2001, duration: 200, codec: "alac", sampleRate: 96_000, bitDepth: 24,
                                trackGain: -3, albumGain: nil, loudness: nil, loved: false, lovedAt: nil, rating: 0, playCount: 3,
                                lastPlayed: nil, dateAdded: .now, lyrics: nil, artworkHash: nil),
        ], albums: [DeviceSnapshot.Album(key: "band\u{1F}lp", title: "LP", artist: "Band", year: 2001, isCompilation: false, artworkHash: nil)],
        playlists: [])
        try database.importSnapshot(snapshot, musicFolder: URL(fileURLWithPath: "/old/container/Music"))
        try database.relocateDeviceMusic(to: URL(fileURLWithPath: "/new/container/Music"))
        let track = try #require(try database.writer.read { try LibraryDatabase.track($0, id: 7) })
        #expect(track.path == "/new/container/Music/Band/LP/01 One.flac")
        #expect(AudioSpec.Codec(formatName: track.format) == .alac)
        #expect(track.sampleRate == 96_000)
        #expect(try database.writer.read { try LibraryDatabase.roots($0) }.map(\.path) == ["/new/container/Music"])
    }

    /// Wi-Fi drops halfway through a song: the download picks up where it stopped (Range with the Mac's ETag), the
    /// whole file is checked against the SHA-256 and recorded in the manifest.
    @Test(.timeLimit(.minutes(1))) func resumesACutDownload() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = Data((0..<2_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let server = try CuttingServer(file: file)
        defer { server.stop() }
        let port = try await server.start()

        let client = MacClient(host: "127.0.0.1", port: port, deviceId: "phone-1", key: nil)
        let downloads = FileDownloads(configuration: .ephemeral, musicFolder: folder)
        let entry = DeviceManifest.Entry(kind: .song, trackId: 1, fingerprint: "f", size: Int64(file.count), synced: true)
        let write = WirelessProtocol.SyncPlan.Write(index: 0, path: "Band/LP/01 One.flac", size: Int64(file.count), entry: entry)
        let outcomes = try await downloads.download([write], client: client, session: "s", token: "t") { _, _ in }

        #expect(try outcomes[write.path]?.get() == Int64(file.count))
        #expect(try Data(contentsOf: folder.appendingPathComponent(write.path)) == file)
        #expect(DeviceManifest.read(from: folder).entries[write.path]?.size == Int64(file.count))
        let requests = server.requests
        #expect(requests.count == 2)
        #expect(requests.last?["range"] == "bytes=\(CuttingServer.cut)-")
        #expect(requests.last?["if-range"] == "\"\(MacClient.sha256(file))\"")
    }

    /// A small valid image, as the Mac's covers are.
    static func png() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

/// Test certificates, made one at a time: the login keychain refuses a key made while another test makes one.
enum TestKeychain {
    private static let lock = NSLock()

    static func identity(label: String) throws -> (identity: SecIdentity, fingerprint: String) {
        try lock.withLock { try TLSIdentity.load(label: label) }
    }
}

/// Serves one file as the Mac does (ETag, Accept-Ranges, SHA-256), but the first time it stops halfway and drops the
/// connection, as when Wi-Fi goes.
final class CuttingServer: @unchecked Sendable {
    static let cut = 600_000
    let file: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cutting-server")
    private let lock = NSLock()
    private var received: [[String: String]] = []

    var requests: [[String: String]] { lock.withLock { received } }

    init(file: Data) throws {
        self.file = file
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> Int {
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .main)
            self?.read(connection, buffer: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: continuation.resume(returning: Int(listener.port?.rawValue ?? 0))
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self, error == nil, let data else { return connection.cancel() }
            let buffer = buffer + data
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return self.read(connection, buffer: buffer) }
            var headers: [String: String] = [:]
            for line in String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n").dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let first = self.lock.withLock { () -> Bool in
                self.received.append(headers)
                return self.received.count == 1
            }
            self.respond(on: connection, headers: headers, first: first)
        }
    }

    private func respond(on connection: NWConnection, headers: [String: String], first: Bool) {
        let tag = "\"\(MacClient.sha256(file))\""
        var start = 0
        if let range = headers["range"], headers["if-range"] == tag, let from = Int(range.dropFirst(6).dropLast()) { start = from }
        var head = start > 0 ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        head += "Content-Length: \(file.count - start)\r\nETag: \(tag)\r\nAccept-Ranges: bytes\r\n"
        head += "\(WirelessProtocol.Header.sha256): \(MacClient.sha256(file))\r\nConnection: close\r\n"
        if start > 0 { head += "Content-Range: bytes \(start)-\(file.count - 1)/\(file.count)\r\n" }
        head += "\r\n"
        if first {
            // Half the song, then the connection goes.
            connection.send(content: Data(head.utf8) + file.prefix(Self.cut), completion: .contentProcessed { _ in
                self.queue.asyncAfter(deadline: .now() + 0.3) { connection.forceCancel() }
            })
        } else {
            connection.send(content: Data(head.utf8) + file[start...], contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in })
        }
    }
}
