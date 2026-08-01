import Foundation
import XCTest
@testable import TableCore

/// The macOS API key store of DESIGN §5.
final class FileAPIKeyStoreTests: XCTestCase {
    private var scratch: Scratch!
    private var store: FileAPIKeyStore!

    override func setUpWithError() throws {
        scratch = try Scratch(name: "FileAPIKeyStore")
        store = FileAPIKeyStore(fileURL: scratch.file("nested").appending(path: "api-key"))
    }

    override func tearDown() {
        scratch.remove()
    }

    func test_anUnwrittenKeyReadsAsEmpty() throws {
        XCTAssertEqual(try store.read(), "")
    }

    func test_theKeyRoundTripsThroughADirectoryThatDidNotExist() throws {
        try store.write("sekrit")

        XCTAssertEqual(try store.read(), "sekrit")
    }

    func test_writingOverAKeyReplacesIt() throws {
        try store.write("first")
        try store.write("second")

        XCTAssertEqual(try store.read(), "second")
    }

    /// `APIKeyStore`: an empty key removes the stored one, so clearing it in Settings leaves
    /// nothing on disk to read back.
    func test_anEmptyKeyRemovesTheFile() throws {
        try store.write("sekrit")

        try store.write("")

        XCTAssertEqual(try store.read(), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
    }

    func test_clearingAKeyThatWasNeverWrittenIsNotAnError() throws {
        XCTAssertNoThrow(try store.write(""))
    }

    /// DESIGN §5: the key is at rest in the container, so it is at least not world-readable.
    func test_theKeyFileIsOwnerOnly() throws {
        try store.write("sekrit")

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path(percentEncoded: false))
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    private var fileURL: URL {
        scratch.file("nested").appending(path: "api-key")
    }
}
