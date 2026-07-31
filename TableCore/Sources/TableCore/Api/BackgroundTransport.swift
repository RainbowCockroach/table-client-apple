import Foundation

/// Where a background download lands, and what the server has to declare about it (rule 6).
///
/// It travels with the task itself, because the process that started the task may be gone by
/// the time the bytes arrive: whoever receives them has everything needed to finish the job.
public struct BackgroundDownloadPlan: Codable, Sendable, Hashable {
    public let fileID: String
    public let partialFile: URL
    public let totalSize: Int64
    public let sha256: String

    public init(_ target: DownloadTarget, partialFile: URL) {
        fileID = target.id
        self.partialFile = partialFile
        totalSize = target.size
        sha256 = target.sha256
    }

    var target: DownloadTarget {
        DownloadTarget(id: fileID, name: partialFile.lastPathComponent, size: totalSize, sha256: sha256)
    }
}

/// Runs one request whose body is a whole file, out of process — on iOS the background
/// `URLSession`, which is the only way a transfer outlives app suspension (DESIGN §2).
public protocol FileBodyTransport: Sendable {
    /// `taskID` identifies the transfer across process death: a relaunched app asks for the
    /// same id and gets the running task's outcome instead of starting a second one.
    func send(
        _ request: URLRequest,
        bodyFile: URL,
        taskID: String,
        onProgress: (@Sendable (Int64) -> Void)?
    ) async throws -> (Data, HTTPURLResponse)
}

/// Runs one download out of process, into the partial file its plan names.
public protocol FileDownloadTransport: Sendable {
    /// Returns the bytes on disk once the task has finished. The transport appends what the
    /// task delivers even when nobody is waiting, so the tail survives a suspended app.
    func download(
        _ request: URLRequest,
        plan: BackgroundDownloadPlan,
        taskID: String,
        onProgress: (@Sendable (Int64) -> Void)?
    ) async throws -> Int64
}

/// Appends a delivered background download to its partial file at the offset the response
/// declares, and returns the bytes on disk afterwards.
///
/// The counterpart of the streaming path's incremental write, minus the hashing: a background
/// task hands over a finished file, so rule 6's hash is computed over the partial file later.
/// A process that dies mid-append leaves a shorter prefix, which the next `Range` resumes from.
func applyDownloadedTail(
    _ delivered: URL,
    _ headers: DownloadHeaders,
    to plan: BackgroundDownloadPlan
) throws -> Int64 {
    guard headers.statusCode == 200 || headers.statusCode == 206 else {
        throw downloadFailure(headers, id: plan.fileID, body: errorBody(of: delivered))
    }
    try checkDeclarations(headers, match: plan.target)

    let partialFile = plan.partialFile
    let onDisk = fileSize(partialFile)
    guard headers.rangeStart <= onDisk else {
        throw TableError.malformedResponse(
            "download \(plan.fileID): server answered from byte \(headers.rangeStart), "
                + "past the \(onDisk) on disk"
        )
    }
    try FileManager.default.createDirectory(
        at: partialFile.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    // A response from byte 0 supersedes whatever was on disk, so the delivered file can become
    // the partial file outright — worth a special case when it is several gigabytes.
    if headers.rangeStart == 0 {
        try? FileManager.default.removeItem(at: partialFile)
        try FileManager.default.moveItem(at: delivered, to: partialFile)
        try fsync(partialFile)
        return fileSize(partialFile)
    }
    if !FileManager.default.fileExists(atPath: partialFile.path(percentEncoded: false)) {
        FileManager.default.createFile(atPath: partialFile.path(percentEncoded: false), contents: nil)
    }

    let source = try FileHandle(forReadingFrom: delivered)
    defer { try? source.close() }
    let sink = try FileHandle(forWritingTo: partialFile)
    defer { try? sink.close() }
    // A server that ignored the Range answers from byte 0, so whatever we had is superseded
    // rather than appended to.
    try sink.truncate(atOffset: UInt64(headers.rangeStart))
    try sink.seek(toOffset: UInt64(headers.rangeStart))
    while let chunk = try source.read(upToCount: transferBufferBytes), !chunk.isEmpty {
        try sink.write(contentsOf: chunk)
    }
    // Rule 7: durable before anything acks it.
    try sink.synchronize()
    return fileSize(partialFile)
}

/// Rule 7: durable before anything acks it. A moved file carries no promise that its bytes
/// reached the disk, so it is flushed like a written one.
private func fsync(_ fileURL: URL) throws {
    let handle = try FileHandle(forWritingTo: fileURL)
    defer { try? handle.close() }
    try handle.synchronize()
}

/// A failed download's body arrives as a file like any other; the message in it is one line.
private func errorBody(of delivered: URL) -> Data {
    guard let handle = try? FileHandle(forReadingFrom: delivered) else { return Data() }
    defer { try? handle.close() }
    return (try? handle.read(upToCount: 64 * 1024)) ?? Data()
}
