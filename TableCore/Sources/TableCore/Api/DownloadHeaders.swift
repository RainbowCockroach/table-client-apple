import Foundation

/// What the server declares about a download response.
///
/// Read the same way whether the body arrives as a stream or as a file a background task
/// delivered (DESIGN §2), so conformance rule 6 is checked in one place for both.
public struct DownloadHeaders: Sendable, Hashable {
    public let statusCode: Int

    /// `X-Checksum-SHA256`: the full-file hash, present on `200` and `206` alike.
    public let checksumSHA256: String?

    public let fileName: String?

    /// Offset of the first byte in this response body.
    public let rangeStart: Int64

    /// Size of the complete file, or nil if the server declared neither form of length.
    public let totalSize: Int64?

    public init(_ response: HTTPURLResponse) {
        statusCode = response.statusCode
        checksumSHA256 = response.value(forHTTPHeaderField: "X-Checksum-SHA256")
        fileName = response.value(forHTTPHeaderField: "Content-Disposition").flatMap(fileName(inContentDisposition:))
        let contentRange = response.value(forHTTPHeaderField: "Content-Range").flatMap(parseContentRange)
        rangeStart = contentRange?.start ?? 0
        totalSize = contentRange?.total ?? (response.expectedContentLength >= 0 ? response.expectedContentLength : nil)
    }
}

/// Rule 6 verifies against what the server declares on the wire, so it has to declare it —
/// and it has to still be the file the queue asked for.
func checkDeclarations(_ headers: DownloadHeaders, match target: DownloadTarget) throws {
    guard let declaredSize = headers.totalSize else {
        throw TableError.malformedResponse("download \(target.id): server declared no length")
    }
    guard let declaredHash = headers.checksumSHA256 else {
        throw TableError.malformedResponse("download \(target.id): no X-Checksum-SHA256 header")
    }
    guard declaredSize == target.size, declaredHash == target.sha256 else {
        throw TableError.malformedResponse(
            "download \(target.id): server now declares \(declaredSize)/\(declaredHash), "
                + "queued as \(target.size)/\(target.sha256)"
        )
    }
}

/// The download statuses outside `200`/`206`, as the errors the queue acts on.
func downloadFailure(_ headers: DownloadHeaders, id: String, body: Data) -> TableError {
    switch headers.statusCode {
    case 404, 410:
        return .fileGone(id: id, statusCode: headers.statusCode)
    case 416:
        return .rangeNotSatisfiable(id: id)
    case 401:
        return .unauthorized(operation: "download \(id)")
    default:
        return .unexpectedStatus(
            operation: "download \(id)",
            statusCode: headers.statusCode,
            serverMessage: serverMessage(body)
        )
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
