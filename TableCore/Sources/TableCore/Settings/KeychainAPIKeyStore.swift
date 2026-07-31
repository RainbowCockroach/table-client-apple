import Foundation
import Security

public struct KeychainError: Error, Equatable, LocalizedError {
    public let operation: String
    public let status: OSStatus

    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "keychain \(operation) failed: \(detail)"
    }
}

/// The Keychain item holding the API key (DESIGN §5).
///
/// `accessGroup` is what the share extension will read the same item through (DESIGN §5);
/// nil keeps the item private to the app.
public struct KeychainAPIKeyStore: APIKeyStore {
    private let service: String
    private let account: String
    private let accessGroup: String?

    public init(service: String = "table", account: String = "api-key", accessGroup: String? = nil) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func read() throws -> String {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
                throw KeychainError(operation: "read", status: errSecInvalidData)
            }
            return key
        case errSecItemNotFound:
            return ""
        default:
            throw KeychainError(operation: "read", status: status)
        }
    }

    public func write(_ apiKey: String) throws {
        guard !apiKey.isEmpty else { return try delete() }

        let value = Data(apiKey.utf8)
        let updated = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: value] as CFDictionary
        )
        guard updated == errSecItemNotFound else {
            guard updated == errSecSuccess else { throw KeychainError(operation: "update", status: updated) }
            return
        }

        var item = baseQuery
        item[kSecValueData as String] = value
        // C3 runs transfers in the background, where the device can be locked from the first
        // byte to the last; the key still has to be readable then.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(operation: "add", status: added) }
    }

    private func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(operation: "delete", status: status)
        }
    }

    private var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // The macOS file keychain has no access groups and prompts on every read from a
            // rebuilt binary; this is the same keychain iOS uses, so both platforms behave alike.
            kSecUseDataProtectionKeychain as String: true,
        ]
        query[kSecAttrAccessGroup as String] = accessGroup
        return query
    }
}
