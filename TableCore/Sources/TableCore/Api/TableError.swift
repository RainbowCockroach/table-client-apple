import Foundation

/// Every failure the client raises itself; transport failures surface as `URLError`.
public enum TableError: Error, Sendable, Equatable {
    case invalidHost(String)

    /// Conformance rule 13: plain `http://` needs an explicit override.
    case insecureHost(String)

    /// `401`: the API key is missing or wrong. Never worth retrying without user action.
    case unauthorized(operation: String)

    /// `404`/`410` on download: the file is gone (acked elsewhere, expired, or upload aborted).
    case fileGone(id: String, statusCode: Int)

    /// `416`: the requested range starts at or beyond the bytes the server holds.
    ///
    /// Expected against a live-relay upload that has not reached the resume point yet
    /// (root DESIGN §2); the caller retries later.
    case rangeNotSatisfiable(id: String)

    /// A response outside the contract for that operation.
    case unexpectedStatus(operation: String, statusCode: Int, serverMessage: String?)

    /// The response was in-contract on status but not on content.
    case malformedResponse(String)

    /// The request would violate the contract before it is sent.
    case invalidRequest(String)

    /// The file to upload cannot be read or seeked to the resume offset.
    case sourceNotReadable(URL)
}

extension TableError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidHost(let host):
            return "not a valid http(s) URL: \(host)"
        case .insecureHost(let host):
            return "refusing plain http:// host \(host) — enable the insecure-host override to use it"
        case .unauthorized(let operation):
            return "\(operation) failed: the API key was rejected"
        case .fileGone(let id, let statusCode):
            return "download \(id) failed: the file is gone (HTTP \(statusCode))"
        case .rangeNotSatisfiable(let id):
            return "download \(id) failed: the server does not hold the requested range yet"
        case .unexpectedStatus(let operation, let statusCode, let serverMessage):
            let detail = serverMessage.map { " (\($0))" } ?? ""
            return "\(operation) failed: HTTP \(statusCode)\(detail)"
        case .malformedResponse(let detail), .invalidRequest(let detail):
            return detail
        case .sourceNotReadable(let url):
            return "cannot read \(url.lastPathComponent) to upload it"
        }
    }
}

/// Whether retrying the same request unchanged could plausibly succeed.
///
/// Transport failures and server-side faults are retryable; a rejected key or a
/// contract violation is not.
public enum RetryPolicy {
    public static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case is CancellationError:
            return false
        case let table as TableError:
            switch table {
            case .rangeNotSatisfiable:
                return true
            case .unexpectedStatus(_, let statusCode, _):
                return statusCode >= 500 || statusCode == 408 || statusCode == 429
            case .invalidHost, .insecureHost, .unauthorized, .fileGone, .malformedResponse,
                 .invalidRequest, .sourceNotReadable:
                return false
            }
        case let url as URLError:
            return url.code != .cancelled
        default:
            return false
        }
    }
}
