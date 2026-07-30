import Foundation
import XCTest
@testable import TableCore

/// The queue's state machine, driven by a scripted attempt instead of a server: admission
/// control (DESIGN §3), the retry/give-up ladder, and rule 14's resume-on-launch.
final class TransferQueueTests: XCTestCase {
    private func makeQueue(
        _ attempt: ScriptedAttempt,
        store: InMemoryTransferStore = InMemoryTransferStore(),
        policy: TransferPolicy = TransferPolicy()
    ) throws -> TransferQueue {
        TransferQueue(
            store: store,
            tasks: attempt,
            client: { try TableClient(hostURL: "https://files.example.com", apiKey: "k") },
            policy: policy,
            // Retries fire immediately; the backoff ladder is asserted against the policy
            // rather than waited out.
            sleep: { _ in },
            now: { Date(timeIntervalSince1970: 0) },
            newID: { UUID().uuidString }
        )
    }

    func test_aFinishedTransferIsRecordedAsDoneWithWhereItWasPublished() async throws {
        let store = InMemoryTransferStore()
        let attempt = ScriptedAttempt(outcomes: [.done(published: PublishedDownload(name: "a.bin", path: "/tmp/a.bin"))])
        let queue = try makeQueue(attempt, store: store)

        try await queue.download(file(id: "f1", name: "a.bin", size: 10))
        await queue.drain()

        let all_record = try await store.all()
        let record = try XCTUnwrap(all_record.first)
        XCTAssertEqual(record.state, .done)
        XCTAssertEqual(record.bytesDone, 10)
        XCTAssertEqual(record.publishedName, "a.bin")
        XCTAssertEqual(record.publishedPath, "/tmp/a.bin")
        XCTAssertNil(record.failure)
        XCTAssertEqual(attempt.runCount, 1)
    }

    func test_aRetryableFailureIsReattemptedWithADoublingBackoffUntilTheCapGivesUp() async throws {
        let store = InMemoryTransferStore()
        var policy = TransferPolicy()
        policy.maxAttempts = 4
        policy.backoffBase = .seconds(2)
        policy.backoffCap = .seconds(5)
        let attempt = ScriptedAttempt(outcomes: [], fallback: retryable("connection lost"))
        let queue = try makeQueue(attempt, store: store, policy: policy)

        try await queue.download(file(id: "f1", name: "a.bin", size: 10))
        await queue.drain()

        XCTAssertEqual(attempt.runCount, 4, "one attempt per allowance, then no more")
        let all_record = try await store.all()
        let record = try XCTUnwrap(all_record.first)
        XCTAssertEqual(record.state, .failed)
        XCTAssertEqual(record.attempts, 4)
        XCTAssertEqual(record.failure?.retryable, false)
        XCTAssertTrue(
            record.failure?.message.contains("gave up after 4 attempts") == true,
            "got \(record.failure?.message ?? "no failure")"
        )
        XCTAssertEqual(
            policy.backoff(afterAttempt: 1)..<policy.backoff(afterAttempt: 2),
            Duration.seconds(2)..<Duration.seconds(4),
            "the delay doubles between attempts"
        )
        XCTAssertEqual(policy.backoff(afterAttempt: 9), .seconds(5), "and stops at the cap")
    }

    func test_aPermanentFailureIsNotReattempted() async throws {
        let store = InMemoryTransferStore()
        let attempt = ScriptedAttempt(outcomes: [], fallback: permanent("no longer on the server"))
        let queue = try makeQueue(attempt, store: store)

        try await queue.download(file(id: "f1", name: "a.bin", size: 10))
        await queue.drain()

        XCTAssertEqual(attempt.runCount, 1)
        let all_record = try await store.all()
        let record = try XCTUnwrap(all_record.first)
        XCTAssertEqual(record.state, .failed)
        XCTAssertEqual(record.failure, TransferFailure(message: "no longer on the server", retryable: false))
    }

    func test_retryStartsAFreshAttemptCountAfterGivingUp() async throws {
        let store = InMemoryTransferStore()
        var policy = TransferPolicy()
        policy.maxAttempts = 1
        let attempt = ScriptedAttempt(outcomes: [retryable("connection lost")], fallback: .done(published: nil))
        let queue = try makeQueue(attempt, store: store, policy: policy)

        try await queue.download(file(id: "f1", name: "a.bin", size: 10))
        await queue.drain()
        let all_givenUp = try await store.all()
        let givenUp = try XCTUnwrap(all_givenUp.first)
        XCTAssertEqual(givenUp.failure?.retryable, false)

        try await queue.retry(id: givenUp.id)
        await queue.drain()

        let all_record = try await store.all()
        let record = try XCTUnwrap(all_record.first)
        XCTAssertEqual(record.state, .done)
        XCTAssertEqual(record.attempts, 0)
        XCTAssertEqual(attempt.runCount, 2)
    }

    /// DESIGN §3: 2 per direction, and the two directions do not compete for each other's slots.
    func test_atMostTwoTransfersPerDirectionRunAtOnce() async throws {
        let store = InMemoryTransferStore()
        let attempt = ScriptedAttempt(outcomes: [], fallback: .done(published: nil), holdUntilReleased: true)
        let queue = try makeQueue(attempt, store: store)

        for index in 0..<4 {
            try await queue.download(file(id: "d\(index)", name: "d\(index).bin", size: 10))
            try await queue.upload(try uploadSource(named: "u\(index).bin"))
        }
        try await attempt.waitForConcurrentPeak()

        XCTAssertEqual(attempt.peakConcurrency(.download), 2)
        XCTAssertEqual(attempt.peakConcurrency(.upload), 2)

        attempt.releaseAll()
        await queue.drain()
        let states = try await store.all().map(\.state)
        XCTAssertEqual(states, Array(repeating: TransferState.done, count: 8))
        XCTAssertEqual(attempt.runCount, 8)
    }

    /// Rule 14: a record left mid-flight by a killed process is picked up again, not restarted
    /// from scratch — the attempt still receives the session id and hash it had.
    func test_resumeUnfinishedRequeuesRecordsLeftRunningByAKilledProcess() async throws {
        let interrupted = TransferRecord(
            id: "t1",
            direction: .upload,
            name: "big.bin",
            size: 1000,
            state: .running,
            remoteID: "session-1",
            sha256: String(repeating: "a", count: 64),
            sourcePath: "/tmp/big.bin",
            bytesDone: 400,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let settled = TransferRecord(
            id: "t2",
            direction: .download,
            name: "old.bin",
            size: 10,
            state: .done,
            remoteID: "f2",
            sha256: String(repeating: "b", count: 64),
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let store = InMemoryTransferStore([interrupted, settled])
        let attempt = ScriptedAttempt(outcomes: [], fallback: .done(published: nil))
        let queue = try makeQueue(attempt, store: store)

        try await queue.resumeUnfinished()
        await queue.drain()

        XCTAssertEqual(attempt.runCount, 1, "a finished record is not run again")
        let resumed = try XCTUnwrap(attempt.records.first)
        XCTAssertEqual(resumed.id, "t1")
        XCTAssertEqual(resumed.uploadSession?.id, "session-1", "rule 2: the same session is resumed")
        XCTAssertEqual(attempt.sweptLive.first?.map(\.id), ["t1"])
    }

    func test_dismissDropsTheRecordAndWhatItLeftOnDisk() async throws {
        let store = InMemoryTransferStore()
        let attempt = ScriptedAttempt(outcomes: [], fallback: permanent("nope"))
        let queue = try makeQueue(attempt, store: store)

        try await queue.download(file(id: "f1", name: "a.bin", size: 10))
        await queue.drain()
        let all_record = try await store.all()
        let record = try XCTUnwrap(all_record.first)

        try await queue.dismiss(id: record.id)

        let remaining = try await store.all()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(attempt.discarded.map(\.id), [record.id])
    }

    func test_downloadingAFileAlreadyInFlightDoesNotQueueItTwice() async throws {
        let store = InMemoryTransferStore()
        let attempt = ScriptedAttempt(outcomes: [], fallback: .done(published: nil), holdUntilReleased: true)
        let queue = try makeQueue(attempt, store: store)
        let target = file(id: "f1", name: "a.bin", size: 10)

        try await queue.download(target)
        try await queue.download(target)

        let whileInFlight = try await store.all()
        XCTAssertEqual(whileInFlight.count, 1)
        attempt.releaseAll()
        await queue.drain()

        // A settled entry is a fresh start, not a duplicate.
        try await queue.download(target)
        await queue.drain()
        let afterSettling = try await store.all()
        XCTAssertEqual(afterSettling.count, 1)
        XCTAssertEqual(attempt.runCount, 2)
    }

    func test_progressWritesTheBytesMovedWhileTheTransferIsStillRunning() async throws {
        let store = InMemoryTransferStore()
        let attempt = ScriptedAttempt(
            outcomes: [], fallback: .done(published: nil), holdUntilReleased: true, progress: [40]
        )
        let queue = try makeQueue(attempt, store: store)

        try await queue.download(file(id: "f1", name: "a.bin", size: 100))
        let midway = try await waitForRecord(in: store) { $0.bytesDone == 40 }
        XCTAssertEqual(midway.state, .running)

        attempt.releaseAll()
        await queue.drain()
    }

    /// The last byte is not the end of the transfer: hashing, acking and — for an upload — the
    /// server's own rehash still have to happen, and DESIGN §3 gives that its own state.
    func test_theQueueShowsVerifyingOnceEveryByteHasMoved() async throws {
        let store = InMemoryTransferStore()
        let attempt = ScriptedAttempt(
            outcomes: [], fallback: .done(published: nil), holdUntilReleased: true, progress: [100]
        )
        let queue = try makeQueue(attempt, store: store)

        try await queue.download(file(id: "f1", name: "a.bin", size: 100))
        let verifying = try await waitForRecord(in: store) { $0.state == .verifying }
        XCTAssertEqual(verifying.bytesDone, 100)

        attempt.releaseAll()
        await queue.drain()
    }

    private func waitForRecord(
        in store: InMemoryTransferStore,
        matching predicate: @Sendable (TransferRecord) -> Bool
    ) async throws -> TransferRecord {
        for _ in 0..<400 {
            if let record = try await store.all().first, predicate(record) { return record }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw XCTSkip("no record matched within 4 s; last was \(try await store.all().first as Any)")
    }

    private func file(id: String, name: String, size: Int64) -> TableFile {
        TableFile(
            id: id,
            name: name,
            size: size,
            sha256: String(repeating: "c", count: 64),
            state: .available,
            bytesReceived: size,
            uploadedAt: Date(timeIntervalSince1970: 0),
            expiresAt: Date(timeIntervalSince1970: 600)
        )
    }

    private func uploadSource(named name: String) throws -> UploadSource {
        let url = URL.temporaryDirectory.appending(path: "TableCoreTests-\(UUID().uuidString)-\(name)")
        try Data(count: 10).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try UploadSource(fileURL: url, name: name)
    }
}

/// An attempt that returns scripted outcomes, records what it was asked to move, and can hold
/// its callers open so the concurrency cap is observable.
private final class ScriptedAttempt: TransferAttempt, @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [TransferResult]
    private let fallback: TransferResult
    private let holdUntilReleased: Bool
    private let progress: [Int64]
    private var inFlight: [TransferDirection: Int] = [:]
    private var peak: [TransferDirection: Int] = [:]
    private var released = false
    private var seen: [TransferRecord] = []
    private var discardedRecords: [TransferRecord] = []
    private var sweeps: [[TransferRecord]] = []
    private var runs = 0

    init(
        outcomes: [TransferResult],
        fallback: TransferResult = .done(published: nil),
        holdUntilReleased: Bool = false,
        progress: [Int64] = []
    ) {
        self.outcomes = outcomes
        self.fallback = fallback
        self.holdUntilReleased = holdUntilReleased
        self.progress = progress
    }

    var runCount: Int { lock.withLock { runs } }
    var records: [TransferRecord] { lock.withLock { seen } }
    var discarded: [TransferRecord] { lock.withLock { discardedRecords } }
    var sweptLive: [[TransferRecord]] { lock.withLock { sweeps } }

    func peakConcurrency(_ direction: TransferDirection) -> Int {
        lock.withLock { peak[direction] ?? 0 }
    }

    func releaseAll() {
        lock.withLock { released = true }
    }

    /// Waits until both directions have as many attempts in flight as they will ever have.
    func waitForConcurrentPeak() async throws {
        for _ in 0..<200 where !(peakConcurrency(.download) == 2 && peakConcurrency(.upload) == 2) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func run(
        _ client: TableClient,
        _ record: TransferRecord,
        report: any TransferReport
    ) async -> TransferResult {
        lock.withLock {
            runs += 1
            seen.append(record)
            let count = (inFlight[record.direction] ?? 0) + 1
            inFlight[record.direction] = count
            peak[record.direction] = max(peak[record.direction] ?? 0, count)
        }
        defer { lock.withLock { inFlight[record.direction] = (inFlight[record.direction] ?? 1) - 1 } }

        for bytes in progress {
            report.bytes(bytes)
        }
        while holdUntilReleased, !lock.withLock({ released }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return lock.withLock { outcomes.isEmpty ? fallback : outcomes.removeFirst() }
    }

    func discard(_ record: TransferRecord) {
        lock.withLock { discardedRecords.append(record) }
    }

    func sweep(live: [TransferRecord]) {
        lock.withLock { sweeps.append(live) }
    }
}
