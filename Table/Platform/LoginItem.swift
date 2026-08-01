#if os(macOS)
import ServiceManagement

/// DESIGN §4: opening at login is optional, and it is what keeps the menu bar extra there
/// without the user launching the app.
struct LoginItem {
    /// `SMAppService` is the registration itself, so there is nothing of ours to persist.
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
#endif
