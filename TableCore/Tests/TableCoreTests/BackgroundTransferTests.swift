import Foundation
import XCTest
@testable import TableCore

private let mib = 1024 * 1024
private let bogusSha = String(repeating: "0", count: 64)

/// The pure halves of the iOS background path (DESIGN §2): the slice a resumed upload sends,
/// and the tail a finished download task delivers.
final class BackgroundPiecesTests: XCTestCase {
    private var scratch: Scratch!

    override func setUpWithError() throws {
        scratch = try Scratch(name: "background")
    }

    override func tearDown() {
        scratch.remove()
    }

    func test_aResumeSliceHoldsExactlyTheBytesTheServerIsMissing() throws {
        let source = try scratch.randomFile("source.bin", bytes: 3 * mib + 17)
        let whole = try Data(contentsOf: source)
        let slice = scratch.file("resume.slice")

        try materializeUploadSlice(of: source, from: 2 * Int64(mib), into: slice)

        XCTAssertEqual(try Data(contentsOf: slice), whole.suffix(from: 2 * mib))
    }

    func test_aSliceReplacesWhateverAnEarlierAttemptLeftUnderTheSameName() throws {
        let source = try scratch.randomFile("source.bin", bytes: 4096)
        let slice = scratch.file("resume.slice")
        try Data(repeating: 0xEE, count: 9999).write(to: slice)

        try materializeUploadSlice(of: source, from: 4000, into: slice)

        XCTAssertEqual(fileSize(slice), 96)
    }

    func test_aWholeFileResponseReplacesAStalePartialFile() throws {
        let delivered = try scratch.randomFile("delivered.bin", bytes: 2048)
        let deliveredBytes = try Data(contentsOf: delivered)
        let partial = scratch.file("target.part")
        try Data(repeating: 0xAA, count: 512).write(to: partial)

        let onDisk = try applyDownloadedTail(delivered, headers(status: 200, size: 2048), to: plan(partial, size: 2048))

        XCTAssertEqual(onDisk, 2048)
        XCTAssertEqual(try Data(contentsOf: partial), deliveredBytes)
    }

    func test_aRangedResponseIsAppendedToWhatIsAlreadyThere() throws {
        let head = Data(repeating: 0x01, count: 600)
        let tail = Data(repeating: 0x02, count: 400)
        let partial = scratch.file("target.part")
        try head.write(to: partial)
        let delivered = scratch.file("delivered.bin")
        try tail.write(to: delivered)

        let onDisk = try applyDownloadedTail(
            delivered,
            headers(status: 206, size: 1000, contentRange: "bytes 600-999/1000"),
            to: plan(partial, size: 1000)
        )

        XCTAssertEqual(onDisk, 1000)
        XCTAssertEqual(try Data(contentsOf: partial), head + tail)
    }

    /// Rule 6 is checked before a byte is written: a response about some other file must not
    /// touch the partial copy.
    func test_aResponseDeclaringAnotherFileIsRefusedAndChangesNothing() throws {
        let delivered = try scratch.randomFile("delivered.bin", bytes: 64)
        let partial = scratch.file("target.part")
        try Data(repeating: 0x01, count: 600).write(to: partial)

        XCTAssertThrowsError(
            try applyDownloadedTail(delivered, headers(status: 200, size: 64), to: plan(partial, size: 1000))
        ) { error in
            guard case .malformedResponse = error as? TableError else {
                return XCTFail("expected a malformed-response error, got \(error)")
            }
        }
        XCTAssertEqual(fileSize(partial), 600)
    }

    func test_aRangeStartingPastThePartialFileIsRefusedRatherThanLeavingAHole() throws {
        let delivered = try scratch.randomFile("delivered.bin", bytes: 100)
        let partial = scratch.file("target.part")
        try Data(repeating: 0x01, count: 600).write(to: partial)

        XCTAssertThrowsError(
            try applyDownloadedTail(
                delivered,
                headers(status: 206, size: 1000, contentRange: "bytes 900-999/1000"),
                to: plan(partial, size: 1000)
            )
        )
        XCTAssertEqual(fileSize(partial), 600)
    }

    func test_aGoneFileIsReportedAsGoneRatherThanAsBytes() throws {
        let delivered = scratch.file("delivered.bin")
        try Data(#"{"error":"not found"}"#.utf8).write(to: delivered)

        XCTAssertThrowsError(
            try applyDownloadedTail(delivered, headers(status: 410, size: 21), to: plan(scratch.file("t.part"), size: 1000))
        ) { error in
            XCTAssertEqual(error as? TableError, .fileGone(id: "file-1", statusCode: 410))
        }
    }

    private func plan(_ partialFile: URL, size: Int64) -> BackgroundDownloadPlan {
        BackgroundDownloadPlan(
            DownloadTarget(id: "file-1", name: "x.bin", size: size, sha256: bogusSha),
            partialFile: partialFile
        )
    }

    private func headers(status: Int, size: Int64, contentRange: String? = nil) -> DownloadHeaders {
        var fields = ["Content-Length": String(size), "X-Checksum-SHA256": bogusSha]
        fields["Content-Range"] = contentRange
        return DownloadHeaders(
            HTTPURLResponse(
                url: URL(string: "https://example.invalid/files/file-1")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: fields
            )!
        )
    }
}

/// The same transfers as the conformance suite, driven through the file-at-a-time seams the
/// iOS background session uses instead of the streaming ones.
final class BackgroundTransferTests: XCTestCase {
    private var scratch: Scratch!
    private var wire: TestWire!
    private var transport: ForegroundFileTransport!
    private var client: TableClient!
    private var uploader: Uploader!
    private var downloader: Downloader!

    override func setUp() async throws {
        try XCTSkipUnless(TestServer.isConfigured, TestServer.missingConfigMessage)
        scratch = try Scratch(name: name.filter { $0.isLetter || $0.isNumber })
        wire = TestWire()
        let candidate = try TestServer.client(wire: wire)
        do {
            _ = try await candidate.listFiles()
        } catch {
            throw XCTSkip(TestServer.unreachableMessage(error))
        }
        client = candidate
        transport = ForegroundFileTransport()
        uploader = Uploader(
            candidate,
            sender: BackgroundUploadSender(transport: transport, sliceDirectory: scratch.file("slices"))
        )
        downloader = Downloader(candidate, fetcher: BackgroundDownloadFetcher(transport: transport))
    }

    override func tearDown() async throws {
        if let client {
            for file in (try? await client.listFiles()) ?? [] {
                _ = try? await client.deleteFile(id: file.id)
            }
        }
        scratch?.remove()
    }

    func test_aFileGoesUpAndComesBackDownThroughTheBackgroundSeams() async throws {
        let source = try scratch.randomFile("roundtrip.bin", bytes: 2 * mib)
        let sourceHash = try sha256Hex(fileAt: source)
        let uploadSource = try UploadSource(fileURL: source)

        let session = try await uploader.createSession(for: uploadSource)
        guard case .finalized(let uploaded) = try await uploader.upload(session, from: uploadSource) else {
            return XCTFail("a whole-file background upload must finalize")
        }
        XCTAssertEqual(uploaded.sha256, sourceHash)

        let temp = scratch.file("roundtrip.part")
        let outcome = try await downloader.download(DownloadTarget(uploaded), to: temp)
        guard case .verified(_, let hash, let ack) = outcome else {
            return XCTFail("expected a verified download, got \(outcome)")
        }
        XCTAssertEqual(hash, sourceHash)
        XCTAssertEqual(ack, .deleted)
        XCTAssertEqual(try Data(contentsOf: temp), try Data(contentsOf: source))
    }

    /// Rule 2 over DESIGN §2's wrinkle: the remainder is materialized as a slice, and the
    /// `PATCH` still carries the server's committed offset.
    func test_aDroppedUploadResumesFromASliceOfTheRemainder() async throws {
        try XCTSkipUnless(TestServer.faultsEnabled, TestServer.faultsDisabledMessage)
        let source = try scratch.randomFile("resume.bin", bytes: 2 * mib)
        let sourceHash = try sha256Hex(fileAt: source)
        let uploadSource = try UploadSource(fileURL: source)
        let session = try await uploader.createSession(for: uploadSource)

        wire.dropAfter("PATCH", 300_000)
        _ = try? await uploader.upload(session, from: uploadSource)
        let committed = try await client.uploadOffset(id: session.id)
        XCTAssertNotNil(committed)
        XCTAssertNotEqual(committed, 0, "the server kept nothing, so there is no resume to test")

        guard case .finalized(let uploaded) = try await uploader.upload(session, from: uploadSource) else {
            return XCTFail("the resumed upload must finalize")
        }
        XCTAssertEqual(uploaded.sha256, sourceHash)
        XCTAssertEqual(
            transport.uploadOffsets.last, committed.map(String.init),
            "the resumed PATCH must start at the server's committed offset"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: scratch.file("slices").appending(path: "\(session.id).slice").path(percentEncoded: false)
            ),
            "the slice is deleted once the attempt is over"
        )
    }

    /// Rule 5: a task that delivers only the tail leaves a whole, verifiable file behind.
    func test_aPartialFileIsResumedWithARangeAndAppendedTo() async throws {
        let source = try scratch.randomFile("ranged.bin", bytes: 2 * mib)
        let sourceHash = try sha256Hex(fileAt: source)
        let uploadSource = try UploadSource(fileURL: source)
        let session = try await uploader.createSession(for: uploadSource)
        guard case .finalized(let uploaded) = try await uploader.upload(session, from: uploadSource) else {
            return XCTFail("upload must finalize before the download half")
        }

        let temp = try scratch.slice(of: source, upTo: 700_000, named: "ranged.part")
        let outcome = try await downloader.download(DownloadTarget(uploaded), to: temp)

        guard case .verified(_, let hash, _) = outcome else {
            return XCTFail("expected a verified download, got \(outcome)")
        }
        XCTAssertEqual(hash, sourceHash)
        XCTAssertEqual(try Data(contentsOf: temp), try Data(contentsOf: source))
        XCTAssertEqual(
            transport.ranges.last, "bytes=700000-",
            "the resume must ask for the missing tail, not the whole file"
        )
    }
}
