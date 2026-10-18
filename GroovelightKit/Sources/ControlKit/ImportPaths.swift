import Foundation

/// What the command line tool and AI connectors may import from. Handing a path to the app gives the sandboxed app
/// read access to it until it quits, so a request (typed, scripted, or made by an AI model that read a malicious
/// instruction somewhere) must not reach the home folder as a whole, the disk, app data or hidden folders.
public enum ImportPaths {
    /// Why `path` may not be imported from, or nil when it may.
    public static func refusal(for path: String, home: String = realHome) -> String? {
        let resolved = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
        let home = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath().path
        func within(_ folder: String) -> Bool { resolved == folder || resolved.hasPrefix(folder + "/") }

        if resolved == "/" || resolved == home || home.hasPrefix(resolved + "/") || resolved == "/Volumes" {
            return "\(path) is too broad to import from: choose the folder or archive with the music."
        }
        if within(home) {
            let inside = resolved.dropFirst(home.count + 1).split(separator: "/")
            // iCloud Drive and cloud storage folders live in Library and can hold music.
            let cloud = inside.count > 1 && inside[0] == "Library" && (inside[1] == "Mobile Documents" || inside[1] == "CloudStorage")
            if inside.first == "Library", !cloud { return "\(path) is app data, not music: Groovelight does not import from ~/Library." }
            if inside.contains(where: { $0.hasPrefix(".") }) { return "\(path) is in a hidden folder: Groovelight does not import from hidden folders." }
            return nil
        }
        for folder in ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/private/var/db", "/opt"]
        where within(folder) {
            return "\(path) is a system folder: Groovelight does not import from it."
        }
        return nil
    }

    /// Throws the first refusal.
    public static func check(_ paths: [String]) throws {
        if let reason = paths.lazy.compactMap({ refusal(for: $0) }).first { throw Refused(reason: reason) }
    }

    public struct Refused: LocalizedError {
        public var reason: String
        public var errorDescription: String? { reason }
    }

    /// The user's home folder, also in the sandboxed app (whose NSHomeDirectory is its container).
    public static var realHome: String {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir { return String(cString: directory) }
        return NSHomeDirectory()
    }
}
