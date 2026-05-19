import Foundation

/// Compiled query: a single WHERE-clause SQL boolean expression on `messages m`.
/// Text predicates compile to `m.apple_rowid IN (SELECT rowid FROM messages_fts WHERE messages_fts MATCH ?)`
/// subqueries; date / flag / scope predicates compile to direct SQL conditions
/// on `m.*`. AND / OR / NOT all compose via native SQL boolean operators.
///
/// As an optimization, *pure-text* subtrees (no date/flag/scope) collapse into
/// a single FTS5 MATCH expression — FTS5 has its own AND / OR / NOT — so a
/// query like `from:kyoko OR from:meiko` becomes one MATCH subquery, not two.
struct CompiledQuery {
    /// SQL boolean expression, suitable as a WHERE clause body.
    let whereClause: String
    /// Bindings in WHERE-order. Mix of text (FTS expressions) and integers.
    let bindings: [SQLBinding]
    /// Human-readable reconstruction shown in the "Interpreted as" strip.
    let interpretation: String

    var hasAnyConstraint: Bool { !whereClause.isEmpty }
}

enum SQLBinding {
    case int(Int64)
    case text(String)
}

enum Evaluator {
    static func compile(_ node: QueryNode) -> CompiledQuery {
        let compiled = compileNode(node)
        let interpretation = humanize(node)
        switch compiled {
        case .empty:
            return CompiledQuery(whereClause: "", bindings: [], interpretation: interpretation)
        case .text(let expr):
            // Top-level pure-text query: wrap in a single MATCH subquery.
            return CompiledQuery(
                whereClause: ftsSubquery(positive: true),
                bindings: [.text(expr)],
                interpretation: interpretation
            )
        case .sql(let frag, let bs):
            return CompiledQuery(whereClause: frag, bindings: bs, interpretation: interpretation)
        }
    }

    // MARK: — Internal compile output

    /// Result of compiling one AST node. `text` is an FTS5 expression that
    /// hasn't been wrapped in a MATCH subquery yet (so adjacent text-only
    /// subtrees can fuse into one MATCH). `sql` is a SQL fragment on `m.*`.
    private indirect enum Compiled {
        case empty
        case text(String)
        case sql(fragment: String, bindings: [SQLBinding])
    }

    private static func compileNode(_ node: QueryNode) -> Compiled {
        switch node {
        case .empty:
            return .empty
        case .term(let t):
            return compileTerm(t)
        case .not(let inner):
            return compileNOT(compileNode(inner))
        case .and(let children):
            return compileAND(children.map(compileNode))
        case .or(let children):
            return compileOR(children.map(compileNode))
        }
    }

    private static func compileTerm(_ term: Term) -> Compiled {
        switch term {
        case .anyText(let w):
            let safe = sanitize(w)
            guard !safe.isEmpty else { return .empty }
            return .text("\(safe)*")
        case .phrase(let p):
            let safe = sanitize(p)
            guard !safe.isEmpty else { return .empty }
            return .text("\"\(safe)\"")
        case .fromAddr(let v):
            return ftsField("sender", v)
        case .toAddr(let v):
            return ftsField("recipients", v)
        case .ccAddr(let v):
            return ftsField("recipients", v)
        case .subject(let v):
            return ftsField("subject", v)
        case .body(let v):
            return ftsField("body_text", v)
        case .attachmentName(let v):
            return ftsField("attachment_names", v)
        case .dateBefore(let d):
            return .sql(
                fragment: "m.date_received < ?",
                bindings: [.int(Int64(d.timeIntervalSince1970))]
            )
        case .dateAfter(let d):
            return .sql(
                fragment: "m.date_received >= ?",
                bindings: [.int(Int64(d.timeIntervalSince1970))]
            )
        case .dateInRange(let s, let e):
            return .sql(
                fragment: "(m.date_received >= ? AND m.date_received < ?)",
                bindings: [
                    .int(Int64(s.timeIntervalSince1970)),
                    .int(Int64(e.timeIntervalSince1970))
                ]
            )
        case .isUnread:
            return .sql(fragment: "m.is_read = 0", bindings: [])
        case .isRead:
            return .sql(fragment: "m.is_read = 1", bindings: [])
        case .isFlagged:
            return .sql(fragment: "m.is_flagged = 1", bindings: [])
        case .isUnflagged:
            return .sql(fragment: "m.is_flagged = 0", bindings: [])
        case .hasAttachment:
            return .sql(fragment: "m.has_attachment = 1", bindings: [])
        case .noAttachment:
            return .sql(fragment: "m.has_attachment = 0", bindings: [])
        case .mailboxKind(let kind):
            return .sql(
                fragment: "m.mailbox_rowid IN (SELECT apple_rowid FROM mailboxes WHERE kind = ?)",
                bindings: [.text(kind)]
            )
        case .account(let acc):
            return .sql(
                fragment: "m.account_uuid IN (SELECT uuid FROM accounts WHERE email_address = ? OR uuid LIKE ?)",
                bindings: [.text(acc), .text("\(acc)%")]
            )
        case .unknownField(_, let value):
            // Surface unknown fields as bag-of-words so the user still gets
            // results — matches the original behavior.
            let safe = sanitize(value)
            guard !safe.isEmpty else { return .empty }
            return .text("\(safe)*")
        }
    }

    private static func ftsField(_ column: String, _ value: String) -> Compiled {
        let safe = sanitize(value)
        guard !safe.isEmpty else { return .empty }
        return .text("{\(column)}: \(safe)*")
    }

    // MARK: — Combinators

    private static func compileAND(_ items: [Compiled]) -> Compiled {
        let nonEmpty = filterEmpties(items)
        guard !nonEmpty.isEmpty else { return .empty }
        if nonEmpty.count == 1 { return nonEmpty[0] }

        // Fast path: all-text → fuse into one FTS expression. Use explicit
        // AND: FTS5's implicit-AND grammar breaks when an operand is a
        // parenthesized subexpression (e.g. `(a OR b) {col}: c*` is a syntax
        // error, but `(a OR b) AND {col}: c*` parses fine).
        if let texts = allText(nonEmpty) {
            return .text(texts.joined(separator: " AND "))
        }

        // Mixed: convert each branch to SQL form, AND them.
        var fragments: [String] = []
        var allBindings: [SQLBinding] = []
        for item in nonEmpty {
            let (f, b) = sqlForm(of: item)
            fragments.append("(\(f))")
            allBindings.append(contentsOf: b)
        }
        return .sql(fragment: fragments.joined(separator: " AND "), bindings: allBindings)
    }

    private static func compileOR(_ items: [Compiled]) -> Compiled {
        let nonEmpty = filterEmpties(items)
        guard !nonEmpty.isEmpty else { return .empty }
        if nonEmpty.count == 1 { return nonEmpty[0] }

        // Fast path: all-text → fuse into one FTS expression with explicit OR.
        // Wrap in parens because FTS5's NOT > AND > OR precedence would
        // otherwise let an outer AND bind tighter than this OR.
        if let texts = allText(nonEmpty) {
            return .text("(" + texts.joined(separator: " OR ") + ")")
        }

        // Mixed: convert each branch to SQL form, OR them.
        var fragments: [String] = []
        var allBindings: [SQLBinding] = []
        for item in nonEmpty {
            let (f, b) = sqlForm(of: item)
            fragments.append("(\(f))")
            allBindings.append(contentsOf: b)
        }
        return .sql(fragment: fragments.joined(separator: " OR "), bindings: allBindings)
    }

    private static func compileNOT(_ item: Compiled) -> Compiled {
        switch item {
        case .empty:
            return .empty
        case .text(let expr):
            // FTS5 has only binary NOT (`a NOT b`), no unary form, so we
            // negate text predicates by lifting them into a `NOT IN (subquery)`.
            return .sql(fragment: ftsSubquery(positive: false), bindings: [.text(expr)])
        case .sql(let f, let b):
            return .sql(fragment: "NOT (\(f))", bindings: b)
        }
    }

    /// Convert any Compiled to its SQL-fragment form. Text predicates wrap
    /// into a MATCH subquery; SQL predicates pass through; empty becomes
    /// the always-true literal so it doesn't break boolean composition.
    private static func sqlForm(of item: Compiled) -> (String, [SQLBinding]) {
        switch item {
        case .empty:
            return ("1", [])
        case .text(let expr):
            return (ftsSubquery(positive: true), [.text(expr)])
        case .sql(let f, let b):
            return (f, b)
        }
    }

    private static func ftsSubquery(positive: Bool) -> String {
        let op = positive ? "IN" : "NOT IN"
        return "m.apple_rowid \(op) (SELECT rowid FROM messages_fts WHERE messages_fts MATCH ?)"
    }

    // MARK: — Helpers

    private static func filterEmpties(_ items: [Compiled]) -> [Compiled] {
        items.filter {
            if case .empty = $0 { return false }
            return true
        }
    }

    /// Returns the text expressions if every item is `.text`, else nil.
    private static func allText(_ items: [Compiled]) -> [String]? {
        var out: [String] = []
        out.reserveCapacity(items.count)
        for item in items {
            guard case .text(let s) = item else { return nil }
            out.append(s)
        }
        return out
    }

    /// Strip characters that confuse the FTS5 query parser. Matches the
    /// original sanitization rules.
    private static func sanitize(_ s: String) -> String {
        var out = ""
        for ch in s where !"\"():*-".contains(ch) {
            out.append(ch)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: — Human-readable reconstruction

    private static func humanize(_ node: QueryNode) -> String {
        switch node {
        case .empty:
            return ""
        case .term(let t):
            return humanTerm(t, negate: false)
        case .not(let inner):
            if case .term(let t) = inner {
                return humanTerm(t, negate: true)
            }
            let s = humanize(inner)
            return s.isEmpty ? "" : "-(\(s))"
        case .and(let children):
            return children.map(humanize).filter { !$0.isEmpty }.joined(separator: " ")
        case .or(let children):
            let parts = children.map(humanize).filter { !$0.isEmpty }
            if parts.isEmpty { return "" }
            if parts.count == 1 { return parts[0] }
            return "(" + parts.joined(separator: " OR ") + ")"
        }
    }

    private static func humanTerm(_ term: Term, negate: Bool) -> String {
        let pre = negate ? "-" : ""
        switch term {
        case .anyText(let w):
            return pre + w
        case .phrase(let p):
            return "\(pre)\"\(p)\""
        case .fromAddr(let v): return "\(pre)from:\(quoteIfNeeded(v))"
        case .toAddr(let v):   return "\(pre)to:\(quoteIfNeeded(v))"
        case .ccAddr(let v):   return "\(pre)cc:\(quoteIfNeeded(v))"
        case .subject(let v):  return "\(pre)subject:\(quoteIfNeeded(v))"
        case .body(let v):     return "\(pre)body:\(quoteIfNeeded(v))"
        case .attachmentName(let v): return "\(pre)attachment:\(quoteIfNeeded(v))"
        case .dateBefore(let d): return "\(pre)before:\(iso(d))"
        case .dateAfter(let d):  return "\(pre)after:\(iso(d))"
        case .dateInRange(let s, let e):
            let cal = Calendar.current
            let endInclusive = cal.date(byAdding: .day, value: -1, to: e) ?? e
            let label = cal.isDate(s, inSameDayAs: endInclusive)
                ? iso(s)
                : "\(iso(s))..\(iso(endInclusive))"
            return "\(pre)during:\(label)"
        case .isUnread:    return "\(pre)unread"
        case .isRead:      return "\(pre)read"
        case .isFlagged:   return "\(pre)flagged"
        case .isUnflagged: return "\(pre)unflagged"
        case .hasAttachment: return "\(pre)has:attachment"
        case .noAttachment:  return "\(pre)has:no attachment"
        case .mailboxKind(let kind): return "\(pre)in:\(kind)"
        case .account(let acc):      return "\(pre)account:\(quoteIfNeeded(acc))"
        case .unknownField(let name, let value): return "\(pre)\(name)?:\(quoteIfNeeded(value))"
        }
    }

    private static func quoteIfNeeded(_ s: String) -> String {
        s.contains(" ") ? "\"\(s)\"" : s
    }

    private static func iso(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
