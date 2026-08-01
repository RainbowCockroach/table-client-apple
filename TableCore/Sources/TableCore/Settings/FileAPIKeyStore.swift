import Foundation

/// The API key in a `0600` file in the container, for builds that cannot reach a keychain
/// that stays quiet (DESIGN §5).
///
/// macOS pins a file-keychain item's ACL to the app's designated requirement, which for a
/// locally signed build is its `cdhash` — so every rebuild reads as a different app and the
/// system asks for the login password again. The data-protection keychain has no ACL and would
/// not ask, but it needs an `application-identifier` entitlement no ad-hoc signature can carry.
public struct FileAPIKeyStore: APIKeyStore {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func read() throws -> String {
        guard let data = try? Data(contentsOf: fileURL) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public func write(_ apiKey: String) throws {
        guard !apiKey.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(apiKey.utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path(percentEncoded: false)
        )
    }
}
