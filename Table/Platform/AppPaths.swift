import Foundation

/// Every location the app writes to, in one place.
///
/// C4 moves the container into the app group so the share extension appends to the same
/// queue; that is a change to `container` alone.
struct AppPaths {
    let container: URL
    let publishDirectory: URL

    init() throws {
        container = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "table")
        #if os(macOS)
        publishDirectory = try FileManager.default
            .url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        #else
        publishDirectory = try FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        #endif
    }

    var queueDatabase: URL {
        container.appending(path: "queue.sqlite")
    }

    /// Conformance rule 4: downloads stream here, never straight into `publishDirectory`.
    var partialDownloads: URL {
        container.appending(path: "downloads")
    }

    var sourceBookmarks: URL {
        container.appending(path: "sources.json")
    }
}
