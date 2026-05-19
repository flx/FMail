import Foundation

/// Pure functions that extract state signals from `cloudflared` log output.
/// Kept separate from `TunnelCoordinator` so they're easy to unit-test
/// against captured real-world log samples.
enum CloudflaredLogParser {

    /// True when `chunk` contains the substring cloudflared emits once an
    /// edge connection has been registered. cloudflared has shifted phrasing
    /// between versions; we accept the union of seen forms.
    ///
    /// Real samples (2024+ builds):
    ///   `INF Registered tunnel connection connIndex=0 ...`
    ///   `INF Registered connection connIndex=0 ...`
    static func didRegisterConnection(in chunk: String) -> Bool {
        let lower = chunk.lowercased()
        return lower.contains("registered tunnel connection")
            || lower.contains("registered connection")
    }

    /// Extracts the public URL printed by a *quick* tunnel
    /// (`cloudflared tunnel --url …`). Matches the
    /// `https://*.trycloudflare.com` host. Returned for completeness /
    /// dev use; the UI doesn't currently expose quick tunnels.
    static func extractQuickTunnelURL(in chunk: String) -> URL? {
        guard let range = chunk.range(of: #"https://[a-z0-9-]+\.trycloudflare\.com"#, options: .regularExpression) else {
            return nil
        }
        return URL(string: String(chunk[range]))
    }

    /// True when cloudflared has logged a fatal error early in startup —
    /// e.g. missing tunnel name, bad credentials. Used to short-circuit
    /// the "wait for ready" timer rather than waiting the full 15s.
    static func didFailEarly(in chunk: String) -> Bool {
        let lower = chunk.lowercased()
        // Common cloudflared error preambles:
        //   `ERR Couldn't start tunnel ...`
        //   `failed to ...` (during arg validation, before structured logging)
        //   `tunnel credentials file ... doesn't exist`
        return lower.contains("err couldn't start tunnel")
            || lower.contains("tunnel credentials file")
            || lower.contains("error parsing")
            // cloudflared's "not logged in" diagnostic always references
            // the login subcommand in the resolution text.
            || lower.contains("cloudflared tunnel login")
    }
}
