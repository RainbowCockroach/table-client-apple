import Foundation

/// A per-test directory, removed on teardown.
struct Scratch {
    let root: URL

    init(name: String) throws {
        root = URL.temporaryDirectory.appending(path: "TableCoreTests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func file(_ name: String) -> URL {
        root.appending(path: name)
    }

    @discardableResult
    func randomFile(_ name: String, bytes: Int) throws -> URL {
        let url = file(name)
        try Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max) }).write(to: url)
        return url
    }

    /// The first `count` bytes of `source` as a standalone file — a slice, which is how
    /// DESIGN §2 says a resumed background upload sends a partial body.
    func slice(of source: URL, upTo count: Int64, named name: String) throws -> URL {
        let url = file(name)
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        try Data(handle.read(upToCount: Int(count)) ?? Data()).write(to: url)
        return url
    }
}
