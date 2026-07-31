import Foundation

/// The API key's only storage. Conformance rule 12 keeps it out of `UserDefaults`, logs and backups.
public protocol APIKeyStore: Sendable {
    /// The stored key, or "" when none was ever written.
    func read() throws -> String

    /// An empty key removes the stored one.
    func write(_ apiKey: String) throws
}

/// DESIGN §5: host URL in `UserDefaults`, API key in the Keychain, one type over both.
///
/// `@unchecked` only because `UserDefaults` is thread-safe but predates `Sendable`.
public struct SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let apiKeys: any APIKeyStore

    public init(defaults: UserDefaults = .standard, apiKeys: any APIKeyStore) {
        self.defaults = defaults
        self.apiKeys = apiKeys
    }

    public func load() throws -> TableSettings {
        TableSettings(
            hostURL: defaults.string(forKey: Key.hostURL) ?? "",
            apiKey: try apiKeys.read(),
            allowInsecureHTTP: defaults.bool(forKey: Key.allowInsecureHTTP)
        )
    }

    public func save(_ settings: TableSettings) throws {
        defaults.set(settings.hostURL.trimmed, forKey: Key.hostURL)
        defaults.set(settings.allowInsecureHTTP, forKey: Key.allowInsecureHTTP)
        try apiKeys.write(settings.apiKey.trimmed)
    }

    private enum Key {
        static let hostURL = "table.hostURL"
        static let allowInsecureHTTP = "table.allowInsecureHTTP"
    }
}
