import Foundation

/// An open upload session. The queue persists it so a resumed transfer keeps the same session.
public struct UploadSession: Sendable, Hashable {
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
}

public enum UploadOutcome: Sendable, Equatable {
    /// The last byte landed and the server verified size and hash; the TTL is now running.
    case finalized(TableFile)

    /// The server holds this many bytes and wants more; the next attempt continues there.
    case interrupted(committedOffset: Int64)

    /// The session is gone (aborted or idle-GC'd). A new session is the only way forward.
    case sessionGone

    /// Finalize rejected the bytes. Conformance rule 3: the server already discarded the
    /// session, so the retry needs a brand-new one.
    case rejected(message: String?)
}

/// One attempt at pushing an upload session to completion.
///
/// Retry and backoff belong to the caller; each attempt asks the server where it got to
/// rather than assuming (conformance rules 2, 14).
public struct Uploader: Sendable {
    private let client: TableClient
    private let sender: any UploadSender

    public init(_ client: TableClient, sender: any UploadSender = StreamingUploadSender()) {
        self.client = client
        self.sender = sender
    }

    /// Conformance rule 1: size and SHA-256 are computed before the session is created.
    public func createSession(for source: UploadSource) async throws -> UploadSession {
        let sha256 = try sha256Hex(fileAt: source.fileURL)
        let id = try await client.createUpload(name: source.name, size: source.size, sha256: sha256)
        return UploadSession(id: id, name: source.name, size: source.size, sha256: sha256)
    }

    public func upload(
        _ session: UploadSession,
        from source: UploadSource,
        onProgress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> UploadOutcome {
        // Rule 2: the committed offset comes from the server, never from local bookkeeping.
        guard let offset = try await client.uploadOffset(id: session.id) else {
            return .sessionGone
        }
        guard offset < session.size else {
            throw TableError.malformedResponse(
                "session \(session.id) reports offset \(offset) for a \(session.size)-byte file"
            )
        }

        let result = try await sender.send(client, session, from: source, at: offset, onProgress: onProgress)
        switch result {
        case .finalized(let file):
            return .finalized(file)
        case .incomplete(let committed), .offsetMismatch(let committed):
            return .interrupted(committedOffset: committed)
        case .sessionGone:
            return .sessionGone
        case .finalizeRejected(let message):
            return .rejected(message: message)
        }
    }
}
