import ServiceManagement

/// Opens Notch+ when you log in, through the system's own Login Items (nothing is installed behind your back).
enum LoginItem {
    enum State: Equatable {
        case on
        case off
        /// Registered, but macOS wants you to allow it in System Settings > General > Login Items.
        case needsApproval
    }

    static func state(for status: SMAppService.Status) -> State {
        switch status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        case .notRegistered, .notFound: .off      // an app that was never registered reports "not found"; it can still be switched on
        @unknown default: .off
        }
    }

    static var state: State { state(for: SMAppService.mainApp.status) }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    static func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
