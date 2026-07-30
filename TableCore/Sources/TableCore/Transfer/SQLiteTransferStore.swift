import Foundation
import GRDB

extension TransferRecord: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "transfer"
}

/// The queue table from DESIGN §3: SQLite via GRDB, in the app group container so the share
/// extension and the main app see the same queue.
public final class SQLiteTransferStore: TransferStore {
    private let database: DatabaseQueue

    public init(fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        database = try DatabaseQueue(path: fileURL.path(percentEncoded: false))
        try Self.migrator.migrate(database)
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
