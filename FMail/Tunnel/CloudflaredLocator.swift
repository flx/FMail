import Foundation

/// Locates the `cloudflared` binary. Looks first at the user override, then
/// at the two standard Homebrew install paths. We don't shell out to
/// `which` — Apple's TCC sandbox would block the resulting exec on a
/// signed/notarised build, and a small ordered list of well-known paths
/// covers every Homebrew install (`/opt/homebrew` on Apple Silicon,
/// `/usr/local` on Intel). The user override exists for the edge case of
/// a custom install or a non-Homebrew package.
enum CloudflaredLocator {
    /// Candidate absolute paths in priority order. The user override is
    /// only consulted when non-empty; otherwise the two Homebrew defaults.
    static func candidatePaths(override: String) -> [String] {
        var paths: [String] = []
        let trimmed = override.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            paths.append(trimmed)
        }
        paths.append("/opt/homebrew/bin/cloudflared")
        paths.append("/usr/local/bin/cloudflared")
        return paths
    }

    /// Returns the first candidate path that exists on disk and is
    /// executable, or nil if none match.
    static func locate(override: String, fileManager: FileManager = .default) -> String? {
        for path in candidatePaths(override: override) {
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// True when `~/.cloudflared/cert.pem` exists — the credential
    /// `cloudflared tunnel login` writes. Absence is a hard error for
    /// named tunnels (cloudflared refuses to start without it).
    static func isLoggedIn(fileManager: FileManager = .default) -> Bool {
        let path = NSHomeDirectory() + "/.cloudflared/cert.pem"
        return fileManager.fileExists(atPath: path)
    }
}
