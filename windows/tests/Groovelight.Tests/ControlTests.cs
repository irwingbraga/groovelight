using System.Text.Json.Nodes;
using Groovelight.ControlKit;

namespace Groovelight.Tests;

/// <summary>The Mac's ControlKit tests, ported: import path rules, the MCP server, and the pipe to the app.</summary>
public class ControlTests
{
    private static readonly ImportPaths.Folders Folders = new(@"C:\Users\ana", [@"C:\Windows", @"C:\Program Files", @"C:\Program Files (x86)", @"C:\ProgramData"]);

    [Theory]
    [InlineData(@"C:\Users\ana\Music\New")]
    [InlineData(@"C:\Users\ana\Downloads\album.zip")]
    [InlineData(@"C:\Users\ana\OneDrive\Music")]
    [InlineData(@"D:\Music")]
    [InlineData(@"\\nas\music\Rock")]
    [InlineData(@"C:\Users\ana\Music\..\Downloads\x.flac")]
    public void AllowsMusicFolders(string path) => Assert.Null(ImportPaths.Refusal(path, Folders));

    [Theory]
    [InlineData(@"C:\", "too broad")]
    [InlineData(@"D:", "too broad")]
    [InlineData(@"C:\Users", "too broad")]
    [InlineData(@"c:\users\ANA", "too broad")]
    [InlineData(@"C:\Users\ana\Music\..", "too broad")]
    [InlineData(@"\\nas\music", "too broad")]
    [InlineData(@"C:\Users\ana\AppData\Roaming\Claude", "app data")]
    [InlineData(@"C:\Users\ana\.ssh", "hidden folder")]
    [InlineData(@"C:\Users\ana\Music\.cache\a.mp3", "hidden folder")]
    [InlineData(@"C:\Windows\Media", "system folder")]
    [InlineData(@"C:\Program Files\Groovelight", "system folder")]
    [InlineData(@"C:/ProgramData/x", "system folder")]
    public void RefusesBroadHiddenAndSystemFolders(string path, string reason) =>
        Assert.Contains(reason, ImportPaths.Refusal(path, Folders));

    private sealed class FakeApp
    {
        public List<ControlRequest> Requests { get; } = [];

        public ControlReply Execute(ControlRequest request, Action<ControlReply> progress)
        {
            Requests.Add(request);
            progress(new ControlReply { Job = "1", Finished = false, Progress = new JobProgress("Reading files", 1, 2) });
            progress(new ControlReply { Job = "1", Finished = false, Progress = new JobProgress("Reading files", 1, 2) });
            return request switch
            {
                ImportRequest { Options.DryRun: true } => new() { Summary = "Would import 2 songs", Data = new JsonObject { ["dryRun"] = true } },
                FixMetadataRequest { Options.DryRun: true } => new() { Summary = "OK Computer", Data = new JsonObject { ["release"] = new JsonObject { ["id"] = "rel-1" } } },
                OrganizeRequest { Options.DryRun: true } => new() { Summary = "Nothing", Data = new JsonObject { ["renames"] = new JsonArray() } },
                StatusRequest => new() { Summary = "Groovelight 1.0", Data = new JsonObject { ["songs"] = 3 } },
                _ => new() { Summary = "Done it" },
            };
        }
    }

    private static JsonNode Call(McpServer server, string tool, JsonObject? arguments = null, List<JsonNode>? notes = null) =>
        server.Handle(new JsonObject
        {
            ["jsonrpc"] = "2.0", ["id"] = 7, ["method"] = "tools/call",
            ["params"] = new JsonObject { ["name"] = tool, ["arguments"] = arguments ?? [], ["_meta"] = new JsonObject { ["progressToken"] = "t" } },
        }, note => notes?.Add(note))!["result"]!;

    [Fact]
    public void AnswersInitializeAndListsTheTools()
    {
        var server = new McpServer("1.2.3", new FakeApp().Execute);
        var reply = server.Handle(JsonNode.Parse("""{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}""")!, _ => { })!;
        Assert.Equal("2025-03-26", reply["result"]!["protocolVersion"]!.GetValue<string>());
        Assert.Equal("1.2.3", reply["result"]!["serverInfo"]!["version"]!.GetValue<string>());
        var old = server.Handle(JsonNode.Parse("""{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}""")!, _ => { })!;
        Assert.Equal("2025-06-18", old["result"]!["protocolVersion"]!.GetValue<string>());
        Assert.Null(server.Handle(JsonNode.Parse("""{"jsonrpc":"2.0","method":"notifications/initialized"}""")!, _ => { }));
        var tools = server.Handle(JsonNode.Parse("""{"jsonrpc":"2.0","id":3,"method":"tools/list"}""")!, _ => { })!["result"]!["tools"]!.AsArray();
        Assert.Equal(16, tools.Count);
        Assert.Contains(tools, tool => tool!["name"]!.GetValue<string>() == "preview_import");
        var unknown = server.Handle(JsonNode.Parse("""{"jsonrpc":"2.0","id":4,"method":"nope"}""")!, _ => { })!;
        Assert.Equal(-32601, unknown["error"]!["code"]!.GetValue<int>());
    }

    [Fact]
    public void ChangesNeedAPreviewFirst()
    {
        var app = new FakeApp();
        var server = new McpServer("1", app.Execute);
        var refused = Call(server, "import_music", new JsonObject { ["preview_id"] = "pnope" });
        Assert.True(refused["isError"]!.GetValue<bool>());
        Assert.Empty(app.Requests);

        var notes = new List<JsonNode>();
        var preview = Call(server, "preview_import", new JsonObject { ["paths"] = new JsonArray(@"D:\Incoming\album.zip"), ["copy"] = true }, notes);
        var id = preview["structuredContent"]!["preview_id"]!.GetValue<string>();
        Assert.Contains("preview_id: " + id, preview["content"]![0]!["text"]!.GetValue<string>());
        // One progress note per change, not per poll.
        Assert.Single(notes);
        Assert.Equal("Reading files (1 of 2)", notes[0]["params"]!["message"]!.GetValue<string>());

        // The id belongs to its own apply tool.
        Assert.True(Call(server, "organize_files", new JsonObject { ["preview_id"] = id })["isError"]!.GetValue<bool>());
        var applied = Call(server, "import_music", new JsonObject { ["preview_id"] = id });
        Assert.Null(applied["isError"]);
        var import = Assert.IsType<ImportRequest>(app.Requests[^1]);
        Assert.False(import.Options.DryRun);
        Assert.True(import.Options.Copy);
        // Used once.
        Assert.True(Call(server, "import_music", new JsonObject { ["preview_id"] = id })["isError"]!.GetValue<bool>());
    }

    [Fact]
    public void AppliesTheReleaseThatWasPreviewed()
    {
        var app = new FakeApp();
        var server = new McpServer("1", app.Execute);
        var preview = Call(server, "preview_fix_metadata", new JsonObject { ["album"] = "OK Computer" });
        Call(server, "apply_fix_metadata", new JsonObject { ["preview_id"] = preview["structuredContent"]!["preview_id"]!.GetValue<string>() });
        var fix = Assert.IsType<FixMetadataRequest>(app.Requests[^1]);
        Assert.Equal("rel-1", fix.Options.Release);
        Assert.False(fix.Options.DryRun);
        Assert.True(Call(server, "preview_fix_metadata")["isError"]!.GetValue<bool>());
        // Nothing to rename: no preview_id.
        Assert.Null(Call(server, "preview_organize")["structuredContent"]!["preview_id"]);
    }

    [Fact]
    public void RefusesBroadImportsBeforeAskingTheApp()
    {
        var app = new FakeApp();
        var server = new McpServer("1", app.Execute);
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var result = Call(server, "preview_import", new JsonObject { ["paths"] = new JsonArray(home) });
        Assert.True(result["isError"]!.GetValue<bool>());
        Assert.Contains("too broad", result["content"]![0]!["text"]!.GetValue<string>());
        Assert.Empty(app.Requests);
    }

    [Fact]
    public void StampsSnapshotsWithTheirTime()
    {
        var result = Call(new McpServer("1", new FakeApp().Execute), "library_status");
        Assert.Equal(3, result["structuredContent"]!["songs"]!.GetValue<int>());
        Assert.NotNull(result["structuredContent"]!["as_of"]);
        Assert.Contains("As of ", result["content"]![0]!["text"]!.GetValue<string>());
        var stamped = McpServer.Stamped(McpServer.ToolResult(new ControlReply { Summary = "x" }), new DateTimeOffset(2026, 11, 6, 9, 30, 0, TimeSpan.FromHours(-3)));
        Assert.Equal("2026-11-06T09:30:00-03:00", stamped["structuredContent"]!["as_of"]!.GetValue<string>());
        Assert.Null(McpServer.Stamped(McpServer.ToolError("no"), DateTimeOffset.Now)["structuredContent"]);
    }

    [Fact]
    public async Task TalksThroughThePipe()
    {
        var pipe = "Groovelight.Test." + Guid.NewGuid().ToString("N")[..8];
        var seen = new List<ControlRequest>();
        using var server = new ControlServer(request =>
        {
            seen.Add(request);
            return Task.FromResult(request switch
            {
                SearchRequest search => new ControlReply { Summary = $"Found {search.Query}", Data = new JsonObject { ["limit"] = search.Limit } },
                PollRequest => new ControlReply { Summary = "Imported", Job = "1" },
                ImportRequest => new ControlReply { Job = "1", Finished = false, Progress = new JobProgress("Reading", 0, 1) },
                _ => throw new ControlException("Not this one"),
            });
        });
        Assert.True(server.Start(pipe));
        Assert.False(new ControlServer(_ => Task.FromResult(new ControlReply())).Start(pipe));

        var reply = await Task.Run(() => ControlClient.Send(new SearchRequest("Björk", 5), pipe));
        Assert.Equal("Found Björk", reply.Summary);
        Assert.Equal(5, reply.Data!["limit"]!.GetValue<int>());
        var updates = 0;
        var done = await Task.Run(() => ControlClient.Run(new ImportRequest(new ImportOptions { Paths = [@"D:\a.flac"] }), _ => updates++, pipe, TimeSpan.Zero));
        Assert.Equal("Imported", done.Summary);
        Assert.Equal(1, updates);
        Assert.Equal("Not this one", (await Task.Run(() => ControlClient.Send(new UndoRequest(), pipe))).Error);
        Assert.Equal(@"D:\a.flac", Assert.IsType<ImportRequest>(seen[1]).Options.Paths[0]);

        var mismatch = await server.AnswerAsync("""{"version": 99, "request": {"type": "status"}}""");
        Assert.Contains("version 99", mismatch.Error);
        Assert.NotNull((await server.AnswerAsync("not json")).Error);
        Assert.Throws<ControlException>(() => ControlClient.Send(new StatusRequest(), pipe + ".missing", TimeSpan.FromMilliseconds(200)));
    }
}
