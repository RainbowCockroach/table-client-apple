import Foundation
import XCTest
@testable import TableCore

/// What can be put on the table at all: `POST /uploads` refuses a non-positive size, so the
/// picker and the drop have to refuse the same files before they reach the queue.
final class UploadSourceTests: XCTestCase {
    private var scratch: Scratch!

    override func setUpWithError() throws {
        scratch = try Scratch(name: "upload-source")
    }

    override func tearDown() {
        scratch.remove()
    }

    func test_aFileIsMeasuredAndNamedFromItsUrl() throws {
        let file = try scratch.randomFile("notes.txt", bytes: 1234)

        let source = try UploadSource(fileURL: file)
        XCTAssertEqual(source.name, "notes.txt")
        XCTAssertEqual(source.size, 1234)
    }

    func test_anEmptyFileIsRefused() throws {
        let file = try scratch.randomFile("nothing.bin", bytes: 0)

        XCTAssertThrowsError(try UploadSource(fileURL: file)) { error in
            XCTAssertEqual(error as? TableError, .invalidRequest("empty; an upload needs at least one byte"))
        }
    }

    func test_aFolderIsRefused() throws {
        let folder = scratch.file("holiday")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        XCTAssertThrowsError(try UploadSource(fileURL: folder)) { error in
            XCTAssertEqual(error as? TableError, .invalidRequest("a folder, not a file"))
        }
    }

    func test_aFileThatIsNotThereIsRefused() {
        let missing = scratch.file("gone.bin")

        XCTAssertThrowsError(try UploadSource(fileURL: missing)) { error in
            XCTAssertEqual(error as? TableError, .sourceNotReadable(missing))
        }
    }
}
