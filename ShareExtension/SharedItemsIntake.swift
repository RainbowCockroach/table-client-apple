import Foundation
import TableCore
import UniformTypeIdentifiers

/// Copies what the share sheet handed over into the app group container and appends a queue
/// row per file (DESIGN §4).
@MainActor
@Observable
final class SharedItemsIntake {
    /// What the confirmation shows once every item has been dealt with; nil while working.
    private(set) var summary: Summary?

    /// The container or the queue could not be opened — nothing was staged.
    private(set) var failure: String?

    struct Summary {
        var queued: [String] = []
        var rejected: [String] = []
    }

    /// The user gets told to set the app up rather than left wondering why nothing moved.
    let hasServer = SettingsStore.hasHost(in: AppGroup.defaults() ?? .standard)

    private let providers: [NSItemProvider]

    init(items: [NSExtensionItem]) {
        providers = items.flatMap { $0.attachments ?? [] }
    }

    func run() async {
        do {
            let paths = try ContainerPaths.appGroup()
            try paths.create()
            let staging = UploadStaging(
                store: try SQLiteTransferStore(fileURL: paths.queueDatabase),
                directory: paths.stagedUploads
            )
            var summary = Summary()
            for provider in providers {
                do {
                    summary.queued.append(try await stage(provider, with: staging).name)
                } catch {
                    summary.rejected.append(describe(error))
                }
            }
            self.summary = summary
        } catch {
            failure = describe(error)
        }
    }

    private func stage(_ provider: NSItemProvider, with staging: UploadStaging) async throws -> TransferRecord {
        try await staging.queue(try await copyIn(provider, with: staging))
    }

    /// The handed-over file is readable only until the callback returns — in place under a
    /// claim we have to take, otherwise as a temporary the system deletes right after — so the
    /// copy happens inside it and the queue row waits until after.
    private func copyIn(_ provider: NSItemProvider, with staging: UploadStaging) async throws -> UploadSource {
        let type = provider.registeredContentTypes.first { $0.conforms(to: .item) } ?? .data
        let name = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: true) { url, wasInPlace, error in
                continuation.resume(with: Result {
                    guard let url else {
                        throw error ?? SharedItemUnavailable(name: name ?? "the shared item")
                    }
                    let claimed = wasInPlace && url.startAccessingSecurityScopedResource()
                    defer {
                        if claimed { url.stopAccessingSecurityScopedResource() }
                    }
                    return try staging.copyIn(url, name: name)
                })
            }
        }
    }
}

struct SharedItemUnavailable: Error, LocalizedError {
    let name: String

    var errorDescription: String? {
        "\(name) — the app that shared it did not hand over a file"
    }
}

private func describe(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
}
