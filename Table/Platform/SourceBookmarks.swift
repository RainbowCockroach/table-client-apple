#if os(macOS)
import Foundation

/// Security-scoped bookmarks for the files the upload queue still has to read.
///
/// A dropped or picked file is readable only while the app holds a claim on it, and the claim
/// dies with the process — so conformance rule 14's resume-after-relaunch needs the bookmark
/// on disk. Claims are held for the whole launch and released by process exit: a queued upload
/// may start reading at any point until it finishes.
final class SourceBookmarks {
    private let fileURL: URL
    private var bookmarks: [String: Data]

    init(fileURL: URL) {
        self.fileURL = fileURL
        bookmarks = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String: Data].self, from: $0) } ?? [:]
    }

    func remember(_ url: URL) throws {
        _ = url.startAccessingSecurityScopedResource()
        bookmarks[url.path(percentEncoded: false)] = try url.bookmarkData(options: .withSecurityScope)
        try save()
    }

    /// Reclaims the sources `paths` names and forgets bookmarks nothing needs any more.
    func reopen(paths: Set<String>) {
        bookmarks = bookmarks.filter { paths.contains($0.key) }
        for (path, bookmark) in bookmarks where !claim(bookmark, expectedPath: path) {
            bookmarks[path] = nil
        }
        try? save()
    }

    /// False for a bookmark that no longer resolves to the file the queue recorded — a moved
    /// or deleted source, which the upload will report as unreadable.
    private func claim(_ bookmark: Data, expectedPath: String) -> Bool {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            bookmarkDataIsStale: &isStale
        ) else { return false }
        return url.path(percentEncoded: false) == expectedPath && url.startAccessingSecurityScopedResource()
    }

    private func save() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(bookmarks).write(to: fileURL, options: .atomic)
    }
}
#endif
