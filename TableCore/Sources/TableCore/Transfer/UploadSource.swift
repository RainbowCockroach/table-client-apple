import Foundation

/// A file to upload.
///
/// Always a file on disk: a picked document, a share-extension copy in the app group
/// container, or a resume slice — which is what lets a resumed `PATCH` seek instead of
/// re-reading from the start (DESIGN §2).
public struct UploadSource: Sendable, Hashable {
    public let fileURL: URL
    public let name: String
    public let size: Int64

    public init(fileURL: URL, name: String? = nil) throws {
        guard FileManager.default.isReadableFile(atPath: fileURL.path(percentEncoded: false)) else {
            throw TableError.sourceNotReadable(fileURL)
        }
        self.fileURL = fileURL
        self.name = name ?? fileURL.lastPathComponent
        size = fileSize(fileURL)
    }
}
