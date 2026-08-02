#if os(macOS)
import AppKit

/// Finder's Services menu entry, declared as `NSServices` in `Info-macOS.plist` (DESIGN §4).
///
/// The selection arrives on a pasteboard instead of through `application(_:open:)`, but it is the
/// user's own pick either way, so it takes the same intake — bookmark and all — as a drop.
final class ServicesProvider: NSObject {
    @objc func putOnTheTable(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "Nothing to put on the table." as NSString
            return
        }
        appModel.add(urls)
    }
}
#endif
