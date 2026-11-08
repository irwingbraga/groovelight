import CryptoKit
import Foundation
import Testing
@testable import WirelessSync

struct CatalogLyricsTests {
    /// A song's lyrics for a device playing it elsewhere without having it: over HTTPS, signed, 404 when there are none.
    @Test func lyricsOfTheMacsSongs() async throws {
        let key = SymmetricKey(size: .bits256)
        let server = WirelessSyncServer(backend: WirelessSyncServer.Backend(
            info: { WirelessProtocol.Info(id: "mac-1", name: "Test Mac") },
            pairRequested: { _, _ in },
            pairStatus: { _ in "accepted" },
            key: { $0 == "phone-1" ? key : nil },
            plan: { _, _ in throw CocoaError(.featureUnsupported) },
            cover: { _, _ in nil },
            finished: { _, _ in },
            status: { _ in WirelessProtocol.Status(syncRequested: false, pendingSends: 0) },
            lyrics: { $0 == 7 ? "[00:01.00]Ça va\n" : nil }))

        func request(_ path: String, secure: Bool = true) -> LocalHTTPServer.Request {
            let time = Int(Date.now.timeIntervalSince1970), nonce = UUID().uuidString
            let headers = [WirelessProtocol.Header.device: "phone-1", WirelessProtocol.Header.time: "\(time)", WirelessProtocol.Header.nonce: nonce,
                           WirelessProtocol.Header.signature: WirelessProtocol.signature(method: "GET", path: path, time: time, nonce: nonce,
                                                                                          body: Data(), key: key)]
            var request = LocalHTTPServer.Request(method: "GET", path: path, query: [:], headers: headers, body: Data(), remote: "test")
            request.secure = secure
            return request
        }

        let found = await server.handle(request("/catalog/lyrics/7"))
        #expect(found.status == 200)
        if case .data(let data) = found.body { #expect(String(decoding: data, as: UTF8.self) == "[00:01.00]Ça va\n") } else { Issue.record("no body") }
        #expect(await server.handle(request("/catalog/lyrics/8")).status == 404)
        #expect(await server.handle(request("/catalog/lyrics/7", secure: false)).status == 403)
    }
}

struct HomeRouteTests {
    /// Home for a device: over HTTPS, signed, deflated with its SHA-256 as the ETag, 304 when the device has it.
    @Test func servesHome() async throws {
        let key = SymmetricKey(size: .bits256)
        let json = Data(#"{"day":20400,"song":[],"album":[],"artist":[],"stats":[]}"#.utf8)
        let server = WirelessSyncServer(backend: WirelessSyncServer.Backend(
            info: { WirelessProtocol.Info(id: "mac-1", name: "Test Mac") },
            pairRequested: { _, _ in },
            pairStatus: { _ in "accepted" },
            key: { $0 == "phone-1" ? key : nil },
            plan: { _, _ in throw CocoaError(.featureUnsupported) },
            cover: { _, _ in nil },
            finished: { _, _ in },
            status: { _ in WirelessProtocol.Status(syncRequested: false, pendingSends: 0) },
            home: { _ in json }))

        func request(_ tag: String? = nil, secure: Bool = true) -> LocalHTTPServer.Request {
            let time = Int(Date.now.timeIntervalSince1970), nonce = UUID().uuidString
            var headers = [WirelessProtocol.Header.device: "phone-1", WirelessProtocol.Header.time: "\(time)", WirelessProtocol.Header.nonce: nonce,
                           WirelessProtocol.Header.signature: WirelessProtocol.signature(method: "GET", path: "/home", time: time, nonce: nonce,
                                                                                          body: Data(), key: key)]
            if let tag { headers["if-none-match"] = tag }
            var request = LocalHTTPServer.Request(method: "GET", path: "/home", query: [:], headers: headers, body: Data(), remote: "test")
            request.secure = secure
            return request
        }

        let response = await server.handle(request())
        #expect(response.status == 200 && response.headers[WirelessProtocol.Header.encoding] == "deflate")
        let tag = try #require(response.headers["ETag"])
        #expect(tag == WirelessSyncServer.sha256(json))
        if case .data(let data) = response.body {
            #expect(try (data as NSData).decompressed(using: .zlib) as Data == json)
        } else { Issue.record("no body") }
        #expect(await server.handle(request(tag)).status == 304)
        #expect(await server.handle(request(secure: false)).status == 403)
    }
}
