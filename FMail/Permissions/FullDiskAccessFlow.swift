import AppKit
import Foundation

enum FullDiskAccess {
    /// Heuristic: if we can list `~/Library/Mail`, we have FDA. Mail.app stores its
    /// data there and the directory is gated by FDA for non-Apple processes.
    /// Returns false if the directory doesn't exist (no Mail.app data) — caller
    /// should distinguish that case if needed.
    static func isGrantedHeuristic() -> Bool {
        let mailDir = URL(fileURLWithPath: ("~/Library/Mail" as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: mailDir.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        // Try to read directory contents — this is what TCC actually gates.
        return (try? FileManager.default.contentsOfDirectory(atPath: mailDir.path)) != nil
    }

    /// Opens the System Settings pane where the user can grant Full Disk Access
    /// to FMail. The URL scheme has shifted across macOS versions; we try the
    /// current Tahoe form first and fall back to the older form.
    static func openSystemSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
