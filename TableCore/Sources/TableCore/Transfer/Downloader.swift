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
    private let fetcher: any DownloadFetcher

    public init(_ client: TableClient, fetcher: any DownloadFetcher = StreamingDownloadFetcher()) {
        self.client = client
        self.fetcher = fetcher
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
            let fetched: FetchedBytes
            do {
                fetched = try await fetcher.fetch(client, target, into: tempFile, onProgress: onProgress)
            } catch TableError.fileGone {
                return .gone
            }
            guard fetched.bytesOnDisk >= target.size else {
                return .incomplete(bytesOnDisk: fetched.bytesOnDisk)
            }
            localHash = try fetched.sha256 ?? sha256Hex(fileAt: tempFile)
        }
        return try await verifyAndAck(target, tempFile: tempFile, localHash: localHash)
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
