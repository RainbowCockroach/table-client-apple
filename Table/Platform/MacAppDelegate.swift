#if os(macOS)
import AppKit

/// The two things the system says before there is any window to say them to: the app launched,
/// and files were dropped on its Dock icon (DESIGN §4).
///
/// Both have to be answered whether or not a scene ever appears — a login-item launch may show
/// nothing but the menu bar extra — so this goes to the model directly.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        appModel.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        appModel.add(urls)
    }
}
#endif
