import SwiftUI

#if os(macOS)
/// The window the menu bar extra reopens when the user closed it (DESIGN §4).
let mainWindowID = "table"
#endif

@main
struct TableApp: App {
    private let model = appModel

    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        #if os(macOS)
        WindowGroup(id: mainWindowID) {
            MainView().environment(model)
        }
        .defaultSize(width: 520, height: 640)

        Settings {
            SettingsView().environment(model)
        }

        MenuBarExtra("table", systemImage: "tray.and.arrow.down") {
            MenuBarView().environment(model)
        }
        .menuBarExtraStyle(.window)
        #else
        WindowGroup {
            MainView().environment(model)
        }
        // DESIGN §6: the system relaunches the app for its finished background transfers, and
        // this is where they turn into verified, acked, published files.
        .backgroundTask(.urlSession(backgroundSessionIdentifier)) {
            await model.completeBackgroundTransfers()
        }
        #endif
    }
}
