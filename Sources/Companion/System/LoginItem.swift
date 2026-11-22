import ServiceManagement

@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// returns the resulting state (unchanged when registration fails, e.g. outside an app bundle).
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            AppLog.app.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
        return isEnabled
    }
}
