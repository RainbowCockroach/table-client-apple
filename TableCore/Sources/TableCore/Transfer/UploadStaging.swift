import Foundation

/// Everything the share extension is allowed to do: copy the item into the shared container
/// and append a queue row (DESIGN §4).
///
/// No hashing and no network — an extension lives only as long as its UI, and conformance
/// rule 1 needs the whole file hashed before a session can even be created. The app picks the
/// row up and does that work.
///
/// The copy comes first and the row second, so a queue sweep in the other process can at worst
/// delete a file no row claims yet; the reverse order would leave a row pointing at a
/// half-written file, which is a truncated upload rather than a visible failure.
public struct UploadStaging: Sendable {
    private let store: any TransferStore
    private let directory: URL
    private let newID: @Sendable () -> String
    private let now: @Sendable () -> Date

    public init(
        store: any TransferStore,
        directory: URL,
        newID: @escaping @Sendable () -> String = { UUID().uuidString },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.directory = directory
        self.newID = newID
        self.now = now
    }

    /// Copies `fileURL` into the container and queues the copy. `name` overrides the file name
    /// shown to the user and sent to the server — a share sheet often has a better one than the
    /// temporary file it hands over.
    @discardableResult
    public func stage(_ fileURL: URL, name: String? = nil) async throws -> TransferRecord {
        try await queue(copyIn(fileURL, name: name))
    }

    /// The copy half, on its own because a shared item is readable only inside the callback
    /// that hands it over, and that callback cannot wait for a database write.
    public func copyIn(_ fileURL: URL, name: String? = nil) throws -> UploadSource {
        let original = try UploadSource(fileURL: fileURL, name: name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appending(path: "\(newID())-\(safeDisplayName(original.name))")
        try FileManager.default.copyItem(at: original.fileURL, to: copy)
        return try UploadSource(fileURL: copy, name: original.name)
    }

    /// The row half. A copy no row claims is nobody's file, so a failure here takes it with it.
    @discardableResult
    public func queue(_ copy: UploadSource) async throws -> TransferRecord {
        let record = TransferRecord.upload(copy, id: newID(), createdAt: now())
        do {
            try await store.put(record)
        } catch {
            try? FileManager.default.removeItem(at: copy.fileURL)
            throw error
        }
        return record
    }
}

extension TransferRecord {
    /// One definition of an upload row, whichever process appends it.
    static func upload(_ source: UploadSource, id: String, createdAt: Date) -> TransferRecord {
        TransferRecord(
            id: id,
            direction: .upload,
            name: source.name,
            size: source.size,
            sourcePath: source.fileURL.path(percentEncoded: false),
            createdAt: createdAt
        )
    }
}
