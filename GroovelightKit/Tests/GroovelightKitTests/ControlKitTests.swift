import Foundation
import Testing
@testable import ControlKit

struct ControlKitTests {
    @Test func jsonValuesRoundTrip() throws {
        struct Song: Encodable { var id: Int64; var title: String; var year: Int?; var loved: Bool; var gain: Double }
        let value = try JSONValue(encoding: [Song(id: 42, title: "Airbag", year: nil, loved: true, gain: -6.5)])
        #expect(value == .array([.object(["id": .number(42), "title": .string("Airbag"), "loved": .bool(true), "gain": .number(-6.5)])]))
        let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
        // Ids print as whole numbers.
        #expect(value.prettyPrinted.contains("\"id\" : 42,"))
    }

    @Test func requestsSurviveTheTrip() throws {
        let requests: [ControlRequest] = [
            .status, .search(query: "radiohead", limit: 5), .importFiles(ImportOptions(paths: ["/a.zip"], trashArchives: true, dryRun: true)),
            .fixMetadata(FixMetadataOptions(album: "OK Computer", artist: "Radiohead", release: "abc", dryRun: true)),
            .organize(OrganizeFilesOptions(artist: "Radiohead", dryRun: true)), .play(PlayOptions(album: "Kid A", shuffle: true)),
            .playback(.next), .poll(job: "1"), .expectFiles(["/x"]),
        ]
        for request in requests {
            #expect(try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request)) == request)
        }
    }

    @MainActor
    @Test func answersOverAMessagePort() throws {
        let name = "dev.irwingbraga.groovelight.test-\(UUID().uuidString)"
        let server = ControlServer { request in
            switch request {
            case .search(let query, _): ControlReply(summary: "found \(query)", data: .object(["query": .string(query)]))
            case .poll(let job): ControlReply(summary: "done", job: job, finished: true)
            default: ControlReply(job: "7", finished: false, progress: JobProgress(label: "Working", done: 1, total: 2))
            }
        }
        #expect(server.start(name: name))
        defer { server.stop() }
        #expect(ControlClient.isAvailable(port: name))

        let reply = try ControlClient.send(.search(query: "kid a", limit: 3), port: name)
        #expect(reply.summary == "found kid a")
        #expect(reply.data == .object(["query": .string("kid a")]))

        // A job is polled until it finishes.
        var updates = 0
        let finished = try ControlClient.run(.rescan, port: name, interval: 0.01) { _ in updates += 1 }
        #expect(finished.summary == "done" && updates == 1)

        server.stop()
        #expect(throws: ControlClient.ClientError.self) { try ControlClient.send(.status, port: name) }
    }

    @Test func refusesBroadAndPrivateImportPaths() {
        let home = "/Users/someone"
        for path in ["/", "/Users", home, home + "/", "/Volumes", home + "/Library", home + "/Library/Keychains", home + "/.ssh",
                     home + "/Music/.secret/a.zip", "/System/Library", "/Library/Audio", "/Applications/Music.app", "/etc", "/private/etc/hosts"] {
            #expect(ImportPaths.refusal(for: path, home: home) != nil, "\(path)")
        }
        for path in [home + "/Downloads/Album.zip", home + "/Music/New", "/Volumes/Music/Albums", "/tmp/import",
                     home + "/Library/Mobile Documents/com~apple~CloudDocs/Music", home + "/Library/CloudStorage/Dropbox/Albums"] {
            #expect(ImportPaths.refusal(for: path, home: home) == nil, "\(path)")
        }
        #expect(throws: ImportPaths.Refused.self) { try ImportPaths.check(["/tmp/import", ImportPaths.realHome]) }
    }
}
