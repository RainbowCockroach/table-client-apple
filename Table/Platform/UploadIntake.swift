#if os(macOS)
import Foundation
import TableCore

/// What an intake has to say for itself; `rejected` is empty when every file was queued.
struct IntakeResult {
    let queued: Int
    let rejected: [String]
}

/// Turns dropped and picked files into upload records.
///
/// The sandbox claim comes first: a file the queue cannot read is a permanent failure, and
/// this is the only moment the app is allowed to take that claim.
struct UploadIntake {
    private let queue: TransferQueue
    private let bookmarks: SourceBookmarks

    init(queue: TransferQueue, bookmarks: SourceBookmarks) {
        self.queue = queue
        self.bookmarks = bookmarks
    }

    func accept(_ urls: [URL]) async -> IntakeResult {
        var queued = 0
        var rejected: [String] = []
        for url in urls {
            do {
                try bookmarks.remember(url)
                try await queue.upload(UploadSource(fileURL: url))
                queued += 1
            } catch {
                rejected.append("\(url.lastPathComponent) — \(error.localizedDescription)")
            }
        }
        return IntakeResult(queued: queued, rejected: rejected)
    }
}
#endif
