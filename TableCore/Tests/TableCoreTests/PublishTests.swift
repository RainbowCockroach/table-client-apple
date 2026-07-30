import Foundation
import XCTest
@testable import TableCore

/// Conformance rule 11's last step: the name a download lands under, and what happens to the
/// verified temp file when publishing cannot proceed.
final class PublishTests: XCTestCase {
    private var scratch: Scratch!

    override func setUpWithError() throws {
        scratch = try Scratch(name: "publish")
    }

    override func tearDown() {
        scratch.remove()
    }

    func test_aNameFromAnotherDeviceCannotEscapeTheDestinationDirectory() {
        XCTAssertEqual(safeDisplayName("../../etc/passwd"), ".._.._etc_passwd")
        XCTAssertEqual(safeDisplayName("holiday/photo.jpg"), "holiday_photo.jpg")
        XCTAssertEqual(safeDisplayName("C:\\notes.txt"), "C__notes.txt")
        XCTAssertEqual(safeDisplayName("re\u{0000}port.pdf"), "re_port.pdf")
        XCTAssertEqual(safeDisplayName("  spaced.bin  "), "spaced.bin")
        XCTAssertEqual(safeDisplayName("trailing..."), "trailing")
        XCTAssertEqual(safeDisplayName(""), "download")
        XCTAssertEqual(safeDisplayName("..."), "download")
        XCTAssertEqual(safeDisplayName("réservé.txt"), "réservé.txt")
    }

    func test_collidingNamesGetANumberBeforeTheExtension() {
        XCTAssertEqual(uniqueDisplayName("a.bin") { _ in false }, "a.bin")
        XCTAssertEqual(uniqueDisplayName("a.bin") { $0 == "a.bin" }, "a (1).bin")
        XCTAssertEqual(
            uniqueDisplayName("a.bin") { ["a.bin", "a (1).bin"].contains($0) },
            "a (2).bin"
        )
        XCTAssertEqual(uniqueDisplayName("notes") { $0 == "notes" }, "notes (1)")
        XCTAssertEqual(uniqueDisplayName(".hidden") { $0 == ".hidden" }, ".hidden (1)")
    }

    func test_publishingMovesTheFileInAndUniquifiesTheName() throws {
        let destination = scratch.root.appending(path: "Downloads")
        let publisher = DirectoryDownloadPublisher(directory: destination)
        let first = try scratch.randomFile("first.part", bytes: 64)
        let second = try scratch.randomFile("second.part", bytes: 64)
        let firstBytes = try Data(contentsOf: first)

        let published = try publisher.publish(first, displayName: "holiday/photo.jpg")
        XCTAssertEqual(published.name, "holiday_photo.jpg")
        XCTAssertEqual(try Data(contentsOf: destination.appending(path: "holiday_photo.jpg")), firstBytes)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: first.path(percentEncoded: false)),
            "a published temp file has been moved, not copied"
        )

        let again = try publisher.publish(second, displayName: "holiday/photo.jpg")
        XCTAssertEqual(again.name, "holiday_photo (1).jpg")
    }

    /// Rule 11: a publish that cannot happen must leave the verified copy where it is.
    func test_aFailedPublishKeepsTheVerifiedTempFile() throws {
        let blocked = scratch.file("blocked")
        try Data("not a directory".utf8).write(to: blocked)
        let publisher = DirectoryDownloadPublisher(directory: blocked.appending(path: "Downloads"))
        let temp = try scratch.randomFile("keep.part", bytes: 64)

        XCTAssertThrowsError(try publisher.publish(temp, displayName: "keep.bin"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path(percentEncoded: false)))
    }

    /// Rule 14: temp files outlive processes, so what no record still needs has to go.
    func test_sweepingKeepsOnlyTheTempFilesLiveRecordsStillNeed() throws {
        let temporaryDirectory = scratch.root.appending(path: "temp")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let kept = temporaryDirectory.appending(path: "keep-me.part")
        let orphan = temporaryDirectory.appending(path: "forget-me.part")
        try Data(count: 4).write(to: kept)
        try Data(count: 4).write(to: orphan)

        let tasks = TransferTasks(
            downloads: DownloadTask(
                temporaryDirectory: temporaryDirectory,
                publisher: DirectoryDownloadPublisher(directory: scratch.root)
            ),
            uploads: UploadTask()
        )
        let live = TransferRecord(
            id: "t1",
            direction: .download,
            name: "keep-me.bin",
            size: 4,
            remoteID: "keep-me",
            sha256: String(repeating: "a", count: 64)
        )

        tasks.sweep(live: [live])

        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path(percentEncoded: false)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path(percentEncoded: false)))

        tasks.discard(live)
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.path(percentEncoded: false)))
    }
}
