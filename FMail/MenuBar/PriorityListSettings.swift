import Foundation

/// Hand-edited supplementary senders for the menu's "Priority Messages" block.
/// Backed by `UserDefaults.standard`.
///
/// A message is *priority* when its sender is either someone you've emailed
/// (derived automatically from your sent mail — see `IndexDB.sentToAddresses`)
/// **or** one of these addresses. This list is for senders you want surfaced
/// even though you've never written to them (a landlord's no-reply address, a
/// service you only ever receive from, …).
enum PriorityListSettings {
    static let supplementalKey = "priority.supplemental.addresses"

    /// The user's hand-edited addresses, trimmed and non-empty, in entry order.
    static var supplementalAddresses: [String] {
        get { UserDefaults.standard.stringArray(forKey: supplementalKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: supplementalKey) }
    }

    /// Parse a free-text value (addresses or `*wildcard*` patterns separated by
    /// `;`, `,` or newlines) into clean, de-duplicated entries. Order preserved;
    /// case as typed (matching is case-insensitive downstream).
    static func parse(_ text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for token in text.split(whereSeparator: { $0 == "\n" || $0 == "," || $0 == ";" }) {
            let entry = token.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }
            if seen.insert(entry.lowercased()).inserted { out.append(entry) }
        }
        return out
    }

    /// Append `additions` to the stored list, de-duplicated (case-insensitive),
    /// and return the new list.
    @discardableResult
    static func add(_ additions: [String]) -> [String] {
        var seen = Set(supplementalAddresses.map { $0.lowercased() })
        var out = supplementalAddresses
        for entry in additions where seen.insert(entry.lowercased()).inserted {
            out.append(entry)
        }
        supplementalAddresses = out
        return out
    }

    /// Remove `entry` (case-insensitive) and return the new list.
    @discardableResult
    static func remove(_ entry: String) -> [String] {
        let out = supplementalAddresses.filter { $0.lowercased() != entry.lowercased() }
        supplementalAddresses = out
        return out
    }

    /// How a supplemental entry is matched against a sender address.
    enum Match: Equatable {
        case exact(String)   // a full address — matched literally
        case glob(String)    // a GLOB pattern — matched with SQLite GLOB
    }

    /// Interpret a raw entry (all lowercased; matching is case-insensitive):
    ///   - contains `*` / `?`            → a GLOB pattern, used verbatim
    ///   - a full address `local@dom.tld` → exact match
    ///   - anything else (a bare word or a domain like `vendor`, `vendor.com`)
    ///     → substring match, i.e. GLOB `*entry*`
    ///
    /// The substring fallback is the forgiving bit: typing `vendor` matches
    /// every `…@vendor.com` / `…@mail.vendor.com` address without the user
    /// having to remember the `*…*` syntax.
    static func classify(_ entry: String) -> Match {
        let e = entry.trimmingCharacters(in: .whitespaces).lowercased()
        if e.contains("*") || e.contains("?") { return .glob(e) }
        if isFullAddress(e) { return .exact(e) }
        return .glob("*\(e)*")
    }

    /// `local@domain.tld` — exactly one `@`, non-empty local part, dotted domain.
    private static func isFullAddress(_ e: String) -> Bool {
        let parts = e.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let (local, domain) = (parts[0], parts[1])
        return !local.isEmpty && domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    /// Whether this entry matches more than one exact address — drives the
    /// settings row's icon.
    static func isPattern(_ entry: String) -> Bool {
        if case .glob = classify(entry) { return true }
        return false
    }

    /// The hand-edited entries that currently put `address` into Priority — an
    /// exact entry equal to it, or a wildcard/substring entry whose pattern
    /// matches it. Order preserved; case-insensitive. Drives the menu's
    /// per-message "Remove … from Priority Mail" commands: one per matching
    /// entry, each shown verbatim, so a wildcard reads e.g. "*savills.com".
    ///
    /// Mirrors the SQLite `GLOB` membership test the index runs to build the
    /// Priority/Other split (see `IndexDB.priorityMembership`), so the entry a
    /// menu offers to remove is the same one that landed the message there.
    static func entriesMatching(_ address: String) -> [String] {
        let addr = address.trimmingCharacters(in: .whitespaces).lowercased()
        guard !addr.isEmpty else { return [] }
        return supplementalAddresses.filter { entry in
            switch classify(entry) {
            case .exact(let e):   return e == addr
            case .glob(let pat):  return globMatch(pat, addr)
            }
        }
    }

    /// Minimal GLOB matcher for the `*` (any run, incl. empty) and `?` (one
    /// char) wildcards — enough to mirror SQLite `GLOB` for the patterns we
    /// generate (`*vendor*`, `*@vendor.com`, …). Both arguments are already
    /// lowercased by the caller, so matching is effectively case-insensitive.
    /// Character classes (`[…]`) aren't handled; they don't occur in practice,
    /// and the only cost is such an entry not being offered for removal here.
    private static func globMatch(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern), t = Array(text)
        var pi = 0, ti = 0
        var star = -1, mark = 0        // last `*` position and the text index it began at
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1; ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = ti; pi += 1
            } else if star != -1 {
                pi = star + 1; mark += 1; ti = mark   // backtrack: let `*` swallow one more char
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
