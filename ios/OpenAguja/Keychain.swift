import Foundation
import Security

/// Jetons API dans le trousseau. `AfterFirstUnlock` : les requêtes
/// lancées par la montre en arrière-plan marchent téléphone verrouillé.
enum Keychain {
    /// Service = bundle id de l'app (trousseau isolé par app installée).
    private static let service = Bundle.main.bundleIdentifier ?? "OpenAguja"
    private static let account = "webhook.token"
    private static let macdAccount = "macd.token"

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func token(account: String) -> String? {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func setToken(_ token: String, account: String) -> Bool {
        let data = Data(token.utf8)
        var exists: CFTypeRef?
        var q = query(account: account)
        q[kSecReturnData as String] = true
        if SecItemCopyMatching(q as CFDictionary, &exists) == errSecSuccess {
            return SecItemUpdate(
                query(account: account) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            ) == errSecSuccess
        }
        var add = query(account: account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func deleteToken(account: String) -> Bool {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Webhook HTTP

    static func token() -> String? {
        token(account: account)
    }

    @discardableResult
    static func setToken(_ token: String) -> Bool {
        setToken(token, account: account)
    }

    @discardableResult
    static func deleteToken() -> Bool {
        deleteToken(account: account)
    }

    // MARK: - Daemon Mac (HTTP local)

    static func macdToken() -> String? {
        token(account: macdAccount)
    }

    @discardableResult
    static func setMacdToken(_ token: String) -> Bool {
        setToken(token, account: macdAccount)
    }

    @discardableResult
    static func deleteMacdToken() -> Bool {
        deleteToken(account: macdAccount)
    }
}
