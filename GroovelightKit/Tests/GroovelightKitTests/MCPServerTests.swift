import Foundation
import Testing
@testable import ControlKit

struct MCPServerTests {
    /// A server whose "app" records requests and answers from `answer`.
    private final class FakeApp {
        var requests: [ControlRequest] = []
        var granted: [[String]] = []
        var answer: (ControlRequest) -> ControlReply = { _ in ControlReply(summary: "ok") }
    }

    private func makeServer(_ app: FakeApp) -> MCPServer {
        MCPServer(version: "1.0", execute: { request, progress in
            app.requests.append(request)
            progress(ControlReply(job: "1", finished: false, progress: JobProgress(label: "Working", done: 1, total: 2)))
            return app.answer(request)
        }, grantAccess: { app.granted.append($0) })
    }

    private func call(_ server: MCPServer, _ name: String, _ arguments: [String: JSONValue] = [:], token: JSONValue? = nil,
                      notifications: inout [JSONValue]) -> JSONValue? {
        var params: [String: JSONValue] = ["name": .string(name), "arguments": .object(arguments)]
        if let token { params["_meta"] = .object(["progressToken": token]) }
        var sent: [JSONValue] = []
        let reply = server.handle(.object(["jsonrpc": .string("2.0"), "id": .number(7), "method": .string("tools/call"), "params": .object(params)])) {
            sent.append($0)
        }
        notifications += sent
        return reply?["result"]
    }

    @Test func introducesItselfAndListsTools() throws {
        let server = makeServer(FakeApp())
        let hello = server.handle(.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("initialize"),
                                           "params": .object(["protocolVersion": .string("2025-06-18")])])) { _ in }
        #expect(hello?["result"]?["protocolVersion"] == .string("2025-06-18"))
        #expect(hello?["result"]?["serverInfo"]?["name"] == .string("groovelight"))
        // Notifications get no reply.
        #expect(server.handle(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")])) { _ in } == nil)

        let list = server.handle(.object(["jsonrpc": .string("2.0"), "id": .number(2), "method": .string("tools/list")])) { _ in }
        let tools = try #require(list?["result"]?["tools"]?.arrayValue)
        #expect(tools.count == 16)
        for tool in tools {
            #expect(tool["name"]?.stringValue != nil && tool["description"]?.stringValue != nil)
            #expect(tool["inputSchema"]?["type"] == .string("object"))
        }
        let unknown = server.handle(.object(["jsonrpc": .string("2.0"), "id": .number(3), "method": .string("resources/list")])) { _ in }
        #expect(unknown?["error"]?["code"] == .number(-32601))
    }

    @Test func importsOnlyWhatWasPreviewed() throws {
        let app = FakeApp()
        app.answer = { _ in ControlReply(summary: "Would import 4 songs", data: .object(["albums": .array([])])) }
        let server = makeServer(app)
        var notes: [JSONValue] = []

        // Applying without a preview is refused.
        let refused = call(server, "import_music", ["preview_id": .string("p123")], notifications: &notes)
        #expect(refused?["isError"] == .bool(true))
        #expect(app.requests.isEmpty)

        let preview = try #require(call(server, "preview_import", ["paths": .array([.string("/music/a.zip")]), "trash_archives": .bool(true)],
                                        token: .string("t1"), notifications: &notes))
        let id = try #require(preview["structuredContent"]?["preview_id"]?.stringValue)
        #expect(app.granted == [["/music/a.zip"]])
        #expect(app.requests == [.importFiles(ImportOptions(paths: ["/music/a.zip"], trashArchives: true, dryRun: true))])
        // Progress went out as notifications for the token.
        #expect(notes.first?["method"] == .string("notifications/progress"))
        #expect(notes.first?["params"]?["progressToken"] == .string("t1"))

        // The wrong apply tool is refused; the right one runs the previewed import for real, once.
        #expect(call(server, "organize_files", ["preview_id": .string(id)], notifications: &notes)?["isError"] == .bool(true))
        _ = call(server, "import_music", ["preview_id": .string(id)], notifications: &notes)
        #expect(app.requests.last == .importFiles(ImportOptions(paths: ["/music/a.zip"], trashArchives: true, dryRun: false)))
        #expect(call(server, "import_music", ["preview_id": .string(id)], notifications: &notes)?["isError"] == .bool(true))
    }

    @Test func appliesTheReleaseThatWasPreviewed() throws {
        let app = FakeApp()
        app.answer = { _ in ControlReply(summary: "OK Computer", data: .object(["release": .object(["id": .string("rel-1")])])) }
        let server = makeServer(app)
        var notes: [JSONValue] = []
        let preview = try #require(call(server, "preview_fix_metadata", ["album": .string("OK Computer")], notifications: &notes))
        let id = try #require(preview["structuredContent"]?["preview_id"]?.stringValue)
        #expect(preview["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("preview_id: \(id)") == true)
        _ = call(server, "apply_fix_metadata", ["preview_id": .string(id)], notifications: &notes)
        guard case .fixMetadata(let options) = app.requests.last else { Issue.record("no fix"); return }
        #expect(options.release == "rel-1" && !options.dryRun && options.album == "OK Computer")
    }

    @Test func reportsErrorsAsToolResults() throws {
        let app = FakeApp()
        app.answer = { _ in .failure("No album matches “Kid A”.") }
        let server = makeServer(app)
        var notes: [JSONValue] = []
        let result = try #require(call(server, "preview_fix_metadata", ["album": .string("Kid A")], notifications: &notes))
        #expect(result["isError"] == .bool(true))
        #expect(result["content"]?.arrayValue?.first?["text"]?.stringValue == "No album matches “Kid A”.")
        #expect(result["structuredContent"]?["preview_id"] == nil)
        #expect(call(server, "playback_control", ["action": .string("dance")], notifications: &notes)?["isError"] == .bool(true))
    }

    /// The Claude Desktop extension (extension/manifest.json) lists the tools the server has.
    @Test func stampsStateWithTheTimeItWasRead() throws {
        let app = FakeApp()
        app.answer = { request in
            if case .nowPlaying = request { return ControlReply(summary: "Playing Crazy Life", data: .object(["title": .string("Crazy Life")])) }
            return ControlReply(summary: "Playlists", data: .array([]))
        }
        let server = makeServer(app)
        var notes: [JSONValue] = []

        let playing = try #require(call(server, "now_playing", notifications: &notes))
        let time = try #require(playing["structuredContent"]?["as_of"]?.stringValue)
        #expect(ISO8601DateFormatter().date(from: time) != nil)
        #expect(playing["structuredContent"]?["title"] == .string("Crazy Life"))
        #expect(playing["content"]?.arrayValue?.first?["text"]?.stringValue?.hasSuffix("As of \(time).") == true)
        // Results that are not objects keep their data next to the time.
        let playlists = try #require(call(server, "list_playlists", notifications: &notes))
        #expect(playlists["structuredContent"]?["result"] == .array([]))
        #expect(playlists["structuredContent"]?["as_of"] != nil)
        // Changes and errors are not stamped.
        app.answer = { _ in ControlReply(summary: "Paused") }
        #expect(call(server, "playback_control", ["action": .string("pause")], notifications: &notes)?["structuredContent"] == nil)
        app.answer = { _ in ControlReply(error: "Groovelight is not running") }
        #expect(call(server, "now_playing", notifications: &notes)?["structuredContent"] == nil)
    }

    @Test func refusesToImportFromPrivateFolders() throws {
        let app = FakeApp()
        let server = makeServer(app)
        var notes: [JSONValue] = []
        let result = try #require(call(server, "preview_import", ["paths": .array([.string("~/Library")])], notifications: &notes))
        #expect(result["isError"] == .bool(true))
        // Nothing was handed to the app.
        #expect(app.granted.isEmpty && app.requests.isEmpty)
    }

    @Test func extensionManifestListsEveryTool() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: root.appendingPathComponent("extension/manifest.json")))
        let listed = (manifest["tools"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
        #expect(listed == MCPServer.tools.compactMap { $0["name"]?.stringValue })
        #expect(manifest["server"]?["entry_point"] == .string("server/groovelight-mcp"))
    }

    @Test func makesPlaylistsOfSongIds() throws {
        let app = FakeApp()
        let server = makeServer(app)
        var notes: [JSONValue] = []
        _ = call(server, "create_playlist", ["name": .string("Gino's Best"), "song_ids": .array([.number(2798), .number(2765)])], notifications: &notes)
        #expect(app.requests.last == .createPlaylist(name: "Gino's Best", songIds: [2798, 2765]))
        _ = call(server, "add_to_playlist", ["playlist": .string("Gino's Best"), "song_ids": .array([.number(2801)])], notifications: &notes)
        #expect(app.requests.last == .addToPlaylist(playlist: "Gino's Best", songIds: [2801]))
        _ = call(server, "play", ["song_ids": .array([.number(2798)])], notifications: &notes)
        #expect(app.requests.last == .play(PlayOptions(songIds: [2798])))
        #expect(call(server, "create_playlist", ["song_ids": .array([])], notifications: &notes)?["isError"] == .bool(true))
    }
}
