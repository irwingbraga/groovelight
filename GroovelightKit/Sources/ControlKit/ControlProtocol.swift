import Foundation

/// The command line tool (and AI connectors built on it) controls the running app: requests and replies travel as JSON
/// in Mach messages, on a port named after the app's App Group, the only names a sandboxed app may publish.
public enum ControlPort {
    public static let appGroup = "MHW58UT524.dev.irwingbraga.groovelight"
    public static let appBundleIdentifier = "dev.irwingbraga.groovelight"

    /// Debug builds use a port of their own, so they run beside the installed app. `GROOVELIGHT_PORT` overrides it.
    public static var name: String {
        if let name = ProcessInfo.processInfo.environment["GROOVELIGHT_PORT"], !name.isEmpty { return name }
        #if DEBUG
        return appGroup + ".control-debug"
        #else
        return appGroup + ".control"
        #endif
    }

    /// Bumped when requests or replies change in a way an older app or tool cannot read.
    public static let protocolVersion = 1
}

public enum ControlRequest: Codable, Hashable, Sendable {
    /// App version, library size, folders, what is playing.
    case status
    case search(query: String, limit: Int)
    case importFiles(ImportOptions)
    case fixMetadata(FixMetadataOptions)
    case organize(OrganizeFilesOptions)
    /// Undoes the last import or organize.
    case undo
    /// Checks every file of every library folder.
    case rescan
    case play(PlayOptions)
    case playback(PlaybackAction)
    case listPlaylists
    /// A new playlist of these songs, in this order.
    case createPlaylist(name: String, songIds: [Int64])
    /// Adds songs at the end of a playlist (by name).
    case addToPlaylist(playlist: String, songIds: [Int64])
    case nowPlaying
    /// Files the tool is about to open with the app (to grant it access): the app takes them in silently instead of
    /// showing its import sheet.
    case expectFiles([String])
    /// What a job did since the last poll, and its result when it is done.
    case poll(job: String)
    case cancel(job: String)
}

public struct ImportOptions: Codable, Hashable, Sendable {
    public var paths: [String]
    /// The library folder to import into (its name or path); the one set in Settings, Library when nil.
    public var folder: String?
    public var copy = false
    public var useOnlineMetadata = true
    public var writeTags = true
    /// Moves archives to the Trash once everything from them is imported.
    public var trashArchives = false
    public var dryRun = false

    public init(paths: [String], folder: String? = nil, copy: Bool = false, useOnlineMetadata: Bool = true, writeTags: Bool = true,
                trashArchives: Bool = false, dryRun: Bool = false) {
        self.paths = paths
        self.folder = folder
        self.copy = copy
        self.useOnlineMetadata = useOnlineMetadata
        self.writeTags = writeTags
        self.trashArchives = trashArchives
        self.dryRun = dryRun
    }
}

public struct FixMetadataOptions: Codable, Hashable, Sendable {
    /// The songs to fix: an album (by title, with its artist to tell albums apart), or song ids.
    public var album: String?
    public var artist: String?
    public var songIds: [Int64]?
    /// What to search MusicBrainz for, instead of the songs' own album and artist ("" leaves the field out).
    public var searchAlbum: String?
    public var searchArtist: String?
    /// The MusicBrainz release to apply; without it, `auto` takes the best candidate.
    public var release: String?
    public var auto = false
    /// Also gives the album's details to songs that are not on the release.
    public var includeUnmatched = false
    public var cover = true
    /// Writes the tags into the files too (the setting in Settings, Metadata when nil).
    public var writeTags: Bool?
    public var dryRun = false

    public init(album: String? = nil, artist: String? = nil, songIds: [Int64]? = nil, searchAlbum: String? = nil, searchArtist: String? = nil,
                release: String? = nil, auto: Bool = false, includeUnmatched: Bool = false, cover: Bool = true, writeTags: Bool? = nil,
                dryRun: Bool = false) {
        self.album = album
        self.artist = artist
        self.songIds = songIds
        self.searchAlbum = searchAlbum
        self.searchArtist = searchArtist
        self.release = release
        self.auto = auto
        self.includeUnmatched = includeUnmatched
        self.cover = cover
        self.writeTags = writeTags
        self.dryRun = dryRun
    }
}

public struct OrganizeFilesOptions: Codable, Hashable, Sendable {
    /// Only these songs' files (an album, an artist); the whole library when both are nil.
    public var album: String?
    public var artist: String?
    public var dryRun = false

    public init(album: String? = nil, artist: String? = nil, dryRun: Bool = false) {
        self.album = album
        self.artist = artist
        self.dryRun = dryRun
    }
}

public struct PlayOptions: Codable, Hashable, Sendable {
    /// What to play: songs by id (in this order), an album, an artist, a playlist or a song, matched by name; or the
    /// first songs a search finds.
    public var songIds: [Int64]?
    public var album: String?
    public var artist: String?
    public var playlist: String?
    public var song: String?
    public var query: String?
    public var shuffle = false

    public init(songIds: [Int64]? = nil, album: String? = nil, artist: String? = nil, playlist: String? = nil, song: String? = nil,
                query: String? = nil, shuffle: Bool = false) {
        self.songIds = songIds
        self.album = album
        self.artist = artist
        self.playlist = playlist
        self.song = song
        self.query = query
        self.shuffle = shuffle
    }
}

public enum PlaybackAction: String, Codable, Hashable, Sendable, CaseIterable {
    case pause, resume, toggle, next, previous, stop
}

/// A reply: a result (text for people, data for programs), an error, or a job to poll.
public struct ControlReply: Codable, Hashable, Sendable {
    /// What happened, for people.
    public var summary: String?
    /// The same for programs.
    public var data: JSONValue?
    public var error: String?
    /// A job that keeps running in the app: poll it until `finished`.
    public var job: String?
    public var finished = true
    /// Lines a job printed since the last poll.
    public var messages: [String] = []
    public var progress: JobProgress?

    public init(summary: String? = nil, data: JSONValue? = nil, error: String? = nil, job: String? = nil, finished: Bool = true,
                messages: [String] = [], progress: JobProgress? = nil) {
        self.summary = summary
        self.data = data
        self.error = error
        self.job = job
        self.finished = finished
        self.messages = messages
        self.progress = progress
    }

    public static func failure(_ message: String) -> ControlReply { ControlReply(error: message) }
}

public struct JobProgress: Codable, Hashable, Sendable {
    public var label: String
    public var done: Int
    public var total: Int

    public init(label: String, done: Int, total: Int) {
        self.label = label
        self.done = done
        self.total = total
    }
}
