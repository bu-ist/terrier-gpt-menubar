import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` for Launch at Login.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Human-readable guidance when registration needs user action or is unavailable.
    static var statusMessage: String? {
        switch SMAppService.mainApp.status {
        case .requiresApproval:
            return "Approve TerrierGPT under System Settings → General → Login Items & Extensions."
        case .notFound:
            return "Launch at Login works after the app is installed (e.g. in Applications)."
        default:
            return nil
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }
}
