import AppKit

/// Menu-bar-only lifecycle. The app runs as an accessory (no Dock icon, no
/// main window) — the entire UI is the `NSStatusItem` drop-down owned by
/// `StatusItemController`. The SwiftUI `Settings` scene is the one window,
/// opened on demand from the menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Shared with the `Settings` scene via the delegate adaptor so the
    /// settings window reads the same model the menu drives.
    let model = MailModel()
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusController = StatusItemController(model: model)
        Task { await model.boot() }
    }
}
