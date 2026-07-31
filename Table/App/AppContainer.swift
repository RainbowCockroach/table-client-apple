import Foundation
import TableCore

/// Everything the app owns for a whole launch, wired once.
final class AppContainer {
    let settings: SettingsStore
    let clients: ClientProvider
    let queue: TransferQueue

    #if os(macOS)
    let uploads: UploadIntake
    private let bookmarks: SourceBookmarks
    #endif

    init() throws {
        let paths = try AppPaths()
        settings = SettingsStore(apiKeys: KeychainAPIKeyStore())
        let clients = ClientProvider(settings: settings)
        self.clients = clients
        queue = TransferQueue(
            store: try SQLiteTransferStore(fileURL: paths.queueDatabase),
            tasks: TransferTasks(
                downloads: DownloadTask(
                    temporaryDirectory: paths.partialDownloads,
                    publisher: DirectoryDownloadPublisher(directory: paths.publishDirectory)
                ),
                uploads: UploadTask()
            ),
            client: { try await clients.client() }
        )
        #if os(macOS)
        bookmarks = SourceBookmarks(fileURL: paths.sourceBookmarks)
        uploads = UploadIntake(queue: queue, bookmarks: bookmarks)
        #endif
    }

    /// Rule 14: an upload that outlived its process needs its sandbox claim back before the
    /// queue resumes it.
    func reclaimUploadSources() async {
        #if os(macOS)
        let live = (try? await queue.transfers())?.filter(\.isLive) ?? []
        bookmarks.reopen(paths: Set(live.compactMap(\.sourcePath)))
        #endif
    }
}

/// One client per version of the settings: building a new one per attempt would mean a new
/// `URLSession`, and a new connection pool, for every retry.
actor ClientProvider {
    private let settings: SettingsStore
    private var current: (settings: TableSettings, client: TableClient)?

    init(settings: SettingsStore) {
        self.settings = settings
    }

    func client() throws -> TableClient {
        let latest = try settings.load()
        if let current, current.settings == latest {
            return current.client
        }
        let client = try latest.client()
        current = (latest, client)
        return client
    }
}
