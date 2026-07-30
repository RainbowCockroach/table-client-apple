import Foundation

/// The server-declared identity of a file to download; survives process death in the queue.
public struct DownloadTarget: Sendable, Hashable {
    public let id: String
    public let name: String
    public let size: Int64
    public let sha256: String

    public init(id: String, name: String, size: Int64, sha256: String) {
        self.id = id
        self.name = name
        self.size = size
        self.sha256 = sha256
    }

    public init(_ file: TableFile) {
        self.init(id: file.id, name: file.name, size: file.size, sha256: file.sha256)
    }
}

public enum DownloadOutcome: Sendable, Equatable {
    /// Complete, verified, fsynced and acked. The temp file must survive until it has been
    /// published to the user-visible location (conformance rule 11).
    case verified(tempFile: URL, sha256: String, ack: AckResult)

    /// The stream ended early. The next attempt resumes from `bytesOnDisk` (rule 5).
    case incomplete(bytesOnDisk: Int64)

    /// The local copy failed verification and was discarded; re-download from zero (rules 6, 10).
    case corrupt(reason: String)

    /// The server no longer has the file and no complete local copy exists.
    case gone
}

/// One attempt at fetching a file into a temp file, verifying it, and acking it.
///
/// Retry and backoff belong to the caller: every attempt resumes from whatever the temp
/// file already holds rather than restarting (conformance rules 5, 14).
public struct Downloader: Sendable {
    private let client: TableClient

    public init(_ client: TableClient) {
        self.client = client
    }

    public func download(
        _ target: DownloadTarget,
        to tempFile: URL,
        onProgress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> DownloadOutcome {
        let localHash: String
        if fileSize(tempFile) >= target.size {
            // A previous attempt finished the bytes but not the ack; nothing left to fetch.
            localHash = try sha256Hex(fileAt: tempFile)
        } else {
            let fetched: Fetched
            do {
                fetched = try await fetch(target, into: tempFile, onProgress: onProgress)
            } catch TableError.fileGone {
                return .gone
            }
            guard fetched.bytesOnDisk >= target.size else {
                return .incomplete(bytesOnDisk: fetched.bytesOnDisk)
            }
            localHash = fetched.sha256
        }
        return try await verifyAndAck(target, tempFile: tempFile, localHash: localHash)
    }

    private struct Fetched {
        let bytesOnDisk: Int64
        let sha256: String
    }

    /// Streams the missing tail into `tempFile`, hashing the complete file as it goes.
    private func fetch(
        _ target: DownloadTarget,
        into tempFile: URL,
        onProgress: (@Sendable (Int64) -> Void)?
    ) async throws -> Fetched {
        let stream = try await client.openDownload(id: target.id, rangeFrom: fileSize(tempFile))
        try check(target, against: stream)

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
        return Fetched(bytesOnDisk: onDisk, sha256: hasher.hex())
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

    private func verifyAndAck(
        _ target: DownloadTarget,
        tempFile: URL,
        localHash: String
    ) async throws -> DownloadOutcome {
        let localSize = fileSize(tempFile)
        guard localSize == target.size else {
            return discard(tempFile, "expected \(target.size) bytes, local copy has \(localSize)")
        }
        guard localHash == target.sha256 else {
            return discard(tempFile, "SHA-256 mismatch: expected \(target.sha256), computed \(localHash)")
        }
        switch try await client.ack(id: target.id, sha256: localHash) {
        // Rule 9: another device got there first, and the file being gone is the point.
        case .deleted:
            return .verified(tempFile: tempFile, sha256: localHash, ack: .deleted)
        case .alreadyGone:
            return .verified(tempFile: tempFile, sha256: localHash, ack: .alreadyGone)
        // Rule 10: the server disagrees about the bytes, so the local copy loses.
        case .hashMismatch:
            return discard(tempFile, "server rejected the acked hash \(localHash)")
        }
    }

    private func discard(_ tempFile: URL, _ reason: String) -> DownloadOutcome {
        try? FileManager.default.removeItem(at: tempFile)
        return .corrupt(reason: reason)
    }

    /// Rule 6 verifies against what the server declares on the wire, so it has to declare it.
    private func check(_ target: DownloadTarget, against stream: DownloadStream) throws {
        guard let declaredSize = stream.totalSize else {
            stream.cancel()
            throw TableError.malformedResponse("download \(target.id): server declared no length")
        }
        guard let declaredHash = stream.checksumSHA256 else {
            stream.cancel()
            throw TableError.malformedResponse("download \(target.id): no X-Checksum-SHA256 header")
        }
        guard declaredSize == target.size, declaredHash == target.sha256 else {
            stream.cancel()
            throw TableError.malformedResponse(
                "download \(target.id): server now declares \(declaredSize)/\(declaredHash), "
                    + "queued as \(target.size)/\(target.sha256)"
            )
        }
    }
}

/// Zero for a file that is not there yet — a download that has not started and one whose
/// temp file is empty resume identically.
///
/// Asks the file system rather than `URL.resourceValues`, which caches inside the URL value
/// and would keep reporting the size a growing temp file had when it was first measured.
func fileSize(_ fileURL: URL) -> Int64 {
    let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path(percentEncoded: false))
    return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
}
