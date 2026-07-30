import Foundation

/// Where the queue lives across process death (conformance rule 14).
///
/// A protocol so the queue and its tests are plain Swift; the durable implementation is
/// ``SQLiteTransferStore``.
public protocol TransferStore: Sendable {
    /// Oldest first, so the UI order is the order things were queued in.
    func all() async throws -> [TransferRecord]

    func record(id: String) async throws -> TransferRecord?

    func put(_ record: TransferRecord) async throws

    /// Read-modify-write as one step; nil if the record was dismissed meanwhile.
    @discardableResult
    func update(id: String, _ change: @Sendable (inout TransferRecord) -> Void) async throws -> TransferRecord?

    func delete(id: String) async throws

    /// The current queue, and every version of it after that.
    func updates() -> AsyncThrowingStream<[TransferRecord], Error>
}
