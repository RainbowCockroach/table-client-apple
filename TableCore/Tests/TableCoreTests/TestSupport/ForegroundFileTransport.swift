import Foundation
@testable import TableCore

/// Stands in for ``BackgroundTransferSession`` in tests: the same two seams, an ordinary
/// `URLSession` underneath, and a note of what each request carried.
///
/// DESIGN §7 — the background session's scheduling is verified by hand once per release,
/// because it is the one part that cannot run in a test process; everything it calls into
/// (the request, the tail append, the response reading) is what this exercises.
final class ForegroundFileTransport: FileDownloadTransport, FileBodyTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [(range: String?, uploadOffset: String?)] = []

    var ranges: [String?] {
        lock.withLock { sent.map(\.range) }
    }

    var uploadOffsets: [String?] {
        lock.withLock { sent.map(\.uploadOffset) }
    }

    func download(
        _ request: URLRequest,
        plan: BackgroundDownloadPlan,
        taskID: String,
        onProgress: (@Sendable (Int64) -> Void)?
    ) async throws -> Int64 {
        record(request)
        let (delivered, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: delivered) }
        guard let http = response as? HTTPURLResponse else {
            throw TableError.malformedResponse("download \(taskID) got a non-HTTP response")
        }
        onProgress?(fileSize(delivered))
        return try applyDownloadedTail(delivered, DownloadHeaders(http), to: plan)
    }

    func send(
        _ request: URLRequest,
        bodyFile: URL,
        taskID: String,
        onProgress: (@Sendable (Int64) -> Void)?
    ) async throws -> (Data, HTTPURLResponse) {
        record(request)
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyFile)
        guard let http = response as? HTTPURLResponse else {
            throw TableError.malformedResponse("upload \(taskID) got a non-HTTP response")
        }
        onProgress?(fileSize(bodyFile))
        return (data, http)
    }

    private func record(_ request: URLRequest) {
        lock.withLock {
            sent.append(
                (
                    request.value(forHTTPHeaderField: "Range"),
                    request.value(forHTTPHeaderField: "Upload-Offset")
                )
            )
        }
    }
}
