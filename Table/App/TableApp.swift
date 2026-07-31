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
        #endif
    }
}
