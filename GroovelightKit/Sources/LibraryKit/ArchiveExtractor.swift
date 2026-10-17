import Foundation

/// Archives of music (zip, 7z, rar, tar and its compressed forms), extracted before an import with the system's bsdtar
/// (libarchive), which macOS ships with every format here.
public enum ArchiveExtractor {
    public static let extensions: Set<String> = ["zip", "7z", "rar", "tar", "tgz", "tbz", "tbz2", "txz", "gz", "bz2", "xz"]

    public static func isArchive(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    public enum ExtractError: LocalizedError {
        case encrypted(String)
        case failed(String, String)

        public var errorDescription: String? {
            switch self {
            case .encrypted(let name): "“\(name)” is protected with a password, which Groovelight cannot open."
            case .failed(let name, let reason): "Could not extract “\(name)”: \(reason)"
            }
        }
    }

    /// Extracts `archive` into `folder` (created when missing). This process opens the archive and hands it to bsdtar
    /// as standard input: a file there can still be seeked (7z needs it), and the tool, sandboxed like the app, never
    /// has to open the user's file itself. bsdtar refuses entries with ".." in their path and strips a leading "/".
    public static func extract(_ archive: URL, into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        let errors = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/bsdtar")
        // A passphrase given up front: without one, bsdtar asks for it, reading from the terminal or standard input
        // (the archive). A protected archive then fails with "Incorrect passphrase".
        process.arguments = ["-x", "-f", "-", "-C", folder.path, "--passphrase", "groovelight"]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        // Read before waiting: a full pipe would block bsdtar.
        let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return }
        let name = archive.lastPathComponent
        let lowered = output.lowercased()
        if lowered.contains("passphrase") || lowered.contains("encrypt") { throw ExtractError.encrypted(name) }
        let reason = output.split(separator: "\n").map { $0.replacingOccurrences(of: "bsdtar: ", with: "").replacingOccurrences(of: "tar: ", with: "") }
            .first { !$0.contains("Error exit delayed") } ?? "unknown error"
        throw ExtractError.failed(name, reason)
    }
}
