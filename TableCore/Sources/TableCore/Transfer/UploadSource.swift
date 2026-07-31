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

    /// Rejects here what `POST /uploads` would reject on the wire, so a file that can never be
    /// sent is refused where it is picked rather than becoming a dead queue row.
    public init(fileURL: URL, name: String? = nil) throws {
        let path = fileURL.path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              FileManager.default.isReadableFile(atPath: path)
        else {
            throw TableError.sourceNotReadable(fileURL)
        }
        guard !isDirectory.boolValue else {
            throw TableError.invalidRequest("a folder, not a file")
        }
        size = fileSize(fileURL)
        guard size > 0 else {
            throw TableError.invalidRequest("empty; an upload needs at least one byte")
        }
        self.fileURL = fileURL
        self.name = name ?? fileURL.lastPathComponent
    }
}
