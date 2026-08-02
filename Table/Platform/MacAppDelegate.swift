#if os(macOS)
import AppKit

/// The things the system says before there is any window to say them to: the app launched, files
/// were dropped on its Dock icon, and Finder's Services menu sent a selection (DESIGN §4).
///
/// All have to be answered whether or not a scene ever appears — a login-item launch may show
/// nothing but the menu bar extra — so this goes to the model directly.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        appModel.start()
        NSApplication.shared.servicesProvider = services
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        appModel.add(urls)
    }
}
#endif
