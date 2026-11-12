import Foundation
import NetFS

/// Connecting to the NAS's shared folder with a user and password kept by Groovelight (in the Keychain), for backups:
/// the share is mounted when it is not, with no dialog, so a backup at night does not depend on the Finder having
/// remembered a password. A share already mounted (by the Finder, as any user) is used as it is.
enum NASConnection {
    /// The Keychain item holding the password, by "user@server".
    static let keychainService = Keychain.nasService

    struct Login: Equatable {
        /// The shared folder, as smb://host/share (no user in it).
        var server: URL
        var user: String
        var password: String
    }

    enum Failure: LocalizedError, Equatable {
        case refused(user: String)
        case notFound(String)
        case unreachable(String)
        case other(Int32)

        var errorDescription: String? {
            switch self {
            case .refused(let user): "The NAS refused the user \(user). Check the user and password in Settings, Backups."
            case .notFound(let share): "The NAS has no shared folder \(share)."
            case .unreachable(let host): "\(host) is not reachable. Is the NAS on and on this network?"
            case .other(let code): "Could not connect to the NAS (error \(code))."
            }
        }
    }

    // MARK: - The saved login

    static func account(user: String, server: URL) -> String { "\(user)@\(server.host() ?? "")" }

    static func password(user: String, server: URL) -> String? {
        Keychain.string(account(user: user, server: server), service: keychainService)
    }

    static func savePassword(_ password: String?, user: String, server: URL) {
        Keychain.set(password, for: account(user: user, server: server), service: keychainService)
    }

    /// smb://host/share from what the user typed ("nas.local/Backups", "smb://me@nas.local/Backups", "\\nas\Backups").
    static func serverURL(from text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "/")
        while text.hasPrefix("/") { text.removeFirst() }
        if !text.contains("://") { text = "smb://" + text }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty,
              components.path.split(separator: "/").first != nil else { return nil }
        components.user = nil
        components.password = nil
        components.scheme = "smb"
        // The share only: a folder inside it is the folder chosen with Choose….
        components.path = "/" + (components.path.split(separator: "/").first.map(String.init) ?? "")
        return components.url
    }

    /// The share a folder is on (smb://host/share), when it is on a network share.
    static func share(of folder: URL) -> URL? {
        guard let remount = try? folder.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting,
              ["smb", "cifs", "afp", "nfs"].contains(remount.scheme?.lowercased() ?? "") else { return nil }
        return serverURL(from: remount.absoluteString)
    }

    /// The user a share was mounted as, when the Finder mounted it with one.
    static func user(of folder: URL) -> String? {
        (try? folder.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting)?.user(percentEncoded: false)
    }

    // MARK: - Mounting

    /// Whether the share is mounted now (by anyone, as any user).
    static func isMounted(_ server: URL) -> Bool {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey], options: [.skipHiddenVolumes]) ?? []
        return volumes.contains { volume in
            guard let remount = try? volume.resourceValues(forKeys: [.volumeURLForRemountingKey]).volumeURLForRemounting,
                  let share = serverURL(from: remount.absoluteString) else { return false }
            return share.host()?.lowercased() == server.host()?.lowercased()
                && share.path(percentEncoded: false).lowercased() == server.path(percentEncoded: false).lowercased()
        }
    }

    /// Mounts the share with the login when it is not mounted (blocking: call it off the main thread). Returns where it
    /// is mounted (nil when it already was).
    @discardableResult
    static func mount(_ login: Login) throws -> URL? {
        if isMounted(login.server) { return nil }
        let openOptions = NSMutableDictionary()
        openOptions[kNAUIOptionKey] = kNAUIOptionNoUI
        let mountOptions = NSMutableDictionary()
        // A soft mount: a NAS that goes away makes reads fail instead of hanging the app.
        mountOptions[kNetFSSoftMountKey] = true
        var mountPoints: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(login.server as CFURL, nil, login.user as CFString, login.password as CFString,
                                       openOptions, mountOptions, &mountPoints)
        let points = mountPoints?.takeRetainedValue() as? [String]
        switch Int(status) {
        case 0: return points?.first.map { URL(fileURLWithPath: $0, isDirectory: true) }
        case Int(EEXIST): return nil
        case Int(EAUTH), Int(EACCES), Int(EPERM): throw Failure.refused(user: login.user)
        case Int(ENOENT), -6003 /* kNetAuthErrorNoSharesAvailable */: throw Failure.notFound(login.server.lastPathComponent)
        case Int(EHOSTDOWN), Int(EHOSTUNREACH), Int(ETIMEDOUT), Int(ENETUNREACH), Int(ENETDOWN), Int(ECONNREFUSED):
            throw Failure.unreachable(login.server.host() ?? "The NAS")
        default: throw Failure.other(status)
        }
    }
}
