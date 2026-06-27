import Foundation

/// Boolean tree of search conditions.
indirect enum QueryNode: Equatable {
    case and([QueryNode])
    case or([QueryNode])
    case not(QueryNode)
    case term(Term)
    case empty
}

/// Atomic search predicates. Some compile to FTS5 MATCH terms, others to
/// auxiliary SQL conditions on the `messages` table.
enum Term: Equatable {
    /// Bag-of-words matched in any indexed FTS column.
    case anyText(String)
    /// Multi-word phrase matched in any column.
    case phrase(String)

    /// Single-word value matched in a specific FTS column.
    case fromAddr(String)
    case toAddr(String)
    case ccAddr(String)
    case subject(String)
    case body(String)
    case attachmentName(String)
    /// `attachment-type:pdf` — matches an attachment whose content-type
    /// contains the (lowercased) value as a substring (so `pdf` matches
    /// `application/pdf`, `image` matches `image/png`).
    case attachmentType(String)
    /// `attachment-size:>1mb` — matches a message with an attachment whose
    /// stored byte_count satisfies the comparison.
    case attachmentSize(SizeComparator, Int)

    case dateBefore(Date)
    case dateAfter(Date)
    /// Half-open range `[start, end)`. Used by `on:` and `during:`.
    case dateInRange(Date, Date)

    case isUnread, isRead, isFlagged, isUnflagged, hasAttachment, noAttachment
    case mailboxKind(String)        // in:inbox / in:sent / etc.
    case account(String)            // account:you@example.com or short prefix
    case thread(Int)                // thread:<id> — narrow to one conversation

    /// `from:me` / `to:me` / `cc:me` after owner-identity expansion (see
    /// `OwnerExpansion`). The associated value is the runtime owner-identity
    /// set — every address that identifies the mailbox's owner. Matched
    /// precisely against the structured `sender_address` / `recipients`
    /// columns (not FTS), so `from:me` can't over-match a stranger. An empty
    /// set compiles to match-nothing rather than match-everything.
    case ownerFrom([String])
    case ownerTo([String])
    case ownerCc([String])
    /// `in:sent` generalised: a `\Sent`-class mailbox OR mail authored by an
    /// owner identity. The owner-sender union is the provider-agnostic part —
    /// sent mail is authored by the owner regardless of which (possibly
    /// non-English, possibly flat-Gmail-label) folder holds it.
    case sentMailbox([String])

    /// Field we didn't recognize — pass through as bag-of-words on value
    /// so the user still gets results.
    case unknownField(name: String, value: String)
}

/// Comparison operator for `attachment-size:`. Maps directly to a SQL
/// comparison on `attachments.byte_count`.
enum SizeComparator: String, Equatable {
    case gt = ">"
    case gte = ">="
    case lt = "<"
    case lte = "<="
    case eq = "="

    var sql: String { rawValue }
}

/// Parse the value of an `attachment-size:` operator — an optional comparator
/// (`>`, `>=`, `<`, `<=`, `=`; default `>=`) followed by a number and an
/// optional unit (`b`, `k`/`kb`, `m`/`mb`, `g`/`gb`; default bytes; binary
/// 1024-based). Returns nil on anything unparseable so the parser can fall
/// back to an unknown-field bag-of-words match.
enum AttachmentSizeValue {
    static func parse(_ raw: String) -> (SizeComparator, Int)? {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }

        // Leading comparator (longest match first so ">=" beats ">").
        var comparator: SizeComparator = .gte
        for cmp in [SizeComparator.gte, .lte, .gt, .lt, .eq] where s.hasPrefix(cmp.rawValue) {
            comparator = cmp
            s.removeFirst(cmp.rawValue.count)
            break
        }
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        // Trailing unit.
        var multiplier = 1
        let units: [(String, Int)] = [
            ("gb", 1024 * 1024 * 1024), ("g", 1024 * 1024 * 1024),
            ("mb", 1024 * 1024), ("m", 1024 * 1024),
            ("kb", 1024), ("k", 1024),
            ("b", 1)
        ]
        for (suffix, mult) in units where s.hasSuffix(suffix) {
            multiplier = mult
            s.removeLast(suffix.count)
            break
        }
        s = s.trimmingCharacters(in: .whitespaces)

        // Accept an integer or a simple decimal (e.g. `1.5mb`).
        guard let value = Double(s), value >= 0 else { return nil }
        return (comparator, Int((value * Double(multiplier)).rounded()))
    }
}
