import Foundation
@testable import TableCore

/// A queue that forgets on exit — enough for the state-machine tests, which are about
/// transitions rather than durability.
final class InMemoryTransferStore: TransferStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: TransferRecord] = [:]
    private var listeners: [UUID: AsyncThrowingStream<[TransferRecord], Error>.Continuation] = [:]

    init(_ initial: [TransferRecord] = []) {
        for record in initial {
            records[record.id] = record
        }
    }

    func all() async throws -> [TransferRecord] {
        lock.withLock { sortedLocked() }
    }

    func record(id: String) async throws -> TransferRecord? {
        lock.withLock { records[id] }
    }

    func put(_ record: TransferRecord) async throws {
        lock.withLock { records[record.id] = record }
        publish()
    }

    @discardableResult
    func update(
        id: String,
        _ change: @Sendable (inout TransferRecord) -> Void
    ) async throws -> TransferRecord? {
        let updated: TransferRecord? = lock.withLock {
            guard var record = records[id] else { return nil }
            change(&record)
            records[id] = record
            return record
        }
        if updated != nil { publish() }
        return updated
    }

    func delete(id: String) async throws {
        lock.withLock { records[id] = nil }
        publish()
    }

    func updates() -> AsyncThrowingStream<[TransferRecord], Error> {
        AsyncThrowingStream { continuation in
            let token = UUID()
            lock.withLock { listeners[token] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.listeners[token] = nil }
            }
            continuation.yield(lock.withLock { sortedLocked() })
        }
    }

    private func publish() {
        let (snapshot, continuations) = lock.withLock { (sortedLocked(), Array(listeners.values)) }
        for continuation in continuations {
            continuation.yield(snapshot)
        }
    }

    private func sortedLocked() -> [TransferRecord] {
        records.values.sorted { $0.createdAt < $1.createdAt }
    }
}
