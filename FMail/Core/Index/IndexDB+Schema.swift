import Foundation
import SQLite3

/// The index-derived half of FMail's data-model ontology (`fmail://schema`):
/// owner identities and the *enumerable* values actually present in this index
/// — accounts, mailbox classes, attachment-type families. Everything here is
/// computed from the live index (or optional config); nothing is hardcoded to a
/// particular mailbox, so a fresh install with different accounts, providers,
/// and folder languages produces a correct schema unchanged.
///
/// The static half (entity/field lists, relationship strings, operator grammar,
/// few-shot exemplars) lives in the MCP layer (`MCPSchema`), which assembles it
/// around these values.

/// Index-present enum values for the schema document. Plain `Sendable` data so
/// it can be memoised inside the `IndexDB` actor and handed to the MCP layer.
struct SchemaEnums: Sendable {
    struct Account: Sendable {
        let uuid: String
        let email: String?
        let displayName: String
        /// Whether this account counts as the user's own. Defaults true for
        /// every configured account; false only when the user marked it
        /// non-owner (e.g. a shared family mailbox).
        let isOwner: Bool
        let messageCount: Int
        /// Canonical mailbox classes present in this account (e.g.
        /// `["inbox","sent","all"]`).
        let mailboxClasses: [String]
    }

    let accounts: [Account]
    /// Every address that identifies an owner (`from:me`/`in:sent` resolve to
    /// this set). Lowercased, de-duplicated, sorted.
    let ownerIdentities: [String]
    /// Distinct canonical mailbox classes present across the whole index.
    let mailboxClasses: [String]
    /// Distinct attachment-type families present (queryable via
    /// `attachment-type:`), e.g. `["pdf","image","zip"]`.
    let attachmentTypes: [String]
}

extension IndexDB {

    // MARK: — Owner identities

    /// Every email address that identifies the mailbox's owner — the union of
    /// the configured accounts' own addresses plus, for any account whose
    /// address FMail couldn't derive, the dominant sender in that account's
    /// `\Sent` mail. Lowercased, trimmed, de-duplicated, sorted. Accounts in
    /// `excluded` (a user-configured non-owner set) contribute nothing.
    ///
    /// Nothing here is hardcoded: a different install derives a different set.
    /// This is the single source of truth shared by `from:me`/`to:me`/`cc:me`
    /// and `in:sent` (via `OwnerExpansion`) and by the schema document, so
    /// `from:me` and `in:sent` always resolve against the same owner set.
    func ownerIdentities(excludingAccounts excluded: Set<String> = []) throws -> [String] {
        let isExcluded = Self.nonOwnerPredicate(excluded)
        var ids = Set<String>()
        for acct in try loadAccounts() {
            if isExcluded(acct.uuid, acct.emailAddress) { continue }
            let email = acct.emailAddress?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            if !email.isEmpty {
                ids.insert(email)
            } else if let inferred = try dominantSentSender(accountUUID: acct.uuid) {
                ids.insert(inferred)
            }
        }
        return ids.sorted()
    }

    /// Build the predicate that decides whether an account is a *non-owner*. The
    /// configured set (from `MCPSettings.nonOwnerAccounts`) entries may be either
    /// an account UUID or an account email — whichever the user finds easier —
    /// so an account matches if EITHER its uuid or its (trimmed) email is listed.
    /// All comparisons are case-insensitive. Empty set ⇒ nobody is excluded
    /// (every configured account is an owner, the default).
    static func nonOwnerPredicate(_ excluded: Set<String>) -> (String, String?) -> Bool {
        guard !excluded.isEmpty else { return { _, _ in false } }
        let lowered = Set(excluded.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        return { uuid, email in
            if lowered.contains(uuid.lowercased()) { return true }
            if let e = email?.trimmingCharacters(in: .whitespaces).lowercased(), !e.isEmpty {
                return lowered.contains(e)
            }
            return false
        }
    }

    /// Dominant `From:` address among an account's `\Sent`-class mail — the
    /// fallback owner identity for an account whose own address couldn't be
    /// derived. Scoped to `kind = 'sent'` so an external inbox sender can never
    /// be mistaken for the owner. nil when the account has no classified sent
    /// mail to learn from.
    private func dominantSentSender(accountUUID: String) throws -> String? {
        var stmt: OpaquePointer?
        try prepare("""
            SELECT LOWER(m.sender_address) AS s, COUNT(*) AS c
            FROM messages m
            JOIN mailboxes mb ON mb.apple_rowid = m.mailbox_rowid
            WHERE mb.account_uuid = ?
              AND mb.kind = 'sent'
              AND m.sender_address IS NOT NULL
              AND TRIM(m.sender_address) <> ''
            GROUP BY s
            ORDER BY c DESC
            LIMIT 1
            """, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, accountUUID)
        if sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) {
            return String(cString: c)
        }
        return nil
    }

    // MARK: — Schema enum builder (memoised via `schemaEnums`)

    /// Compute the present-in-this-index enum values. Read-only; callers should
    /// prefer the cached `schemaEnums(excludingAccounts:)`.
    func buildSchemaEnums(excludingAccounts excluded: Set<String>) throws -> SchemaEnums {
        let accounts = try loadAccounts()
        let owners = try ownerIdentities(excludingAccounts: excluded)
        let counts = try messageCountsByAccount()
        let classesByAccount = try mailboxClassesByAccount()

        let isExcluded = Self.nonOwnerPredicate(excluded)
        let accountEntries = accounts.map { a -> SchemaEnums.Account in
            let trimmed = a.emailAddress?.trimmingCharacters(in: .whitespaces)
            return SchemaEnums.Account(
                uuid: a.uuid,
                email: (trimmed?.isEmpty == false) ? trimmed : nil,
                displayName: a.displayName,
                isOwner: !isExcluded(a.uuid, a.emailAddress),
                messageCount: counts[a.uuid] ?? 0,
                mailboxClasses: classesByAccount[a.uuid] ?? []
            )
        }

        return SchemaEnums(
            accounts: accountEntries,
            ownerIdentities: owners,
            mailboxClasses: try distinctMailboxClasses(),
            attachmentTypes: try distinctAttachmentFamilies()
        )
    }

    private func messageCountsByAccount() throws -> [String: Int] {
        var stmt: OpaquePointer?
        try prepare("SELECT account_uuid, COUNT(*) FROM messages GROUP BY account_uuid", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        var out: [String: Int] = [:]
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            if let u = sqlite3_column_text(stmt, 0) {
                out[String(cString: u)] = Int(sqlite3_column_int64(stmt, 1))
            }
            rc = sqlite3_step(stmt)
        }
        try checkRowLoopDone(rc)
        return out
    }

    /// Distinct canonical mailbox classes per account, sorted. Reflects the
    /// mailboxes that exist in the index — so empty categories are simply absent.
    private func mailboxClassesByAccount() throws -> [String: [String]] {
        var stmt: OpaquePointer?
        try prepare("SELECT DISTINCT account_uuid, kind FROM mailboxes ORDER BY account_uuid, kind", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        var out: [String: [String]] = [:]
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            if let u = sqlite3_column_text(stmt, 0), let k = sqlite3_column_text(stmt, 1) {
                out[String(cString: u), default: []].append(String(cString: k))
            }
            rc = sqlite3_step(stmt)
        }
        try checkRowLoopDone(rc)
        return out
    }

    private func distinctMailboxClasses() throws -> [String] {
        var stmt: OpaquePointer?
        try prepare("SELECT DISTINCT kind FROM mailboxes ORDER BY kind", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            if let k = sqlite3_column_text(stmt, 0) { out.append(String(cString: k)) }
            rc = sqlite3_step(stmt)
        }
        try checkRowLoopDone(rc)
        return out
    }

    /// Distinct attachment-type *families* present, mapped from the content
    /// types in the index via the curated `AttachmentType` classifier (never
    /// fragments). Sorted; empty when the index has no attachments.
    private func distinctAttachmentFamilies() throws -> [String] {
        var stmt: OpaquePointer?
        try prepare("SELECT DISTINCT content_type FROM attachments", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        var families = Set<String>()
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                families.insert(AttachmentType.family(for: String(cString: c)))
            }
            rc = sqlite3_step(stmt)
        }
        try checkRowLoopDone(rc)
        return families.sorted()
    }
}
