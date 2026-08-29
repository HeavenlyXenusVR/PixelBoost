import Foundation
import Security

/// Minimal Keychain wrapper for the one secret this app ever stores
/// locally — a user-supplied `UPSCALER_BRIDGE_API_KEY` override (see
/// `ServerConfig`). Everything else server-related (base URL) is just a
/// hostname, not a secret, and stays in `UserDefaults`/`@AppStorage` as
/// before. `kSecAttrAccessibleAfterFirstUnlock` matches how every other
/// on-device credential in this app class is expected to behave — readable
/// in the background (a batch upload shouldn't need the device unlocked)
/// but never included in an unencrypted backup of the keychain itself.
enum KeychainStore {
    private static let service = "com.pixelboost.keychain"

    static func string(forAccount account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setString(_ value: String?, forAccount account: String) {
        guard let value, !value.isEmpty else {
            SecItemDelete(baseQuery(account: account) as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        var query = baseQuery(account: account)
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
