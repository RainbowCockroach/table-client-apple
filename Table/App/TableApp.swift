import SwiftUI

@main
struct TableApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            MainView().environment(model)
        }
        .defaultSize(width: 520, height: 640)

        Settings {
            SettingsView().environment(model)
        }
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
