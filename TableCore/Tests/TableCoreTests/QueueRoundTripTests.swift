import Foundation
import XCTest
@testable import TableCore

/// The whole stack against a local `table-server`: the persistent queue driving the real tasks,
/// end to end, with the download landing where a publisher put it.
final class QueueRoundTripTests: XCTestCase {
    private var scratch: Scratch!
    private var client: TableClient!
    private var queue: TransferQueue!
    private var published: URL!

    override func setUp() async throws {
        try XCTSkipUnless(TestServer.isConfigured, TestServer.missingConfigMessage)
        scratch = try Scratch(name: name.filter { $0.isLetter || $0.isNumber })
        let candidate = try TestServer.client()
        do {
            _ = try await candidate.listFiles()
        } catch {
            throw XCTSkip(TestServer.unreachableMessage(error))
        }
        client = candidate
        published = scratch.root.appending(path: "Downloads")
        queue = try makeQueue(databaseAt: scratch.file("queue/transfers.sqlite"))
        try await sweepServer()
    }

    override func tearDown() async throws {
        if client != nil {
            try await sweepServer()
        }
        scratch?.remove()
    }

    private func makeQueue(databaseAt databaseURL: URL) throws -> TransferQueue {
        TransferQueue(
            store: try SQLiteTransferStore(fileURL: databaseURL),
            tasks: TransferTasks(
                downloads: DownloadTask(
                    temporaryDirectory: temporaryDirectory,
                    publisher: DirectoryDownloadPublisher(directory: published)
                ),
                uploads: UploadTask()
            ),
            client: { try TestServer.client() }
        )
    }

    private var temporaryDirectory: URL {
        scratch.root.appending(path: "temp")
    }

    /// Scenarios are independent, exactly as `conformance/run.sh` keeps them. An `uploading`
    /// entry needs its session aborted — `DELETE /files/{id}` answers 404 for those.
    private func sweepServer() async throws {
        for file in try await client.listFiles() {
            switch file.state {
            case .uploading: _ = try await client.abortUpload(id: file.id)
            case .available: _ = try await client.deleteFile(id: file.id)
            }
        }
    }

    func test_aFileQueuedForUploadIsHashedDeclaredAndFinalized() async throws {
        let source = try scratch.randomFile("queued-upload.bin", bytes: 512 * 1024)
        let sourceHash = try sha256Hex(fileAt: source)

        try await queue.upload(try UploadSource(fileURL: source))
        await queue.drain()

        let transfers = try await queue.transfers()
        let record = try XCTUnwrap(transfers.first)
        XCTAssertEqual(record.state, .done)
        XCTAssertEqual(record.bytesDone, record.size)
        XCTAssertNil(record.failure)

        let listed = try await client.listFiles()
        let uploaded = try XCTUnwrap(listed.first { $0.id == record.remoteID })
        XCTAssertEqual(uploaded.state, .available)
        XCTAssertEqual(uploaded.sha256, sourceHash)
        XCTAssertEqual(uploaded.name, "queued-upload.bin")
    }

    func test_aQueuedDownloadEndsUpPublishedVerifiedAndGoneFromTheServer() async throws {
        let source = try scratch.randomFile("queued-download.bin", bytes: 512 * 1024)
        let sourceBytes = try Data(contentsOf: source)
        try await queue.upload(try UploadSource(fileURL: source))
        await queue.drain()
        let listed = try await client.listFiles()
        let uploaded = try XCTUnwrap(listed.first)

        try await queue.download(uploaded)
        await queue.drain()

        let transfers = try await queue.transfers()
        let record = try XCTUnwrap(transfers.first { $0.direction == .download })
        XCTAssertEqual(record.state, .done)
        XCTAssertEqual(record.publishedName, "queued-download.bin")
        let landed = try XCTUnwrap(record.publishedPath)
        XCTAssertEqual(try Data(contentsOf: URL(filePath: landed)), sourceBytes)

        let remaining = try await client.listFiles()
        XCTAssertTrue(remaining.isEmpty, "rule 8: a verified download acks, and the ack deletes")
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: temporaryDirectory.path(percentEncoded: false)
        )
        XCTAssertEqual(leftovers, [], "rule 11: the temp file goes once the copy is published")
    }

    /// Rule 14 with a real database: the record a killed process left behind resumes from the
    /// server's committed offset instead of starting over.
    func test_aQueueReopenedAfterProcessDeathResumesTheUploadItLeftRunning() async throws {
        let source = try scratch.randomFile("interrupted.bin", bytes: 512 * 1024)
        let sourceHash = try sha256Hex(fileAt: source)
        let uploadSource = try UploadSource(fileURL: source)
        let half = uploadSource.size / 2

        // What a process killed mid-upload leaves behind: a live session with half its bytes
        // committed, and a queue row that still names it.
        let sessionID = try await client.createUpload(
            name: uploadSource.name,
            size: uploadSource.size,
            sha256: sourceHash
        )
        let partial = try await client.appendBytes(
            id: sessionID,
            offset: 0,
            from: try scratch.slice(of: source, upTo: half, named: "interrupted.firsthalf")
        )
        XCTAssertEqual(partial, .incomplete(committedOffset: half))

        let databaseURL = scratch.file("resumed/transfers.sqlite")
        try await SQLiteTransferStore(fileURL: databaseURL).put(
            TransferRecord(
                id: "t1",
                direction: .upload,
                name: uploadSource.name,
                size: uploadSource.size,
                state: .running,
                remoteID: sessionID,
                sha256: sourceHash,
                sourcePath: source.path(percentEncoded: false),
                bytesDone: half
            )
        )

        let reopened = try makeQueue(databaseAt: databaseURL)
        try await reopened.resumeUnfinished()
        await reopened.drain()

        let transfers = try await reopened.transfers()
        let record = try XCTUnwrap(transfers.first)
        XCTAssertEqual(record.state, .done)
        XCTAssertEqual(record.remoteID, sessionID, "rule 2: the same session, not a new one")
        let listed = try await client.listFiles()
        let finalized = try XCTUnwrap(listed.first { $0.id == sessionID })
        XCTAssertEqual(finalized.state, .available)
        XCTAssertEqual(finalized.sha256, sourceHash)
    }

    /// A source the app can no longer read never fixes itself, so the queue must not spend its
    /// retry allowance on it.
    func test_anUploadWhoseSourceIsGoneFailsPermanently() async throws {
        let databaseURL = scratch.file("missing/transfers.sqlite")
        try await SQLiteTransferStore(fileURL: databaseURL).put(
            TransferRecord(
                id: "t1",
                direction: .upload,
                name: "vanished.bin",
                size: 1024,
                sourcePath: scratch.file("vanished.bin").path(percentEncoded: false)
            )
        )

        let queue = try makeQueue(databaseAt: databaseURL)
        try await queue.resumeUnfinished()
        await queue.drain()

        let transfers = try await queue.transfers()
        let failed = try XCTUnwrap(transfers.first)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.failure?.retryable, false)
        XCTAssertEqual(failed.attempts, 1, "a permanent failure is not retried")
    }
}
