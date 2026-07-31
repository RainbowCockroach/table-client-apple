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
    /// Which of macOS's two keychains the item lives in. iOS only has the first.
    private enum Keychain {
        /// What DESIGN §5 asks for: the keychain iOS uses, which takes an access group and
        /// does not re-prompt when the binary is rebuilt.
        case dataProtection

        /// The older macOS file keychain, which needs no entitlement.
        case file
    }

    private let service: String
    private let account: String
    private let accessGroup: String?

    public init(service: String = "table", account: String = "api-key", accessGroup: String? = nil) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func read() throws -> String {
        if let key = try read(from: .dataProtection) {
            return key
        }
        // The data-protection keychain answers "not found" rather than "not allowed" to a build
        // that may not write to it, so a key stored by such a build is only found this way.
        guard let fallback = fallbackKeychain else { return "" }
        return try read(from: fallback) ?? ""
    }

    public func write(_ apiKey: String) throws {
        guard !apiKey.isEmpty else { return try delete() }
        do {
            try store(Data(apiKey.utf8), in: .dataProtection)
        } catch let error as KeychainError where error.status == errSecMissingEntitlement {
            // macOS opens the data-protection keychain only to an app signed with a team, so a
            // locally signed build stores the key rather than refusing to.
            guard let fallback = fallbackKeychain else { throw error }
            try store(Data(apiKey.utf8), in: fallback)
        }
    }

    /// macOS keeps an older keychain alongside the data-protection one; iOS has only the one.
    private var fallbackKeychain: Keychain? {
        #if os(macOS)
        return .file
        #else
        return nil
        #endif
    }

    private func read(from keychain: Keychain) throws -> String? {
        var query = baseQuery(keychain)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess:
            guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
                throw KeychainError(operation: "read", status: errSecInvalidData)
            }
            return key
        case errSecItemNotFound:
            return nil
        case let status:
            throw KeychainError(operation: "read", status: status)
        }
    }

    private func store(_ value: Data, in keychain: Keychain) throws {
        let updated = SecItemUpdate(
            baseQuery(keychain) as CFDictionary,
            [kSecValueData as String: value] as CFDictionary
        )
        guard updated == errSecItemNotFound else {
            guard updated == errSecSuccess else { throw KeychainError(operation: "update", status: updated) }
            return
        }

        var item = baseQuery(keychain)
        item[kSecValueData as String] = value
        if keychain == .dataProtection {
            // C3 runs transfers in the background, where the device can be locked from the
            // first byte to the last; the key still has to be readable then.
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        }
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(operation: "add", status: added) }
    }

    /// Clearing the key clears it from both keychains: which one holds it depends on how the
    /// build that wrote it was signed.
    private func delete() throws {
        try delete(from: .dataProtection)
        if let fallback = fallbackKeychain {
            try delete(from: fallback)
        }
    }

    private func delete(from keychain: Keychain) throws {
        let status = SecItemDelete(baseQuery(keychain) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound || status == errSecMissingEntitlement
        else {
            throw KeychainError(operation: "delete", status: status)
        }
    }

    private func baseQuery(_ keychain: Keychain) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // The file keychain has neither: no access groups, and accessibility is a
        // data-protection notion.
        if keychain == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
