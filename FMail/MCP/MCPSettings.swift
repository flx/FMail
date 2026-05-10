import Foundation

/// User-facing toggles for the MCP server. Backed by `UserDefaults.standard`.
/// Off by default — the server reads every email so the user has to opt in
/// explicitly.
enum MCPSettings {
    static let enabledKey = "mcp_enabled"
    static let portKey = "mcp_port"
    static let defaultPort: Int = 8765

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// 1–65535. Returns `defaultPort` when unset or out of range.
    static var port: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: portKey)
            return (v >= 1 && v <= 65535) ? v : defaultPort
        }
        set {
            let clamped = max(1, min(65535, newValue))
            UserDefaults.standard.set(clamped, forKey: portKey)
        }
    }
}
