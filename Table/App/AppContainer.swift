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
        settings = SettingsStore(apiKeys: KeychainAPIKeyStore())
        let clients = ClientProvider(settings: settings)
        self.clients = clients
        queue = TransferQueue(
            store: try SQLiteTransferStore(fileURL: paths.queueDatabase),
            tasks: transferTasks(paths),
            client: { try await clients.client() }
        )
        #if os(macOS)
        bookmarks = SourceBookmarks(fileURL: paths.sourceBookmarks)
        uploads = UploadIntake(queue: queue, bookmarks: bookmarks)
        #else
        uploads = UploadIntake(queue: queue, stagedSources: paths.stagedUploads)
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
            temporaryDirectory: paths.partialDownloads,
            publisher: publisher,
            fetcher: BackgroundDownloadFetcher(transport: backgroundTransfers)
        ),
        uploads: UploadTask(
            sender: BackgroundUploadSender(transport: backgroundTransfers, sliceDirectory: paths.uploadSlices),
            stagedSources: paths.stagedUploads
        )
    )
    #else
    return TransferTasks(
        downloads: DownloadTask(temporaryDirectory: paths.partialDownloads, publisher: publisher),
        uploads: UploadTask()
    )
    #endif
}

#if os(iOS)
/// The identifier the system reattaches this app's unfinished transfers to, whichever launch
/// asks for them.
let backgroundSessionIdentifier = "rainbowroachie.Table.transfers"

/// A global because a background session is one per process by construction: `URLSession`
/// refuses a second one with the same identifier, and building the container twice — which
/// SwiftUI is free to do — must not try.
let backgroundTransfers = BackgroundTransferSession(identifier: backgroundSessionIdentifier)
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
