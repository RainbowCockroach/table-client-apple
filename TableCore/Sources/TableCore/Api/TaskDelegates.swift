import Foundation

/// Feeds a response body into a ``BodyChannel`` and hands the caller its headers as soon as
/// they arrive, without waiting for the bytes.
///
/// `@unchecked Sendable`: `headers` is guarded by `lock`, and everything else is touched only
/// on the session's (serial) delegate queue.
final class StreamingResponseDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let channel: BodyChannel
    private let lock = NSLock()
    private var headers: CheckedContinuation<HTTPURLResponse, Error>?

    init(channel: BodyChannel) {
        self.channel = channel
    }

    func awaitHeaders(startingWith start: @Sendable () -> Void) async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            headers = continuation
            lock.unlock()
            start()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            deliverHeaders(.failure(TableError.malformedResponse("response was not HTTP")))
            return
        }
        completionHandler(.allow)
        deliverHeaders(.success(http))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        channel.send(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            deliverHeaders(.failure(error))
            channel.finish(.failure(error))
        } else {
            channel.finish(.success(()))
        }
    }

    private func deliverHeaders(_ result: Result<HTTPURLResponse, Error>) {
        lock.lock()
        let continuation = headers
        headers = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

/// Streams a `PATCH` body from a file and collects the response, which is small enough to
/// hold in memory whatever the outcome.
///
/// `@unchecked Sendable`: `completion` is guarded by `lock`, and everything else is touched
/// only on the session's (serial) delegate queue.
final class UploadBodyDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let openBody: @Sendable () throws -> InputStream
    private let onProgress: (@Sendable (Int64) -> Void)?
    private let lock = NSLock()
    private var completion: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var bodyProvided = false
    private var bodyFailure: Error?
    private var received = Data()
    private var response: HTTPURLResponse?

    init(
        openBody: @escaping @Sendable () throws -> InputStream,
        onProgress: (@Sendable (Int64) -> Void)?
    ) {
        self.openBody = openBody
        self.onProgress = onProgress
    }

    func awaitResponse(startingWith start: @Sendable () -> Void) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            completion = continuation
            lock.unlock()
            start()
        }
    }

    /// Conformance rule 2: the body is one-shot, so a dropped `PATCH` cannot be replayed from a
    /// stale offset — the next attempt has to ask `HEAD` where the server got to.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping (InputStream?) -> Void
    ) {
        guard !bodyProvided else {
            completionHandler(nil)
            return
        }
        bodyProvided = true
        do {
            completionHandler(try openBody())
        } catch {
            bodyFailure = error
            completionHandler(nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onProgress?(totalBytesSent)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        self.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome: Result<(Data, HTTPURLResponse), Error>
        switch (bodyFailure ?? error, response) {
        case (let failure?, _):
            outcome = .failure(failure)
        case (nil, let http?):
            outcome = .success((received, http))
        case (nil, nil):
            outcome = .failure(TableError.malformedResponse("upload finished without an HTTP response"))
        }
        lock.lock()
        let continuation = completion
        completion = nil
        lock.unlock()
        continuation?.resume(with: outcome)
    }
}
