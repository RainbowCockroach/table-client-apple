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
        try excludeFromBackup(container)
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

    /// iOS: the copies an upload reads from. A background upload is sent by another process
    /// from a file, which is why a picked document is copied in rather than read where it lies.
    var stagedUploads: URL {
        container.appending(path: "uploads")
    }

    /// iOS: where a background upload's resume slice is materialized (DESIGN §2).
    var uploadSlices: URL {
        container.appending(path: "slices")
    }
}

/// Everything under the container is a transfer in flight; none of it should come back on a
/// restored device.
private func excludeFromBackup(_ directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var excluded = directory
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try excluded.setResourceValues(values)
}
