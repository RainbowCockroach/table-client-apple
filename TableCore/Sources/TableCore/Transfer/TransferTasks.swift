import Foundation

/// How a running attempt writes back into the queue.
public protocol TransferReport: Sendable {
    /// Absolute bytes moved so far. Called from the transfer's own thread, so it must not block.
    func bytes(_ done: Int64)

    /// The upload session this attempt will use, or nil when it is lost (rules 3, 14).
    /// Durable before the first byte goes out, so a resumed attempt keeps the same session.
    func session(_ session: UploadSession?) async
}

/// One attempt at moving one file, in whichever direction the record names.
public protocol TransferAttempt: Sendable {
    func run(
        _ client: TableClient,
        _ record: TransferRecord,
        report: any TransferReport
    ) async -> TransferResult

    /// Drops what a dismissed transfer leaves on disk.
    func discard(_ record: TransferRecord)

    /// Removes temp files no record needs any more (rule 14: records outlive processes).
    func sweep(live: [TransferRecord])
}

extension TransferAttempt {
    public func discard(_ record: TransferRecord) {}
    public func sweep(live: [TransferRecord]) {}
}

/// Sends a record to the task for its direction; the two halves share nothing else.
public struct TransferTasks: TransferAttempt {
    private let downloads: DownloadTask
    private let uploads: UploadTask

    public init(downloads: DownloadTask, uploads: UploadTask) {
        self.downloads = downloads
        self.uploads = uploads
    }

    public func run(
        _ client: TableClient,
        _ record: TransferRecord,
        report: any TransferReport
    ) async -> TransferResult {
        switch record.direction {
        case .download:
            guard let target = record.downloadTarget else {
                return permanent("queued without a file id or hash")
            }
            return await downloads.run(client, target, report: report)
        case .upload:
            return await uploads.run(client, record, report: report)
        }
    }

    /// Drops what a dismissed transfer leaves on disk.
    public func discard(_ record: TransferRecord) {
        downloads.discard(record)
        uploads.discard(record)
    }

    /// Removes temp files no record needs any more (rule 14: records outlive processes).
    public func sweep(live: [TransferRecord]) {
        downloads.sweep(live: live)
        uploads.sweep(live: live)
    }
}

/// The whole of conformance rule 11 for one file: temp file → verify → fsync → ack → publish.
///
/// One attempt, like ``Downloader``: a retry re-enters here and picks up from whatever the temp
/// file holds — partial bytes resume via `Range`, and a complete-but-unpublished copy skips
/// straight back to the ack (rule 9 makes the second ack a no-op).
public struct DownloadTask: Sendable {
    private let temporaryDirectory: URL
    private let publisher: any DownloadPublisher
    private let fetcher: any DownloadFetcher

    public init(
        temporaryDirectory: URL,
        publisher: any DownloadPublisher,
        fetcher: any DownloadFetcher = StreamingDownloadFetcher()
    ) {
        self.temporaryDirectory = temporaryDirectory
        self.publisher = publisher
        self.fetcher = fetcher
    }

    public func run(
        _ client: TableClient,
        _ target: DownloadTarget,
        report: any TransferReport
    ) async -> TransferResult {
        do {
            let tempFile = try temporaryFile(for: target.id)
            let downloader = Downloader(client, fetcher: fetcher)
            let outcome = try await downloader.download(target, to: tempFile) { report.bytes($0) }
            switch outcome {
            case .verified(let tempFile, _, _):
                return try publish(tempFile, as: target.name)
            case .incomplete(let bytesOnDisk):
                return retryable("stopped after \(bytesOnDisk) of \(target.size) bytes")
            case .corrupt(let reason):
                return retryable("\(reason) — downloading again")
            case .gone:
                return permanent("no longer on the server")
            }
        } catch {
            return .failed(TransferFailure(message: describe(error), retryable: RetryPolicy.isRetryable(error)))
        }
    }

    /// Rule 11: the temp file outlives the ack and is dropped only once the copy is published.
    private func publish(_ tempFile: URL, as name: String) throws -> TransferResult {
        let published = try publisher.publish(tempFile, displayName: name)
        try? FileManager.default.removeItem(at: tempFile)
        return .done(published: published)
    }

    func discard(_ record: TransferRecord) {
        guard record.direction == .download, let remoteID = record.remoteID else { return }
        try? FileManager.default.removeItem(at: temporaryPath(for: remoteID))
    }

    func sweep(live: [TransferRecord]) {
        let needed = Set(live.compactMap { $0.direction == .download ? $0.remoteID : nil })
        let existing = try? FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        )
        for file in existing ?? [] where !needed.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func temporaryFile(for fileID: String) throws -> URL {
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        return temporaryPath(for: fileID)
    }

    /// Named by file id so a retry after process death finds the same partial file (rule 14).
    private func temporaryPath(for fileID: String) -> URL {
        temporaryDirectory.appending(path: "\(fileID).part")
    }
}

/// The upload half of the conformance checklist for one file: hash and declare, then push the
/// session to completion.
///
/// One attempt. A retry re-enters here with the session id the previous attempt persisted and
/// resumes from the server's committed offset (rule 2); rule 3 and the session-gone case drop
/// that id so the next attempt declares the file afresh.
public struct UploadTask: Sendable {
    private let sender: any UploadSender
    private let stagedSources: URL?

    /// `stagedSources` is the directory this task owns copies in: on iOS an upload reads from
    /// a copy in the container (DESIGN §4), and nothing but the queue knows when it can go.
    public init(sender: any UploadSender = StreamingUploadSender(), stagedSources: URL? = nil) {
        self.sender = sender
        self.stagedSources = stagedSources
    }

    public func run(
        _ client: TableClient,
        _ record: TransferRecord,
        report: any TransferReport
    ) async -> TransferResult {
        guard let sourcePath = record.sourcePath else {
            return permanent("queued without a source file")
        }
        let uploader = Uploader(client, sender: sender)
        do {
            let source = try UploadSource(fileURL: URL(filePath: sourcePath), name: record.name)
            let session: UploadSession
            if let known = record.uploadSession {
                session = known
            } else {
                session = try await uploader.createSession(for: source)
                await report.session(session)
            }
            switch try await uploader.upload(session, from: source, onProgress: { report.bytes($0) }) {
            case .finalized:
                discard(record)
                return .done(published: nil)
            case .interrupted(let committedOffset):
                return retryable("stopped at \(committedOffset) of \(session.size) bytes")
            case .sessionGone:
                return await startOver(report, "the upload session expired")
            // Rule 3: the server has already discarded the session, so only a new one can work.
            case .rejected(let message):
                return await startOver(report, "the server rejected the upload (\(message ?? "no reason given"))")
            }
        } catch TableError.sourceNotReadable(let url) {
            // DESIGN §6: a file the app can no longer read does not come back on its own.
            return permanent("cannot read \(url.lastPathComponent) — pick or share \(record.name) again")
        } catch {
            return .failed(TransferFailure(message: describe(error), retryable: RetryPolicy.isRetryable(error)))
        }
    }

    private func startOver(_ report: any TransferReport, _ reason: String) async -> TransferResult {
        await report.session(nil)
        return retryable("\(reason) — sending it again from the start")
    }

    func discard(_ record: TransferRecord) {
        guard record.direction == .upload, let staged = staged(record.sourcePath) else { return }
        try? FileManager.default.removeItem(at: staged)
    }

    func sweep(live: [TransferRecord]) {
        guard let stagedSources else { return }
        let needed = Set(live.compactMap { staged($0.sourcePath)?.lastPathComponent })
        let existing = try? FileManager.default.contentsOfDirectory(
            at: stagedSources,
            includingPropertiesForKeys: nil
        )
        for file in existing ?? [] where !needed.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// A source this task owns — one it copied into `stagedSources` — rather than a file that
    /// belongs to the user and must survive the transfer.
    private func staged(_ sourcePath: String?) -> URL? {
        guard let stagedSources, let sourcePath else { return nil }
        let source = URL(filePath: sourcePath)
        guard source.deletingLastPathComponent().standardizedFileURL == stagedSources.standardizedFileURL else {
            return nil
        }
        return source
    }
}
