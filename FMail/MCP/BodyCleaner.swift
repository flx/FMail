import Foundation

/// Aggressive plain-text cleaner for `get_thread` / `get_email`'s
/// `body_format: "clean"` mode. Designed for the LLM-consumer case:
/// when an MCP client pulls a long thread, every message arrives with
/// the full quoted-reply chain of all prior messages plus several KB
/// of legal-disclaimer boilerplate. Sending that 21x is a lot of
/// context-window tax for very little additional signal.
///
/// What this does, in order:
///   1. Truncate at the first reply-chain marker (`On <date> ... wrote:`,
///      `-----Original Message-----`, classic Outlook `From: ...` quoted
///      header block).
///   2. Truncate at the first signature marker (`-- ` line, `Sent from
///      my iPhone/iPad`, `Get Outlook for iOS` link).
///   3. Collapse known tracking-URL wrappers (Mimecast cybergraph,
///      Outlook safelinks, Google AMP) to short tokens — they're long
///      and the underlying URL isn't useful to the LLM.
///   4. Collapse runs of blank lines.
///
/// Heuristic by design. The fallback is always to return `plain` mode
/// (the original `HTMLStripper` output) — clients can compare if they
/// suspect content was lost.
enum BodyCleaner {

    /// Apply all cleaning passes. Returns the cleaned text.
    static func clean(_ text: String) -> String {
        split(text).clean
    }

    /// Split a body into the part worth ranking (`clean`) and the
    /// reply-chain / signature tail that was stripped off (`quoted`). The
    /// cut point is the first line that is either a reply-chain marker or a
    /// signature delimiter — the same boundary `clean(_:)` used to truncate
    /// at, so `split(text).clean` reproduces the old `clean(text)` output
    /// exactly. The body indexer stores both halves: `clean` as the primary
    /// ranking column, `quoted` as a near-zero-weight column kept for recall
    /// (so the offending quoted signature in the eBay/FT failure mode is still
    /// searchable but can't dominate BM25).
    static func split(_ text: String) -> (clean: String, quoted: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var cut: Int?
        for (i, line) in lines.enumerated() {
            if isReplyChainMarker(line, peekNext: lines[safe: i + 1]) || isSignatureMarker(line) {
                cut = i
                break
            }
        }
        guard let cut else {
            return (postProcess(text), "")
        }
        let cleanRaw = lines.prefix(cut).joined(separator: "\n")
        let quotedRaw = lines.suffix(from: cut).joined(separator: "\n")
        return (postProcess(cleanRaw), quotedRaw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The cosmetic passes `clean(_:)` applied after truncation: collapse
    /// tracking-URL wrappers and runs of blank lines, then trim.
    private static func postProcess(_ text: String) -> String {
        var working = collapseTrackingURLs(text)
        working = collapseBlankLines(working)
        return working.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: — Reply-chain detection

    private static func isReplyChainMarker(_ line: String, peekNext: String?) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Apple Mail / many clients: "On <date>, <person> <addr> wrote:"
        // (with or without leading `> `, since quoted blocks repeat it).
        if trimmed.hasSuffix("wrote:") {
            let stripped = trimmed.drop(while: { $0 == ">" }).trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("On ") || stripped.hasPrefix("On,") {
                return true
            }
        }
        // Outlook desktop / Windows Mail: literal banner
        if trimmed == "-----Original Message-----" { return true }
        // Outlook web / Office365: bold "From: ..." with following To/Date/Subject
        // headers. Heuristic — only treat as a marker if the next line is also
        // a header-style "Sent:" / "To:" / "Date:" / "Subject:" line.
        if trimmed.hasPrefix("From:"), let next = peekNext?.trimmingCharacters(in: .whitespaces) {
            let nextHeaders = ["Sent:", "Date:", "To:", "Subject:", "Cc:"]
            if nextHeaders.contains(where: { next.hasPrefix($0) }) {
                return true
            }
        }
        return false
    }

    // MARK: — Signature detection

    private static func isSignatureMarker(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // RFC 3676 §4.3 signature delimiter — literally `-- ` (two
        // dashes + space). HTML→plain strippers often drop the trailing
        // space, so accept the dash-only form too.
        if trimmed == "--" || trimmed == "—" { return true }
        // Common mobile / web-mail auto-signatures.
        let mobile: Set<String> = [
            "Sent from my iPhone",
            "Sent from my iPad",
            "Sent from my Android",
            "Get Outlook for iOS",
            "Get Outlook for Android"
        ]
        if mobile.contains(trimmed) { return true }
        return false
    }

    // MARK: — Tracking-URL collapse

    private static func collapseTrackingURLs(_ text: String) -> String {
        var out = text
        let rules: [(pattern: String, replacement: String)] = [
            // Mimecast cybergraph rewrites — pages of opaque-looking URL.
            (#"https?://[a-z0-9-]*\.mimecastcybergraph\.com/\S+"#, "[mimecast-link]"),
            // Outlook ATP safelinks — wraps every external URL with a tracker.
            (#"https?://[a-z0-9-]+\.safelinks\.protection\.outlook\.com/\?[^\s]+"#, "[safelink]"),
            // Google AMP cache redirect.
            (#"https?://www\.google\.com/amp/s/\S+"#, "[google-amp-link]"),
            // Generic "really long URL" — anything 250+ chars without a
            // space is probably a tracker, not a useful link. Tune cautiously.
            (#"https?://\S{250,}"#, "[long-link]")
        ]
        for rule in rules {
            out = out.replacingOccurrences(
                of: rule.pattern,
                with: rule.replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return out
    }

    // MARK: — Blank-line collapse

    private static func collapseBlankLines(_ text: String) -> String {
        // 3+ consecutive newlines → 2. Keeps paragraph breaks intact but
        // squashes the multi-paragraph empty-line drift signatures leave.
        text.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
