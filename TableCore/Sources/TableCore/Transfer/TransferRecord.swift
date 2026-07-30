import Foundation

/// DESIGN §3: `queued → running → verifying → done | failed`.
public enum TransferState: String, Codable, Sendable {
    case queued
    case running
    case verifying
    case done
    case failed
}

public enum TransferDirection: String, Codable, Sendable, CaseIterable {
    case upload
    case download
}

/// Why a transfer stopped. `retryable` separates "try again" from "this will never work".
public struct TransferFailure: Codable, Sendable, Hashable {
    public let message: String
    public let retryable: Bool

    public init(message: String, retryable: Bool) {
        self.message = message
        self.retryable = retryable
    }
}

/// One row of the persistent queue.
///
/// Conformance rule 14: this is everything an attempt needs to resume after process death —
/// the upload session id, the file id, and the source file — so the next attempt asks the
/// server where it got to instead of starting over.
public struct TransferRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var direction: TransferDirection
    public var name: String
    public var size: Int64
    public var state: TransferState

    /// Download: the file id, known from the listing. Upload: the session id, nil until created.
    public var remoteID: String?

    /// The declared hash: the server's for a download, ours for an upload (rule 1).
    public var sha256: String?

    /// Upload: the file the bytes come from, seeked to the committed offset on resume.
    public var sourcePath: String?

    public var bytesDone: Int64
    public var failure: TransferFailure?

    /// Attempts since the last success or user retry; what the backoff and give-up cap count.
    public var attempts: Int

    public var publishedName: String?
    public var publishedPath: String?
    public var createdAt: Date

    public init(
        id: String,
        direction: TransferDirection,
        name: String,
        size: Int64,
        state: TransferState = .queued,
        remoteID: String? = nil,
        sha256: String? = nil,
        sourcePath: String? = nil,
        bytesDone: Int64 = 0,
        failure: TransferFailure? = nil,
        attempts: Int = 0,
        publishedName: String? = nil,
        publishedPath: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.direction = direction
        self.name = name
        self.size = size
        self.state = state
        self.remoteID = remoteID
        self.sha256 = sha256
        self.sourcePath = sourcePath
        self.bytesDone = bytesDone
        self.failure = failure
        self.attempts = attempts
        self.publishedName = publishedName
        self.publishedPath = publishedPath
        self.createdAt = createdAt
    }

    public var isFinished: Bool {
        state == .done || state == .failed
    }

    /// True while the transfer is worth spending more effort on.
    public var isLive: Bool {
        state != .done && failure?.retryable != false
    }

    public var downloadTarget: DownloadTarget? {
        guard let remoteID, let sha256 else { return nil }
        return DownloadTarget(id: remoteID, name: name, size: size, sha256: sha256)
    }

    /// The session a previous attempt opened, if it got that far (rules 2, 14).
    public var uploadSession: UploadSession? {
        guard let remoteID, let sha256 else { return nil }
        return UploadSession(id: remoteID, name: name, size: size, sha256: sha256)
    }
}

public enum TransferResult: Sendable {
    /// Uploads finalize on the server; downloads carry where they were published.
    case done(published: PublishedDownload?)

    case failed(TransferFailure)
}

func retryable(_ message: String) -> TransferResult {
    .failed(TransferFailure(message: message, retryable: true))
}

func permanent(_ message: String) -> TransferResult {
    .failed(TransferFailure(message: message, retryable: false))
}

func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}
