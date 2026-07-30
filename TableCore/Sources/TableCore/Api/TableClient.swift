import Foundation

/// No new bytes for this long fails the request. DESIGN §2: transfers get no overall
/// deadline — a multi-GB file must not race a stopwatch — so socket inactivity is the
/// only watchdog.
public let transferInactivityTimeout: TimeInterval = 60

extension URLSessionConfiguration {
    /// The foreground configuration from DESIGN §2; iOS background sessions are checkpoint C3.
    public static var tableForeground: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = transferInactivityTimeout
        configuration.httpShouldUsePipelining = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }
}

/// Sees every request just before it is sent and every response as it arrives.
///
/// The seam the conformance tests assert the resume rules through — `Range` and
/// `Upload-Offset` are only observable on the wire — and how they arm the server's
/// `X-Test-Drop-After` fault. Nothing in the app installs one.
protocol WireHook: Sendable {
    func annotate(_ request: inout URLRequest)
    func record(_ request: URLRequest, _ response: HTTPURLResponse)
}

/// Typed wrapper over the table server API.
///
/// Callers own retry and backoff. ``openDownload(id:rangeFrom:)`` hands back a live
/// connection the caller must consume or cancel.
public final class TableClient: Sendable {
    private let baseURL: URL
    private let authorization: String
    private let session: URLSession
    private let wire: WireHook?

    public convenience init(
        hostURL: String,
        apiKey: String,
        allowInsecureHTTP: Bool = false,
        configuration: URLSessionConfiguration = .tableForeground
    ) throws {
        try self.init(
            hostURL: hostURL,
            apiKey: apiKey,
            allowInsecureHTTP: allowInsecureHTTP,
            configuration: configuration,
            wire: nil
        )
    }

    init(
        hostURL: String,
        apiKey: String,
        allowInsecureHTTP: Bool,
        configuration: URLSessionConfiguration,
        wire: WireHook?
    ) throws {
        baseURL = try validatedHostURL(hostURL, allowInsecureHTTP: allowInsecureHTTP)
        authorization = "Bearer \(apiKey)"
        session = URLSession(configuration: configuration)
        self.wire = wire
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    public func listFiles() async throws -> [TableFile] {
        let (data, http) = try await send(request("GET", "files"), operation: "list files")
        guard http.statusCode == 200 else { throw failure("list files", data, http) }
        return try TableJSON.decoder.decode([TableFile].self, from: data)
    }

    /// `POST /uploads`; returns the id used for the file's whole lifecycle.
    public func createUpload(name: String, size: Int64, sha256: String) async throws -> String {
        guard !name.isEmpty, name.utf8.count <= 255 else {
            throw TableError.invalidRequest("upload name must be 1-255 bytes, was \(name.utf8.count)")
        }
        guard size > 0 else {
            throw TableError.invalidRequest("upload size must be positive, was \(size)")
        }
        guard isSha256Hex(sha256) else {
            throw TableError.invalidRequest("sha256 must be 64 lowercase hex characters")
        }

        var request = request("POST", "uploads")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try TableJSON.encoder.encode(UploadCreate(name: name, size: size, sha256: sha256))

        let (data, http) = try await send(request, operation: "create upload session")
        guard http.statusCode == 201 else { throw failure("create upload session", data, http) }
        return try TableJSON.decoder.decode(UploadCreated.self, from: data).id
    }

    /// The server's committed offset, or nil if the session is unknown.
    public func uploadOffset(id: String) async throws -> Int64? {
        let (data, http) = try await send(request("HEAD", "uploads", id), operation: "read upload offset")
        switch http.statusCode {
        case 200:
            guard let offset = http.uploadOffset else {
                throw TableError.malformedResponse("HEAD /uploads/\(id) returned no Upload-Offset")
            }
            return offset
        case 404:
            return nil
        default:
            throw failure("read upload offset", data, http)
        }
    }

    /// `PATCH /uploads/{id}`: streams the file from `offset` to its end.
    ///
    /// `onProgress` reports the absolute offset handed to the socket — bytes in flight, not
    /// yet committed server-side.
    public func appendBytes(
        id: String,
        offset: Int64,
        from fileURL: URL,
        onProgress: (@Sendable (Int64) -> Void)? = nil
    ) async throws -> AppendResult {
        var request = request("PATCH", "uploads", id)
        request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")

        var absoluteProgress: (@Sendable (Int64) -> Void)?
        if let onProgress {
            absoluteProgress = { sent in onProgress(offset + sent) }
        }
        let outgoing = prepared(request)
        let delegate = UploadBodyDelegate(
            openBody: { try bodyStream(of: fileURL, from: offset) },
            onProgress: absoluteProgress
        )
        let task = session.uploadTask(withStreamedRequest: outgoing)
        task.delegate = delegate
        let (data, http) = try await delegate.awaitResponse { task.resume() }
        wire?.record(outgoing, http)

        switch http.statusCode {
        case 200:
            return .finalized(try TableJSON.decoder.decode(TableFile.self, from: data))
        case 204:
            return .incomplete(committedOffset: http.uploadOffset ?? offset)
        case 404:
            return .sessionGone
        case 409:
            return .offsetMismatch(committedOffset: try await committedOffset(id, fallback: http.uploadOffset))
        case 422:
            return .finalizeRejected(message: serverMessage(data))
        default:
            throw failure("append upload bytes", data, http)
        }
    }

    /// `DELETE /uploads/{id}`; false if the session was already gone.
    public func abortUpload(id: String) async throws -> Bool {
        let (data, http) = try await send(request("DELETE", "uploads", id), operation: "abort upload")
        switch http.statusCode {
        case 204: return true
        case 404: return false
        default: throw failure("abort upload", data, http)
        }
    }

    /// Opens `GET /files/{id}`, resuming from `rangeFrom` when it is non-zero.
    public func openDownload(id: String, rangeFrom: Int64 = 0) async throws -> DownloadStream {
        var request = request("GET", "files", id)
        if rangeFrom > 0 {
            request.setValue("bytes=\(rangeFrom)-", forHTTPHeaderField: "Range")
        }

        let outgoing = prepared(request)
        let channel = BodyChannel()
        let delegate = StreamingResponseDelegate(channel: channel)
        let task = session.dataTask(with: outgoing)
        task.delegate = delegate
        channel.onTerminate { task.cancel() }

        let http = try await delegate.awaitHeaders { task.resume() }
        wire?.record(outgoing, http)
        let stream = DownloadStream(
            response: http,
            body: AsyncThrowingStream(unfolding: { try await channel.next() }),
            release: { channel.terminate() }
        )

        switch http.statusCode {
        case 200, 206:
            return stream
        case 404, 410:
            stream.cancel()
            throw TableError.fileGone(id: id, statusCode: http.statusCode)
        case 416:
            stream.cancel()
            throw TableError.rangeNotSatisfiable(id: id)
        default:
            let body = await collectErrorBody(stream)
            stream.cancel()
            throw failure("download \(id)", body, http)
        }
    }

    /// `POST /files/{id}/ack` with the hash computed over the complete local copy.
    public func ack(id: String, sha256: String) async throws -> AckResult {
        guard isSha256Hex(sha256) else {
            throw TableError.invalidRequest("sha256 must be 64 lowercase hex characters")
        }
        var request = request("POST", "files", id, "ack")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try TableJSON.encoder.encode(AckRequest(sha256: sha256))

        let (data, http) = try await send(request, operation: "ack \(id)")
        switch http.statusCode {
        case 204: return .deleted
        case 404, 410: return .alreadyGone
        case 409: return .hashMismatch
        default: throw failure("ack \(id)", data, http)
        }
    }

    /// `DELETE /files/{id}`; false if the file was already gone.
    public func deleteFile(id: String) async throws -> Bool {
        let (data, http) = try await send(request("DELETE", "files", id), operation: "delete \(id)")
        switch http.statusCode {
        case 204: return true
        case 404, 410: return false
        default: throw failure("delete \(id)", data, http)
        }
    }

    private func committedOffset(_ id: String, fallback: Int64?) async throws -> Int64 {
        if let fallback { return fallback }
        guard let offset = try await uploadOffset(id: id) else {
            throw TableError.malformedResponse("upload session \(id) vanished during offset recovery")
        }
        return offset
    }

    private func request(_ method: String, _ segments: String...) -> URLRequest {
        var url = baseURL
        for segment in segments {
            url.append(path: segment)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        return request
    }

    /// Conformance rule 12: the Authorization header is attached here and nowhere else.
    private func prepared(_ request: URLRequest) -> URLRequest {
        var prepared = request
        prepared.setValue(authorization, forHTTPHeaderField: "Authorization")
        wire?.annotate(&prepared)
        return prepared
    }

    private func send(_ request: URLRequest, operation: String) async throws -> (Data, HTTPURLResponse) {
        let outgoing = prepared(request)
        let (data, response) = try await session.data(for: outgoing)
        guard let http = response as? HTTPURLResponse else {
            throw TableError.malformedResponse("\(operation) got a non-HTTP response")
        }
        wire?.record(outgoing, http)
        return (data, http)
    }

    private func failure(_ operation: String, _ data: Data, _ http: HTTPURLResponse) -> TableError {
        http.statusCode == 401
            ? .unauthorized(operation: operation)
            : .unexpectedStatus(operation: operation, statusCode: http.statusCode, serverMessage: serverMessage(data))
    }
}

/// Conformance rule 13: plain `http://` is refused unless the user explicitly overrode it.
func validatedHostURL(_ hostURL: String, allowInsecureHTTP: Bool) throws -> URL {
    var trimmed = hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
    while trimmed.hasSuffix("/") {
        trimmed.removeLast()
    }
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), url.host() != nil else {
        throw TableError.invalidHost(hostURL)
    }
    switch scheme {
    case "https":
        return url
    case "http":
        guard allowInsecureHTTP else { throw TableError.insecureHost(hostURL) }
        return url
    default:
        throw TableError.invalidHost(hostURL)
    }
}

/// DESIGN §2: a foreground upload resumes by seeking the source file, with no temp slice.
private func bodyStream(of fileURL: URL, from offset: Int64) throws -> InputStream {
    guard let stream = InputStream(url: fileURL) else {
        throw TableError.sourceNotReadable(fileURL)
    }
    guard offset == 0 || stream.setProperty(NSNumber(value: offset), forKey: .fileCurrentOffsetKey) else {
        throw TableError.sourceNotReadable(fileURL)
    }
    return stream
}

private func serverMessage(_ data: Data) -> String? {
    try? TableJSON.decoder.decode(ApiErrorBody.self, from: data).error
}

/// Error bodies are a line of JSON; a non-contract status still deserves its message.
private func collectErrorBody(_ stream: DownloadStream) async -> Data {
    var body = Data()
    do {
        for try await chunk in stream.body where body.count < 64 * 1024 {
            body.append(chunk)
        }
    } catch {
        stream.cancel()
    }
    return body
}

extension HTTPURLResponse {
    var uploadOffset: Int64? {
        value(forHTTPHeaderField: "Upload-Offset").flatMap(Int64.init)
    }
}
