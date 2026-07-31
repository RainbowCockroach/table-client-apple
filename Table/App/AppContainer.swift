import Foundation
import TableCore

/// Everything the app owns for a whole launch, wired once.
final class AppContainer {
    let settings: SettingsStore
    let clients: ClientProvider
    let queue: TransferQueue
    let uploads: UploadIntake

    #if os(macOS)
    private let bookmarks: SourceBookmarks
    #endif

    init() throws {
        let paths = try AppPaths()
        settings = makeSettingsStore()
        let clients = ClientProvider(settings: settings)
        self.clients = clients
        let store = try SQLiteTransferStore(fileURL: paths.container.queueDatabase)
        queue = TransferQueue(
            store: store,
            tasks: transferTasks(paths),
            client: { try await clients.client() }
        )
        #if os(macOS)
        bookmarks = SourceBookmarks(fileURL: paths.container.sourceBookmarks)
        uploads = UploadIntake(queue: queue, bookmarks: bookmarks)
        #else
        uploads = UploadIntake(
            queue: queue,
            staging: UploadStaging(store: store, directory: paths.container.stagedUploads)
        )
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

/// DESIGN §2: macOS transfers run in the foreground session; iOS transfers run in the
/// background one, so they survive suspension and app termination.
private func transferTasks(_ paths: AppPaths) -> TransferTasks {
    let publisher = DirectoryDownloadPublisher(directory: paths.publishDirectory)
    #if os(iOS)
    return TransferTasks(
        downloads: DownloadTask(
            temporaryDirectory: paths.container.partialDownloads,
            publisher: publisher,
            fetcher: BackgroundDownloadFetcher(transport: backgroundTransfers)
        ),
        uploads: UploadTask(
            sender: BackgroundUploadSender(
                transport: backgroundTransfers,
                sliceDirectory: paths.container.uploadSlices
            ),
            stagedSources: paths.container.stagedUploads
        )
    )
    #else
    return TransferTasks(
        downloads: DownloadTask(temporaryDirectory: paths.container.partialDownloads, publisher: publisher),
        uploads: UploadTask()
    )
    #endif
}

/// DESIGN §5: on iOS the host URL lives in the app group's suite, which is the only way the
/// share extension can tell whether there is a server to queue for.
private func makeSettingsStore() -> SettingsStore {
    let apiKeys = KeychainAPIKeyStore()
    #if os(iOS)
    guard let shared = AppGroup.defaults() else { return SettingsStore(apiKeys: apiKeys) }
    return SettingsStore(defaults: shared, inheritingFrom: .standard, apiKeys: apiKeys)
    #else
    return SettingsStore(apiKeys: apiKeys)
    #endif
}

#if os(iOS)
/// The identifier the system reattaches this app's unfinished transfers to, whichever launch
/// asks for them.
let backgroundSessionIdentifier = "rainbowroachie.Table.transfers"

/// A global because a background session is one per process by construction: `URLSession`
/// refuses a second one with the same identifier, and building the container twice — which
/// SwiftUI is free to do — must not try. It is told about the app group because the bodies
/// `nsurlsessiond` reads and the files it writes are in that container (DESIGN §4).
let backgroundTransfers = BackgroundTransferSession(
    identifier: backgroundSessionIdentifier,
    sharedContainerIdentifier: AppGroup.identifier
)
#endif

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
