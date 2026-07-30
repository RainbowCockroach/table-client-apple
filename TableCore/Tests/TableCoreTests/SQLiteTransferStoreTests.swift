import Foundation
import XCTest
@testable import TableCore

/// Conformance rule 14 is only as good as the queue's durability, so the store is tested
/// against a real database file rather than a stub.
final class SQLiteTransferStoreTests: XCTestCase {
    private var scratch: Scratch!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        scratch = try Scratch(name: "store")
        databaseURL = scratch.file("queue/transfers.sqlite")
    }

    override func tearDown() {
        scratch.remove()
    }

    func test_aRecordSurvivesReopeningTheDatabase() async throws {
        let record = TransferRecord(
            id: "t1",
            direction: .upload,
            name: "big.bin",
            size: 4096,
            state: .running,
            remoteID: "session-1",
            sha256: String(repeating: "a", count: 64),
            sourcePath: "/tmp/big.bin",
            bytesDone: 1024,
            failure: TransferFailure(message: "connection lost", retryable: true),
            attempts: 2,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await SQLiteTransferStore(fileURL: databaseURL).put(record)

        let reopened = try SQLiteTransferStore(fileURL: databaseURL)
        let restored = try await reopened.record(id: "t1")
        XCTAssertEqual(restored, record)
    }

    func test_recordsComeBackOldestFirst() async throws {
        let store = try SQLiteTransferStore(fileURL: databaseURL)
        for (index, id) in ["third", "first", "second"].enumerated() {
            let offsets: [String: TimeInterval] = ["first": 0, "second": 10, "third": 20]
            try await store.put(
                TransferRecord(
                    id: id,
                    direction: .download,
                    name: "\(id).bin",
                    size: Int64(index + 1),
                    createdAt: Date(timeIntervalSince1970: offsets[id]!)
                )
            )
        }

        let ordered = try await store.all()
        XCTAssertEqual(ordered.map(\.id), ["first", "second", "third"])
    }

    func test_updateAppliesToTheStoredRowAndReportsAMissingOne() async throws {
        let store = try SQLiteTransferStore(fileURL: databaseURL)
        try await store.put(
            TransferRecord(id: "t1", direction: .download, name: "a.bin", size: 10, remoteID: "f1")
        )

        let updated = try await store.update(id: "t1") { record in
            record.state = .verifying
            record.bytesDone = 10
        }
        XCTAssertEqual(updated?.state, .verifying)
        let stored = try await store.record(id: "t1")
        XCTAssertEqual(stored?.bytesDone, 10)

        let missing = try await store.update(id: "gone") { $0.state = .done }
        XCTAssertNil(missing)
    }

    func test_deleteRemovesTheRow() async throws {
        let store = try SQLiteTransferStore(fileURL: databaseURL)
        try await store.put(TransferRecord(id: "t1", direction: .download, name: "a.bin", size: 10))

        try await store.delete(id: "t1")

        let deleted = try await store.record(id: "t1")
        XCTAssertNil(deleted)
        let remaining = try await store.all()
        XCTAssertTrue(remaining.isEmpty)
    }

    func test_updatesPublishTheQueueAndThenEveryChangeToIt() async throws {
        let store = try SQLiteTransferStore(fileURL: databaseURL)
        var versions = store.updates().makeAsyncIterator()

        let first = try await versions.next()
        XCTAssertEqual(first?.count, 0)

        try await store.put(TransferRecord(id: "t1", direction: .download, name: "a.bin", size: 10))
        let afterInsert = try await versions.next()
        XCTAssertEqual(afterInsert?.map(\.id), ["t1"])

        try await store.update(id: "t1") { $0.state = .done }
        let afterUpdate = try await versions.next()
        XCTAssertEqual(afterUpdate?.first?.state, .done)
    }
}
