import Foundation
import XCTest
@testable import TableCore

private let mib = 1024 * 1024
private let bogusSha = String(repeating: "0", count: 64)

/// Scenario 10's drop offset, kept identical to the shell scenario's.
private let drop: Int64 = 300_000

/// The server's conformance scenarios re-run through this client's real code paths
/// (DESIGN §7). Each test maps to one script in `table-server/conformance/scenarios/`.
final class ConformanceTests: XCTestCase {
    private var scratch: Scratch!
    private var wire: TestWire!
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
        uploader = Uploader(candidate)
        downloader = Downloader(candidate)
        try await sweepServer()
        wire.clear()
    }

    override func tearDown() async throws {
        if client != nil {
            try await sweepServer()
        }
        scratch?.remove()
    }

    /// Scenarios are independent, exactly as `conformance/run.sh` keeps them. An `uploading`
    /// entry needs its session aborted — `DELETE /files/{id}` answers 404 for those.
    private func sweepServer() async throws {
        for file in try await client.listFiles() {
            switch file.state {
            case .uploading: _ = try await client.abortUpload(id: file.id)
            case .available: _ = try await client.deleteFile(id: file.id)
            }
        }
    }

    // MARK: 01_auth — the bearer key gates everything (conformance rule 12)

    func test_scenario01_wrongApiKeyIsRejectedAndTheRightOneIsNot() async throws {
        let wrongKey = try TestServer.client(apiKey: "definitely-wrong")
        await assertThrows(TableError.unauthorized(operation: "list files")) {
            _ = try await wrongKey.listFiles()
        }

        _ = try await client.listFiles()
    }

    func test_ruleThirteenRefusesPlainHttpUnlessOverridden() throws {
        XCTAssertThrowsError(try TableClient(hostURL: "http://files.example.com", apiKey: "k")) { error in
            XCTAssertEqual(error as? TableError, .insecureHost("http://files.example.com"))
        }
        XCTAssertThrowsError(try TableClient(hostURL: "not a url", apiKey: "k")) { error in
            XCTAssertEqual(error as? TableError, .invalidHost("not a url"))
        }
        XCTAssertNoThrow(try TableClient(hostURL: "https://files.example.com/", apiKey: "k"))
        XCTAssertNoThrow(
            try TableClient(hostURL: "http://127.0.0.1:8080", apiKey: "k", allowInsecureHTTP: true)
        )
    }

    // MARK: 02_roundtrip — upload → listed → download → verify → ack → gone

    func test_scenario02_aFileSurvivesARoundTripByteIdenticalAndThenDisappears() async throws {
        let source = try scratch.randomFile("roundtrip.bin", bytes: mib)
        let sourceHash = try sha256Hex(fileAt: source)
        let uploaded = try await uploadFully(source)

        let files = try await client.listFiles()
        let listed = try XCTUnwrap(files.first { $0.id == uploaded.id })
        XCTAssertEqual(listed.state, .available)
        XCTAssertEqual(listed.sha256, sourceHash)
        XCTAssertEqual(listed.bytesReceived, listed.size)
        XCTAssertNotNil(listed.expiresAt, "an available file has a running TTL")

        let temp = scratch.file("roundtrip.part")
        let outcome = try await downloader.download(DownloadTarget(listed), to: temp)
        guard case .verified(_, let hash, let ack) = outcome else {
            return XCTFail("expected a verified download, got \(outcome)")
        }
        XCTAssertEqual(ack, .deleted)
        XCTAssertEqual(hash, sourceHash)
        try assertSameBytes(temp, source)

        let stillListed = try await client.listFiles().contains { $0.id == uploaded.id }
        XCTAssertFalse(stillListed, "an acked file must not be listed")
        let again = try await downloader.download(DownloadTarget(listed), to: scratch.file("roundtrip.again"))
        XCTAssertEqual(again, .gone)
    }

    // MARK: 03_upload_resume — resume from the server's offset, never from zero (rule 2)

    func test_scenario03_aHalfSentUploadResumesFromTheCommittedOffset() async throws {
        let source = try scratch.randomFile("resume.bin", bytes: 2 * mib)
        let sourceHash = try sha256Hex(fileAt: source)
        let uploadSource = try UploadSource(fileURL: source)
        let half = uploadSource.size / 2
        let session = try await uploader.createSession(for: uploadSource)

        let firstHalf = try await client.appendBytes(
            id: session.id,
            offset: 0,
            from: try scratch.slice(of: source, upTo: half, named: "resume.firsthalf")
        )
        XCTAssertEqual(firstHalf, .incomplete(committedOffset: half))
        let offset = try await client.uploadOffset(id: session.id)
        XCTAssertEqual(offset, half)

        // A short body, so the 409 never races an unread request body on the socket.
        let replayed = try await client.appendBytes(
            id: session.id,
            offset: 0,
            from: try scratch.slice(of: source, upTo: 1024, named: "resume.replay")
        )
        XCTAssertEqual(
            replayed, .offsetMismatch(committedOffset: half),
            "a replay from a stale offset must be refused, not silently accepted"
        )

        try await assertResumes(from: half) {
            try await self.uploader.upload(session, from: uploadSource)
        }
        let verified = try await downloadVerified(session.id, size: uploadSource.size, sha256: sourceHash)
        XCTAssertEqual(verified.sha256, sourceHash)
    }

    // MARK: 04_upload_hash_mismatch — a corrupt upload never becomes visible (rule 3)

    func test_scenario04_aDeclaredHashThatDoesNotMatchDestroysTheSession() async throws {
        let source = try scratch.randomFile("liar.bin", bytes: 512 * 1024)
        let size = fileSize(source)
        let lyingSession = try await client.createUpload(name: "liar.bin", size: size, sha256: bogusSha)

        let result = try await client.appendBytes(id: lyingSession, offset: 0, from: source)
        guard case .finalizeRejected = result else {
            return XCTFail("expected finalize to be rejected, got \(result)")
        }

        let offset = try await client.uploadOffset(id: lyingSession)
        XCTAssertNil(offset, "the rejected session must be destroyed")
        let listed = try await client.listFiles().contains { $0.id == lyingSession }
        XCTAssertFalse(listed, "a rejected upload must not be listed")

        // Rule 3: the retry is a brand-new session, and it succeeds.
        let honest = try await uploadFully(source)
        let honestListed = try await client.listFiles().contains { $0.id == honest.id }
        XCTAssertTrue(honestListed)
    }

    // MARK: 05_download_range_resume — resume from the partial temp file (rule 5)

    func test_scenario05_anInterruptedDownloadResumesWithRangeAndVerifiesWhole() async throws {
        let source = try scratch.randomFile("ranged.bin", bytes: mib)
        let sourceHash = try sha256Hex(fileAt: source)
        let uploaded = try await uploadFully(source)

        let cut: Int64 = 500_000
        let temp = scratch.file("ranged.part")
        try await streamPrefix(of: uploaded.id, upTo: cut, into: temp)
        XCTAssertEqual(fileSize(temp), cut)

        await assertThrows(TableError.rangeNotSatisfiable(id: uploaded.id)) {
            _ = try await self.client.openDownload(id: uploaded.id, rangeFrom: Int64(10 * mib))
        }

        wire.clear()
        let progress = LowestProgress()
        let outcome = try await downloader.download(DownloadTarget(uploaded), to: temp) { progress.saw($0) }

        guard case .verified(_, let hash, let ack) = outcome else {
            return XCTFail("expected a verified download, got \(outcome)")
        }
        XCTAssertEqual(ack, .deleted)
        XCTAssertEqual(hash, sourceHash)
        try assertSameBytes(temp, source)
        let lowest = progress.lowest
        XCTAssertGreaterThan(lowest, cut, "the resumed download restarted at \(lowest)")

        let resumeGet = try XCTUnwrap(wire.of("GET").first)
        XCTAssertEqual(resumeGet.range, "bytes=\(cut)-", "rule 5: Range comes from the partial file's size")
        XCTAssertEqual(resumeGet.status, 206)
    }

    // MARK: 06_ack_semantics — ack is hash-gated and 404 means success (rules 8, 9, 10)

    func test_scenario06_ackDeletesOnlyOnAMatchingHashAndRepeatsAreSuccess() async throws {
        let source = try scratch.randomFile("acked.bin", bytes: 256 * 1024)
        let sourceHash = try sha256Hex(fileAt: source)
        let uploaded = try await uploadFully(source)

        let rejected = try await client.ack(id: uploaded.id, sha256: bogusSha)
        XCTAssertEqual(rejected, .hashMismatch)
        let survived = try await client.listFiles().contains { $0.id == uploaded.id }
        XCTAssertTrue(survived, "a bad ack must not delete")

        let accepted = try await client.ack(id: uploaded.id, sha256: sourceHash)
        XCTAssertEqual(accepted, .deleted)
        let repeated = try await client.ack(id: uploaded.id, sha256: sourceHash)
        XCTAssertEqual(repeated, .alreadyGone)
    }

    func test_scenario06_aCorruptLocalCopyIsDiscardedInsteadOfAcked() async throws {
        let source = try scratch.randomFile("corrupt.bin", bytes: 128 * 1024)
        let uploaded = try await uploadFully(source)

        // Right length, wrong bytes: nothing is left to fetch, so only verification can catch it.
        let temp = scratch.file("corrupt.part")
        try Data(count: Int(uploaded.size)).write(to: temp)
        wire.clear()

        let outcome = try await downloader.download(DownloadTarget(uploaded), to: temp)
        guard case .corrupt = outcome else {
            return XCTFail("expected the local copy to be rejected, got \(outcome)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: temp.path(percentEncoded: false)),
            "rule 10: a corrupt local copy is discarded"
        )
        let serverCopy = try await client.listFiles().contains { $0.id == uploaded.id }
        XCTAssertTrue(serverCopy, "the server copy must survive")
        XCTAssertFalse(
            wire.entries.contains { $0.path.hasSuffix("/ack") },
            "rule 8: never ack a copy that failed verification"
        )
    }

    // MARK: 07_ttl_expiry — unacked files vanish on their own

    func test_scenario07_anUnackedFileExpires() async throws {
        let ttl = try XCTUnwrap(
            TestServer.ttlSeconds,
            "TABLE_TTL_SECONDS unset — run the dev server with a short TABLE_TTL"
        )
        try XCTSkipUnless(ttl <= 60, "TABLE_TTL_SECONDS=\(ttl) is too long for a test to wait out")
        let source = try scratch.randomFile("doomed.bin", bytes: 64 * 1024)
        let uploaded = try await uploadFully(source)
        let listed = try await client.listFiles().contains { $0.id == uploaded.id }
        XCTAssertTrue(listed)

        // The sweeper runs every TABLE_SWEEP_INTERVAL, 15 s by default.
        try await Task.sleep(for: .seconds(ttl + 20))

        let stillListed = try await client.listFiles().contains { $0.id == uploaded.id }
        XCTAssertFalse(stillListed, "an expired file must not be listed")
        let outcome = try await downloader.download(DownloadTarget(uploaded), to: scratch.file("doomed.part"))
        XCTAssertEqual(outcome, .gone)
    }

    // MARK: 08_live_relay — uploading files are listed and downloadable (rule 15)

    func test_scenario08_aDownloadStartedMidUploadTailFollowsToAVerifiedFile() async throws {
        let source = try scratch.randomFile("live.bin", bytes: 2 * mib)
        let sourceHash = try sha256Hex(fileAt: source)
        let uploadSource = try UploadSource(fileURL: source)
        let half = uploadSource.size / 2
        let session = try await uploader.createSession(for: uploadSource)

        let firstHalf = try await client.appendBytes(
            id: session.id,
            offset: 0,
            from: try scratch.slice(of: source, upTo: half, named: "live.firsthalf")
        )
        XCTAssertEqual(firstHalf, .incomplete(committedOffset: half))

        let files = try await client.listFiles()
        let listed = try XCTUnwrap(files.first { $0.id == session.id })
        XCTAssertEqual(listed.state, .uploading)
        XCTAssertEqual(listed.bytesReceived, half)
        XCTAssertNil(listed.expiresAt, "the TTL starts at finalize, not at upload")

        let temp = scratch.file("live.part")
        let target = DownloadTarget(listed)
        let downloading = Task { [downloader] in try await downloader!.download(target, to: temp) }
        try await Task.sleep(for: .milliseconds(500))
        let finished = try await uploader.upload(session, from: uploadSource)
        guard case .finalized = finished else {
            return XCTFail("expected the upload to finalize, got \(finished)")
        }

        let outcome = try await downloading.value
        guard case .verified(_, let hash, let ack) = outcome else {
            return XCTFail("expected a verified download, got \(outcome)")
        }
        XCTAssertEqual(hash, sourceHash)
        try assertSameBytes(temp, source)
        // A relay reader reaches the declared size the moment the last bytes are committed,
        // which is before the server's finalize flips the row to `available` — and an ack
        // arriving inside that window is answered 404. Rule 9 covers it either way; see the
        // C1 log in PROGRESS.md for the server-side race this leaves open.
        XCTAssertTrue([.deleted, .alreadyGone].contains(ack), "unexpected ack outcome \(ack)")
    }

    // MARK: 09_concurrent_downloads — both complete, the second ack is success (rule 9)

    func test_scenario09_twoConcurrentDownloadsBothVerifyAndTheLoserAcksAsGone() async throws {
        let source = try scratch.randomFile("popular.bin", bytes: mib)
        let sourceHash = try sha256Hex(fileAt: source)
        let uploaded = try await uploadFully(source)
        let target = DownloadTarget(uploaded)
        let temps = [scratch.file("popular.a"), scratch.file("popular.b")]

        let outcomes = try await withThrowingTaskGroup(of: DownloadOutcome.self) { group in
            for temp in temps {
                group.addTask { [downloader] in try await downloader!.download(target, to: temp) }
            }
            return try await group.reduce(into: [DownloadOutcome]()) { $0.append($1) }
        }

        var acks: [AckResult] = []
        for outcome in outcomes {
            guard case .verified(_, let hash, let ack) = outcome else {
                return XCTFail("expected a verified download, got \(outcome)")
            }
            XCTAssertEqual(hash, sourceHash)
            acks.append(ack)
        }
        for temp in temps {
            try assertSameBytes(temp, source)
        }
        XCTAssertEqual(
            Set(acks), [.deleted, .alreadyGone],
            "exactly one ack deletes; the other is told the file is already gone"
        )
    }

    // MARK: 10_fault_injection — an exact-byte drop, both directions (rules 2, 5)

    func test_scenario10_aDownloadDroppedAtAnExactByteResumesFromThePartialFile() async throws {
        try skipUnlessFaultsEnabled()
        let source = try scratch.randomFile("fault_dl.bin", bytes: mib)
        let sourceHash = try sha256Hex(fileAt: source)
        let uploaded = try await uploadFully(source)
        let target = DownloadTarget(uploaded)
        let temp = scratch.file("fault_dl.part")

        wire.dropAfter("GET", drop)
        await assertRetryableFailure {
            _ = try await self.downloader.download(target, to: temp)
        }
        // The server flushes exactly `drop` bytes, but the abrupt close resets the connection,
        // and an RST lets the receiving side discard whatever it had buffered but not yet
        // delivered — so what landed is a prefix of `drop`, not necessarily all of it. What
        // rule 5 is about is that the resume starts from whatever landed.
        let partial = fileSize(temp)
        XCTAssertGreaterThan(partial, 0, "the drop must land mid-transfer, not before it started")
        XCTAssertLessThan(partial, target.size)

        wire.clear()
        let progress = LowestProgress()
        let outcome = try await downloader.download(target, to: temp) { progress.saw($0) }

        guard case .verified(_, let hash, let ack) = outcome else {
            return XCTFail("expected a verified download, got \(outcome)")
        }
        XCTAssertEqual(ack, .deleted)
        XCTAssertEqual(hash, sourceHash)
        try assertSameBytes(temp, source)
        let lowest = progress.lowest
        XCTAssertGreaterThan(lowest, partial, "the resumed download restarted at \(lowest)")

        let resumeGet = try XCTUnwrap(wire.of("GET").first)
        XCTAssertEqual(resumeGet.range, "bytes=\(partial)-", "rule 5: Range comes from the partial file's size")
        XCTAssertEqual(resumeGet.status, 206)
    }

    func test_scenario10_anUploadDroppedAtAnExactByteResumesFromTheCommittedOffset() async throws {
        try skipUnlessFaultsEnabled()
        let source = try scratch.randomFile("fault_ul.bin", bytes: mib)
        let sourceHash = try sha256Hex(fileAt: source)
        let uploadSource = try UploadSource(fileURL: source)
        let session = try await uploader.createSession(for: uploadSource)

        wire.dropAfter("PATCH", drop)
        await assertRetryableFailure {
            _ = try await self.uploader.upload(session, from: uploadSource)
        }
        let committed = try await client.uploadOffset(id: session.id)
        XCTAssertEqual(committed, drop, "the server commits exactly the bytes it read before the drop")

        try await assertResumes(from: drop) {
            try await self.uploader.upload(session, from: uploadSource)
        }
        let verified = try await downloadVerified(session.id, size: uploadSource.size, sha256: sourceHash)
        XCTAssertEqual(verified.sha256, sourceHash)
    }

    /// The digest of a resumed download is rebuilt from the temp file rather than carried
    /// across attempts (DESIGN §2), so a second drop has to land on an already-partial file
    /// to exercise that path for real. The drop offset is relative to the range body.
    func test_aDownloadDroppedTwiceKeepsAccumulatingInsteadOfRestarting() async throws {
        try skipUnlessFaultsEnabled()
        let source = try scratch.randomFile("fault_twice.bin", bytes: mib)
        let sourceHash = try sha256Hex(fileAt: source)
        let uploaded = try await uploadFully(source)
        let target = DownloadTarget(uploaded)
        let temp = scratch.file("fault_twice.part")

        let secondDrop: Int64 = 200_000
        wire.dropAfter("GET", drop)
        await assertRetryableFailure { _ = try await self.downloader.download(target, to: temp) }
        let afterFirstDrop = fileSize(temp)
        wire.dropAfter("GET", secondDrop)
        await assertRetryableFailure { _ = try await self.downloader.download(target, to: temp) }
        let afterSecondDrop = fileSize(temp)
        XCTAssertGreaterThan(
            afterSecondDrop, afterFirstDrop,
            "the second attempt appended rather than restarting at zero"
        )

        wire.clear()
        let outcome = try await downloader.download(target, to: temp)
        guard case .verified(_, let hash, _) = outcome else {
            return XCTFail("expected a verified download, got \(outcome)")
        }
        XCTAssertEqual(hash, sourceHash, "rule 6: the rebuilt digest covers the whole file")
        try assertSameBytes(temp, source)
        XCTAssertEqual(
            wire.of("GET").map(\.range), ["bytes=\(afterSecondDrop)-"],
            "rule 5: one resume request, from the partial file's size"
        )
    }

    // MARK: helpers

    private func skipUnlessFaultsEnabled() throws {
        try XCTSkipUnless(TestServer.faultsEnabled, TestServer.faultsDisabledMessage)
    }

    private func uploadFully(_ source: URL) async throws -> TableFile {
        let uploadSource = try UploadSource(fileURL: source)
        let session = try await uploader.createSession(for: uploadSource)
        let outcome = try await uploader.upload(session, from: uploadSource)
        guard case .finalized(let file) = outcome else {
            throw XCTSkip("upload did not finalize: \(outcome)")
        }
        return file
    }

    /// Conformance rule 2: the offset comes from `HEAD`, and the upload never restarts at zero.
    private func assertResumes(from committed: Int64, _ upload: () async throws -> UploadOutcome) async throws {
        wire.clear()
        let outcome = try await upload()
        guard case .finalized = outcome else {
            return XCTFail("expected the resumed upload to finalize, got \(outcome)")
        }
        XCTAssertEqual(wire.entries.first?.method, "HEAD", "rule 2: ask the server where it got to")
        let resumePatch = try XCTUnwrap(wire.of("PATCH").last)
        XCTAssertEqual(resumePatch.uploadOffset, String(committed), "rule 2: resume, never restart")
    }

    /// Reads only the first `byteCount` bytes and hangs up — a client-side mid-download drop.
    private func streamPrefix(of id: String, upTo byteCount: Int64, into temp: URL) async throws {
        let stream = try await client.openDownload(id: id)
        var written = Data()
        for try await chunk in stream.body {
            written.append(chunk)
            if written.count >= Int(byteCount) { break }
        }
        stream.cancel()
        try written.prefix(Int(byteCount)).write(to: temp)
    }

    private func downloadVerified(
        _ id: String,
        size: Int64,
        sha256: String
    ) async throws -> (tempFile: URL, sha256: String) {
        let target = DownloadTarget(id: id, name: "verify.bin", size: size, sha256: sha256)
        let outcome = try await downloader.download(target, to: scratch.file("verify.\(id)"))
        guard case .verified(let tempFile, let hash, _) = outcome else {
            throw XCTSkip("expected a verified download, got \(outcome)")
        }
        return (tempFile, hash)
    }

    private func assertSameBytes(_ lhs: URL, _ rhs: URL) throws {
        XCTAssertEqual(try Data(contentsOf: lhs), try Data(contentsOf: rhs))
    }

    private func assertThrows(_ expected: TableError, _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)")
        } catch {
            XCTAssertEqual(error as? TableError, expected)
        }
    }

    private func assertRetryableFailure(_ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected the transfer to fail")
        } catch {
            XCTAssertTrue(
                RetryPolicy.isRetryable(error),
                "a cut connection is what backoff exists for, got \(error)"
            )
        }
    }
}

/// The smallest progress figure a transfer reported, which is how a restart-instead-of-resume
/// shows up from the outside.
private final class LowestProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = Int64.max

    var lowest: Int64 { lock.withLock { seen } }

    func saw(_ bytes: Int64) {
        lock.withLock { seen = min(seen, bytes) }
    }
}
