import Foundation

/// `File` in openapi.yaml.
public struct TableFile: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let size: Int64
    public let sha256: String
    public let state: FileState
    public let bytesReceived: Int64
    public let uploadedAt: Date?
    public let expiresAt: Date?

    public init(
        id: String,
        name: String,
        size: Int64,
        sha256: String,
        state: FileState,
        bytesReceived: Int64,
        uploadedAt: Date? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.sha256 = sha256
        self.state = state
        self.bytesReceived = bytesReceived
        self.uploadedAt = uploadedAt
        self.expiresAt = expiresAt
    }
}

public enum FileState: String, Codable, Sendable {
    /// Upload still running: live progress in `bytesReceived`, no TTL yet, downloadable via live relay.
    case uploading
    case available
}

/// Outcome of `PATCH /uploads/{id}`.
public enum AppendResult: Sendable, Equatable {
    /// Final byte accepted: size and hash verified server-side, TTL now running.
    case finalized(TableFile)

    /// Bytes committed, more expected — the request body ended early.
    case incomplete(committedOffset: Int64)

    /// `409`: the offset sent was not the committed one. Resume from the given offset.
    case offsetMismatch(committedOffset: Int64)

    /// `404`: session unknown, aborted, idle-GC'd, or already finalized.
    case sessionGone

    /// `422`: declared size/hash did not match. Conformance rule 3 — retry with a NEW session.
    case finalizeRejected(message: String?)
}

/// Outcome of `POST /files/{id}/ack`. Conformance rules 8-10.
public enum AckResult: Sendable, Equatable {
    /// `204`: hash matched, server deleted the file.
    case deleted

    /// `404`/`410`: another device completed it first. Rule 9 — the desired end state holds.
    case alreadyGone

    /// `409`: the local copy is corrupt. Rule 10 — discard it and re-download.
    case hashMismatch
}

struct UploadCreate: Encodable {
    let name: String
    let size: Int64
    let sha256: String
}

struct UploadCreated: Decodable {
    let id: String
}

struct AckRequest: Encodable {
    let sha256: String
}

struct ApiErrorBody: Decodable {
    let error: String
}

enum TableJSON {
    static let encoder = JSONEncoder()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = rfc3339(text) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "not an RFC 3339 timestamp: \(text)")
                )
            }
            return date
        }
        return decoder
    }()
}

/// The server writes Go's RFC 3339, which carries fractional seconds only when they are non-zero.
private func rfc3339(_ text: String) -> Date? {
    (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        ?? (try? Date(text, strategy: Date.ISO8601FormatStyle()))
}
