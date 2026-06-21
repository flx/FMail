import Foundation
import SQLite3

/// Markers + sizing for the `snippet()` excerpts returned by
/// `IndexDB.searchRanked`. The markers wrap matched terms inside the excerpt;
/// they're chosen to be rare in mail bodies so an LLM consumer can strip them
/// unambiguously, and none contains a single quote (they're embedded in a
/// single-quoted SQL string literal in the snippet() call).
enum SearchSnippet {
    static let open = "«"
    static let close = "»"
    static let ellipsis = "…"
    static let defaultTokens = 18
    static let minTokens = 5
    static let maxTokens = 64
}

/// Actor wrapping FMail's own SQLite database. Not thread-safe externally;
/// all access goes through actor methods.
actor IndexDB {
    // Immutable after init. `unsafe` only because the nonisolated deinit
    // closes the (non-Sendable) handle; `let` makes the immutability explicit
    // and lets every call site use `db` directly instead of `db!`.
    nonisolated(unsafe) private let db: OpaquePointer

    /// Returns `~/Library/Application Support/FMail/index.sqlite`. Creates the
    /// directory if needed.
    static func defaultPath() throws -> String {
        let supportDir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("FMail", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        return supportDir.appendingPathComponent("index.sqlite").path
    }

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let msg = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            sqlite3_close(handle)
            throw IndexDBError.openFailed(msg)
        }
        self.db = handle
        try Schema.apply(to: handle)
        // Connection-scoped scratch tables holding the current "priority
        // senders" set: exact lowercased addresses (`priority_addr`) and
        // lowercased GLOB patterns like `*vendor*` (`priority_pat`). Rebuilt by
        // `updatePrioritySet`; joined against by the menu's Priority/Other
        // split. Created here so the split queries can reference them before the
        // first update.
        try Schema.exec(handle, "CREATE TEMP TABLE IF NOT EXISTS priority_addr(addr TEXT PRIMARY KEY)")
        try Schema.exec(handle, "CREATE TEMP TABLE IF NOT EXISTS priority_pat(pat TEXT PRIMARY KEY)")
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: — Metadata

    func setMeta(_ key: String, _ value: String) throws {
        let sql = "INSERT INTO index_metadata(key, value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value"
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, key)
        bind(stmt, 2, value)
        try stepDone(stmt)
    }

    func getMeta(_ key: String) throws -> String? {
        var stmt: OpaquePointer?
        try prepare("SELECT value FROM index_metadata WHERE key = ?", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, key)
        if sqlite3_step(stmt) == SQLITE_ROW, let cstr = sqlite3_column_text(stmt, 0) {
            return String(cString: cstr)
        }
        return nil
    }

    // MARK: — Body-index read queries

    /// Unread messages whose body hasn't been indexed yet AND aren't in a
    /// drafts/trash/junk mailbox. Used by the post-sync auto-fetch hook —
    /// we ask Mail.app to download these so they're readable when the user
    /// opens them. Newest first, so freshly arrived mail wins. `limit: nil`
    /// means no LIMIT clause — fetch everything.
    func fetchUnreadMissingBody(limit: Int?) throws -> [(rowid: Int, mailboxRowId: Int, imapUID: Int?, rfcMessageId: String?)] {
        let sql = """
        SELECT m.apple_rowid, m.mailbox_rowid, m.imap_uid, m.rfc_message_id
        FROM messages m
        WHERE m.is_read = 0
          AND m.body_indexed = 0
          AND m.mailbox_rowid NOT IN (SELECT apple_rowid FROM mailboxes WHERE kind IN ('drafts', 'trash', 'junk'))
        ORDER BY m.date_received DESC
        \(limit.map { "LIMIT \($0)" } ?? "")
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        var out: [(Int, Int, Int?, String?)] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            let rowid = Int(sqlite3_column_int64(stmt, 0))
            let mboxId = Int(sqlite3_column_int64(stmt, 1))
            let uid: Int? = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 2))
            let rfc = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            out.append((rowid, mboxId, uid, rfc))
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw IndexDBError.stepFailed(String(cString: sqlite3_errmsg(db))) }
        return out.map { (rowid: $0.0, mailboxRowId: $0.1, imapUID: $0.2, rfcMessageId: $0.3) }
    }

    /// Returns up to `limit` messages where body_indexed = 0, oldest-first
    /// (newer mail tends to already be parseable; older mail may need on-demand
    /// fetch from Mail.app and we want to surface gaps early).
    func fetchUnindexedBodyMessages(limit: Int) throws -> [(rowid: Int, mailboxRowId: Int)] {
        var stmt: OpaquePointer?
        try prepare("""
            SELECT apple_rowid, mailbox_rowid
            FROM messages
            WHERE body_indexed = 0
            ORDER BY apple_rowid DESC
            LIMIT ?
            """, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, Int64(limit))
        var out: [(Int, Int)] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            out.append((Int(sqlite3_column_int64(stmt, 0)), Int(sqlite3_column_int64(stmt, 1))))
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw IndexDBError.stepFailed(String(cString: sqlite3_errmsg(db))) }
        return out.map { (rowid: $0.0, mailboxRowId: $0.1) }
    }

    func countUnindexedBody() throws -> Int {
        var stmt: OpaquePointer?
        try prepare("SELECT COUNT(*) FROM messages WHERE body_indexed = 0", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// One-shot rowid → effective-thread-id map. Used by the optimistic-flip
    /// path to update every affected thread's summary in
    /// `threadsForSelectedMailbox`, not just the currently open one. Returns
    /// the synthetic singleton id (apple_rowid) for unthreaded messages so
    /// the keys match the ids displayed in the thread list.
    func threadIds(forMessages rowids: [Int]) throws -> [Int: Int] {
        guard !rowids.isEmpty else { return [:] }
        let placeholders = rowids.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT apple_rowid, \(Self.effectiveThreadIdExpr) FROM messages m WHERE apple_rowid IN (\(placeholders))"
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        for (i, id) in rowids.enumerated() {
            bind(stmt, Int32(i + 1), Int64(id))
        }
        var out: [Int: Int] = [:]
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            let rowid = Int(sqlite3_column_int64(stmt, 0))
            let tid = Int(sqlite3_column_int64(stmt, 1))
            out[rowid] = tid
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw IndexDBError.stepFailed(String(cString: sqlite3_errmsg(db))) }
        return out
    }

    /// Run a compiled search query and return matched messages. The
    /// compiled query is a single SQL boolean expression on `messages m`;
    /// text predicates compile to `apple_rowid IN (SELECT rowid FROM messages_fts ...)`
    /// subqueries, so AND / OR / NOT all compose natively here. Search always
    /// excludes drafts/trash/junk (canonical or label) — to search inside one
    /// of those, navigate to that mailbox first.
    ///
    /// `sort`:
    ///   .newestFirst (default): ORDER BY date_received DESC
    ///   .oldestFirst:           ORDER BY date_received ASC
    ///   .relevance:             ORDER BY date (fallback) — true BM25 ranking
    ///                           is handled by `searchRanked`, which the MCP
    ///                           layer uses whenever the query carries a
    ///                           `relevancePlan`. This IN-subquery shape can't
    ///                           surface bm25() (the FTS table is hidden inside
    ///                           the subquery), so a relevance sort with no
    ///                           plan degrades to newest-first here.
    func search(_ q: CompiledQuery, limit: Int = 200, offset: Int = 0, sort: SearchSort = .newestFirst) throws -> [MessageHeader] {
        guard q.hasAnyConstraint else { return [] }

        let orderBy: String
        switch sort {
        case .newestFirst: orderBy = "m.date_received DESC"
        case .oldestFirst: orderBy = "m.date_received ASC"
        case .relevance:   orderBy = "m.date_received DESC"  // fallback
        }

        let sql = """
        SELECT \(Self.messageHeaderSelectList)
        FROM messages m
        WHERE (\(q.whereClause))
          AND \(Self.systemMailboxExcludeFilter)
        ORDER BY \(orderBy) LIMIT ? OFFSET ?
        """
        var bindings = q.bindings
        bindings.append(.int(Int64(limit)))
        bindings.append(.int(Int64(max(0, offset))))

        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        for (i, b) in bindings.enumerated() {
            switch b {
            case .int(let v): sqlite3_bind_int64(stmt, Int32(i + 1), v)
            case .text(let s): bind(stmt, Int32(i + 1), s)
            }
        }
        return try Self.collectMessageHeaders(stmt)
    }

    /// One ranked search result: a decoded header plus an optional snippet —
    /// a short excerpt of the best-matching column with the matched terms
    /// wrapped in `SearchSnippet.open`/`.close` markers.
    struct RankedHit: Sendable {
        let header: MessageHeader
        let snippet: String?
    }

    /// BM25-ranked / snippet search. Unlike `search()`'s `apple_rowid IN
    /// (SELECT rowid FROM messages_fts …)` shape, this JOINs `messages_fts`
    /// directly so `bm25()` and `snippet()` are in scope of the outer query.
    /// Requires a `RelevancePlan` (a single positive FTS match plus an
    /// FTS-free `m.*` residual) — the MCP layer only calls this when
    /// `CompiledQuery.relevancePlan != nil`.
    ///
    /// `sort`: `.relevance` orders by the blended score (see
    /// `searchRankedByRelevance`); `.newestFirst` / `.oldestFirst` keep date
    /// order but still attach snippets.
    func searchRanked(
        plan: RelevancePlan,
        limit: Int,
        offset: Int,
        sort: SearchSort,
        includeSnippet: Bool,
        snippetTokens: Int,
        tuning: RelevanceTuning = .default
    ) throws -> [RankedHit] {
        switch sort {
        case .relevance:
            return try searchRankedByRelevance(
                plan: plan, limit: limit, offset: offset,
                includeSnippet: includeSnippet, snippetTokens: snippetTokens, tuning: tuning
            )
        case .newestFirst, .oldestFirst:
            return try searchRankedByDate(
                plan: plan, limit: limit, offset: offset, sort: sort,
                includeSnippet: includeSnippet, snippetTokens: snippetTokens, tuning: tuning
            )
        }
    }

    /// `.relevance` ordering: a blended score over the matched set.
    ///
    ///   final = (bm25_norm * bulk_mult) + λ·recency + boost·[matches NEAR()]
    ///
    /// `bm25_norm` is the negated, column-weighted BM25 (higher = better)
    /// divided by the top score in the matched set, so the recency and
    /// proximity terms live on a comparable 0…1 scale and `λ` / `boost` mean
    /// the same thing regardless of the query's raw BM25 magnitude. The
    /// matched set is materialised in a CTE (one `MATCH`, the system-mailbox
    /// filter, and the FTS-free residual) so `bm25()` / `snippet()` are in
    /// scope and the page-wide `MAX(text_score)` is one scan. Column weights
    /// are formatted as numeric literals (never user input); λ / τ / the bulk
    /// multiplier / the proximity boost are bound parameters.
    private func searchRankedByRelevance(
        plan: RelevancePlan,
        limit: Int,
        offset: Int,
        includeSnippet: Bool,
        snippetTokens: Int,
        tuning: RelevanceTuning
    ) throws -> [RankedHit] {
        let weights = tuning.columnWeights
            .map { String(format: "%.6f", $0) }
            .joined(separator: ", ")
        let snippetSelect = includeSnippet ? ", \(Self.snippetExpr(tokens: snippetTokens)) AS snip" : ""
        let snippetOut = includeSnippet ? ", scored.snip" : ", NULL"
        let residual = plan.residualSQL.map { " AND (\($0))" } ?? ""
        let bulkFilter = tuning.includeBulk ? "" : " AND m.is_bulk = 0"
        let proximityTerm = plan.proximityMatch != nil
            ? "\n          + ? * (CASE WHEN scored.rid IN (SELECT rowid FROM messages_fts WHERE messages_fts MATCH ?) THEN 1.0 ELSE 0.0 END)"
            : ""

        // `MATERIALIZED` is load-bearing: without it SQLite flattens the CTE
        // into the outer query, which lifts `bm25()` / `snippet()` out of the
        // `MATCH` context and fails with "unable to use function bm25 in the
        // requested context". Materialising computes the FTS-aux columns where
        // the MATCH is in scope, then the outer query just reads them.
        let sql = """
        WITH scored AS MATERIALIZED (
            SELECT m.apple_rowid AS rid,
                   (-bm25(messages_fts, \(weights))) AS text_score,
                   m.is_bulk AS is_bulk,
                   COALESCE(m.date_received, 0) AS dr\(snippetSelect)
            FROM messages_fts
            JOIN messages m ON m.apple_rowid = messages_fts.rowid
            WHERE messages_fts MATCH ?\(residual)
              AND \(Self.systemMailboxExcludeFilter)\(bulkFilter)
        )
        SELECT \(Self.messageHeaderSelectList)\(snippetOut)
        FROM scored
        JOIN messages m ON m.apple_rowid = scored.rid
        ORDER BY
            (scored.text_score / NULLIF((SELECT MAX(text_score) FROM scored), 0))
              * (CASE WHEN scored.is_bulk = 1 THEN ? ELSE 1.0 END)
          + ? * (CASE WHEN scored.dr <= 0 THEN 0.0
                      ELSE exp(-((CAST(strftime('%s','now') AS REAL) - scored.dr) / 86400.0) / ?) END)\(proximityTerm)
            DESC
        LIMIT ? OFFSET ?
        """

        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        var pos: Int32 = 1
        bind(stmt, pos, plan.ftsMatch); pos += 1
        for b in plan.residualBindings { bindSQL(stmt, pos, b); pos += 1 }
        sqlite3_bind_double(stmt, pos, tuning.bulkMultiplier); pos += 1
        sqlite3_bind_double(stmt, pos, tuning.lambda); pos += 1
        sqlite3_bind_double(stmt, pos, Swift.max(1.0, tuning.tauDays)); pos += 1
        if let near = plan.proximityMatch {
            sqlite3_bind_double(stmt, pos, tuning.proximityBoost); pos += 1
            bind(stmt, pos, near); pos += 1
        }
        bind(stmt, pos, Int64(limit)); pos += 1
        bind(stmt, pos, Int64(Swift.max(0, offset)))

        return try collectRankedHits(stmt, includeSnippet: includeSnippet)
    }

    /// `.newestFirst` / `.oldestFirst` ranked search — date order, still
    /// attaching a snippet of the best-matching column. No BM25 blend.
    private func searchRankedByDate(
        plan: RelevancePlan,
        limit: Int,
        offset: Int,
        sort: SearchSort,
        includeSnippet: Bool,
        snippetTokens: Int,
        tuning: RelevanceTuning
    ) throws -> [RankedHit] {
        let orderBy = (sort == .oldestFirst) ? "m.date_received ASC" : "m.date_received DESC"
        let snippetExpr = includeSnippet ? ", \(Self.snippetExpr(tokens: snippetTokens))" : ", NULL"
        let residual = plan.residualSQL.map { " AND (\($0))" } ?? ""
        let bulkFilter = tuning.includeBulk ? "" : " AND m.is_bulk = 0"
        let sql = """
        SELECT \(Self.messageHeaderSelectList)\(snippetExpr)
        FROM messages_fts
        JOIN messages m ON m.apple_rowid = messages_fts.rowid
        WHERE messages_fts MATCH ?\(residual)
          AND \(Self.systemMailboxExcludeFilter)\(bulkFilter)
        ORDER BY \(orderBy) LIMIT ? OFFSET ?
        """

        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        var pos: Int32 = 1
        bind(stmt, pos, plan.ftsMatch); pos += 1
        for b in plan.residualBindings { bindSQL(stmt, pos, b); pos += 1 }
        bind(stmt, pos, Int64(limit)); pos += 1
        bind(stmt, pos, Int64(Swift.max(0, offset)))

        return try collectRankedHits(stmt, includeSnippet: includeSnippet)
    }

    /// The `snippet(messages_fts, …)` SQL fragment. `-1` lets FTS5 pick the
    /// best-matching column for the excerpt; the markers + clamped token count
    /// are constants, so this carries no injectable input.
    private static func snippetExpr(tokens: Int) -> String {
        let n = Swift.max(SearchSnippet.minTokens, Swift.min(SearchSnippet.maxTokens, tokens))
        return "snippet(messages_fts, -1, '\(SearchSnippet.open)', '\(SearchSnippet.close)', '\(SearchSnippet.ellipsis)', \(n))"
    }

    /// Bind one `SQLBinding` at `pos` (int or text).
    private func bindSQL(_ stmt: OpaquePointer?, _ pos: Int32, _ b: SQLBinding) {
        switch b {
        case .int(let v): sqlite3_bind_int64(stmt, pos, v)
        case .text(let s): bind(stmt, pos, s)
        }
    }

    /// Decode a ranked-search result set: a 12-column header select list with
    /// the snippet as the column right after it (col 12).
    private func collectRankedHits(_ stmt: OpaquePointer?, includeSnippet: Bool) throws -> [RankedHit] {
        let snippetCol: Int32 = 12
        var out: [RankedHit] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            let header = Self.decodeMessageHeader(stmt)
            let snip = includeSnippet ? sqlite3_column_text(stmt, snippetCol).map { String(cString: $0) } : nil
            out.append(RankedHit(header: header, snippet: snip))
            rc = sqlite3_step(stmt)
        }
        try checkRowLoopDone(rc)
        return out
    }

    // MARK: — Read API for UI

    // NOTE: the bare `String(cString:)` reads below (and in `loadAccounts` /
    // `decodeRepresentative`) are crash-safe only because these columns are
    // declared `NOT NULL DEFAULT ''` in `Schema`. A future migration that
    // makes one of them nullable must switch that read to the NULL-safe
    // `.map { String(cString:) } ?? ""` form.
    func loadMailboxes() throws -> [Mailbox] {
        var stmt: OpaquePointer?
        try prepare("SELECT apple_rowid, account_uuid, path, name, hidden, total_count, unread_count, kind FROM mailboxes ORDER BY name", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        var out: [Mailbox] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            let rowid = Int(sqlite3_column_int64(stmt, 0))
            let acctUUID = String(cString: sqlite3_column_text(stmt, 1))
            let path = String(cString: sqlite3_column_text(stmt, 2))
            let pathComponents = path.split(separator: "/").map(String.init)
            let total = Int(sqlite3_column_int64(stmt, 5))
            let unread = Int(sqlite3_column_int64(stmt, 6))
            let hidden = sqlite3_column_int(stmt, 4) != 0
            let kindStr = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
            let kind = kindStr.flatMap(MailboxKind.init(rawValue:)) ?? .other
            out.append(Mailbox(
                rowId: rowid,
                accountUUID: acctUUID,
                pathComponents: pathComponents,
                totalCount: total,
                unreadCount: unread,
                hidden: hidden,
                kind: kind
            ))
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw IndexDBError.stepFailed(String(cString: sqlite3_errmsg(db))) }
        return out
    }

    func loadAccounts() throws -> [MailAccount] {
        var stmt: OpaquePointer?
        try prepare("SELECT uuid, display_name, email_address FROM accounts ORDER BY display_name", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        var out: [MailAccount] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            let uuid = String(cString: sqlite3_column_text(stmt, 0))
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let email = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            out.append(MailAccount(uuid: uuid, displayName: name, emailAddress: email))
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw IndexDBError.stepFailed(String(cString: sqlite3_errmsg(db))) }
        return out
    }

    /// Count of unread messages across the entire index, excluding
    /// drafts/trash/junk — badge for the "All Mailboxes" sidebar row.
    /// Filters by *both* canonical mailbox kind *and* labels (Gmail's spam
    /// lives canonically in `[Gmail]/All Mail` and is only marked spam via
    /// a label in the `message_labels` table).
    func countAllUnreadExcludingDrafts() throws -> Int {
        var stmt: OpaquePointer?
        try prepare("""
            SELECT COUNT(*) FROM messages m
            WHERE m.is_read = 0
              AND \(Self.systemMailboxExcludeFilter)
            """, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// SQL fragment that filters out messages whose canonical mailbox OR any
    /// of its labels is a drafts / trash / junk / spam mailbox. Inlined into
    /// every "user-facing list" query so junk-folder mail doesn't bleed into
    /// global views.
    static let systemMailboxExcludeFilter = """
        m.mailbox_rowid NOT IN (
            SELECT apple_rowid FROM mailboxes WHERE kind IN ('drafts', 'trash', 'junk')
        )
        AND m.apple_rowid NOT IN (
            SELECT message_rowid FROM message_labels
            WHERE mailbox_rowid IN (
                SELECT apple_rowid FROM mailboxes WHERE kind IN ('drafts', 'trash', 'junk')
            )
        )
        """

    enum ThreadViewScope {
        /// User is browsing the Drafts/Trash/Junk mailbox itself — show
        /// everything in the thread including those.
        case includeAll
        /// Default: hide drafts only (the messages still being composed).
        case excludeDrafts
        /// "All Mailboxes" view: hide drafts AND trash AND junk.
        case excludeAllSystem
    }

    func loadThreadMessages(threadId: Int, scope: ThreadViewScope = .excludeDrafts) throws -> [MessageHeader] {
        let filter: String
        switch scope {
        case .includeAll:
            filter = ""
        case .excludeDrafts:
            filter = " AND m.mailbox_rowid NOT IN (SELECT apple_rowid FROM mailboxes WHERE kind = 'drafts')"
        case .excludeAllSystem:
            filter = " AND \(Self.systemMailboxExcludeFilter)"
        }
        let sql = """
        SELECT \(Self.messageHeaderSelectList)
        FROM messages m
        WHERE \(Self.threadScopePredicate)\(filter)
        ORDER BY m.date_received ASC
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, Int64(threadId))
        bind(stmt, 2, Int64(threadId))
        return try Self.collectMessageHeaders(stmt)
    }

    // MARK: — Internals used by ThreadGrouper

    /// `apple_rowid → is_read` for every indexed message. Backs the flag-only
    /// reconcile (compared against Apple's Envelope Index `read` column).
    func snapshotReadFlags() throws -> [Int: Bool] {
        var stmt: OpaquePointer?
        try prepare("SELECT apple_rowid, is_read FROM messages", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        var out: [Int: Bool] = [:]
        out.reserveCapacity(200_000)
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            out[Int(sqlite3_column_int64(stmt, 0))] = sqlite3_column_int(stmt, 1) != 0
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw IndexDBError.stepFailed(String(cString: sqlite3_errmsg(db))) }
        return out
    }

    /// Streams (apple_rowid, apple_message_id_hash, date_received, is_read, is_flagged)
    /// for all messages. Used by ThreadGrouper to build components in memory.
    func snapshotMessagesForThreading() throws -> [(rowid: Int, hash: Int64, date: Int, isRead: Bool, isFlagged: Bool)] {
        var stmt: OpaquePointer?
        try prepare("SELECT apple_rowid, apple_message_id_hash, COALESCE(date_received, 0), is_read, is_flagged FROM messages", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        var out: [(Int, Int64, Int, Bool, Bool)] = []
        out.reserveCapacity(200_000)
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            out.append((
                Int(sqlite3_column_int64(stmt, 0)),
                sqlite3_column_int64(stmt, 1),
                Int(sqlite3_column_int64(stmt, 2)),
                sqlite3_column_int(stmt, 3) != 0,
                sqlite3_column_int(stmt, 4) != 0
            ))
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw IndexDBError.stepFailed(String(cString: sqlite3_errmsg(db))) }
        return out.map { (rowid: $0.0, hash: $0.1, date: $0.2, isRead: $0.3, isFlagged: $0.4) }
    }

    func snapshotMessageLinks() throws -> [(from: Int, toHash: Int64)] {
        var stmt: OpaquePointer?
        try prepare("SELECT from_message_rowid, to_message_id_hash FROM message_links", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        var out: [(Int, Int64)] = []
        out.reserveCapacity(200_000)
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            out.append((Int(sqlite3_column_int64(stmt, 0)), sqlite3_column_int64(stmt, 1)))
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else { throw IndexDBError.stepFailed(String(cString: sqlite3_errmsg(db))) }
        return out.map { (from: $0.0, toHash: $0.1) }
    }

    // MARK: — Helpers

    /// SQL expression: the effective thread id for a row. Real thread_id
    /// when set (>0); apple_rowid as a synthetic id when the message hasn't
    /// been threaded yet (thread_id = 0). Real thread ids are
    /// `min(memberRowIds)`, so a rowid never equals a real thread id unless
    /// the message is in that thread — by definition impossible for an
    /// unthreaded message. So the namespaces don't overlap.
    static let effectiveThreadIdExpr = """
        CASE WHEN m.thread_id = 0 THEN m.apple_rowid ELSE m.thread_id END
        """

    /// SQL fragment used in the thread-scoped lookups (latest representative,
    /// load thread messages). Matches both real-thread members and a single
    /// synthetic-id message (an unthreaded one whose apple_rowid equals the
    /// supplied id). Bind the same value to both `?`s.
    static let threadScopePredicate = """
        (m.thread_id = ? OR (m.thread_id = 0 AND m.apple_rowid = ?))
        """

    /// Shared SELECT list for the 12 columns `decodeMessageHeader` expects,
    /// with the `m.` alias and the subject prefix already concatenated.
    /// Reused by `search`, `loadThreadMessages`, and `loadMessage` so the
    /// column order can't drift between query and decoder.
    static let messageHeaderSelectList = """
        m.apple_rowid, m.mailbox_rowid,
        COALESCE(m.subject_prefix, '') || m.subject,
        m.sender_address, m.sender_display,
        m.date_sent, m.date_received,
        m.is_read, m.is_flagged, m.rfc_message_id, m.imap_uid,
        m.has_attachment
        """

    /// Decode one `MessageHeader` from a row shaped like
    /// `messageHeaderSelectList`. Caller must have stepped to `SQLITE_ROW`.
    nonisolated static func decodeMessageHeader(_ stmt: OpaquePointer?) -> MessageHeader {
        let rowid = Int(sqlite3_column_int64(stmt, 0))
        let mboxId = Int(sqlite3_column_int64(stmt, 1))
        let subject = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let sa = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
        let sd = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
        let ds = sqlite3_column_int64(stmt, 5)
        let dr = sqlite3_column_int64(stmt, 6)
        let read = sqlite3_column_int(stmt, 7) != 0
        let flagged = sqlite3_column_int(stmt, 8) != 0
        let rfcId = sqlite3_column_text(stmt, 9).map { String(cString: $0) }
        let uid: Int? = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 10))
        let hasAttachment = sqlite3_column_int(stmt, 11) != 0
        return MessageHeader(
            rowId: rowid, mailboxRowId: mboxId, subject: subject,
            senderAddress: sa, senderDisplay: sd,
            dateSent: ds > 0 ? Date(timeIntervalSince1970: TimeInterval(ds)) : nil,
            dateReceived: dr > 0 ? Date(timeIntervalSince1970: TimeInterval(dr)) : nil,
            isRead: read, isFlagged: flagged, hasAttachment: hasAttachment,
            rfcMessageId: rfcId, imapUID: uid
        )
    }

    /// Decode every remaining row as a `MessageHeader`.
    ///
    /// Throws on a terminal code other than `SQLITE_DONE` (BUSY/ERROR/CORRUPT
    /// from Mail.app's concurrent writes), so a truncated result surfaces to
    /// the caller instead of silently returning a short list — consistent with
    /// the other read loops (see `checkRowLoopDone`). It's `nonisolated static`
    /// with no `db` handle, so the thrown message carries the raw `rc` rather
    /// than `sqlite3_errmsg`; all callers (`search`, `loadThreadMessages`,
    /// `searchSplitByPriority`) already `throws`.
    nonisolated static func collectMessageHeaders(_ stmt: OpaquePointer?) throws -> [MessageHeader] {
        var out: [MessageHeader] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            out.append(decodeMessageHeader(stmt))
            rc = sqlite3_step(stmt)
        }
        guard rc == SQLITE_DONE else {
            throw IndexDBError.stepFailed("collectMessageHeaders: terminal rc=\(rc) (result would be truncated)")
        }
        return out
    }

    // MARK: — Low-level helpers
    //
    // `db` is private to this file; the helpers below (`exec`, `inTransaction`,
    // `prepare`, `stepDone`, `bind*`) are the only seam through which the
    // IndexDB extensions in other files (IndexDB+Write, IndexDB+ThreadList,
    // IndexDB+MCP) reach SQLite. External callers should still go through the
    // typed APIs.

    /// Run a single statement with no bindings/results.
    func exec(_ sql: String) throws {
        try Schema.exec(db, sql)
    }

    func inTransaction(_ work: () throws -> Void) throws {
        try exec("BEGIN TRANSACTION;")
        do {
            try work()
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    func prepare(_ sql: String, into stmt: inout OpaquePointer?) throws {
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if rc != SQLITE_OK {
            throw IndexDBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func stepDone(_ stmt: OpaquePointer?) throws {
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            throw IndexDBError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    /// Assert that a read loop's terminal `sqlite3_step` return code is
    /// `SQLITE_DONE`. Any other code (SQLITE_BUSY/ERROR/CORRUPT — common while
    /// Mail.app concurrently writes the Envelope Index) means the loop stopped
    /// early and the collected results are truncated; we throw rather than
    /// silently return a short list, which would feed `pruneMessagesNotIn` a
    /// too-small keep-set. Exposed (non-private) so the IndexDB extensions in
    /// other files can reach `db`'s `sqlite3_errmsg`, which is file-private.
    func checkRowLoopDone(_ rc: Int32) throws {
        guard rc == SQLITE_DONE else {
            throw IndexDBError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    nonisolated func bind(_ stmt: OpaquePointer?, _ pos: Int32, _ value: String) {
        sqlite3_bind_text(stmt, pos, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    nonisolated func bind(_ stmt: OpaquePointer?, _ pos: Int32, _ value: Int) {
        sqlite3_bind_int64(stmt, pos, Int64(value))
    }

    nonisolated func bind(_ stmt: OpaquePointer?, _ pos: Int32, _ value: Int64) {
        sqlite3_bind_int64(stmt, pos, value)
    }

    nonisolated func bindOptional(_ stmt: OpaquePointer?, _ pos: Int32, _ value: String?) {
        if let v = value {
            bind(stmt, pos, v)
        } else {
            sqlite3_bind_null(stmt, pos)
        }
    }

    nonisolated func bindOptional(_ stmt: OpaquePointer?, _ pos: Int32, _ value: Int?) {
        if let v = value {
            bind(stmt, pos, v)
        } else {
            sqlite3_bind_null(stmt, pos)
        }
    }
}
