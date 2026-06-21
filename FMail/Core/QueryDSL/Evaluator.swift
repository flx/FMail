import Foundation

/// Compiled query: a single WHERE-clause SQL boolean expression on `messages m`.
/// Text predicates compile to `m.apple_rowid IN (SELECT rowid FROM messages_fts WHERE messages_fts MATCH ?)`
/// subqueries; date / flag / scope predicates compile to direct SQL conditions
/// on `m.*`. AND / OR / NOT all compose via native SQL boolean operators.
///
/// As an optimization, *pure-text* subtrees (no date/flag/scope) collapse into
/// a single FTS5 MATCH expression — FTS5 has its own AND / OR / NOT — so a
/// query like `from:alice OR from:bob` becomes one MATCH subquery, not two.
struct CompiledQuery {
    /// SQL boolean expression, suitable as a WHERE clause body.
    let whereClause: String
    /// Bindings in WHERE-order. Mix of text (FTS expressions) and integers.
    let bindings: [SQLBinding]
    /// Human-readable reconstruction shown in the "Interpreted as" strip.
    let interpretation: String
    /// Non-nil when the query can be reshaped for BM25 ranking / snippets —
    /// i.e. it reduces to a single positive FTS5 MATCH plus an FTS-free
    /// residual predicate. nil for metadata-only queries (no text to rank)
    /// and for shapes that straddle the MATCH/SQL boundary (negated text,
    /// text OR-ed with a date/flag). See `Evaluator.relevancePlan`.
    let relevancePlan: RelevancePlan?

    var hasAnyConstraint: Bool { !whereClause.isEmpty }
}

/// A query reshaped for `IndexDB.searchRanked` — a single positive FTS5
/// MATCH expression plus an optional FTS-free residual predicate on `m.*`.
/// This is what lets `bm25()` / `snippet()` run against `messages_fts`
/// directly (a JOIN), instead of the `apple_rowid IN (SELECT …)` subquery
/// shape that hides the FTS table from the outer query.
struct RelevancePlan: Sendable {
    /// The fused FTS5 MATCH expression — bound as the single `?` immediately
    /// after `messages_fts MATCH`.
    let ftsMatch: String
    /// FTS-free SQL predicate on `m.*`, ANDed after the MATCH. nil when the
    /// query is pure text.
    let residualSQL: String?
    /// Bindings for `residualSQL`, in order. Empty when `residualSQL` is nil.
    let residualBindings: [SQLBinding]
    /// An FTS5 `NEAR()` MATCH expression over the high-value columns
    /// (`{subject body_clean}`), built from the query's free-text tokens when
    /// there are ≥2 of them. The ranker adds a fixed bonus to rows that also
    /// match this — terms clustering in real body/subject text signals an
    /// on-topic message, and scoping it away from `body_quoted` keeps a quoted
    /// signature from earning the boost. nil when the query has <2 free-text
    /// tokens (nothing to measure proximity between).
    let proximityMatch: String?

    init(ftsMatch: String, residualSQL: String?, residualBindings: [SQLBinding], proximityMatch: String? = nil) {
        self.ftsMatch = ftsMatch
        self.residualSQL = residualSQL
        self.residualBindings = residualBindings
        self.proximityMatch = proximityMatch
    }
}

/// Tunable knobs for `IndexDB.searchRanked`'s `.relevance` ordering. The
/// column weights feed `bm25()` positionally in `messages_fts` column order
/// (subject, body_clean, body_quoted, sender, recipients, attachment_names);
/// the rest shape the blended final score:
///
///   final = (bm25_normalized * bulkMultiplier)
///         + lambda * exp(-age_days / tauDays)
///         + proximityBoost * [row also matches NEAR()]
///
/// `bm25_normalized` divides the negated BM25 (higher = better) by the top
/// score in the matched set, so `lambda` / `proximityBoost` live on a
/// comparable 0…1 scale. `.default` is what the MCP tool uses out of the box;
/// `.textOnly` drops recency/proximity/bulk effects (pure weighted BM25); the
/// eval harness compares `.uniform` (every lever off — the old "all text
/// equal" behaviour) against `.default`.
struct RelevanceTuning: Sendable {
    var subjectWeight: Double = 10.0
    var bodyCleanWeight: Double = 5.0
    var bodyQuotedWeight: Double = 0.3
    var senderWeight: Double = 8.0
    var recipientsWeight: Double = 2.0
    var attachmentWeight: Double = 2.0

    /// Weight of the recency term in the blended score.
    var lambda: Double = 0.2
    /// Exponential-decay time constant for recency, in days.
    var tauDays: Double = 180.0
    /// Score multiplier applied to rows flagged `is_bulk`.
    var bulkMultiplier: Double = 0.3
    /// When false, bulk rows are hard-filtered out instead of just discounted.
    var includeBulk: Bool = true
    /// Bonus added to rows that match the plan's `NEAR()` proximity expression.
    var proximityBoost: Double = 0.15

    /// Column weights in `messages_fts` order — the argument list for `bm25()`.
    var columnWeights: [Double] {
        [subjectWeight, bodyCleanWeight, bodyQuotedWeight, senderWeight, recipientsWeight, attachmentWeight]
    }

    static let `default` = RelevanceTuning()

    /// Weighted BM25 only — no recency, proximity, or bulk discount.
    static let textOnly = RelevanceTuning(lambda: 0, bulkMultiplier: 1.0, proximityBoost: 0)

    /// Every lever neutralised: equal column weights, no recency / proximity /
    /// bulk discount. Reproduces the pre-overhaul "rank the raw blob, all text
    /// equal" behaviour for the eval harness's baseline.
    static let uniform = RelevanceTuning(
        subjectWeight: 1, bodyCleanWeight: 1, bodyQuotedWeight: 1,
        senderWeight: 1, recipientsWeight: 1, attachmentWeight: 1,
        lambda: 0, bulkMultiplier: 1.0, proximityBoost: 0
    )
}

enum SQLBinding: Sendable {
    case int(Int64)
    case text(String)
}

enum Evaluator {
    static func compile(_ node: QueryNode) -> CompiledQuery {
        let compiled = compileNode(node)
        let interpretation = humanize(node)
        let plan = relevancePlan(node)
        switch compiled {
        case .empty:
            return CompiledQuery(whereClause: "", bindings: [], interpretation: interpretation, relevancePlan: plan)
        case .text(let expr):
            // Top-level pure-text query: wrap in a single MATCH subquery.
            return CompiledQuery(
                whereClause: ftsSubquery(positive: true),
                bindings: [.text(expr)],
                interpretation: interpretation,
                relevancePlan: plan
            )
        case .sql(let frag, let bs):
            return CompiledQuery(whereClause: frag, bindings: bs, interpretation: interpretation, relevancePlan: plan)
        }
    }

    // MARK: — Relevance-plan extraction (BM25 / snippets)

    /// Reshape `node` into a `RelevancePlan` when it separates cleanly into a
    /// single positive FTS5 MATCH plus an FTS-free `m.*` residual. Returns nil
    /// when there's no text to rank, or when the boolean structure can't be
    /// expressed as `MATCH ? AND <sql>` — specifically:
    ///   * negated text (`NOT from:x`) — can't be the positive match,
    ///   * text OR-ed with a date/flag (`from:x OR after:2024`) — the OR
    ///     straddles the MATCH/SQL boundary.
    /// Callers fall back to `search()` (date order, no snippet) when nil.
    static func relevancePlan(_ node: QueryNode) -> RelevancePlan? {
        let ex = extract(node)
        guard ex.supported, let fts = ex.fts else { return nil }
        return RelevancePlan(
            ftsMatch: fts,
            residualSQL: ex.sql,
            residualBindings: ex.bindings,
            proximityMatch: proximityExpr(node)
        )
    }

    /// Build the `NEAR()` proximity expression for the ranker from the query's
    /// free-text tokens (barewords + phrases) in positive (non-negated)
    /// position. Returns nil with fewer than two tokens — proximity needs at
    /// least a pair to measure. Scoped to `{subject body_clean}` so a quoted
    /// signature in `body_quoted` can't earn the bonus.
    static func proximityExpr(_ node: QueryNode) -> String? {
        var tokens: [String] = []
        collectFreeText(node, negated: false, into: &tokens)
        guard tokens.count >= 2 else { return nil }
        return "{subject body_clean}: NEAR(\(tokens.joined(separator: " ")), 10)"
    }

    /// Collect the FTS forms of free-text terms (`anyText` → `tok*`, `phrase`
    /// → `"tok"`), skipping anything under a `NOT`. Field-scoped terms
    /// (`from:` / `subject:` / dates / flags) are ignored — proximity is a
    /// bag-of-topic-words signal.
    private static func collectFreeText(_ node: QueryNode, negated: Bool, into tokens: inout [String]) {
        switch node {
        case .empty:
            break
        case .not(let inner):
            collectFreeText(inner, negated: !negated, into: &tokens)
        case .and(let children), .or(let children):
            for c in children { collectFreeText(c, negated: negated, into: &tokens) }
        case .term(let t):
            guard !negated else { return }
            switch t {
            case .anyText(let w):
                let safe = sanitize(w)
                if !safe.isEmpty { tokens.append("\(safe)*") }
            case .phrase(let p):
                let safe = sanitize(p)
                if !safe.isEmpty { tokens.append("\"\(safe)\"") }
            default:
                break
            }
        }
    }

    /// Intermediate result of separating a subtree into its FTS part (a
    /// MATCH expression) and its FTS-free SQL part. `bindings` are for `sql`
    /// only — the `fts` string is embedded as the single MATCH bind value by
    /// the caller. `supported == false` marks a shape we won't rank.
    private struct Extraction {
        var fts: String?
        var sql: String?
        var bindings: [SQLBinding]
        var supported: Bool
        static let empty = Extraction(fts: nil, sql: nil, bindings: [], supported: true)
        static let unsupported = Extraction(fts: nil, sql: nil, bindings: [], supported: false)
    }

    private static func extract(_ node: QueryNode) -> Extraction {
        switch node {
        case .empty:
            return .empty
        case .term(let t):
            // `compileTerm` already maps text/field terms to `.text` (an FTS
            // expression) and everything else to `.sql` (always FTS-free at the
            // term level — FTS subqueries only appear via the combinators).
            switch compileTerm(t) {
            case .empty: return .empty
            case .text(let expr): return Extraction(fts: expr, sql: nil, bindings: [], supported: true)
            case .sql(let f, let b): return Extraction(fts: nil, sql: f, bindings: b, supported: true)
            }
        case .not(let inner):
            let e = extract(inner)
            if !e.supported { return .unsupported }
            if e.fts != nil { return .unsupported }            // can't negate the positive match
            if let sql = e.sql {
                return Extraction(fts: nil, sql: "NOT (\(sql))", bindings: e.bindings, supported: true)
            }
            return .empty
        case .and(let children):
            var ftsParts: [String] = []
            var sqlParts: [String] = []
            var binds: [SQLBinding] = []
            for c in children {
                let e = extract(c)
                if !e.supported { return .unsupported }
                if let f = e.fts { ftsParts.append(f) }
                if let s = e.sql { sqlParts.append("(\(s))"); binds.append(contentsOf: e.bindings) }
            }
            return Extraction(
                fts: ftsParts.isEmpty ? nil : ftsParts.joined(separator: " AND "),
                sql: sqlParts.isEmpty ? nil : sqlParts.joined(separator: " AND "),
                bindings: binds,
                supported: true
            )
        case .or(let children):
            var branches: [Extraction] = []
            for c in children {
                let e = extract(c)
                if !e.supported { return .unsupported }
                if e.fts != nil || e.sql != nil { branches.append(e) }
            }
            if branches.isEmpty { return .empty }
            // An OR can't straddle the MATCH/SQL boundary: every branch must
            // be all-FTS or all-SQL, and the branches must agree.
            if branches.contains(where: { $0.fts != nil && $0.sql != nil }) { return .unsupported }
            let anyFTS = branches.contains { $0.fts != nil }
            let anySQL = branches.contains { $0.sql != nil }
            if anyFTS && anySQL { return .unsupported }
            if anyFTS {
                let parts = branches.compactMap { $0.fts }
                return Extraction(fts: "(" + parts.joined(separator: " OR ") + ")", sql: nil, bindings: [], supported: true)
            }
            var sqlParts: [String] = []
            var binds: [SQLBinding] = []
            for e in branches {
                if let s = e.sql { sqlParts.append("(\(s))"); binds.append(contentsOf: e.bindings) }
            }
            return Extraction(fts: nil, sql: "(" + sqlParts.joined(separator: " OR ") + ")", bindings: binds, supported: true)
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
            // Search both body columns so `body:` keeps full recall after the
            // clean/quoted split (the column weights only matter for ranking).
            return ftsField("body_clean body_quoted", v)
        case .attachmentName(let v):
            return ftsField("attachment_names", v)
        case .attachmentType(let t):
            // Substring match on content-type so `pdf` hits `application/pdf`.
            // `t` is already lowercased by the parser.
            return .sql(
                fragment: "EXISTS (SELECT 1 FROM attachments a WHERE a.message_rowid = m.apple_rowid AND LOWER(a.content_type) LIKE ?)",
                bindings: [.text("%\(t)%")]
            )
        case .attachmentSize(let cmp, let bytes):
            // `cmp.sql` is a fixed enum rawValue (>, >=, …), not user input.
            return .sql(
                fragment: "EXISTS (SELECT 1 FROM attachments a WHERE a.message_rowid = m.apple_rowid AND a.byte_count \(cmp.sql) ?)",
                bindings: [.int(Int64(bytes))]
            )
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
        case .thread(let id):
            // Match both real and synthetic-singleton thread IDs (a
            // not-yet-grouped message has thread_id = 0 and is keyed by
            // its own apple_rowid in `effectiveThreadIdExpr` / MCP results).
            return .sql(
                fragment: "(m.thread_id = ? OR (m.thread_id = 0 AND m.apple_rowid = ?))",
                bindings: [.int(Int64(id)), .int(Int64(id))]
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
        // Split on non-alphanumerics so addresses / domains tokenise the
        // same way FTS5's unicode61 tokeniser broke them apart at index
        // time. Without this, `from:vendor.com` searches for the
        // single token "vendor.com" — which doesn't exist, because
        // `alice@vendor.com` was indexed as ["alice", "vendor",
        // "com"]. With this split, the search becomes
        // `{sender}: (vendor* AND com*)` and hits any vendor.com
        // sender. Same for `from:jdoe@vendor.com` → tokens
        // [jdoe, vendor, com] all AND-prefixed.
        let tokens = safe
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return .empty }
        if tokens.count == 1 {
            return .text("{\(column)}: \(tokens[0])*")
        }
        let inner = tokens.map { "\($0)*" }.joined(separator: " AND ")
        return .text("{\(column)}: (\(inner))")
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
        case .attachmentType(let t): return "\(pre)attachment-type:\(t)"
        case .attachmentSize(let cmp, let bytes): return "\(pre)attachment-size:\(cmp.rawValue)\(bytes)"
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
        case .thread(let id):        return "\(pre)thread:\(id)"
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
