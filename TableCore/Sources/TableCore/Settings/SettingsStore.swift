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

    /// `inheritingFrom` is the defaults an earlier build wrote to: iOS moved the host URL into
    /// the app group's suite for the share extension (DESIGN §5), and a device that was set up
    /// before that keeps its server rather than reading as unconfigured.
    public init(
        defaults: UserDefaults = .standard,
        inheritingFrom previous: UserDefaults? = nil,
        apiKeys: any APIKeyStore
    ) {
        self.defaults = defaults
        self.apiKeys = apiKeys
        if let previous, defaults.string(forKey: Key.hostURL) == nil {
            inherit(from: previous)
        }
    }

    /// Whether a server has been set up, answered without a keychain: the share extension has
    /// no API key and no use for one (DESIGN §5).
    public static func hasHost(in defaults: UserDefaults) -> Bool {
        !(defaults.string(forKey: Key.hostURL) ?? "").trimmed.isEmpty
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

    private func inherit(from previous: UserDefaults) {
        guard let hostURL = previous.string(forKey: Key.hostURL) else { return }
        defaults.set(hostURL, forKey: Key.hostURL)
        defaults.set(previous.bool(forKey: Key.allowInsecureHTTP), forKey: Key.allowInsecureHTTP)
    }

    private enum Key {
        static let hostURL = "table.hostURL"
        static let allowInsecureHTTP = "table.allowInsecureHTTP"
    }
}
