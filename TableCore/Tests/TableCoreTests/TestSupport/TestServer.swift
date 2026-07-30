import Foundation
@testable import TableCore

/// The local `table-server` the conformance suite runs against (DESIGN §7).
///
/// Address and key come from `TABLE_URL`/`TABLE_API_KEY` in the environment; without them
/// the conformance tests skip and the unit tests still run.
enum TestServer {
    static let url = setting("TABLE_URL")
    static let apiKey = setting("TABLE_API_KEY")
    static let ttlSeconds = setting("TABLE_TTL_SECONDS").flatMap(Int.init)
    static let faultsEnabled = setting("TABLE_TEST_FAULTS") == "1"

    static var isConfigured: Bool { url != nil && apiKey != nil }

    static let missingConfigMessage =
        "no table-server configured — start one and set TABLE_URL and TABLE_API_KEY "
            + "(see table-server/CLAUDE.md 'Dev loop')"

    static let faultsDisabledMessage =
        "TABLE_TEST_FAULTS is not 1 — the dev server and the tests both need it set "
            + "for X-Test-Drop-After to do anything"

    static func unreachableMessage(_ cause: Error) -> String {
        "table-server at \(url ?? "?") is not reachable: \(cause)"
    }

    static func client(wire: WireHook? = nil, apiKey overrideKey: String? = nil) throws -> TableClient {
        try TableClient(
            hostURL: url!,
            apiKey: overrideKey ?? apiKey!,
            allowInsecureHTTP: true,
            configuration: .tableForeground,
            wire: wire
        )
    }

    private static func setting(_ name: String) -> String? {
        ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Records what actually went on the wire and arms the server's `X-Test-Drop-After` fault
/// (root DESIGN §2) — the resume rules are assertions about `Range` and `Upload-Offset`.
///
/// The fault is one-shot by construction: the attempt after a drop is the resume being
/// tested, so it has to reach the server intact.
final class TestWire: WireHook, @unchecked Sendable {
    struct Entry: Sendable {
        let method: String
        let path: String
        let range: String?
        let uploadOffset: String?
        let status: Int
    }

    private let lock = NSLock()
    private var recorded: [Entry] = []
    private var armed: (method: String, afterBytes: Int64)?

    var entries: [Entry] {
        lock.withLock { recorded }
    }

    func of(_ method: String) -> [Entry] {
        entries.filter { $0.method == method }
    }

    func clear() {
        lock.withLock { recorded.removeAll() }
    }

    func dropAfter(_ method: String, _ afterBytes: Int64) {
        lock.withLock { armed = (method, afterBytes) }
    }

    func annotate(_ request: inout URLRequest) {
        let fault: Int64? = lock.withLock {
            guard let armed, armed.method == request.httpMethod else { return nil }
            self.armed = nil
            return armed.afterBytes
        }
        guard let fault else { return }
        request.setValue(String(fault), forHTTPHeaderField: "X-Test-Drop-After")
    }

    func record(_ request: URLRequest, _ response: HTTPURLResponse) {
        let entry = Entry(
            method: request.httpMethod ?? "?",
            path: request.url?.path() ?? "",
            range: request.value(forHTTPHeaderField: "Range"),
            uploadOffset: request.value(forHTTPHeaderField: "Upload-Offset"),
            status: response.statusCode
        )
        lock.withLock { recorded.append(entry) }
    }
}
