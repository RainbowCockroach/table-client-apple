import Foundation

/// How the bytes of an upload leave the device — the one thing that differs between the
/// foreground session and iOS's background session (DESIGN §2).
///
/// The offset is the server's, read by ``Uploader`` before every attempt (conformance rule 2);
/// a sender only has to send from there to the end of the source.
public protocol UploadSender: Sendable {
    func send(
        _ client: TableClient,
        _ session: UploadSession,
        from source: UploadSource,
        at offset: Int64,
        onProgress: (@Sendable (Int64) -> Void)?
    ) async throws -> AppendResult
}

/// Streams the `PATCH` body straight from the source file, seeked to the offset.
public struct StreamingUploadSender: UploadSender {
    public init() {}

    public func send(
        _ client: TableClient,
        _ session: UploadSession,
        from source: UploadSource,
        at offset: Int64,
        onProgress: (@Sendable (Int64) -> Void)?
    ) async throws -> AppendResult {
        try await client.appendBytes(
            id: session.id,
            offset: offset,
            from: source.fileURL,
            onProgress: onProgress
        )
    }
}

/// Hands the `PATCH` to a background session, which keeps sending while the app is suspended.
///
/// DESIGN §2: a background task uploads a file front to back, so a resume from a non-zero
/// offset materializes the remainder as its own file first. That is the rare path — a fresh
/// upload sends the source itself — and the slice is deleted as soon as the attempt is over.
public struct BackgroundUploadSender: UploadSender {
    private let transport: any FileBodyTransport
    private let sliceDirectory: URL

    public init(transport: any FileBodyTransport, sliceDirectory: URL) {
        self.transport = transport
        self.sliceDirectory = sliceDirectory
    }

    public func send(
        _ client: TableClient,
        _ session: UploadSession,
        from source: UploadSource,
        at offset: Int64,
        onProgress: (@Sendable (Int64) -> Void)?
    ) async throws -> AppendResult {
        let slice = offset > 0 ? sliceDirectory.appending(path: "\(session.id).slice") : nil
        if let slice {
            try materializeUploadSlice(of: source.fileURL, from: offset, into: slice)
        }
        defer {
            if let slice { try? FileManager.default.removeItem(at: slice) }
        }
        return try await client.appendWholeFile(
            id: session.id,
            offset: offset,
            bodyFile: slice ?? source.fileURL,
            via: transport,
            onProgress: onProgress
        )
    }
}

/// Writes the bytes of `fileURL` from `offset` to its end into `sliceFile`.
func materializeUploadSlice(of fileURL: URL, from offset: Int64, into sliceFile: URL) throws {
    guard let source = try? FileHandle(forReadingFrom: fileURL) else {
        throw TableError.sourceNotReadable(fileURL)
    }
    defer { try? source.close() }
    try FileManager.default.createDirectory(
        at: sliceFile.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try? FileManager.default.removeItem(at: sliceFile)
    guard FileManager.default.createFile(atPath: sliceFile.path(percentEncoded: false), contents: nil) else {
        throw TableError.sourceNotReadable(sliceFile)
    }
    let sink = try FileHandle(forWritingTo: sliceFile)
    defer { try? sink.close() }

    try source.seek(toOffset: UInt64(offset))
    while let chunk = try source.read(upToCount: transferBufferBytes), !chunk.isEmpty {
        try sink.write(contentsOf: chunk)
    }
    // The session hands the file to another process, which may read it after this one is gone.
    try sink.synchronize()
}
