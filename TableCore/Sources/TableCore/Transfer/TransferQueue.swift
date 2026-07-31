import Foundation

/// DESIGN §3: 2 transfers per direction, exponential backoff on retryable failures.
public struct TransferPolicy: Sendable {
    public var maxConcurrentPerDirection = 2

    /// How many times a retryable failure is worth re-running before the queue calls it dead;
    /// the user's Retry starts a fresh count.
    public var maxAttempts = 8

    public var backoffBase: Duration = .seconds(2)

    /// The TTL is ten minutes (root DESIGN §2), so waiting longer than this between attempts
    /// would mean giving up on a file that is still there.
    public var backoffCap: Duration = .seconds(60)

    public init() {}

    func backoff(afterAttempt attempt: Int) -> Duration {
        let doublings = min(max(attempt - 1, 0), 20)
        return min(backoffBase * (1 << doublings), backoffCap)
    }
}

/// The transfer queue: persistent records, admission control, and retry.
///
/// Every change lands in the ``TransferStore`` before anything runs, so an attempt started
/// here always finds its record (conformance rule 14).
public actor TransferQueue {
    private let store: any TransferStore
    private let tasks: any TransferAttempt
    private let clientFactory: @Sendable () async throws -> TableClient
    private let policy: TransferPolicy
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date
    private let newID: @Sendable () -> String

    private struct RunningTransfer {
        let direction: TransferDirection
        let task: Task<Void, Never>
    }

    private var running: [String: RunningTransfer] = [:]
    private var waitingToRetry: [String: Task<Void, Never>] = [:]

    public init(
        store: any TransferStore,
        tasks: any TransferAttempt,
        client: @escaping @Sendable () async throws -> TableClient,
        policy: TransferPolicy = TransferPolicy(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() },
        newID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.store = store
        self.tasks = tasks
        clientFactory = client
        self.policy = policy
        self.sleep = sleep
        self.now = now
        self.newID = newID
    }

    /// The current queue, and every version of it after that.
    public func updates() -> AsyncThrowingStream<[TransferRecord], Error> {
        store.updates()
    }

    public func transfers() async throws -> [TransferRecord] {
        try await store.all()
    }

    /// No-op while `file` is already downloading; a finished or failed entry starts over.
    public func download(_ file: TableFile) async throws {
        let existing = try await store.all().first {
            $0.direction == .download && $0.remoteID == file.id
        }
        if let existing {
            guard existing.isFinished else { return }
            try await dismiss(id: existing.id)
        }
        try await add(
            TransferRecord(
                id: newID(),
                direction: .download,
                name: file.name,
                size: file.size,
                remoteID: file.id,
                sha256: file.sha256,
                createdAt: now()
            )
        )
    }

    public func upload(_ source: UploadSource) async throws {
        try await add(TransferRecord.upload(source, id: newID(), createdAt: now()))
    }

    /// Starts rows another process appended — the share extension's, which no observation in
    /// this process can see (DESIGN §3).
    public func pickUpQueuedWork() async {
        await pump()
    }

    public func retry(id: String) async throws {
        waitingToRetry.removeValue(forKey: id)?.cancel()
        await mutate(id) { record in
            record.state = .queued
            record.failure = nil
            record.attempts = 0
        }
        await pump()
    }

    public func dismiss(id: String) async throws {
        running.removeValue(forKey: id)?.task.cancel()
        waitingToRetry.removeValue(forKey: id)?.cancel()
        if let record = try await store.record(id: id) {
            tasks.discard(record)
        }
        try await store.delete(id: id)
        await pump()
    }

    /// Rule 14: process death or reboot leaves records behind. Anything unfinished is picked up
    /// where the server and the temp files left it, and orphaned temp files go.
    public func resumeUnfinished() async throws {
        let live = try await store.all().filter(\.isLive)
        tasks.sweep(live: live)
        for record in live where record.state != .queued {
            await mutate(record.id) { $0.state = .queued }
        }
        await pump()
    }

    /// Waits until nothing is running or waiting to retry.
    public func drain() async {
        while true {
            let outstanding = running.values.map(\.task) + Array(waitingToRetry.values)
            guard !outstanding.isEmpty else { return }
            for task in outstanding {
                await task.value
            }
        }
    }

    private func add(_ record: TransferRecord) async throws {
        try await store.put(record)
        await pump()
    }

    /// Starts everything queued that fits under the concurrency cap, oldest first.
    private func pump() async {
        guard let records = try? await store.all() else { return }
        for record in records where record.state == .queued {
            launch(record)
        }
    }

    /// Takes a slot for `record` if one is free, with no suspension in between: a caller waiting
    /// for the queue to go idle must never catch it between two slots.
    private func launch(_ record: TransferRecord) {
        guard running[record.id] == nil, waitingToRetry[record.id] == nil,
              runningCount(record.direction) < policy.maxConcurrentPerDirection
        else { return }
        running[record.id] = RunningTransfer(
            direction: record.direction,
            task: Task { await self.execute(record.id) }
        )
    }

    private func runningCount(_ direction: TransferDirection) -> Int {
        running.values.count { $0.direction == direction }
    }

    /// `nonisolated` so the bytes move on a task executor instead of serializing behind the
    /// queue's own bookkeeping.
    private nonisolated func execute(_ id: String) async {
        guard let record = await mutate(id, { $0.state = .running; $0.failure = nil }) else {
            await settle(id, nil)
            return
        }
        await settle(id, await run(record))
    }

    private nonisolated func run(_ record: TransferRecord) async -> TransferResult {
        let client: TableClient
        do {
            client = try await clientFactory()
        } catch {
            // A rejected host URL — plain `http://` included, per rule 13 — is not something
            // the queue can retry its way out of.
            return permanent(describe(error))
        }
        let report = QueueReport(store: store, id: record.id, size: record.size)
        let result = await tasks.run(client, record, report: report)
        await report.flush()
        return result
    }

    private func settle(_ id: String, _ result: TransferResult?) async {
        switch result {
        case .done(let published):
            await mutate(id) { record in
                record.state = .done
                record.bytesDone = record.size
                record.failure = nil
                record.attempts = 0
                record.publishedName = published?.name
                record.publishedPath = published?.path
            }
        case .failed(let failure):
            let maxAttempts = policy.maxAttempts
            let settled = await mutate(id) { record in
                record.attempts += 1
                record.state = .failed
                record.failure = record.attempts >= maxAttempts && failure.retryable
                    ? TransferFailure(
                        message: "\(failure.message) — gave up after \(maxAttempts) attempts",
                        retryable: false
                    )
                    : failure
            }
            if let settled, settled.failure?.retryable == true {
                scheduleRetry(settled)
            }
        case nil:
            break
        }
        // The retry, if there is one, already holds its own slot, so releasing this one cannot
        // make the queue look idle while the transfer is still going.
        running[id] = nil
        await pump()
    }

    private func scheduleRetry(_ record: TransferRecord) {
        let delay = policy.backoff(afterAttempt: record.attempts)
        waitingToRetry[record.id] = Task {
            try? await sleep(delay)
            await requeue(record.id)
        }
    }

    private func requeue(_ id: String) async {
        guard let failed = try? await store.record(id: id), failed.state == .failed,
              failed.failure?.retryable == true,
              let record = await mutate(id, { $0.state = .queued })
        else {
            waitingToRetry[id] = nil
            return
        }
        waitingToRetry[id] = nil
        launch(record)
        await pump()
    }

    @discardableResult
    private nonisolated func mutate(
        _ id: String,
        _ change: @escaping @Sendable (inout TransferRecord) -> Void
    ) async -> TransferRecord? {
        guard let record = try? await store.update(id: id, change) else { return nil }
        return record
    }
}

/// Writes a running attempt's progress back into the store: one write at a time, and at most
/// one every `interval`, so a fast transfer does not become a stream of database writes.
private final class QueueReport: TransferReport, @unchecked Sendable {
    private let interval: Duration = .milliseconds(500)
    private let store: any TransferStore
    private let id: String
    private let size: Int64
    private let lock = NSLock()
    private var pending: Int64?
    private var writing = false
    private var finished = false

    init(store: any TransferStore, id: String, size: Int64) {
        self.store = store
        self.id = id
        self.size = size
    }

    func bytes(_ done: Int64) {
        let shouldStartWriter: Bool = lock.withLock {
            pending = done
            guard !writing, !finished else { return false }
            writing = true
            return true
        }
        guard shouldStartWriter else { return }
        Task { await drain() }
    }

    func session(_ session: UploadSession?) async {
        _ = try? await store.update(id: id) { record in
            record.remoteID = session?.id
            record.sha256 = session?.sha256 ?? record.sha256
            record.size = session?.size ?? record.size
        }
    }

    /// Persists the last figure the attempt reported, whatever the throttle was still holding.
    func flush() async {
        let last: Int64? = lock.withLock {
            finished = true
            defer { pending = nil }
            return pending
        }
        guard let last else { return }
        await write(last)
    }

    private func drain() async {
        while true {
            let next: Int64? = lock.withLock {
                defer { pending = nil }
                if finished || pending == nil { writing = false }
                return finished ? nil : pending
            }
            guard let next else { return }
            await write(next)
            try? await Task.sleep(for: interval)
        }
    }

    private func write(_ done: Int64) async {
        // Every byte is there but the transfer is not done: hashing, acking and — for an
        // upload — the server's own rehash are what is left.
        let phase: TransferState = done >= size ? .verifying : .running
        _ = try? await store.update(id: id) { record in
            record.bytesDone = done
            if record.state == .running || record.state == .verifying {
                record.state = phase
            }
        }
    }
}
