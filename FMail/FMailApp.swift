import AppKit
import SwiftUI

@main
struct FMailApp: App {
    /// Menu-bar-only build: the entire UI is the status-item drop-down built
    /// by `StatusItemController` (owned by `AppDelegate`). The only SwiftUI
    /// scene is `Settings`, opened on demand from the menu.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            MinimalSettingsView(model: appDelegate.model)
        }
    }
}
