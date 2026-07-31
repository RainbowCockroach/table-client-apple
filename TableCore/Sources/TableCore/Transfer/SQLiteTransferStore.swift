import Foundation
import GRDB

extension TransferRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transfer"
}

/// The queue table from DESIGN §3: SQLite via GRDB, in the app group container so the share
/// extension and the main app see the same queue.
///
/// A pool rather than a queue because two processes write here: it opens the database in WAL
/// mode, where the extension appending a row and the app updating a transfer's progress do not
/// have to wait for each other. `updates()` still only sees this process's own writes — the
/// app re-reads the queue when it comes to the front (DESIGN §3).
public final class SQLiteTransferStore: TransferStore {
    private let database: DatabasePool

    public init(fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var configuration = Configuration()
        // What another process holds the write lock for is one row; waiting for it beats
        // failing an intake with SQLITE_BUSY.
        configuration.busyMode = .timeout(10)
        database = try Self.openMigrated(fileURL, configuration)
    }

    /// Both processes may arrive at an empty container at once; the coordinator lets one of
    /// them create and migrate the database while the other waits.
    private static func openMigrated(_ fileURL: URL, _ configuration: Configuration) throws -> DatabasePool {
        var opened: Result<DatabasePool, Error>?
        var coordinationFailure: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: fileURL,
            options: .forMerging,
            error: &coordinationFailure
        ) { url in
            opened = Result {
                let database = try DatabasePool(
                    path: url.path(percentEncoded: false),
                    configuration: configuration
                )
                try migrator.migrate(database)
                return database
            }
        }
        guard let opened else { throw coordinationFailure ?? CocoaError(.fileReadUnknown) }
        return try opened.get()
    }

    public func all() async throws -> [TransferRecord] {
        try await database.read { db in
            try TransferRecord.order(Column("createdAt")).fetchAll(db)
        }
    }

    public func record(id: String) async throws -> TransferRecord? {
        try await database.read { db in
            try TransferRecord.fetchOne(db, key: id)
        }
    }

    public func put(_ record: TransferRecord) async throws {
        try await database.write { db in
            try record.save(db)
        }
    }

    @discardableResult
    public func update(
        id: String,
        _ change: @Sendable (inout TransferRecord) -> Void
    ) async throws -> TransferRecord? {
        try await database.write { db in
            guard var record = try TransferRecord.fetchOne(db, key: id) else { return nil }
            change(&record)
            try record.update(db)
            return record
        }
    }

    public func delete(id: String) async throws {
        _ = try await database.write { db in
            try TransferRecord.deleteOne(db, key: id)
        }
    }

    public func updates() -> AsyncThrowingStream<[TransferRecord], Error> {
        let observation = ValueObservation.tracking { db in
            try TransferRecord.order(Column("createdAt")).fetchAll(db)
        }
        return AsyncThrowingStream { continuation in
            let observing = Task { [database] in
                do {
                    for try await records in observation.values(in: database) {
                        continuation.yield(records)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in observing.cancel() }
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createTransfer") { db in
            try db.create(table: TransferRecord.databaseTableName) { table in
                table.primaryKey("id", .text)
                table.column("direction", .text).notNull()
                table.column("name", .text).notNull()
                table.column("size", .integer).notNull()
                table.column("state", .text).notNull()
                table.column("remoteID", .text)
                table.column("sha256", .text)
                table.column("sourcePath", .text)
                table.column("bytesDone", .integer).notNull()
                table.column("failure", .text)
                table.column("attempts", .integer).notNull()
                table.column("publishedName", .text)
                table.column("publishedPath", .text)
                table.column("createdAt", .datetime).notNull().indexed()
            }
        }
        return migrator
    }
}
