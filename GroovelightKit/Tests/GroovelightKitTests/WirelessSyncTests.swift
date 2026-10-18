import CryptoKit
import Foundation
import Testing
@testable import LibraryKit
@testable import WirelessSync

struct WirelessSyncTests {
    /// Fixed keys, so the Android app's own test can check it derives the same code and key.
    static let devicePrivate = Data((1...32).map { UInt8($0) })
    static let macPrivate = Data((33...64).map { UInt8($0) })

    @Test func bothSidesDeriveTheSameCodeAndKey() throws {
        let device = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.devicePrivate)
        let mac = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.macPrivate)
        let pairing = try WirelessProtocol.Pairing(privateKey: mac, devicePublicKey: device.publicKey.rawRepresentation)

        // The device's side, from the Mac's public key.
        let secret = try device.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: pairing.macPublicKey))
        let (key, code) = WirelessProtocol.derive(secret: secret.withUnsafeBytes { Data($0) }, macPublicKey: pairing.macPublicKey,
                                                   devicePublicKey: device.publicKey.rawRepresentation)
        #expect(code == pairing.code)
        #expect(key == pairing.key)
        #expect(code.count == 6 && code.allSatisfy(\.isNumber))
        // The vector the Android test checks (see android/app/src/test).
        #expect(device.publicKey.rawRepresentation.base64EncodedString() == "B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw=")
        #expect(code == Self.vectorCode)
        #expect(Self.vectorSignature == WirelessProtocol.signature(method: "post", path: "/sync", time: 1_700_000_000, nonce: "n1",
                                                                     body: Data("{}".utf8), key: key))
        #expect(pairing.macPublicKey.base64EncodedString() == "WGmv9FBUlzLLqu1eXfmzCm2jHLDldCutWtShp2jxpns=")
    }

    static let vectorCode = "328727"
    static let vectorSignature = "lpDhU3RKuAhlJ1Osb2X4F88i0R6pUe5J//UAaIQxHFs="

    @Test func signaturesCoverTheWholeRequestAndExpire() {
        let key = SymmetricKey(size: .bits256)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let body = Data("{\"a\":1}".utf8)
        let signature = WirelessProtocol.signature(method: "POST", path: "/sync", time: 1_700_000_000, nonce: "n", body: body, key: key)
        #expect(WirelessProtocol.isValid(signature: signature, method: "POST", path: "/sync", time: 1_700_000_000, nonce: "n", body: body, key: key, now: now))
        #expect(!WirelessProtocol.isValid(signature: signature, method: "POST", path: "/sync", time: 1_700_000_000, nonce: "n",
                                          body: Data("{\"a\":2}".utf8), key: key, now: now))
        #expect(!WirelessProtocol.isValid(signature: signature, method: "GET", path: "/sync", time: 1_700_000_000, nonce: "n", body: body, key: key, now: now))
        #expect(!WirelessProtocol.isValid(signature: signature, method: "POST", path: "/sync", time: 1_700_000_000, nonce: "n", body: body,
                                          key: SymmetricKey(size: .bits256), now: now))
        #expect(!WirelessProtocol.isValid(signature: signature, method: "POST", path: "/sync", time: 1_700_000_000, nonce: "n", body: body, key: key,
                                          now: now.addingTimeInterval(600)))
    }

    @Test func parsesRanges() {
        #expect(LocalHTTPServer.parseRange("bytes=100-", size: 1000)! == (100, 999))
        #expect(LocalHTTPServer.parseRange("bytes=100-199", size: 1000)! == (100, 199))
        #expect(LocalHTTPServer.parseRange("bytes=-10", size: 1000)! == (990, 999))
        #expect(LocalHTTPServer.parseRange("bytes=2000-", size: 1000) == nil)
    }

    /// The whole exchange against a real server on this Mac: info, pairing, a signed sync, a file in full and resumed
    /// from an offset, and the result; a replayed request is refused.
    @Test(.timeLimit(.minutes(1))) func pairsSyncsAndServesFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-wireless-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let song = folder.appendingPathComponent("song.flac")
        let bytes = Data((0..<3_000_000).map { UInt8($0 % 251) })
        try bytes.write(to: song)

        final class State: @unchecked Sendable {
            var pairing: WirelessProtocol.Pairing?
            var accepted = false
            var result: WirelessProtocol.SyncResult?
            var sawFiles: [String] = []
        }
        let state = State()
        var made = LibraryDatabaseTests.makeTrack(rootId: 1, "Song", artist: "Band", album: "LP", number: 1)
        made.id = 7
        made.path = song.path
        made.fileSize = Int64(bytes.count)
        let track = made
        let backend = WirelessSyncServer.Backend(
            info: { WirelessProtocol.Info(id: "mac-1", name: "Test Mac") },
            pairRequested: { _, pairing in state.pairing = pairing },
            pairStatus: { _ in state.accepted ? "accepted" : "pending" },
            key: { id in id == "phone-1" && state.accepted ? state.pairing?.key : nil },
            plan: { _, request in
                state.sawFiles = request.files
                let plan = DeviceSync.plan(tracks: [track], playlists: [DevicePlaylist(name: "Mix", tracks: [track])],
                                           profile: DeviceProfile(), manifest: request.manifest ?? DeviceManifest(), mode: .sync,
                                           root: URL(fileURLWithPath: "/device")) { request.files.contains($0) }
                return (plan, DeviceProfile())
            },
            cover: { _, _ in nil },
            finished: { _, result in state.result = result },
            status: { _ in WirelessProtocol.Status(syncRequested: true, pendingSends: 0) })
        let server = WirelessSyncServer(backend: backend)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            server.start(name: "Groovelight Test \(UUID().uuidString.prefix(4))") { port in
                if let port { continuation.resume(returning: port) } else { continuation.resume(throwing: CocoaError(.featureUnsupported)) }
            }
        }
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!

        func call(_ method: String, _ path: String, body: Data = Data(), key: SymmetricKey? = nil, time: Int = Int(Date.now.timeIntervalSince1970),
                  nonce: String = UUID().uuidString, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.httpMethod = method
            if !body.isEmpty { request.httpBody = body }
            if let key {
                request.setValue("phone-1", forHTTPHeaderField: WirelessProtocol.Header.device)
                request.setValue("\(time)", forHTTPHeaderField: WirelessProtocol.Header.time)
                request.setValue(nonce, forHTTPHeaderField: WirelessProtocol.Header.nonce)
                request.setValue(WirelessProtocol.signature(method: method, path: path, time: time, nonce: nonce, body: body, key: key),
                                 forHTTPHeaderField: WirelessProtocol.Header.signature)
            }
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, response as! HTTPURLResponse)
        }

        let (infoData, _) = try await call("GET", "/info")
        #expect(try WirelessProtocol.decoder.decode(WirelessProtocol.Info.self, from: infoData).name == "Test Mac")

        // Pairing: the device's key pair, the Mac's answer, the same code on both sides.
        let device = Curve25519.KeyAgreement.PrivateKey()
        let pairBody = try WirelessProtocol.encoder.encode(WirelessProtocol.PairRequest(
            deviceId: "phone-1", name: "Pixel", model: "Pixel 8", publicKey: device.publicKey.rawRepresentation.base64EncodedString()))
        let (pairData, _) = try await call("POST", "/pair", body: pairBody)
        let answer = try WirelessProtocol.decoder.decode(WirelessProtocol.PairResponse.self, from: pairData)
        let secret = try device.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: Data(base64Encoded: answer.publicKey)!))
        let (key, code) = WirelessProtocol.derive(secret: secret.withUnsafeBytes { Data($0) }, macPublicKey: Data(base64Encoded: answer.publicKey)!,
                                                   devicePublicKey: device.publicKey.rawRepresentation)
        #expect(code == state.pairing?.code)
        // Not usable before the user allows it on the Mac.
        #expect(try await call("GET", "/status", key: key).1.statusCode == 401)
        #expect(try WirelessProtocol.decoder.decode(WirelessProtocol.PairStatus.self, from: try await call("GET", "/pair/phone-1").0).status == "pending")
        state.accepted = true

        let (statusData, statusResponse) = try await call("GET", "/status", key: key)
        #expect(statusResponse.statusCode == 200)
        #expect(try WirelessProtocol.decoder.decode(WirelessProtocol.Status.self, from: statusData).syncRequested)

        // A signed request cannot be sent twice, nor with another key.
        let time = Int(Date.now.timeIntervalSince1970)
        #expect(try await call("GET", "/status", key: key, time: time, nonce: "once").1.statusCode == 200)
        #expect(try await call("GET", "/status", key: key, time: time, nonce: "once").1.statusCode == 401)
        #expect(try await call("GET", "/status", key: SymmetricKey(size: .bits256)).1.statusCode == 401)

        // The plan, then the song in full and from an offset (a resumed download), then the result.
        let syncBody = try WirelessProtocol.encoder.encode(WirelessProtocol.SyncRequest(manifest: nil, files: ["Music/other.mp3"],
                                                                                        capacity: 1_000_000_000, available: 500_000_000))
        let (planData, planResponse) = try await call("POST", "/sync", body: syncBody, key: key)
        #expect(planResponse.statusCode == 200)
        let plan = try WirelessProtocol.decoder.decode(WirelessProtocol.SyncPlan.self, from: planData)
        #expect(state.sawFiles == ["Music/other.mp3"])
        #expect(plan.writes.map(\.path) == ["Music/Band/LP (1969)/01 Song.flac", "Playlists/Mix.m3u8"])
        let songWrite = try #require(plan.writes.first)
        let filePath = "/sync/\(plan.session)/file/\(songWrite.index)"
        let (whole, wholeResponse) = try await call("GET", filePath, key: key)
        #expect(wholeResponse.statusCode == 200)
        #expect(whole == bytes)
        let (tail, tailResponse) = try await call("GET", filePath, key: key, headers: ["Range": "bytes=2000000-"])
        #expect(tailResponse.statusCode == 206)
        #expect(tail == bytes.suffix(from: 2_000_000))
        let (playlist, _) = try await call("GET", "/sync/\(plan.session)/file/1", key: key)
        #expect(String(data: playlist, encoding: .utf8)?.contains("../Music/Band/LP (1969)/01 Song.flac") == true)

        let result = try WirelessProtocol.encoder.encode(WirelessProtocol.SyncResult(written: 2, deleted: 0, failed: [], available: 1))
        #expect(try await call("POST", "/sync/\(plan.session)/done", body: result, key: key).1.statusCode == 200)
        #expect(state.result?.written == 2)
        // The session is over.
        #expect(try await call("GET", filePath, key: key).1.statusCode == 404)
    }

    @Test func makesAValidSelfSignedCertificate() throws {
        let key = try #require(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256] as CFDictionary, nil))
        let der = try TLSIdentity.makeCertificate(privateKey: key, commonName: "Groovelight", now: Date(timeIntervalSince1970: 1_800_000_000))
        let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))
        #expect(SecCertificateCopySubjectSummary(certificate) as String? == "Groovelight")
        // Its public key is the key's, and its signature checks with it (self-signed).
        let publicKey = try #require(SecCertificateCopyKey(certificate))
        #expect(SecKeyCopyExternalRepresentation(publicKey, nil) as Data? == SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(key)!, nil) as Data?)
        var trust: SecTrust?
        SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust)
        SecTrustSetAnchorCertificates(trust!, [certificate] as CFArray)
        SecTrustSetVerifyDate(trust!, Date(timeIntervalSince1970: 1_800_000_000) as CFDate)
        #expect(SecTrustEvaluateWithError(trust!, nil))
        #expect(TLSIdentity.fingerprint(of: certificate).count == 64)
        #expect(DER.oid("1.2.840.10045.4.3.2") == Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]))
    }

    /// Version 2 against a real HTTPS server: the device pins the certificate from a proof only the paired Mac can make,
    /// gets a player plan (an ALAC song converted to FLAC), downloads with the plan's token and checks each file's
    /// SHA-256, and gets the library snapshot. The token does not work in plain HTTP.
    @Test(.timeLimit(.minutes(1))) func servesPlayersOverTLS() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-tls-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let flacSource = folder.appendingPathComponent("a.flac"), alacSource = folder.appendingPathComponent("b.m4a")
        let converted = folder.appendingPathComponent("b-converted.flac")
        try Data(repeating: 1, count: 100_000).write(to: flacSource)
        try Data(repeating: 2, count: 50_000).write(to: alacSource)
        try Data(repeating: 3, count: 60_000).write(to: converted)
        var a = LibraryDatabaseTests.makeTrack(rootId: 1, "One", artist: "Band", album: "LP", number: 1)
        a.id = 1; a.path = flacSource.path; a.format = "FLAC"
        var b = LibraryDatabaseTests.makeTrack(rootId: 1, "Two", artist: "Band", album: "LP", number: 2)
        b.id = 2; b.path = alacSource.path; b.format = "Apple Lossless"
        let tracks = [a, b]

        let label = "dev.irwingbraga.groovelight.test-\(UUID().uuidString)"
        defer { TLSIdentity.remove(label: label) }
        let tls = try TLSIdentity.load(label: label)
        // Loading again gives the same certificate.
        #expect(try TLSIdentity.load(label: label).fingerprint == tls.fingerprint)

        let key = SymmetricKey(size: .bits256)
        final class Seen: @unchecked Sendable { var snapshot: [Int64: String] = [:]; var codecs: [Int64: String] = [:] }
        let seen = Seen()
        let backend = WirelessSyncServer.Backend(
            info: { WirelessProtocol.Info(id: "mac-1", name: "Test Mac") },
            pairRequested: { _, _ in }, pairStatus: { _ in "accepted" },
            key: { $0 == "phone-1" ? key : nil },
            plan: { _, request in
                let player = request.isPlayer ? DeviceSync.Player(decodes: Set(request.decodes ?? [])) : nil
                let plan = DeviceSync.plan(tracks: tracks, playlists: [], profile: DeviceProfile(), manifest: DeviceManifest(), mode: .sync,
                                           root: URL(fileURLWithPath: "/device"), player: player)
                return (plan, DeviceProfile())
            },
            cover: { _, _ in Data([0xFF, 0xD8]) },
            finished: { _, _ in },
            status: { _ in WirelessProtocol.Status(syncRequested: false, pendingSends: 0) },
            flac: { source, fingerprint in
                #expect(source == alacSource && fingerprint.hasSuffix("|flac"))
                return converted
            },
            snapshot: { _, paths, codecs in
                seen.snapshot = paths
                seen.codecs = codecs
                return Data("{\"songs\":2}".utf8)
            })
        let server = WirelessSyncServer(backend: backend)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            server.start(name: "Groovelight TLS Test \(UUID().uuidString.prefix(4))", tls: (tls.identity, tls.fingerprint)) { port in
                if let port { continuation.resume(returning: port) } else { continuation.resume(throwing: CocoaError(.featureUnsupported)) }
            }
        }
        defer { server.stop() }
        let (infoData, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/info")!)
        let info = try WirelessProtocol.decoder.decode(WirelessProtocol.Info.self, from: infoData)
        #expect(info.version == 2)
        let tlsPort = try #require(info.tlsPort)

        /// Trusts any certificate (as a device does before pinning) and remembers the one the server showed.
        final class Pinning: NSObject, URLSessionDelegate, @unchecked Sendable {
            var seen: String?
            func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
                -> (URLSession.AuthChallengeDisposition, URLCredential?) {
                guard let trust = challenge.protectionSpace.serverTrust,
                      let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
                    return (.cancelAuthenticationChallenge, nil)
                }
                seen = TLSIdentity.fingerprint(of: leaf)
                return (.useCredential, URLCredential(trust: trust))
            }
        }
        let pinning = Pinning()
        let session = URLSession(configuration: .ephemeral, delegate: pinning, delegateQueue: nil)
        func call(_ method: String, _ path: String, query: String = "", body: Data = Data(), signed: Bool = true, secure: Bool = true,
                  headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: URL(string: secure ? "https://127.0.0.1:\(tlsPort)\(path)\(query)" : "http://127.0.0.1:\(port)\(path)\(query)")!)
            request.httpMethod = method
            if !body.isEmpty { request.httpBody = body }
            if signed {
                let time = Int(Date.now.timeIntervalSince1970), nonce = UUID().uuidString
                request.setValue("phone-1", forHTTPHeaderField: WirelessProtocol.Header.device)
                request.setValue("\(time)", forHTTPHeaderField: WirelessProtocol.Header.time)
                request.setValue(nonce, forHTTPHeaderField: WirelessProtocol.Header.nonce)
                request.setValue(WirelessProtocol.signature(method: method, path: path, time: time, nonce: nonce, body: body, key: key),
                                 forHTTPHeaderField: WirelessProtocol.Header.signature)
            }
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            let (data, response) = try await session.data(for: request)
            return (data, response as! HTTPURLResponse)
        }

        // Pinning, before any HTTPS: the proof checks with the pairing key, and names the certificate HTTPS then shows.
        let nonce = UUID().uuidString
        let (certificateData, certificateResponse) = try await call("GET", "/certificate", query: "?nonce=\(nonce)", secure: false)
        #expect(certificateResponse.statusCode == 200)
        let certificate = try WirelessProtocol.decoder.decode(WirelessProtocol.Certificate.self, from: certificateData)
        #expect(certificate.fingerprint == tls.fingerprint)
        #expect(certificate.proof == WirelessProtocol.certificateProof(fingerprint: certificate.fingerprint, nonce: nonce, key: key))
        // A request without a nonce gets nothing.
        #expect(try await call("GET", "/certificate", secure: false).1.statusCode == 400)
        _ = try await call("GET", "/status")
        #expect(pinning.seen == certificate.fingerprint)

        // A player that decodes FLAC but not ALAC.
        let syncBody = try WirelessProtocol.encoder.encode(WirelessProtocol.SyncRequest(
            manifest: nil, files: [], capacity: 1_000_000_000, available: 500_000_000, mode: "player", decodes: ["flac", "mp3"]))
        let plan = try WirelessProtocol.decoder.decode(WirelessProtocol.SyncPlan.self, from: try await call("POST", "/sync", body: syncBody).0)
        let token = try #require(plan.token)
        #expect(plan.writes.map(\.path) == ["Music/Band/LP (1969)/01 One.flac", "Music/Band/LP (1969)/02 Two.flac"])
        for write in plan.writes {
            let (data, response) = try await call("GET", "/sync/\(plan.session)/file/\(write.index)", signed: false,
                                                  headers: [WirelessProtocol.Header.token: token])
            #expect(response.statusCode == 200)
            #expect(response.value(forHTTPHeaderField: WirelessProtocol.Header.sha256) == WirelessSyncServer.sha256(data))
            #expect(data.count == (write.path.hasSuffix("One.flac") ? 100_000 : 60_000))
        }
        let (snapshot, _) = try await call("GET", "/sync/\(plan.session)/snapshot", signed: false, headers: [WirelessProtocol.Header.token: token])
        #expect(String(data: snapshot, encoding: .utf8) == "{\"songs\":2}")
        #expect(seen.snapshot == [1: "Music/Band/LP (1969)/01 One.flac", 2: "Music/Band/LP (1969)/02 Two.flac"])
        #expect(seen.codecs == [2: "flac"])
        // The token is refused in plain HTTP, and a wrong one over TLS.
        #expect(try await call("GET", "/sync/\(plan.session)/file/0", signed: false, secure: false,
                               headers: [WirelessProtocol.Header.token: token]).1.statusCode == 401)
        #expect(try await call("GET", "/sync/\(plan.session)/file/0", signed: false, headers: [WirelessProtocol.Header.token: "nope"]).1.statusCode == 401)
    }

    @Test func sendsJoinTheSyncWithoutBecomingPartOfIt() throws {
        var a = LibraryDatabaseTests.makeTrack(rootId: 1, "One", artist: "Band", album: "First", number: 1)
        a.id = 1
        var b = LibraryDatabaseTests.makeTrack(rootId: 1, "Two", artist: "Band", album: "First", number: 2)
        b.id = 2
        let root = URL(fileURLWithPath: "/device")
        // Both synced before; now only One is selected, and Two was sent.
        var manifest = DeviceManifest()
        for track in [a, b] {
            let path = "Music/Band/First (1969)/0\(track.trackNumber!) \(track.title).flac"
            manifest.entries[path] = DeviceManifest.Entry(kind: .song, trackId: track.id,
                                                          fingerprint: "\(track.url.path)|\(track.fileSize)|\(Int(track.modifiedAt.timeIntervalSince1970))",
                                                          size: track.fileSize, synced: true)
        }
        let plan = DeviceSync.plan(syncing: ([a], []), sending: ([b], []), profile: DeviceProfile(), manifest: manifest, root: root) {
            manifest.entries[$0] != nil
        }
        #expect(plan.deletions.isEmpty)
        #expect(plan.writes.isEmpty)
        #expect(plan.unchanged.count == 2)
        // Two is a sent song now: a later sync without sends keeps it.
        #expect(plan.unchanged["Music/Band/First (1969)/02 Two.flac"]?.synced == false)
    }
}
