import Foundation

/// An open download response: the server's declarations, plus the body in chunks.
public struct DownloadStream: Sendable {
    public let headers: DownloadHeaders

    public let body: AsyncThrowingStream<Data, Error>

    private let release: @Sendable () -> Void

    public var statusCode: Int { headers.statusCode }
    public var checksumSHA256: String? { headers.checksumSHA256 }
    public var fileName: String? { headers.fileName }
    public var rangeStart: Int64 { headers.rangeStart }
    public var totalSize: Int64? { headers.totalSize }

    init(response: HTTPURLResponse, body: AsyncThrowingStream<Data, Error>, release: @escaping @Sendable () -> Void) {
        headers = DownloadHeaders(response)
        self.body = body
        self.release = release
    }

    /// Drops the connection. A no-op once the body has been read to its end.
    public func cancel() {
        release()
    }
}
