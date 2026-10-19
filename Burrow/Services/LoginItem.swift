import Foundation
import ServiceManagement
import os

/// "Open Burrow at login" via `SMAppService.mainApp` (macOS 13+). App-wide,
/// so it lives in Settings rather than with any one feature.
enum LoginItem {
    private static let logger = Logger(subsystem: "fun.burrow", category: "LoginItem")

    static var isSupported: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    /// Registered, including "waiting for the user's approval".
    static var isEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    /// Registers or unregisters; returns a message for the user when the
    /// change failed or still needs approval in System Settings.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        guard #available(macOS 13.0, *) else { return nil }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("Open at login failed: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
        if SMAppService.mainApp.status == .requiresApproval {
            return "Allow Burrow in System Settings → General → Login Items."
        }
        return nil
    }
}
