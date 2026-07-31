import Foundation
import TableCore

/// What an intake has to say for itself; `rejected` is empty when every file was queued.
struct IntakeResult {
    let queued: Int
    let rejected: [String]
}

/// Turns dropped, picked and shared files into upload records.
///
/// The sandbox claim comes first: a file the queue cannot read is a permanent failure, and
/// this is the only moment the app is allowed to take that claim.
struct UploadIntake {
    private let queue: TransferQueue

    #if os(macOS)
    private let bookmarks: SourceBookmarks

    init(queue: TransferQueue, bookmarks: SourceBookmarks) {
        self.queue = queue
        self.bookmarks = bookmarks
    }
    #else
    private let staging: UploadStaging

    init(queue: TransferQueue, staging: UploadStaging) {
        self.queue = queue
        self.staging = staging
    }
    #endif

    func accept(_ urls: [URL]) async -> IntakeResult {
        var queued = 0
        var rejected: [String] = []
        for url in urls {
            do {
                try await enqueue(url)
                queued += 1
            } catch {
                rejected.append("\(url.lastPathComponent) — \(error.localizedDescription)")
            }
        }
        return IntakeResult(queued: queued, rejected: rejected)
    }

    #if os(macOS)
    private func enqueue(_ url: URL) async throws {
        try bookmarks.remember(url)
        try await queue.upload(UploadSource(fileURL: url))
    }
    #else
    /// The picked document is copied into the container first: the background session sends the
    /// body from another process, and the pick's claim on the original dies with this launch
    /// while the upload may outlive it (conformance rule 14). That is the share extension's
    /// intake exactly, so it is the share extension's code (DESIGN §4).
    private func enqueue(_ url: URL) async throws {
        let claimed = url.startAccessingSecurityScopedResource()
        defer {
            if claimed { url.stopAccessingSecurityScopedResource() }
        }
        try await staging.stage(url)
        await queue.pickUpQueuedWork()
    }
    #endif
}
