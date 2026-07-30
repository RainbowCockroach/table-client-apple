import Foundation

/// Where a download landed: the name it actually got, and the path the completion
/// notification can reveal it at (DESIGN §4).
public struct PublishedDownload: Sendable, Hashable {
    public let name: String
    public let path: String?

    public init(name: String, path: String? = nil) {
        self.name = name
        self.path = path
    }
}

/// The last step of conformance rule 11: move a verified, acked copy somewhere the user can see.
///
/// An implementation must either publish the whole file or leave nothing behind and throw —
/// ``DownloadTask`` keeps the temp file until this returns, so a failure costs a retry, never data.
public protocol DownloadPublisher: Sendable {
    func publish(_ source: URL, displayName: String) throws -> PublishedDownload
}

/// Publishes into a directory: `~/Downloads` on macOS, the app's Documents directory on
/// iOS/iPadOS (DESIGN §3).
public struct DirectoryDownloadPublisher: DownloadPublisher {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func publish(_ source: URL, displayName: String) throws -> PublishedDownload {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = uniqueDisplayName(safeDisplayName(displayName)) { candidate in
            FileManager.default.fileExists(atPath: destination(candidate).path(percentEncoded: false))
        }
        // A move leaves the temp file untouched if it fails, which is what rule 11 needs, and
        // spares a multi-GB copy when the container and the destination share a volume.
        try FileManager.default.moveItem(at: source, to: destination(name))
        return PublishedDownload(name: name, path: destination(name).path(percentEncoded: false))
    }

    private func destination(_ name: String) -> URL {
        directory.appending(path: name)
    }
}
