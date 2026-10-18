import ArgumentParser
import ControlKit
import Foundation

@main
struct Groovelight: ParsableCommand {
    static var configuration: CommandConfiguration {
        CommandConfiguration(
            commandName: "groovelight",
            abstract: "Control Groovelight, the music player, from the terminal.",
            discussion: """
                Commands go to the running app (it starts in the background when needed), so the library, undo and \
                the app's windows stay in step. Add --json to any command for a result programs can read.
                """,
            version: Runner.version,
            subcommands: [Status.self, Search.self, Import.self, FixMetadata.self, Organize.self, Undo.self, Rescan.self,
                          Play.self, Pause.self, Resume.self, Toggle.self, Next.self, Previous.self, Stop.self, NowPlaying.self,
                          Playlists.self, CreatePlaylist.self, AddToPlaylist.self,
                          MCP.self]
        )
    }
}

struct OutputOptions: ParsableArguments {
    @Flag(help: "Print the result as JSON.")
    var json = false
}

// MARK: - Library

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the library's size, its folders and what is playing.")
    @OptionGroup var output: OutputOptions

    func run() throws {
        try Runner.execute(.status, output: output)
    }
}

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Search the library for artists, albums and songs.")
    @Argument(help: "What to look for.")
    var query: [String]
    @Option(help: "How many of each kind to show.")
    var limit = 10
    @OptionGroup var output: OutputOptions

    func run() throws {
        try Runner.execute(.search(query: query.joined(separator: " "), limit: limit), output: output)
    }
}

struct Import: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Import songs, folders or archives (zip, 7z, rar, tar) into the library.",
        discussion: """
            Songs are identified on MusicBrainz, tagged and named like Organize Library Files names them, then moved \
            into the library folder set in Settings, Library. Preview with --dry-run; undo with `groovelight undo`.
            """
    )
    @Argument(help: "Songs, folders or archives.", completion: .file())
    var paths: [String]
    @Option(help: "The library folder to import into (its name or path).")
    var folder: String?
    @Flag(help: "Copy the files instead of moving them (archives are always extracted into the library).")
    var copy = false
    @Flag(name: .customLong("no-online"), help: "Keep the files' own tags instead of the metadata found on MusicBrainz.")
    var noOnline = false
    @Flag(name: .customLong("no-tags"), help: "Do not write tags and covers into the files.")
    var noTags = false
    @Flag(help: "Move each archive to the Trash once everything from it is imported (undo puts it back).")
    var trashArchives = false
    @Flag(help: "Show what would be imported and where, without changing anything.")
    var dryRun = false
    @OptionGroup var output: OutputOptions

    func run() throws {
        let resolved = try paths.map { path in
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("No such file or folder: \(path)") }
            return url.path
        }
        try Runner.ensureRunning()
        try Runner.grantAccess(to: resolved)
        let options = ImportOptions(paths: resolved, folder: folder, copy: copy, useOnlineMetadata: !noOnline, writeTags: !noTags,
                                    trashArchives: trashArchives, dryRun: dryRun)
        try Runner.execute(.importFiles(options), output: output)
    }
}

struct FixMetadata: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fix an album's tags with a release found on MusicBrainz.",
        discussion: """
            Without --release, lists the releases found; preview the best one with --dry-run, then apply it with \
            --release ID (or --auto to take the best match).
            """
    )
    @Option(help: "The album to fix (its title).")
    var album: String?
    @Option(help: "The album's artist, to tell albums with the same title apart (or every song of the artist, without --album).")
    var artist: String?
    @Option(parsing: .upToNextOption, help: "Song ids to fix as one album (from `groovelight search`).")
    var songs: [Int64] = []
    @Option(help: "Search MusicBrainz for this album title instead of the songs' own (\"\" leaves it out).")
    var searchAlbum: String?
    @Option(help: "Search MusicBrainz for this artist instead of the songs' own (\"\" leaves it out).")
    var searchArtist: String?
    @Option(help: "The MusicBrainz release id to apply.")
    var release: String?
    @Flag(help: "Apply the best match found.")
    var auto = false
    @Flag(help: "Also give the album's details to songs that are not on the release.")
    var includeUnmatched = false
    @Flag(name: .customLong("no-cover"), help: "Keep the current cover.")
    var noCover = false
    @Flag(inversion: .prefixedNo, help: "Write the tags into the files too (default: the setting in Settings, Metadata).")
    var writeTags: Bool?
    @Flag(help: "Show the changes without making them.")
    var dryRun = false
    @OptionGroup var output: OutputOptions

    func validate() throws {
        if album == nil, artist == nil, songs.isEmpty { throw ValidationError("Say which songs: --album, --artist or --songs.") }
    }

    func run() throws {
        let options = FixMetadataOptions(album: album, artist: artist, songIds: songs.isEmpty ? nil : songs, searchAlbum: searchAlbum,
                                         searchArtist: searchArtist, release: release, auto: auto, includeUnmatched: includeUnmatched,
                                         cover: !noCover, writeTags: writeTags, dryRun: dryRun)
        try Runner.execute(.fixMetadata(options), output: output)
    }
}

struct Organize: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Rename and move files with the naming settings (Settings, Files).")
    @Option(help: "Only this album's files.")
    var album: String?
    @Option(help: "Only this artist's files (or the album's artist, with --album).")
    var artist: String?
    @Flag(help: "Show the new names without renaming anything.")
    var dryRun = false
    @OptionGroup var output: OutputOptions

    func run() throws {
        try Runner.execute(.organize(OrganizeFilesOptions(album: album, artist: artist, dryRun: dryRun)), output: output)
    }
}

struct Undo: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Undo the last import or organize.")
    @OptionGroup var output: OutputOptions

    func run() throws {
        try Runner.execute(.undo, output: output)
    }
}

struct Rescan: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check every file of every library folder.")
    @OptionGroup var output: OutputOptions

    func run() throws {
        try Runner.execute(.rescan, output: output)
    }
}

// MARK: - Playback

struct Play: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Play a song, what a search finds, an album, an artist or a playlist (or resume).",
        discussion: """
            Names match ignoring case and accents; a part of the name is enough when only one thing matches. With --song \
            or a search, --artist and --album narrow it down: play --song "Karma Police" --artist Radiohead.
            """
    )
    @Option(help: "An album's title.")
    var album: String?
    @Option(help: "An artist (or the album's artist, with --album).")
    var artist: String?
    @Option(help: "A playlist's name.")
    var playlist: String?
    @Option(help: "One song: the first that matches.")
    var song: String?
    @Option(parsing: .upToNextOption, help: "Songs by id (from `groovelight search`), in this order.")
    var songs: [Int64] = []
    @Flag(help: "Shuffle.")
    var shuffle = false
    @Argument(help: "Play the songs a search finds.")
    var query: [String] = []
    @OptionGroup var output: OutputOptions

    func run() throws {
        let options = PlayOptions(songIds: songs.isEmpty ? nil : songs, album: album, artist: artist, playlist: playlist, song: song,
                                  query: query.isEmpty ? nil : query.joined(separator: " "), shuffle: shuffle)
        try Runner.execute(.play(options), output: output)
    }
}

struct Pause: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Pause.")
    @OptionGroup var output: OutputOptions
    func run() throws { try Runner.execute(.playback(.pause), output: output) }
}

struct Resume: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Resume playing.")
    @OptionGroup var output: OutputOptions
    func run() throws { try Runner.execute(.playback(.resume), output: output) }
}

struct Toggle: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "play-pause", abstract: "Play or pause.")
    @OptionGroup var output: OutputOptions
    func run() throws { try Runner.execute(.playback(.toggle), output: output) }
}

struct Next: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Skip to the next song.")
    @OptionGroup var output: OutputOptions
    func run() throws { try Runner.execute(.playback(.next), output: output) }
}

struct Previous: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Go back to the previous song.")
    @OptionGroup var output: OutputOptions
    func run() throws { try Runner.execute(.playback(.previous), output: output) }
}

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop playing.")
    @OptionGroup var output: OutputOptions
    func run() throws { try Runner.execute(.playback(.stop), output: output) }
}

struct NowPlaying: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show what is playing.")
    @OptionGroup var output: OutputOptions
    func run() throws { try Runner.execute(.nowPlaying, output: output) }
}

// MARK: - Playlists

struct Playlists: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the playlists.")
    @OptionGroup var output: OutputOptions
    func run() throws { try Runner.execute(.listPlaylists, output: output) }
}

struct CreatePlaylist: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create a playlist of songs, in order.",
        discussion: "Song ids come from `groovelight search`: create-playlist \"Gino's Best\" --songs 2798 2765 2801"
    )
    @Argument(help: "The playlist's name.")
    var name: String
    @Option(parsing: .upToNextOption, help: "Song ids, in playlist order.")
    var songs: [Int64]
    @OptionGroup var output: OutputOptions
    func run() throws { try Runner.execute(.createPlaylist(name: name, songIds: songs), output: output) }
}

struct AddToPlaylist: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Add songs at the end of a playlist.")
    @Argument(help: "The playlist's name.")
    var playlist: String
    @Option(parsing: .upToNextOption, help: "Song ids (from `groovelight search`).")
    var songs: [Int64]
    @OptionGroup var output: OutputOptions
    func run() throws { try Runner.execute(.addToPlaylist(playlist: playlist, songIds: songs), output: output) }
}

// MARK: - AI tools

struct MCP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve Groovelight to Claude and other AI tools (Model Context Protocol, over stdin and stdout).",
        discussion: """
            Claude Code: claude mcp add groovelight -- /usr/local/bin/groovelight mcp
            Claude Desktop: add {"mcpServers": {"groovelight": {"command": "/usr/local/bin/groovelight", "args": ["mcp"]}}} \
            to ~/Library/Application Support/Claude/claude_desktop_config.json.
            Changes to files always go through a preview the user sees first.
            """
    )

    func run() throws {
        let server = MCPServer(version: Runner.appVersion ?? "0", execute: { request, progress in
            try Runner.ensureRunning()
            return try ControlClient.run(request, onUpdate: progress)
        }, grantAccess: { paths in
            try Runner.ensureRunning()
            try Runner.grantAccess(to: paths)
        })
        server.run()
    }
}
