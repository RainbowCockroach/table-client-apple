import Foundation

/// The app group the iOS app and its share extension both live in (DESIGN §4).
///
/// macOS has neither: no extension shares its queue, and a group container there would need a
/// team-prefixed identifier from a provisioning profile.
public enum AppGroup {
    public static let identifier = "group.rainbowroachie.Table"

    /// Where the host URL is stored, so the extension can see whether there is a server to
    /// queue for (DESIGN §5). Nil without the group entitlement.
    public static func defaults() -> UserDefaults? {
        UserDefaults(suiteName: identifier)
    }

    public static func containerURL() throws -> URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
        else {
            throw MissingAppGroup(identifier: identifier)
        }
        return url
    }
}

/// Without the group there is no shared queue and nothing works, so this is what the app shows
/// instead of the file list.
public struct MissingAppGroup: Error, LocalizedError {
    public let identifier: String

    public var errorDescription: String? {
        "no app group container for \(identifier) — this build is missing the entitlement"
    }
}

/// Every path inside the container, resolved the same way by the app and by the share
/// extension — which is the whole point of the app group (DESIGN §3, §4).
public struct ContainerPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The shared container of DESIGN §3.
    public static func appGroup() throws -> ContainerPaths {
        ContainerPaths(root: try AppGroup.containerURL().appending(path: "table"))
    }

    public var queueDatabase: URL {
        root.appending(path: "queue.sqlite")
    }

    /// Conformance rule 4: downloads stream here, never straight into the publish directory.
    public var partialDownloads: URL {
        root.appending(path: "downloads")
    }

    /// The copies an upload reads from. A background upload is sent by another process from a
    /// file, and a shared or picked item is gone once its process is (DESIGN §4).
    public var stagedUploads: URL {
        root.appending(path: "uploads")
    }

    /// Where a background upload's resume slice is materialized (DESIGN §2).
    public var uploadSlices: URL {
        root.appending(path: "slices")
    }

    /// macOS: the security-scoped bookmarks that outlive a launch (conformance rule 14).
    public var sourceBookmarks: URL {
        root.appending(path: "sources.json")
    }

    /// macOS: the API key, which does not live in a keychain there (DESIGN §5).
    public var apiKeyFile: URL {
        root.appending(path: "api-key")
    }

    /// Creates the container. Both processes call this; whoever gets there first wins.
    public func create() throws {
        var attributes: [FileAttributeKey: Any] = [:]
        #if os(iOS)
        // A background transfer writes here with the device locked, the same reach the API key
        // is stored with.
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: attributes
        )
        #if os(iOS)
        try excludeFromBackup()
        #endif
    }

    /// Everything in here is a transfer in flight; none of it should come back on a restored
    /// device.
    private func excludeFromBackup() throws {
        var directory = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }
}
