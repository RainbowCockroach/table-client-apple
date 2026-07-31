import Foundation
import TableCore

/// Every location the app writes to, in one place.
///
/// iOS: the container is the app group's, so the share extension appends to the same queue
/// (DESIGN §4). macOS has no extension and keeps its own.
struct AppPaths {
    let container: ContainerPaths
    let publishDirectory: URL

    init() throws {
        #if os(macOS)
        container = ContainerPaths(
            root: try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "table")
        )
        publishDirectory = try FileManager.default
            .url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        #else
        container = try ContainerPaths.appGroup()
        publishDirectory = try FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        #endif
        try container.create()
    }
}
