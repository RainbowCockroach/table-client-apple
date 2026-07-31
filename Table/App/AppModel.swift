import Foundation
import Observation
import TableCore

/// DESIGN §5: the list refreshes on this cadence while the app is in front of the user.
private let listPollInterval = Duration.seconds(5)

enum ConnectionTest {
    case running
    case reachable(fileCount: Int)
    case unreachable(String)
}

/// The state both screens read, and the only place they reach the queue through.
@Observable
final class AppModel {
    private(set) var settings = TableSettings()
    private(set) var files: [TableFile] = []
    private(set) var isListLoaded = false
    private(set) var listError: String?
    private(set) var transfers: [TransferRecord] = []
    private(set) var connectionTest: ConnectionTest?

    /// Nothing works without a queue on disk, so this is shown instead of the list.
    private(set) var startupFailure: String?

    var notice: String?

    private let container: AppContainer?
    private let notifications = TransferNotifications()
    private var settled = SettledTransfers()

    init() {
        do {
            container = try AppContainer()
        } catch {
            container = nil
            startupFailure = error.localizedDescription
            return
        }
        reloadSettings()
    }

    /// Resumes what the last launch left behind, then follows the queue for as long as the
    /// view lives (conformance rule 14).
    func start() async {
        guard let container else { return }
        await notifications.requestAuthorization()
        settled.takeStock(of: await snapshot(container))
        await resumeUnfinished(container)
        do {
            for try await records in await container.queue.updates() {
                announce(settled.newlySettled(in: records))
                transfers = records
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    /// DESIGN §6: the system woke the app to hand back finished background transfers, and it
    /// stays awake only as long as this runs — verify, ack and publish happen here or not yet.
    func completeBackgroundTransfers() async {
        guard let container else { return }
        settled.takeStock(of: await snapshot(container))
        await resumeUnfinished(container)
        await container.queue.drain()
        announce(settled.newlySettled(in: await snapshot(container)))
    }

    /// DESIGN §3: the share extension appends its rows from another process, which no database
    /// observation in this one can see. Coming to the front is when they are read and started.
    func adoptSharedQueue() async {
        guard let container else { return }
        transfers = await snapshot(container)
        await container.queue.pickUpQueuedWork()
    }

    func pollWhileActive() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: listPollInterval)
        }
    }

    func refresh() async {
        guard let container, settings.isConfigured else {
            files = []
            isListLoaded = false
            return
        }
        do {
            files = try await container.clients.client().listFiles()
            isListLoaded = true
            listError = nil
        } catch {
            // Keep the last good list on screen: a poll failing is not the same as an empty table.
            listError = error.localizedDescription
        }
    }

    func download(_ file: TableFile) {
        perform { try await $0.queue.download(file) }
    }

    /// DESIGN §5's "take all": the queue ignores the ones already running.
    func downloadAll() {
        let wanted = files
        perform { container in
            for file in wanted {
                try await container.queue.download(file)
            }
        }
    }

    func retry(_ transferID: String) {
        perform { try await $0.queue.retry(id: transferID) }
    }

    func dismiss(_ transferID: String) {
        perform { try await $0.queue.dismiss(id: transferID) }
    }

    func dismissFinished() {
        let settled = transfers.filter(\.isFinished).map(\.id)
        perform { container in
            for transferID in settled {
                try await container.queue.dismiss(id: transferID)
            }
        }
    }

    func save(_ edited: TableSettings) {
        guard let container else { return }
        connectionTest = nil
        do {
            try container.settings.save(edited)
        } catch {
            notice = error.localizedDescription
        }
        reloadSettings()
    }

    /// DESIGN §5: `GET /files` is the cheapest proof that the host, TLS, and key all work.
    func testConnection(_ edited: TableSettings) {
        connectionTest = .running
        Task {
            do {
                connectionTest = .reachable(fileCount: try await edited.client().listFiles().count)
            } catch {
                connectionTest = .unreachable(error.localizedDescription)
            }
        }
    }

    func add(_ urls: [URL]) {
        guard let container, !urls.isEmpty else { return }
        Task {
            notice = problem(with: await container.uploads.accept(urls))
        }
    }

    /// What the drop and the picker never say: which files could not be queued, and why.
    private func problem(with intake: IntakeResult) -> String? {
        guard !intake.rejected.isEmpty else { return nil }
        let couldNotAdd = "Couldn't add \(intake.rejected.joined(separator: ", "))."
        return intake.queued == 0 ? couldNotAdd : "Queued \(intake.queued). \(couldNotAdd)"
    }

    private func announce(_ finished: [TransferRecord]) {
        for transfer in finished {
            notifications.post(transfer)
        }
    }

    private func snapshot(_ container: AppContainer) async -> [TransferRecord] {
        (try? await container.queue.transfers()) ?? []
    }

    private func resumeUnfinished(_ container: AppContainer) async {
        await container.reclaimUploadSources()
        do {
            try await container.queue.resumeUnfinished()
        } catch {
            notice = error.localizedDescription
        }
    }

    private func reloadSettings() {
        guard let container else { return }
        do {
            settings = try container.settings.load()
        } catch {
            notice = error.localizedDescription
        }
    }

    private func perform(_ work: @escaping (AppContainer) async throws -> Void) {
        guard let container else { return }
        Task {
            do {
                try await work(container)
            } catch {
                notice = error.localizedDescription
            }
        }
    }
}
