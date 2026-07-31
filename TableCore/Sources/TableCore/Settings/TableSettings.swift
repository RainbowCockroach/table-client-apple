import Foundation

/// Everything needed to reach a server. The key is read back from the Keychain (DESIGN §5).
public struct TableSettings: Sendable, Hashable {
    public var hostURL: String

    public var apiKey: String

    /// Conformance rule 13: plain `http://` is refused unless this is turned on deliberately.
    public var allowInsecureHTTP: Bool

    public init(hostURL: String = "", apiKey: String = "", allowInsecureHTTP: Bool = false) {
        self.hostURL = hostURL
        self.apiKey = apiKey
        self.allowInsecureHTTP = allowInsecureHTTP
    }

    public var isConfigured: Bool {
        !hostURL.trimmed.isEmpty && !apiKey.trimmed.isEmpty
    }

    /// A client for these settings; throws before any request goes out if the host is unusable.
    public func client(configuration: URLSessionConfiguration = .tableForeground) throws -> TableClient {
        try TableClient(
            hostURL: hostURL.trimmed,
            apiKey: apiKey.trimmed,
            allowInsecureHTTP: allowInsecureHTTP,
            configuration: configuration
        )
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
