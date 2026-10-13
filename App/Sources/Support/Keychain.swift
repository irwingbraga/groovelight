import Foundation
import Security

/// Small generic-password store in the user's keychain (the Last.fm API secret and session key).
enum Keychain {
    /// The real app is sandboxed. Unsandboxed builds (debug tours run from the command line) keep separate items, so
    /// they can never read, replace or delete the user's Last.fm secret and session (the keychain is shared, unlike
    /// the preferences, which an unsandboxed build keeps outside the app's container).
    static let service = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil
        ? "dev.irwingbraga.groovelight.lastfm.unsandboxed"
        : "dev.irwingbraga.groovelight.lastfm"

    static func string(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves `value`, or removes the item when it is nil or empty.
    static func set(_ value: String?, for account: String) {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(match as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = match
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
