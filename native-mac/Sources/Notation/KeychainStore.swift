import Foundation
import Security

/// Minimal wrapper over `Security.framework` for storing per-account secrets
/// (LLM API keys) in the macOS Keychain.
///
/// Service id is the bundle identifier; accounts are short strings like
/// `"anthropic"` or `"openai"`. No `kSecAttrAccessGroup` is set, so this
/// works in the App Sandbox without any extra entitlement.
enum KeychainStore {
    private static let service: String =
        Bundle.main.bundleIdentifier ?? "com.shifengzhang.notation"

    @discardableResult
    static func save(account: String, secret: String) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus != errSecItemNotFound {
            DebugLog.write("[keychain] update failed for \(account) status=\(updateStatus)")
            return false
        }

        var addQuery = query
        for (k, v) in attributes { addQuery[k] = v }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            DebugLog.write("[keychain] add failed for \(account) status=\(addStatus)")
            return false
        }
        return true
    }

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                DebugLog.write("[keychain] load failed for \(account) status=\(status)")
            }
            return nil
        }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            DebugLog.write("[keychain] delete failed for \(account) status=\(status)")
            return false
        }
        return true
    }

    static func maskedDisplay(account: String) -> String? {
        guard let value = load(account: account), !value.isEmpty else { return nil }
        let last4 = value.suffix(4)
        return "••••••••\(last4)"
    }
}
