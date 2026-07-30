import Foundation

/// An open download response: the server's declarations, plus the body in chunks.
///
/// A `206` carries only the requested range; ``totalSize`` is the size of the whole file
/// either way, which is what the length check in conformance rule 6 compares against.
public struct DownloadStream: Sendable {
    public let statusCode: Int

    /// `X-Checksum-SHA256`: the full-file hash, present on `200` and `206` alike.
    public let checksumSHA256: String?

    public let fileName: String?

    /// Offset of the first byte in this response body.
    public let rangeStart: Int64

    /// Size of the complete file, or nil if the server declared neither form of length.
    public let totalSize: Int64?

    public let body: AsyncThrowingStream<Data, Error>

    private let release: @Sendable () -> Void

    init(response: HTTPURLResponse, body: AsyncThrowingStream<Data, Error>, release: @escaping @Sendable () -> Void) {
        statusCode = response.statusCode
        checksumSHA256 = response.value(forHTTPHeaderField: "X-Checksum-SHA256")
        fileName = response.value(forHTTPHeaderField: "Content-Disposition").flatMap(fileName(inContentDisposition:))
        let contentRange = response.value(forHTTPHeaderField: "Content-Range").flatMap(parseContentRange)
        rangeStart = contentRange?.start ?? 0
        totalSize = contentRange?.total ?? (response.expectedContentLength >= 0 ? response.expectedContentLength : nil)
        self.body = body
        self.release = release
    }

    /// Drops the connection. A no-op once the body has been read to its end.
    public func cancel() {
        release()
    }
}

private func parseContentRange(_ header: String) -> (start: Int64, total: Int64)? {
    let parts = header
        .replacingOccurrences(of: "bytes", with: "")
        .trimmingCharacters(in: .whitespaces)
        .split(separator: "/")
    guard parts.count == 2,
          let total = Int64(parts[1].trimmingCharacters(in: .whitespaces)),
          let start = Int64(parts[0].split(separator: "-").first?.trimmingCharacters(in: .whitespaces) ?? "")
    else { return nil }
    return (start, total)
}

private func fileName(inContentDisposition header: String) -> String? {
    for parameter in header.split(separator: ";") {
        let pair = parameter.split(separator: "=", maxSplits: 1)
        guard pair.count == 2 else { continue }
        let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
        guard key == "filename" || key == "filename*" else { continue }
        let value = pair[1].trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .replacingOccurrences(of: "UTF-8''", with: "")
        return value.isEmpty ? nil : value.removingPercentEncoding ?? value
    }
    return nil
}
