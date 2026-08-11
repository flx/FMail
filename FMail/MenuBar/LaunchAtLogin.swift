import ServiceManagement

/// Launch-at-login registration via `SMAppService.mainApp` (macOS 13+).
///
/// Registration ties the login item to the app bundle's current on-disk
/// location — moving FMail.app afterwards breaks the login launch until the
/// toggle is flipped off and on again from the new location.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// The user disabled FMail under System Settings → General → Login Items;
    /// registration stays pending until they re-enable it there.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Returns `false` when the service call itself failed (the toggle should
    /// snap back to `isEnabled` in that case).
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("LaunchAtLogin: \(enabled ? "register" : "unregister") failed: \(error)")
            return false
        }
    }
}
