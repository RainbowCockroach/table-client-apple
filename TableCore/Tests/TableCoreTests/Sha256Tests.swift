import Foundation
import XCTest
@testable import TableCore

final class Sha256Tests: XCTestCase {
    private var scratch: Scratch!

    override func setUpWithError() throws {
        scratch = try Scratch(name: "sha256")
    }

    override func tearDown() {
        scratch.remove()
    }

    func test_hashesTheKnownVectorInLowercaseHex() throws {
        var hasher = Sha256Hasher()
        hasher.update(Data("abc".utf8))

        XCTAssertEqual(hasher.hex(), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hasher.bytesHashed, 3)
    }

    /// DESIGN §2: a resumed download re-feeds the partial temp file and then continues, so the
    /// two must add up to the hash of the whole file (conformance rule 6).
    func test_aDigestRebuiltFromAPartialFileMatchesHashingItAllAtOnce() throws {
        let whole = try scratch.randomFile("whole.bin", bytes: 300_000)
        let partial = try scratch.slice(of: whole, upTo: 128 * 1024, named: "whole.part")
        let tail = try Data(contentsOf: whole).dropFirst(128 * 1024)

        var resumed = Sha256Hasher()
        try resumed.update(contentsOf: partial)
        XCTAssertEqual(resumed.bytesHashed, 128 * 1024)
        resumed.update(Data(tail))

        XCTAssertEqual(resumed.hex(), try sha256Hex(fileAt: whole))
        XCTAssertEqual(resumed.bytesHashed, fileSize(whole))
    }

    func test_anEmptyFileHashesToTheEmptyDigest() throws {
        let empty = scratch.file("empty.bin")
        try Data().write(to: empty)

        XCTAssertEqual(
            try sha256Hex(fileAt: empty),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func test_onlySixtyFourLowercaseHexCharactersAreASha256() {
        XCTAssertTrue(isSha256Hex(String(repeating: "a", count: 64)))
        XCTAssertTrue(isSha256Hex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
        XCTAssertFalse(isSha256Hex(String(repeating: "A", count: 64)), "the contract says lowercase")
        XCTAssertFalse(isSha256Hex(String(repeating: "a", count: 63)))
        XCTAssertFalse(isSha256Hex(String(repeating: "a", count: 65)))
        XCTAssertFalse(isSha256Hex("g" + String(repeating: "a", count: 63)))
        XCTAssertFalse(isSha256Hex(""))
    }
}
