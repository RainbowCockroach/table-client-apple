import CryptoKit
import Foundation

/// Buffer size for every streaming read in the client; DESIGN §2 calls for ~1 MiB.
public let transferBufferBytes = 1 << 20

/// Incremental SHA-256 over a byte stream.
///
/// A download that resumes rebuilds its digest by re-feeding the partial temp file
/// (``update(contentsOf:)``) and then continues incrementally, so a resumed transfer
/// still hashes the complete file (conformance rule 6).
public struct Sha256Hasher: Sendable {
    private var digest = SHA256()

    public private(set) var bytesHashed: Int64 = 0

    public init() {}

    public mutating func update(_ data: Data) {
        digest.update(data: data)
        bytesHashed += Int64(data.count)
    }

    /// Feeds the whole file; returns the number of bytes read.
    @discardableResult
    public mutating func update(contentsOf fileURL: URL) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let before = bytesHashed
        while let chunk = try handle.read(upToCount: transferBufferBytes), !chunk.isEmpty {
            update(chunk)
        }
        return bytesHashed - before
    }

    public func hex() -> String {
        digest.finalize().hex
    }
}

/// SHA-256 of a file, in lowercase hex.
public func sha256Hex(fileAt fileURL: URL) throws -> String {
    var hasher = Sha256Hasher()
    try hasher.update(contentsOf: fileURL)
    return hasher.hex()
}

/// True for the lowercase-hex SHA-256 shape the API contract requires.
public func isSha256Hex(_ text: String) -> Bool {
    let bytes = text.utf8
    return bytes.count == 64 && bytes.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
}

extension Sequence<UInt8> {
    /// Lowercase hex, the only SHA-256 encoding the wire protocol uses.
    var hex: String {
        var out = ""
        out.reserveCapacity(64)
        for byte in self {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0f)])
        }
        return out
    }
}

private let hexDigits = Array("0123456789abcdef")
