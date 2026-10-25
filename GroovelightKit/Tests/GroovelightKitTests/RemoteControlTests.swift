import CryptoKit
import Foundation
import Testing
import WirelessSync
@testable import WirelessSyncClient

/// Playing on the Mac from a paired device: the player's state and commands over HTTPS, refused for devices the Mac
/// does not let control it, and the state waited on until it changes.
struct RemoteControlTests {
    /// The Mac's player, as the app's backend sees it.
    final class Player: @unchecked Sendable {
        private let lock = NSLock()
        private var state = WirelessProtocol.RemoteState(item: nil, playing: false, position: 0, volume: 0.8, shuffle: false, repeatMode: "off",
                                                         queue: [], queueIndex: nil)
        /// When `state.position` was true (the song moves on from there while playing).
        private var positionAt = Date.now
        var allowed = true
        private(set) var commands: [WirelessProtocol.RemoteCommand] = []

        var current: WirelessProtocol.RemoteState? { lock.withLock { allowed ? now() : nil } }

        private func now() -> WirelessProtocol.RemoteState {
            var now = state
            if now.playing { now.position += Date.now.timeIntervalSince(positionAt) }
            return now
        }

        func apply(_ command: WirelessProtocol.RemoteCommand) -> WirelessProtocol.RemoteState? {
            lock.withLock {
                guard allowed else { return nil }
                commands.append(command)
                state = now()
                positionAt = .now
                switch command {
                case let .play(ids, start, position, shuffle):
                    state.queue = ids
                    state.queueIndex = start
                    state.item = .init(id: ids[start], title: "Song \(ids[start])", artist: "Band", album: "LP", albumKey: "band\u{1F}lp",
                                       artworkHash: nil, duration: 200)
                    state.position = position
                    state.playing = true
                    state.shuffle = shuffle
                case .pause: state.playing = false
                case .resume: state.playing = true
                case .seek(let position): state.position = position
                case .volume(let volume): state.volume = volume
                default: break
                }
                return now()
            }
        }
    }

    @Test(.timeLimit(.minutes(1))) func controlsTheMacsPlayer() async throws {
        let label = "dev.irwingbraga.groovelight.test-\(UUID().uuidString)"
        defer { TLSIdentity.remove(label: label) }
        let tls = try TestKeychain.identity(label: label)
        let key = SymmetricKey(size: .bits256)
        let player = Player()
        let backend = WirelessSyncServer.Backend(
            info: { WirelessProtocol.Info(id: "mac-1", name: "Test Mac") },
            pairRequested: { _, _ in }, pairStatus: { _ in "accepted" },
            key: { $0 == "phone-1" ? key : nil },
            plan: { _, _ in throw CocoaError(.featureUnsupported) },
            cover: { _, _ in nil }, finished: { _, _ in },
            status: { _ in WirelessProtocol.Status(syncRequested: false, pendingSends: 0) },
            remoteState: { _ in player.current },
            remote: { _, command in player.apply(command) })
        let server = WirelessSyncServer(backend: backend)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            server.start(name: "Groovelight Remote Test \(UUID().uuidString.prefix(4))", tls: (tls.identity, tls.fingerprint)) { port in
                if let port { continuation.resume(returning: port) } else { continuation.resume(throwing: CocoaError(.featureUnsupported)) }
            }
        }
        defer { server.stop() }
        let tlsPort = try #require(try await MacClient(host: "127.0.0.1", port: Int(port), deviceId: "phone-1", key: nil).info().tlsPort)
        let client = MacClient(host: "127.0.0.1", port: Int(port), deviceId: "phone-1", key: key, tls: .init(port: tlsPort, fingerprint: tls.fingerprint))

        // Nothing playing yet; then a queue handed over, at 42 seconds into its second song.
        let idle = try await client.remoteState()
        #expect(idle.item == nil)
        #expect(!idle.version.isEmpty)
        let playing = try await client.remote(.play(songIds: [7, 8, 9], startAt: 1, position: 42, shuffle: false))
        #expect(playing.item?.id == 8)
        #expect(playing.playing)
        #expect(abs(playing.position - 42) < 1)
        #expect(playing.queue == [7, 8, 9])
        #expect(playing.version != idle.version)

        // Waiting on a version: answered as soon as something changes on the Mac (here, paused there).
        let started = Date.now
        Task {
            try await Task.sleep(for: .milliseconds(600))
            _ = player.apply(.pause)
        }
        let paused = try await client.remoteState(after: playing.version)
        #expect(!paused.playing)
        #expect(Date.now.timeIntervalSince(started) >= 0.5)
        #expect(Date.now.timeIntervalSince(started) < 5)

        try await client.remote(.volume(0.3))
        #expect(try await client.remoteState().volume == 0.3)

        // A device the Mac does not let control it.
        player.allowed = false
        await #expect(throws: MacError.self) { try await client.remoteState() }
        do {
            try await client.remote(.resume)
            Issue.record("A command went through")
        } catch let error as MacError {
            #expect(error.status == 403)
        }
        #expect(player.commands.count == 3)
    }

    /// One phone plays on another through the Mac: the other phone waits for commands there, applies them to its own
    /// player and reports it; the first lists it, sends it a queue, and follows it.
    @Test(.timeLimit(.minutes(1))) func playsOnAnotherDeviceThroughTheMac() async throws {
        let label = "dev.irwingbraga.groovelight.test-\(UUID().uuidString)"
        defer { TLSIdentity.remove(label: label) }
        let tls = try TestKeychain.identity(label: label)
        let keys = ["phone-1": SymmetricKey(size: .bits256), "phone-2": SymmetricKey(size: .bits256)]
        let backend = WirelessSyncServer.Backend(
            info: { WirelessProtocol.Info(id: "mac-1", name: "Test Mac") },
            pairRequested: { _, _ in }, pairStatus: { _ in "accepted" },
            key: { keys[$0] },
            plan: { _, _ in throw CocoaError(.featureUnsupported) },
            cover: { _, _ in nil }, finished: { _, _ in },
            status: { _ in WirelessProtocol.Status(syncRequested: false, pendingSends: 0) },
            mayControl: { $0 == "phone-1" },
            deviceName: { $0 == "phone-1" ? "Ana's iPhone" : "Pixel" })
        let server = WirelessSyncServer(backend: backend)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            server.start(name: "Groovelight Relay Test \(UUID().uuidString.prefix(4))", tls: (tls.identity, tls.fingerprint)) { port in
                if let port { continuation.resume(returning: port) } else { continuation.resume(throwing: CocoaError(.featureUnsupported)) }
            }
        }
        defer { server.stop() }
        let tlsPort = try #require(try await MacClient(host: "127.0.0.1", port: Int(port), deviceId: "phone-1", key: nil).info().tlsPort)
        func client(_ id: String) -> MacClient {
            MacClient(host: "127.0.0.1", port: Int(port), deviceId: id, key: keys[id], tls: .init(port: tlsPort, fingerprint: tls.fingerprint))
        }
        let controller = client("phone-1"), pixel = client("phone-2")

        // Not there yet.
        #expect(try await controller.remoteDevices().isEmpty)
        await #expect(throws: MacError.self) { try await controller.remote(.pause, device: "phone-2") }

        // The Pixel waits for commands and plays what it is sent.
        let player = Player()
        let start = try await pixel.relayCommands(after: nil)
        #expect(start.commands.isEmpty)
        let receiver = Task {
            var last = start.last
            while !Task.isCancelled {
                guard let answer = try? await pixel.relayCommands(after: last) else { return }
                for relayed in answer.commands {
                    #expect(relayed.from == "phone-1")
                    #expect(relayed.fromName == "Ana's iPhone")
                    _ = player.apply(relayed.command)
                    last = relayed.seq
                }
                if !answer.commands.isEmpty { try? await pixel.relayState(player.current, applied: last) }
            }
        }
        defer { receiver.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await controller.remoteDevices() == [WirelessProtocol.RemoteDevice(id: "phone-2", name: "Pixel")])
        // Only devices the Mac lets control playback see it.
        await #expect(throws: MacError.self) { try await pixel.remoteDevices() }

        let playing = try await controller.remote(.play(songIds: [7, 8], startAt: 1, position: 30, shuffle: false), device: "phone-2")
        #expect(playing.item?.id == 8)
        #expect(playing.playing)
        #expect(abs(playing.position - 30) < 1)

        // Followed: a pause made on the Pixel itself reaches the controller.
        let started = Date.now
        Task {
            try await Task.sleep(for: .milliseconds(500))
            _ = player.apply(.pause)
            try await pixel.relayState(player.current, applied: start.last + 1)
        }
        let paused = try await controller.remoteState(after: playing.version, device: "phone-2")
        #expect(!paused.playing)
        #expect(Date.now.timeIntervalSince(started) < 5)

        // Nobody by that name.
        do {
            _ = try await controller.remoteState(device: "phone-9")
            Issue.record("An unknown device answered")
        } catch let error as MacError {
            #expect(error.status == 404)
        }
    }

    /// The commands as Groovelight for Android writes them (flat objects), and back.
    @Test func commandsAreFlatJSON() throws {
        let decode = { (json: String) in try WirelessProtocol.decoder.decode(WirelessProtocol.RemoteCommand.self, from: Data(json.utf8)) }
        #expect(try decode(#"{"command":"seek","position":42.5}"#) == .seek(42.5))
        #expect(try decode(#"{"command":"play","songIds":[7,8],"startAt":1,"position":3,"shuffle":false}"#)
                == .play(songIds: [7, 8], startAt: 1, position: 3, shuffle: false))
        #expect(try decode(#"{"command":"play","songIds":[7]}"#) == .play(songIds: [7], startAt: 0, position: 0, shuffle: false))
        #expect(try decode(#"{"command":"pause"}"#) == .pause)
        #expect(try decode(#"{"command":"volume","volume":0.5}"#) == .volume(0.5))
        #expect(try decode(#"{"command":"shuffle","on":true}"#) == .shuffle(true))
        #expect(try decode(#"{"command":"repeatMode","mode":"all"}"#) == .repeatMode("all"))
        #expect(throws: DecodingError.self) { try decode(#"{"command":"explode"}"#) }
        let seek = String(decoding: try WirelessProtocol.encoder.encode(WirelessProtocol.RemoteCommand.seek(12)), as: UTF8.self)
        #expect(seek == #"{"command":"seek","position":12}"#)
        for command: WirelessProtocol.RemoteCommand in [.play(songIds: [1, 2], startAt: 1, position: 9, shuffle: true), .resume, .next, .previous,
                                                        .stop, .volume(0.25), .shuffle(false), .repeatMode("one")] {
            #expect(try WirelessProtocol.decoder.decode(WirelessProtocol.RemoteCommand.self, from: WirelessProtocol.encoder.encode(command)) == command)
        }
    }

    @Test func versionIgnoresSteadyPlayingButNotASeek() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var state = WirelessProtocol.RemoteState(item: .init(id: 1, title: "A", artist: "B", album: "C", albumKey: nil, artworkHash: nil, duration: 300),
                                                 playing: true, position: 10, volume: 1, shuffle: false, repeatMode: "off", queue: [1], queueIndex: 0)
        let first = state.signature(now: start)
        state.position = 20
        #expect(state.signature(now: start.addingTimeInterval(10)) == first)
        state.position = 120
        #expect(state.signature(now: start.addingTimeInterval(11)) != first)
    }
}
