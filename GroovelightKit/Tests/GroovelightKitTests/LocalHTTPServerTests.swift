import Foundation
import Testing
@testable import WirelessSync

struct LocalHTTPServerTests {
    /// Large responses arrive whole: the connection is closed only after the device has read them (closing as soon as
    /// they were handed to the network stack cut them short on slow links: "unexpected end of stream" on Android).
    @Test(.timeLimit(.minutes(1))) func largeResponsesArriveWhole() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-http-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let big = Data((0..<24 * 1024 * 1024).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let file = folder.appendingPathComponent("song.flac")
        try big.write(to: file)
        let server = LocalHTTPServer { request in
            request.path == "/file" ? LocalHTTPServer.Response(body: .file(file)) : LocalHTTPServer.Response(body: .data(big))
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            server.start(name: nil) { port in
                if let port { continuation.resume(returning: port) } else { continuation.resume(throwing: CocoaError(.featureUnsupported)) }
            }
        }
        defer { server.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        // Several at once, as a sync's downloads and the snapshot can be.
        try await withThrowingTaskGroup(of: Data.self) { group in
            for path in ["/data", "/file", "/data", "/file"] {
                group.addTask { try await session.data(from: URL(string: "http://127.0.0.1:\(port)\(path)")!).0 }
            }
            for try await data in group { #expect(data == big) }
        }
    }
}
