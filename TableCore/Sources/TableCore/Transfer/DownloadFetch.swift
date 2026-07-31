import Foundation

/// What one fetch attempt left in the temp file.
public struct FetchedBytes: Sendable, Hashable {
    public let bytesOnDisk: Int64

    /// Set only by a fetcher that hashed while it wrote; otherwise the caller hashes the
    /// finished temp file itself.
    public let sha256: String?

    public init(bytesOnDisk: Int64, sha256: String? = nil) {
        self.bytesOnDisk = bytesOnDisk
        self.sha256 = sha256
    }
}

/// How the bytes of a download reach the temp file — the one thing that differs between the
/// foreground session and iOS's background session (DESIGN §2).
///
/// Every implementation resumes from what the temp file already holds (conformance rule 5)
/// and leaves verification, acking and publishing to ``Downloader``.
public protocol DownloadFetcher: Sendable {
    func fetch(
        _ client: TableClient,
        _ target: DownloadTarget,
        into tempFile: URL,
        onProgress: (@Sendable (Int64) -> Void)?
    ) async throws -> FetchedBytes
}

/// Streams the missing tail into the temp file, hashing the complete file as it goes.
public struct StreamingDownloadFetcher: DownloadFetcher {
    public init() {}

    public func fetch(
        _ client: TableClient,
        _ target: DownloadTarget,
        into tempFile: URL,
        onProgress: (@Sendable (Int64) -> Void)?
    ) async throws -> FetchedBytes {
        let stream = try await client.openDownload(id: target.id, rangeFrom: fileSize(tempFile))
        do {
            try checkDeclarations(stream.headers, match: target)
        } catch {
            stream.cancel()
            throw error
        }

        if !FileManager.default.fileExists(atPath: tempFile.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: tempFile.path(percentEncoded: false), contents: nil)
        }
        let sink = try FileHandle(forWritingTo: tempFile)
        var hasher = Sha256Hasher()
        var onDisk = stream.rangeStart
        do {
            // A server that ignored the Range answers from byte 0, so whatever we had is
            // superseded rather than appended to.
            try sink.truncate(atOffset: UInt64(stream.rangeStart))
            try rehashKeptBytes(of: tempFile, upTo: stream.rangeStart, into: &hasher)
            try sink.seek(toOffset: UInt64(stream.rangeStart))

            for try await chunk in stream.body {
                try sink.write(contentsOf: chunk)
                hasher.update(chunk)
                onDisk += Int64(chunk.count)
                onProgress?(onDisk)
            }
            // Rule 7: durable before anything acks it.
            try sink.synchronize()
            try sink.close()
        } catch {
            stream.cancel()
            try? sink.synchronize()
            try? sink.close()
            throw error
        }
        return FetchedBytes(bytesOnDisk: onDisk, sha256: hasher.hex())
    }

    /// DESIGN §2: a resumed download rebuilds its digest from the bytes already on disk.
    private func rehashKeptBytes(of tempFile: URL, upTo keptBytes: Int64, into hasher: inout Sha256Hasher) throws {
        guard keptBytes > 0 else { return }
        try hasher.update(contentsOf: tempFile)
        guard hasher.bytesHashed == keptBytes else {
            throw TableError.malformedResponse(
                "partial file shrank to \(hasher.bytesHashed) while rebuilding the digest"
            )
        }
    }
}

/// Hands the fetch to a background session, which keeps going while the app is suspended and
/// appends what it receives whether or not this process is still there to see it (DESIGN §2).
///
/// The delivered file is complete rather than a stream, so nothing is hashed here: the digest
/// is computed over the temp file once the bytes are all in.
public struct BackgroundDownloadFetcher: DownloadFetcher {
    private let transport: any FileDownloadTransport

    public init(transport: any FileDownloadTransport) {
        self.transport = transport
    }

    public func fetch(
        _ client: TableClient,
        _ target: DownloadTarget,
        into tempFile: URL,
        onProgress: (@Sendable (Int64) -> Void)?
    ) async throws -> FetchedBytes {
        let resumeFrom = fileSize(tempFile)
        var absoluteProgress: (@Sendable (Int64) -> Void)?
        if let onProgress {
            absoluteProgress = { received in onProgress(resumeFrom + received) }
        }
        let onDisk = try await client.download(
            BackgroundDownloadPlan(target, partialFile: tempFile),
            via: transport,
            onProgress: absoluteProgress
        )
        return FetchedBytes(bytesOnDisk: onDisk)
    }
}
