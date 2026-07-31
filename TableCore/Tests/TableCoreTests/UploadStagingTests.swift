import Foundation
import XCTest
@testable import TableCore

/// DESIGN §4: what the share extension does, which is the one intake with no UI to test it
/// through.
final class UploadStagingTests: XCTestCase {
    private var scratch: Scratch!
    private var store: InMemoryTransferStore!
    private var staging: UploadStaging!

    override func setUpWithError() throws {
        scratch = try Scratch(name: "staging")
        store = InMemoryTransferStore()
        staging = UploadStaging(store: store, directory: scratch.file("uploads"))
    }

    override func tearDown() {
        scratch.remove()
    }

    func test_aSharedFileIsCopiedInAndQueued() async throws {
        let shared = try scratch.randomFile("holiday.mov", bytes: 2048)

        let record = try await staging.stage(shared)

        XCTAssertEqual(record.direction, .upload)
        XCTAssertEqual(record.state, .queued)
        XCTAssertEqual(record.name, "holiday.mov")
        XCTAssertEqual(record.size, 2048)
        let queued = try await store.all()
        XCTAssertEqual(queued.map(\.id), [record.id])
        let copy = try XCTUnwrap(record.sourcePath)
        XCTAssertEqual(try Data(contentsOf: URL(filePath: copy)), try Data(contentsOf: shared))
    }

    /// The copy is what the upload reads: whatever the share sheet handed over is gone once
    /// the extension is (conformance rule 14).
    func test_theQueuedCopyOutlivesTheSharedFile() async throws {
        let shared = try scratch.randomFile("gone.bin", bytes: 512)

        let record = try await staging.stage(shared)
        try FileManager.default.removeItem(at: shared)

        let copy = URL(filePath: try XCTUnwrap(record.sourcePath))
        XCTAssertNotEqual(copy, shared)
        XCTAssertNoThrow(try UploadSource(fileURL: copy))
    }

    /// A share sheet's temporary file is often named for the format, not for the item.
    func test_theSharedNameTravelsWithTheCopy() async throws {
        let shared = try scratch.randomFile("IMG_0001.tmp", bytes: 16)

        let record = try await staging.stage(shared, name: "Sunset.heic")

        XCTAssertEqual(record.name, "Sunset.heic")
        XCTAssertTrue(try XCTUnwrap(record.sourcePath).hasSuffix("Sunset.heic"))
    }

    func test_aNameThatWouldEscapeTheStagingDirectoryIsFlattened() async throws {
        let shared = try scratch.randomFile("odd.bin", bytes: 16)

        let record = try await staging.stage(shared, name: "../../etc/passwd")

        let copy = URL(filePath: try XCTUnwrap(record.sourcePath))
        XCTAssertEqual(copy.deletingLastPathComponent().lastPathComponent, "uploads")
    }

    /// What `POST /uploads` would refuse anyway is refused where the file comes in, so the
    /// extension can say which item it could not take.
    func test_anEmptyItemIsRejectedWithoutQueueingAnything() async throws {
        let empty = scratch.file("empty.txt")
        try Data().write(to: empty)

        do {
            _ = try await staging.stage(empty)
            XCTFail("an empty file is not uploadable")
        } catch {
            let queued = try await store.all()
            XCTAssertTrue(queued.isEmpty)
        }
    }

    /// A copy no row claims is invisible garbage in the shared container.
    func test_aCopyIsDroppedWhenItsRowCannotBeWritten() async throws {
        let shared = try scratch.randomFile("doomed.bin", bytes: 64)
        let staging = UploadStaging(store: FailingTransferStore(), directory: scratch.file("uploads"))

        let copy = try staging.copyIn(shared)
        do {
            _ = try await staging.queue(copy)
            XCTFail("the store refused the row")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: copy.fileURL.path(percentEncoded: false)))
        }
    }
}

private struct FailingTransferStore: TransferStore {
    struct Refused: Error {}

    func all() async throws -> [TransferRecord] { [] }
    func record(id: String) async throws -> TransferRecord? { nil }
    func put(_ record: TransferRecord) async throws { throw Refused() }
    func update(id: String, _ change: @Sendable (inout TransferRecord) -> Void) async throws -> TransferRecord? { nil }
    func delete(id: String) async throws {}
    func updates() -> AsyncThrowingStream<[TransferRecord], Error> { AsyncThrowingStream { $0.finish() } }
}
