import Foundation
import XCTest
@testable import TableCore

/// DESIGN §5's split storage, and what the settings hand to ``TableClient`` afterwards.
final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var apiKeys: InMemoryAPIKeyStore!
    private var store: SettingsStore!

    override func setUpWithError() throws {
        suiteName = "SettingsStoreTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        apiKeys = InMemoryAPIKeyStore()
        store = SettingsStore(defaults: defaults, apiKeys: apiKeys)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func test_settingsRoundTripThroughTheirTwoStores() throws {
        try store.save(
            TableSettings(hostURL: "https://files.example.com", apiKey: "sekrit", allowInsecureHTTP: true)
        )

        let loaded = try store.load()
        XCTAssertEqual(loaded.hostURL, "https://files.example.com")
        XCTAssertEqual(loaded.apiKey, "sekrit")
        XCTAssertTrue(loaded.allowInsecureHTTP)
        XCTAssertTrue(loaded.isConfigured)
    }

    /// Rule 12: nothing in the defaults domain may hold the key.
    func test_theApiKeyIsNeverWrittenToUserDefaults() throws {
        try store.save(TableSettings(hostURL: "https://files.example.com", apiKey: "sekrit"))

        let stored = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertFalse(stored.values.contains { ($0 as? String) == "sekrit" })
        XCTAssertEqual(apiKeys.stored, "sekrit")
    }

    func test_nothingSavedYetReadsAsUnconfigured() throws {
        let loaded = try store.load()
        XCTAssertEqual(loaded, TableSettings())
        XCTAssertFalse(loaded.isConfigured)
    }

    func test_surroundingWhitespaceFromATypedFieldIsDropped() throws {
        try store.save(TableSettings(hostURL: "  https://files.example.com\n", apiKey: " sekrit "))

        let loaded = try store.load()
        XCTAssertEqual(loaded.hostURL, "https://files.example.com")
        XCTAssertEqual(loaded.apiKey, "sekrit")
    }

    func test_clearingTheKeyRemovesTheStoredOne() throws {
        try store.save(TableSettings(hostURL: "https://files.example.com", apiKey: "sekrit"))
        try store.save(TableSettings(hostURL: "https://files.example.com", apiKey: ""))

        XCTAssertNil(apiKeys.stored)
        XCTAssertFalse(try store.load().isConfigured)
    }

    /// DESIGN §5: iOS moved the host URL into the app group's suite so the extension can read
    /// it, and a device set up before that keeps its server.
    func test_theHostIsInheritedFromTheDefaultsAnEarlierBuildWroteTo() throws {
        try store.save(TableSettings(hostURL: "https://files.example.com", apiKey: "sekrit", allowInsecureHTTP: true))
        let sharedSuite = "SettingsStoreTests-shared-\(UUID().uuidString)"
        let shared = try XCTUnwrap(UserDefaults(suiteName: sharedSuite))
        defer { shared.removePersistentDomain(forName: sharedSuite) }

        let moved = SettingsStore(defaults: shared, inheritingFrom: defaults, apiKeys: apiKeys)

        XCTAssertEqual(try moved.load().hostURL, "https://files.example.com")
        XCTAssertTrue(try moved.load().allowInsecureHTTP)
        XCTAssertTrue(SettingsStore.hasHost(in: shared))
    }

    func test_aHostAlreadyInTheSharedSuiteIsNotOverwritten() throws {
        try store.save(TableSettings(hostURL: "https://old.example.com", apiKey: "sekrit"))
        let sharedSuite = "SettingsStoreTests-shared-\(UUID().uuidString)"
        let shared = try XCTUnwrap(UserDefaults(suiteName: sharedSuite))
        defer { shared.removePersistentDomain(forName: sharedSuite) }
        try SettingsStore(defaults: shared, apiKeys: apiKeys)
            .save(TableSettings(hostURL: "https://current.example.com", apiKey: "sekrit"))

        let reopened = SettingsStore(defaults: shared, inheritingFrom: defaults, apiKeys: apiKeys)

        XCTAssertEqual(try reopened.load().hostURL, "https://current.example.com")
    }

    /// What the share extension is allowed to know: whether there is a server, without a key.
    func test_anEmptyHostReadsAsNoServer() throws {
        XCTAssertFalse(SettingsStore.hasHost(in: defaults))

        try store.save(TableSettings(hostURL: "https://files.example.com", apiKey: ""))

        XCTAssertTrue(SettingsStore.hasHost(in: defaults))
    }

    /// Rule 13: the refusal happens when the settings build a client, before any request.
    func test_aPlainHttpHostIsRefusedUntilTheOverrideIsOn() throws {
        var settings = TableSettings(hostURL: "http://127.0.0.1:8080", apiKey: "devkey")
        XCTAssertThrowsError(try settings.client()) { error in
            XCTAssertEqual(error as? TableError, .insecureHost("http://127.0.0.1:8080"))
        }

        settings.allowInsecureHTTP = true
        XCTAssertNoThrow(try settings.client())
    }
}

private final class InMemoryAPIKeyStore: APIKeyStore, @unchecked Sendable {
    private(set) var stored: String?

    func read() throws -> String {
        stored ?? ""
    }

    func write(_ apiKey: String) throws {
        stored = apiKey.isEmpty ? nil : apiKey
    }
}
