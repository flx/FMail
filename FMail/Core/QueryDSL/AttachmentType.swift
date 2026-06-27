import Foundation

/// Maps MIME content-types to a small set of curated, human-meaningful
/// attachment *families* (pdf, word, excel, archive, …) — and back. This is
/// the single source of truth shared by:
///   * the `fmail://schema` `attachment_types` enum (classify each content-type
///     present, list the distinct families), and
///   * the `attachment-type:` DSL operator (expand a family name to the
///     content-type substrings that identify it).
///
/// Generic across providers — no user- or mailbox-specific entries. Anything
/// unrecognised classifies as `other`; the schema lists only families that are
/// actually present.
enum AttachmentType {
    /// Ordered classification rules: `(family, identifying content-type
    /// substrings)`. First matching rule wins, so order matters where a type
    /// would satisfy two rules — e.g. `text/calendar` must reach `calendar`
    /// before the catch-all `text/`.
    private static let rules: [(family: String, tokens: [String])] = [
        ("pdf",          ["pdf"]),
        ("word",         ["msword", "wordprocessingml", "opendocument.text"]),
        ("excel",        ["ms-excel", "spreadsheetml", "opendocument.spreadsheet"]),
        ("presentation", ["ms-powerpoint", "presentationml", "opendocument.presentation"]),
        ("archive",      ["zip", "gzip", "7z", "rar", "x-tar", "bzip"]),
        ("calendar",     ["calendar"]),
        ("email",        ["rfc822", "message/"]),
        ("image",        ["image/"]),
        ("audio",        ["audio/"]),
        ("video",        ["video/"]),
        ("text",         ["text/"])
    ]

    /// Every family name, in stable order, including the `other` residual.
    static let families: [String] = rules.map(\.family) + ["other"]

    /// Classify one MIME content-type into exactly one family. Never returns a
    /// fragment of the type — unrecognised types map to `other`.
    static func family(for contentType: String) -> String {
        let ct = normalized(contentType)
        guard !ct.isEmpty else { return "other" }
        for rule in rules where rule.tokens.contains(where: { ct.contains($0) }) {
            return rule.family
        }
        return "other"
    }

    /// The content-type substrings that identify `family`, for expanding the
    /// `attachment-type:` operator. Empty for `other` or any non-family value —
    /// the operator then falls back to matching the literal value as a
    /// substring (power-user behaviour).
    static func likeTokens(forFamily family: String) -> [String] {
        rules.first { $0.family == family }?.tokens ?? []
    }

    /// Lowercase, drop any `; charset=…` parameter, trim.
    private static func normalized(_ raw: String) -> String {
        var ct = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if let semi = ct.firstIndex(of: ";") {
            ct = String(ct[..<semi]).trimmingCharacters(in: .whitespaces)
        }
        return ct
    }
}
